# glTF 2.0 model loader

"""
    load_gltf(path::String; base_dir::String = dirname(path)) -> Vector{EntityDef}

Load a glTF 2.0 file (.gltf or .glb) and return a vector of EntityDefs.
Each mesh primitive becomes a separate entity with MeshComponent and MaterialComponent.
"""
function load_gltf(path::String; base_dir::String = dirname(abspath(path)))
    gltf = GLTFLib.load(path)

    # Load buffer data
    buffers_data = _load_gltf_buffers(gltf, base_dir)

    entities_out = EntityDef[]

    gltf.meshes === nothing && return entities_out

    for mesh in gltf.meshes
        for prim in mesh.primitives
            mesh_comp = _extract_gltf_mesh(gltf, prim, buffers_data)
            mat_comp = _extract_gltf_material(gltf, prim, base_dir)
            push!(entities_out, entity([mesh_comp, mat_comp, transform()]))
        end
    end

    return entities_out
end

# ---- Buffer loading ----

function _load_gltf_buffers(gltf::GLTFLib.Object, base_dir::String)
    buffers_data = Vector{UInt8}[]
    gltf.buffers === nothing && return buffers_data

    for buf in gltf.buffers
        if buf.uri !== nothing
            if startswith(buf.uri, "data:")
                # Data URI (base64 embedded)
                data_start = findfirst(',', buf.uri)
                if data_start !== nothing
                    encoded = buf.uri[data_start+1:end]
                    push!(buffers_data, base64decode(encoded))
                else
                    push!(buffers_data, UInt8[])
                end
            else
                # External file
                filepath = joinpath(base_dir, buf.uri)
                push!(buffers_data, read(filepath))
            end
        else
            push!(buffers_data, UInt8[])
        end
    end

    return buffers_data
end

# ---- Accessor data extraction ----

const GLTF_COMPONENT_SIZES = Dict(
    5120 => 1,  # BYTE
    5121 => 1,  # UNSIGNED_BYTE
    5122 => 2,  # SHORT
    5123 => 2,  # UNSIGNED_SHORT
    5125 => 4,  # UNSIGNED_INT
    5126 => 4,  # FLOAT
)

const GLTF_TYPE_COUNTS = Dict(
    "SCALAR" => 1,
    "VEC2" => 2,
    "VEC3" => 3,
    "VEC4" => 4,
    "MAT2" => 4,
    "MAT3" => 9,
    "MAT4" => 16,
)

function _read_accessor_data(gltf::GLTFLib.Object, accessor_idx::Int, buffers_data::Vector{Vector{UInt8}})
    accessor = gltf.accessors[accessor_idx]
    accessor.bufferView === nothing && return Float32[]

    bv = gltf.bufferViews[accessor.bufferView]
    buf_data = buffers_data[bv.buffer + 1]  # buffers are 0-indexed in glTF, 1-indexed in our array

    byte_offset = bv.byteOffset + accessor.byteOffset
    component_size = get(GLTF_COMPONENT_SIZES, accessor.componentType, 4)
    type_count = get(GLTF_TYPE_COUNTS, accessor.type, 1)
    stride = bv.byteStride !== nothing ? bv.byteStride : component_size * type_count

    n = accessor.count
    result = Float32[]

    for i in 0:(n-1)
        offset = byte_offset + i * stride
        for j in 0:(type_count-1)
            elem_offset = offset + j * component_size + 1  # +1 for Julia 1-based

            if accessor.componentType == 5126  # FLOAT
                val = reinterpret(Float32, buf_data[elem_offset:elem_offset+3])[1]
                push!(result, val)
            elseif accessor.componentType == 5125  # UNSIGNED_INT
                val = reinterpret(UInt32, buf_data[elem_offset:elem_offset+3])[1]
                push!(result, Float32(val))
            elseif accessor.componentType == 5123  # UNSIGNED_SHORT
                val = reinterpret(UInt16, buf_data[elem_offset:elem_offset+1])[1]
                push!(result, Float32(val))
            elseif accessor.componentType == 5121  # UNSIGNED_BYTE
                push!(result, Float32(buf_data[elem_offset]))
            end
        end
    end

    return result
end

function _read_index_data(gltf::GLTFLib.Object, accessor_idx::Int, buffers_data::Vector{Vector{UInt8}})
    accessor = gltf.accessors[accessor_idx]
    accessor.bufferView === nothing && return UInt32[]

    bv = gltf.bufferViews[accessor.bufferView]
    buf_data = buffers_data[bv.buffer + 1]

    byte_offset = bv.byteOffset + accessor.byteOffset
    component_size = get(GLTF_COMPONENT_SIZES, accessor.componentType, 4)
    stride = bv.byteStride !== nothing ? bv.byteStride : component_size

    n = accessor.count
    result = UInt32[]

    for i in 0:(n-1)
        offset = byte_offset + i * stride + 1  # +1 for Julia 1-based

        if accessor.componentType == 5125  # UNSIGNED_INT
            val = reinterpret(UInt32, buf_data[offset:offset+3])[1]
            push!(result, val)
        elseif accessor.componentType == 5123  # UNSIGNED_SHORT
            val = reinterpret(UInt16, buf_data[offset:offset+1])[1]
            push!(result, UInt32(val))
        elseif accessor.componentType == 5121  # UNSIGNED_BYTE
            push!(result, UInt32(buf_data[offset]))
        end
    end

    return result
end

# ---- Mesh extraction ----

function _extract_gltf_mesh(gltf::GLTFLib.Object, prim::GLTFLib.Primitive, buffers_data::Vector{Vector{UInt8}})
    positions = Point3f[]
    normals = Vec3f[]
    uvs = Vec2f[]
    indices = UInt32[]

    # Positions
    if haskey(prim.attributes, "POSITION")
        pos_data = _read_accessor_data(gltf, prim.attributes["POSITION"], buffers_data)
        for i in 1:3:length(pos_data)
            push!(positions, Point3f(pos_data[i], pos_data[i+1], pos_data[i+2]))
        end
    end

    # Normals
    if haskey(prim.attributes, "NORMAL")
        norm_data = _read_accessor_data(gltf, prim.attributes["NORMAL"], buffers_data)
        for i in 1:3:length(norm_data)
            push!(normals, Vec3f(norm_data[i], norm_data[i+1], norm_data[i+2]))
        end
    end

    # UVs (TEXCOORD_0)
    if haskey(prim.attributes, "TEXCOORD_0")
        uv_data = _read_accessor_data(gltf, prim.attributes["TEXCOORD_0"], buffers_data)
        for i in 1:2:length(uv_data)
            push!(uvs, Vec2f(uv_data[i], uv_data[i+1]))
        end
    end

    # Indices
    if prim.indices !== nothing
        indices = _read_index_data(gltf, prim.indices, buffers_data)
    end

    # Compute normals if not provided
    if isempty(normals) && !isempty(positions) && !isempty(indices)
        normals = _compute_averaged_normals(positions, indices)
    end

    return MeshComponent(vertices=positions, indices=indices, normals=normals, uvs=uvs)
end

# ---- Material extraction ----

function _extract_gltf_material(gltf::GLTFLib.Object, prim::GLTFLib.Primitive, base_dir::String)
    if prim.material === nothing || gltf.materials === nothing
        return MaterialComponent()
    end

    mat = gltf.materials[prim.material]
    pbr = mat.pbrMetallicRoughness

    # Base color
    bc = pbr.baseColorFactor
    color = RGB{Float32}(Float32(bc[1]), Float32(bc[2]), Float32(bc[3]))
    metallic = Float32(pbr.metallicFactor)
    roughness = Float32(pbr.roughnessFactor)

    # Texture references
    albedo_map = _resolve_gltf_texture(gltf, pbr.baseColorTexture, base_dir)
    normal_map = _resolve_gltf_texture(gltf, mat.normalTexture, base_dir)
    mr_map = _resolve_gltf_texture(gltf, pbr.metallicRoughnessTexture, base_dir)
    ao_map = _resolve_gltf_texture(gltf, mat.occlusionTexture, base_dir)
    emissive_map = _resolve_gltf_texture(gltf, mat.emissiveTexture, base_dir)

    emissive_factor = Vec3f(0, 0, 0)
    if mat.emissiveFactor !== nothing
        ef = mat.emissiveFactor
        emissive_factor = Vec3f(Float32(ef[1]), Float32(ef[2]), Float32(ef[3]))
    end

    return MaterialComponent(
        color=color, metallic=metallic, roughness=roughness,
        albedo_map=albedo_map, normal_map=normal_map,
        metallic_roughness_map=mr_map, ao_map=ao_map,
        emissive_map=emissive_map, emissive_factor=emissive_factor
    )
end

function _resolve_gltf_texture(gltf::GLTFLib.Object, tex_info, base_dir::String)
    tex_info === nothing && return nothing
    gltf.textures === nothing && return nothing

    texture = gltf.textures[tex_info.index]
    texture.source === nothing && return nothing

    gltf.images === nothing && return nothing
    image = gltf.images[texture.source]
    image.uri === nothing && return nothing

    # Skip data URIs for now
    startswith(image.uri, "data:") && return nothing

    return TextureRef(joinpath(base_dir, image.uri))
end
