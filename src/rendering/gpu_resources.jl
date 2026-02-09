# GPU resource management
# VAO/VBO/EBO creation and caching for MeshComponent data

using ModernGL

"""
    GPUMesh

OpenGL handles for a single mesh's GPU buffers.
"""
mutable struct GPUMesh
    vao::GLuint
    vbo::GLuint     # vertex positions
    nbo::GLuint     # normals
    ubo::GLuint     # UV coordinates
    ebo::GLuint     # element (index) buffer
    index_count::Int32

    GPUMesh() = new(GLuint(0), GLuint(0), GLuint(0), GLuint(0), GLuint(0), Int32(0))
end

"""
    GPUResourceCache

Maps EntityIDs to their GPU-side resources. Provides lazy creation and explicit cleanup.
"""
mutable struct GPUResourceCache
    meshes::Dict{EntityID, GPUMesh}

    GPUResourceCache() = new(Dict{EntityID, GPUMesh}())
end

"""
    upload_mesh!(cache::GPUResourceCache, entity_id::EntityID, mesh::MeshComponent) -> GPUMesh

Upload a MeshComponent's data to GPU buffers. Creates VAO/VBO/EBO.
If the entity already has a GPUMesh, the old buffers are destroyed first.
"""
function upload_mesh!(cache::GPUResourceCache, entity_id::EntityID, mesh::MeshComponent)
    if haskey(cache.meshes, entity_id)
        destroy_gpu_mesh!(cache.meshes[entity_id])
    end

    gpu = GPUMesh()

    # Generate VAO
    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    gpu.vao = vao_ref[]
    glBindVertexArray(gpu.vao)

    # Vertex positions (layout = 0)
    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    gpu.vbo = vbo_ref[]
    glBindBuffer(GL_ARRAY_BUFFER, gpu.vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(mesh.vertices), mesh.vertices, GL_STATIC_DRAW)
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, C_NULL)
    glEnableVertexAttribArray(0)

    # Normals (layout = 1)
    nbo_ref = Ref(GLuint(0))
    glGenBuffers(1, nbo_ref)
    gpu.nbo = nbo_ref[]
    glBindBuffer(GL_ARRAY_BUFFER, gpu.nbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(mesh.normals), mesh.normals, GL_STATIC_DRAW)
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 0, C_NULL)
    glEnableVertexAttribArray(1)

    # UV coordinates (layout = 2)
    if !isempty(mesh.uvs)
        ubo_ref = Ref(GLuint(0))
        glGenBuffers(1, ubo_ref)
        gpu.ubo = ubo_ref[]
        glBindBuffer(GL_ARRAY_BUFFER, gpu.ubo)
        glBufferData(GL_ARRAY_BUFFER, sizeof(mesh.uvs), mesh.uvs, GL_STATIC_DRAW)
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 0, C_NULL)
        glEnableVertexAttribArray(2)
    end

    # Index buffer
    ebo_ref = Ref(GLuint(0))
    glGenBuffers(1, ebo_ref)
    gpu.ebo = ebo_ref[]
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gpu.ebo)
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(mesh.indices), mesh.indices, GL_STATIC_DRAW)
    gpu.index_count = Int32(length(mesh.indices))

    glBindVertexArray(GLuint(0))

    cache.meshes[entity_id] = gpu
    return gpu
end

"""
    get_or_upload_mesh!(cache::GPUResourceCache, entity_id::EntityID, mesh::MeshComponent) -> GPUMesh

Retrieve existing GPUMesh or upload if not yet cached.
"""
function get_or_upload_mesh!(cache::GPUResourceCache, entity_id::EntityID, mesh::MeshComponent)
    if haskey(cache.meshes, entity_id)
        return cache.meshes[entity_id]
    end
    return upload_mesh!(cache, entity_id, mesh)
end

"""
    destroy_gpu_mesh!(gpu::GPUMesh)

Delete OpenGL buffers for a mesh.
"""
function destroy_gpu_mesh!(gpu::GPUMesh)
    bufs = GLuint[gpu.vbo, gpu.nbo, gpu.ebo]
    if gpu.ubo != GLuint(0)
        push!(bufs, gpu.ubo)
    end
    glDeleteBuffers(length(bufs), bufs)
    vaos = GLuint[gpu.vao]
    glDeleteVertexArrays(1, vaos)
    gpu.vao = GLuint(0)
    gpu.vbo = GLuint(0)
    gpu.nbo = GLuint(0)
    gpu.ubo = GLuint(0)
    gpu.ebo = GLuint(0)
end

"""
    destroy_all!(cache::GPUResourceCache)

Cleanup all GPU resources.
"""
function destroy_all!(cache::GPUResourceCache)
    for (_, gpu) in cache.meshes
        destroy_gpu_mesh!(gpu)
    end
    empty!(cache.meshes)
end
