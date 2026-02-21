# Vulkan terrain renderer: G-Buffer rendering with splatmap blending

# ---- GLSL 450 Terrain Shaders ----

const VK_TERRAIN_GBUFFER_VERT = """
#version 450

layout(set = 0, binding = 0) uniform PerFrame {
    mat4 view;
    mat4 projection;
    vec3 cam_pos;
    float time;
} per_frame;

layout(location = 0) in vec3 a_Position;
layout(location = 1) in vec3 a_Normal;
layout(location = 2) in vec2 a_TexCoord;

layout(location = 0) out vec3 v_WorldPos;
layout(location = 1) out vec3 v_Normal;
layout(location = 2) out vec2 v_TexCoord;

void main()
{
    v_WorldPos = a_Position;  // Terrain vertices are already in world space
    v_Normal = a_Normal;
    v_TexCoord = a_TexCoord;
    gl_Position = per_frame.projection * per_frame.view * vec4(a_Position, 1.0);
}
"""

const VK_TERRAIN_GBUFFER_FRAG = """
#version 450

layout(set = 1, binding = 0) uniform TerrainUBO {
    int numLayers;
    float layer0UVScale;
    float layer1UVScale;
    float layer2UVScale;
    float layer3UVScale;
    float _pad1, _pad2, _pad3;
} terrain;

layout(set = 1, binding = 1) uniform sampler2D u_Splatmap;
layout(set = 1, binding = 2) uniform sampler2D u_Layer0Albedo;
layout(set = 1, binding = 3) uniform sampler2D u_Layer1Albedo;
layout(set = 1, binding = 4) uniform sampler2D u_Layer2Albedo;
layout(set = 1, binding = 5) uniform sampler2D u_Layer3Albedo;

layout(location = 0) in vec3 v_WorldPos;
layout(location = 1) in vec3 v_Normal;
layout(location = 2) in vec2 v_TexCoord;

layout(location = 0) out vec4 gAlbedoMetallic;
layout(location = 1) out vec4 gNormalRoughness;
layout(location = 2) out vec4 gEmissiveAO;
layout(location = 3) out vec4 gAdvancedMaterial;

void main()
{
    vec4 splat = texture(u_Splatmap, v_TexCoord);
    vec2 world_uv = v_WorldPos.xz;

    vec3 albedo = vec3(0.3, 0.6, 0.2);  // Default green fallback

    if (terrain.numLayers >= 1) {
        albedo = texture(u_Layer0Albedo, world_uv * terrain.layer0UVScale).rgb * splat.r;
    }
    if (terrain.numLayers >= 2) {
        albedo += texture(u_Layer1Albedo, world_uv * terrain.layer1UVScale).rgb * splat.g;
    }
    if (terrain.numLayers >= 3) {
        albedo += texture(u_Layer2Albedo, world_uv * terrain.layer2UVScale).rgb * splat.b;
    }
    if (terrain.numLayers >= 4) {
        albedo += texture(u_Layer3Albedo, world_uv * terrain.layer3UVScale).rgb * splat.a;
    }

    // Normalize by total splatmap weight to prevent darkening
    float total_weight = splat.r;
    if (terrain.numLayers >= 2) total_weight += splat.g;
    if (terrain.numLayers >= 3) total_weight += splat.b;
    if (terrain.numLayers >= 4) total_weight += splat.a;
    if (total_weight > 0.001)
        albedo /= total_weight;

    gAlbedoMetallic = vec4(albedo, 0.0);                            // Metallic = 0
    gNormalRoughness = vec4(normalize(v_Normal) * 0.5 + 0.5, 0.85); // Roughness = 0.85
    gEmissiveAO = vec4(0.0, 0.0, 0.0, 1.0);                        // No emissive, full AO
    gAdvancedMaterial = vec4(0.0, 0.0, 0.0, 1.0);                   // No advanced features
}
"""

# ---- Terrain UBO ----

struct VulkanTerrainUniforms
    num_layers::Int32
    layer0_uv_scale::Float32
    layer1_uv_scale::Float32
    layer2_uv_scale::Float32
    layer3_uv_scale::Float32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

# ---- Initialization ----

"""
    vk_init_terrain!(renderer, device, physical_device, gbuffer_render_pass,
                     per_frame_layout, per_material_layout, push_constant_range, width, height)

Create the terrain G-Buffer pipeline. Reuses the existing G-Buffer render pass and
per_material_layout (binding 0 = UBO, bindings 1-6 = samplers).
"""
function vk_init_terrain!(renderer::VulkanTerrainRenderer,
                           device::Device, physical_device::PhysicalDevice,
                           gbuffer_render_pass::RenderPass,
                           per_frame_layout::DescriptorSetLayout,
                           per_material_layout::DescriptorSetLayout,
                           push_constant_range::PushConstantRange,
                           width::Int, height::Int)
    renderer.pipeline = vk_compile_and_create_pipeline(
        device, VK_TERRAIN_GBUFFER_VERT, VK_TERRAIN_GBUFFER_FRAG,
        VulkanPipelineConfig(
            gbuffer_render_pass, UInt32(0),
            vk_standard_vertex_bindings(), vk_standard_vertex_attributes(),
            [per_frame_layout, per_material_layout],
            [push_constant_range],
            false,  # no alpha blend
            true,   # depth test
            true,   # depth write
            CULL_MODE_BACK_BIT,
            FRONT_FACE_CLOCKWISE,
            4,      # 4 MRTs
            width, height
        ))

    renderer.initialized = true
    return nothing
end

# ---- Per-Entity GPU Cache ----

"""
    vk_get_or_create_terrain_cache!(renderer, entity_id, td, comp, device, physical_device,
                                     command_pool, queue, texture_cache, default_texture)

Get or create the GPU cache for a terrain entity (chunk meshes, splatmap, layer textures).
"""
function vk_get_or_create_terrain_cache!(renderer::VulkanTerrainRenderer,
                                          entity_id::EntityID,
                                          td::TerrainData,
                                          comp::TerrainComponent,
                                          device::Device,
                                          physical_device::PhysicalDevice,
                                          command_pool::CommandPool,
                                          queue::Queue,
                                          texture_cache::VulkanTextureCache,
                                          default_texture::VulkanGPUTexture)
    if haskey(renderer.caches, entity_id)
        return renderer.caches[entity_id]
    end

    cache = VulkanTerrainGPUCache()

    # Load layer albedo textures
    for layer in comp.layers
        if !isempty(layer.albedo_path) && isfile(layer.albedo_path)
            tex = vk_load_texture(texture_cache, device, physical_device, command_pool, queue,
                                   layer.albedo_path)
            push!(cache.layer_textures, tex)
        else
            push!(cache.layer_textures, nothing)
        end
    end

    # Load or generate splatmap
    if !isempty(comp.splatmap_path) && isfile(comp.splatmap_path)
        cache.splatmap_texture = vk_load_texture(texture_cache, device, physical_device,
                                                   command_pool, queue, comp.splatmap_path)
    else
        cache.splatmap_texture = _vk_create_default_splatmap(td, device, physical_device,
                                                               command_pool, queue)
    end

    renderer.caches[entity_id] = cache
    return cache
end

"""
    _vk_create_default_splatmap(td, device, physical_device, cmd_pool, queue) -> VulkanGPUTexture

Generate a default splatmap texture based on normalized height (altitude-based splatting).
"""
function _vk_create_default_splatmap(td::TerrainData,
                                      device::Device, physical_device::PhysicalDevice,
                                      command_pool::CommandPool, queue::Queue)
    rows, cols = size(td.heightmap)
    pixels = Vector{UInt8}(undef, rows * cols * 4)

    min_h = minimum(td.heightmap)
    max_h = maximum(td.heightmap)
    range_h = max_h - min_h
    if range_h < 0.001f0
        range_h = 1.0f0
    end

    idx = 1
    for iz in 1:cols, ix in 1:rows
        h = td.heightmap[ix, iz]
        t = (h - min_h) / range_h

        r = clamp(1.0f0 - abs(t - 0.2f0) * 4.0f0, 0.0f0, 1.0f0)  # Grass at 0.2
        g = clamp(1.0f0 - abs(t - 0.5f0) * 3.0f0, 0.0f0, 1.0f0)  # Rock at 0.5
        b = clamp(1.0f0 - abs(t - 0.0f0) * 5.0f0, 0.0f0, 1.0f0)  # Sand at 0.0
        a = clamp((t - 0.7f0) * 3.3f0, 0.0f0, 1.0f0)               # Snow above 0.7

        total = r + g + b + a
        if total > 0.001f0
            r /= total; g /= total; b /= total; a /= total
        end

        pixels[idx]     = UInt8(clamp(round(Int, r * 255), 0, 255))
        pixels[idx + 1] = UInt8(clamp(round(Int, g * 255), 0, 255))
        pixels[idx + 2] = UInt8(clamp(round(Int, b * 255), 0, 255))
        pixels[idx + 3] = UInt8(clamp(round(Int, a * 255), 0, 255))
        idx += 4
    end

    return vk_upload_texture(device, physical_device, command_pool, queue,
                              pixels, rows, cols, 4;
                              format=FORMAT_R8G8B8A8_UNORM, generate_mipmaps=false)
end

# ---- Chunk Mesh Upload ----

"""
    _vk_get_or_upload_terrain_chunk!(cache, td, cx, cz, lod, device, physical_device, cmd_pool, queue)

Get or upload a terrain chunk mesh to device-local GPU memory.
"""
function _vk_get_or_upload_terrain_chunk!(cache::VulkanTerrainGPUCache,
                                           td::TerrainData,
                                           cx::Int, cz::Int, lod::Int,
                                           device::Device,
                                           physical_device::PhysicalDevice,
                                           command_pool::CommandPool,
                                           queue::Queue)
    key = (cx, cz, lod)
    if haskey(cache.chunk_meshes, key)
        return cache.chunk_meshes[key]
    end

    chunk = td.chunks[cx, cz]
    mesh = chunk.lod_meshes[lod]

    # Upload positions
    pos_data = Vector{UInt8}(reinterpret(UInt8, reinterpret(Float32, mesh.vertices)))
    vertex_buffer, vertex_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        pos_data, sizeof(pos_data), BUFFER_USAGE_VERTEX_BUFFER_BIT)

    # Upload normals
    norm_data = Vector{UInt8}(reinterpret(UInt8, reinterpret(Float32, mesh.normals)))
    normal_buffer, normal_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        norm_data, sizeof(norm_data), BUFFER_USAGE_VERTEX_BUFFER_BIT)

    # Upload UVs
    uv_data = Vector{UInt8}(reinterpret(UInt8, reinterpret(Float32, mesh.uvs)))
    uv_buffer, uv_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        uv_data, sizeof(uv_data), BUFFER_USAGE_VERTEX_BUFFER_BIT)

    # Upload indices
    idx_data = Vector{UInt8}(reinterpret(UInt8, mesh.indices))
    index_buffer, index_memory = _upload_to_device_local(
        device, physical_device, command_pool, queue,
        idx_data, sizeof(idx_data), BUFFER_USAGE_INDEX_BUFFER_BIT)

    gpu_mesh = VulkanGPUMesh(
        vertex_buffer, vertex_memory,
        normal_buffer, normal_memory,
        uv_buffer, uv_memory,
        index_buffer, index_memory,
        Int32(length(mesh.indices)),
        nothing, nothing, nothing, nothing, false  # no skinning
    )

    cache.chunk_meshes[key] = gpu_mesh
    return gpu_mesh
end

# ---- Terrain Rendering (within G-Buffer pass) ----

"""
    vk_render_terrain_gbuffer!(cmd, backend, frame_idx, vk_proj, view, cam_pos, width, height)

Render all terrain entities into the currently active G-Buffer render pass.
Called after opaque entities and before cmd_end_render_pass.
"""
function vk_render_terrain_gbuffer!(cmd::CommandBuffer, backend::VulkanBackend,
                                     frame_idx::Int, vk_proj::Mat4f, view::Mat4f,
                                     cam_pos::Vec3f, width::Int, height::Int)
    renderer = backend.terrain_renderer
    !renderer.initialized && return
    renderer.pipeline === nothing && return

    # Compute frustum for chunk culling
    vp = vk_proj * view
    terrain_frustum = extract_frustum(vp)

    iterate_components(TerrainComponent) do terrain_eid, terrain_comp
        td = get(_TERRAIN_CACHE, terrain_eid, nothing)
        if td !== nothing && td.initialized
            _vk_render_one_terrain!(cmd, backend, renderer, terrain_eid, td, terrain_comp,
                                     frame_idx, terrain_frustum, width, height)
        end
    end
end

"""
    _vk_render_one_terrain!(cmd, backend, renderer, entity_id, td, comp, frame_idx, frustum, w, h)

Render a single terrain entity: bind pipeline, create descriptor set, draw visible chunks.
"""
function _vk_render_one_terrain!(cmd::CommandBuffer, backend::VulkanBackend,
                                  renderer::VulkanTerrainRenderer,
                                  entity_id::EntityID, td::TerrainData,
                                  comp::TerrainComponent,
                                  frame_idx::Int, frustum::Frustum,
                                  width::Int, height::Int)
    cache = vk_get_or_create_terrain_cache!(renderer, entity_id, td, comp,
        backend.device, backend.physical_device, backend.command_pool, backend.graphics_queue,
        backend.texture_cache, backend.default_texture)

    pipeline = renderer.pipeline
    cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline)

    # Bind per-frame descriptor set (set 0)
    cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline_layout,
        UInt32(0), [backend.per_frame_ds[frame_idx]], UInt32[])

    # Create terrain material descriptor set (set 1)
    mat_ds = vk_allocate_descriptor_set(backend.device,
        backend.transient_pools[frame_idx], backend.per_material_layout)

    # Pack terrain UBO
    num_layers = length(comp.layers)
    uv_scales = Float32[10.0, 10.0, 10.0, 10.0]  # defaults
    for i in 1:min(4, num_layers)
        uv_scales[i] = comp.layers[i].uv_scale
    end

    terrain_uniforms = VulkanTerrainUniforms(
        Int32(num_layers),
        uv_scales[1], uv_scales[2], uv_scales[3], uv_scales[4],
        0.0f0, 0.0f0, 0.0f0
    )
    terrain_ubo, terrain_mem = vk_create_uniform_buffer(
        backend.device, backend.physical_device, terrain_uniforms)
    push!(backend.frame_temp_buffers[frame_idx], (terrain_ubo, terrain_mem))

    vk_update_ubo_descriptor!(backend.device, mat_ds, 0,
        terrain_ubo, sizeof(VulkanTerrainUniforms))

    # Bind splatmap (binding 1)
    splatmap_tex = cache.splatmap_texture !== nothing ? cache.splatmap_texture : backend.default_texture
    vk_update_texture_descriptor!(backend.device, mat_ds, 1, splatmap_tex)

    # Bind layer albedos (bindings 2-5)
    for i in 1:4
        tex = if i <= length(cache.layer_textures) && cache.layer_textures[i] !== nothing
            cache.layer_textures[i]
        else
            backend.default_texture
        end
        vk_update_texture_descriptor!(backend.device, mat_ds, i + 1, tex)
    end

    # Fill remaining binding (6) with default
    vk_update_texture_descriptor!(backend.device, mat_ds, 6, backend.default_texture)

    cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline_layout,
        UInt32(1), [mat_ds], UInt32[])

    # Push identity matrices (terrain doesn't use model transform, but pipeline layout requires it)
    push_data = vk_pack_per_object(Mat4f(I), SMatrix{3, 3, Float32, 9}(I))
    push_ref = Ref(push_data)
    GC.@preserve push_ref cmd_push_constants(cmd, pipeline.pipeline_layout,
        SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
        UInt32(0), UInt32(sizeof(push_data)),
        Base.unsafe_convert(Ptr{Cvoid}, Base.cconvert(Ptr{Cvoid}, push_ref)))

    # Render visible chunks
    for cz in 1:td.num_chunks_z, cx in 1:td.num_chunks_x
        chunk = td.chunks[cx, cz]

        # Frustum cull by chunk AABB
        if !is_aabb_in_frustum(frustum, chunk.aabb_min, chunk.aabb_max)
            continue
        end

        gpu_mesh = _vk_get_or_upload_terrain_chunk!(cache, td, cx, cz, chunk.current_lod,
            backend.device, backend.physical_device, backend.command_pool, backend.graphics_queue)

        vk_bind_and_draw_mesh!(cmd, gpu_mesh)
    end
end

# ---- Cleanup ----

"""
    vk_destroy_terrain!(device, renderer)

Destroy all terrain GPU resources.
"""
function vk_destroy_terrain!(device::Device, renderer::VulkanTerrainRenderer)
    for (_, cache) in renderer.caches
        _vk_destroy_terrain_cache!(device, cache)
    end
    empty!(renderer.caches)

    if renderer.pipeline !== nothing
        finalize(renderer.pipeline.pipeline)
        finalize(renderer.pipeline.pipeline_layout)
        renderer.pipeline.vert_module !== nothing && finalize(renderer.pipeline.vert_module)
        renderer.pipeline.frag_module !== nothing && finalize(renderer.pipeline.frag_module)
        renderer.pipeline = nothing
    end

    renderer.initialized = false
    return nothing
end

function _vk_destroy_terrain_cache!(device::Device, cache::VulkanTerrainGPUCache)
    for (_, mesh) in cache.chunk_meshes
        vk_destroy_mesh!(device, mesh)
    end
    empty!(cache.chunk_meshes)

    # Note: layer textures are owned by the shared VulkanTextureCache, don't destroy here
    empty!(cache.layer_textures)

    # Splatmap may be generated (not in texture cache) — destroy if present
    if cache.splatmap_texture !== nothing
        vk_destroy_texture!(device, cache.splatmap_texture)
        cache.splatmap_texture = nothing
    end
end
