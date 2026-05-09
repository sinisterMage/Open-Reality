# Vulkan framebuffer capture for visual regression testing
# Mirrors src/backend/opengl/opengl_capture.jl so visual tests can target
# either backend. Reads the most recently presented swapchain image into a
# Matrix{RGBA{Float32}} suitable for FileIO.save() and image-diff comparison.

"""
    vk_capture_framebuffer(backend::VulkanBackend; width, height) -> Matrix{RGBA{Float32}}

Read back the contents of the most recently presented swapchain image. Returns a
`(height x width)` matrix of `RGBA{Float32}` pixels in standard image orientation
(top-left origin). Vulkan's NDC is already Y-down so no vertical flip is needed.

This call performs a `device_wait_idle` to ensure the GPU has finished rendering
the captured frame, and uses a one-shot command buffer to copy the swapchain
image into a host-visible staging buffer. It is intended for testing — not for
the hot rendering path.

If the swapchain uses a BGRA format (the common case on Linux/Windows) the
channels are swizzled to RGBA before being returned.
"""
function vk_capture_framebuffer(backend::VulkanBackend;
                                 width::Int=Int(backend.swapchain_extent.width),
                                 height::Int=Int(backend.swapchain_extent.height))
    backend.initialized || error("Vulkan backend not initialized")
    isempty(backend.swapchain_images) && error("Vulkan swapchain has no images to capture")

    # Wait for all GPU work to settle so the image we read is consistent.
    unwrap(device_wait_idle(backend.device))

    src_image = backend.swapchain_images[backend.current_image_index]

    # Host-visible staging buffer, sized for tightly packed RGBA8.
    buffer_size = width * height * 4
    staging_buffer, staging_mem = vk_create_buffer(
        backend.device, backend.physical_device, UInt64(buffer_size),
        BUFFER_USAGE_TRANSFER_DST_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
    )

    cmd = vk_begin_single_time_commands(backend.device, backend.command_pool)

    transition_image_layout!(cmd, src_image,
        IMAGE_LAYOUT_PRESENT_SRC_KHR, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)

    region = BufferImageCopy(
        UInt64(0), UInt32(0), UInt32(0),
        ImageSubresourceLayers(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(0), UInt32(1)),
        Offset3D(0, 0, 0),
        Extent3D(UInt32(width), UInt32(height), UInt32(1))
    )
    cmd_copy_image_to_buffer(cmd, src_image,
        IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging_buffer, [region])

    transition_image_layout!(cmd, src_image,
        IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, IMAGE_LAYOUT_PRESENT_SRC_KHR)

    vk_end_single_time_commands(backend.device, backend.command_pool,
        backend.graphics_queue, cmd)

    # Read pixels back from host-visible memory.
    pixels = Vector{UInt8}(undef, buffer_size)
    ptr = unwrap(map_memory(backend.device, staging_mem, UInt64(0), UInt64(buffer_size)))
    GC.@preserve pixels begin
        unsafe_copyto!(pointer(pixels), Ptr{UInt8}(ptr), buffer_size)
    end
    unmap_memory(backend.device, staging_mem)

    finalize(staging_buffer)
    finalize(staging_mem)

    is_bgra = backend.swapchain_format == FORMAT_B8G8R8A8_SRGB ||
              backend.swapchain_format == FORMAT_B8G8R8A8_UNORM

    img = Matrix{RGBA{Float32}}(undef, height, width)
    for row in 1:height
        for col in 1:width
            offset = ((row - 1) * width + (col - 1)) * 4
            if is_bgra
                b = Float32(pixels[offset + 1]) / 255.0f0
                g = Float32(pixels[offset + 2]) / 255.0f0
                r = Float32(pixels[offset + 3]) / 255.0f0
                a = Float32(pixels[offset + 4]) / 255.0f0
            else
                r = Float32(pixels[offset + 1]) / 255.0f0
                g = Float32(pixels[offset + 2]) / 255.0f0
                b = Float32(pixels[offset + 3]) / 255.0f0
                a = Float32(pixels[offset + 4]) / 255.0f0
            end
            img[row, col] = RGBA{Float32}(r, g, b, a)
        end
    end

    return img
end

# Multi-backend dispatch — keeps the existing OpenGL `capture_framebuffer(w, h)`
# overload working while letting tests pass an explicit backend instance.

"""
    capture_framebuffer(backend::VulkanBackend, width, height) -> Matrix{RGBA{Float32}}

Backend-dispatched form of [`capture_framebuffer`](@ref). Equivalent to
`vk_capture_framebuffer(backend; width=width, height=height)`.
"""
function capture_framebuffer(backend::VulkanBackend, width::Int, height::Int)
    return vk_capture_framebuffer(backend; width=width, height=height)
end
