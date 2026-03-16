# Deferred Render Graph Construction
# Builds the standard deferred rendering graph used by all backends.
# Pass execute functions dispatch via multiple dispatch on the backend type.

# ---- Execute function stubs (dispatched per-backend) ----
# Concrete implementations live in backend-specific files:
#   opengl_graph_passes.jl, vulkan_graph_passes.jl, webgpu_graph_passes.jl

function execute_rg_shadow_csm!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_gbuffer!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_terrain_gbuffer!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_deferred_lighting!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_ssao!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_ssao_blur!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_ssr!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_composite_lighting!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_taa!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_dof_coc!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_dof_blur!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_dof_composite!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_mblur_velocity!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_mblur_blur!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_bloom_extract!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_bloom_blur!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_post_composite!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_fxaa!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_depth_copy!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_forward_transparent!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_particles!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_ui!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_debug_draw!(backend::AbstractBackend, ctx::RGExecuteContext) end
function execute_rg_present!(backend::AbstractBackend, ctx::RGExecuteContext) end

# ---- Resource handle storage ----

"""
    DeferredGraphHandles

Holds all resource handles produced by `build_deferred_render_graph!`.
Stored on the backend/executor so pass callbacks can reference specific resources.
"""
struct DeferredGraphHandles
    # G-Buffer
    gbuf_albedo_metallic::RGResourceHandle
    gbuf_normal_roughness::RGResourceHandle
    gbuf_emissive_ao::RGResourceHandle
    gbuf_advanced::RGResourceHandle
    gbuf_depth::RGResourceHandle

    # Shadows
    csm_depth::RGResourceHandle

    # Lighting
    lighting_hdr::RGResourceHandle
    lighting_composited::RGResourceHandle

    # SSAO
    ssao_raw::RGResourceHandle
    ssao_blurred::RGResourceHandle

    # SSR
    ssr_result::RGResourceHandle

    # TAA
    taa_history::RGResourceHandle
    taa_output::RGResourceHandle

    # DoF
    dof_coc::RGResourceHandle
    dof_blur::RGResourceHandle
    dof_output::RGResourceHandle

    # Motion blur
    mblur_velocity::RGResourceHandle
    mblur_output::RGResourceHandle

    # Post-processing
    bloom_bright::RGResourceHandle
    bloom_blurred::RGResourceHandle
    post_output::RGResourceHandle

    # Swapchain
    swapchain::RGResourceHandle
end

# ---- Graph construction ----

"""
    build_deferred_render_graph!(config::PostProcessConfig;
        ssao_enabled=false, ssr_enabled=false, taa_enabled=false
    ) -> (RenderGraph, DeferredGraphHandles)

Construct the standard deferred rendering graph. Backend-agnostic — the same
graph works for OpenGL, Vulkan, and WebGPU. The `config` and boolean flags
determine which optional passes are enabled.
"""
function build_deferred_render_graph!(config::PostProcessConfig;
        ssao_enabled::Bool=false,
        ssr_enabled::Bool=false,
        taa_enabled::Bool=false)

    graph = RenderGraph()

    # ================================================================
    # Resource Declarations
    # ================================================================

    # G-Buffer MRTs
    gbuf_albedo = declare_resource!(graph, :gbuf_albedo_metallic, RG_RGBA16F;
        clear_value=(0.0f0, 0.0f0, 0.0f0, 0.0f0))
    gbuf_normal = declare_resource!(graph, :gbuf_normal_roughness, RG_RGBA16F;
        clear_value=(0.5f0, 0.5f0, 1.0f0, 0.0f0))
    gbuf_emissive = declare_resource!(graph, :gbuf_emissive_ao, RG_RGBA16F;
        clear_value=(0.0f0, 0.0f0, 0.0f0, 1.0f0))
    gbuf_advanced = declare_resource!(graph, :gbuf_advanced, RG_RGBA8;
        clear_value=(0.0f0, 0.0f0, 0.0f0, 1.0f0))
    gbuf_depth = declare_resource!(graph, :gbuf_depth, RG_DEPTH32F;
        clear_value=(1.0f0, 0.0f0, 0.0f0, 0.0f0))

    # Shadow cascades (fixed size, persistent)
    csm_depth = declare_resource!(graph, :csm_depth, RG_DEPTH32F,
        rg_fixed_size(1024, 1024); lifetime=RG_PERSISTENT)

    # Lighting
    lighting_hdr = declare_resource!(graph, :lighting_hdr, RG_RGBA16F)

    # SSAO
    ssao_raw = declare_resource!(graph, :ssao_raw, RG_R16F)
    ssao_blurred = declare_resource!(graph, :ssao_blurred, RG_R16F)

    # SSR
    ssr_result = declare_resource!(graph, :ssr_result, RG_RGBA16F)

    # Composited lighting (after SSR + SSAO)
    lighting_composited = declare_resource!(graph, :lighting_composited, RG_RGBA16F)

    # TAA
    taa_history = declare_resource!(graph, :taa_history, RG_RGBA16F; lifetime=RG_MULTI_FRAME)
    taa_output = declare_resource!(graph, :taa_output, RG_RGBA16F)

    # DoF
    dof_coc = declare_resource!(graph, :dof_coc, RG_R16F)
    dof_blur = declare_resource!(graph, :dof_blur, RG_RGBA16F, HALF_RES)
    dof_output = declare_resource!(graph, :dof_output, RG_RGBA16F)

    # Motion blur
    mblur_velocity = declare_resource!(graph, :mblur_velocity, RG_RG16F)
    mblur_output = declare_resource!(graph, :mblur_output, RG_RGBA16F)

    # Post-process / bloom
    bloom_bright = declare_resource!(graph, :bloom_bright, RG_RGBA16F, HALF_RES)
    bloom_blurred = declare_resource!(graph, :bloom_blurred, RG_RGBA16F, HALF_RES)
    post_output = declare_resource!(graph, :post_output, RG_RGBA16F)

    # Swapchain (imported)
    swapchain = import_resource!(graph, :swapchain, RG_RGBA8_SRGB)

    # ================================================================
    # Pass Declarations
    # ================================================================

    # 1. Shadow CSM
    add_pass!(graph, :shadow_csm, execute_rg_shadow_csm!;
        writes=[(csm_depth, 0)])

    # 2. G-Buffer (opaque geometry)
    add_pass!(graph, :gbuffer, execute_rg_gbuffer!;
        writes=[
            (gbuf_albedo, 0), (gbuf_normal, 1),
            (gbuf_emissive, 2), (gbuf_advanced, 3),
            (gbuf_depth, 4)
        ])

    # 3. Terrain G-Buffer
    add_pass!(graph, :terrain_gbuffer, execute_rg_terrain_gbuffer!;
        read_writes=[
            (gbuf_albedo, 0), (gbuf_normal, 1),
            (gbuf_emissive, 2), (gbuf_advanced, 3),
            (gbuf_depth, 4)
        ])

    # 4. Deferred Lighting
    add_pass!(graph, :deferred_lighting, execute_rg_deferred_lighting!;
        reads=[gbuf_albedo, gbuf_normal, gbuf_emissive, gbuf_advanced, gbuf_depth, csm_depth],
        writes=[(lighting_hdr, 0)])

    # 5. SSAO
    add_pass!(graph, :ssao, execute_rg_ssao!;
        reads=[gbuf_normal, gbuf_depth],
        writes=[(ssao_raw, 0)],
        enabled=ssao_enabled)

    # 6. SSAO Blur
    add_pass!(graph, :ssao_blur, execute_rg_ssao_blur!;
        reads=[ssao_raw],
        writes=[(ssao_blurred, 0)],
        enabled=ssao_enabled)

    # 7. SSR
    add_pass!(graph, :ssr, execute_rg_ssr!;
        reads=[gbuf_normal, gbuf_depth, lighting_hdr],
        writes=[(ssr_result, 0)],
        enabled=ssr_enabled)

    # 8. Composite lighting (SSR + SSAO onto lighting)
    # Only read SSR/SSAO results if those effects are enabled
    composite_reads = RGResourceHandle[lighting_hdr]
    if ssr_enabled
        push!(composite_reads, ssr_result)
    end
    if ssao_enabled
        push!(composite_reads, ssao_blurred)
    end
    add_pass!(graph, :composite_lighting, execute_rg_composite_lighting!;
        reads=composite_reads,
        writes=[(lighting_composited, 0)])

    # 9. TAA
    add_pass!(graph, :taa, execute_rg_taa!;
        reads=[lighting_composited, gbuf_depth, taa_history],
        writes=[(taa_output, 0)],
        enabled=taa_enabled)

    # 10. DoF - Circle of Confusion
    add_pass!(graph, :dof_coc, execute_rg_dof_coc!;
        reads=[gbuf_depth],
        writes=[(dof_coc, 0)],
        enabled=config.dof_enabled)

    # 11. DoF - Blur
    # Input depends on whether TAA is enabled
    dof_input = taa_enabled ? taa_output : lighting_composited
    add_pass!(graph, :dof_blur, execute_rg_dof_blur!;
        reads=[dof_input, dof_coc],
        writes=[(dof_blur, 0)],
        enabled=config.dof_enabled)

    # 12. DoF - Composite
    add_pass!(graph, :dof_composite, execute_rg_dof_composite!;
        reads=[dof_input, dof_blur, dof_coc],
        writes=[(dof_output, 0)],
        enabled=config.dof_enabled)

    # 13. Motion Blur - Velocity
    add_pass!(graph, :mblur_velocity, execute_rg_mblur_velocity!;
        reads=[gbuf_depth],
        writes=[(mblur_velocity, 0)],
        enabled=config.motion_blur_enabled)

    # 14. Motion Blur - Blur
    # Input chain: dof_output > taa_output > lighting_composited
    mblur_input = if config.dof_enabled
        dof_output
    elseif taa_enabled
        taa_output
    else
        lighting_composited
    end
    add_pass!(graph, :mblur_blur, execute_rg_mblur_blur!;
        reads=[mblur_input, mblur_velocity],
        writes=[(mblur_output, 0)],
        enabled=config.motion_blur_enabled)

    # Determine final HDR input for post-processing
    final_hdr = if config.motion_blur_enabled
        mblur_output
    elseif config.dof_enabled
        dof_output
    elseif taa_enabled
        taa_output
    else
        lighting_composited
    end

    # 15. Bloom - Extract bright pixels
    add_pass!(graph, :bloom_extract, execute_rg_bloom_extract!;
        reads=[final_hdr],
        writes=[(bloom_bright, 0)],
        enabled=config.bloom_enabled)

    # 16. Bloom - Blur
    add_pass!(graph, :bloom_blur, execute_rg_bloom_blur!;
        reads=[bloom_bright],
        writes=[(bloom_blurred, 0)],
        enabled=config.bloom_enabled)

    # 17. Post-process composite (tone mapping + vignette + color grading + bloom combine)
    post_reads = RGResourceHandle[final_hdr]
    if config.bloom_enabled
        push!(post_reads, bloom_blurred)
    end
    add_pass!(graph, :post_composite, execute_rg_post_composite!;
        reads=post_reads,
        writes=[(post_output, 0)])

    # 18. FXAA
    add_pass!(graph, :fxaa, execute_rg_fxaa!;
        reads=[post_output],
        writes=[(swapchain, 0)],
        enabled=config.fxaa_enabled)

    # Sequential screen passes are chained via lightweight sequencing resources.
    # Each pass produces a "token" that the next pass reads, ensuring correct order
    # without cycles. All passes render to the default framebuffer (swapchain).

    seq_depth_done = declare_resource!(graph, :seq_depth_done, RG_R8)
    seq_transparent_done = declare_resource!(graph, :seq_transparent_done, RG_R8)
    seq_particles_done = declare_resource!(graph, :seq_particles_done, RG_R8)
    seq_ui_done = declare_resource!(graph, :seq_ui_done, RG_R8)
    seq_debug_done = declare_resource!(graph, :seq_debug_done, RG_R8)

    # 19. Depth copy
    add_pass!(graph, :depth_copy, execute_rg_depth_copy!;
        reads=[gbuf_depth, post_output],
        writes=[(seq_depth_done, 0)])

    # 20. Forward transparent
    add_pass!(graph, :forward_transparent, execute_rg_forward_transparent!;
        reads=[csm_depth, seq_depth_done],
        writes=[(seq_transparent_done, 0)])

    # 21. Particles
    add_pass!(graph, :particles, execute_rg_particles!;
        reads=[seq_transparent_done],
        writes=[(seq_particles_done, 0)])

    # 22. UI
    add_pass!(graph, :ui, execute_rg_ui!;
        reads=[seq_particles_done],
        writes=[(seq_ui_done, 0)])

    # 23. Debug draw
    add_pass!(graph, :debug_draw, execute_rg_debug_draw!;
        reads=[seq_ui_done],
        writes=[(seq_debug_done, 0)])

    # 24. Present (swap buffers) — terminal pass writing to imported swapchain
    add_pass!(graph, :present, execute_rg_present!;
        reads=[seq_debug_done],
        writes=[(swapchain, 0)])

    # Build handles struct for pass callbacks
    handles = DeferredGraphHandles(
        gbuf_albedo, gbuf_normal, gbuf_emissive, gbuf_advanced, gbuf_depth,
        csm_depth,
        lighting_hdr, lighting_composited,
        ssao_raw, ssao_blurred,
        ssr_result,
        taa_history, taa_output,
        dof_coc, dof_blur, dof_output,
        mblur_velocity, mblur_output,
        bloom_bright, bloom_blurred, post_output,
        swapchain
    )

    return (graph, handles)
end

# ---- Forward graph (simpler) ----

"""
    build_forward_render_graph!(config::PostProcessConfig) -> (RenderGraph, Nothing)

Build a simpler forward rendering graph (no G-buffer, no deferred lighting).
"""
function build_forward_render_graph!(config::PostProcessConfig)
    graph = RenderGraph()

    csm_depth = declare_resource!(graph, :csm_depth, RG_DEPTH32F,
        rg_fixed_size(1024, 1024); lifetime=RG_PERSISTENT)
    swapchain = import_resource!(graph, :swapchain, RG_RGBA8_SRGB)

    seq_fwd = declare_resource!(graph, :seq_fwd_done, RG_R8)
    seq_particles = declare_resource!(graph, :seq_particles_done, RG_R8)
    seq_ui = declare_resource!(graph, :seq_ui_done, RG_R8)
    seq_debug = declare_resource!(graph, :seq_debug_done, RG_R8)

    add_pass!(graph, :shadow_csm, execute_rg_shadow_csm!;
        writes=[(csm_depth, 0)])

    add_pass!(graph, :forward_transparent, execute_rg_forward_transparent!;
        reads=[csm_depth],
        writes=[(seq_fwd, 0)])

    add_pass!(graph, :particles, execute_rg_particles!;
        reads=[seq_fwd],
        writes=[(seq_particles, 0)])

    add_pass!(graph, :ui, execute_rg_ui!;
        reads=[seq_particles],
        writes=[(seq_ui, 0)])

    add_pass!(graph, :debug_draw, execute_rg_debug_draw!;
        reads=[seq_ui],
        writes=[(seq_debug, 0)])

    add_pass!(graph, :present, execute_rg_present!;
        reads=[seq_debug],
        writes=[(swapchain, 0)])

    return (graph, nothing)
end
