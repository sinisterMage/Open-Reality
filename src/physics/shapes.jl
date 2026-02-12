# Shape definitions and AABB computation for physics broadphase

"""
    CapsuleAxis

Axis along which a capsule is oriented.
"""
@enum CapsuleAxis CAPSULE_X CAPSULE_Y CAPSULE_Z

"""
    CapsuleShape <: ColliderShape

Capsule collider: a cylinder with hemispherical caps.
- `radius`: radius of the cylinder and hemispherical caps
- `half_height`: half the height of the cylindrical section (total height = 2*half_height + 2*radius)
- `axis`: orientation axis (default Y)
"""
struct CapsuleShape <: ColliderShape
    radius::Float32
    half_height::Float32
    axis::CapsuleAxis

    CapsuleShape(;
        radius::Float32 = 0.5f0,
        half_height::Float32 = 0.5f0,
        axis::CapsuleAxis = CAPSULE_Y
    ) = new(radius, half_height, axis)
end

"""
    OBBShape <: ColliderShape

Oriented Bounding Box collider. Uses the entity's rotation for orientation.
- `half_extents`: half-extents along local X, Y, Z axes.
"""
struct OBBShape <: ColliderShape
    half_extents::Vec3f
end

"""
    ConvexHullShape <: ColliderShape

Convex hull collider from a set of vertices.
The convex hull is assumed to be precomputed (vertices should form a convex shape).
"""
struct ConvexHullShape <: ColliderShape
    vertices::Vector{Vec3f}
end

"""
    CompoundChild

A child shape within a compound collider, with its own local transform.
"""
struct CompoundChild
    shape::ColliderShape
    local_position::Vec3d
    local_rotation::Quaternion{Float64}
end

CompoundChild(shape::ColliderShape; position::Vec3d=Vec3d(0,0,0),
              rotation::Quaternion{Float64}=Quaternion(1.0, 0.0, 0.0, 0.0)) =
    CompoundChild(shape, position, rotation)

"""
    CompoundShape <: ColliderShape

Compound collider made of multiple child shapes, each with its own local transform.
Broadphase uses the union AABB of all children.
Narrowphase tests each child independently.
"""
struct CompoundShape <: ColliderShape
    children::Vector{CompoundChild}
end

"""
    compute_world_aabb(shape::ColliderShape, position::Vec3d, rotation::Quaternion{Float64}, scale::Vec3d, offset::Vec3f) -> AABB3D

Compute world-space AABB for a collider shape, accounting for position, rotation, and scale.
"""
function compute_world_aabb(shape::AABBShape, position::Vec3d, rotation::Quaternion{Float64},
                            scale::Vec3d, offset::Vec3f)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    he = Vec3d(Float64(shape.half_extents[1]),
               Float64(shape.half_extents[2]),
               Float64(shape.half_extents[3]))

    # For rotated AABB, compute the transformed extents
    R = rotation_matrix(rotation)
    # Extract 3x3 rotation part and take absolute values for AABB
    aabb_he = Vec3d(0.0, 0.0, 0.0)
    for i in 1:3
        extent_i = 0.0
        for j in 1:3
            extent_i += abs(R[i, j]) * he[j] * scale[j]
        end
        aabb_he = setindex(aabb_he, extent_i, i)
    end
    return AABB3D(center - aabb_he, center + aabb_he)
end

function compute_world_aabb(shape::SphereShape, position::Vec3d, rotation::Quaternion{Float64},
                            scale::Vec3d, offset::Vec3f)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    r = Float64(shape.radius) * max(scale[1], scale[2], scale[3])
    rv = Vec3d(r, r, r)
    return AABB3D(center - rv, center + rv)
end

function compute_world_aabb(shape::CapsuleShape, position::Vec3d, rotation::Quaternion{Float64},
                            scale::Vec3d, offset::Vec3f)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    r = Float64(shape.radius)
    hh = Float64(shape.half_height)

    # Get the capsule's local axis direction
    local_axis = if shape.axis == CAPSULE_X
        Vec3d(1, 0, 0)
    elseif shape.axis == CAPSULE_Y
        Vec3d(0, 1, 0)
    else
        Vec3d(0, 0, 1)
    end

    # Rotate the axis into world space
    R = rotation_matrix(rotation)
    world_axis = Vec3d(
        R[1,1]*local_axis[1] + R[1,2]*local_axis[2] + R[1,3]*local_axis[3],
        R[2,1]*local_axis[1] + R[2,2]*local_axis[2] + R[2,3]*local_axis[3],
        R[3,1]*local_axis[1] + R[3,2]*local_axis[2] + R[3,3]*local_axis[3]
    )

    # Scale the capsule dimensions
    max_scale = max(scale[1], scale[2], scale[3])
    scaled_r = r * max_scale
    scaled_hh = hh * max_scale

    # AABB from the two hemisphere centers + radius
    tip_a = center + world_axis * scaled_hh
    tip_b = center - world_axis * scaled_hh

    min_pt = Vec3d(
        min(tip_a[1], tip_b[1]) - scaled_r,
        min(tip_a[2], tip_b[2]) - scaled_r,
        min(tip_a[3], tip_b[3]) - scaled_r
    )
    max_pt = Vec3d(
        max(tip_a[1], tip_b[1]) + scaled_r,
        max(tip_a[2], tip_b[2]) + scaled_r,
        max(tip_a[3], tip_b[3]) + scaled_r
    )
    return AABB3D(min_pt, max_pt)
end

"""
    get_capsule_segment(shape::CapsuleShape, position::Vec3d, rotation::Quaternion{Float64}, scale::Vec3d, offset::Vec3f) -> (Vec3d, Vec3d)

Get the world-space endpoints of a capsule's central line segment.
"""
function get_capsule_segment(shape::CapsuleShape, position::Vec3d, rotation::Quaternion{Float64},
                              scale::Vec3d, offset::Vec3f)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale

    local_axis = if shape.axis == CAPSULE_X
        Vec3d(1, 0, 0)
    elseif shape.axis == CAPSULE_Y
        Vec3d(0, 1, 0)
    else
        Vec3d(0, 0, 1)
    end

    R = rotation_matrix(rotation)
    world_axis = Vec3d(
        R[1,1]*local_axis[1] + R[1,2]*local_axis[2] + R[1,3]*local_axis[3],
        R[2,1]*local_axis[1] + R[2,2]*local_axis[2] + R[2,3]*local_axis[3],
        R[3,1]*local_axis[1] + R[3,2]*local_axis[2] + R[3,3]*local_axis[3]
    )

    max_scale = max(scale[1], scale[2], scale[3])
    scaled_hh = Float64(shape.half_height) * max_scale

    return (center + world_axis * scaled_hh, center - world_axis * scaled_hh)
end

"""
    get_capsule_world_radius(shape::CapsuleShape, scale::Vec3d) -> Float64

Get the world-space radius of a capsule after scaling.
"""
function get_capsule_world_radius(shape::CapsuleShape, scale::Vec3d)
    return Float64(shape.radius) * max(scale[1], scale[2], scale[3])
end

function compute_world_aabb(shape::OBBShape, position::Vec3d, rotation::Quaternion{Float64},
                            scale::Vec3d, offset::Vec3f)
    # OBB AABB = same as AABB but using entity rotation
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    he = Vec3d(Float64(shape.half_extents[1]),
               Float64(shape.half_extents[2]),
               Float64(shape.half_extents[3]))

    R = rotation_matrix(rotation)
    aabb_he = Vec3d(0.0, 0.0, 0.0)
    for i in 1:3
        extent_i = 0.0
        for j in 1:3
            extent_i += abs(R[i, j]) * he[j] * scale[j]
        end
        aabb_he = setindex(aabb_he, extent_i, i)
    end
    return AABB3D(center - aabb_he, center + aabb_he)
end

function compute_world_aabb(shape::ConvexHullShape, position::Vec3d, rotation::Quaternion{Float64},
                            scale::Vec3d, offset::Vec3f)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    R = rotation_matrix(rotation)

    min_pt = Vec3d(Inf, Inf, Inf)
    max_pt = Vec3d(-Inf, -Inf, -Inf)

    for v in shape.vertices
        # Transform vertex to world space
        local_v = Vec3d(Float64(v[1]) * scale[1], Float64(v[2]) * scale[2], Float64(v[3]) * scale[3])
        world_v = Vec3d(
            R[1,1]*local_v[1] + R[1,2]*local_v[2] + R[1,3]*local_v[3],
            R[2,1]*local_v[1] + R[2,2]*local_v[2] + R[2,3]*local_v[3],
            R[3,1]*local_v[1] + R[3,2]*local_v[2] + R[3,3]*local_v[3]
        ) + center
        min_pt = Vec3d(min(min_pt[1], world_v[1]), min(min_pt[2], world_v[2]), min(min_pt[3], world_v[3]))
        max_pt = Vec3d(max(max_pt[1], world_v[1]), max(max_pt[2], world_v[2]), max(max_pt[3], world_v[3]))
    end

    return AABB3D(min_pt, max_pt)
end

# =============================================================================
# GJK Support functions
# =============================================================================

"""
    gjk_support(shape::ColliderShape, position::Vec3d, rotation::Quaternion{Float64},
                scale::Vec3d, offset::Vec3f, direction::Vec3d) -> Vec3d

Compute the support point of a shape in a given direction (farthest point along direction).
Used by GJK/EPA algorithms.
"""
function gjk_support(shape::SphereShape, position::Vec3d, rotation::Quaternion{Float64},
                     scale::Vec3d, offset::Vec3f, direction::Vec3d)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    r = Float64(shape.radius) * max(scale[1], scale[2], scale[3])
    d_len = vec3d_length(direction)
    if d_len < COLLISION_EPSILON
        return center
    end
    return center + direction * (r / d_len)
end

function gjk_support(shape::AABBShape, position::Vec3d, rotation::Quaternion{Float64},
                     scale::Vec3d, offset::Vec3f, direction::Vec3d)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    he = Vec3d(Float64(shape.half_extents[1]) * scale[1],
               Float64(shape.half_extents[2]) * scale[2],
               Float64(shape.half_extents[3]) * scale[3])
    R = rotation_matrix(rotation)
    # Transform direction to local space
    local_dir = Vec3d(
        R[1,1]*direction[1] + R[2,1]*direction[2] + R[3,1]*direction[3],
        R[1,2]*direction[1] + R[2,2]*direction[2] + R[3,2]*direction[3],
        R[1,3]*direction[1] + R[2,3]*direction[2] + R[3,3]*direction[3]
    )
    local_support = Vec3d(
        local_dir[1] >= 0 ? he[1] : -he[1],
        local_dir[2] >= 0 ? he[2] : -he[2],
        local_dir[3] >= 0 ? he[3] : -he[3]
    )
    # Transform back to world
    return center + Vec3d(
        R[1,1]*local_support[1] + R[1,2]*local_support[2] + R[1,3]*local_support[3],
        R[2,1]*local_support[1] + R[2,2]*local_support[2] + R[2,3]*local_support[3],
        R[3,1]*local_support[1] + R[3,2]*local_support[2] + R[3,3]*local_support[3]
    )
end

function gjk_support(shape::OBBShape, position::Vec3d, rotation::Quaternion{Float64},
                     scale::Vec3d, offset::Vec3f, direction::Vec3d)
    # Same as AABB support but always uses rotation
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    he = Vec3d(Float64(shape.half_extents[1]) * scale[1],
               Float64(shape.half_extents[2]) * scale[2],
               Float64(shape.half_extents[3]) * scale[3])
    R = rotation_matrix(rotation)
    local_dir = Vec3d(
        R[1,1]*direction[1] + R[2,1]*direction[2] + R[3,1]*direction[3],
        R[1,2]*direction[1] + R[2,2]*direction[2] + R[3,2]*direction[3],
        R[1,3]*direction[1] + R[2,3]*direction[2] + R[3,3]*direction[3]
    )
    local_support = Vec3d(
        local_dir[1] >= 0 ? he[1] : -he[1],
        local_dir[2] >= 0 ? he[2] : -he[2],
        local_dir[3] >= 0 ? he[3] : -he[3]
    )
    return center + Vec3d(
        R[1,1]*local_support[1] + R[1,2]*local_support[2] + R[1,3]*local_support[3],
        R[2,1]*local_support[1] + R[2,2]*local_support[2] + R[2,3]*local_support[3],
        R[3,1]*local_support[1] + R[3,2]*local_support[2] + R[3,3]*local_support[3]
    )
end

function gjk_support(shape::ConvexHullShape, position::Vec3d, rotation::Quaternion{Float64},
                     scale::Vec3d, offset::Vec3f, direction::Vec3d)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    R = rotation_matrix(rotation)

    best_dot = -Inf
    best_pt = center

    for v in shape.vertices
        local_v = Vec3d(Float64(v[1]) * scale[1], Float64(v[2]) * scale[2], Float64(v[3]) * scale[3])
        world_v = Vec3d(
            R[1,1]*local_v[1] + R[1,2]*local_v[2] + R[1,3]*local_v[3],
            R[2,1]*local_v[1] + R[2,2]*local_v[2] + R[2,3]*local_v[3],
            R[3,1]*local_v[1] + R[3,2]*local_v[2] + R[3,3]*local_v[3]
        ) + center
        d = vec3d_dot(world_v, direction)
        if d > best_dot
            best_dot = d
            best_pt = world_v
        end
    end

    return best_pt
end

function gjk_support(shape::CapsuleShape, position::Vec3d, rotation::Quaternion{Float64},
                     scale::Vec3d, offset::Vec3f, direction::Vec3d)
    a, b = get_capsule_segment(shape, position, rotation, scale, offset)
    r = get_capsule_world_radius(shape, scale)
    d_len = vec3d_length(direction)
    d_norm = d_len < COLLISION_EPSILON ? Vec3d(0, 1, 0) : direction / d_len

    # Support is the endpoint farthest along direction plus radius
    if vec3d_dot(a, direction) >= vec3d_dot(b, direction)
        return a + d_norm * r
    else
        return b + d_norm * r
    end
end

function compute_world_aabb(shape::CompoundShape, position::Vec3d, rotation::Quaternion{Float64},
                            scale::Vec3d, offset::Vec3f)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale

    min_pt = Vec3d(Inf, Inf, Inf)
    max_pt = Vec3d(-Inf, -Inf, -Inf)

    R_parent = rotation_matrix(rotation)

    for child in shape.children
        # Transform child position to world space
        local_pos = child.local_position .* scale
        world_child_pos = center + Vec3d(
            R_parent[1,1]*local_pos[1] + R_parent[1,2]*local_pos[2] + R_parent[1,3]*local_pos[3],
            R_parent[2,1]*local_pos[1] + R_parent[2,2]*local_pos[2] + R_parent[2,3]*local_pos[3],
            R_parent[3,1]*local_pos[1] + R_parent[3,2]*local_pos[2] + R_parent[3,3]*local_pos[3]
        )
        # Compose rotations
        child_rot = rotation * child.local_rotation
        # Compute child AABB in world space
        child_aabb = compute_world_aabb(child.shape, world_child_pos, child_rot, scale, Vec3f(0, 0, 0))
        min_pt = Vec3d(min(min_pt[1], child_aabb.min_pt[1]),
                       min(min_pt[2], child_aabb.min_pt[2]),
                       min(min_pt[3], child_aabb.min_pt[3]))
        max_pt = Vec3d(max(max_pt[1], child_aabb.max_pt[1]),
                       max(max_pt[2], child_aabb.max_pt[2]),
                       max(max_pt[3], child_aabb.max_pt[3]))
    end

    return AABB3D(min_pt, max_pt)
end

function gjk_support(shape::CompoundShape, position::Vec3d, rotation::Quaternion{Float64},
                     scale::Vec3d, offset::Vec3f, direction::Vec3d)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    R_parent = rotation_matrix(rotation)

    best_dot = -Inf
    best_pt = center

    for child in shape.children
        local_pos = child.local_position .* scale
        world_child_pos = center + Vec3d(
            R_parent[1,1]*local_pos[1] + R_parent[1,2]*local_pos[2] + R_parent[1,3]*local_pos[3],
            R_parent[2,1]*local_pos[1] + R_parent[2,2]*local_pos[2] + R_parent[2,3]*local_pos[3],
            R_parent[3,1]*local_pos[1] + R_parent[3,2]*local_pos[2] + R_parent[3,3]*local_pos[3]
        )
        child_rot = rotation * child.local_rotation
        pt = gjk_support(child.shape, world_child_pos, child_rot, scale, Vec3f(0, 0, 0), direction)
        d = vec3d_dot(pt, direction)
        if d > best_dot
            best_dot = d
            best_pt = pt
        end
    end

    return best_pt
end

"""
    get_entity_physics_aabb(entity_id::EntityID) -> Union{AABB3D, Nothing}

Compute the physics AABB for an entity from its collider and transform.
"""
function get_entity_physics_aabb(entity_id::EntityID)
    collider = get_component(entity_id, ColliderComponent)
    collider === nothing && return nothing

    tc = get_component(entity_id, TransformComponent)
    tc === nothing && return nothing

    return compute_world_aabb(collider.shape, tc.position[], tc.rotation[], tc.scale[], collider.offset)
end
