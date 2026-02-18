# Backend-agnostic frame preparation
# Extracts camera, lights, and entity classification from a scene.

"""
    FrameLightData

Structured light data collected from the ECS for any backend to upload.
"""
struct FrameLightData
    # Point lights
    point_positions::Vector{Vec3f}
    point_colors::Vector{RGB{Float32}}
    point_intensities::Vector{Float32}
    point_ranges::Vector{Float32}

    # Directional lights
    dir_directions::Vector{Vec3f}
    dir_colors::Vector{RGB{Float32}}
    dir_intensities::Vector{Float32}

    # IBL
    has_ibl::Bool
    ibl_path::String
    ibl_intensity::Float32
end

"""
    EntityRenderData

Pre-computed rendering data for a single entity.
"""
struct EntityRenderData
    entity_id::EntityID
    mesh::MeshComponent
    model::Mat4f
    normal_matrix::SMatrix{3, 3, Float32, 9}
    lod_crossfade::Float32                         # 1.0 = no crossfade, <1.0 = transitioning
    lod_next_mesh::Union{MeshComponent, Nothing}   # Second mesh during LOD crossfade
end

"""
    TransparentEntityData

Rendering data for a transparent entity, with camera distance for sorting.
"""
struct TransparentEntityData
    entity_id::EntityID
    mesh::MeshComponent
    model::Mat4f
    normal_matrix::SMatrix{3, 3, Float32, 9}
    dist_sq::Float32
end

"""
    FrameData

All backend-agnostic data needed to render a frame.
Computed once by `prepare_frame`, consumed by any backend's `render_frame!`.
"""
struct FrameData
    # Camera
    camera_id::EntityID
    view::Mat4f
    proj::Mat4f
    cam_pos::Vec3f

    # Frustum
    frustum::Frustum

    # Classified entities
    opaque_entities::Vector{EntityRenderData}
    transparent_entities::Vector{TransparentEntityData}

    # Lights
    lights::FrameLightData

    # Directional light direction for shadow mapping (first dir light, or nothing)
    primary_light_dir::Union{Vec3f, Nothing}
end

"""
    collect_lights() -> FrameLightData

Query all light components from the ECS and return structured data.
"""
function collect_lights()
    # Point lights
    point_entities = entities_with_component(PointLightComponent)
    num_point = min(length(point_entities), 16)
    point_positions = Vec3f[]
    point_colors = RGB{Float32}[]
    point_intensities = Float32[]
    point_ranges = Float32[]

    for i in 1:num_point
        eid = point_entities[i]
        light = get_component(eid, PointLightComponent)
        world = get_world_transform(eid)
        pos = Vec3f(Float32(world[1, 4]), Float32(world[2, 4]), Float32(world[3, 4]))
        push!(point_positions, pos)
        push!(point_colors, light.color)
        push!(point_intensities, light.intensity)
        push!(point_ranges, light.range)
    end

    # Directional lights
    dir_entities = entities_with_component(DirectionalLightComponent)
    num_dir = min(length(dir_entities), 4)
    dir_directions = Vec3f[]
    dir_colors = RGB{Float32}[]
    dir_intensities = Float32[]

    for i in 1:num_dir
        eid = dir_entities[i]
        light = get_component(eid, DirectionalLightComponent)
        push!(dir_directions, light.direction)
        push!(dir_colors, light.color)
        push!(dir_intensities, light.intensity)
    end

    # IBL
    has_ibl = false
    ibl_path = ""
    ibl_intensity = 1.0f0
    ibl_entities = entities_with_component(IBLComponent)
    if !isempty(ibl_entities)
        ibl_comp = get_component(ibl_entities[1], IBLComponent)
        if ibl_comp.enabled
            has_ibl = true
            ibl_path = ibl_comp.environment_path
            ibl_intensity = ibl_comp.intensity
        end
    end

    return FrameLightData(
        point_positions, point_colors, point_intensities, point_ranges,
        dir_directions, dir_colors, dir_intensities,
        has_ibl, ibl_path, ibl_intensity
    )
end

"""
    prepare_frame(scene::Scene, bounds_cache::Dict{EntityID, BoundingSphere}) -> Union{FrameData, Nothing}

Perform backend-agnostic frame setup: find camera, extract frustum, classify entities
(opaque vs transparent), collect lights. Returns `nothing` if no camera is found.
"""
function prepare_frame(scene::Scene, bounds_cache::Dict{EntityID, BoundingSphere})
    # Find active camera
    camera_id = find_active_camera()
    if camera_id === nothing
        return nothing
    end

    view = get_view_matrix(camera_id)
    proj = get_projection_matrix(camera_id)
    cam_world = get_world_transform(camera_id)
    cam_pos = Vec3f(Float32(cam_world[1, 4]), Float32(cam_world[2, 4]), Float32(cam_world[3, 4]))

    # Frustum culling setup
    vp = proj * view
    frustum = extract_frustum(vp)

    # Collect and classify entities
    opaque_entities = EntityRenderData[]
    transparent_entities = TransparentEntityData[]

    iterate_components(MeshComponent) do entity_id, mesh
        isempty(mesh.indices) && return

        # Model matrix
        world_transform = get_world_transform(entity_id)
        model = Mat4f(world_transform)

        # Frustum culling
        bs = get!(bounds_cache, entity_id) do
            bounding_sphere_from_mesh(mesh)
        end
        world_center, world_radius = transform_bounding_sphere(bs, model)
        if !is_sphere_in_frustum(frustum, world_center, world_radius)
            return  # culled
        end

        # LOD selection: swap mesh if entity has LODComponent
        render_mesh = mesh
        lod_crossfade = 1.0f0
        lod_next_mesh = nothing
        lod = get_component(entity_id, LODComponent)
        if lod !== nothing && !isempty(lod.levels)
            dx = world_center[1] - cam_pos[1]
            dy = world_center[2] - cam_pos[2]
            dz = world_center[3] - cam_pos[3]
            cam_distance = sqrt(dx*dx + dy*dy + dz*dz)
            selection = select_lod_level(lod, cam_distance, entity_id)
            render_mesh = selection.mesh
            lod_crossfade = selection.crossfade_alpha
            lod_next_mesh = selection.next_mesh
        end

        # Normal matrix
        model3 = SMatrix{3, 3, Float32, 9}(
            model[1,1], model[2,1], model[3,1],
            model[1,2], model[2,2], model[3,2],
            model[1,3], model[2,3], model[3,3]
        )
        normal_matrix = SMatrix{3, 3, Float32, 9}(transpose(inv(model3)))

        # Classify opaque vs transparent
        material = get_component(entity_id, MaterialComponent)
        is_transparent = material !== nothing && (material.opacity < 1.0f0 || material.alpha_cutoff > 0.0f0)

        if is_transparent
            dx = world_center[1] - cam_pos[1]
            dy = world_center[2] - cam_pos[2]
            dz = world_center[3] - cam_pos[3]
            dist_sq = dx*dx + dy*dy + dz*dz
            push!(transparent_entities, TransparentEntityData(entity_id, render_mesh, model, normal_matrix, dist_sq))
        else
            push!(opaque_entities, EntityRenderData(entity_id, render_mesh, model, normal_matrix, lod_crossfade, lod_next_mesh))
        end
    end

    # Collect lights
    lights = collect_lights()

    # Primary directional light direction
    primary_light_dir = isempty(lights.dir_directions) ? nothing : lights.dir_directions[1]

    return FrameData(
        camera_id, view, proj, cam_pos,
        frustum,
        opaque_entities, transparent_entities,
        lights,
        primary_light_dir
    )
end

"""
    prepare_frame_parallel(scene::Scene, bounds_cache::Dict{EntityID, BoundingSphere}) -> Union{FrameData, Nothing}

Threaded variant of `prepare_frame`. Pre-computes world transforms on the main
thread, then parallelises frustum culling, LOD selection, and entity classification
across worker threads using per-thread local arrays.
"""
function prepare_frame_parallel(scene::Scene, bounds_cache::Dict{EntityID, BoundingSphere})
    # Find active camera (main thread)
    camera_id = find_active_camera()
    camera_id === nothing && return nothing

    view = get_view_matrix(camera_id)
    proj = get_projection_matrix(camera_id)
    cam_world = get_world_transform(camera_id)
    cam_pos = Vec3f(Float32(cam_world[1, 4]), Float32(cam_world[2, 4]), Float32(cam_world[3, 4]))

    vp = proj * view
    frustum = extract_frustum(vp)

    # Step 1: Collect mesh entities and pre-compute world transforms (main thread)
    # This writes _WORLD_TRANSFORM_CACHE safely since still single-threaded.
    mesh_entities = entities_with_component(MeshComponent)
    n = length(mesh_entities)

    world_transforms = Vector{Mat4f}(undef, n)
    meshes = Vector{MeshComponent}(undef, n)
    bspheres = Vector{Tuple{Vec3f, Float32}}(undef, n)
    valid = Vector{Bool}(undef, n)

    for i in 1:n
        eid = mesh_entities[i]
        mesh = get_component(eid, MeshComponent)
        if mesh === nothing || isempty(mesh.indices)
            valid[i] = false
            continue
        end
        meshes[i] = mesh
        wt = get_world_transform(eid)
        model = Mat4f(wt)
        world_transforms[i] = model

        bs = get!(bounds_cache, eid) do
            bounding_sphere_from_mesh(mesh)
        end
        world_center, world_radius = transform_bounding_sphere(bs, model)
        bspheres[i] = (world_center, world_radius)
        valid[i] = true
    end

    # Step 2: Parallel — frustum cull + LOD + classify
    nt = Threads.nthreads()
    local_opaque = [EntityRenderData[] for _ in 1:nt]
    local_transparent = [TransparentEntityData[] for _ in 1:nt]

    Threads.@threads for i in 1:n
        valid[i] || continue
        tid = Threads.threadid()
        eid = mesh_entities[i]
        model = world_transforms[i]
        world_center, world_radius = bspheres[i]

        # Frustum culling (pure function)
        if !is_sphere_in_frustum(frustum, world_center, world_radius)
            continue  # culled
        end

        # LOD selection
        render_mesh = meshes[i]
        lod_crossfade = 1.0f0
        lod_next_mesh = nothing
        lod = get_component(eid, LODComponent)
        if lod !== nothing && !isempty(lod.levels)
            dx = world_center[1] - cam_pos[1]
            dy = world_center[2] - cam_pos[2]
            dz = world_center[3] - cam_pos[3]
            cam_distance = sqrt(dx*dx + dy*dy + dz*dz)
            selection = select_lod_level(lod, cam_distance, eid)
            render_mesh = selection.mesh
            lod_crossfade = selection.crossfade_alpha
            lod_next_mesh = selection.next_mesh
        end

        # Normal matrix
        model3 = SMatrix{3, 3, Float32, 9}(
            model[1,1], model[2,1], model[3,1],
            model[1,2], model[2,2], model[3,2],
            model[1,3], model[2,3], model[3,3]
        )
        normal_matrix = SMatrix{3, 3, Float32, 9}(transpose(inv(model3)))

        # Classify opaque vs transparent
        material = get_component(eid, MaterialComponent)
        is_transparent = material !== nothing && (material.opacity < 1.0f0 || material.alpha_cutoff > 0.0f0)

        if is_transparent
            dx = world_center[1] - cam_pos[1]
            dy = world_center[2] - cam_pos[2]
            dz = world_center[3] - cam_pos[3]
            dist_sq = dx*dx + dy*dy + dz*dz
            push!(local_transparent[tid], TransparentEntityData(eid, render_mesh, model, normal_matrix, dist_sq))
        else
            push!(local_opaque[tid], EntityRenderData(eid, render_mesh, model, normal_matrix, lod_crossfade, lod_next_mesh))
        end
    end

    # Step 3: Merge per-thread results
    opaque_entities = reduce(vcat, local_opaque; init=EntityRenderData[])
    transparent_entities = reduce(vcat, local_transparent; init=TransparentEntityData[])

    # Collect lights (main thread)
    lights = collect_lights()
    primary_light_dir = isempty(lights.dir_directions) ? nothing : lights.dir_directions[1]

    return FrameData(
        camera_id, view, proj, cam_pos,
        frustum,
        opaque_entities, transparent_entities,
        lights,
        primary_light_dir
    )
end
