# OpenGL backend implementation

using ModernGL

"""
    OpenGLBackend <: AbstractBackend

OpenGL rendering backend with deferred rendering support, PBR pipeline,
shadow mapping, frustum culling, transparency, and post-processing.
"""
mutable struct OpenGLBackend <: AbstractBackend
    initialized::Bool
    window::Union{Window, Nothing}
    input::InputState
    shader::Union{ShaderProgram, Nothing}  # Forward rendering shader (for backward compatibility)
    deferred_pipeline::Union{DeferredPipeline, Nothing}
    use_deferred::Bool  # Use deferred rendering (true) or forward rendering (false)
    gpu_cache::GPUResourceCache
    texture_cache::TextureCache
    shadow_map::Union{ShadowMap, Nothing}
    csm::Union{CascadedShadowMap, Nothing}  # Cascaded shadow maps (preferred)
    bounds_cache::Dict{EntityID, BoundingSphere}
    post_process::Union{PostProcessPipeline, Nothing}

    OpenGLBackend(; post_process_config::PostProcessConfig = PostProcessConfig(), use_deferred::Bool = true) = new(
        false, nothing, InputState(), nothing, nothing, use_deferred,
        GPUResourceCache(), TextureCache(),
        nothing, nothing, Dict{EntityID, BoundingSphere}(),
        PostProcessPipeline(config=post_process_config)
    )
end

function initialize!(backend::OpenGLBackend;
                     width::Int=1280, height::Int=720, title::String="OpenReality")
    backend.window = Window(width=width, height=height, title=title)
    create_window!(backend.window)

    setup_input_callbacks!(backend.window, backend.input)
    setup_resize_callback!(backend.window, (w, h) -> begin
        # Convert Int32 from GLFW to Int
        width, height = Int(w), Int(h)
        glViewport(0, 0, width, height)
        if backend.deferred_pipeline !== nothing
            resize_deferred_pipeline!(backend.deferred_pipeline, width, height)
        end
        if backend.post_process !== nothing
            resize_post_process!(backend.post_process, width, height)
        end
    end)

    # OpenGL state
    glViewport(0, 0, width, height)
    glEnable(GL_DEPTH_TEST)
    glEnable(GL_CULL_FACE)
    glCullFace(GL_BACK)
    glEnable(GL_MULTISAMPLE)
    glClearColor(0.1f0, 0.1f0, 0.1f0, 1.0f0)

    # Initialize rendering pipeline
    if backend.use_deferred
        # Deferred rendering pipeline
        backend.deferred_pipeline = DeferredPipeline()
        create_deferred_pipeline!(backend.deferred_pipeline, width, height)
        @info "Created deferred pipeline" width height

        # Still need forward shader for transparent objects in deferred mode
        backend.shader = create_shader_program(PBR_VERTEX_SHADER, PBR_FRAGMENT_SHADER)

        @info "Using deferred rendering pipeline (hybrid with forward fallback)"
    else
        # Forward rendering (backward compatibility)
        backend.shader = create_shader_program(PBR_VERTEX_SHADER, PBR_FRAGMENT_SHADER)
        @info "Using forward rendering pipeline"
    end

    # Cascaded Shadow Maps (CSM) - better quality than single shadow map
    backend.csm = CascadedShadowMap(num_cascades=4, resolution=2048)
    # Create with camera near/far planes (will be updated per frame)
    create_csm!(backend.csm, 0.1f0, 150.0f0)

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
    if backend.deferred_pipeline !== nothing
        destroy_deferred_pipeline!(backend.deferred_pipeline)
        backend.deferred_pipeline = nothing
    end
    destroy_all!(backend.gpu_cache)
    destroy_all_textures!(backend.texture_cache)
    if backend.shadow_map !== nothing
        destroy_shadow_map!(backend.shadow_map)
        backend.shadow_map = nothing
    end
    if backend.csm !== nothing
        destroy_csm!(backend.csm)
        backend.csm = nothing
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

# ---- Deferred Rendering Helpers ----

"""
    render_gbuffer_pass!(backend, pipeline, opaque_entities, view, proj)

Render opaque entities to the G-Buffer.
"""
function render_gbuffer_pass!(backend::OpenGLBackend, pipeline::DeferredPipeline,
                              opaque_entities, view::Mat4f, proj::Mat4f)
    # Bind G-Buffer for writing
    bind_gbuffer_for_write!(pipeline.gbuffer)
    glViewport(0, 0, pipeline.gbuffer.width, pipeline.gbuffer.height)

    # Ensure correct OpenGL state for G-Buffer rendering
    glEnable(GL_DEPTH_TEST)
    glDepthMask(GL_TRUE)
    glDepthFunc(GL_LESS)
    glEnable(GL_CULL_FACE)
    glDisable(GL_BLEND)

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

    # Render each opaque entity
    for (entity_id, mesh, model, normal_matrix) in opaque_entities
        # Get material
        material = get_component(entity_id, MaterialComponent)
        if material === nothing
            continue
        end

        # Determine shader variant based on material
        variant_key = determine_shader_variant(material)
        sp = get_or_compile_variant!(pipeline.gbuffer_shader_library, variant_key)

        glUseProgram(sp.id)

        # Set uniforms
        set_uniform!(sp, "u_Model", model)
        set_uniform!(sp, "u_View", view)
        set_uniform!(sp, "u_Projection", proj)
        set_uniform!(sp, "u_NormalMatrix", normal_matrix)

        # Material uniforms
        set_uniform!(sp, "u_Albedo", material.color)
        set_uniform!(sp, "u_Metallic", material.metallic)
        set_uniform!(sp, "u_Roughness", material.roughness)
        set_uniform!(sp, "u_AO", 1.0f0)  # Default AO value (can be overridden by ao_map)
        set_uniform!(sp, "u_EmissiveFactor", material.emissive_factor)
        set_uniform!(sp, "u_Opacity", material.opacity)
        set_uniform!(sp, "u_AlphaCutoff", material.alpha_cutoff)

        # Bind material textures
        bind_material_textures!(sp, material, backend.texture_cache)

        # Draw mesh
        gpu_mesh = get_or_upload_mesh!(backend.gpu_cache, entity_id, mesh)
        glBindVertexArray(gpu_mesh.vao)
        glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
        glBindVertexArray(GLuint(0))
    end

    unbind_framebuffer!()
end

"""
    render_deferred_lighting_pass!(backend, pipeline, cam_pos, view, proj, light_space, has_shadows)

Execute deferred lighting pass (fullscreen quad).
"""
function render_deferred_lighting_pass!(backend::OpenGLBackend, pipeline::DeferredPipeline,
                                        cam_pos::Vec3f, view::Mat4f, proj::Mat4f,
                                        light_space::Mat4f, has_shadows::Bool)
    # Render to lighting accumulation framebuffer
    glBindFramebuffer(GL_FRAMEBUFFER, pipeline.lighting_fbo.fbo)
    glViewport(0, 0, pipeline.lighting_fbo.width, pipeline.lighting_fbo.height)

    # Fullscreen quad doesn't need depth test or writes
    glDisable(GL_DEPTH_TEST)
    glDepthMask(GL_FALSE)
    glDisable(GL_CULL_FACE)

    glClear(GL_COLOR_BUFFER_BIT)

    sp = pipeline.lighting_shader
    glUseProgram(sp.id)

    # Bind G-Buffer textures for reading (texture units 0-3)
    next_unit = bind_gbuffer_textures_for_read!(pipeline.gbuffer, 0)

    # Set G-Buffer sampler uniforms
    set_uniform!(sp, "gAlbedoMetallic", Int32(0))
    set_uniform!(sp, "gNormalRoughness", Int32(1))
    set_uniform!(sp, "gEmissiveAO", Int32(2))
    set_uniform!(sp, "gDepth", Int32(3))

    # Camera uniforms
    set_uniform!(sp, "u_CameraPos", cam_pos)
    vp = proj * view
    inv_vp = inv(vp)
    set_uniform!(sp, "u_InvViewProj", inv_vp)

    # Light uniforms
    upload_lights!(sp)

    # Cascaded Shadow Maps (CSM)
    if has_shadows && backend.csm !== nothing
        # Bind cascade shadow maps
        for i in 1:backend.csm.num_cascades
            glActiveTexture(GL_TEXTURE0 + UInt32(next_unit + i - 1))
            glBindTexture(GL_TEXTURE_2D, backend.csm.cascade_textures[i])
            set_uniform!(sp, "u_CascadeShadowMaps[$( i - 1)]", Int32(next_unit + i - 1))
        end
        next_unit += backend.csm.num_cascades

        # Set cascade matrices
        for i in 1:backend.csm.num_cascades
            set_uniform!(sp, "u_CascadeMatrices[$(i - 1)]", backend.csm.cascade_matrices[i])
        end

        # Set cascade split distances
        for i in 1:(backend.csm.num_cascades + 1)
            set_uniform!(sp, "u_CascadeSplits[$(i - 1)]", backend.csm.split_distances[i])
        end

        set_uniform!(sp, "u_NumCascades", Int32(backend.csm.num_cascades))
        set_uniform!(sp, "u_HasShadows", Int32(1))
    else
        set_uniform!(sp, "u_HasShadows", Int32(0))
        set_uniform!(sp, "u_NumCascades", Int32(0))
    end

    # IBL (Image-Based Lighting)
    if pipeline.ibl_env !== nothing && pipeline.ibl_env.irradiance_map != GLuint(0)
        # Bind IBL textures
        glActiveTexture(GL_TEXTURE0 + UInt32(next_unit))
        glBindTexture(GL_TEXTURE_CUBE_MAP, pipeline.ibl_env.irradiance_map)
        set_uniform!(sp, "u_IrradianceMap", Int32(next_unit))
        next_unit += 1

        glActiveTexture(GL_TEXTURE0 + UInt32(next_unit))
        glBindTexture(GL_TEXTURE_CUBE_MAP, pipeline.ibl_env.prefilter_map)
        set_uniform!(sp, "u_PrefilterMap", Int32(next_unit))
        next_unit += 1

        glActiveTexture(GL_TEXTURE0 + UInt32(next_unit))
        glBindTexture(GL_TEXTURE_2D, pipeline.ibl_env.brdf_lut)
        set_uniform!(sp, "u_BRDFLUT", Int32(next_unit))

        set_uniform!(sp, "u_IBLIntensity", pipeline.ibl_env.intensity)
        set_uniform!(sp, "u_HasIBL", Int32(1))
    else
        # No IBL - use fallback ambient lighting
        set_uniform!(sp, "u_HasIBL", Int32(0))
    end

    # Draw fullscreen quad
    glBindVertexArray(pipeline.quad_vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(GLuint(0))

    unbind_framebuffer!()
end

"""
    copy_depth_buffer!(src_fbo, dst_fbo, width, height)

Copy depth buffer from source to destination framebuffer.
"""
function copy_depth_buffer!(src_fbo::GLuint, dst_fbo::GLuint, width::Int, height::Int)
    glBindFramebuffer(GL_READ_FRAMEBUFFER, src_fbo)
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst_fbo)
    glBlitFramebuffer(0, 0, width, height, 0, 0, width, height,
                     GL_DEPTH_BUFFER_BIT, GL_NEAREST)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
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

    # ---- Check for IBL component and create environment if needed ----
    if backend.deferred_pipeline !== nothing
        ibl_entities = entities_with_component(IBLComponent)
        if !isempty(ibl_entities) && backend.deferred_pipeline.ibl_env === nothing
            ibl_comp = get_component(ibl_entities[1], IBLComponent)
            if ibl_comp.enabled
                @info "Creating IBL environment" path=ibl_comp.environment_path intensity=ibl_comp.intensity
                ibl_env = IBLEnvironment(intensity=ibl_comp.intensity)
                create_ibl_environment!(ibl_env, ibl_comp.environment_path)
                backend.deferred_pipeline.ibl_env = ibl_env
            end
        end
    end

    # ---- Cascaded Shadow Map pass ----
    light_space = Mat4f(I)
    has_shadows = false
    if backend.csm !== nothing
        dir_entities = entities_with_component(DirectionalLightComponent)
        if !isempty(dir_entities)
            light = get_component(dir_entities[1], DirectionalLightComponent)
            light_dir = light.direction

            # Create depth shader if needed (reuse from shadow_map.jl)
            if backend.csm.depth_shader === nothing
                backend.csm.depth_shader = create_shader_program(SHADOW_VERTEX_SHADER, SHADOW_FRAGMENT_SHADER)
            end

            # Render all cascades
            for cascade_idx in 1:backend.csm.num_cascades
                near = backend.csm.split_distances[cascade_idx]
                far = backend.csm.split_distances[cascade_idx + 1]

                # Compute light space matrix for this cascade
                light_matrix = compute_cascade_light_matrix(view, proj, near, far, light_dir)
                backend.csm.cascade_matrices[cascade_idx] = light_matrix

                # Bind cascade framebuffer
                glBindFramebuffer(GL_FRAMEBUFFER, backend.csm.cascade_fbos[cascade_idx])
                glViewport(0, 0, backend.csm.resolution, backend.csm.resolution)
                glClear(GL_DEPTH_BUFFER_BIT)

                # Enable depth test and cull front faces (reduces peter-panning)
                glEnable(GL_DEPTH_TEST)
                glDepthFunc(GL_LESS)
                glEnable(GL_CULL_FACE)
                glCullFace(GL_FRONT)

                # Render depth only
                depth_shader = backend.csm.depth_shader
                glUseProgram(depth_shader.id)
                set_uniform!(depth_shader, "u_LightSpaceMatrix", light_matrix)

                # Render all entities (TODO: per-cascade frustum culling for optimization)
                iterate_components(MeshComponent) do entity_id, mesh
                    isempty(mesh.indices) && return

                    world_transform = get_world_transform(entity_id)
                    model = Mat4f(world_transform)

                    set_uniform!(depth_shader, "u_Model", model)

                    gpu_mesh = get_or_upload_mesh!(backend.gpu_cache, entity_id, mesh)
                    glBindVertexArray(gpu_mesh.vao)
                    glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
                    glBindVertexArray(GLuint(0))
                end

                # Restore state
                glCullFace(GL_BACK)
            end

            glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
            has_shadows = true

            # Keep light_space for backward compatibility (use first cascade)
            light_space = backend.csm.cascade_matrices[1]
        end
    end

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

    # Debug: Log entity counts (first frame only)
    if !haskey(backend.bounds_cache, EntityID(0xFFFFFFFFFFFFFFFF))
        @info "Rendering stats" opaque=length(opaque_entities) transparent=length(transparent_entities)
        backend.bounds_cache[EntityID(0xFFFFFFFFFFFFFFFF)] = BoundingSphere(Vec3f(0,0,0), 0.0f0)
    end

    # ==================================================================
    # DEFERRED RENDERING PATH
    # ==================================================================
    if backend.use_deferred && backend.deferred_pipeline !== nothing
        # Note: In deferred mode, we manage our own framebuffers and only use
        # post-processing at the very end for bloom/tone mapping/FXAA
        pipeline = backend.deferred_pipeline

        # ---- G-Buffer pass (opaque only) ----
        render_gbuffer_pass!(backend, pipeline, opaque_entities, view, proj)

        # ---- Deferred lighting pass ----
        render_deferred_lighting_pass!(backend, pipeline, cam_pos, view, proj, light_space, has_shadows)

        # ---- Screen-Space Ambient Occlusion (SSAO) pass ----
        ssao_texture = GLuint(0)
        if pipeline.ssao_pass !== nothing
            # Render SSAO (returns blurred occlusion texture)
            ssao_texture = render_ssao!(pipeline.ssao_pass, pipeline.gbuffer, proj)
        end

        # ---- Screen-Space Reflections (SSR) pass ----
        if pipeline.ssr_pass !== nothing
            # Run SSR ray-marching
            render_ssr!(pipeline.ssr_pass, pipeline.gbuffer,
                       pipeline.lighting_fbo.color_texture,
                       view, proj, cam_pos)

            # Composite SSR over lighting result (in-place)
            composite_ssr!(pipeline.lighting_fbo.fbo,
                          pipeline.lighting_fbo.color_texture,
                          pipeline.ssr_pass.ssr_texture,
                          pipeline.lighting_fbo.width,
                          pipeline.lighting_fbo.height,
                          pipeline.quad_vao)
        end

        # ---- Apply SSAO to lighting result ----
        if ssao_texture != GLuint(0)
            apply_ssao_to_lighting!(pipeline.lighting_fbo.fbo,
                                   pipeline.lighting_fbo.color_texture,
                                   ssao_texture,
                                   pipeline.lighting_fbo.width,
                                   pipeline.lighting_fbo.height,
                                   pipeline.quad_vao)
        end

        # ---- Copy lighting result to screen ----
        # Blit to default framebuffer
        glBindFramebuffer(GL_READ_FRAMEBUFFER, pipeline.lighting_fbo.fbo)
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(0))
        viewport = Int32[0, 0, 0, 0]
        glGetIntegerv(GL_VIEWPORT, viewport)
        width, height = Int(viewport[3]), Int(viewport[4])
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height,
                         GL_COLOR_BUFFER_BIT, GL_NEAREST)

        # Copy depth to default framebuffer for transparent pass
        copy_depth_buffer!(pipeline.gbuffer.fbo, GLuint(0), width, height)

        # ---- Forward pass for transparent objects (on top of deferred result) ----
        if !isempty(transparent_entities) && backend.shader !== nothing
            sort!(transparent_entities, by=x -> -x[5])  # farthest first

            sp = backend.shader
            glUseProgram(sp.id)

            # Camera uniforms
            set_uniform!(sp, "u_View", view)
            set_uniform!(sp, "u_Projection", proj)
            set_uniform!(sp, "u_CameraPos", cam_pos)
            set_uniform!(sp, "u_LightSpaceMatrix", light_space)

            # Shadow map
            if has_shadows && backend.shadow_map !== nothing
                glActiveTexture(GL_TEXTURE6)
                glBindTexture(GL_TEXTURE_2D, backend.shadow_map.depth_texture)
                set_uniform!(sp, "u_ShadowMap", Int32(6))
                set_uniform!(sp, "u_HasShadows", Int32(1))
            else
                set_uniform!(sp, "u_HasShadows", Int32(0))
            end

            # Lights
            upload_lights!(sp)

            # Render transparent entities
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

    # ==================================================================
    # FORWARD RENDERING PATH (Backward Compatibility)
    # ==================================================================
    else
        # Begin post-processing (render to HDR FBO)
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

        # Shadow map binding
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

        # ---- Opaque pass ----
        glDepthMask(GL_TRUE)
        glDisable(GL_BLEND)
        glEnable(GL_CULL_FACE)

        for (entity_id, mesh, model, normal_matrix) in opaque_entities
            _render_entity!(backend, sp, entity_id, mesh, model, normal_matrix)
        end

        # ---- Transparent pass (back-to-front) ----
        if !isempty(transparent_entities)
            sort!(transparent_entities, by=x -> -x[5])

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
    end

    # ---- End post-processing ----
    # Only apply post-processing in forward mode (for now)
    if backend.post_process !== nothing && !backend.use_deferred
        viewport = Int32[0, 0, 0, 0]
        glGetIntegerv(GL_VIEWPORT, viewport)
        end_post_process!(backend.post_process, Int(viewport[3]), Int(viewport[4]))
    end

    swap_buffers!(backend.window)
    return nothing
end
