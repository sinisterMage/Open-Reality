# Narrowphase collision detection: shape-pair specific tests
# Returns ContactManifold with contact normal pointing from A to B

const COLLISION_EPSILON = 1e-10

"""
    vec3d_dot(a::Vec3d, b::Vec3d) -> Float64
"""
@inline function vec3d_dot(a::Vec3d, b::Vec3d)
    return a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
end

"""
    vec3d_length(v::Vec3d) -> Float64
"""
@inline function vec3d_length(v::Vec3d)
    return sqrt(v[1]*v[1] + v[2]*v[2] + v[3]*v[3])
end

"""
    vec3d_normalize(v::Vec3d) -> Vec3d
"""
@inline function vec3d_normalize(v::Vec3d)
    l = vec3d_length(v)
    l < COLLISION_EPSILON && return Vec3d(0, 1, 0)
    return v / l
end

"""
    vec3d_cross(a::Vec3d, b::Vec3d) -> Vec3d
"""
@inline function vec3d_cross(a::Vec3d, b::Vec3d)
    return Vec3d(
        a[2]*b[3] - a[3]*b[2],
        a[3]*b[1] - a[1]*b[3],
        a[1]*b[2] - a[2]*b[1]
    )
end

# =============================================================================
# Collision detection dispatch
# =============================================================================

"""
    collide(entity_a::EntityID, entity_b::EntityID) -> Union{ContactManifold, Nothing}

Perform narrowphase collision between two entities.
Dispatches to the appropriate shape-pair test.
"""
function collide(entity_a::EntityID, entity_b::EntityID)
    ca = get_component(entity_a, ColliderComponent)
    cb = get_component(entity_b, ColliderComponent)
    ta = get_component(entity_a, TransformComponent)
    tb = get_component(entity_b, TransformComponent)
    (ca === nothing || cb === nothing || ta === nothing || tb === nothing) && return nothing

    return _collide_shapes(
        ca.shape, ta.position[], ta.rotation[], ta.scale[], ca.offset,
        cb.shape, tb.position[], tb.rotation[], tb.scale[], cb.offset,
        entity_a, entity_b
    )
end

# =============================================================================
# Shape-pair dispatch table
# =============================================================================

# Sphere vs Sphere
function _collide_shapes(sa::SphereShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::SphereShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    center_a = pos_a + Vec3d(Float64(off_a[1]), Float64(off_a[2]), Float64(off_a[3])) .* scl_a
    center_b = pos_b + Vec3d(Float64(off_b[1]), Float64(off_b[2]), Float64(off_b[3])) .* scl_b
    ra = Float64(sa.radius) * max(scl_a[1], scl_a[2], scl_a[3])
    rb = Float64(sb.radius) * max(scl_b[1], scl_b[2], scl_b[3])

    diff = center_b - center_a
    dist = vec3d_length(diff)
    sum_r = ra + rb

    if dist >= sum_r
        return nothing
    end

    if dist < COLLISION_EPSILON
        normal = Vec3d(0, 1, 0)
    else
        normal = diff / dist
    end

    penetration = sum_r - dist
    contact_pt = center_a + normal * (ra - penetration * 0.5)

    manifold = ContactManifold(eid_a, eid_b, normal)
    push!(manifold.points, ContactPoint(contact_pt, normal, penetration))
    return manifold
end

# AABB vs AABB (SAT with 3 axes)
function _collide_shapes(sa::AABBShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::AABBShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    center_a = pos_a + Vec3d(Float64(off_a[1]), Float64(off_a[2]), Float64(off_a[3])) .* scl_a
    center_b = pos_b + Vec3d(Float64(off_b[1]), Float64(off_b[2]), Float64(off_b[3])) .* scl_b
    he_a = Vec3d(Float64(sa.half_extents[1]) * scl_a[1],
                 Float64(sa.half_extents[2]) * scl_a[2],
                 Float64(sa.half_extents[3]) * scl_a[3])
    he_b = Vec3d(Float64(sb.half_extents[1]) * scl_b[1],
                 Float64(sb.half_extents[2]) * scl_b[2],
                 Float64(sb.half_extents[3]) * scl_b[3])

    min_a = center_a - he_a
    max_a = center_a + he_a
    min_b = center_b - he_b
    max_b = center_b + he_b

    # Check overlap on each axis
    overlap_x = min(max_a[1], max_b[1]) - max(min_a[1], min_b[1])
    overlap_y = min(max_a[2], max_b[2]) - max(min_a[2], min_b[2])
    overlap_z = min(max_a[3], max_b[3]) - max(min_a[3], min_b[3])

    if overlap_x <= 0 || overlap_y <= 0 || overlap_z <= 0
        return nothing
    end

    diff = center_b - center_a

    # Find minimum overlap axis
    if overlap_x <= overlap_y && overlap_x <= overlap_z
        normal = Vec3d(diff[1] >= 0 ? 1.0 : -1.0, 0, 0)
        penetration = overlap_x
    elseif overlap_y <= overlap_z
        normal = Vec3d(0, diff[2] >= 0 ? 1.0 : -1.0, 0)
        penetration = overlap_y
    else
        normal = Vec3d(0, 0, diff[3] >= 0 ? 1.0 : -1.0)
        penetration = overlap_z
    end

    # Contact point at midpoint of overlap region
    contact_pt = (center_a + center_b) * 0.5

    manifold = ContactManifold(eid_a, eid_b, normal)
    push!(manifold.points, ContactPoint(contact_pt, normal, penetration))
    return manifold
end

# Sphere vs AABB
function _collide_shapes(sa::SphereShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::AABBShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    center_a = pos_a + Vec3d(Float64(off_a[1]), Float64(off_a[2]), Float64(off_a[3])) .* scl_a
    center_b = pos_b + Vec3d(Float64(off_b[1]), Float64(off_b[2]), Float64(off_b[3])) .* scl_b
    ra = Float64(sa.radius) * max(scl_a[1], scl_a[2], scl_a[3])
    he_b = Vec3d(Float64(sb.half_extents[1]) * scl_b[1],
                 Float64(sb.half_extents[2]) * scl_b[2],
                 Float64(sb.half_extents[3]) * scl_b[3])

    # Closest point on AABB to sphere center
    closest = Vec3d(
        clamp(center_a[1], center_b[1] - he_b[1], center_b[1] + he_b[1]),
        clamp(center_a[2], center_b[2] - he_b[2], center_b[2] + he_b[2]),
        clamp(center_a[3], center_b[3] - he_b[3], center_b[3] + he_b[3])
    )

    diff = center_a - closest
    dist_sq = vec3d_dot(diff, diff)

    if dist_sq > ra * ra
        return nothing
    end

    dist = sqrt(dist_sq)
    if dist < COLLISION_EPSILON
        # Sphere center is inside AABB — find closest face
        dx_min = (center_b[1] + he_b[1]) - center_a[1]
        dx_max = center_a[1] - (center_b[1] - he_b[1])
        dy_min = (center_b[2] + he_b[2]) - center_a[2]
        dy_max = center_a[2] - (center_b[2] - he_b[2])
        dz_min = (center_b[3] + he_b[3]) - center_a[3]
        dz_max = center_a[3] - (center_b[3] - he_b[3])
        min_dist = min(dx_min, dx_max, dy_min, dy_max, dz_min, dz_max)
        if min_dist == dx_min
            normal = Vec3d(1, 0, 0)
        elseif min_dist == dx_max
            normal = Vec3d(-1, 0, 0)
        elseif min_dist == dy_min
            normal = Vec3d(0, 1, 0)
        elseif min_dist == dy_max
            normal = Vec3d(0, -1, 0)
        elseif min_dist == dz_min
            normal = Vec3d(0, 0, 1)
        else
            normal = Vec3d(0, 0, -1)
        end
        penetration = ra + min_dist
    else
        normal = diff / dist  # Points from AABB toward sphere
        penetration = ra - dist
        normal = -normal  # Flip: A→B (sphere→AABB)
    end

    contact_pt = closest

    manifold = ContactManifold(eid_a, eid_b, normal)
    push!(manifold.points, ContactPoint(contact_pt, normal, penetration))
    return manifold
end

# AABB vs Sphere (swap and flip)
function _collide_shapes(sa::AABBShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::SphereShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    result = _collide_shapes(sb, pos_b, rot_b, scl_b, off_b,
                              sa, pos_a, rot_a, scl_a, off_a,
                              eid_b, eid_a)
    if result !== nothing
        # Flip: swap entities and negate normal
        result.entity_a = eid_a
        result.entity_b = eid_b
        result.normal = -result.normal
        for p in result.points
            p.normal = -p.normal
        end
    end
    return result
end

# =============================================================================
# Capsule collision tests
# =============================================================================

"""
    closest_point_on_segment(a::Vec3d, b::Vec3d, p::Vec3d) -> (Vec3d, Float64)

Find the closest point on line segment AB to point P.
Returns the point and the parameter t ∈ [0,1].
"""
function closest_point_on_segment(a::Vec3d, b::Vec3d, p::Vec3d)
    ab = b - a
    ab_sq = vec3d_dot(ab, ab)
    if ab_sq < COLLISION_EPSILON
        return a, 0.0
    end
    t = clamp(vec3d_dot(p - a, ab) / ab_sq, 0.0, 1.0)
    return a + ab * t, t
end

"""
    closest_points_segments(a1::Vec3d, a2::Vec3d, b1::Vec3d, b2::Vec3d) -> (Vec3d, Vec3d)

Find the closest points between two line segments.
Returns (closest_on_A, closest_on_B).
"""
function closest_points_segments(a1::Vec3d, a2::Vec3d, b1::Vec3d, b2::Vec3d)
    d1 = a2 - a1  # Direction of segment A
    d2 = b2 - b1  # Direction of segment B
    r = a1 - b1

    a = vec3d_dot(d1, d1)
    e = vec3d_dot(d2, d2)
    f = vec3d_dot(d2, r)

    if a < COLLISION_EPSILON && e < COLLISION_EPSILON
        return a1, b1
    end

    if a < COLLISION_EPSILON
        s = 0.0
        t = clamp(f / e, 0.0, 1.0)
    else
        c = vec3d_dot(d1, r)
        if e < COLLISION_EPSILON
            t = 0.0
            s = clamp(-c / a, 0.0, 1.0)
        else
            b_val = vec3d_dot(d1, d2)
            denom = a * e - b_val * b_val
            if abs(denom) > COLLISION_EPSILON
                s = clamp((b_val * f - c * e) / denom, 0.0, 1.0)
            else
                s = 0.0
            end
            t = (b_val * s + f) / e
            if t < 0.0
                t = 0.0
                s = clamp(-c / a, 0.0, 1.0)
            elseif t > 1.0
                t = 1.0
                s = clamp((b_val - c) / a, 0.0, 1.0)
            end
        end
    end

    closest_a = a1 + d1 * s
    closest_b = b1 + d2 * t
    return closest_a, closest_b
end

# Capsule vs Capsule
function _collide_shapes(sa::CapsuleShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::CapsuleShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    a1, a2 = get_capsule_segment(sa, pos_a, rot_a, scl_a, off_a)
    b1, b2 = get_capsule_segment(sb, pos_b, rot_b, scl_b, off_b)
    ra = get_capsule_world_radius(sa, scl_a)
    rb = get_capsule_world_radius(sb, scl_b)

    ca, cb = closest_points_segments(a1, a2, b1, b2)
    diff = cb - ca
    dist = vec3d_length(diff)
    sum_r = ra + rb

    if dist >= sum_r
        return nothing
    end

    normal = dist < COLLISION_EPSILON ? Vec3d(0, 1, 0) : diff / dist
    penetration = sum_r - dist
    contact_pt = ca + normal * (ra - penetration * 0.5)

    manifold = ContactManifold(eid_a, eid_b, normal)
    push!(manifold.points, ContactPoint(contact_pt, normal, penetration))
    return manifold
end

# Capsule vs Sphere
function _collide_shapes(sa::CapsuleShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::SphereShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    a1, a2 = get_capsule_segment(sa, pos_a, rot_a, scl_a, off_a)
    ra = get_capsule_world_radius(sa, scl_a)
    center_b = pos_b + Vec3d(Float64(off_b[1]), Float64(off_b[2]), Float64(off_b[3])) .* scl_b
    rb = Float64(sb.radius) * max(scl_b[1], scl_b[2], scl_b[3])

    closest_a, _ = closest_point_on_segment(a1, a2, center_b)
    diff = center_b - closest_a
    dist = vec3d_length(diff)
    sum_r = ra + rb

    if dist >= sum_r
        return nothing
    end

    normal = dist < COLLISION_EPSILON ? Vec3d(0, 1, 0) : diff / dist
    penetration = sum_r - dist
    contact_pt = closest_a + normal * (ra - penetration * 0.5)

    manifold = ContactManifold(eid_a, eid_b, normal)
    push!(manifold.points, ContactPoint(contact_pt, normal, penetration))
    return manifold
end

# Sphere vs Capsule (swap and flip)
function _collide_shapes(sa::SphereShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::CapsuleShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    result = _collide_shapes(sb, pos_b, rot_b, scl_b, off_b,
                              sa, pos_a, rot_a, scl_a, off_a,
                              eid_b, eid_a)
    if result !== nothing
        result.entity_a = eid_a
        result.entity_b = eid_b
        result.normal = -result.normal
        for p in result.points
            p.normal = -p.normal
        end
    end
    return result
end

# Capsule vs AABB
function _collide_shapes(sa::CapsuleShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::AABBShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    a1, a2 = get_capsule_segment(sa, pos_a, rot_a, scl_a, off_a)
    ra = get_capsule_world_radius(sa, scl_a)

    center_b = pos_b + Vec3d(Float64(off_b[1]), Float64(off_b[2]), Float64(off_b[3])) .* scl_b
    he_b = Vec3d(Float64(sb.half_extents[1]) * scl_b[1],
                 Float64(sb.half_extents[2]) * scl_b[2],
                 Float64(sb.half_extents[3]) * scl_b[3])

    # Find closest point on capsule segment to AABB
    # Sample multiple points along the segment and find minimum distance
    min_dist = Inf
    best_cap_pt = a1
    best_box_pt = center_b

    for t in 0.0:0.25:1.0
        seg_pt = a1 + (a2 - a1) * t
        box_pt = Vec3d(
            clamp(seg_pt[1], center_b[1] - he_b[1], center_b[1] + he_b[1]),
            clamp(seg_pt[2], center_b[2] - he_b[2], center_b[2] + he_b[2]),
            clamp(seg_pt[3], center_b[3] - he_b[3], center_b[3] + he_b[3])
        )
        d = vec3d_length(seg_pt - box_pt)
        if d < min_dist
            min_dist = d
            best_cap_pt = seg_pt
            best_box_pt = box_pt
        end
    end

    # Refine: project the best box point back onto the segment
    refined_cap_pt, _ = closest_point_on_segment(a1, a2, best_box_pt)
    refined_box_pt = Vec3d(
        clamp(refined_cap_pt[1], center_b[1] - he_b[1], center_b[1] + he_b[1]),
        clamp(refined_cap_pt[2], center_b[2] - he_b[2], center_b[2] + he_b[2]),
        clamp(refined_cap_pt[3], center_b[3] - he_b[3], center_b[3] + he_b[3])
    )

    diff = refined_box_pt - refined_cap_pt
    dist = vec3d_length(diff)

    if dist >= ra
        return nothing
    end

    if dist < COLLISION_EPSILON
        # Capsule segment point is inside AABB
        # Find closest face for normal
        dx_pos = (center_b[1] + he_b[1]) - refined_cap_pt[1]
        dx_neg = refined_cap_pt[1] - (center_b[1] - he_b[1])
        dy_pos = (center_b[2] + he_b[2]) - refined_cap_pt[2]
        dy_neg = refined_cap_pt[2] - (center_b[2] - he_b[2])
        dz_pos = (center_b[3] + he_b[3]) - refined_cap_pt[3]
        dz_neg = refined_cap_pt[3] - (center_b[3] - he_b[3])
        min_d = min(dx_pos, dx_neg, dy_pos, dy_neg, dz_pos, dz_neg)
        if min_d == dx_pos
            normal = Vec3d(1, 0, 0)
        elseif min_d == dx_neg
            normal = Vec3d(-1, 0, 0)
        elseif min_d == dy_pos
            normal = Vec3d(0, 1, 0)
        elseif min_d == dy_neg
            normal = Vec3d(0, -1, 0)
        elseif min_d == dz_pos
            normal = Vec3d(0, 0, 1)
        else
            normal = Vec3d(0, 0, -1)
        end
        penetration = ra + min_d
    else
        normal = diff / dist  # Points from capsule toward AABB
        penetration = ra - dist
    end

    contact_pt = refined_box_pt

    manifold = ContactManifold(eid_a, eid_b, normal)
    push!(manifold.points, ContactPoint(contact_pt, normal, penetration))
    return manifold
end

# AABB vs Capsule (swap and flip)
function _collide_shapes(sa::AABBShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::CapsuleShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    result = _collide_shapes(sb, pos_b, rot_b, scl_b, off_b,
                              sa, pos_a, rot_a, scl_a, off_a,
                              eid_b, eid_a)
    if result !== nothing
        result.entity_a = eid_a
        result.entity_b = eid_b
        result.normal = -result.normal
        for p in result.points
            p.normal = -p.normal
        end
    end
    return result
end

# =============================================================================
# OBB and ConvexHull collision via GJK+EPA
# =============================================================================

# OBB vs any shape (use GJK+EPA)
for ShapeB in (OBBShape, ConvexHullShape, AABBShape, SphereShape, CapsuleShape)
    @eval function _collide_shapes(sa::OBBShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                                    sb::$ShapeB, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                                    eid_a::EntityID, eid_b::EntityID)
        return collide_gjk_epa(sa, pos_a, rot_a, scl_a, off_a,
                                sb, pos_b, rot_b, scl_b, off_b,
                                eid_a, eid_b)
    end
end

# Any shape vs OBB (swap if not already handled)
for ShapeA in (AABBShape, SphereShape, CapsuleShape)
    @eval function _collide_shapes(sa::$ShapeA, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                                    sb::OBBShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                                    eid_a::EntityID, eid_b::EntityID)
        return collide_gjk_epa(sa, pos_a, rot_a, scl_a, off_a,
                                sb, pos_b, rot_b, scl_b, off_b,
                                eid_a, eid_b)
    end
end

# ConvexHull vs any shape (use GJK+EPA)
for ShapeB in (ConvexHullShape, AABBShape, SphereShape, CapsuleShape)
    @eval function _collide_shapes(sa::ConvexHullShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                                    sb::$ShapeB, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                                    eid_a::EntityID, eid_b::EntityID)
        return collide_gjk_epa(sa, pos_a, rot_a, scl_a, off_a,
                                sb, pos_b, rot_b, scl_b, off_b,
                                eid_a, eid_b)
    end
end

# Any shape vs ConvexHull
for ShapeA in (AABBShape, SphereShape, CapsuleShape)
    @eval function _collide_shapes(sa::$ShapeA, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                                    sb::ConvexHullShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                                    eid_a::EntityID, eid_b::EntityID)
        return collide_gjk_epa(sa, pos_a, rot_a, scl_a, off_a,
                                sb, pos_b, rot_b, scl_b, off_b,
                                eid_a, eid_b)
    end
end

# =============================================================================
# CompoundShape collision: test each child separately
# =============================================================================

"""
    _collide_compound(compound_shape, pos, rot, scale, offset, other_shape, other_pos, other_rot, other_scale, other_offset, eid_compound, eid_other, compound_is_a) -> Union{ContactManifold, Nothing}

Test a compound shape against another shape by testing each child.
Returns the deepest penetrating contact manifold.
"""
function _collide_compound(cs::CompoundShape, pos::Vec3d, rot::Quaternion{Float64}, scl::Vec3d, off::Vec3f,
                            other_shape::ColliderShape, other_pos::Vec3d, other_rot::Quaternion{Float64},
                            other_scl::Vec3d, other_off::Vec3f,
                            eid_compound::EntityID, eid_other::EntityID, compound_is_a::Bool)
    off_d = Vec3d(Float64(off[1]), Float64(off[2]), Float64(off[3]))
    center = pos + off_d .* scl
    R_parent = rotation_matrix(rot)

    best_manifold = nothing
    best_penetration = 0.0

    for child in cs.children
        local_pos = child.local_position .* scl
        world_child_pos = center + Vec3d(
            R_parent[1,1]*local_pos[1] + R_parent[1,2]*local_pos[2] + R_parent[1,3]*local_pos[3],
            R_parent[2,1]*local_pos[1] + R_parent[2,2]*local_pos[2] + R_parent[2,3]*local_pos[3],
            R_parent[3,1]*local_pos[1] + R_parent[3,2]*local_pos[2] + R_parent[3,3]*local_pos[3]
        )
        child_rot = rot * child.local_rotation
        zero_off = Vec3f(0, 0, 0)

        manifold = if compound_is_a
            _collide_shapes(child.shape, world_child_pos, child_rot, scl, zero_off,
                           other_shape, other_pos, other_rot, other_scl, other_off,
                           eid_compound, eid_other)
        else
            _collide_shapes(other_shape, other_pos, other_rot, other_scl, other_off,
                           child.shape, world_child_pos, child_rot, scl, zero_off,
                           eid_other, eid_compound)
        end

        if manifold !== nothing
            max_pen = maximum(cp.penetration for cp in manifold.points)
            if max_pen > best_penetration
                best_manifold = manifold
                best_penetration = max_pen
            end
        end
    end

    return best_manifold
end

# CompoundShape vs any shape
function _collide_shapes(sa::CompoundShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::ColliderShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    return _collide_compound(sa, pos_a, rot_a, scl_a, off_a,
                              sb, pos_b, rot_b, scl_b, off_b,
                              eid_a, eid_b, true)
end

# Any shape vs CompoundShape
function _collide_shapes(sa::ColliderShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::CompoundShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    return _collide_compound(sb, pos_b, rot_b, scl_b, off_b,
                              sa, pos_a, rot_a, scl_a, off_a,
                              eid_b, eid_a, false)
end

# CompoundShape vs CompoundShape
function _collide_shapes(sa::CompoundShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::CompoundShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    # Test each child of A against the full compound B
    return _collide_compound(sa, pos_a, rot_a, scl_a, off_a,
                              sb, pos_b, rot_b, scl_b, off_b,
                              eid_a, eid_b, true)
end

# Fallback for unknown shape pairs
function _collide_shapes(sa::ColliderShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          sb::ColliderShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    return nothing
end
