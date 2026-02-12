# Raycasting: ray-shape intersection tests and world query

"""
    raycast(origin::Vec3d, direction::Vec3d; max_distance::Float64=Inf) -> Union{RaycastHit, Nothing}

Cast a ray into the world and return the closest hit.
Direction does not need to be normalized (will be normalized internally).
"""
function raycast(origin::Vec3d, direction::Vec3d; max_distance::Float64=Inf)
    d_len = vec3d_length(direction)
    if d_len < COLLISION_EPSILON
        return nothing
    end
    dir_norm = direction / d_len

    closest_hit = nothing
    closest_dist = max_distance

    iterate_components(ColliderComponent) do eid, collider
        collider.is_trigger && return  # Skip triggers
        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        hit = _ray_shape(origin, dir_norm, closest_dist, collider.shape,
                         tc.position[], tc.rotation[], tc.scale[], collider.offset, eid)
        if hit !== nothing && hit.distance < closest_dist
            closest_dist = hit.distance
            closest_hit = hit
        end
    end

    return closest_hit
end

"""
    raycast_all(origin::Vec3d, direction::Vec3d; max_distance::Float64=Inf) -> Vector{RaycastHit}

Cast a ray and return all hits sorted by distance.
"""
function raycast_all(origin::Vec3d, direction::Vec3d; max_distance::Float64=Inf)
    d_len = vec3d_length(direction)
    if d_len < COLLISION_EPSILON
        return RaycastHit[]
    end
    dir_norm = direction / d_len

    hits = RaycastHit[]

    iterate_components(ColliderComponent) do eid, collider
        collider.is_trigger && return
        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        hit = _ray_shape(origin, dir_norm, max_distance, collider.shape,
                         tc.position[], tc.rotation[], tc.scale[], collider.offset, eid)
        if hit !== nothing
            push!(hits, hit)
        end
    end

    sort!(hits, by=h -> h.distance)
    return hits
end

# =============================================================================
# Ray-Shape intersection tests
# =============================================================================

"""
    _ray_shape(origin, direction, max_dist, shape, ...) -> Union{RaycastHit, Nothing}
"""
function _ray_shape(origin::Vec3d, direction::Vec3d, max_dist::Float64,
                    shape::SphereShape, position::Vec3d, rotation::Quaternion{Float64},
                    scale::Vec3d, offset::Vec3f, eid::EntityID)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    r = Float64(shape.radius) * max(scale[1], scale[2], scale[3])

    oc = origin - center
    a = vec3d_dot(direction, direction)
    b = 2.0 * vec3d_dot(oc, direction)
    c = vec3d_dot(oc, oc) - r * r
    discriminant = b * b - 4 * a * c

    if discriminant < 0
        return nothing
    end

    sqrt_disc = sqrt(discriminant)
    t1 = (-b - sqrt_disc) / (2 * a)
    t2 = (-b + sqrt_disc) / (2 * a)

    t = t1 >= 0 ? t1 : t2
    if t < 0 || t > max_dist
        return nothing
    end

    hit_point = origin + direction * t
    normal = vec3d_normalize(hit_point - center)
    return RaycastHit(eid, hit_point, normal, t)
end

function _ray_shape(origin::Vec3d, direction::Vec3d, max_dist::Float64,
                    shape::AABBShape, position::Vec3d, rotation::Quaternion{Float64},
                    scale::Vec3d, offset::Vec3f, eid::EntityID)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    he = Vec3d(Float64(shape.half_extents[1]) * scale[1],
               Float64(shape.half_extents[2]) * scale[2],
               Float64(shape.half_extents[3]) * scale[3])

    # Slab method
    box_min = center - he
    box_max = center + he
    return _ray_aabb_slab(origin, direction, max_dist, box_min, box_max, eid)
end

function _ray_shape(origin::Vec3d, direction::Vec3d, max_dist::Float64,
                    shape::OBBShape, position::Vec3d, rotation::Quaternion{Float64},
                    scale::Vec3d, offset::Vec3f, eid::EntityID)
    off = Vec3d(Float64(offset[1]), Float64(offset[2]), Float64(offset[3]))
    center = position + off .* scale
    he = Vec3d(Float64(shape.half_extents[1]) * scale[1],
               Float64(shape.half_extents[2]) * scale[2],
               Float64(shape.half_extents[3]) * scale[3])

    # Transform ray to OBB local space
    R = rotation_matrix(rotation)
    local_origin = Vec3d(
        R[1,1]*(origin[1]-center[1]) + R[2,1]*(origin[2]-center[2]) + R[3,1]*(origin[3]-center[3]),
        R[1,2]*(origin[1]-center[1]) + R[2,2]*(origin[2]-center[2]) + R[3,2]*(origin[3]-center[3]),
        R[1,3]*(origin[1]-center[1]) + R[2,3]*(origin[2]-center[2]) + R[3,3]*(origin[3]-center[3])
    )
    local_dir = Vec3d(
        R[1,1]*direction[1] + R[2,1]*direction[2] + R[3,1]*direction[3],
        R[1,2]*direction[1] + R[2,2]*direction[2] + R[3,2]*direction[3],
        R[1,3]*direction[1] + R[2,3]*direction[2] + R[3,3]*direction[3]
    )

    # Slab method in local space
    hit = _ray_aabb_slab(local_origin, local_dir, max_dist, -he, he, eid)
    if hit === nothing
        return nothing
    end

    # Transform hit back to world space
    world_point = origin + direction * hit.distance
    world_normal = Vec3d(
        R[1,1]*hit.normal[1] + R[1,2]*hit.normal[2] + R[1,3]*hit.normal[3],
        R[2,1]*hit.normal[1] + R[2,2]*hit.normal[2] + R[2,3]*hit.normal[3],
        R[3,1]*hit.normal[1] + R[3,2]*hit.normal[2] + R[3,3]*hit.normal[3]
    )
    return RaycastHit(eid, world_point, world_normal, hit.distance)
end

function _ray_shape(origin::Vec3d, direction::Vec3d, max_dist::Float64,
                    shape::CapsuleShape, position::Vec3d, rotation::Quaternion{Float64},
                    scale::Vec3d, offset::Vec3f, eid::EntityID)
    a_pt, b_pt = get_capsule_segment(shape, position, rotation, scale, offset)
    r = get_capsule_world_radius(shape, scale)

    # Ray-capsule = closest approach of ray to segment, then sphere test
    seg_dir = b_pt - a_pt
    seg_len_sq = vec3d_dot(seg_dir, seg_dir)

    # Test ray against infinite cylinder, then clamp
    oa = origin - a_pt
    d_cross_seg = vec3d_cross(direction, seg_dir)
    oa_cross_seg = vec3d_cross(oa, seg_dir)

    a_coeff = vec3d_dot(d_cross_seg, d_cross_seg)
    b_coeff = 2.0 * vec3d_dot(d_cross_seg, oa_cross_seg)
    c_coeff = vec3d_dot(oa_cross_seg, oa_cross_seg) - r * r * seg_len_sq

    best_t = Inf
    best_normal = Vec3d(0, 1, 0)

    # Check cylinder body
    disc = b_coeff * b_coeff - 4 * a_coeff * c_coeff
    if disc >= 0 && a_coeff > COLLISION_EPSILON
        sqrt_disc = sqrt(disc)
        for t_sign in (-1, 1)
            t = (-b_coeff + t_sign * sqrt_disc) / (2 * a_coeff)
            if t >= 0 && t < best_t && t <= max_dist
                hit_pt = origin + direction * t
                # Project onto segment to check if within caps
                proj = vec3d_dot(hit_pt - a_pt, seg_dir) / seg_len_sq
                if proj >= 0 && proj <= 1
                    closest_on_seg = a_pt + seg_dir * proj
                    n = vec3d_normalize(hit_pt - closest_on_seg)
                    best_t = t
                    best_normal = n
                end
            end
        end
    end

    # Check sphere caps
    for cap_center in (a_pt, b_pt)
        oc = origin - cap_center
        a_s = vec3d_dot(direction, direction)
        b_s = 2.0 * vec3d_dot(oc, direction)
        c_s = vec3d_dot(oc, oc) - r * r
        disc_s = b_s * b_s - 4 * a_s * c_s
        if disc_s >= 0
            sqrt_disc_s = sqrt(disc_s)
            t = (-b_s - sqrt_disc_s) / (2 * a_s)
            if t < 0
                t = (-b_s + sqrt_disc_s) / (2 * a_s)
            end
            if t >= 0 && t < best_t && t <= max_dist
                hit_pt = origin + direction * t
                n = vec3d_normalize(hit_pt - cap_center)
                best_t = t
                best_normal = n
            end
        end
    end

    if best_t < Inf
        return RaycastHit(eid, origin + direction * best_t, best_normal, best_t)
    end
    return nothing
end

function _ray_shape(origin::Vec3d, direction::Vec3d, max_dist::Float64,
                    shape::ConvexHullShape, position::Vec3d, rotation::Quaternion{Float64},
                    scale::Vec3d, offset::Vec3f, eid::EntityID)
    # Use GJK-raycast: treat ray as a thin capsule
    # Simplified: test against AABB first, then brute-force face tests
    aabb = compute_world_aabb(shape, position, rotation, scale, offset)
    aabb_hit = _ray_aabb_slab(origin, direction, max_dist, aabb.min_pt, aabb.max_pt, eid)
    if aabb_hit === nothing
        return nothing
    end

    # For convex hulls, use the AABB hit as approximation
    # (Full face-based raycast requires convex hull face data)
    return aabb_hit
end

# Fallback
function _ray_shape(origin::Vec3d, direction::Vec3d, max_dist::Float64,
                    shape::ColliderShape, position::Vec3d, rotation::Quaternion{Float64},
                    scale::Vec3d, offset::Vec3f, eid::EntityID)
    return nothing
end

# =============================================================================
# Helper: Ray-AABB slab method
# =============================================================================

function _ray_aabb_slab(origin::Vec3d, direction::Vec3d, max_dist::Float64,
                        box_min::Vec3d, box_max::Vec3d, eid::EntityID)
    t_min = 0.0
    t_max = max_dist
    normal = Vec3d(0, 0, 0)

    for i in 1:3
        if abs(direction[i]) < COLLISION_EPSILON
            if origin[i] < box_min[i] || origin[i] > box_max[i]
                return nothing
            end
        else
            inv_d = 1.0 / direction[i]
            t1 = (box_min[i] - origin[i]) * inv_d
            t2 = (box_max[i] - origin[i]) * inv_d
            n = Vec3d(0, 0, 0)

            if t1 > t2
                t1, t2 = t2, t1
                n = setindex(n, 1.0, i)
            else
                n = setindex(n, -1.0, i)
            end

            if t1 > t_min
                t_min = t1
                normal = n
            end
            t_max = min(t_max, t2)

            if t_min > t_max
                return nothing
            end
        end
    end

    if t_min < 0
        return nothing
    end

    hit_point = origin + direction * t_min
    return RaycastHit(eid, hit_point, normal, t_min)
end
