# Vulkan texture creation, upload, and caching

"""
    vk_create_default_sampler(device; filter=FILTER_LINEAR, mipmap=true) -> Sampler

Create a default texture sampler with linear filtering and repeat wrapping.
"""
function vk_create_default_sampler(device::Device; filter::Filter=FILTER_LINEAR,
                                    mipmap::Bool=true, anisotropy::Bool=true)
    sampler_info = SamplerCreateInfo(
        filter, filter,  # mag, min
        mipmap ? SAMPLER_MIPMAP_MODE_LINEAR : SAMPLER_MIPMAP_MODE_NEAREST,
        SAMPLER_ADDRESS_MODE_REPEAT,
        SAMPLER_ADDRESS_MODE_REPEAT,
        SAMPLER_ADDRESS_MODE_REPEAT,
        0.0f0,    # mip_lod_bias
        anisotropy,
        anisotropy ? 16.0f0 : 1.0f0,
        false,    # compare_enable
        COMPARE_OP_ALWAYS,
        0.0f0,    # min_lod
        mipmap ? 16.0f0 : 0.0f0,  # max_lod
        BORDER_COLOR_FLOAT_OPAQUE_BLACK,
        false     # unnormalized_coordinates
    )
    return unwrap(create_sampler(device, sampler_info))
end

"""
    vk_create_shadow_sampler(device) -> Sampler

Create a sampler for shadow map depth textures with comparison.
"""
function vk_create_shadow_sampler(device::Device)
    sampler_info = SamplerCreateInfo(
        FILTER_LINEAR, FILTER_LINEAR,
        SAMPLER_MIPMAP_MODE_NEAREST,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        0.0f0, false, 1.0f0,
        true,  # compare_enable
        COMPARE_OP_LESS,
        0.0f0, 1.0f0,
        BORDER_COLOR_FLOAT_OPAQUE_WHITE,
        false
    )
    return unwrap(create_sampler(device, sampler_info))
end

"""
    vk_upload_texture(device, physical_device, cmd_pool, queue, pixels, width, height, channels;
                      format=nothing, generate_mipmaps=true) -> VulkanGPUTexture

Upload pixel data to a GPU texture with optional mipmap generation.
"""
function vk_upload_texture(device::Device, physical_device::PhysicalDevice,
                            command_pool::CommandPool, queue::Queue,
                            pixels::Vector{UInt8}, width::Int, height::Int, channels::Int;
                            format::Union{Format, Nothing}=nothing,
                            generate_mipmaps::Bool=true)
    if format === nothing
        format = channels == 4 ? FORMAT_R8G8B8A8_SRGB : FORMAT_R8G8B8A8_SRGB
    end

    # Convert 3-channel to 4-channel if needed
    actual_pixels = if channels == 3
        rgba = Vector{UInt8}(undef, width * height * 4)
        for i in 0:(width * height - 1)
            rgba[4i + 1] = pixels[3i + 1]
            rgba[4i + 2] = pixels[3i + 2]
            rgba[4i + 3] = pixels[3i + 3]
            rgba[4i + 4] = 0xFF
        end
        rgba
    else
        pixels
    end

    mip_levels = generate_mipmaps ? UInt32(floor(log2(max(width, height)))) + UInt32(1) : UInt32(1)

    # Create image
    image, memory = vk_create_image(
        device, physical_device, width, height, format,
        IMAGE_TILING_OPTIMAL,
        IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT | IMAGE_USAGE_SAMPLED_BIT,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        mip_levels=mip_levels
    )

    # Create staging buffer
    buffer_size = width * height * 4
    staging_buf, staging_mem = vk_create_buffer(
        device, physical_device, buffer_size,
        BUFFER_USAGE_TRANSFER_SRC_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
    )
    ptr = unwrap(map_memory(device, staging_mem, UInt64(0), UInt64(buffer_size)))
    GC.@preserve actual_pixels begin
        unsafe_copyto!(Ptr{UInt8}(ptr), pointer(actual_pixels), buffer_size)
    end
    unmap_memory(device, staging_mem)

    # Transition + copy + generate mipmaps
    cmd = vk_begin_single_time_commands(device, command_pool)

    transition_image_layout!(cmd, image, IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                              mip_levels=mip_levels)

    region = BufferImageCopy(
        UInt64(0), UInt32(0), UInt32(0),
        ImageSubresourceLayers(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(0), UInt32(1)),
        Offset3D(0, 0, 0),
        Extent3D(UInt32(width), UInt32(height), UInt32(1))
    )
    cmd_copy_buffer_to_image(cmd, staging_buf, image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, [region])

    # Generate mipmaps via blit chain
    if generate_mipmaps && mip_levels > 1
        _generate_mipmaps!(cmd, image, format, width, height, mip_levels)
    else
        transition_image_layout!(cmd, image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                  IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; mip_levels=mip_levels)
    end

    vk_end_single_time_commands(device, command_pool, queue, cmd)

    # Cleanup staging (use finalize to properly deregister GC finalizer)
    finalize(staging_buf)
    finalize(staging_mem)

    # Create image view
    view_info = ImageViewCreateInfo(
        image, IMAGE_VIEW_TYPE_2D, format,
        ComponentMapping(COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                         COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY),
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), mip_levels, UInt32(0), UInt32(1))
    )
    view = unwrap(create_image_view(device, view_info))

    # Create sampler
    sampler = vk_create_default_sampler(device)

    return VulkanGPUTexture(image, memory, view, sampler, width, height, 4, format,
                             IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
end

"""
    _generate_mipmaps!(cmd, image, format, width, height, mip_levels)

Generate mipmaps using vkCmdBlitImage.
Each mip level is transitioned individually.
"""
function _generate_mipmaps!(cmd::CommandBuffer, image::Image, format::Format,
                             width::Integer, height::Integer, mip_levels::Integer)
    mip_width = Int32(width)
    mip_height = Int32(height)

    for i in 1:(mip_levels - 1)
        # Transition level i-1 from TRANSFER_DST to TRANSFER_SRC
        barrier = ImageMemoryBarrier(
            C_NULL,
            ACCESS_TRANSFER_WRITE_BIT, ACCESS_TRANSFER_READ_BIT,
            IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
            image,
            ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(i - 1), UInt32(1), UInt32(0), UInt32(1))
        )
        cmd_pipeline_barrier(cmd, [], [], [barrier];
                              src_stage_mask=PIPELINE_STAGE_TRANSFER_BIT, dst_stage_mask=PIPELINE_STAGE_TRANSFER_BIT,
                              dependency_flags=DependencyFlag(0))

        next_width = max(Int32(1), mip_width ÷ Int32(2))
        next_height = max(Int32(1), mip_height ÷ Int32(2))

        blit = ImageBlit(
            ImageSubresourceLayers(IMAGE_ASPECT_COLOR_BIT, UInt32(i - 1), UInt32(0), UInt32(1)),
            (Offset3D(0, 0, 0), Offset3D(mip_width, mip_height, 1)),
            ImageSubresourceLayers(IMAGE_ASPECT_COLOR_BIT, UInt32(i), UInt32(0), UInt32(1)),
            (Offset3D(0, 0, 0), Offset3D(next_width, next_height, 1))
        )
        cmd_blit_image(cmd, image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                        image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                        [blit], FILTER_LINEAR)

        # Transition level i-1 to SHADER_READ_ONLY
        barrier2 = ImageMemoryBarrier(
            C_NULL,
            ACCESS_TRANSFER_READ_BIT, ACCESS_SHADER_READ_BIT,
            IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
            image,
            ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(i - 1), UInt32(1), UInt32(0), UInt32(1))
        )
        cmd_pipeline_barrier(cmd, [], [], [barrier2];
                              src_stage_mask=PIPELINE_STAGE_TRANSFER_BIT, dst_stage_mask=PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                              dependency_flags=DependencyFlag(0))

        mip_width = next_width
        mip_height = next_height
    end

    # Transition last mip level
    last_barrier = ImageMemoryBarrier(
        C_NULL,
        ACCESS_TRANSFER_WRITE_BIT, ACCESS_SHADER_READ_BIT,
        IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
        image,
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(mip_levels - 1), UInt32(1), UInt32(0), UInt32(1))
    )
    cmd_pipeline_barrier(cmd, [], [], [last_barrier];
                          src_stage_mask=PIPELINE_STAGE_TRANSFER_BIT, dst_stage_mask=PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                          dependency_flags=DependencyFlag(0))
    return nothing
end

"""
    vk_load_texture(cache, device, physical_device, cmd_pool, queue, path) -> VulkanGPUTexture

Load a texture from file, with caching.
"""
function vk_load_texture(cache::VulkanTextureCache, device::Device,
                          physical_device::PhysicalDevice, command_pool::CommandPool,
                          queue::Queue, path::String)
    if haskey(cache.textures, path)
        return cache.textures[path]
    end

    img = FileIO.load(path)
    h, w = size(img)

    # Detect alpha channel
    has_alpha = eltype(img) <: ColorTypes.TransparentColor
    channels = has_alpha ? 4 : 3

    # Convert to row-major UInt8 array (flip vertically for Vulkan's top-left origin)
    pixel_count = w * h
    num_channels = has_alpha ? 4 : 3
    pixels = Vector{UInt8}(undef, pixel_count * num_channels)

    idx = 1
    for row in 1:h  # top to bottom (Vulkan convention)
        for col in 1:w
            c = img[row, col]
            pixels[idx] = round(UInt8, clamp(ColorTypes.red(c) * 255, 0, 255))
            pixels[idx + 1] = round(UInt8, clamp(ColorTypes.green(c) * 255, 0, 255))
            pixels[idx + 2] = round(UInt8, clamp(ColorTypes.blue(c) * 255, 0, 255))
            if has_alpha
                pixels[idx + 3] = round(UInt8, clamp(ColorTypes.alpha(c) * 255, 0, 255))
            end
            idx += num_channels
        end
    end

    tex = vk_upload_texture(device, physical_device, command_pool, queue,
                             pixels, w, h, channels)
    cache.textures[path] = tex
    return tex
end

"""
    vk_destroy_texture!(device, texture)

Destroy a VulkanGPUTexture and free its resources.
"""
function vk_destroy_texture!(device::Device, texture::VulkanGPUTexture)
    finalize(texture.sampler)
    finalize(texture.view)
    finalize(texture.image)
    finalize(texture.memory)
    return nothing
end

"""
    vk_destroy_all_textures!(device, cache)

Destroy all cached textures.
"""
function vk_destroy_all_textures!(device::Device, cache::VulkanTextureCache)
    for (_, tex) in cache.textures
        vk_destroy_texture!(device, tex)
    end
    empty!(cache.textures)
    return nothing
end

"""
    vk_create_render_target_texture(device, physical_device, width, height, format;
                                     aspect=IMAGE_ASPECT_COLOR_BIT, usage=nothing) -> VulkanGPUTexture

Create a texture suitable for use as a render target (color or depth).
"""
function vk_create_render_target_texture(device::Device, physical_device::PhysicalDevice,
                                          width::Integer, height::Integer, format::Format;
                                          aspect::ImageAspectFlag=IMAGE_ASPECT_COLOR_BIT,
                                          usage::Union{ImageUsageFlag, Nothing}=nothing,
                                          initial_layout::ImageLayout=IMAGE_LAYOUT_UNDEFINED)
    is_depth = (aspect & IMAGE_ASPECT_DEPTH_BIT) != ImageAspectFlag(0)

    if usage === nothing
        usage = if is_depth
            IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT
        else
            IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT
        end
    end

    image, memory = vk_create_image(
        device, physical_device, width, height, format,
        IMAGE_TILING_OPTIMAL, usage,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT
    )

    view_info = ImageViewCreateInfo(
        image, IMAGE_VIEW_TYPE_2D, format,
        ComponentMapping(COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                         COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY),
        ImageSubresourceRange(aspect, UInt32(0), UInt32(1), UInt32(0), UInt32(1))
    )
    view = unwrap(create_image_view(device, view_info))

    sampler = vk_create_default_sampler(device; mipmap=false)

    channels = is_depth ? 1 : 4

    return VulkanGPUTexture(image, memory, view, sampler, Int(width), Int(height),
                             channels, format, initial_layout)
end

"""
    _vk_create_default_cubemap(device, physical_device, command_pool, queue) -> VulkanGPUTexture

Create a 1x1 black cubemap texture (6 faces) for use as a placeholder in samplerCube bindings.
The image is transitioned to SHADER_READ_ONLY_OPTIMAL layout.
"""
function _vk_create_default_cubemap(device::Device, physical_device::PhysicalDevice,
                                     command_pool::CommandPool, queue::Queue)
    format = FORMAT_R8G8B8A8_UNORM

    # Create cubemap image (6 array layers + CUBE_COMPATIBLE)
    image, memory = vk_create_image(
        device, physical_device, 1, 1, format,
        IMAGE_TILING_OPTIMAL,
        IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_SAMPLED_BIT,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        array_layers=6,
        flags=IMAGE_CREATE_CUBE_COMPATIBLE_BIT
    )

    # Upload black pixels to all 6 faces via staging buffer
    face_data = UInt8[0x00, 0x00, 0x00, 0xFF]
    staging_size = 4 * 6
    staging_buf, staging_mem = vk_create_buffer(
        device, physical_device, staging_size,
        BUFFER_USAGE_TRANSFER_SRC_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
    )

    data_ptr = unwrap(map_memory(device, staging_mem, UInt64(0), UInt64(staging_size)))
    for face in 0:5
        unsafe_copyto!(Ptr{UInt8}(data_ptr) + 4 * face, pointer(face_data), 4)
    end
    unmap_memory(device, staging_mem)

    # Record copy commands
    cmd_info = CommandBufferAllocateInfo(command_pool, COMMAND_BUFFER_LEVEL_PRIMARY, UInt32(1))
    cmd = unwrap(allocate_command_buffers(device, cmd_info))[1]
    unwrap(begin_command_buffer(cmd, CommandBufferBeginInfo(flags=COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)))

    # Transition UNDEFINED → TRANSFER_DST
    barrier = ImageMemoryBarrier(
        C_NULL,
        AccessFlag(0), ACCESS_TRANSFER_WRITE_BIT,
        IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
        image,
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(1), UInt32(0), UInt32(6))
    )
    cmd_pipeline_barrier(cmd, [], [], [barrier];
        src_stage_mask=PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        dst_stage_mask=PIPELINE_STAGE_TRANSFER_BIT,
        dependency_flags=DependencyFlag(0))

    # Copy staging buffer to each face
    regions = [BufferImageCopy(
        UInt64(4 * face), UInt32(0), UInt32(0),
        ImageSubresourceLayers(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(face), UInt32(1)),
        Offset3D(0, 0, 0),
        Extent3D(UInt32(1), UInt32(1), UInt32(1))
    ) for face in 0:5]

    cmd_copy_buffer_to_image(cmd, staging_buf, image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, regions)

    # Transition TRANSFER_DST → SHADER_READ_ONLY
    barrier2 = ImageMemoryBarrier(
        C_NULL,
        ACCESS_TRANSFER_WRITE_BIT, ACCESS_SHADER_READ_BIT,
        IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
        image,
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(1), UInt32(0), UInt32(6))
    )
    cmd_pipeline_barrier(cmd, [], [], [barrier2];
        src_stage_mask=PIPELINE_STAGE_TRANSFER_BIT,
        dst_stage_mask=PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        dependency_flags=DependencyFlag(0))

    unwrap(end_command_buffer(cmd))
    unwrap(queue_submit(queue, [SubmitInfo([], [], [cmd], [])]))
    unwrap(queue_wait_idle(queue))
    free_command_buffers(device, command_pool, [cmd])

    finalize(staging_buf)
    finalize(staging_mem)

    # Cube image view
    cube_view = unwrap(create_image_view(device, ImageViewCreateInfo(
        image, IMAGE_VIEW_TYPE_CUBE, format,
        ComponentMapping(COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                         COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY),
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(1), UInt32(0), UInt32(6))
    )))

    sampler = unwrap(create_sampler(device, SamplerCreateInfo(
        FILTER_LINEAR, FILTER_LINEAR,
        SAMPLER_MIPMAP_MODE_NEAREST,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        0.0f0, false, 1.0f0, false, COMPARE_OP_ALWAYS,
        0.0f0, 0.0f0,
        BORDER_COLOR_FLOAT_OPAQUE_BLACK, false
    )))

    return VulkanGPUTexture(image, memory, cube_view, sampler, 1, 1, 4, format,
                             IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
end

"""
    _vk_transition_framebuffer_readable!(device, command_pool, queue, fb)

Transition a VulkanFramebuffer's color (and optionally depth) image from UNDEFINED
to SHADER_READ_ONLY_OPTIMAL. Call this after creating render targets that may be
sampled before any render pass writes to them.
"""
function _vk_transition_framebuffer_readable!(device::Device, command_pool::CommandPool,
                                               queue::Queue, fb::VulkanFramebuffer)
    cmd = vk_begin_single_time_commands(device, command_pool)
    transition_image_layout!(cmd, fb.color_image,
        IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
    if fb.depth_image !== nothing
        transition_image_layout!(cmd, fb.depth_image,
            IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            aspect_mask=IMAGE_ASPECT_DEPTH_BIT)
    end
    vk_end_single_time_commands(device, command_pool, queue, cmd)
    return nothing
end
