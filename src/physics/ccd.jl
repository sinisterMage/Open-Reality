# Continuous Collision Detection (CCD)
# Prevents fast-moving objects from tunneling through thin walls

const CCD_MAX_TOI_ITERATIONS = 20
const CCD_VELOCITY_THRESHOLD = 2.0  # Only enable CCD above this speed

"""
    sweep_test(entity_id::EntityID, velocity::Vec3d, dt::Float64) -> Union{Tuple{Float64, RaycastHit}, Nothing}

Perform a swept collision test for a moving entity.
Returns (time_of_impact, hit) or nothing if no collision would occur.
Time of impact is in [0, dt].
"""
function sweep_test(entity_id::EntityID, velocity::Vec3d, dt::Float64)
    speed = vec3d_length(velocity)
    if speed < CCD_VELOCITY_THRESHOLD
        return nothing
    end

    collider = get_component(entity_id, ColliderComponent)
    tc = get_component(entity_id, TransformComponent)
    (collider === nothing || tc === nothing) && return nothing

    position = tc.position[]
    direction = velocity / speed
    travel_distance = speed * dt

    # For spheres: cast a ray from the center along the velocity
    if collider.shape isa SphereShape
        r = Float64(collider.shape.radius) * max(tc.scale[]...)
        # Offset the ray start back by radius along the direction
        ray_origin = position + Vec3d(Float64(collider.offset[1]), Float64(collider.offset[2]), Float64(collider.offset[3]))

        hit = _sweep_sphere(ray_origin, direction, r, travel_distance, entity_id)
        if hit !== nothing
            toi = hit.distance / speed
            return (toi, hit)
        end
    elseif collider.shape isa CapsuleShape
        # For capsules: sweep the capsule along the velocity
        a, b = get_capsule_segment(collider.shape, position, tc.rotation[], tc.scale[], collider.offset)
        r = get_capsule_world_radius(collider.shape, tc.scale[])

        hit = _sweep_capsule(a, b, r, direction, travel_distance, entity_id)
        if hit !== nothing
            toi = hit.distance / speed
            return (toi, hit)
        end
    else
        # For other shapes: use conservative advancement via AABB sweep
        hit = _sweep_aabb(position, collider, tc, velocity, dt, entity_id)
        if hit !== nothing
            return hit
        end
    end

    return nothing
end

"""
    _sweep_sphere(center, direction, radius, max_distance, exclude_entity) -> Union{RaycastHit, Nothing}

Sweep a sphere along a direction and find the first collision.
"""
function _sweep_sphere(center::Vec3d, direction::Vec3d, radius::Float64,
                        max_distance::Float64, exclude_entity::EntityID)
    # Cast a fat ray (sphere cast = ray + radius expansion)
    best_hit = nothing
    best_dist = max_distance

    iterate_components(ColliderComponent) do eid, collider
        eid == exclude_entity && return
        collider.is_trigger && return
        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        # Expand the target shape by the sweep radius and do a ray test
        if collider.shape isa SphereShape
            # Sphere-sphere sweep = ray vs expanded sphere
            off = Vec3d(Float64(collider.offset[1]), Float64(collider.offset[2]), Float64(collider.offset[3]))
            target_center = tc.position[] + off .* tc.scale[]
            target_r = Float64(collider.shape.radius) * max(tc.scale[]...) + radius

            oc = center - target_center
            a = vec3d_dot(direction, direction)
            b = 2.0 * vec3d_dot(oc, direction)
            c = vec3d_dot(oc, oc) - target_r * target_r
            disc = b * b - 4 * a * c

            if disc >= 0
                t = (-b - sqrt(disc)) / (2 * a)
                if t >= 0 && t < best_dist
                    hit_pt = center + direction * t
                    normal = vec3d_normalize(hit_pt - target_center)
                    best_hit = RaycastHit(eid, hit_pt, normal, t)
                    best_dist = t
                end
            end
        elseif collider.shape isa AABBShape
            # Expand AABB by radius and ray test
            off = Vec3d(Float64(collider.offset[1]), Float64(collider.offset[2]), Float64(collider.offset[3]))
            box_center = tc.position[] + off .* tc.scale[]
            he = Vec3d(
                Float64(collider.shape.half_extents[1]) * tc.scale[][1] + radius,
                Float64(collider.shape.half_extents[2]) * tc.scale[][2] + radius,
                Float64(collider.shape.half_extents[3]) * tc.scale[][3] + radius
            )
            hit = _ray_aabb_slab(center, direction, best_dist, box_center - he, box_center + he, eid)
            if hit !== nothing && hit.distance < best_dist
                best_hit = hit
                best_dist = hit.distance
            end
        end
    end

    return best_hit
end

"""
    _sweep_capsule(a, b, radius, direction, max_distance, exclude_entity) -> Union{RaycastHit, Nothing}

Sweep a capsule along a direction.
Uses sphere sweeps from each endpoint as approximation.
"""
function _sweep_capsule(a::Vec3d, b::Vec3d, radius::Float64, direction::Vec3d,
                         max_distance::Float64, exclude_entity::EntityID)
    # Sweep both endpoints and take the earliest hit
    hit_a = _sweep_sphere(a, direction, radius, max_distance, exclude_entity)
    hit_b = _sweep_sphere(b, direction, radius, max_distance, exclude_entity)

    if hit_a === nothing
        return hit_b
    elseif hit_b === nothing
        return hit_a
    else
        return hit_a.distance <= hit_b.distance ? hit_a : hit_b
    end
end

"""
    _sweep_aabb(position, collider, tc, velocity, dt, exclude_entity) -> Union{Tuple{Float64, RaycastHit}, Nothing}

Conservative AABB sweep for non-sphere/capsule shapes.
"""
function _sweep_aabb(position::Vec3d, collider::ColliderComponent, tc::TransformComponent,
                      velocity::Vec3d, dt::Float64, exclude_entity::EntityID)
    # Binary search for time of impact
    t_min = 0.0
    t_max = dt

    for _ in 1:CCD_MAX_TOI_ITERATIONS
        t_mid = (t_min + t_max) * 0.5
        test_pos = position + velocity * t_mid

        # Check if AABB at test_pos overlaps anything
        aabb = compute_world_aabb(collider.shape, test_pos, tc.rotation[], tc.scale[], collider.offset)

        has_overlap = false
        iterate_components(ColliderComponent) do eid, other_collider
            has_overlap && return
            eid == exclude_entity && return
            other_collider.is_trigger && return
            other_aabb = get_entity_physics_aabb(eid)
            other_aabb === nothing && return
            if aabb_overlap(aabb, other_aabb)
                has_overlap = true
            end
        end

        if has_overlap
            t_max = t_mid
        else
            t_min = t_mid
        end

        if (t_max - t_min) < dt * 0.01
            break
        end
    end

    if t_max < dt * 0.99
        toi = t_min
        hit_pos = position + velocity * toi
        return (toi, RaycastHit(exclude_entity, hit_pos, Vec3d(0, 1, 0), vec3d_length(velocity) * toi))
    end

    return nothing
end

"""
    apply_ccd!(world::PhysicsWorld, dt::Float64)

Apply CCD to entities with ccd_mode=CCD_SWEPT.
Must be called before position integration.
"""
function apply_ccd!(world, dt::Float64)
    iterate_components(RigidBodyComponent) do eid, rb
        rb.body_type == BODY_DYNAMIC || return
        rb.ccd_mode == CCD_SWEPT || return
        rb.sleeping && return

        result = sweep_test(eid, rb.velocity, dt)
        if result !== nothing
            toi, hit = result
            # Clamp the velocity to stop just before the collision
            if toi > 0
                tc = get_component(eid, TransformComponent)
                if tc !== nothing
                    # Move to just before the collision point
                    safe_toi = max(toi - 0.001, 0.0)
                    tc.position[] = tc.position[] + rb.velocity * safe_toi

                    # Remove velocity component along collision normal
                    normal_vel = vec3d_dot(rb.velocity, hit.normal)
                    if normal_vel < 0
                        rb.velocity = rb.velocity - hit.normal * normal_vel
                    end
                end
            end
        end
    end
end
