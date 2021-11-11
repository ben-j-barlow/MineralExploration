
@with_kw struct MineralExplorationPOMDP <: POMDP{MEState, MEAction, MEObservation}
    reservoir_dims::Tuple{Float64, Float64, Float64} = (2000.0, 2000.0, 30.0) #  lat x lon x thick in meters
    grid_dim::Tuple{Int64, Int64, Int64} = (50, 50, 1) #  dim x dim grid size
    max_bores::Int64 = 10 # Maximum number of bores
    min_bores::Int64 = 0 # Minimum number of bores
    initial_data::RockObservations = RockObservations() # Initial rock observations
    delta::Int64 = 1 # Minimum distance between wells (grid coordinates)
    grid_spacing::Int64 = 1 # Number of cells in between each cell in which wells can be placed
    drill_cost::Float64 = 0.1
    strike_reward::Float64 = 1.0
    extraction_cost::Float64 = 125.0
    extraction_lcb::Float64 = 0.1
    # variogram::Tuple = (1, 1, 0.0, 0.0, 0.0, 30.0, 30.0, 1.0)
    variogram::Tuple = (0.005, 30.0, 0.0001) #sill, range, nugget
    # nugget::Tuple = (1, 0)
    gp_mean::Float64 = 0.0
    gp_weight::Float64 = 0.5
    mainbody_weight::Float64 = 0.7
    mainbody_loc::Vector{Float64} = [25.0, 25.0]
    mainbody_var_min::Float64 = 40.0
    mainbody_var_max::Float64 = 80.0
    massive_threshold::Float64 = 0.5
    rng::AbstractRNG = Random.GLOBAL_RNG
end

function GeoStatsDistribution(p::MineralExplorationPOMDP)
    variogram = SphericalVariogram(sill=p.variogram[1], range=p.variogram[2],
                                    nugget=p.variogram[3])
    domain = CartesianGrid{Int64}(p.grid_dim[1], p.grid_dim[2])
    return GeoStatsDistribution(grid_dims=p.grid_dim,
                                data=deepcopy(p.initial_data),
                                domain=domain,
                                mean=p.gp_mean,
                                variogram=variogram)
end

"""
    sample_coords(dims::Tuple{Int, Int}, n::Int)
Sample coordinates from a Cartesian grid of dimensions given by dims and return
them in an array
"""
function sample_coords(dims::Tuple{Int, Int, Int}, n::Int)
    idxs = CartesianIndices(dims)
    samples = sample(idxs, n)
    sample_array = Array{Int64}(undef, 2, n)
    for (i, sample) in enumerate(samples)
        sample_array[1, i] = sample[1]
        sample_array[2, i] = sample[2]
    end
    return (samples, sample_array)
end

function sample_initial(p::MineralExplorationPOMDP, n::Integer)
    coords, coords_array = sample_coords(p.grid_dim, n)
    dist = GeoStatsDistribution(p)
    state = rand(dist)
    ore_quality = state[coords]
    return RockObservations(ore_quality, coords_array)
end

function sample_initial(p::MineralExplorationPOMDP, coords::Array)
    n = length(coords)
    coords_array = Array{Int64}(undef, 2, n)
    for (i, sample) in enumerate(coords)
        coords_array[1, i] = sample[1]
        coords_array[2, i] = sample[2]
    end
    dist = GeoStatsDistribution(p)
    state = rand(dist)
    ore_quality = state[coords]
    return RockObservations(ore_quality, coords_array)
end

function initialize_data!(p::MineralExplorationPOMDP, n::Integer)
    new_rock_obs = sample_initial(p, n)
    append!(p.initial_data.ore_quals, new_rock_obs.ore_quals)
    p.initial_data.coordinates = hcat(p.initial_data.coordinates, new_rock_obs.coordinates)
    return p
end

function initialize_data!(p::MineralExplorationPOMDP, coords::Array)
    new_rock_obs = sample_initial(p, coords)
    append!(p.initial_data.ore_quals, new_rock_obs.ore_quals)
    p.initial_data.coordinates = hcat(p.initial_data.coordinates, new_rock_obs.coordinates)
    return p
end

POMDPs.discount(::MineralExplorationPOMDP) = 0.99
POMDPs.isterminal(m::MineralExplorationPOMDP, s::MEState) = s.stopped

struct MEInitStateDist
    gp_distribution::GeoStatsDistribution
    gp_weight::Float64
    mainbody_weight::Float64
    mainbody_loc::Vector{Float64}
    mainbody_var_max::Float64
    mainbody_var_min::Float64
    massive_thresh::Float64
    rng::AbstractRNG
end

function POMDPs.initialstate_distribution(m::MineralExplorationPOMDP)
    gp_dist = GeoStatsDistribution(m)
    MEInitStateDist(gp_dist, m.gp_weight, m.mainbody_weight,
                    m.mainbody_loc, m.mainbody_var_max, m.mainbody_var_min,
                    m.massive_threshold, m.rng)
end

function Base.rand(d::MEInitStateDist)
    gp_ore_map = Base.rand(d.rng, d.gp_distribution)

    # gp_ore_map ./= 0.3 # TODO
    gp_ore_map .*= d.gp_weight

    # clamp!(gp_ore_map, 0.0, d.massive_thresh)

    x_dim = d.gp_distribution.grid_dims[1]
    y_dim = d.gp_distribution.grid_dims[2]
    lode_map = zeros(Float64, x_dim, y_dim)
    mainbody_var = rand(d.rng)*(d.mainbody_var_max - d.mainbody_var_min) + d.mainbody_var_min
    cov = Distributions.PDiagMat([mainbody_var, mainbody_var])
    mvnorm = MvNormal(d.mainbody_loc, cov)
    for i = 1:x_dim
        for j = 1:y_dim
            lode_map[i, j] = pdf(mvnorm, [float(i), float(j)])
        end
    end
    max_lode = maximum(lode_map)
    lode_map ./= max_lode
    lode_map .*= d.mainbody_weight
    lode_map = repeat(lode_map, outer=(1, 1, 1))

    ore_map = lode_map + gp_ore_map
    # clamp!(ore_map, 0.0, Inf)
    # ore_map = gp_ore_map
    particles = Vector{Tuple{Float64, Array{Float64, 3}}}[]
    MEState(ore_map, mainbody_var, lode_map,
            RockObservations(), false, particles)
end

Base.rand(rng::AbstractRNG, d::MEInitStateDist) = rand(d)

function extraction_reward(m::MineralExplorationPOMDP, s::MEState)
    r = m.strike_reward*sum(s.mainbody_map .>= m.massive_threshold)
    r -= m.extraction_cost
    return r
end

function gen_observation(m::MineralExplorationPOMDP, s::MEState, a::MEAction, rng::Random.AbstractRNG)
    if s.ore_map[1,1,1] != -1.0
        return s.ore_map[a.coords[1], a.coords[2], 1]
    else
        coords = reshape([float(a.coords[1]), float(a.coords[2])], 2, 1)
        dist = GeoStatsDistribution(m) #TODO add coordinates
        gp_obs = rand(rng, dist, coords)
        mb_obs = s.mainbody_map[a.coords[1], a.coords[2], 1]
        return mb_obs + gp_obs * m.gp_weight
    end
end

function POMDPs.gen(m::MineralExplorationPOMDP, s::MEState, a::MEAction, rng::Random.AbstractRNG)
    stopped = s.stopped
    a_type = a.type
    if a_type == :stop && !stopped
        obs = MEObservation(nothing, true)
        rock_obs_p = s.rock_obs
        stopped_p = true
        if s.ore_map[1,1,1] == -1.0
            if length(s.rock_obs) > 0
                variogram = SphericalVariogram(sill=m.variogram[1], range=m.variogram[2],
                                                nugget=m.variogram[3])
                wp = reweight(s.particles, s.rock_obs, m.grid_dim, variogram, m.gp_mean, m.gp_weight, a, obs)
                particles = resample(s.particles, wp, m.grid_dim, m.mainbody_loc, m.mainbody_weight, a, obs, rng)
            else
                particles = deepcopy(s.particles)
            end
        else
            particles = deepcopy(s.particles)
        end
        volumes = [m.strike_reward*sum(p[2] .>= m.massive_threshold) for p in particles]
        vol_mean = mean(volumes)
        vol_std = std(volumes)
        if vol_mean - m.extraction_lcb*vol_std > m.extraction_cost
            r = extraction_reward(m, s)
        else
            r = 0.0
        end
    elseif a_type ==:drill && !stopped
        ore_obs = gen_observation(m, s, a, rng)
        a = reshape(Int64[a.coords[1] a.coords[2]], 2, 1)
        r = -m.drill_cost
        rock_obs_p = deepcopy(s.rock_obs)
        rock_obs_p.coordinates = hcat(rock_obs_p.coordinates, a)
        push!(rock_obs_p.ore_quals, ore_obs)
        n_bores = length(rock_obs_p.ore_quals)
        stopped_p = n_bores >= m.max_bores
        obs = MEObservation(ore_obs, stopped_p)
        particles = deepcopy(s.particles)
    else
        error("Invalid Action! Action: $a, Stopped: $stopped")
    end
    sp = MEState(s.ore_map, s.var, s.mainbody_map, rock_obs_p, stopped_p, particles)
    return (sp=sp, o=obs, r=r)
end


function POMDPs.actions(m::MineralExplorationPOMDP)
    idxs = CartesianIndices(m.grid_dim[1:2])
    bore_actions = reshape(collect(idxs), prod(m.grid_dim[1:2]))
    actions = MEAction[MEAction(type=:stop)]
    for coord in bore_actions
        push!(actions, MEAction(coords=coord))
    end
    return actions
end

function POMDPs.actions(m::MineralExplorationPOMDP, s::MEState)
    if s.stopped
        return MEAction[]
    else
        action_set = Set(POMDPs.actions(m))
        for i=1:size(s.bore_coords)[2]
            coord = s.bore_coords[:, i]
            x = Int64(coord[1])
            y = Int64(coord[2])
            keepout = collect(CartesianIndices((x-m.delta:x+m.delta,y-m.delta:y+m.delta)))
            keepout_acts = Set([MEAction(coords=coord) for coord in keepout])
            setdiff!(action_set, keepout_acts)
        end
        return collect(action_set)
    end
    return MEAction[]
end

function POMDPModelTools.obs_weight(m::MineralExplorationPOMDP, s::MEState,
                    a::MEAction, sp::MEState, o::MEObservation)
    w = 0.0
    if a.type != :drill
        w = o.ore_quality == nothing ? 1.0 : 0.0
    else
        mainbody_cov = [s.var 0.0; 0.0 s.var]
        mainbody_dist = MvNormal(m.mainbody_loc, mainbody_cov)
        o_mainbody = s.mainbody_map[a.coords[1], a.coords[2], 1]

        # mainbody_max = 1.0/(2*π*s.var)
        o_gp = (o.ore_quality - o_mainbody)/m.gp_weight
        # if s.bore_coords isa Nothing || size(s.bore_coords)[2] == 0
        mu = m.gp_mean
        sigma = sqrt(m.variogram[1])
        point_dist = Normal(mu, sigma)
        w = pdf(point_dist, o_gp)
    end
    return w
end
