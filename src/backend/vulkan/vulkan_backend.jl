# Vulkan backend: main struct + initialize!/shutdown!/render_frame! + all backend_* methods

const VK_MAX_FRAMES_IN_FLIGHT = 2

const VK_PRESENT_FRAG = """
#version 450

layout(set = 0, binding = 0) uniform PresentUBO {
    float bloom_threshold;
    float bloom_intensity;
    float gamma;
    int tone_mapping_mode;
    int horizontal;
    float _pad1, _pad2, _pad3;
} params;

layout(set = 0, binding = 1) uniform sampler2D sceneTexture;

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 outColor;

vec3 aces(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec3 hdr = texture(sceneTexture, fragUV).rgb;
    // Tone mapping (ACES)
    vec3 mapped = aces(hdr);
    // Gamma correction
    mapped = pow(mapped, vec3(1.0 / params.gamma));
    outColor = vec4(mapped, 1.0);
}
"""

"""
    VulkanBackend <: AbstractBackend

Vulkan rendering backend for Linux/Windows.
Uses deferred rendering with PBR, CSM shadows, IBL, SSAO, SSR, TAA, and post-processing.
"""
mutable struct VulkanBackend <: AbstractBackend
    initialized::Bool
    window::Union{Window, Nothing}
    input::InputState
    width::Int
    height::Int

    # Vulkan core
    instance::Union{Instance, Nothing}
    physical_device::Union{PhysicalDevice, Nothing}
    device::Union{Device, Nothing}
    graphics_queue::Union{Queue, Nothing}
    present_queue::Union{Queue, Nothing}
    graphics_family::UInt32
    present_family::UInt32

    # Presentation
    surface::Union{SurfaceKHR, Nothing}
    swapchain::Union{SwapchainKHR, Nothing}
    swapchain_images::Vector{Image}
    swapchain_views::Vector{ImageView}
    swapchain_format::Format
    swapchain_extent::Extent2D
    swapchain_framebuffers::Vector{VkFramebuffer}
    present_render_pass::Union{RenderPass, Nothing}
    depth_image::Union{Image, Nothing}
    depth_memory::Union{DeviceMemory, Nothing}
    depth_view::Union{ImageView, Nothing}

    # Commands + sync (2 frames in flight)
    command_pool::Union{CommandPool, Nothing}
    command_buffers::Vector{CommandBuffer}
    image_available_semaphores::Vector{Semaphore}
    render_finished_semaphores::Vector{Semaphore}
    in_flight_fences::Vector{Fence}
    current_frame::Int

    # Descriptors
    descriptor_pool::Union{DescriptorPool, Nothing}
    per_frame_layout::Union{DescriptorSetLayout, Nothing}
    per_material_layout::Union{DescriptorSetLayout, Nothing}
    lighting_layout::Union{DescriptorSetLayout, Nothing}
    fullscreen_layout::Union{DescriptorSetLayout, Nothing}
    push_constant_range::Union{PushConstantRange, Nothing}

    # Per-frame descriptor sets + UBOs
    per_frame_ds::Vector{DescriptorSet}
    per_frame_ubos::Vector{Buffer}
    per_frame_ubo_mems::Vector{DeviceMemory}

    # Lighting descriptor sets + UBOs
    lighting_ds::Vector{DescriptorSet}
    light_ubos::Vector{Buffer}
    light_ubo_mems::Vector{DeviceMemory}
    shadow_ubos::Vector{Buffer}
    shadow_ubo_mems::Vector{DeviceMemory}

    # Pipelines + caches
    deferred_pipeline::Union{VulkanDeferredPipeline, Nothing}
    forward_pipeline::Union{VulkanShaderProgram, Nothing}
    gpu_cache::VulkanGPUResourceCache
    texture_cache::VulkanTextureCache
    bounds_cache::Dict{EntityID, BoundingSphere}
    csm::Union{VulkanCascadedShadowMap, Nothing}
    post_process::Union{VulkanPostProcessPipeline, Nothing}
    default_texture::Union{VulkanGPUTexture, Nothing}
    black_texture::Union{VulkanGPUTexture, Nothing}
    shadow_sampler::Union{Sampler, Nothing}

    # Per-frame transient descriptor pools (reset each frame for per-material allocations)
    transient_pools::Vector{DescriptorPool}

    # Per-frame temporary buffers (freed after fence wait at start of next frame)
    frame_temp_buffers::Vector{Vector{Tuple{Buffer, DeviceMemory}}}

    # Fullscreen quad
    quad_buffer::Union{Buffer, Nothing}
    quad_memory::Union{DeviceMemory, Nothing}

    # State
    framebuffer_resized::Bool
    use_deferred::Bool
    post_process_config::Union{PostProcessConfig, Nothing}
    present_pipeline::Union{VulkanShaderProgram, Nothing}
    debug_frame_count::Int
end

function VulkanBackend()
    VulkanBackend(
        false, nothing, InputState(), 1280, 720,
        # Vulkan core
        nothing, nothing, nothing, nothing, nothing, UInt32(0), UInt32(0),
        # Presentation
        nothing, nothing, Image[], ImageView[], FORMAT_B8G8R8A8_SRGB,
        Extent2D(1280, 720), VkFramebuffer[], nothing, nothing, nothing, nothing,
        # Commands + sync
        nothing, CommandBuffer[], Semaphore[], Semaphore[], Fence[], 1,
        # Descriptors
        nothing, nothing, nothing, nothing, nothing, nothing,
        # Per-frame
        DescriptorSet[], Buffer[], DeviceMemory[],
        # Lighting
        DescriptorSet[], Buffer[], DeviceMemory[], Buffer[], DeviceMemory[],
        # Pipelines
        nothing, nothing, VulkanGPUResourceCache(), VulkanTextureCache(),
        Dict{EntityID, BoundingSphere}(), nothing, nothing, nothing, nothing, nothing,
        # Transient pools
        DescriptorPool[],
        # Temp buffers per frame
        [Tuple{Buffer, DeviceMemory}[] for _ in 1:VK_MAX_FRAMES_IN_FLIGHT],
        # Quad
        nothing, nothing,
        # State
        false, true, nothing,
        # Present
        nothing,
        # Debug
        0
    )
end

# ==================================================================
# Core Lifecycle
# ==================================================================

function initialize!(backend::VulkanBackend; width::Int=1280, height::Int=720, title::String="OpenReality")
    backend.width = width
    backend.height = height

    # Initialize GLFW with NO_API (no OpenGL context)
    ensure_glfw_init!()
    GLFW.WindowHint(GLFW.CLIENT_API, GLFW.NO_API)

    backend.window = Window()
    backend.window.handle = GLFW.CreateWindow(width, height, title)
    backend.window.width = width
    backend.window.height = height

    # Create Vulkan instance (validation layers for debugging)
    backend.instance = vk_create_instance(; enable_validation=true)

    # Create surface
    backend.surface = vk_create_surface(backend.instance, backend.window.handle)

    # Select physical device
    backend.physical_device, indices = vk_select_physical_device(backend.instance, backend.surface)
    backend.graphics_family = indices.graphics
    backend.present_family = indices.present

    # Create logical device
    backend.device, backend.graphics_queue, backend.present_queue =
        vk_create_logical_device(backend.physical_device, indices)

    # Create swapchain
    vk_create_swapchain!(backend)

    # Create command pool and buffers
    pool_info = CommandPoolCreateInfo(backend.graphics_family;
        flags=COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT)
    backend.command_pool = unwrap(create_command_pool(backend.device, pool_info))

    alloc_info = CommandBufferAllocateInfo(
        backend.command_pool, COMMAND_BUFFER_LEVEL_PRIMARY, UInt32(VK_MAX_FRAMES_IN_FLIGHT))
    backend.command_buffers = unwrap(allocate_command_buffers(backend.device, alloc_info))

    # Create sync objects
    # image_available semaphores: per frame-in-flight (used before we know image index)
    for _ in 1:VK_MAX_FRAMES_IN_FLIGHT
        push!(backend.image_available_semaphores,
            unwrap(create_semaphore(backend.device, SemaphoreCreateInfo())))
        push!(backend.in_flight_fences,
            unwrap(create_fence(backend.device, FenceCreateInfo(; flags=FENCE_CREATE_SIGNALED_BIT))))
    end
    # render_finished semaphores: per swapchain image (presentation holds onto these)
    for _ in 1:length(backend.swapchain_images)
        push!(backend.render_finished_semaphores,
            unwrap(create_semaphore(backend.device, SemaphoreCreateInfo())))
    end

    # Create descriptor pool (persistent allocations)
    backend.descriptor_pool = vk_create_descriptor_pool(backend.device; max_sets=512)

    # Create per-frame transient descriptor pools (reset each frame)
    for _ in 1:VK_MAX_FRAMES_IN_FLIGHT
        push!(backend.transient_pools,
            vk_create_descriptor_pool(backend.device; max_sets=256))
    end

    # Create descriptor set layouts
    backend.per_frame_layout = vk_create_per_frame_layout(backend.device)
    backend.per_material_layout = vk_create_per_material_layout(backend.device)
    backend.lighting_layout = vk_create_lighting_layout(backend.device)
    backend.fullscreen_layout = vk_create_fullscreen_pass_layout(backend.device)
    backend.push_constant_range = vk_per_object_push_constant_range()

    # Create per-frame UBOs and descriptor sets
    for _ in 1:VK_MAX_FRAMES_IN_FLIGHT
        dummy_uniforms = vk_pack_per_frame(Mat4f(I), Mat4f(I), Vec3f(0, 0, 0), 0.0f0)
        ubo, mem = vk_create_uniform_buffer(backend.device, backend.physical_device, dummy_uniforms)
        push!(backend.per_frame_ubos, ubo)
        push!(backend.per_frame_ubo_mems, mem)

        ds = vk_allocate_descriptor_set(backend.device, backend.descriptor_pool, backend.per_frame_layout)
        push!(backend.per_frame_ds, ds)
        vk_update_ubo_descriptor!(backend.device, ds, 0, ubo, sizeof(dummy_uniforms))
    end

    # Create lighting UBOs and descriptor sets
    for _ in 1:VK_MAX_FRAMES_IN_FLIGHT
        # Light UBO
        light_data = FrameLightData(Vec3f[], RGB{Float32}[], Float32[], Float32[],
                                     Vec3f[], RGB{Float32}[], Float32[], false, "", 1.0f0)
        light_uniforms = vk_pack_lights(light_data)
        light_ubo, light_mem = vk_create_uniform_buffer(backend.device, backend.physical_device, light_uniforms)
        push!(backend.light_ubos, light_ubo)
        push!(backend.light_ubo_mems, light_mem)

        # Shadow UBO (placeholder)
        shadow_data = VulkanShadowUniforms(
            ntuple(_ -> ntuple(_ -> 0.0f0, 16), 4),
            ntuple(_ -> 0.0f0, 5), Int32(0), Int32(0), 0.0f0)
        shadow_ubo, shadow_mem = vk_create_uniform_buffer(backend.device, backend.physical_device, shadow_data)
        push!(backend.shadow_ubos, shadow_ubo)
        push!(backend.shadow_ubo_mems, shadow_mem)

        ds = vk_allocate_descriptor_set(backend.device, backend.descriptor_pool, backend.lighting_layout)
        push!(backend.lighting_ds, ds)
        vk_update_ubo_descriptor!(backend.device, ds, 0, light_ubo, sizeof(light_uniforms))
        vk_update_ubo_descriptor!(backend.device, ds, 1, shadow_ubo, sizeof(shadow_data))
    end

    # Create fullscreen quad
    backend.quad_buffer, backend.quad_memory = vk_create_fullscreen_quad(
        backend.device, backend.physical_device, backend.command_pool, backend.graphics_queue)

    # Create 1x1 white default texture (SSAO default = no occlusion)
    white_pixel = UInt8[0xFF, 0xFF, 0xFF, 0xFF]
    backend.default_texture = vk_upload_texture(
        backend.device, backend.physical_device, backend.command_pool, backend.graphics_queue,
        white_pixel, 1, 1, 4; format=FORMAT_R8G8B8A8_UNORM, generate_mipmaps=false)

    # Create 1x1 black texture (SSR default = no reflections, alpha=0 prevents SSR contribution)
    black_pixel = UInt8[0x00, 0x00, 0x00, 0x00]
    backend.black_texture = vk_upload_texture(
        backend.device, backend.physical_device, backend.command_pool, backend.graphics_queue,
        black_pixel, 1, 1, 4; format=FORMAT_R8G8B8A8_UNORM, generate_mipmaps=false)

    # Fill lighting descriptor set unused bindings with default texture
    for i in 1:VK_MAX_FRAMES_IN_FLIGHT
        for binding in 2:8  # CSM cascades (2-5) + IBL (6-8)
            vk_update_texture_descriptor!(backend.device, backend.lighting_ds[i],
                binding, backend.default_texture)
        end
    end

    # Create shadow sampler
    backend.shadow_sampler = vk_create_shadow_sampler(backend.device)

    # Create deferred pipeline
    backend.post_process_config = PostProcessConfig()
    backend.deferred_pipeline = vk_create_deferred_pipeline(
        backend.device, backend.physical_device, backend.command_pool, backend.graphics_queue,
        width, height,
        backend.per_frame_layout, backend.per_material_layout, backend.lighting_layout,
        backend.fullscreen_layout, backend.descriptor_pool, backend.push_constant_range,
        backend.post_process_config)

    # Create post-processing pipeline
    backend.post_process = vk_create_post_process(
        backend.device, backend.physical_device, width, height,
        backend.post_process_config, backend.fullscreen_layout, backend.descriptor_pool)

    # Create present pipeline (tone maps and blits deferred result to swapchain)
    backend.present_pipeline = vk_compile_and_create_pipeline(
        backend.device, VK_FULLSCREEN_QUAD_VERT, VK_PRESENT_FRAG,
        VulkanPipelineConfig(
            backend.present_render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [backend.fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    # Setup input callbacks
    setup_input_callbacks!(backend.window, backend.input)

    # Setup resize callback
    GLFW.SetFramebufferSizeCallback(backend.window.handle, (_, w, h) -> begin
        backend.framebuffer_resized = true
        backend.width = Int(w)
        backend.height = Int(h)
    end)

    backend.initialized = true
    @info "Vulkan backend initialized" width height
    return nothing
end

function shutdown!(backend::VulkanBackend)
    !backend.initialized && return

    unwrap(device_wait_idle(backend.device))

    # Destroy present pipeline
    if backend.present_pipeline !== nothing
        finalize(backend.present_pipeline.pipeline)
        finalize(backend.present_pipeline.pipeline_layout)
        backend.present_pipeline.vert_module !== nothing && finalize(backend.present_pipeline.vert_module)
        backend.present_pipeline.frag_module !== nothing && finalize(backend.present_pipeline.frag_module)
    end

    # Destroy post-processing
    if backend.post_process !== nothing
        vk_destroy_post_process!(backend.device, backend.post_process)
    end

    # Destroy deferred pipeline
    if backend.deferred_pipeline !== nothing
        vk_destroy_deferred_pipeline!(backend.device, backend.deferred_pipeline)
    end

    # Destroy CSM
    if backend.csm !== nothing
        vk_destroy_csm!(backend.device, backend.csm)
    end

    # Destroy forward pipeline
    if backend.forward_pipeline !== nothing
        finalize(backend.forward_pipeline.pipeline)
        finalize(backend.forward_pipeline.pipeline_layout)
    end

    # Destroy default textures + shadow sampler
    if backend.default_texture !== nothing
        vk_destroy_texture!(backend.device, backend.default_texture)
    end
    if backend.black_texture !== nothing
        vk_destroy_texture!(backend.device, backend.black_texture)
    end
    if backend.shadow_sampler !== nothing
        finalize(backend.shadow_sampler)
    end

    # Destroy caches
    vk_destroy_all_meshes!(backend.device, backend.gpu_cache)
    vk_destroy_all_textures!(backend.device, backend.texture_cache)

    # Destroy per-frame UBOs
    for i in 1:VK_MAX_FRAMES_IN_FLIGHT
        finalize(backend.per_frame_ubos[i])
        finalize(backend.per_frame_ubo_mems[i])
        finalize(backend.light_ubos[i])
        finalize(backend.light_ubo_mems[i])
        finalize(backend.shadow_ubos[i])
        finalize(backend.shadow_ubo_mems[i])
    end

    # Destroy temp buffers
    for frame_bufs in backend.frame_temp_buffers
        for (buf, mem) in frame_bufs
            finalize(buf)
            finalize(mem)
        end
        empty!(frame_bufs)
    end

    # Destroy quad
    if backend.quad_buffer !== nothing
        finalize(backend.quad_buffer)
        finalize(backend.quad_memory)
    end

    # Destroy descriptor set layouts
    for layout in [backend.per_frame_layout, backend.per_material_layout,
                   backend.lighting_layout, backend.fullscreen_layout]
        layout !== nothing && finalize(layout)
    end

    # Destroy descriptor pools
    for pool in backend.transient_pools
        finalize(pool)
    end
    backend.descriptor_pool !== nothing && finalize(backend.descriptor_pool)

    # Destroy sync objects
    for i in 1:VK_MAX_FRAMES_IN_FLIGHT
        finalize(backend.image_available_semaphores[i])
        finalize(backend.in_flight_fences[i])
    end
    for sem in backend.render_finished_semaphores
        finalize(sem)
    end

    # Destroy command pool
    backend.command_pool !== nothing && finalize(backend.command_pool)

    # Destroy pipeline cache
    vk_destroy_all_cached_pipelines!(backend.device)

    # Destroy swapchain resources
    vk_destroy_swapchain_resources!(backend)
    backend.swapchain !== nothing && finalize(backend.swapchain)

    # Destroy surface, device, instance
    backend.surface !== nothing && finalize(backend.surface)
    # Device and instance are finalized by Vulkan.jl GC

    # Destroy window
    if backend.window !== nothing && backend.window.handle !== nothing
        GLFW.DestroyWindow(backend.window.handle)
    end

    backend.initialized = false
    @info "Vulkan backend shut down"
    return nothing
end

# ==================================================================
# Render Frame
# ==================================================================

function render_frame!(backend::VulkanBackend, scene::Scene)
    !backend.initialized && return

    # Wait for the current frame's fence
    frame_idx = backend.current_frame
    unwrap(wait_for_fences(backend.device, [backend.in_flight_fences[frame_idx]], true, typemax(UInt64)))

    # Free temporary buffers from this frame's previous use (GPU is done with them now)
    for (buf, mem) in backend.frame_temp_buffers[frame_idx]
        finalize(buf)
        finalize(mem)
    end
    empty!(backend.frame_temp_buffers[frame_idx])

    # Acquire next swapchain image
    result = acquire_next_image_khr(backend.device, backend.swapchain, typemax(UInt64);
                                     semaphore=backend.image_available_semaphores[frame_idx])
    if iserror(result)
        err = unwrap_error(result)
        if err.code == ERROR_OUT_OF_DATE_KHR
            vk_recreate_swapchain!(backend)
            return
        end
        error("Failed to acquire swapchain image: $err")
    end
    image_index_raw, _ = unwrap(result)
    image_index = Int(image_index_raw) + 1  # 0-indexed → 1-indexed

    unwrap(reset_fences(backend.device, [backend.in_flight_fences[frame_idx]]))

    # Reset the transient descriptor pool for this frame
    unwrap(reset_descriptor_pool(backend.device, backend.transient_pools[frame_idx]))

    # Prepare frame data (backend-agnostic, parallel when threading enabled)
    frame_data = threading_enabled() ?
        prepare_frame_parallel(scene, backend.bounds_cache) :
        prepare_frame(scene, backend.bounds_cache)
    if frame_data === nothing
        # No camera — submit empty frame
        _submit_empty_frame!(backend, frame_idx, image_index)
        return
    end

    # Reset and begin command buffer
    cmd = backend.command_buffers[frame_idx]
    unwrap(reset_command_buffer(cmd))
    unwrap(begin_command_buffer(cmd, CommandBufferBeginInfo()))

    # Flip Y for Vulkan's Y-down NDC (OpenGL projection has Y-up)
    proj = frame_data.proj
    vk_proj = Mat4f(
        proj[1], proj[2], proj[3], proj[4],
        proj[5], -proj[6], proj[7], proj[8],
        proj[9], proj[10], proj[11], proj[12],
        proj[13], proj[14], proj[15], proj[16]
    )

    # Update per-frame UBO
    per_frame_uniforms = vk_pack_per_frame(frame_data.view, vk_proj,
                                             frame_data.cam_pos, Float32(backend_get_time(backend)))
    vk_upload_struct_data!(backend.device, backend.per_frame_ubo_mems[frame_idx], per_frame_uniforms)

    # Update lighting UBOs
    light_uniforms = vk_pack_lights(frame_data.lights)
    vk_upload_struct_data!(backend.device, backend.light_ubo_mems[frame_idx], light_uniforms)

    # Update shadow UBOs
    has_shadows = backend.csm !== nothing && frame_data.primary_light_dir !== nothing
    if has_shadows
        shadow_uniforms = vk_pack_shadow_uniforms(backend.csm, true)
        vk_upload_struct_data!(backend.device, backend.shadow_ubo_mems[frame_idx], shadow_uniforms)
    end

    w = Int(backend.swapchain_extent.width)
    h = Int(backend.swapchain_extent.height)

    # --- Shadow pass ---
    if has_shadows && backend.csm !== nothing
        vk_render_csm_passes!(cmd, backend, backend.csm,
            frame_data.view, vk_proj, frame_data.primary_light_dir)
    end

    # --- G-Buffer pass ---
    if backend.deferred_pipeline !== nothing && backend.deferred_pipeline.gbuffer !== nothing
        _render_gbuffer_pass!(cmd, backend, frame_data, frame_idx, w, h)
    end

    # --- Deferred lighting pass ---
    if backend.deferred_pipeline !== nothing && backend.deferred_pipeline.lighting_target !== nothing
        _render_lighting_pass!(cmd, backend, frame_data, frame_idx, w, h)
    end

    # --- Present pass (blit to swapchain) ---
    _render_present_pass!(cmd, backend, image_index, frame_idx, w, h)

    # End command buffer
    unwrap(end_command_buffer(cmd))

    # Submit (render_finished semaphore indexed by swapchain image to avoid reuse conflicts)
    submit_info = SubmitInfo(
        [backend.image_available_semaphores[frame_idx]],
        [PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT],
        [cmd],
        [backend.render_finished_semaphores[image_index]]
    )
    unwrap(queue_submit(backend.graphics_queue, [submit_info];
                         fence=backend.in_flight_fences[frame_idx]))

    # Present
    present_result = queue_present_khr(backend.present_queue,
        PresentInfoKHR(
            [backend.render_finished_semaphores[image_index]],
            [backend.swapchain],
            [UInt32(image_index - 1)]  # 1-indexed → 0-indexed
        ))

    if iserror(present_result)
        err = unwrap_error(present_result)
        if err.code == ERROR_OUT_OF_DATE_KHR || err.code == SUBOPTIMAL_KHR || backend.framebuffer_resized
            vk_recreate_swapchain!(backend)
        end
    elseif backend.framebuffer_resized
        vk_recreate_swapchain!(backend)
    end

    # Advance frame
    backend.current_frame = (frame_idx % VK_MAX_FRAMES_IN_FLIGHT) + 1
    return nothing
end

# ==================================================================
# Internal render helpers
# ==================================================================

function _submit_empty_frame!(backend::VulkanBackend, frame_idx::Int, image_index::Int)
    cmd = backend.command_buffers[frame_idx]
    unwrap(reset_command_buffer(cmd))
    unwrap(begin_command_buffer(cmd, CommandBufferBeginInfo()))

    # Clear the swapchain image
    w = Int(backend.swapchain_extent.width)
    h = Int(backend.swapchain_extent.height)

    clear_values = [
        ClearValue(ClearColorValue((0.1f0, 0.1f0, 0.1f0, 1.0f0))),
        ClearValue(ClearDepthStencilValue(1.0f0, UInt32(0)))
    ]
    rp_begin = RenderPassBeginInfo(
        backend.present_render_pass,
        backend.swapchain_framebuffers[image_index],
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(w), UInt32(h))),
        clear_values
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)
    cmd_end_render_pass(cmd)

    unwrap(end_command_buffer(cmd))

    submit_info = SubmitInfo(
        [backend.image_available_semaphores[frame_idx]],
        [PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT],
        [cmd],
        [backend.render_finished_semaphores[image_index]]
    )
    unwrap(queue_submit(backend.graphics_queue, [submit_info];
                         fence=backend.in_flight_fences[frame_idx]))
    queue_present_khr(backend.present_queue,
        PresentInfoKHR(
            [backend.render_finished_semaphores[image_index]],
            [backend.swapchain],
            [UInt32(image_index - 1)]
        ))
    backend.current_frame = (frame_idx % VK_MAX_FRAMES_IN_FLIGHT) + 1
end

function _render_gbuffer_pass!(cmd::CommandBuffer, backend::VulkanBackend,
                                frame_data::FrameData, frame_idx::Int,
                                width::Int, height::Int)
    dp = backend.deferred_pipeline
    gb = dp.gbuffer

    clear_values = [
        ClearValue(ClearColorValue((0.0f0, 0.0f0, 0.0f0, 0.0f0))),  # albedo+metallic
        ClearValue(ClearColorValue((0.5f0, 0.5f0, 1.0f0, 0.0f0))),  # normal+roughness (default up normal)
        ClearValue(ClearColorValue((0.0f0, 0.0f0, 0.0f0, 1.0f0))),  # emissive+AO
        ClearValue(ClearColorValue((0.0f0, 0.0f0, 0.0f0, 1.0f0))),  # advanced material
        ClearValue(ClearDepthStencilValue(1.0f0, UInt32(0))),        # depth
    ]

    rp_begin = RenderPassBeginInfo(
        gb.render_pass, gb.framebuffer,
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height))),
        clear_values
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)

    cmd_set_viewport(cmd,
        [Viewport(0.0f0, 0.0f0, Float32(width), Float32(height), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd,
        [Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height)))])

    # Render each opaque entity
    for entity_data in frame_data.opaque_entities
        eid = entity_data.entity_id
        mesh = entity_data.mesh

        # Get material and determine shader variant
        material = get_component(eid, MaterialComponent)
        if material === nothing
            material = MaterialComponent()
        end

        variant_key = determine_shader_variant(material)
        shader = get_or_compile_variant!(dp.gbuffer_shader_library, variant_key)

        # Bind pipeline
        cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, shader.pipeline)

        # Bind per-frame descriptor set (set 0)
        cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS, shader.pipeline_layout,
            UInt32(0), [backend.per_frame_ds[frame_idx]], UInt32[])

        # Allocate and update per-material descriptor set (set 1) from transient pool
        mat_ds = vk_allocate_descriptor_set(backend.device,
            backend.transient_pools[frame_idx], backend.per_material_layout)
        mat_uniforms = vk_pack_material(material)
        mat_ubo, mat_mem = vk_create_uniform_buffer(backend.device, backend.physical_device, mat_uniforms)
        vk_update_ubo_descriptor!(backend.device, mat_ds, 0, mat_ubo, sizeof(mat_uniforms))
        vk_bind_material_textures!(backend.device, mat_ds, material, backend.texture_cache,
                                    backend.physical_device, backend.command_pool,
                                    backend.graphics_queue, backend.default_texture)
        cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS, shader.pipeline_layout,
            UInt32(1), [mat_ds], UInt32[])

        # Push constants (per-object)
        push_data = vk_pack_per_object(entity_data.model, entity_data.normal_matrix)
        push_ref = Ref(push_data)
        GC.@preserve push_ref cmd_push_constants(cmd, shader.pipeline_layout,
            SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
            UInt32(0), UInt32(sizeof(push_data)),
            Base.unsafe_convert(Ptr{Cvoid}, Base.cconvert(Ptr{Cvoid}, push_ref)))

        # Draw mesh
        gpu_mesh = vk_get_or_upload_mesh!(backend.gpu_cache, backend.device,
            backend.physical_device, backend.command_pool, backend.graphics_queue,
            eid, mesh)
        vk_bind_and_draw_mesh!(cmd, gpu_mesh)

        # Defer UBO cleanup until after GPU finishes (freed at start of next frame after fence wait)
        push!(backend.frame_temp_buffers[frame_idx], (mat_ubo, mat_mem))
    end

    cmd_end_render_pass(cmd)
end

function _render_lighting_pass!(cmd::CommandBuffer, backend::VulkanBackend,
                                 frame_data::FrameData, frame_idx::Int,
                                 width::Int, height::Int)
    dp = backend.deferred_pipeline
    lt = dp.lighting_target

    clear_values = [ClearValue(ClearColorValue((0.0f0, 0.0f0, 0.0f0, 1.0f0)))]

    rp_begin = RenderPassBeginInfo(
        lt.render_pass, lt.framebuffer,
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height))),
        clear_values
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)

    cmd_set_viewport(cmd,
        [Viewport(0.0f0, 0.0f0, Float32(width), Float32(height), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd,
        [Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height)))])

    if dp.lighting_pipeline !== nothing
        cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, dp.lighting_pipeline.pipeline)

        # Bind G-buffer textures + per-frame UBO to fullscreen pass descriptor set
        lighting_ds = vk_allocate_descriptor_set(backend.device,
            backend.transient_pools[frame_idx], backend.fullscreen_layout)

        # Binding 0: Per-frame UBO
        vk_update_ubo_descriptor!(backend.device, lighting_ds, 0,
            backend.per_frame_ubos[frame_idx], sizeof(VulkanPerFrameUniforms))

        gb = dp.gbuffer
        # Bindings 1-5: G-buffer textures
        vk_update_texture_descriptor!(backend.device, lighting_ds, 1, gb.albedo_metallic)
        vk_update_texture_descriptor!(backend.device, lighting_ds, 2, gb.normal_roughness)
        vk_update_texture_descriptor!(backend.device, lighting_ds, 3, gb.emissive_ao)
        vk_update_texture_descriptor!(backend.device, lighting_ds, 4, gb.advanced_material)
        vk_update_texture_descriptor!(backend.device, lighting_ds, 5, gb.depth)

        # Binding 6: SSAO (white = no occlusion)
        vk_update_texture_descriptor!(backend.device, lighting_ds, 6, backend.default_texture)
        # Binding 7: SSR (black/alpha=0 = no reflections)
        vk_update_texture_descriptor!(backend.device, lighting_ds, 7, backend.black_texture)
        # Binding 8: unused
        vk_update_texture_descriptor!(backend.device, lighting_ds, 8, backend.default_texture)

        cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS, dp.lighting_pipeline.pipeline_layout,
            UInt32(0), [lighting_ds, backend.lighting_ds[frame_idx]], UInt32[])

        vk_draw_fullscreen_quad!(cmd, backend.quad_buffer)
    end

    cmd_end_render_pass(cmd)
end

function _render_present_pass!(cmd::CommandBuffer, backend::VulkanBackend,
                                image_index::Int, frame_idx::Int,
                                width::Int, height::Int)
    clear_values = [
        ClearValue(ClearColorValue((0.0f0, 0.0f0, 0.0f0, 1.0f0))),
        ClearValue(ClearDepthStencilValue(1.0f0, UInt32(0)))
    ]

    rp_begin = RenderPassBeginInfo(
        backend.present_render_pass,
        backend.swapchain_framebuffers[image_index],
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height))),
        clear_values
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)

    cmd_set_viewport(cmd,
        [Viewport(0.0f0, 0.0f0, Float32(width), Float32(height), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd,
        [Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height)))])

    # Draw deferred lighting result to swapchain with tone mapping
    if backend.present_pipeline !== nothing && backend.deferred_pipeline !== nothing &&
       backend.deferred_pipeline.lighting_target !== nothing
        dp = backend.deferred_pipeline

        cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, backend.present_pipeline.pipeline)

        # Allocate descriptor set from transient pool
        present_ds = vk_allocate_descriptor_set(backend.device,
            backend.transient_pools[frame_idx], backend.fullscreen_layout)

        # Binding 0: Present pass UBO (post-process params matching PresentUBO layout)
        pp = backend.post_process_config !== nothing ? backend.post_process_config : PostProcessConfig()
        present_uniforms = VulkanPostProcessUniforms(
            pp.bloom_threshold, pp.bloom_intensity, pp.gamma,
            Int32(pp.tone_mapping), Int32(0),
            0.0f0, 0.0f0, 0.0f0
        )
        present_ubo, present_mem = vk_create_uniform_buffer(
            backend.device, backend.physical_device, present_uniforms)
        push!(backend.frame_temp_buffers[frame_idx], (present_ubo, present_mem))
        vk_update_ubo_descriptor!(backend.device, present_ds, 0,
            present_ubo, sizeof(VulkanPostProcessUniforms))

        # Binding 1: deferred lighting result texture
        vk_update_image_sampler_descriptor!(backend.device, present_ds, 1,
            dp.lighting_target.color_view, backend.default_texture.sampler)

        # Fill unused bindings 2-8 with default texture to avoid validation errors
        for bind_idx in 2:8
            vk_update_texture_descriptor!(backend.device, present_ds, bind_idx, backend.default_texture)
        end

        cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS,
            backend.present_pipeline.pipeline_layout,
            UInt32(0), [present_ds], UInt32[])

        vk_draw_fullscreen_quad!(cmd, backend.quad_buffer)
    end

    cmd_end_render_pass(cmd)
end

# ==================================================================
# backend_* Method Implementations
# ==================================================================

# ---- Shader operations ----

function backend_create_shader(backend::VulkanBackend, vertex_src::String, fragment_src::String)
    return vk_compile_and_create_pipeline(backend.device, vertex_src, fragment_src,
        VulkanPipelineConfig(
            backend.present_render_pass, UInt32(0),
            vk_standard_vertex_bindings(), vk_standard_vertex_attributes(),
            [backend.per_frame_layout, backend.per_material_layout, backend.lighting_layout],
            [backend.push_constant_range],
            false, true, true,
            CULL_MODE_BACK_BIT, FRONT_FACE_CLOCKWISE,
            1, backend.width, backend.height
        ))
end

function backend_destroy_shader!(backend::VulkanBackend, shader::VulkanShaderProgram)
    finalize(shader.pipeline)
    finalize(shader.pipeline_layout)
    shader.vert_module !== nothing && finalize(shader.vert_module)
    shader.frag_module !== nothing && finalize(shader.frag_module)
    return nothing
end

function backend_use_shader!(backend::VulkanBackend, shader::VulkanShaderProgram)
    # In Vulkan, pipeline binding happens in the command buffer, not globally.
    # This is a no-op — pipelines are bound during render passes.
    return nothing
end

function backend_set_uniform!(backend::VulkanBackend, shader::VulkanShaderProgram, name::String, value)
    # In Vulkan, uniforms are set via UBOs and push constants, not per-name.
    # This is a no-op for the Vulkan backend.
    return nothing
end

# ---- Mesh operations ----

function backend_upload_mesh!(backend::VulkanBackend, entity_id, mesh)
    return vk_upload_mesh!(backend.gpu_cache, backend.device, backend.physical_device,
                            backend.command_pool, backend.graphics_queue, entity_id, mesh)
end

function backend_draw_mesh!(backend::VulkanBackend, gpu_mesh::VulkanGPUMesh)
    # Draw calls happen within command buffers during render passes.
    # This standalone method is not directly usable in Vulkan.
    return nothing
end

function backend_destroy_mesh!(backend::VulkanBackend, gpu_mesh::VulkanGPUMesh)
    vk_destroy_mesh!(backend.device, gpu_mesh)
    return nothing
end

# ---- Texture operations ----

function backend_upload_texture!(backend::VulkanBackend, pixels::Vector{UInt8},
                                  width::Int, height::Int, channels::Int)
    return vk_upload_texture(backend.device, backend.physical_device,
                              backend.command_pool, backend.graphics_queue,
                              pixels, width, height, channels)
end

function backend_bind_texture!(backend::VulkanBackend, texture::VulkanGPUTexture, unit::Int)
    # In Vulkan, textures are bound via descriptor sets, not texture units.
    return nothing
end

function backend_destroy_texture!(backend::VulkanBackend, texture::VulkanGPUTexture)
    vk_destroy_texture!(backend.device, texture)
    return nothing
end

# ---- Framebuffer operations ----

function backend_create_framebuffer!(backend::VulkanBackend, width::Int, height::Int)
    return vk_create_render_target(backend.device, backend.physical_device, width, height)
end

function backend_bind_framebuffer!(backend::VulkanBackend, fb::VulkanFramebuffer)
    # In Vulkan, framebuffers are bound via render passes in command buffers.
    return nothing
end

function backend_unbind_framebuffer!(backend::VulkanBackend)
    return nothing
end

function backend_destroy_framebuffer!(backend::VulkanBackend, fb::VulkanFramebuffer)
    vk_destroy_render_target!(backend.device, fb)
    return nothing
end

# ---- G-Buffer operations ----

function backend_create_gbuffer!(backend::VulkanBackend, width::Int, height::Int)
    return vk_create_gbuffer(backend.device, backend.physical_device, width, height)
end

# ---- Shadow map operations ----

function backend_create_shadow_map!(backend::VulkanBackend, width::Int, height::Int)
    fb, rp, depth_tex = vk_create_depth_only_render_target(backend.device, backend.physical_device, width, height)
    return VulkanShadowMap(fb, rp, depth_tex, width, height)
end

function backend_create_csm!(backend::VulkanBackend, num_cascades::Int, resolution::Int,
                               near::Float32, far::Float32)
    csm = vk_create_csm(backend.device, backend.physical_device, num_cascades, resolution, near, far)

    # Create depth pipeline for CSM
    csm.depth_pipeline = vk_create_shadow_depth_pipeline(
        backend.device, csm,
        [backend.per_frame_layout],
        backend.push_constant_range)

    # Bind CSM depth textures to lighting descriptor sets
    for i in 1:VK_MAX_FRAMES_IN_FLIGHT
        for c in 1:min(num_cascades, VK_MAX_CSM_CASCADES)
            vk_update_image_sampler_descriptor!(
                backend.device, backend.lighting_ds[i], 1 + c,
                csm.cascade_depth_textures[c].view,
                backend.shadow_sampler)
        end
    end

    backend.csm = csm
    return csm
end

# ---- IBL operations ----

function backend_create_ibl_environment!(backend::VulkanBackend, path::String, intensity::Float32)
    ibl = vk_create_ibl_environment(backend.device, backend.physical_device,
                                     backend.command_pool, backend.graphics_queue,
                                     path, intensity)

    # Bind IBL textures to lighting descriptor sets
    for i in 1:VK_MAX_FRAMES_IN_FLIGHT
        vk_update_texture_descriptor!(backend.device, backend.lighting_ds[i], 6, ibl.irradiance_map)
        vk_update_texture_descriptor!(backend.device, backend.lighting_ds[i], 7, ibl.prefilter_map)
        vk_update_texture_descriptor!(backend.device, backend.lighting_ds[i], 8, ibl.brdf_lut)
    end

    if backend.deferred_pipeline !== nothing
        backend.deferred_pipeline.ibl_env = ibl
    end
    return ibl
end

# ---- Screen-space effect operations ----

function backend_create_ssr_pass!(backend::VulkanBackend, width::Int, height::Int)
    return vk_create_ssr_pass(backend.device, backend.physical_device, width, height,
                               backend.fullscreen_layout, backend.descriptor_pool)
end

function backend_create_ssao_pass!(backend::VulkanBackend, width::Int, height::Int)
    return vk_create_ssao_pass(backend.device, backend.physical_device,
                                backend.command_pool, backend.graphics_queue,
                                width, height, backend.fullscreen_layout, backend.descriptor_pool)
end

function backend_create_taa_pass!(backend::VulkanBackend, width::Int, height::Int)
    return vk_create_taa_pass(backend.device, backend.physical_device, width, height,
                               backend.fullscreen_layout, backend.descriptor_pool)
end

# ---- Post-processing operations ----

function backend_create_post_process!(backend::VulkanBackend, width::Int, height::Int, config)
    pp_config = config isa PostProcessConfig ? config : PostProcessConfig()
    return vk_create_post_process(backend.device, backend.physical_device, width, height,
                                   pp_config, backend.fullscreen_layout, backend.descriptor_pool)
end

# ---- Render state operations ----
# In Vulkan, most of these are set per-pipeline or per-render-pass, not globally.

function backend_set_viewport!(backend::VulkanBackend, x::Int, y::Int, width::Int, height::Int)
    return nothing  # Set within command buffers
end

function backend_clear!(backend::VulkanBackend; color::Bool=true, depth::Bool=true)
    return nothing  # Handled by render pass load ops
end

function backend_set_depth_test!(backend::VulkanBackend; enabled::Bool=true, write::Bool=true)
    return nothing  # Set per-pipeline
end

function backend_set_blend!(backend::VulkanBackend; enabled::Bool=false)
    return nothing  # Set per-pipeline
end

function backend_set_cull_face!(backend::VulkanBackend; enabled::Bool=true, front::Bool=false)
    return nothing  # Set per-pipeline
end

function backend_swap_buffers!(backend::VulkanBackend)
    return nothing  # Handled by queue_present_khr in render_frame!
end

function backend_draw_fullscreen_quad!(backend::VulkanBackend, quad_handle)
    return nothing  # Called within command buffers
end

function backend_blit_framebuffer!(backend::VulkanBackend, src, dst, width::Int, height::Int;
                                    color::Bool=false, depth::Bool=false)
    return nothing  # Handled via image blit commands in render passes
end

# ---- Windowing / event loop operations ----

function backend_should_close(backend::VulkanBackend)
    backend.window === nothing && return true
    return GLFW.WindowShouldClose(backend.window.handle)
end

function backend_poll_events!(backend::VulkanBackend)
    GLFW.PollEvents()
    return nothing
end

function backend_get_time(backend::VulkanBackend)
    return get_time()
end

function backend_capture_cursor!(backend::VulkanBackend)
    backend.window === nothing && return
    capture_cursor!(backend.window)
    return nothing
end

function backend_release_cursor!(backend::VulkanBackend)
    backend.window === nothing && return
    release_cursor!(backend.window)
    return nothing
end

function backend_is_key_pressed(backend::VulkanBackend, key)
    return is_key_pressed(backend.input, key)
end

function backend_get_input(backend::VulkanBackend)
    return backend.input
end
