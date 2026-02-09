# Mesh component

"""
    MeshComponent <: Component

Represents a 3D mesh with vertices, indices, normals, and UV coordinates.
"""
struct MeshComponent <: Component
    vertices::Vector{Point3f}
    indices::Vector{UInt32}
    normals::Vector{Vec3f}
    uvs::Vector{Vec2f}

    MeshComponent(;
        vertices::Vector{Point3f} = Point3f[],
        indices::Vector{UInt32} = UInt32[],
        normals::Vector{Vec3f} = Vec3f[],
        uvs::Vector{Vec2f} = Vec2f[]
    ) = new(vertices, indices, normals, uvs)
end
