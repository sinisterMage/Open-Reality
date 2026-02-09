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
    # Map glTF node index (0-based) -> EntityID for animation targeting
    node_to_entity = Dict{Int, EntityID}()

    gltf.meshes === nothing && return entities_out

    # Build node→mesh mapping for animation targets
    node_mesh_map = Dict{Int, Int}()  # node_idx -> mesh_idx (0-based)
    if gltf.nodes !== nothing
        for (i, node) in enumerate(gltf.nodes)
            if node.mesh !== nothing
                node_mesh_map[i-1] = node.mesh  # store 0-based
            end
        end
    end

    # Track which mesh index maps to which entity indices
    mesh_entity_map = Dict{Int, Vector{Int}}()  # mesh_idx (0-based) -> entity indices in entities_out
    entity_idx = 0

    for (mi, mesh) in enumerate(gltf.meshes)
        mesh_0idx = mi - 1
        start_idx = entity_idx
        for prim in mesh.primitives
            mesh_comp = _extract_gltf_mesh(gltf, prim, buffers_data)
            mat_comp = _extract_gltf_material(gltf, prim, base_dir)
            push!(entities_out, entity([mesh_comp, mat_comp, transform()]))
            entity_idx += 1
        end
        mesh_entity_map[mesh_0idx] = collect(start_idx:(entity_idx-1))
    end

    # Build node_to_entity: map node 0-based index to the first entity of its mesh
    for (node_idx, mesh_idx) in node_mesh_map
        if haskey(mesh_entity_map, mesh_idx) && !isempty(mesh_entity_map[mesh_idx])
            # Note: entity IDs are assigned at scene creation, not here.
            # Store the index into entities_out (0-based) for later mapping.
            node_to_entity[node_idx] = EntityID(mesh_entity_map[mesh_idx][1] + 1)
        end
    end

    # Extract animations if present
    anim_clips = _extract_gltf_animations(gltf, buffers_data, node_to_entity)
    if !isempty(anim_clips)
        # Attach AnimationComponent to the first entity
        anim_comp = AnimationComponent(
            clips=anim_clips,
            active_clip=1,
            playing=true,
            looping=true
        )
        # Add animation component to first entity
        if !isempty(entities_out)
            first_def = entities_out[1]
            push!(first_def.components, anim_comp)
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

    # Alpha mode
    opacity = Float32(1.0)
    alpha_cutoff = Float32(0.0)
    if hasproperty(mat, :alphaMode) && mat.alphaMode !== nothing
        if mat.alphaMode == "BLEND"
            opacity = length(bc) >= 4 ? Float32(bc[4]) : Float32(1.0)
        elseif mat.alphaMode == "MASK"
            alpha_cutoff = hasproperty(mat, :alphaCutoff) && mat.alphaCutoff !== nothing ?
                Float32(mat.alphaCutoff) : Float32(0.5)
        end
    end

    return MaterialComponent(
        color=color, metallic=metallic, roughness=roughness,
        albedo_map=albedo_map, normal_map=normal_map,
        metallic_roughness_map=mr_map, ao_map=ao_map,
        emissive_map=emissive_map, emissive_factor=emissive_factor,
        opacity=opacity, alpha_cutoff=alpha_cutoff
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

# ---- Animation extraction ----

const GLTF_PATH_MAP = Dict(
    "translation" => :position,
    "rotation" => :rotation,
    "scale" => :scale,
)

const GLTF_INTERP_MAP = Dict(
    "STEP" => INTERP_STEP,
    "LINEAR" => INTERP_LINEAR,
    "CUBICSPLINE" => INTERP_CUBICSPLINE,
)

function _extract_gltf_animations(gltf::GLTFLib.Object, buffers_data::Vector{Vector{UInt8}},
                                  node_to_entity::Dict{Int, EntityID})
    clips = AnimationClip[]
    (gltf.animations === nothing || isempty(gltf.animations)) && return clips

    for anim in gltf.animations
        channels_out = AnimationChannel[]
        name = hasproperty(anim, :name) && anim.name !== nothing ? anim.name : "clip"

        for ch in anim.channels
            ch.target === nothing && continue
            ch.target.node === nothing && continue

            node_idx = ch.target.node
            !haskey(node_to_entity, node_idx) && continue

            target_eid = node_to_entity[node_idx]
            path_str = ch.target.path
            !haskey(GLTF_PATH_MAP, path_str) && continue
            target_prop = GLTF_PATH_MAP[path_str]

            sampler = anim.samplers[ch.sampler + 1]  # 0-indexed in glTF

            # Read keyframe times
            times_raw = _read_accessor_data(gltf, sampler.input, buffers_data)
            times = Float32.(times_raw)

            # Read keyframe values
            values_raw = _read_accessor_data(gltf, sampler.output, buffers_data)

            interp = get(GLTF_INTERP_MAP,
                        hasproperty(sampler, :interpolation) && sampler.interpolation !== nothing ?
                            sampler.interpolation : "LINEAR",
                        INTERP_LINEAR)

            # Parse values based on target property
            values = Any[]
            if target_prop == :position || target_prop == :scale
                for i in 1:3:length(values_raw)
                    i + 2 > length(values_raw) && break
                    push!(values, Vec3d(Float64(values_raw[i]), Float64(values_raw[i+1]), Float64(values_raw[i+2])))
                end
            elseif target_prop == :rotation
                for i in 1:4:length(values_raw)
                    i + 3 > length(values_raw) && break
                    # glTF quaternions are (x, y, z, w), Quaternions.jl is (w, x, y, z)
                    push!(values, Quaterniond(
                        Float64(values_raw[i+3]),  # w
                        Float64(values_raw[i]),    # x
                        Float64(values_raw[i+1]),  # y
                        Float64(values_raw[i+2])   # z
                    ))
                end
            end

            isempty(values) && continue

            push!(channels_out, AnimationChannel(target_eid, target_prop, times, values, interp))
        end

        duration = 0.0f0
        for ch in channels_out
            if !isempty(ch.times)
                duration = max(duration, ch.times[end])
            end
        end

        !isempty(channels_out) && push!(clips, AnimationClip(name, channels_out, duration))
    end

    return clips
end
