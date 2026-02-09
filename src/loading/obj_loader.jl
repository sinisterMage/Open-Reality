# OBJ model loader

"""
    load_obj(path::String; default_material=nothing) -> Vector{EntityDef}

Load a Wavefront OBJ file and return a vector of EntityDefs.

Uses MeshIO via FileIO for parsing.
"""
function load_obj(path::String;
                  default_material::Union{MaterialComponent, Nothing} = nothing)
    raw_mesh = FileIO.load(path)

    # Extract positions
    coords = GeometryBasics.coordinates(raw_mesh)
    positions = Point3f[Point3f(Float32(p[1]), Float32(p[2]), Float32(p[3])) for p in coords]

    # Extract faces and flatten to triangle indices
    raw_faces = GeometryBasics.faces(raw_mesh)
    indices = UInt32[]
    for face in raw_faces
        idxs = collect(face)
        for idx in idxs
            push!(indices, UInt32(Int(idx) - 1))  # GeometryBasics uses 1-based
        end
    end

    # Extract normals if available
    normals = Vec3f[]
    try
        raw_normals = GeometryBasics.normals(raw_mesh)
        normals = Vec3f[Vec3f(Float32(n[1]), Float32(n[2]), Float32(n[3])) for n in raw_normals]
    catch
        normals = _compute_averaged_normals(positions, indices)
    end

    # Extract UVs if available
    uvs = Vec2f[]
    try
        attrs = raw_mesh.uv
        uvs = Vec2f[Vec2f(Float32(uv[1]), Float32(uv[2])) for uv in attrs]
    catch
        # No UVs available
    end

    mat = default_material !== nothing ? default_material : MaterialComponent()
    mesh_comp = MeshComponent(vertices=positions, indices=indices, normals=normals, uvs=uvs)

    return [entity([mesh_comp, mat, transform()])]
end

"""
    _compute_averaged_normals(positions, indices) -> Vector{Vec3f}

Compute per-vertex normals by averaging face normals.
"""
function _compute_averaged_normals(positions::Vector{Point3f}, indices::Vector{UInt32})
    normals = fill(Vec3f(0, 0, 0), length(positions))

    for i in 1:3:length(indices)
        i0 = Int(indices[i]) + 1
        i1 = Int(indices[i+1]) + 1
        i2 = Int(indices[i+2]) + 1

        if i0 > length(positions) || i1 > length(positions) || i2 > length(positions)
            continue
        end

        v0 = Vec3f(positions[i0]...)
        v1 = Vec3f(positions[i1]...)
        v2 = Vec3f(positions[i2]...)

        edge1 = v1 - v0
        edge2 = v2 - v0
        n = cross(edge1, edge2)
        len = sqrt(n[1]^2 + n[2]^2 + n[3]^2)
        if len > 0
            n = n / len
        end

        normals[i0] = normals[i0] + n
        normals[i1] = normals[i1] + n
        normals[i2] = normals[i2] + n
    end

    return [begin
        len = sqrt(n[1]^2 + n[2]^2 + n[3]^2)
        len > 0 ? n / len : Vec3f(0, 1, 0)
    end for n in normals]
end
