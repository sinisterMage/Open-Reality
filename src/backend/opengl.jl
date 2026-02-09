# OpenGL backend implementation

using ModernGL

"""
    OpenGLBackend <: AbstractBackend

OpenGL rendering backend with PBR pipeline support, shadow mapping,
frustum culling, transparency, and post-processing.
"""
mutable struct OpenGLBackend <: AbstractBackend
    initialized::Bool
    window::Union{Window, Nothing}
    input::InputState
    shader::Union{ShaderProgram, Nothing}
    gpu_cache::GPUResourceCache
    texture_cache::TextureCache
    shadow_map::Union{ShadowMap, Nothing}
    bounds_cache::Dict{EntityID, BoundingSphere}
    post_process::Union{PostProcessPipeline, Nothing}

    OpenGLBackend(; post_process_config::PostProcessConfig = PostProcessConfig()) = new(
        false, nothing, InputState(), nothing, GPUResourceCache(), TextureCache(),
        nothing, Dict{EntityID, BoundingSphere}(),
        PostProcessPipeline(config=post_process_config)
    )
end

function initialize!(backend::OpenGLBackend;
                     width::Int=1280, height::Int=720, title::String="OpenReality")
    backend.window = Window(width=width, height=height, title=title)
    create_window!(backend.window)

    setup_input_callbacks!(backend.window, backend.input)
    setup_resize_callback!(backend.window, (w, h) -> begin
        glViewport(0, 0, w, h)
        if backend.post_process !== nothing
            resize_post_process!(backend.post_process, w, h)
        end
    end)

    # OpenGL state
    glViewport(0, 0, width, height)
    glEnable(GL_DEPTH_TEST)
    glEnable(GL_CULL_FACE)
    glCullFace(GL_BACK)
    glEnable(GL_MULTISAMPLE)
    glClearColor(0.1f0, 0.1f0, 0.1f0, 1.0f0)

    # Compile PBR shader
    backend.shader = create_shader_program(PBR_VERTEX_SHADER, PBR_FRAGMENT_SHADER)

    # Shadow map
    backend.shadow_map = ShadowMap()
    create_shadow_map!(backend.shadow_map)

    # Post-processing pipeline
    if backend.post_process !== nothing
        create_post_process_pipeline!(backend.post_process, width, height)
    end

    backend.initialized = true
    @info "OpenGL backend initialized" width height
    return nothing
end

function shutdown!(backend::OpenGLBackend)
    if backend.shader !== nothing
        destroy_shader_program!(backend.shader)
        backend.shader = nothing
    end
    destroy_all!(backend.gpu_cache)
    destroy_all_textures!(backend.texture_cache)
    if backend.shadow_map !== nothing
        destroy_shadow_map!(backend.shadow_map)
        backend.shadow_map = nothing
    end
    if backend.post_process !== nothing
        destroy_post_process_pipeline!(backend.post_process)
        backend.post_process = nothing
    end
    if backend.window !== nothing
        destroy_window!(backend.window)
        backend.window = nothing
    end
    backend.initialized = false
    return nothing
end

"""
    bind_material_textures!(sp, material, texture_cache)

Bind texture maps for a material, setting sampler uniforms and has-flags.
"""
function bind_material_textures!(sp::ShaderProgram, material::MaterialComponent, texture_cache::TextureCache)
    texture_unit = Int32(0)

    # Albedo map
    if material.albedo_map !== nothing
        gpu_tex = load_texture(texture_cache, material.albedo_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_AlbedoMap", texture_unit)
        set_uniform!(sp, "u_HasAlbedoMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasAlbedoMap", Int32(0))
    end

    # Normal map
    if material.normal_map !== nothing
        gpu_tex = load_texture(texture_cache, material.normal_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_NormalMap", texture_unit)
        set_uniform!(sp, "u_HasNormalMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasNormalMap", Int32(0))
    end

    # Metallic-roughness map
    if material.metallic_roughness_map !== nothing
        gpu_tex = load_texture(texture_cache, material.metallic_roughness_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_MetallicRoughnessMap", texture_unit)
        set_uniform!(sp, "u_HasMetallicRoughnessMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasMetallicRoughnessMap", Int32(0))
    end

    # AO map
    if material.ao_map !== nothing
        gpu_tex = load_texture(texture_cache, material.ao_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_AOMap", texture_unit)
        set_uniform!(sp, "u_HasAOMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasAOMap", Int32(0))
    end

    # Emissive map
    if material.emissive_map !== nothing
        gpu_tex = load_texture(texture_cache, material.emissive_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_EmissiveMap", texture_unit)
        set_uniform!(sp, "u_HasEmissiveMap", Int32(1))
    else
        set_uniform!(sp, "u_HasEmissiveMap", Int32(0))
    end

    set_uniform!(sp, "u_EmissiveFactor", material.emissive_factor)

    return nothing
end

# ---- Per-entity rendering helper ----

"""
    _render_entity!(backend, sp, entity_id, mesh, model, normal_matrix)

Render a single entity with full material setup.
"""
function _render_entity!(backend::OpenGLBackend, sp::ShaderProgram,
                         entity_id::EntityID, mesh::MeshComponent,
                         model::Mat4f, normal_matrix::SMatrix{3,3,Float32,9})
    material = get_component(entity_id, MaterialComponent)
    if material === nothing
        material = MaterialComponent()
    end

    # Per-object uniforms
    set_uniform!(sp, "u_Model", model)
    set_uniform!(sp, "u_NormalMatrix", normal_matrix)
    set_uniform!(sp, "u_Albedo", material.color)
    set_uniform!(sp, "u_Metallic", material.metallic)
    set_uniform!(sp, "u_Roughness", material.roughness)
    set_uniform!(sp, "u_AO", 1.0f0)
    set_uniform!(sp, "u_Opacity", material.opacity)
    set_uniform!(sp, "u_AlphaCutoff", material.alpha_cutoff)

    # Bind textures
    bind_material_textures!(sp, material, backend.texture_cache)

    # Get or upload GPU mesh
    gpu_mesh = get_or_upload_mesh!(backend.gpu_cache, entity_id, mesh)

    # Draw
    glBindVertexArray(gpu_mesh.vao)
    glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
    glBindVertexArray(GLuint(0))
end

# ---- Main render frame ----

function render_frame!(backend::OpenGLBackend, scene::Scene)
    if !backend.initialized
        error("OpenGL backend not initialized")
    end

    # Find active camera
    camera_id = find_active_camera()
    if camera_id === nothing
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
        swap_buffers!(backend.window)
        return nothing
    end

    view = get_view_matrix(camera_id)
    proj = get_projection_matrix(camera_id)
    cam_world = get_world_transform(camera_id)
    cam_pos = Vec3f(Float32(cam_world[1, 4]), Float32(cam_world[2, 4]), Float32(cam_world[3, 4]))

    # ---- Shadow pass ----
    light_space = Mat4f(I)
    has_shadows = false
    if backend.shadow_map !== nothing
        dir_entities = entities_with_component(DirectionalLightComponent)
        if !isempty(dir_entities)
            light = get_component(dir_entities[1], DirectionalLightComponent)
            light_dir = light.direction
            light_space = compute_light_space_matrix(cam_pos, light_dir)
            render_shadow_pass!(backend.shadow_map, light_space, backend.gpu_cache)
            has_shadows = true
        end
    end

    # ---- Begin post-processing (render to HDR FBO) ----
    if backend.post_process !== nothing
        begin_post_process!(backend.post_process)
    end

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

    sp = backend.shader
    glUseProgram(sp.id)

    # Camera uniforms
    set_uniform!(sp, "u_View", view)
    set_uniform!(sp, "u_Projection", proj)
    set_uniform!(sp, "u_CameraPos", cam_pos)
    set_uniform!(sp, "u_LightSpaceMatrix", light_space)

    # Shadow map binding (texture unit 6)
    if has_shadows && backend.shadow_map !== nothing
        glActiveTexture(GL_TEXTURE6)
        glBindTexture(GL_TEXTURE_2D, backend.shadow_map.depth_texture)
        set_uniform!(sp, "u_ShadowMap", Int32(6))
        set_uniform!(sp, "u_HasShadows", Int32(1))
    else
        set_uniform!(sp, "u_HasShadows", Int32(0))
    end

    # Light uniforms
    upload_lights!(sp)

    # Frustum culling setup
    vp = proj * view
    frustum = extract_frustum(vp)

    # ---- Collect and classify entities ----
    opaque_entities = Tuple{EntityID, MeshComponent, Mat4f, SMatrix{3,3,Float32,9}}[]
    transparent_entities = Tuple{EntityID, MeshComponent, Mat4f, SMatrix{3,3,Float32,9}, Float32}[]

    iterate_components(MeshComponent) do entity_id, mesh
        isempty(mesh.indices) && return

        # Model matrix
        world_transform = get_world_transform(entity_id)
        model = Mat4f(world_transform)

        # Frustum culling
        bs = get!(backend.bounds_cache, entity_id) do
            bounding_sphere_from_mesh(mesh)
        end
        world_center, world_radius = transform_bounding_sphere(bs, model)
        if !is_sphere_in_frustum(frustum, world_center, world_radius)
            return  # culled
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
            # Distance to camera for back-to-front sorting
            dx = world_center[1] - cam_pos[1]
            dy = world_center[2] - cam_pos[2]
            dz = world_center[3] - cam_pos[3]
            dist_sq = dx*dx + dy*dy + dz*dz
            push!(transparent_entities, (entity_id, mesh, model, normal_matrix, dist_sq))
        else
            push!(opaque_entities, (entity_id, mesh, model, normal_matrix))
        end
    end

    # ---- Opaque pass ----
    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)
    glEnable(GL_CULL_FACE)

    for (entity_id, mesh, model, normal_matrix) in opaque_entities
        _render_entity!(backend, sp, entity_id, mesh, model, normal_matrix)
    end

    # ---- Transparent pass (back-to-front) ----
    if !isempty(transparent_entities)
        sort!(transparent_entities, by=x -> -x[5])  # farthest first

        glDepthMask(GL_FALSE)
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        glDisable(GL_CULL_FACE)

        for (entity_id, mesh, model, normal_matrix, _) in transparent_entities
            _render_entity!(backend, sp, entity_id, mesh, model, normal_matrix)
        end

        # Restore state
        glDepthMask(GL_TRUE)
        glDisable(GL_BLEND)
        glEnable(GL_CULL_FACE)
    end

    # ---- End post-processing ----
    if backend.post_process !== nothing
        viewport = Int32[0, 0, 0, 0]
        glGetIntegerv(GL_VIEWPORT, viewport)
        end_post_process!(backend.post_process, Int(viewport[3]), Int(viewport[4]))
    end

    swap_buffers!(backend.window)
    return nothing
end
