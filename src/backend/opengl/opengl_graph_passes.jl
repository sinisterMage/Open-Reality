# OpenGL Render Graph Pass Implementations
# Each function wraps existing OpenGL pass code, adapting RGExecuteContext
# to the existing function signatures. These override the abstract stubs
# in deferred_graph.jl via multiple dispatch on OpenGLBackend.

# ---- 1. Shadow CSM ----

function execute_rg_shadow_csm!(backend::OpenGLBackend, ctx::RGExecuteContext)
    backend.csm === nothing && return

    dir_eid = first_entity_with_component(DirectionalLightComponent)
    dir_eid === nothing && return

    light = get_component(dir_eid, DirectionalLightComponent)
    light_dir = light.direction

    if backend.csm.depth_shader === nothing
        backend.csm.depth_shader = create_shader_program(SHADOW_VERTEX_SHADER, SHADOW_FRAGMENT_SHADER)
    end

    for cascade_idx in 1:backend.csm.num_cascades
        near = backend.csm.split_distances[cascade_idx]
        far = backend.csm.split_distances[cascade_idx + 1]
        light_matrix = compute_cascade_light_matrix(ctx.frame_data.view, ctx.frame_data.proj,
                                                     near, far, light_dir)
        backend.csm.cascade_matrices[cascade_idx] = light_matrix

        glBindFramebuffer(GL_FRAMEBUFFER, backend.csm.cascade_fbos[cascade_idx])
        glViewport(0, 0, backend.csm.resolution, backend.csm.resolution)
        glClear(GL_DEPTH_BUFFER_BIT)

        glEnable(GL_DEPTH_TEST)
        glDepthFunc(GL_LESS)
        glEnable(GL_CULL_FACE)
        glCullFace(GL_FRONT)

        depth_shader = backend.csm.depth_shader
        glUseProgram(depth_shader.id)
        set_uniform!(depth_shader, "u_LightSpaceMatrix", light_matrix)

        iterate_components(MeshComponent) do entity_id, mesh
            isempty(mesh.indices) && return

            world_transform = get_world_transform(entity_id)
            model = Mat4f(world_transform)
            set_uniform!(depth_shader, "u_Model", model)

            gpu_mesh = get_or_upload_mesh!(backend.gpu_cache, entity_id, mesh)
            _upload_skinning_uniforms!(depth_shader, entity_id, gpu_mesh)

            glBindVertexArray(gpu_mesh.vao)
            glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
            glBindVertexArray(GLuint(0))
        end

        glCullFace(GL_BACK)
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 2. G-Buffer (opaque geometry) ----

function execute_rg_gbuffer!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return

    opaque = ctx.frame_data.opaque_entities
    view = ctx.frame_data.view
    proj = ctx.frame_data.proj
    cam_pos = ctx.frame_data.cam_pos

    (batches, singles) = group_into_batches(opaque)
    if !isempty(batches)
        render_gbuffer_pass_instanced!(backend, pipeline, batches, singles, view, proj, cam_pos)
    else
        render_gbuffer_pass!(backend, pipeline, opaque, view, proj, cam_pos)
    end
end

# ---- 3. Terrain G-Buffer ----

function execute_rg_terrain_gbuffer!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return

    view = ctx.frame_data.view
    proj = ctx.frame_data.proj
    cam_pos = ctx.frame_data.cam_pos
    vp = proj * view
    terrain_frustum = extract_frustum(vp)

    iterate_components(TerrainComponent) do terrain_eid, terrain_comp
        td = get(_TERRAIN_CACHE, terrain_eid, nothing)
        if td !== nothing && td.initialized
            bind_gbuffer_for_write!(pipeline.gbuffer)
            glViewport(0, 0, pipeline.gbuffer.width, pipeline.gbuffer.height)
            glEnable(GL_DEPTH_TEST)
            glDepthMask(GL_TRUE)
            glDepthFunc(GL_LESS)
            glEnable(GL_CULL_FACE)
            glDisable(GL_BLEND)
            render_terrain_gbuffer!(backend, td, terrain_comp, view, proj,
                                     cam_pos, terrain_frustum, backend.texture_cache)
            unbind_framebuffer!()
        end
    end
end

# ---- 4. Deferred Lighting ----

function execute_rg_deferred_lighting!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return

    render_deferred_lighting_pass!(backend, pipeline, ctx.frame_data.cam_pos,
                                    ctx.frame_data.view, ctx.frame_data.proj,
                                    ctx.light_space, ctx.has_shadows)
end

# ---- 5. SSAO ----

function execute_rg_ssao!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return
    pipeline.ssao_pass === nothing && return

    render_ssao!(pipeline.ssao_pass, pipeline.gbuffer, ctx.frame_data.proj)
end

# ---- 6. SSAO Blur ----
# Note: render_ssao! already includes the blur pass internally
function execute_rg_ssao_blur!(backend::OpenGLBackend, ctx::RGExecuteContext)
    # SSAO blur is handled internally by render_ssao!, so this is a no-op.
    # The ssao_blurred texture is the output of the internal blur.
end

# ---- 7. SSR ----

function execute_rg_ssr!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return
    pipeline.ssr_pass === nothing && return

    render_ssr!(pipeline.ssr_pass, pipeline.gbuffer,
               pipeline.lighting_fbo.color_texture,
               ctx.frame_data.view, ctx.frame_data.proj, ctx.frame_data.cam_pos)
end

# ---- 8. Composite Lighting (SSR + SSAO onto lighting) ----

function execute_rg_composite_lighting!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return

    # Composite SSR over lighting (if SSR is active)
    if pipeline.ssr_pass !== nothing
        composite_ssr!(pipeline.lighting_fbo.fbo,
                      pipeline.lighting_fbo.color_texture,
                      pipeline.ssr_pass.ssr_texture,
                      pipeline.lighting_fbo.width,
                      pipeline.lighting_fbo.height,
                      pipeline.quad_vao)
    end

    # Apply SSAO to lighting (if SSAO is active)
    if pipeline.ssao_pass !== nothing
        ssao_texture = pipeline.ssao_pass.blur_texture
        if ssao_texture != GLuint(0)
            apply_ssao_to_lighting!(pipeline.lighting_fbo.fbo,
                                   pipeline.lighting_fbo.color_texture,
                                   ssao_texture,
                                   pipeline.lighting_fbo.width,
                                   pipeline.lighting_fbo.height,
                                   pipeline.quad_vao)
        end
    end
end

# ---- 9. TAA ----

function execute_rg_taa!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return
    pipeline.taa_pass === nothing && return

    render_taa!(pipeline.taa_pass,
               pipeline.lighting_fbo.color_texture,
               pipeline.gbuffer.depth_texture,
               ctx.frame_data.view, ctx.frame_data.proj,
               pipeline.quad_vao)
end

# ---- Helper: get the current HDR texture flowing through the post-process chain ----

function _get_current_hdr_texture(backend::OpenGLBackend)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return GLuint(0)

    if pipeline.taa_pass !== nothing
        return pipeline.taa_pass.current_texture
    else
        return pipeline.lighting_fbo.color_texture
    end
end

function _get_depth_texture(backend::OpenGLBackend)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return GLuint(0)
    return pipeline.gbuffer.depth_texture
end

# ---- 10. Depth of Field - CoC ----
# DoF CoC + blur + composite are now decomposed into individual graph passes.
# They call the internal sub-steps of the existing render_dof! function.

function execute_rg_dof_coc!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    pp.dof_pass === nothing && return
    !ctx.post_config.dof_enabled && return

    depth_texture = _get_depth_texture(backend)
    depth_texture == GLuint(0) && return

    dof = pp.dof_pass

    # CoC computation pass (extracted from render_dof!)
    glBindFramebuffer(GL_FRAMEBUFFER, dof.coc_fbo.fbo)
    glViewport(0, 0, dof.coc_fbo.width, dof.coc_fbo.height)
    glClear(GL_COLOR_BUFFER_BIT)
    glDisable(GL_DEPTH_TEST)

    if dof.coc_shader !== nothing
        glUseProgram(dof.coc_shader.id)
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, depth_texture)
        set_uniform!(dof.coc_shader, "u_DepthTexture", Int32(0))
        set_uniform!(dof.coc_shader, "u_FocusDistance", ctx.post_config.dof_focus_distance)
        set_uniform!(dof.coc_shader, "u_FocusRange", ctx.post_config.dof_focus_range)
        set_uniform!(dof.coc_shader, "u_NearPlane", 0.1f0)
        set_uniform!(dof.coc_shader, "u_FarPlane", 500.0f0)
        _render_fullscreen_quad(pp.quad_vao)
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 11. Depth of Field - Blur ----

function execute_rg_dof_blur!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    pp.dof_pass === nothing && return
    !ctx.post_config.dof_enabled && return

    dof = pp.dof_pass
    scene_texture = _get_current_hdr_texture(backend)
    scene_texture == GLuint(0) && return

    dof.blur_shader === nothing && return

    glDisable(GL_DEPTH_TEST)

    # Horizontal blur
    glBindFramebuffer(GL_FRAMEBUFFER, dof.blur_fbo_h.fbo)
    glViewport(0, 0, dof.blur_fbo_h.width, dof.blur_fbo_h.height)
    glClear(GL_COLOR_BUFFER_BIT)
    glUseProgram(dof.blur_shader.id)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, scene_texture)
    set_uniform!(dof.blur_shader, "u_SceneTexture", Int32(0))
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, dof.coc_fbo.color_texture)
    set_uniform!(dof.blur_shader, "u_CoCTexture", Int32(1))
    set_uniform!(dof.blur_shader, "u_Horizontal", Int32(1))
    set_uniform!(dof.blur_shader, "u_BokehRadius", ctx.post_config.dof_bokeh_radius)
    _render_fullscreen_quad(pp.quad_vao)

    # Vertical blur
    glBindFramebuffer(GL_FRAMEBUFFER, dof.blur_fbo_v.fbo)
    glViewport(0, 0, dof.blur_fbo_v.width, dof.blur_fbo_v.height)
    glClear(GL_COLOR_BUFFER_BIT)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, dof.blur_fbo_h.color_texture)
    set_uniform!(dof.blur_shader, "u_Horizontal", Int32(0))
    _render_fullscreen_quad(pp.quad_vao)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 12. Depth of Field - Composite ----

function execute_rg_dof_composite!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    pp.dof_pass === nothing && return
    !ctx.post_config.dof_enabled && return

    dof = pp.dof_pass
    scene_texture = _get_current_hdr_texture(backend)
    dof.composite_shader === nothing && return

    glDisable(GL_DEPTH_TEST)
    glBindFramebuffer(GL_FRAMEBUFFER, pp.dof_temp_fbo.fbo)
    glViewport(0, 0, pp.dof_temp_fbo.width, pp.dof_temp_fbo.height)
    glClear(GL_COLOR_BUFFER_BIT)

    glUseProgram(dof.composite_shader.id)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, scene_texture)
    set_uniform!(dof.composite_shader, "u_SharpTexture", Int32(0))
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, dof.blur_fbo_v.color_texture)
    set_uniform!(dof.composite_shader, "u_BlurTexture", Int32(1))
    glActiveTexture(GL_TEXTURE2)
    glBindTexture(GL_TEXTURE_2D, dof.coc_fbo.color_texture)
    set_uniform!(dof.composite_shader, "u_CoCTexture", Int32(2))
    _render_fullscreen_quad(pp.quad_vao)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 13. Motion Blur - Velocity ----

function execute_rg_mblur_velocity!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    pp.motion_blur_pass === nothing && return
    !ctx.post_config.motion_blur_enabled && return

    depth_texture = _get_depth_texture(backend)
    depth_texture == GLuint(0) && return

    mb = pp.motion_blur_pass
    mb.velocity_shader === nothing && return

    current_view_proj = ctx.frame_data.proj * ctx.frame_data.view
    inv_vp = inv(current_view_proj)

    glDisable(GL_DEPTH_TEST)
    glBindFramebuffer(GL_FRAMEBUFFER, mb.velocity_fbo.fbo)
    glViewport(0, 0, mb.velocity_fbo.width, mb.velocity_fbo.height)
    glClear(GL_COLOR_BUFFER_BIT)

    glUseProgram(mb.velocity_shader.id)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, depth_texture)
    set_uniform!(mb.velocity_shader, "u_DepthTexture", Int32(0))
    set_uniform!(mb.velocity_shader, "u_InvViewProj", Mat4f(inv_vp))
    set_uniform!(mb.velocity_shader, "u_PrevViewProj", ctx.prev_view_proj)
    set_uniform!(mb.velocity_shader, "u_MaxVelocity", ctx.post_config.motion_blur_max_velocity)
    _render_fullscreen_quad(pp.quad_vao)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 14. Motion Blur - Blur ----

function execute_rg_mblur_blur!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    pp.motion_blur_pass === nothing && return
    !ctx.post_config.motion_blur_enabled && return

    mb = pp.motion_blur_pass
    mb.blur_shader === nothing && return

    # Determine input: DoF output if available, else TAA output, else lighting
    scene_texture = if ctx.post_config.dof_enabled && pp.dof_pass !== nothing
        pp.dof_temp_fbo.color_texture
    else
        _get_current_hdr_texture(backend)
    end
    scene_texture == GLuint(0) && return

    glDisable(GL_DEPTH_TEST)
    glBindFramebuffer(GL_FRAMEBUFFER, mb.blur_fbo.fbo)
    glViewport(0, 0, mb.blur_fbo.width, mb.blur_fbo.height)
    glClear(GL_COLOR_BUFFER_BIT)

    glUseProgram(mb.blur_shader.id)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, scene_texture)
    set_uniform!(mb.blur_shader, "u_SceneTexture", Int32(0))
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, mb.velocity_fbo.color_texture)
    set_uniform!(mb.blur_shader, "u_VelocityTexture", Int32(1))
    set_uniform!(mb.blur_shader, "u_Intensity", ctx.post_config.motion_blur_intensity)
    set_uniform!(mb.blur_shader, "u_Samples", Int32(ctx.post_config.motion_blur_samples))
    _render_fullscreen_quad(pp.quad_vao)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 15. Bloom - Extract bright pixels ----

function execute_rg_bloom_extract!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    !ctx.post_config.bloom_enabled && return
    pp.bright_extract_shader === nothing && return

    # Determine the final HDR texture at this point in the chain
    scene_texture = if ctx.post_config.motion_blur_enabled && pp.motion_blur_pass !== nothing
        pp.motion_blur_pass.blur_fbo.color_texture
    elseif ctx.post_config.dof_enabled && pp.dof_pass !== nothing
        pp.dof_temp_fbo.color_texture
    else
        _get_current_hdr_texture(backend)
    end
    scene_texture == GLuint(0) && return

    glDisable(GL_DEPTH_TEST)
    glBindFramebuffer(GL_FRAMEBUFFER, pp.bright_fbo.fbo)
    glViewport(0, 0, pp.bright_fbo.width, pp.bright_fbo.height)
    glClear(GL_COLOR_BUFFER_BIT)

    sp = pp.bright_extract_shader
    glUseProgram(sp.id)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, scene_texture)
    set_uniform!(sp, "u_SceneTexture", Int32(0))
    set_uniform!(sp, "u_Threshold", ctx.post_config.bloom_threshold)
    _render_fullscreen_quad(pp.quad_vao)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 16. Bloom - Gaussian blur ping-pong ----

function execute_rg_bloom_blur!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    !ctx.post_config.bloom_enabled && return
    pp.blur_shader === nothing && return

    glDisable(GL_DEPTH_TEST)
    sp = pp.blur_shader
    glUseProgram(sp.id)

    horizontal = true
    first_iteration = true
    for _ in 1:10  # 5 horizontal + 5 vertical iterations
        idx = horizontal ? 1 : 2
        glBindFramebuffer(GL_FRAMEBUFFER, pp.bloom_fbos[idx].fbo)
        glViewport(0, 0, pp.bloom_fbos[idx].width, pp.bloom_fbos[idx].height)
        glClear(GL_COLOR_BUFFER_BIT)
        set_uniform!(sp, "u_Horizontal", Int32(horizontal ? 1 : 0))
        glActiveTexture(GL_TEXTURE0)
        if first_iteration
            glBindTexture(GL_TEXTURE_2D, pp.bright_fbo.color_texture)
            first_iteration = false
        else
            other_idx = horizontal ? 2 : 1
            glBindTexture(GL_TEXTURE_2D, pp.bloom_fbos[other_idx].color_texture)
        end
        set_uniform!(sp, "u_Image", Int32(0))
        _render_fullscreen_quad(pp.quad_vao)
        horizontal = !horizontal
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 17. Post-Process Composite (tone mapping + bloom combine + vignette + color grading) ----

function execute_rg_post_composite!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    pp.composite_shader === nothing && return

    # Determine the final HDR texture
    scene_texture = if ctx.post_config.motion_blur_enabled && pp.motion_blur_pass !== nothing
        pp.motion_blur_pass.blur_fbo.color_texture
    elseif ctx.post_config.dof_enabled && pp.dof_pass !== nothing
        pp.dof_temp_fbo.color_texture
    else
        _get_current_hdr_texture(backend)
    end
    scene_texture == GLuint(0) && return

    bloom_texture = if ctx.post_config.bloom_enabled && length(pp.bloom_fbos) >= 2
        pp.bloom_fbos[2].color_texture
    else
        GLuint(0)
    end

    glDisable(GL_DEPTH_TEST)

    # If FXAA is enabled, render composite to scene_fbo (as temp), then FXAA reads it
    if ctx.post_config.fxaa_enabled && pp.fxaa_shader !== nothing
        glBindFramebuffer(GL_FRAMEBUFFER, pp.scene_fbo.fbo)
        glViewport(0, 0, pp.scene_fbo.width, pp.scene_fbo.height)
    else
        glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
        glViewport(0, 0, ctx.width, ctx.height)
    end
    glClear(GL_COLOR_BUFFER_BIT)

    sp = pp.composite_shader
    glUseProgram(sp.id)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, scene_texture)
    set_uniform!(sp, "u_SceneTexture", Int32(0))

    if bloom_texture != GLuint(0)
        glActiveTexture(GL_TEXTURE1)
        glBindTexture(GL_TEXTURE_2D, bloom_texture)
        set_uniform!(sp, "u_BloomTexture", Int32(1))
        set_uniform!(sp, "u_BloomEnabled", Int32(1))
        set_uniform!(sp, "u_BloomIntensity", ctx.post_config.bloom_intensity)
    else
        set_uniform!(sp, "u_BloomEnabled", Int32(0))
    end

    tone_map_idx = Int32(ctx.post_config.tone_mapping == TONEMAP_REINHARD ? 0 :
                         ctx.post_config.tone_mapping == TONEMAP_ACES ? 1 : 2)
    set_uniform!(sp, "u_ToneMapping", tone_map_idx)
    set_uniform!(sp, "u_Gamma", ctx.post_config.gamma)

    set_uniform!(sp, "u_VignetteEnabled", Int32(ctx.post_config.vignette_enabled ? 1 : 0))
    if ctx.post_config.vignette_enabled
        set_uniform!(sp, "u_VignetteIntensity", ctx.post_config.vignette_intensity)
        set_uniform!(sp, "u_VignetteRadius", ctx.post_config.vignette_radius)
        set_uniform!(sp, "u_VignetteSoftness", ctx.post_config.vignette_softness)
    end

    set_uniform!(sp, "u_ColorGradingEnabled", Int32(ctx.post_config.color_grading_enabled ? 1 : 0))
    if ctx.post_config.color_grading_enabled
        set_uniform!(sp, "u_Brightness", ctx.post_config.color_grading_brightness)
        set_uniform!(sp, "u_Contrast", ctx.post_config.color_grading_contrast)
        set_uniform!(sp, "u_Saturation", ctx.post_config.color_grading_saturation)
    end

    _render_fullscreen_quad(pp.quad_vao)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

# ---- 18. FXAA ----

function execute_rg_fxaa!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pp = backend.post_process
    pp === nothing && return
    !ctx.post_config.fxaa_enabled && return
    pp.fxaa_shader === nothing && return

    glDisable(GL_DEPTH_TEST)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
    glViewport(0, 0, ctx.width, ctx.height)

    sp = pp.fxaa_shader
    glUseProgram(sp.id)
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, pp.scene_fbo.color_texture)
    set_uniform!(sp, "u_SceneTexture", Int32(0))
    set_uniform!(sp, "u_InverseScreenSize", Vec2f(1.0f0 / ctx.width, 1.0f0 / ctx.height))
    _render_fullscreen_quad(pp.quad_vao)

    glEnable(GL_DEPTH_TEST)
end

# ---- 19. Depth Copy ----

function execute_rg_depth_copy!(backend::OpenGLBackend, ctx::RGExecuteContext)
    pipeline = backend.deferred_pipeline
    pipeline === nothing && return

    copy_depth_buffer!(pipeline.gbuffer.fbo, GLuint(0), ctx.width, ctx.height)
end

# ---- 20. Forward Transparent ----

function execute_rg_forward_transparent!(backend::OpenGLBackend, ctx::RGExecuteContext)
    transparent = ctx.frame_data.transparent_entities
    isempty(transparent) && return
    backend.shader === nothing && return

    view = ctx.frame_data.view
    proj = ctx.frame_data.proj
    cam_pos = ctx.frame_data.cam_pos
    sp = backend.shader

    glUseProgram(sp.id)

    # Camera uniforms
    set_uniform!(sp, "u_View", view)
    set_uniform!(sp, "u_Projection", proj)
    set_uniform!(sp, "u_CameraPos", cam_pos)
    set_uniform!(sp, "u_LightSpaceMatrix", ctx.light_space)

    # CSM uniforms
    if ctx.has_shadows && backend.csm !== nothing
        next_unit = Int32(7)
        for i in 1:backend.csm.num_cascades
            glActiveTexture(GL_TEXTURE0 + UInt32(next_unit + i - 1))
            glBindTexture(GL_TEXTURE_2D, backend.csm.cascade_textures[i])
            set_uniform!(sp, "u_CascadeShadowMaps[$(i - 1)]", Int32(next_unit + i - 1))
        end
        for i in 1:backend.csm.num_cascades
            set_uniform!(sp, "u_CascadeMatrices[$(i - 1)]", backend.csm.cascade_matrices[i])
        end
        for i in 1:(backend.csm.num_cascades + 1)
            set_uniform!(sp, "u_CascadeSplits[$(i - 1)]", backend.csm.split_distances[i])
        end
        set_uniform!(sp, "u_NumCascades", Int32(backend.csm.num_cascades))
        set_uniform!(sp, "u_HasShadows", Int32(1))
    elseif ctx.has_shadows && backend.shadow_map !== nothing
        glActiveTexture(GL_TEXTURE6)
        glBindTexture(GL_TEXTURE_2D, backend.shadow_map.depth_texture)
        set_uniform!(sp, "u_ShadowMap", Int32(6))
        set_uniform!(sp, "u_NumCascades", Int32(0))
        set_uniform!(sp, "u_HasShadows", Int32(1))
    else
        set_uniform!(sp, "u_HasShadows", Int32(0))
        set_uniform!(sp, "u_NumCascades", Int32(0))
    end

    upload_lights!(sp)

    # Render transparent entities (sorted back-to-front)
    glDepthMask(GL_FALSE)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDisable(GL_CULL_FACE)

    for tdata in transparent
        _render_entity!(backend, sp, tdata.entity_id, tdata.mesh,
                         tdata.model, tdata.normal_matrix)
    end

    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)
    glEnable(GL_CULL_FACE)
end

# ---- 21. Particles ----

function execute_rg_particles!(backend::OpenGLBackend, ctx::RGExecuteContext)
    render_particles!(ctx.frame_data.view, ctx.frame_data.proj)
end

# ---- 22. UI ----

function execute_rg_ui!(backend::OpenGLBackend, ctx::RGExecuteContext)
    if _UI_CALLBACK[] !== nothing && _UI_CONTEXT[] !== nothing
        ui_ctx = _UI_CONTEXT[]
        clear_ui!(ui_ctx)
        _UI_CALLBACK[](ui_ctx)
        render_ui!(ui_ctx)
    end
end

# ---- 23. Debug Draw ----

function execute_rg_debug_draw!(backend::OpenGLBackend, ctx::RGExecuteContext)
    render_debug_draw!(backend, ctx.frame_data.view, ctx.frame_data.proj)
end

# ---- 24. Present ----

function execute_rg_present!(backend::OpenGLBackend, ctx::RGExecuteContext)
    # Visual regression test capture hook
    if _CAPTURE_HOOK[] !== nothing
        _CAPTURE_HOOK[](backend.window.width, backend.window.height)
    end

    swap_buffers!(backend.window)
end
