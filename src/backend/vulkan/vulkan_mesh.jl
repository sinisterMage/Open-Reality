# Vulkan mesh upload and draw commands

"""
    vk_upload_mesh!(cache, device, physical_device, command_pool, queue, entity_id, mesh) -> VulkanGPUMesh

Upload mesh data to GPU via staging buffers.
Vertex layout: binding 0 = positions, binding 1 = normals, binding 2 = UVs.
"""
function vk_upload_mesh!(cache::VulkanGPUResourceCache, device::Device,
                          physical_device::PhysicalDevice, command_pool::CommandPool,
                          queue::Queue, entity_id::EntityID, mesh::MeshComponent)
    # Check cache
    if haskey(cache.meshes, entity_id)
        return cache.meshes[entity_id]
    end

    # Upload positions
    pos_data = reinterpret(Float32, mesh.vertices)
    pos_size = sizeof(pos_data)
    vertex_buffer, vertex_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        Vector{UInt8}(reinterpret(UInt8, pos_data)), pos_size,
        BUFFER_USAGE_VERTEX_BUFFER_BIT
    )

    # Upload normals
    norm_data = reinterpret(Float32, mesh.normals)
    norm_size = sizeof(norm_data)
    normal_buffer, normal_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        Vector{UInt8}(reinterpret(UInt8, norm_data)), norm_size,
        BUFFER_USAGE_VERTEX_BUFFER_BIT
    )

    # Upload UVs
    uv_data = reinterpret(Float32, mesh.uvs)
    uv_size = sizeof(uv_data)
    uv_buffer, uv_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        Vector{UInt8}(reinterpret(UInt8, uv_data)), uv_size,
        BUFFER_USAGE_VERTEX_BUFFER_BIT
    )

    # Upload indices
    idx_data = mesh.indices
    idx_size = sizeof(idx_data)
    index_buffer, index_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        Vector{UInt8}(reinterpret(UInt8, idx_data)), idx_size,
        BUFFER_USAGE_INDEX_BUFFER_BIT
    )

    # Upload bone weights and indices (if available for skeletal animation)
    bone_weight_buf = nothing
    bone_weight_mem = nothing
    bone_index_buf = nothing
    bone_index_mem = nothing
    has_skinning = !isempty(mesh.bone_weights) && !isempty(mesh.bone_indices)

    if has_skinning
        # Bone weights: vec4 per vertex
        weight_data = reinterpret(Float32, mesh.bone_weights)
        weight_size = sizeof(weight_data)
        bone_weight_buf, bone_weight_mem = _upload_to_device_local(
            device, physical_device, command_pool, queue,
            Vector{UInt8}(reinterpret(UInt8, weight_data)), weight_size,
            BUFFER_USAGE_VERTEX_BUFFER_BIT
        )

        # Bone indices: 4 x UInt16 per vertex, flattened
        n_verts = length(mesh.bone_indices)
        bone_idx_flat = Vector{UInt16}(undef, n_verts * 4)
        for i in 1:n_verts
            bi = mesh.bone_indices[i]
            bone_idx_flat[(i-1)*4 + 1] = bi[1]
            bone_idx_flat[(i-1)*4 + 2] = bi[2]
            bone_idx_flat[(i-1)*4 + 3] = bi[3]
            bone_idx_flat[(i-1)*4 + 4] = bi[4]
        end
        idx_size = sizeof(bone_idx_flat)
        bone_index_buf, bone_index_mem = _upload_to_device_local(
            device, physical_device, command_pool, queue,
            Vector{UInt8}(reinterpret(UInt8, bone_idx_flat)), idx_size,
            BUFFER_USAGE_VERTEX_BUFFER_BIT
        )
    end

    gpu_mesh = VulkanGPUMesh(
        vertex_buffer, vertex_memory,
        normal_buffer, normal_memory,
        uv_buffer, uv_memory,
        index_buffer, index_memory,
        Int32(length(mesh.indices)),
        bone_weight_buf, bone_weight_mem,
        bone_index_buf, bone_index_mem,
        has_skinning
    )

    cache.meshes[entity_id] = gpu_mesh
    return gpu_mesh
end

"""
    _upload_to_device_local(device, physical_device, cmd_pool, queue, data, size, usage) -> (Buffer, DeviceMemory)

Upload data to a device-local buffer via a staging buffer.
"""
function _upload_to_device_local(device::Device, physical_device::PhysicalDevice,
                                  command_pool::CommandPool, queue::Queue,
                                  data::Vector{UInt8}, size::Integer,
                                  usage::BufferUsageFlag)
    # Create staging buffer
    staging_buf, staging_mem = vk_create_buffer(
        device, physical_device, size,
        BUFFER_USAGE_TRANSFER_SRC_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
    )

    # Upload to staging
    ptr = unwrap(map_memory(device, staging_mem, UInt64(0), UInt64(size)))
    GC.@preserve data begin
        unsafe_copyto!(Ptr{UInt8}(ptr), pointer(data), size)
    end
    unmap_memory(device, staging_mem)

    # Create device-local buffer
    dst_buf, dst_mem = vk_create_buffer(
        device, physical_device, size,
        usage | BUFFER_USAGE_TRANSFER_DST_BIT,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT
    )

    # Copy staging → device
    vk_copy_buffer!(device, command_pool, queue, staging_buf, dst_buf, size)

    # Destroy staging (use finalize to properly deregister GC finalizer)
    finalize(staging_buf)
    finalize(staging_mem)

    return dst_buf, dst_mem
end

"""
    vk_get_or_upload_mesh!(cache, device, physical_device, cmd_pool, queue, entity_id, mesh) -> VulkanGPUMesh

Get mesh from cache or upload it.
"""
function vk_get_or_upload_mesh!(cache::VulkanGPUResourceCache, device::Device,
                                 physical_device::PhysicalDevice, command_pool::CommandPool,
                                 queue::Queue, entity_id::EntityID, mesh::MeshComponent)
    if haskey(cache.meshes, entity_id)
        return cache.meshes[entity_id]
    end
    return vk_upload_mesh!(cache, device, physical_device, command_pool, queue, entity_id, mesh)
end

"""
    vk_bind_and_draw_mesh!(cmd, gpu_mesh)

Bind vertex/index buffers and issue an indexed draw call.
"""
function vk_bind_and_draw_mesh!(cmd::CommandBuffer, gpu_mesh::VulkanGPUMesh)
    if gpu_mesh.has_skinning && gpu_mesh.bone_weight_buffer !== nothing && gpu_mesh.bone_index_buffer !== nothing
        cmd_bind_vertex_buffers(cmd,
            [gpu_mesh.vertex_buffer, gpu_mesh.normal_buffer, gpu_mesh.uv_buffer,
             gpu_mesh.bone_weight_buffer, gpu_mesh.bone_index_buffer],
            [UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0)]
        )
    else
        cmd_bind_vertex_buffers(cmd,
            [gpu_mesh.vertex_buffer, gpu_mesh.normal_buffer, gpu_mesh.uv_buffer],
            [UInt64(0), UInt64(0), UInt64(0)]
        )
    end
    cmd_bind_index_buffer(cmd, gpu_mesh.index_buffer, UInt64(0), INDEX_TYPE_UINT32)
    cmd_draw_indexed(cmd, UInt32(gpu_mesh.index_count), UInt32(1), UInt32(0), Int32(0), UInt32(0))
    return nothing
end

"""
    vk_destroy_mesh!(device, gpu_mesh)

Destroy a GPU mesh and free its memory.
"""
function vk_destroy_mesh!(device::Device, gpu_mesh::VulkanGPUMesh)
    finalize(gpu_mesh.vertex_buffer)
    finalize(gpu_mesh.vertex_memory)
    finalize(gpu_mesh.normal_buffer)
    finalize(gpu_mesh.normal_memory)
    finalize(gpu_mesh.uv_buffer)
    finalize(gpu_mesh.uv_memory)
    finalize(gpu_mesh.index_buffer)
    finalize(gpu_mesh.index_memory)
    if gpu_mesh.bone_weight_buffer !== nothing
        finalize(gpu_mesh.bone_weight_buffer)
        finalize(gpu_mesh.bone_weight_memory)
    end
    if gpu_mesh.bone_index_buffer !== nothing
        finalize(gpu_mesh.bone_index_buffer)
        finalize(gpu_mesh.bone_index_memory)
    end
    return nothing
end

"""
    vk_destroy_all_meshes!(device, cache)

Destroy all cached meshes.
"""
function vk_destroy_all_meshes!(device::Device, cache::VulkanGPUResourceCache)
    for (_, mesh) in cache.meshes
        vk_destroy_mesh!(device, mesh)
    end
    empty!(cache.meshes)
    return nothing
end

# ==================================================================
# Fullscreen Quad
# ==================================================================

# Fullscreen quad vertices: position (vec2) + UV (vec2) interleaved
const FULLSCREEN_QUAD_VERTICES = Float32[
    # pos.x, pos.y, uv.x, uv.y
    -1.0, -1.0, 0.0, 0.0,  # bottom-left
     1.0, -1.0, 1.0, 0.0,  # bottom-right
     1.0,  1.0, 1.0, 1.0,  # top-right
    -1.0, -1.0, 0.0, 0.0,  # bottom-left
     1.0,  1.0, 1.0, 1.0,  # top-right
    -1.0,  1.0, 0.0, 1.0,  # top-left
]

"""
    vk_create_fullscreen_quad(device, physical_device, cmd_pool, queue) -> (Buffer, DeviceMemory)

Create a device-local vertex buffer for a fullscreen quad.
"""
function vk_create_fullscreen_quad(device::Device, physical_device::PhysicalDevice,
                                    command_pool::CommandPool, queue::Queue)
    data = Vector{UInt8}(reinterpret(UInt8, FULLSCREEN_QUAD_VERTICES))
    return _upload_to_device_local(
        device, physical_device, command_pool, queue,
        data, sizeof(FULLSCREEN_QUAD_VERTICES),
        BUFFER_USAGE_VERTEX_BUFFER_BIT
    )
end

"""
    vk_draw_fullscreen_quad!(cmd, quad_buffer)

Bind and draw a fullscreen quad (6 vertices, 2 triangles).
"""
function vk_draw_fullscreen_quad!(cmd::CommandBuffer, quad_buffer::Buffer)
    cmd_bind_vertex_buffers(cmd, [quad_buffer], [UInt64(0)])
    cmd_draw(cmd, UInt32(6), UInt32(1), UInt32(0), UInt32(0))
    return nothing
end
