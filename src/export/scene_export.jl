# ORSB (OpenReality Scene Bundle) scene export for WASM web deployment.
#
# Exports a Julia Scene to a binary .orsb file that the Rust WASM runtime can load.

const ORSB_MAGIC = UInt8['O', 'R', 'S', 'B']
const ORSB_VERSION = UInt32(1)

# Section type IDs
const SECTION_ENTITY_GRAPH = UInt32(1)
const SECTION_TRANSFORMS   = UInt32(2)
const SECTION_MESHES       = UInt32(3)
const SECTION_MATERIALS    = UInt32(4)
const SECTION_TEXTURES     = UInt32(5)
const SECTION_LIGHTS       = UInt32(6)
const SECTION_CAMERAS      = UInt32(7)
const SECTION_COLLIDERS    = UInt32(8)
const SECTION_RIGIDBODIES  = UInt32(9)
const SECTION_ANIMATIONS   = UInt32(10)
const SECTION_SKELETONS    = UInt32(11)
const SECTION_PARTICLES    = UInt32(12)
const SECTION_PHYSICS_CFG  = UInt32(13)

# Component mask bit flags
const CMASK_TRANSFORM    = UInt64(1) << 0
const CMASK_MESH         = UInt64(1) << 1
const CMASK_MATERIAL     = UInt64(1) << 2
const CMASK_CAMERA       = UInt64(1) << 3
const CMASK_POINT_LIGHT  = UInt64(1) << 4
const CMASK_DIR_LIGHT    = UInt64(1) << 5
const CMASK_COLLIDER     = UInt64(1) << 6
const CMASK_RIGIDBODY    = UInt64(1) << 7
const CMASK_ANIMATION    = UInt64(1) << 8
const CMASK_SKELETON     = UInt64(1) << 9
const CMASK_PARTICLE     = UInt64(1) << 10
const CMASK_AUDIO_SRC    = UInt64(1) << 11
const CMASK_AUDIO_LIST   = UInt64(1) << 12
const CMASK_IBL          = UInt64(1) << 13

"""
    export_scene(scene::Scene, path::String; physics_config, compress_textures)

Export a Scene to the ORSB binary format for loading in the WASM web runtime.

# Arguments
- `scene`: The scene to export
- `path`: Output .orsb file path
- `physics_config`: Physics world configuration to include
- `compress_textures`: Whether to compress textures (PNG) in the output
"""
function export_scene(scene::Scene, path::String;
                       physics_config::PhysicsWorldConfig = PhysicsWorldConfig(),
                       compress_textures::Bool = true)

    entities = scene.entities
    num_entities = length(entities)

    # Build entity index map (EntityID → array index)
    entity_index = Dict{EntityID, UInt32}()
    for (i, eid) in enumerate(entities)
        entity_index[eid] = UInt32(i - 1)
    end

    # Build parent map
    parent_map = Dict{EntityID, EntityID}()
    for (parent, children) in scene.hierarchy
        for child in children
            parent_map[child] = parent
        end
    end

    # Collect unique meshes, materials, textures
    unique_meshes = MeshComponent[]
    mesh_index_map = Dict{UInt64, UInt32}()  # objectid hash → index
    unique_materials = MaterialComponent[]
    material_index_map = Dict{UInt64, UInt32}()
    unique_textures = String[]
    texture_index_map = Dict{String, Int32}()

    for eid in entities
        if has_component(eid, MeshComponent)
            mesh = get_component(eid, MeshComponent)
            h = objectid(mesh)
            if !haskey(mesh_index_map, h)
                mesh_index_map[h] = UInt32(length(unique_meshes))
                push!(unique_meshes, mesh)
            end
        end
        if has_component(eid, MaterialComponent)
            mat = get_component(eid, MaterialComponent)
            h = objectid(mat)
            if !haskey(material_index_map, h)
                material_index_map[h] = UInt32(length(unique_materials))
                push!(unique_materials, mat)
            end
            # Collect texture paths
            for field in [:albedo_map, :normal_map, :metallic_roughness_map, :ao_map,
                          :emissive_map, :height_map, :clearcoat_map]
                if hasproperty(mat, field)
                    tex_ref = getproperty(mat, field)
                    if tex_ref !== nothing && tex_ref isa TextureRef && tex_ref.path != ""
                        if !haskey(texture_index_map, tex_ref.path)
                            texture_index_map[tex_ref.path] = Int32(length(unique_textures))
                            push!(unique_textures, tex_ref.path)
                        end
                    end
                end
            end
        end
    end

    open(path, "w") do io
        # Write header (32 bytes)
        write(io, ORSB_MAGIC...)
        write(io, ORSB_VERSION)
        write(io, UInt32(0))  # flags
        write(io, UInt32(num_entities))
        write(io, UInt32(length(unique_meshes)))
        write(io, UInt32(length(unique_textures)))
        write(io, UInt32(length(unique_materials)))
        write(io, UInt32(0))  # num_animations (populated below)

        # ---- Entity Graph Section ----
        _write_entity_graph(io, entities, entity_index, parent_map,
                            mesh_index_map, material_index_map)

        # ---- Transforms Section ----
        _write_transforms(io, entities)

        # ---- Meshes Section ----
        _write_meshes(io, unique_meshes)

        # ---- Materials Section ----
        _write_materials(io, unique_materials, texture_index_map)

        # ---- Textures Section ----
        _write_textures(io, unique_textures, compress_textures)

        # ---- Lights Section ----
        _write_lights(io, entities)

        # ---- Cameras Section ----
        _write_cameras(io, entities)

        # ---- Colliders Section ----
        _write_colliders(io, entities)

        # ---- RigidBodies Section ----
        _write_rigidbodies(io, entities)

        # ---- Animations Section ----
        _write_animations(io, entities, entity_index)

        # ---- Physics Config Section ----
        _write_physics_config(io, physics_config)
    end

    @info "Exported scene to $path ($(num_entities) entities, $(length(unique_meshes)) meshes, $(length(unique_textures)) textures)"
    return nothing
end

# ---- Internal serialization helpers ----

function _write_entity_graph(io, entities, entity_index, parent_map,
                              mesh_index_map, material_index_map)
    for eid in entities

        # TODO: do not use internals of Ark
        write(io, (UInt64(eid._id) >> 32) | UInt64(eid._gen))

        # Parent index (UInt32_MAX = root)
        parent_idx = haskey(parent_map, eid) ? entity_index[parent_map[eid]] : typemax(UInt32)
        write(io, parent_idx)

        # Component mask
        mask = UInt64(0)
        has_component(eid, TransformComponent)     && (mask |= CMASK_TRANSFORM)
        has_component(eid, MeshComponent)           && (mask |= CMASK_MESH)
        has_component(eid, MaterialComponent)       && (mask |= CMASK_MATERIAL)
        has_component(eid, CameraComponent)         && (mask |= CMASK_CAMERA)
        has_component(eid, PointLightComponent)     && (mask |= CMASK_POINT_LIGHT)
        has_component(eid, DirectionalLightComponent) && (mask |= CMASK_DIR_LIGHT)
        has_component(eid, ColliderComponent)       && (mask |= CMASK_COLLIDER)
        has_component(eid, RigidBodyComponent)      && (mask |= CMASK_RIGIDBODY)
        has_component(eid, AnimationComponent)      && (mask |= CMASK_ANIMATION)
        has_component(eid, SkinnedMeshComponent)    && (mask |= CMASK_SKELETON)
        has_component(eid, ParticleSystemComponent) && (mask |= CMASK_PARTICLE)
        write(io, mask)

        # Component indices (UInt32_MAX if not present)
        NO_IDX = typemax(UInt32)

        # Mesh index
        if has_component(eid, MeshComponent)
            mesh = get_component(eid, MeshComponent)
            write(io, mesh_index_map[objectid(mesh)])
        else
            write(io, NO_IDX)
        end

        # Material index
        if has_component(eid, MaterialComponent)
            mat = get_component(eid, MaterialComponent)
            write(io, material_index_map[objectid(mat)])
        else
            write(io, NO_IDX)
        end
    end
end

function _write_transforms(io, entities)
    for eid in entities
        if has_component(eid, TransformComponent)
            t = get_component(eid, TransformComponent)
            pos = t.position[]
            rot = t.rotation[]
            scl = t.scale[]
            write(io, Float64(pos[1]), Float64(pos[2]), Float64(pos[3]))
            write(io, Float64(rot.s), Float64(rot.v1), Float64(rot.v2), Float64(rot.v3))
            write(io, Float64(scl[1]), Float64(scl[2]), Float64(scl[3]))
        else
            # Identity transform
            write(io, 0.0, 0.0, 0.0)           # position
            write(io, 1.0, 0.0, 0.0, 0.0)      # rotation (identity quaternion)
            write(io, 1.0, 1.0, 1.0)            # scale
        end
    end
end

function _write_meshes(io, meshes)
    for mesh in meshes
        nv = length(mesh.vertices)
        ni = length(mesh.indices)
        has_bones = !isempty(mesh.bone_weights)

        write(io, UInt32(nv))
        write(io, UInt32(ni))
        write(io, UInt32(has_bones ? 1 : 0))
        write(io, UInt32(0))  # padding

        # Positions
        for v in mesh.vertices
            write(io, Float32(v[1]), Float32(v[2]), Float32(v[3]))
        end

        # Normals
        for n in mesh.normals
            write(io, Float32(n[1]), Float32(n[2]), Float32(n[3]))
        end

        # UVs
        for uv in mesh.uvs
            write(io, Float32(uv[1]), Float32(uv[2]))
        end

        # Indices
        for idx in mesh.indices
            write(io, UInt32(idx))
        end

        # Bone data (if present)
        if has_bones
            for bw in mesh.bone_weights
                write(io, Float32(bw[1]), Float32(bw[2]), Float32(bw[3]), Float32(bw[4]))
            end
            for bi in mesh.bone_indices
                write(io, UInt16(bi[1]), UInt16(bi[2]), UInt16(bi[3]), UInt16(bi[4]))
            end
        end
    end
end

function _write_materials(io, materials, texture_index_map)
    for mat in materials
        write(io, Float32(mat.color.r), Float32(mat.color.g), Float32(mat.color.b), Float32(1.0))
        write(io, Float32(mat.metallic))
        write(io, Float32(mat.roughness))
        write(io, Float32(mat.opacity))
        write(io, Float32(mat.alpha_cutoff))
        write(io, Float32(mat.emissive_factor[1]), Float32(mat.emissive_factor[2]),
              Float32(mat.emissive_factor[3]), Float32(0.0))

        # Advanced material properties
        clearcoat = hasproperty(mat, :clearcoat) ? Float32(mat.clearcoat) : Float32(0)
        clearcoat_roughness = hasproperty(mat, :clearcoat_roughness) ? Float32(mat.clearcoat_roughness) : Float32(0)
        subsurface = hasproperty(mat, :subsurface) ? Float32(mat.subsurface) : Float32(0)
        parallax = hasproperty(mat, :parallax_height_scale) ? Float32(mat.parallax_height_scale) : Float32(0)
        write(io, clearcoat, clearcoat_roughness, subsurface, parallax)

        # Texture indices
        for field in [:albedo_map, :normal_map, :metallic_roughness_map, :ao_map,
                      :emissive_map, :height_map, :clearcoat_map]
            if hasproperty(mat, field)
                tex_ref = getproperty(mat, field)
                if tex_ref !== nothing && tex_ref isa TextureRef && tex_ref.path != "" && haskey(texture_index_map, tex_ref.path)
                    write(io, texture_index_map[tex_ref.path])
                else
                    write(io, Int32(-1))
                end
            else
                write(io, Int32(-1))
            end
        end
        write(io, Int32(0))  # padding
    end
end

function _write_textures(io, texture_paths, compress)
    for path in texture_paths
        if isfile(path)
            data = read(path)
            # Write PNG data directly (already compressed)
            write(io, UInt32(0))  # width (extracted by loader)
            write(io, UInt32(0))  # height
            write(io, UInt32(0))  # channels
            write(io, UInt32(1))  # compression = PNG
            write(io, UInt64(length(data)))
            write(io, data)
        else
            # Missing texture — write empty marker
            write(io, UInt32(0), UInt32(0), UInt32(0), UInt32(0))
            write(io, UInt64(0))
        end
    end
end

function _write_lights(io, entities)
    # Point lights
    point_lights = EntityID[]
    dir_lights = EntityID[]
    for eid in entities
        has_component(eid, PointLightComponent) && push!(point_lights, eid)
        has_component(eid, DirectionalLightComponent) && push!(dir_lights, eid)
    end

    write(io, UInt32(length(point_lights)))
    for eid in point_lights
        light = get_component(eid, PointLightComponent)
        pos = has_component(eid, TransformComponent) ? get_component(eid, TransformComponent).position[] : (0.0, 0.0, 0.0)
        write(io, Float32(pos[1]), Float32(pos[2]), Float32(pos[3]))
        write(io, Float32(light.color.r), Float32(light.color.g), Float32(light.color.b))
        write(io, Float32(light.intensity))
        write(io, Float32(light.range))
    end

    write(io, UInt32(length(dir_lights)))
    for eid in dir_lights
        light = get_component(eid, DirectionalLightComponent)
        write(io, Float32(light.direction[1]), Float32(light.direction[2]), Float32(light.direction[3]))
        write(io, Float32(light.color.r), Float32(light.color.g), Float32(light.color.b))
        write(io, Float32(light.intensity))
        write(io, Float32(0))  # padding
    end
end

function _write_cameras(io, entities)
    cameras = EntityID[]
    for eid in entities
        has_component(eid, CameraComponent) && push!(cameras, eid)
    end

    write(io, UInt32(length(cameras)))
    for eid in cameras
        cam = get_component(eid, CameraComponent)
        write(io, Float32(cam.fov), Float32(cam.near), Float32(cam.far), Float32(cam.aspect))
    end
end

function _write_colliders(io, entities)
    colliders = EntityID[]
    for eid in entities
        has_component(eid, ColliderComponent) && push!(colliders, eid)
    end

    write(io, UInt32(length(colliders)))
    for eid in colliders
        col = get_component(eid, ColliderComponent)
        shape = col.shape

        if shape isa AABBShape
            write(io, UInt8(0))
            write(io, Float32(shape.half_extents[1]), Float32(shape.half_extents[2]), Float32(shape.half_extents[3]))
        elseif shape isa SphereShape
            write(io, UInt8(1))
            write(io, Float32(shape.radius), Float32(0), Float32(0))
        elseif shape isa CapsuleShape
            write(io, UInt8(2))
            write(io, Float32(shape.radius), Float32(shape.half_height), Float32(0))
        else
            write(io, UInt8(0))
            write(io, Float32(0.5), Float32(0.5), Float32(0.5))
        end

        write(io, Float32(col.offset[1]), Float32(col.offset[2]), Float32(col.offset[3]))
        write(io, UInt8(col.is_trigger ? 1 : 0))
        write(io, UInt8(0), UInt8(0), UInt8(0))  # padding
    end
end

function _write_rigidbodies(io, entities)
    bodies = EntityID[]
    for eid in entities
        has_component(eid, RigidBodyComponent) && push!(bodies, eid)
    end

    write(io, UInt32(length(bodies)))
    for eid in bodies
        rb = get_component(eid, RigidBodyComponent)
        body_type = rb.body_type == BODY_STATIC ? UInt8(0) :
                    rb.body_type == BODY_KINEMATIC ? UInt8(1) : UInt8(2)
        ccd = rb.ccd_mode == CCD_SWEPT ? UInt8(1) : UInt8(0)

        write(io, body_type, ccd, UInt8(0), UInt8(0))
        write(io, Float64(rb.mass))
        write(io, Float32(rb.restitution))
        write(io, Float64(rb.friction))
        write(io, Float64(rb.linear_damping))
        write(io, Float64(rb.angular_damping))
    end
end

function _write_animations(io, entities, entity_index)
    anims = EntityID[]
    for eid in entities
        has_component(eid, AnimationComponent) && push!(anims, eid)
    end

    write(io, UInt32(length(anims)))
    for eid in anims
        anim = get_component(eid, AnimationComponent)
        write(io, UInt32(length(anim.clips)))

        for clip in anim.clips
            # Clip name
            name_bytes = Vector{UInt8}(clip.name)
            write(io, UInt16(length(name_bytes)))
            write(io, name_bytes...)

            write(io, UInt32(length(clip.channels)))
            write(io, Float32(clip.duration))

            for channel in clip.channels
                # Target entity index
                target_idx = haskey(entity_index, channel.target) ? entity_index[channel.target] : typemax(UInt32)
                write(io, target_idx)

                # Target property
                prop = channel.property == :position ? UInt8(0) :
                       channel.property == :rotation ? UInt8(1) : UInt8(2)
                write(io, prop)

                # Interpolation mode
                interp = channel.interpolation == INTERP_STEP ? UInt8(0) :
                         channel.interpolation == INTERP_LINEAR ? UInt8(1) : UInt8(2)
                write(io, interp)

                # Keyframes
                write(io, UInt32(length(channel.times)))
                for t in channel.times
                    write(io, Float32(t))
                end
                for v in channel.values
                    if channel.property == :rotation
                        # Quaternion: w, x, y, z
                        write(io, Float64(v.s), Float64(v.v1), Float64(v.v2), Float64(v.v3))
                    else
                        # Vec3
                        write(io, Float64(v[1]), Float64(v[2]), Float64(v[3]))
                    end
                end
            end
        end

        write(io, Int32(anim.active_clip))
        write(io, UInt8(anim.playing ? 1 : 0))
        write(io, UInt8(anim.looping ? 1 : 0))
        write(io, Float32(anim.speed))
    end
end

function _write_physics_config(io, config)
    write(io, Float64(config.gravity[1]), Float64(config.gravity[2]), Float64(config.gravity[3]))
    write(io, Float64(config.fixed_dt))
    write(io, UInt32(config.max_substeps))
    write(io, UInt32(config.solver_iterations))
    write(io, Float32(config.position_correction))
    write(io, Float32(config.slop))
end
