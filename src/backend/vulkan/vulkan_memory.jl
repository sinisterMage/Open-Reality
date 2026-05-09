# Vulkan memory allocation helpers
# Provides utility functions for buffer/image creation with proper memory binding.

"""
    find_memory_type(physical_device, type_filter, properties) -> UInt32

Find a memory type index that satisfies the type filter and has the required properties.
"""
function find_memory_type(physical_device::PhysicalDevice, type_filter::UInt32,
                          properties::MemoryPropertyFlag)
    mem_props = get_physical_device_memory_properties(physical_device)
    for i in 0:(mem_props.memory_type_count - 1)
        if (type_filter & (UInt32(1) << i)) != 0
            mem_type = mem_props.memory_types[i + 1]
            if (mem_type.property_flags & properties) == properties
                return UInt32(i)
            end
        end
    end
    error("Failed to find suitable Vulkan memory type for filter=$type_filter properties=$properties")
end

"""
    vk_create_buffer(device, physical_device, size, usage, properties) -> (Buffer, DeviceMemory)

Create a Vulkan buffer with bound device memory.
"""
function vk_create_buffer(device::Device, physical_device::PhysicalDevice,
                          size::Integer, usage::BufferUsageFlag,
                          properties::MemoryPropertyFlag)
    buffer_info = BufferCreateInfo(
        UInt64(size),
        usage,
        SHARING_MODE_EXCLUSIVE,
        UInt32[]
    )
    buffer = unwrap(create_buffer(device, buffer_info))

    mem_req = get_buffer_memory_requirements(device, buffer)
    mem_type_idx = find_memory_type(physical_device, mem_req.memory_type_bits, properties)

    alloc_info = MemoryAllocateInfo(mem_req.size, mem_type_idx)
    memory = unwrap(allocate_memory(device, alloc_info))

    unwrap(bind_buffer_memory(device, buffer, memory, UInt64(0)))
    return buffer, memory
end

"""
    vk_create_image(device, physical_device, width, height, format, tiling, usage, properties;
                    mip_levels=1, array_layers=1, flags=ImageCreateFlag(0)) -> (Image, DeviceMemory)

Create a Vulkan image with bound device memory.
"""
function vk_create_image(device::Device, physical_device::PhysicalDevice,
                         width::Integer, height::Integer, format::Format,
                         tiling::ImageTiling, usage::ImageUsageFlag,
                         properties::MemoryPropertyFlag;
                         mip_levels::Integer=1, array_layers::Integer=1,
                         flags::ImageCreateFlag=ImageCreateFlag(0),
                         image_type::ImageType=IMAGE_TYPE_2D,
                         samples::SampleCountFlag=SAMPLE_COUNT_1_BIT)
    image_info = ImageCreateInfo(
        image_type,
        format,
        Extent3D(UInt32(width), UInt32(height), UInt32(1)),
        UInt32(mip_levels),
        UInt32(array_layers),
        samples,
        tiling,
        usage,
        SHARING_MODE_EXCLUSIVE,
        UInt32[],
        IMAGE_LAYOUT_UNDEFINED;
        flags=flags
    )
    image = unwrap(create_image(device, image_info))

    mem_req = get_image_memory_requirements(device, image)
    mem_type_idx = find_memory_type(physical_device, mem_req.memory_type_bits, properties)

    alloc_info = MemoryAllocateInfo(mem_req.size, mem_type_idx)
    memory = unwrap(allocate_memory(device, alloc_info))

    unwrap(bind_image_memory(device, image, memory, UInt64(0)))
    return image, memory
end

"""
    vk_upload_buffer_data!(device, memory, data::Vector, offset=0)

Map device memory, copy data, and unmap.
"""
function vk_upload_buffer_data!(device::Device, memory::DeviceMemory,
                                data::Vector, offset::Integer=0)
    size = sizeof(data)
    ptr = unwrap(map_memory(device, memory, UInt64(offset), UInt64(size)))
    GC.@preserve data begin
        unsafe_copyto!(Ptr{UInt8}(ptr), Ptr{UInt8}(pointer(data)), size)
    end
    unmap_memory(device, memory)
    return nothing
end

"""
    vk_upload_struct_data!(device, memory, data_ref, offset=0)

Map device memory, copy a struct, and unmap.
"""
function vk_upload_struct_data!(device::Device, memory::DeviceMemory,
                                data, offset::Integer=0)
    size = sizeof(typeof(data))
    ptr = unwrap(map_memory(device, memory, UInt64(offset), UInt64(size)))
    data_ref = Ref(data)
    GC.@preserve data_ref begin
        src_ptr = Base.unsafe_convert(Ptr{UInt8}, Base.unsafe_convert(Ptr{typeof(data)}, data_ref))
        unsafe_copyto!(Ptr{UInt8}(ptr), src_ptr, size)
    end
    unmap_memory(device, memory)
    return nothing
end

"""
    vk_create_staging_buffer(device, physical_device, data::Vector) -> (Buffer, DeviceMemory)

Create a host-visible staging buffer and upload data to it.
"""
function vk_create_staging_buffer(device::Device, physical_device::PhysicalDevice,
                                  data::Vector)
    size = sizeof(data)
    buffer, memory = vk_create_buffer(
        device, physical_device, size,
        BUFFER_USAGE_TRANSFER_SRC_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
    )
    vk_upload_buffer_data!(device, memory, data)
    return buffer, memory
end

"""
    transition_image_layout!(cmd, image, old_layout, new_layout;
                             aspect_mask, mip_levels, array_layers)

Insert a pipeline barrier to transition an image's layout.
"""
function transition_image_layout!(cmd::CommandBuffer, image::Image,
                                  old_layout::ImageLayout, new_layout::ImageLayout;
                                  aspect_mask::ImageAspectFlag=IMAGE_ASPECT_COLOR_BIT,
                                  mip_levels::Integer=1, array_layers::Integer=1)
    # Determine access masks and pipeline stages based on transition
    src_access = AccessFlag(0)
    dst_access = AccessFlag(0)
    src_stage = PIPELINE_STAGE_TOP_OF_PIPE_BIT
    dst_stage = PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT

    if old_layout == IMAGE_LAYOUT_UNDEFINED && new_layout == IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        dst_access = ACCESS_TRANSFER_WRITE_BIT
        src_stage = PIPELINE_STAGE_TOP_OF_PIPE_BIT
        dst_stage = PIPELINE_STAGE_TRANSFER_BIT
    elseif old_layout == IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL && new_layout == IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        src_access = ACCESS_TRANSFER_WRITE_BIT
        dst_access = ACCESS_SHADER_READ_BIT
        src_stage = PIPELINE_STAGE_TRANSFER_BIT
        dst_stage = PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    elseif old_layout == IMAGE_LAYOUT_UNDEFINED && new_layout == IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        dst_access = ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
        src_stage = PIPELINE_STAGE_TOP_OF_PIPE_BIT
        dst_stage = PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT
    elseif old_layout == IMAGE_LAYOUT_UNDEFINED && new_layout == IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        dst_access = ACCESS_COLOR_ATTACHMENT_WRITE_BIT
        src_stage = PIPELINE_STAGE_TOP_OF_PIPE_BIT
        dst_stage = PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
    elseif old_layout == IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL && new_layout == IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        src_access = ACCESS_COLOR_ATTACHMENT_WRITE_BIT
        dst_access = ACCESS_SHADER_READ_BIT
        src_stage = PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        dst_stage = PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    elseif old_layout == IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL && new_layout == IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        src_access = ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
        dst_access = ACCESS_SHADER_READ_BIT
        src_stage = PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT
        dst_stage = PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    elseif old_layout == IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL && new_layout == IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        src_access = ACCESS_SHADER_READ_BIT
        dst_access = ACCESS_COLOR_ATTACHMENT_WRITE_BIT
        src_stage = PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        dst_stage = PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
    elseif old_layout == IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL && new_layout == IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        src_access = ACCESS_SHADER_READ_BIT
        dst_access = ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
        src_stage = PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        dst_stage = PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT
    elseif old_layout == IMAGE_LAYOUT_UNDEFINED && new_layout == IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        dst_access = ACCESS_SHADER_READ_BIT
        src_stage = PIPELINE_STAGE_TOP_OF_PIPE_BIT
        dst_stage = PIPELINE_STAGE_FRAGMENT_SHADER_BIT
    elseif old_layout == IMAGE_LAYOUT_PRESENT_SRC_KHR && new_layout == IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        # Capture path: read just-presented swapchain image into a staging buffer.
        src_access = AccessFlag(0)
        dst_access = ACCESS_TRANSFER_READ_BIT
        src_stage = PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
        dst_stage = PIPELINE_STAGE_TRANSFER_BIT
    elseif old_layout == IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL && new_layout == IMAGE_LAYOUT_PRESENT_SRC_KHR
        # Capture path: hand the swapchain image back to the presentation engine.
        src_access = ACCESS_TRANSFER_READ_BIT
        dst_access = AccessFlag(0)
        src_stage = PIPELINE_STAGE_TRANSFER_BIT
        dst_stage = PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
    else
        @warn "Unhandled image layout transition" old_layout new_layout
    end

    barrier = ImageMemoryBarrier(
        C_NULL,
        src_access, dst_access,
        old_layout, new_layout,
        QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
        image,
        ImageSubresourceRange(aspect_mask, UInt32(0), UInt32(mip_levels), UInt32(0), UInt32(array_layers))
    )

    cmd_pipeline_barrier(cmd, [], [], [barrier];
                         src_stage_mask=src_stage, dst_stage_mask=dst_stage,
                         dependency_flags=DependencyFlag(0))
    return nothing
end

"""
    vk_begin_single_time_commands(device, command_pool) -> CommandBuffer

Begin a single-use command buffer for one-time operations (staging uploads, layout transitions).
"""
function vk_begin_single_time_commands(device::Device, command_pool::CommandPool)
    alloc_info = CommandBufferAllocateInfo(command_pool, COMMAND_BUFFER_LEVEL_PRIMARY, UInt32(1))
    cmd_buffers = unwrap(allocate_command_buffers(device, alloc_info))
    cmd = cmd_buffers[1]
    begin_info = CommandBufferBeginInfo(; flags=COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)
    unwrap(begin_command_buffer(cmd, begin_info))
    return cmd
end

"""
    vk_end_single_time_commands(device, command_pool, queue, cmd)

End recording, submit, and wait for a single-use command buffer.
"""
function vk_end_single_time_commands(device::Device, command_pool::CommandPool,
                                     queue::Queue, cmd::CommandBuffer)
    unwrap(end_command_buffer(cmd))
    submit_info = SubmitInfo([], [], [cmd], [])
    unwrap(queue_submit(queue, [submit_info]))
    unwrap(queue_wait_idle(queue))
    free_command_buffers(device, command_pool, [cmd])
    return nothing
end

"""
    vk_copy_buffer!(device, command_pool, queue, src, dst, size)

Copy data from one buffer to another using a single-time command buffer.
"""
function vk_copy_buffer!(device::Device, command_pool::CommandPool,
                          queue::Queue, src::Buffer, dst::Buffer, size::Integer)
    cmd = vk_begin_single_time_commands(device, command_pool)
    region = BufferCopy(UInt64(0), UInt64(0), UInt64(size))
    cmd_copy_buffer(cmd, src, dst, [region])
    vk_end_single_time_commands(device, command_pool, queue, cmd)
    return nothing
end
