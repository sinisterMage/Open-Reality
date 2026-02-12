# Vulkan swapchain creation, recreation, and management

"""
    SwapchainSupportDetails

Holds surface capabilities, formats, and present modes for swapchain creation.
"""
struct SwapchainSupportDetails
    capabilities::SurfaceCapabilitiesKHR
    formats::Vector{SurfaceFormatKHR}
    present_modes::Vector{PresentModeKHR}
end

"""
    vk_query_swapchain_support(physical_device, surface) -> SwapchainSupportDetails
"""
function vk_query_swapchain_support(physical_device::PhysicalDevice, surface::SurfaceKHR)
    caps = unwrap(get_physical_device_surface_capabilities_khr(physical_device, surface))
    formats = unwrap(get_physical_device_surface_formats_khr(physical_device; surface=surface))
    modes = unwrap(get_physical_device_surface_present_modes_khr(physical_device; surface=surface))
    return SwapchainSupportDetails(caps, formats, modes)
end

"""
    vk_choose_surface_format(formats) -> SurfaceFormatKHR

Prefer BGRA8 SRGB. Fall back to first available.
"""
function vk_choose_surface_format(formats::Vector{SurfaceFormatKHR})
    for f in formats
        if f.format == FORMAT_B8G8R8A8_SRGB && f.color_space == COLOR_SPACE_SRGB_NONLINEAR_KHR
            return f
        end
    end
    # Fall back to BGRA8 UNORM
    for f in formats
        if f.format == FORMAT_B8G8R8A8_UNORM
            return f
        end
    end
    return formats[1]
end

"""
    vk_choose_present_mode(modes) -> PresentModeKHR

Prefer MAILBOX (low-latency triple buffering), fall back to FIFO (vsync).
"""
function vk_choose_present_mode(modes::Vector{PresentModeKHR})
    for m in modes
        if m == PRESENT_MODE_MAILBOX_KHR
            return m
        end
    end
    return PRESENT_MODE_FIFO_KHR  # guaranteed available
end

"""
    vk_choose_extent(capabilities, desired_width, desired_height) -> Extent2D

Choose swapchain extent, clamped to surface capabilities.
"""
function vk_choose_extent(caps::SurfaceCapabilitiesKHR,
                           desired_width::Integer, desired_height::Integer)
    if caps.current_extent.width != typemax(UInt32)
        return caps.current_extent
    end
    w = clamp(UInt32(desired_width), caps.min_image_extent.width, caps.max_image_extent.width)
    h = clamp(UInt32(desired_height), caps.min_image_extent.height, caps.max_image_extent.height)
    return Extent2D(w, h)
end

"""
    vk_create_swapchain!(backend) -> nothing

Create the swapchain, image views, depth resources, and present render pass.
Populates backend fields: swapchain, swapchain_images, swapchain_views,
swapchain_format, swapchain_extent, present_render_pass, swapchain_framebuffers,
depth_image, depth_memory, depth_view.
"""
function vk_create_swapchain!(backend)
    support = vk_query_swapchain_support(backend.physical_device, backend.surface)
    surface_format = vk_choose_surface_format(support.formats)
    present_mode = vk_choose_present_mode(support.present_modes)
    extent = vk_choose_extent(support.capabilities, backend.width, backend.height)

    # Request one more image than minimum for triple buffering
    image_count = support.capabilities.min_image_count + 1
    if support.capabilities.max_image_count > 0
        image_count = min(image_count, support.capabilities.max_image_count)
    end

    indices = [backend.graphics_family, backend.present_family]
    sharing_mode = backend.graphics_family == backend.present_family ?
        SHARING_MODE_EXCLUSIVE : SHARING_MODE_CONCURRENT
    queue_indices = backend.graphics_family == backend.present_family ?
        UInt32[] : indices

    swapchain_info = SwapchainCreateInfoKHR(
        backend.surface,
        image_count,
        surface_format.format,
        surface_format.color_space,
        extent,
        UInt32(1),  # array layers
        IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSFER_DST_BIT,
        sharing_mode,
        queue_indices,
        support.capabilities.current_transform,
        COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        present_mode,
        true,  # clipped
    )

    backend.swapchain = unwrap(create_swapchain_khr(backend.device, swapchain_info))
    backend.swapchain_format = surface_format.format
    backend.swapchain_extent = extent

    # Get swapchain images
    backend.swapchain_images = unwrap(get_swapchain_images_khr(backend.device, backend.swapchain))

    # Create image views
    backend.swapchain_views = ImageView[]
    for img in backend.swapchain_images
        view_info = ImageViewCreateInfo(
            img,
            IMAGE_VIEW_TYPE_2D,
            surface_format.format,
            ComponentMapping(
                COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY
            ),
            ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(1), UInt32(0), UInt32(1))
        )
        push!(backend.swapchain_views, unwrap(create_image_view(backend.device, view_info)))
    end

    # Create depth resources
    _create_depth_resources!(backend, extent)

    # Create present render pass
    _create_present_render_pass!(backend, surface_format.format)

    # Create swapchain framebuffers
    backend.swapchain_framebuffers = VkFramebuffer[]
    for view in backend.swapchain_views
        fb_info = FramebufferCreateInfo(
            backend.present_render_pass,
            [view, backend.depth_view],
            extent.width, extent.height, UInt32(1)
        )
        push!(backend.swapchain_framebuffers, unwrap(create_framebuffer(backend.device, fb_info)))
    end

    return nothing
end

"""
    _create_depth_resources!(backend, extent)

Create depth image, memory, and view for the swapchain.
"""
function _create_depth_resources!(backend, extent::Extent2D)
    depth_format = FORMAT_D32_SFLOAT

    backend.depth_image, backend.depth_memory = vk_create_image(
        backend.device, backend.physical_device,
        extent.width, extent.height, depth_format,
        IMAGE_TILING_OPTIMAL,
        IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT
    )

    view_info = ImageViewCreateInfo(
        backend.depth_image,
        IMAGE_VIEW_TYPE_2D,
        depth_format,
        ComponentMapping(
            COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
            COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY
        ),
        ImageSubresourceRange(IMAGE_ASPECT_DEPTH_BIT, UInt32(0), UInt32(1), UInt32(0), UInt32(1))
    )
    backend.depth_view = unwrap(create_image_view(backend.device, view_info))

    return nothing
end

"""
    _create_present_render_pass!(backend, color_format)

Create the render pass for presenting to the swapchain.
"""
function _create_present_render_pass!(backend, color_format::Format)
    color_attachment = AttachmentDescription(
        color_format,
        SAMPLE_COUNT_1_BIT,
        ATTACHMENT_LOAD_OP_CLEAR,
        ATTACHMENT_STORE_OP_STORE,
        ATTACHMENT_LOAD_OP_DONT_CARE,
        ATTACHMENT_STORE_OP_DONT_CARE,
        IMAGE_LAYOUT_UNDEFINED,
        IMAGE_LAYOUT_PRESENT_SRC_KHR
    )

    depth_attachment = AttachmentDescription(
        FORMAT_D32_SFLOAT,
        SAMPLE_COUNT_1_BIT,
        ATTACHMENT_LOAD_OP_CLEAR,
        ATTACHMENT_STORE_OP_DONT_CARE,
        ATTACHMENT_LOAD_OP_DONT_CARE,
        ATTACHMENT_STORE_OP_DONT_CARE,
        IMAGE_LAYOUT_UNDEFINED,
        IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    )

    color_ref = AttachmentReference(UInt32(0), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    depth_ref = AttachmentReference(UInt32(1), IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)

    subpass = SubpassDescription(
        PIPELINE_BIND_POINT_GRAPHICS,
        [],          # input attachments
        [color_ref], # color attachments
        [];          # resolve attachments
        depth_stencil_attachment=depth_ref
    )

    dependency = SubpassDependency(
        VK_SUBPASS_EXTERNAL, UInt32(0),
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        AccessFlag(0),
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT | ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        DependencyFlag(0)
    )

    rp_info = RenderPassCreateInfo(
        [color_attachment, depth_attachment],
        [subpass],
        [dependency]
    )

    backend.present_render_pass = unwrap(create_render_pass(backend.device, rp_info))
    return nothing
end

"""
    vk_destroy_swapchain_resources!(backend)

Destroy swapchain framebuffers, image views, depth resources, and render pass.
Does NOT destroy the swapchain itself.
"""
function vk_destroy_swapchain_resources!(backend)
    unwrap(device_wait_idle(backend.device))

    for fb in backend.swapchain_framebuffers
        finalize(fb)
    end
    empty!(backend.swapchain_framebuffers)

    for view in backend.swapchain_views
        finalize(view)
    end
    empty!(backend.swapchain_views)

    if backend.depth_view !== nothing
        finalize(backend.depth_view)
        backend.depth_view = nothing
    end
    if backend.depth_image !== nothing
        finalize(backend.depth_image)
        backend.depth_image = nothing
    end
    if backend.depth_memory !== nothing
        finalize(backend.depth_memory)
        backend.depth_memory = nothing
    end

    if backend.present_render_pass !== nothing
        finalize(backend.present_render_pass)
        backend.present_render_pass = nothing
    end

    return nothing
end

"""
    vk_recreate_swapchain!(backend)

Recreate the swapchain after a window resize or suboptimal present.
"""
function vk_recreate_swapchain!(backend)
    # Wait for window to have non-zero size (handles minimization)
    w, h = Int(0), Int(0)
    while w == 0 || h == 0
        w_ref, h_ref = Ref{Cint}(0), Ref{Cint}(0)
        ccall((:glfwGetFramebufferSize, GLFW.libglfw), Cvoid,
              (GLFW.Window, Ptr{Cint}, Ptr{Cint}), backend.window.handle, w_ref, h_ref)
        w, h = Int(w_ref[]), Int(h_ref[])
        w == 0 && h == 0 && GLFW.WaitEvents()
    end
    backend.width = w
    backend.height = h

    unwrap(device_wait_idle(backend.device))

    # Destroy old resources
    vk_destroy_swapchain_resources!(backend)

    old_swapchain = backend.swapchain

    # Destroy old render_finished semaphores (sized per swapchain image)
    for sem in backend.render_finished_semaphores
        finalize(sem)
    end
    empty!(backend.render_finished_semaphores)

    # Recreate
    vk_create_swapchain!(backend)

    # Create new render_finished semaphores matching new swapchain image count
    for _ in 1:length(backend.swapchain_images)
        push!(backend.render_finished_semaphores,
            unwrap(create_semaphore(backend.device, SemaphoreCreateInfo())))
    end

    # Destroy old swapchain
    if old_swapchain !== nothing
        finalize(old_swapchain)
    end

    backend.framebuffer_resized = false
    @info "Vulkan swapchain recreated" width=w height=h
    return nothing
end
