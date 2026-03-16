# Vulkan Render Graph Pass Implementations
# Each function wraps existing Vulkan pass code, adapting RGExecuteContext
# to the existing function signatures. These override the abstract stubs
# in deferred_graph.jl via multiple dispatch on VulkanBackend.

# Helper: get the current swapchain image index from the backend
_vk_current_image_index(backend::VulkanBackend) = backend.current_image_index

# Helper: convert OpenGL projection to Vulkan conventions (Y-flip + depth remap)
function _vk_proj_from_frame(frame_data::FrameData)
    proj = frame_data.proj
    Mat4f(
        proj[1], proj[2], proj[3], proj[4],
        proj[5], -proj[6], proj[7], proj[8],
        proj[9], proj[10], 0.5f0*proj[11] + 0.5f0*proj[12], proj[12],
        proj[13], proj[14], 0.5f0*proj[15] + 0.5f0*proj[16], proj[16]
    )
end

function execute_rg_shadow_csm!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.csm === nothing && return
    fd = ctx.frame_data
    fd.primary_light_dir === nothing && return

    cmd = backend.command_buffers[backend.current_frame]
    vk_proj = _vk_proj_from_frame(fd)
    vk_render_csm_passes!(cmd, backend, backend.csm, fd.view, vk_proj, fd.primary_light_dir)
end

function execute_rg_gbuffer!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.deferred_pipeline === nothing && return
    cmd = backend.command_buffers[backend.current_frame]
    frame_idx = backend.current_frame
    w, h = ctx.width, ctx.height

    _render_gbuffer_pass!(cmd, backend, ctx.frame_data, frame_idx, w, h)
end

function execute_rg_terrain_gbuffer!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.deferred_pipeline === nothing && return
    backend.terrain_renderer === nothing && return
    cmd = backend.command_buffers[backend.current_frame]
    frame_idx = backend.current_frame
    fd = ctx.frame_data
    vk_proj = _vk_proj_from_frame(fd)
    w, h = ctx.width, ctx.height

    vk_render_terrain_gbuffer!(cmd, backend, frame_idx, vk_proj, fd.view, fd.cam_pos, w, h)
end

function execute_rg_deferred_lighting!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.deferred_pipeline === nothing && return
    dp = backend.deferred_pipeline
    dp.lighting_target === nothing && return
    cmd = backend.command_buffers[backend.current_frame]
    frame_idx = backend.current_frame
    w, h = ctx.width, ctx.height

    # Run SSAO first if enabled (result is passed to lighting)
    ssao_view = nothing
    pp_config = ctx.post_config
    if dp.ssao_pass !== nothing && pp_config.ssao_enabled
        vk_proj = _vk_proj_from_frame(ctx.frame_data)
        ssao_view = _render_ssao_pass!(cmd, backend, vk_proj, frame_idx, w, h)
    end

    _render_lighting_pass!(cmd, backend, ctx.frame_data, frame_idx, w, h; ssao_view=ssao_view)
end

function execute_rg_ssao!(backend::VulkanBackend, ctx::RGExecuteContext)
    # SSAO is handled inside execute_rg_deferred_lighting! since the Vulkan
    # lighting pass consumes the SSAO result directly via ssao_view binding.
end

function execute_rg_ssao_blur!(backend::VulkanBackend, ctx::RGExecuteContext)
    # SSAO blur is handled internally by _render_ssao_pass!
end

function execute_rg_ssr!(backend::VulkanBackend, ctx::RGExecuteContext)
    # SSR is handled internally by the Vulkan deferred lighting/composite pipeline.
    # The SSR pass target is bound as a descriptor in the lighting pass.
end

function execute_rg_composite_lighting!(backend::VulkanBackend, ctx::RGExecuteContext)
    # The Vulkan backend composes SSR + SSAO during the lighting pass itself,
    # so this is a no-op. The result is in deferred_pipeline.lighting_target.
end

function execute_rg_taa!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.deferred_pipeline === nothing && return
    dp = backend.deferred_pipeline
    dp.taa_pass === nothing && return
    dp.lighting_target === nothing && return
    cmd = backend.command_buffers[backend.current_frame]
    frame_idx = backend.current_frame
    fd = ctx.frame_data
    vk_proj = _vk_proj_from_frame(fd)
    w, h = ctx.width, ctx.height

    source_view = dp.lighting_target.color_view
    _render_taa_pass!(cmd, backend, frame_idx, vk_proj, fd.view, w, h, source_view)
end

# DoF, motion blur, bloom are handled in the post-process mega-pass on Vulkan
function execute_rg_dof_coc!(backend::VulkanBackend, ctx::RGExecuteContext) end
function execute_rg_dof_blur!(backend::VulkanBackend, ctx::RGExecuteContext) end
function execute_rg_dof_composite!(backend::VulkanBackend, ctx::RGExecuteContext) end
function execute_rg_mblur_velocity!(backend::VulkanBackend, ctx::RGExecuteContext) end
function execute_rg_mblur_blur!(backend::VulkanBackend, ctx::RGExecuteContext) end
function execute_rg_bloom_extract!(backend::VulkanBackend, ctx::RGExecuteContext) end
function execute_rg_bloom_blur!(backend::VulkanBackend, ctx::RGExecuteContext) end

function execute_rg_post_composite!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.deferred_pipeline === nothing && return
    dp = backend.deferred_pipeline
    cmd = backend.command_buffers[backend.current_frame]
    frame_idx = backend.current_frame
    w, h = ctx.width, ctx.height

    # Determine source view (TAA output if available, else lighting)
    source_view = if dp.taa_pass !== nothing && dp.taa_pass.current_target !== nothing
        dp.taa_pass.current_target.color_view
    elseif dp.lighting_target !== nothing
        dp.lighting_target.color_view
    else
        return
    end

    # DOF pass (returns source_view unchanged if disabled)
    source_view = _render_dof_pass!(cmd, backend, frame_idx, source_view, w, h)

    # Motion blur pass (returns source_view unchanged if disabled)
    fd = ctx.frame_data
    vk_proj = _vk_proj_from_frame(fd)
    source_view = _render_motion_blur_pass!(cmd, backend, frame_idx, source_view,
        vk_proj, fd.view, w, h)

    # Post-process (bloom + tone mapping + color grading)
    source_view = _render_post_process_passes!(cmd, backend, frame_idx, source_view, w, h)

    # Present pass — blit post-processed result to swapchain.
    # Must run HERE (before overlay passes) because the present render pass
    # transitions the swapchain image UNDEFINED → PRESENT_SRC_KHR, and
    # subsequent overlay passes (particles/UI/debug) use the UI render pass
    # which expects initialLayout = PRESENT_SRC_KHR.
    pp_config = ctx.post_config
    image_index = _vk_current_image_index(backend)
    _render_present_pass!(cmd, backend, image_index, frame_idx, w, h;
        source_view=source_view,
        use_passthrough=true,
        apply_fxaa=pp_config.fxaa_enabled)
end

function execute_rg_fxaa!(backend::VulkanBackend, ctx::RGExecuteContext)
    # FXAA is handled inside _render_present_pass! called from execute_rg_post_composite!
end

function execute_rg_depth_copy!(backend::VulkanBackend, ctx::RGExecuteContext)
    # Vulkan doesn't need explicit depth copy — render pass dependencies handle this
end

function execute_rg_forward_transparent!(backend::VulkanBackend, ctx::RGExecuteContext)
    isempty(ctx.frame_data.transparent_entities) && return
    # Forward transparent rendering is handled via the present render pass
    # on Vulkan — transparent entities are drawn after the present pass begins.
    # This is a no-op because Vulkan's present render pass is still active.
end

function execute_rg_particles!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.particle_renderer === nothing && return
    !backend.particle_renderer.initialized && return
    isempty(PARTICLE_POOLS) && return
    cmd = backend.command_buffers[backend.current_frame]
    fd = ctx.frame_data
    vk_proj = _vk_proj_from_frame(fd)
    image_index = _vk_current_image_index(backend)

    vk_render_particles!(cmd, backend.particle_renderer, backend, fd.view, vk_proj, image_index)
end

function execute_rg_ui!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.ui_renderer === nothing && return
    _UI_CALLBACK[] === nothing && return
    _UI_CONTEXT[] === nothing && return

    cmd = backend.command_buffers[backend.current_frame]
    frame_idx = backend.current_frame
    image_index = _vk_current_image_index(backend)
    ui_ctx = _UI_CONTEXT[]

    # Ensure font atlas is ready
    if isempty(ui_ctx.font_atlas.glyphs)
        vk_ensure_font_atlas!(backend.ui_renderer, backend.device,
            backend.physical_device, backend.command_pool, backend.graphics_queue, ui_ctx)
    end
    clear_ui!(ui_ctx)
    _UI_CALLBACK[](ui_ctx)
    vk_render_ui!(cmd, backend.ui_renderer, backend, ui_ctx, image_index, frame_idx)
end

function execute_rg_debug_draw!(backend::VulkanBackend, ctx::RGExecuteContext)
    backend.debug_draw_renderer === nothing && return
    !backend.debug_draw_renderer.initialized && return
    !OPENREALITY_DEBUG && return
    isempty(_DEBUG_LINES) && return

    cmd = backend.command_buffers[backend.current_frame]
    fd = ctx.frame_data
    vk_proj = _vk_proj_from_frame(fd)
    image_index = _vk_current_image_index(backend)

    vk_render_debug_draw!(cmd, backend.debug_draw_renderer, backend, fd.view, vk_proj, image_index)
end

function execute_rg_present!(backend::VulkanBackend, ctx::RGExecuteContext)
    # The actual present render pass (blit to swapchain) runs inside
    # execute_rg_post_composite! so that overlay passes can layer on top.
    # The vkQueuePresent call happens in render_frame! after execute_graph! returns.
end
