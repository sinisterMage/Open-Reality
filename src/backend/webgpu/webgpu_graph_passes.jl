# WebGPU Render Graph Pass Implementations
# Each function wraps existing WebGPU FFI calls, adapting RGExecuteContext
# to the existing function signatures. These override the abstract stubs
# in deferred_graph.jl via multiple dispatch on WebGPUBackend.

# Note: The WebGPU backend's render_frame! already calls modular FFI functions.
# These wrappers delegate to those same FFI calls.

function execute_rg_shadow_csm!(backend::WebGPUBackend, ctx::RGExecuteContext)
    frame_data = ctx.frame_data
    frame_data.primary_light_dir === nothing && return

    _wgpu_render_shadow_pass!(backend, frame_data)
end

function execute_rg_gbuffer!(backend::WebGPUBackend, ctx::RGExecuteContext)
    !backend.deferred_initialized && return

    _wgpu_render_gbuffer_pass!(backend, ctx.frame_data)
end

function execute_rg_terrain_gbuffer!(backend::WebGPUBackend, ctx::RGExecuteContext)
    !backend.deferred_initialized && return

    _wgpu_render_terrain_gbuffer!(backend, ctx.frame_data)
end

function execute_rg_deferred_lighting!(backend::WebGPUBackend, ctx::RGExecuteContext)
    !backend.deferred_initialized && return

    wgpu_lighting_pass(backend.backend_handle)
end

function execute_rg_ssao!(backend::WebGPUBackend, ctx::RGExecuteContext)
    !backend.deferred_initialized && return

    _wgpu_render_ssao!(backend, ctx.frame_data)
end

function execute_rg_ssao_blur!(backend::WebGPUBackend, ctx::RGExecuteContext)
    # SSAO blur handled internally by _wgpu_render_ssao!
end

function execute_rg_ssr!(backend::WebGPUBackend, ctx::RGExecuteContext)
    !backend.deferred_initialized && return

    _wgpu_render_ssr!(backend, ctx.frame_data)
end

function execute_rg_composite_lighting!(backend::WebGPUBackend, ctx::RGExecuteContext)
    # Compositing handled automatically by the wgpu pipeline
end

function execute_rg_taa!(backend::WebGPUBackend, ctx::RGExecuteContext)
    !backend.deferred_initialized && return

    _wgpu_render_taa!(backend, ctx.frame_data, ctx.prev_view_proj)
end

# DoF, motion blur, bloom handled in post-process mega-pass
function execute_rg_dof_coc!(backend::WebGPUBackend, ctx::RGExecuteContext) end
function execute_rg_dof_blur!(backend::WebGPUBackend, ctx::RGExecuteContext) end
function execute_rg_dof_composite!(backend::WebGPUBackend, ctx::RGExecuteContext) end
function execute_rg_mblur_velocity!(backend::WebGPUBackend, ctx::RGExecuteContext) end
function execute_rg_mblur_blur!(backend::WebGPUBackend, ctx::RGExecuteContext) end
function execute_rg_bloom_extract!(backend::WebGPUBackend, ctx::RGExecuteContext) end
function execute_rg_bloom_blur!(backend::WebGPUBackend, ctx::RGExecuteContext) end

function execute_rg_post_composite!(backend::WebGPUBackend, ctx::RGExecuteContext)
    !backend.deferred_initialized && return

    _wgpu_render_post_process!(backend, ctx.frame_data, ctx.prev_view_proj)
end

function execute_rg_fxaa!(backend::WebGPUBackend, ctx::RGExecuteContext)
    # FXAA handled inside _wgpu_render_post_process!
end

function execute_rg_depth_copy!(backend::WebGPUBackend, ctx::RGExecuteContext)
    # WebGPU handles depth automatically
end

function execute_rg_forward_transparent!(backend::WebGPUBackend, ctx::RGExecuteContext)
    isempty(ctx.frame_data.transparent_entities) && return

    _wgpu_render_forward_pass!(backend, ctx.frame_data)
end

function execute_rg_particles!(backend::WebGPUBackend, ctx::RGExecuteContext)
    _wgpu_render_particles!(backend, ctx.frame_data)
end

function execute_rg_ui!(backend::WebGPUBackend, ctx::RGExecuteContext)
    _wgpu_render_ui!(backend)
end

function execute_rg_debug_draw!(backend::WebGPUBackend, ctx::RGExecuteContext)
    _wgpu_render_debug_draw!(backend, ctx.frame_data)
end

function execute_rg_present!(backend::WebGPUBackend, ctx::RGExecuteContext)
    wgpu_present(backend.backend_handle)
end
