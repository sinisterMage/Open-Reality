# Collider component for collision detection

"""
    ColliderShape

Abstract base type for collider shapes.
"""
abstract type ColliderShape end

"""
    AABBShape <: ColliderShape

Axis-Aligned Bounding Box collider defined by half-extents from center.
"""
struct AABBShape <: ColliderShape
    half_extents::Vec3f
end

"""
    SphereShape <: ColliderShape

Sphere collider defined by a radius.
"""
struct SphereShape <: ColliderShape
    radius::Float32
end

"""
    ColliderComponent <: Component

Attaches a collision shape to an entity. The shape is defined in local space;
the physics system uses the entity's world transform to position it.

`offset` shifts the collider relative to the entity's origin.
"""
struct ColliderComponent <: Component
    shape::ColliderShape
    offset::Vec3f

    ColliderComponent(;
        shape::ColliderShape = AABBShape(Vec3f(0.5, 0.5, 0.5)),
        offset::Vec3f = Vec3f(0, 0, 0)
    ) = new(shape, offset)
end

"""
    collider_from_mesh(mesh::MeshComponent) -> ColliderComponent

Auto-generate an AABB collider from mesh vertex bounds.
"""
function collider_from_mesh(mesh::MeshComponent)
    if isempty(mesh.vertices)
        return ColliderComponent()
    end

    min_pt = Vec3f(Inf32, Inf32, Inf32)
    max_pt = Vec3f(-Inf32, -Inf32, -Inf32)

    for v in mesh.vertices
        min_pt = Vec3f(min(min_pt[1], v[1]), min(min_pt[2], v[2]), min(min_pt[3], v[3]))
        max_pt = Vec3f(max(max_pt[1], v[1]), max(max_pt[2], v[2]), max(max_pt[3], v[3]))
    end

    center = (min_pt + max_pt) * 0.5f0
    half_ext = (max_pt - min_pt) * 0.5f0

    return ColliderComponent(shape=AABBShape(half_ext), offset=center)
end

"""
    sphere_collider_from_mesh(mesh::MeshComponent) -> ColliderComponent

Auto-generate a sphere collider that bounds all mesh vertices.
"""
function sphere_collider_from_mesh(mesh::MeshComponent)
    if isempty(mesh.vertices)
        return ColliderComponent(shape=SphereShape(0.5f0))
    end

    center = Vec3f(0, 0, 0)
    for v in mesh.vertices
        center = center + Vec3f(v[1], v[2], v[3])
    end
    center = center / Float32(length(mesh.vertices))

    max_dist_sq = 0.0f0
    for v in mesh.vertices
        d = Vec3f(v[1], v[2], v[3]) - center
        dist_sq = d[1]^2 + d[2]^2 + d[3]^2
        max_dist_sq = max(max_dist_sq, dist_sq)
    end

    return ColliderComponent(shape=SphereShape(sqrt(max_dist_sq)), offset=center)
end
