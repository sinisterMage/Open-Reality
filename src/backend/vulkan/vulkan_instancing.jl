# Vulkan instanced rendering — instance buffer management and draw commands

const VK_INSTANCE_FLOATS_PER_INSTANCE = 25  # mat4 (16) + mat3 (9)
const VK_INSTANCE_STRIDE = VK_INSTANCE_FLOATS_PER_INSTANCE * sizeof(Float32)  # 100 bytes

"""
    VulkanInstanceBuffer

Manages a re-usable host-visible Vulkan buffer for per-instance data
(model matrix + normal matrix). Re-uploaded each frame.
"""
mutable struct VulkanInstanceBuffer
    buffer::Union{Buffer, Nothing}
    memory::Union{DeviceMemory, Nothing}
    capacity::Int  # max instances currently allocated
end

VulkanInstanceBuffer() = VulkanInstanceBuffer(nothing, nothing, 0)

"""
    vk_pack_instance_data(models, normals) -> Vector{Float32}

Pack model matrices (mat4, column-major) and normal matrices (mat3, column-major)
into a flat Float32 array for upload to the instance buffer.
"""
function vk_pack_instance_data(models::Vector{Mat4f},
                                normals::Vector{SMatrix{3, 3, Float32, 9}})
    count = length(models)
    data = Vector{Float32}(undef, count * VK_INSTANCE_FLOATS_PER_INSTANCE)

    for i in 1:count
        base = (i - 1) * VK_INSTANCE_FLOATS_PER_INSTANCE
        m = models[i]
        # mat4 column-major (Julia matrices are column-major)
        for col in 1:4, row in 1:4
            data[base + (col-1)*4 + row] = m[row, col]
        end
        n = normals[i]
        # mat3 column-major
        for col in 1:3, row in 1:3
            data[base + 16 + (col-1)*3 + row] = n[row, col]
        end
    end
    return data
end

"""
    vk_upload_instance_data!(device, physical_device, inst_buf, models, normals) -> Buffer

Upload instance data to the instance buffer, growing if necessary.
Returns the buffer handle for binding.
"""
function vk_upload_instance_data!(device::Device, physical_device::PhysicalDevice,
                                   inst_buf::VulkanInstanceBuffer,
                                   models::Vector{Mat4f},
                                   normals::Vector{SMatrix{3, 3, Float32, 9}})
    count = length(models)
    count == 0 && return inst_buf.buffer

    data = vk_pack_instance_data(models, normals)
    byte_size = count * VK_INSTANCE_STRIDE

    # Grow buffer if needed
    if count > inst_buf.capacity
        # Destroy old buffer
        if inst_buf.buffer !== nothing
            finalize(inst_buf.buffer)
            finalize(inst_buf.memory)
        end
        new_capacity = max(count, inst_buf.capacity * 2, 16)
        alloc_size = new_capacity * VK_INSTANCE_STRIDE
        inst_buf.buffer, inst_buf.memory = vk_create_buffer(
            device, physical_device, alloc_size,
            BUFFER_USAGE_VERTEX_BUFFER_BIT,
            MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
        )
        inst_buf.capacity = new_capacity
    end

    # Upload data
    ptr = unwrap(map_memory(device, inst_buf.memory, UInt64(0), UInt64(byte_size)))
    GC.@preserve data begin
        unsafe_copyto!(Ptr{UInt8}(ptr), Ptr{UInt8}(pointer(data)), byte_size)
    end
    unmap_memory(device, inst_buf.memory)

    return inst_buf.buffer
end

"""
    vk_bind_and_draw_instanced!(cmd, gpu_mesh, instance_buffer, instance_count)

Bind mesh vertex buffers + instance buffer and issue an instanced indexed draw call.
"""
function vk_bind_and_draw_instanced!(cmd::CommandBuffer, gpu_mesh::VulkanGPUMesh,
                                      instance_buffer::Buffer, instance_count::Int)
    cmd_bind_vertex_buffers(cmd,
        [gpu_mesh.vertex_buffer, gpu_mesh.normal_buffer, gpu_mesh.uv_buffer, instance_buffer],
        [UInt64(0), UInt64(0), UInt64(0), UInt64(0)]
    )
    cmd_bind_index_buffer(cmd, gpu_mesh.index_buffer, UInt64(0), INDEX_TYPE_UINT32)
    cmd_draw_indexed(cmd, UInt32(gpu_mesh.index_count), UInt32(instance_count),
                     UInt32(0), Int32(0), UInt32(0))
    return nothing
end

"""
    vk_destroy_instance_buffer!(device, inst_buf)

Destroy the instance buffer and free its memory.
"""
function vk_destroy_instance_buffer!(device::Device, inst_buf::VulkanInstanceBuffer)
    if inst_buf.buffer !== nothing
        finalize(inst_buf.buffer)
        finalize(inst_buf.memory)
        inst_buf.buffer = nothing
        inst_buf.memory = nothing
        inst_buf.capacity = 0
    end
    return nothing
end
