# Chunk streaming system: dynamic load/unload of terrain chunks around the player
#
# Follows the AsyncAssetLoader channel pattern for background generation.
# Pure functions in worker threads, main thread handles GPU upload/destroy.

"""
    ChunkState

Lifecycle state of a streaming chunk.
"""
@enum ChunkState begin
    CHUNK_UNLOADED
    CHUNK_GENERATING
    CHUNK_GENERATED
    CHUNK_UPLOADED
    CHUNK_UNLOADING
end

"""
    StreamingChunkData

CPU-side data for a generated chunk (returned from background worker).
"""
struct StreamingChunkData
    coord::ChunkCoord
    terrain_chunk::TerrainChunk
    heightmap_patch::Matrix{Float32}    # Local heightmap for this chunk
    normal_patch::Matrix{Vec3f}         # Local normals
    biome_ids::Union{Matrix{Int}, Nothing}
    splatmap::Union{Matrix{NTuple{4, Float32}}, Nothing}
end

"""
    StreamingChunk

Runtime state for a single streaming chunk.
"""
mutable struct StreamingChunk
    coord::ChunkCoord
    state::ChunkState
    data::Union{StreamingChunkData, Nothing}
    last_access_frame::Int
end

"""
    ChunkStreamingSystem

Manages dynamic loading/unloading of terrain chunks around the player.
Generation is dispatched per-request to the engine-wide
[`EEVDFScheduler`](@ref) at weight `W_CHUNK_GEN` (background priority).
Completed `StreamingChunkData` is pushed onto `result_channel` and drained
on the main thread by `update_chunk_streaming!`.
"""
mutable struct ChunkStreamingSystem
    config::StreamingConfig
    world_config::WorldGeneratorConfig
    num_lod_levels::Int
    active_chunks::Dict{ChunkCoord, StreamingChunk}
    generation_queue::Vector{ChunkCoord}
    upload_queue::Vector{ChunkCoord}
    unload_queue::Vector{ChunkCoord}
    center_chunk::ChunkCoord
    frame_counter::Int
    # Result channel — main thread drains this each frame.
    result_channel::Channel{StreamingChunkData}
    # In-flight generation task handles; used by shutdown to wait gracefully.
    inflight::Vector{TaskHandle}
    running::Bool
    # Cache for recently unloaded chunks
    chunk_cache::ChunkCache{StreamingChunkData}
end

"""
    create_chunk_streaming(config::StreamingConfig, world_config::WorldGeneratorConfig;
                           num_lod_levels, num_workers, cache_size) -> ChunkStreamingSystem

Create a chunk streaming system. `num_workers` is accepted for backwards
compatibility but is ignored — generation now uses the engine-wide
[`EEVDFScheduler`](@ref) and parallelism is controlled globally via
`Threads.nthreads()`.
"""
function create_chunk_streaming(config::StreamingConfig,
                                 world_config::WorldGeneratorConfig;
                                 num_lod_levels::Int = 3,
                                 num_workers::Int = 2,
                                 cache_size::Int = 256)::ChunkStreamingSystem
    res_ch = Channel{StreamingChunkData}(64)

    system = ChunkStreamingSystem(
        config, world_config, num_lod_levels,
        Dict{ChunkCoord, StreamingChunk}(),
        ChunkCoord[], ChunkCoord[], ChunkCoord[],
        (0, 0), 0,
        res_ch,
        TaskHandle[],
        true,
        ChunkCache{StreamingChunkData}(max_entries=cache_size)
    )

    return system
end

"""
    _generate_chunk_data(coord, system) -> nothing

One-shot chunk generation invoked by the EEVDF scheduler. All functions
called here are pure (no global state access). On success the resulting
`StreamingChunkData` is pushed onto `system.result_channel`. Errors are
logged and swallowed so a single bad chunk cannot poison the worker pool.
The body bails early if the system has been shut down.
"""
function _generate_chunk_data(coord::ChunkCoord, system::ChunkStreamingSystem)
    system.running || return nothing
    config = system.config
    world_config = system.world_config
    num_lod_levels = system.num_lod_levels
    res_ch = system.result_channel
    chunk_size = config.chunk_resolution
    chunk_world = config.chunk_world_size

    try
        cx, cz = coord

        # World-space origin for this chunk
        origin_x = Float32(cx) * chunk_world
        origin_z = Float32(cz) * chunk_world

        # Generate heightmap patch for this chunk (with 1-cell overlap for normals)
        res = chunk_size - 1
        overlap = 1
        patch_size = chunk_size + 2 * overlap
        hm_patch = Matrix{Float32}(undef, patch_size, patch_size)

        terrain_seed = derive_seed(world_config.seed, "terrain", cx, cz)
        cell_size = chunk_world / Float32(res)

        for iz in 1:patch_size, ix in 1:patch_size
            # World position including overlap
            wx = origin_x + Float32(ix - 1 - overlap) * cell_size
            wz = origin_z + Float32(iz - 1 - overlap) * cell_size

            n = simplex_fbm_2d(Float64(wx), Float64(wz);
                               octaves=world_config.base_octaves,
                               frequency=world_config.base_frequency,
                               persistence=world_config.base_persistence,
                               seed=derive_seed(world_config.seed, "heightmap"))
            hm_patch[ix, iz] = Float32(n * 0.5 + 0.5) * world_config.base_max_height
        end

        # Generate biome data for this chunk
        biome_ids = nothing
        splatmap = nothing
        if !isempty(world_config.biome_defs)
            temp_seed = derive_seed(world_config.seed, "temperature")
            moist_seed = derive_seed(world_config.seed, "moisture")

            local_biome_ids = Matrix{Int}(undef, chunk_size, chunk_size)
            local_splatmap = Matrix{NTuple{4, Float32}}(undef, chunk_size, chunk_size)

            biome_channel = Dict{BiomeType, Int}(
                BIOME_GRASSLAND => 1, BIOME_TEMPERATE_FOREST => 1, BIOME_SAVANNA => 1,
                BIOME_TROPICAL_FOREST => 1, BIOME_SWAMP => 1,
                BIOME_MOUNTAIN => 2, BIOME_BOREAL_FOREST => 2, BIOME_TUNDRA => 2,
                BIOME_OCEAN => 3, BIOME_BEACH => 3, BIOME_DESERT => 3,
                BIOME_SNOW => 4, BIOME_CUSTOM => 1
            )

            for iz in 1:chunk_size, ix in 1:chunk_size
                wx = origin_x + Float32(ix - 1) * cell_size
                wz = origin_z + Float32(iz - 1) * cell_size

                t = Float32(simplex_fbm_2d(Float64(wx), Float64(wz);
                                           octaves=world_config.temperature_octaves,
                                           frequency=world_config.temperature_frequency,
                                           seed=temp_seed) * 0.5 + 0.5)
                m = Float32(simplex_fbm_2d(Float64(wx), Float64(wz);
                                           octaves=world_config.moisture_octaves,
                                           frequency=world_config.moisture_frequency,
                                           seed=moist_seed) * 0.5 + 0.5)
                t = clamp(t, 0.0f0, 1.0f0)
                m = clamp(m, 0.0f0, 1.0f0)

                elev = world_config.base_max_height > 0 ?
                       hm_patch[ix + overlap, iz + overlap] / world_config.base_max_height : 0.5f0
                elev = clamp(elev, 0.0f0, 1.0f0)

                bid = classify_biome(t, m, elev, world_config.biome_defs)
                local_biome_ids[ix, iz] = bid

                # Modulate height by biome
                bd = world_config.biome_defs[bid]
                hm_patch[ix + overlap, iz + overlap] =
                    hm_patch[ix + overlap, iz + overlap] * bd.height_scale + bd.height_offset

                # Splatmap
                ch = get(biome_channel, bd.biome_type, 1)
                channels = (ch == 1 ? 1.0f0 : 0.0f0,
                            ch == 2 ? 1.0f0 : 0.0f0,
                            ch == 3 ? 1.0f0 : 0.0f0,
                            ch == 4 ? 1.0f0 : 0.0f0)
                local_splatmap[ix, iz] = channels
            end
            biome_ids = local_biome_ids
            splatmap = local_splatmap
        end

        # Apply erosion if enabled
        if world_config.erosion_enabled && world_config.erosion_params !== nothing
            erosion_seed = derive_seed(world_config.seed, "erosion", cx, cz)
            erode_heightmap!(hm_patch, world_config.erosion_params, erosion_seed)
        end

        # Extract the actual chunk heightmap (without overlap)
        hm = hm_patch[(1 + overlap):(chunk_size + overlap),
                      (1 + overlap):(chunk_size + overlap)]

        # Compute normals from the full patch (with overlap for seamless edges)
        full_normals = compute_terrain_normals(hm_patch, cell_size, cell_size)
        normals = full_normals[(1 + overlap):(chunk_size + overlap),
                              (1 + overlap):(chunk_size + overlap)]

        # Build LOD meshes
        lod_meshes = MeshComponent[]
        terrain_size = Vec2f(chunk_world, chunk_world)
        for lod in 0:(num_lod_levels - 1)
            mesh = _generate_streaming_chunk_mesh(hm, normals, chunk_size,
                                                  terrain_size, origin_x, origin_z, lod)
            push!(lod_meshes, mesh)
        end

        # Compute AABB
        min_h = Float32(Inf)
        max_h = Float32(-Inf)
        for iz in 1:chunk_size, ix in 1:chunk_size
            h = hm[ix, iz]
            min_h = min(min_h, h)
            max_h = max(max_h, h)
        end

        chunk = TerrainChunk(
            cx, cz,
            Vec3f(origin_x, 0.0f0, origin_z),
            lod_meshes, 1,
            Vec3f(origin_x, min_h, origin_z),
            Vec3f(origin_x + chunk_world, max_h, origin_z + chunk_world)
        )

        result = StreamingChunkData(coord, chunk, hm, normals, biome_ids, splatmap)
        # Bail out if shutdown happened mid-generation rather than blocking on a closed channel.
        system.running || return nothing
        try
            put!(res_ch, result)
        catch
        end
    catch e
        @error "Chunk generation failed" coord=coord exception=(e, catch_backtrace())
    end
    return nothing
end

"""
    _generate_streaming_chunk_mesh(hm, normals, chunk_size, terrain_size, origin_x, origin_z, lod_level)

Generate a mesh for a streaming chunk. Similar to generate_chunk_mesh but for local heightmap.
"""
function _generate_streaming_chunk_mesh(hm::Matrix{Float32}, normals::Matrix{Vec3f},
                                         chunk_size::Int, terrain_size::Vec2f,
                                         origin_x::Float32, origin_z::Float32,
                                         lod_level::Int)::MeshComponent
    rows, cols = size(hm)
    step = 1 << lod_level
    cell_size_x = terrain_size[1] / Float32(rows - 1)
    cell_size_z = terrain_size[2] / Float32(cols - 1)

    vertices = Point3f[]
    mesh_normals = Vec3f[]
    uvs = Vec2f[]
    indices = UInt32[]

    vert_ix = UInt32(0)
    ix_map = Dict{Tuple{Int,Int}, UInt32}()

    for iz in 1:step:rows
        for ix in 1:step:cols
            wx = origin_x + Float32(ix - 1) * cell_size_x
            wz = origin_z + Float32(iz - 1) * cell_size_z
            wy = hm[ix, iz]

            push!(vertices, Point3f(wx, wy, wz))
            push!(mesh_normals, normals[ix, iz])
            push!(uvs, Vec2f(Float32(ix - 1) / Float32(rows - 1),
                              Float32(iz - 1) / Float32(cols - 1)))
            ix_map[(ix, iz)] = vert_ix
            vert_ix += 1
        end
    end

    xs = collect(1:step:cols)
    zs = collect(1:step:rows)
    for j in 1:(length(zs) - 1)
        for i in 1:(length(xs) - 1)
            v00 = ix_map[(xs[i], zs[j])]
            v10 = ix_map[(xs[i+1], zs[j])]
            v01 = ix_map[(xs[i], zs[j+1])]
            v11 = ix_map[(xs[i+1], zs[j+1])]

            push!(indices, v00, v10, v01)
            push!(indices, v10, v11, v01)
        end
    end

    return MeshComponent(
        vertices=vertices,
        normals=mesh_normals,
        uvs=uvs,
        indices=indices
    )
end

"""
    _world_to_chunk_coord(pos::Vec3f, chunk_world_size::Float32) -> ChunkCoord

Convert a world-space position to a chunk coordinate.
"""
function _world_to_chunk_coord(pos::Vec3f, chunk_world_size::Float32)::ChunkCoord
    cx = floor(Int, pos[1] / chunk_world_size)
    cz = floor(Int, pos[3] / chunk_world_size)
    return (cx, cz)
end

"""
    _spiral_coords(radius::Int) -> Vector{ChunkCoord}

Generate chunk coordinates in a spiral pattern from center outward.
Closer chunks are processed first.
"""
function _spiral_coords(radius::Int)::Vector{ChunkCoord}
    coords = ChunkCoord[]
    for r in 0:radius
        if r == 0
            push!(coords, (0, 0))
        else
            # Top and bottom rows
            for dx in -r:r
                push!(coords, (dx, -r))
                push!(coords, (dx, r))
            end
            # Left and right columns (excluding corners)
            for dz in (-r + 1):(r - 1)
                push!(coords, (-r, dz))
                push!(coords, (r, dz))
            end
        end
    end
    # Sort by distance from center for priority
    sort!(coords, by=c -> c[1]^2 + c[2]^2)
    return coords
end

"""
    update_chunk_streaming!(system::ChunkStreamingSystem, player_pos::Vec3f)

Per-frame update: manage chunk loading/unloading based on player position.
Call from the terrain update system.
"""
function update_chunk_streaming!(system::ChunkStreamingSystem, player_pos::Vec3f)
    system.frame_counter += 1
    cache_advance_frame!(system.chunk_cache)

    config = system.config
    new_center = _world_to_chunk_coord(player_pos, config.chunk_world_size)

    # Determine which chunks should be loaded
    desired_coords = Set{ChunkCoord}()
    spiral = _spiral_coords(config.load_radius)
    for offset in spiral
        coord = (new_center[1] + offset[1], new_center[2] + offset[2])
        push!(desired_coords, coord)
    end

    # Enqueue chunks that need generation
    for coord in desired_coords
        if !haskey(system.active_chunks, coord)
            # Check cache first
            cached = cache_get(system.chunk_cache, coord)
            if cached !== nothing
                sc = StreamingChunk(coord, CHUNK_GENERATED, cached, system.frame_counter)
                system.active_chunks[coord] = sc
                push!(system.upload_queue, coord)
            else
                # Need to generate — submit one task to the engine-wide
                # EEVDF scheduler at background priority (W_CHUNK_GEN).
                sc = StreamingChunk(coord, CHUNK_GENERATING, nothing, system.frame_counter)
                system.active_chunks[coord] = sc
                if system.running
                    let coord=coord, system=system
                        handle = submit_task!(get_scheduler(),
                            () -> _generate_chunk_data(coord, system);
                            weight=W_CHUNK_GEN, slice=0.05)
                        push!(system.inflight, handle)
                    end
                end
            end
        else
            system.active_chunks[coord].last_access_frame = system.frame_counter
        end
    end

    # Poll completed generations (budget limited)
    loads_this_frame = 0
    while isready(system.result_channel) && loads_this_frame < config.max_loads_per_frame
        result = take!(system.result_channel)
        sc = get(system.active_chunks, result.coord, nothing)
        if sc !== nothing && sc.state == CHUNK_GENERATING
            sc.data = result
            sc.state = CHUNK_GENERATED
            push!(system.upload_queue, result.coord)
            loads_this_frame += 1
        end
    end

    # Schedule unloads for chunks beyond unload_radius
    unload_radius_sq = config.unload_radius^2
    coords_to_unload = ChunkCoord[]
    for (coord, sc) in system.active_chunks
        dx = coord[1] - new_center[1]
        dz = coord[2] - new_center[2]
        if dx * dx + dz * dz > unload_radius_sq
            push!(coords_to_unload, coord)
        end
    end

    for coord in coords_to_unload
        sc = system.active_chunks[coord]
        if sc.data !== nothing
            cache_put!(system.chunk_cache, coord, sc.data)
        end
        sc.state = CHUNK_UNLOADING
        push!(system.unload_queue, coord)
    end

    # Process unload queue
    for coord in system.unload_queue
        delete!(system.active_chunks, coord)
        # GPU cleanup handled by backend terrain renderer (checks for missing chunks)
    end
    empty!(system.unload_queue)

    system.center_chunk = new_center
end

"""
    get_streaming_chunks(system::ChunkStreamingSystem) -> Dict{ChunkCoord, StreamingChunk}

Get all active streaming chunks.
"""
function get_streaming_chunks(system::ChunkStreamingSystem)
    return system.active_chunks
end

"""
    get_uploaded_streaming_chunks(system::ChunkStreamingSystem) -> Vector{StreamingChunk}

Get all chunks that are ready for rendering (generated or uploaded).
"""
function get_uploaded_streaming_chunks(system::ChunkStreamingSystem)::Vector{StreamingChunk}
    result = StreamingChunk[]
    for (_, sc) in system.active_chunks
        if sc.state == CHUNK_GENERATED || sc.state == CHUNK_UPLOADED
            push!(result, sc)
        end
    end
    return result
end

"""
    get_streaming_upload_queue!(system::ChunkStreamingSystem) -> Vector{ChunkCoord}

Drain and return the upload queue (chunks that need GPU resources created).
Respects the per-frame budget.
"""
function get_streaming_upload_queue!(system::ChunkStreamingSystem)::Vector{ChunkCoord}
    n = min(length(system.upload_queue), system.config.max_uploads_per_frame)
    result = system.upload_queue[1:n]
    deleteat!(system.upload_queue, 1:n)
    return result
end

"""
    mark_chunk_uploaded!(system::ChunkStreamingSystem, coord::ChunkCoord)

Mark a chunk as having its GPU resources uploaded.
"""
function mark_chunk_uploaded!(system::ChunkStreamingSystem, coord::ChunkCoord)
    sc = get(system.active_chunks, coord, nothing)
    if sc !== nothing
        sc.state = CHUNK_UPLOADED
    end
end

"""
    heightmap_get_height_streaming(system::ChunkStreamingSystem,
                                   world_x::Float64, world_z::Float64) -> Float64

Query terrain height at a world position using streaming chunk data.
Returns 0.0 (sea level) if the chunk is not loaded.
"""
function heightmap_get_height_streaming(system::ChunkStreamingSystem,
                                        world_x::Float64, world_z::Float64)::Float64
    chunk_size = Float64(system.config.chunk_world_size)
    coord = (floor(Int, world_x / chunk_size), floor(Int, world_z / chunk_size))

    sc = get(system.active_chunks, coord, nothing)
    if sc === nothing || sc.data === nothing
        return 0.0
    end

    hm = sc.data.heightmap_patch
    rows, cols = size(hm)
    cell_size = chunk_size / Float64(rows - 1)

    # Local position within chunk
    local_x = world_x - Float64(coord[1]) * chunk_size
    local_z = world_z - Float64(coord[2]) * chunk_size

    fx = local_x / cell_size
    fz = local_z / cell_size

    ix = floor(Int, fx)
    iz = floor(Int, fz)
    tx = fx - ix
    tz = fz - iz

    ix = clamp(ix + 1, 1, rows - 1)
    iz = clamp(iz + 1, 1, cols - 1)
    ix1 = min(ix + 1, rows)
    iz1 = min(iz + 1, cols)

    h00 = Float64(hm[ix, iz])
    h10 = Float64(hm[ix1, iz])
    h01 = Float64(hm[ix, iz1])
    h11 = Float64(hm[ix1, iz1])

    return h00 * (1.0 - tx) * (1.0 - tz) +
           h10 * tx * (1.0 - tz) +
           h01 * (1.0 - tx) * tz +
           h11 * tx * tz
end

"""
    shutdown_chunk_streaming!(system::ChunkStreamingSystem)

Shutdown the streaming system: prevent new chunk submissions, wait for
in-flight tasks on the engine scheduler to finish, then close the result
channel and clear caches.
"""
function shutdown_chunk_streaming!(system::ChunkStreamingSystem)
    system.running = false
    for handle in system.inflight
        try
            wait(handle.task.done)
        catch
        end
    end
    empty!(system.inflight)
    try
        close(system.result_channel)
    catch
    end
    empty!(system.active_chunks)
    empty!(system.generation_queue)
    empty!(system.upload_queue)
    empty!(system.unload_queue)
    cache_clear!(system.chunk_cache)
end

# Global streaming system registry (entity_id → ChunkStreamingSystem)
const _STREAMING_SYSTEMS = Dict{EntityID, ChunkStreamingSystem}()

"""
    reset_chunk_streaming!()

Shutdown and remove all streaming systems. Called from reset_engine_state!().
"""
function reset_chunk_streaming!()
    for (_, sys) in _STREAMING_SYSTEMS
        shutdown_chunk_streaming!(sys)
    end
    empty!(_STREAMING_SYSTEMS)
end
