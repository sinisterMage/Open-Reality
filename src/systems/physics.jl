# Physics system: gravity, collision detection, collision response

"""
    PhysicsConfig

Global physics settings.
"""
struct PhysicsConfig
    gravity::Vec3d

    PhysicsConfig(;
        gravity::Vec3d = Vec3d(0, -9.81, 0)
    ) = new(gravity)
end

const DEFAULT_PHYSICS_CONFIG = PhysicsConfig()

"""
    WorldAABB

Axis-aligned bounding box in world space.
"""
struct WorldAABB
    min_pt::Vec3d
    max_pt::Vec3d
end

"""
    CollisionResult

Result of a narrowphase collision test.
"""
struct CollisionResult
    entity_a::EntityID
    entity_b::EntityID
    normal::Vec3d
    penetration::Float64
end

# ---- World-space AABB computation ----

"""
    get_world_aabb(entity_id::EntityID) -> Union{WorldAABB, Nothing}

Compute the world-space AABB for an entity's collider, accounting for
position and scale (rotation is ignored for AABBs).
"""
function get_world_aabb(entity_id::EntityID)
    collider = get_component(entity_id, ColliderComponent)
    collider === nothing && return nothing

    tc = get_component(entity_id, TransformComponent)
    tc === nothing && return nothing

    pos = tc.position[]
    scl = tc.scale[]
    offset = Vec3d(Float64(collider.offset[1]),
                   Float64(collider.offset[2]),
                   Float64(collider.offset[3]))

    center = pos + offset .* scl

    if collider.shape isa AABBShape
        he = Vec3d(Float64(collider.shape.half_extents[1]),
                   Float64(collider.shape.half_extents[2]),
                   Float64(collider.shape.half_extents[3]))
        scaled_he = he .* scl
        return WorldAABB(center - scaled_he, center + scaled_he)
    elseif collider.shape isa SphereShape
        r = Float64(collider.shape.radius) * max(scl[1], scl[2], scl[3])
        rv = Vec3d(r, r, r)
        return WorldAABB(center - rv, center + rv)
    end

    return nothing
end

# ---- Broadphase ----

"""
    aabb_overlap(a::WorldAABB, b::WorldAABB) -> Bool

Test if two world-space AABBs overlap.
"""
function aabb_overlap(a::WorldAABB, b::WorldAABB)::Bool
    return a.min_pt[1] <= b.max_pt[1] && a.max_pt[1] >= b.min_pt[1] &&
           a.min_pt[2] <= b.max_pt[2] && a.max_pt[2] >= b.min_pt[2] &&
           a.min_pt[3] <= b.max_pt[3] && a.max_pt[3] >= b.min_pt[3]
end

# ---- Narrowphase ----

"""
    narrowphase_aabb_aabb(a, b, eid_a, eid_b) -> Union{CollisionResult, Nothing}

AABB vs AABB: compute penetration depth and collision normal (minimum overlap axis).
"""
function narrowphase_aabb_aabb(a::WorldAABB, b::WorldAABB,
                               eid_a::EntityID, eid_b::EntityID)
    overlap_x = min(a.max_pt[1], b.max_pt[1]) - max(a.min_pt[1], b.min_pt[1])
    overlap_y = min(a.max_pt[2], b.max_pt[2]) - max(a.min_pt[2], b.min_pt[2])
    overlap_z = min(a.max_pt[3], b.max_pt[3]) - max(a.min_pt[3], b.min_pt[3])

    if overlap_x <= 0 || overlap_y <= 0 || overlap_z <= 0
        return nothing
    end

    center_a = (a.min_pt + a.max_pt) * 0.5
    center_b = (b.min_pt + b.max_pt) * 0.5
    diff = center_b - center_a

    if overlap_x <= overlap_y && overlap_x <= overlap_z
        normal = Vec3d(diff[1] >= 0 ? 1.0 : -1.0, 0, 0)
        return CollisionResult(eid_a, eid_b, normal, overlap_x)
    elseif overlap_y <= overlap_z
        normal = Vec3d(0, diff[2] >= 0 ? 1.0 : -1.0, 0)
        return CollisionResult(eid_a, eid_b, normal, overlap_y)
    else
        normal = Vec3d(0, 0, diff[3] >= 0 ? 1.0 : -1.0)
        return CollisionResult(eid_a, eid_b, normal, overlap_z)
    end
end

"""
    narrowphase_sphere_sphere(eid_a, eid_b) -> Union{CollisionResult, Nothing}

Sphere vs sphere collision test.
"""
function narrowphase_sphere_sphere(eid_a::EntityID, eid_b::EntityID)
    ca = get_component(eid_a, ColliderComponent)
    cb = get_component(eid_b, ColliderComponent)
    ta = get_component(eid_a, TransformComponent)
    tb = get_component(eid_b, TransformComponent)

    pos_a = ta.position[] + Vec3d(Float64(ca.offset[1]), Float64(ca.offset[2]), Float64(ca.offset[3]))
    pos_b = tb.position[] + Vec3d(Float64(cb.offset[1]), Float64(cb.offset[2]), Float64(cb.offset[3]))

    ra = Float64(ca.shape.radius) * max(ta.scale[]...)
    rb = Float64(cb.shape.radius) * max(tb.scale[]...)

    diff = pos_b - pos_a
    dist = sqrt(diff[1]^2 + diff[2]^2 + diff[3]^2)
    sum_r = ra + rb

    if dist >= sum_r || dist < 1e-10
        return nothing
    end

    normal = diff / dist
    penetration = sum_r - dist
    return CollisionResult(eid_a, eid_b, normal, penetration)
end

# ---- Collision response ----

"""
    resolve_collision!(result::CollisionResult)

Push entities apart based on their body types.
"""
function resolve_collision!(result::CollisionResult)
    rb_a = get_component(result.entity_a, RigidBodyComponent)
    rb_b = get_component(result.entity_b, RigidBodyComponent)
    tc_a = get_component(result.entity_a, TransformComponent)
    tc_b = get_component(result.entity_b, TransformComponent)

    type_a = rb_a !== nothing ? rb_a.body_type : BODY_STATIC
    type_b = rb_b !== nothing ? rb_b.body_type : BODY_STATIC

    # Skip if both are static/kinematic (no resolution needed between immovable objects)
    a_movable = type_a == BODY_DYNAMIC || type_a == BODY_KINEMATIC
    b_movable = type_b == BODY_DYNAMIC || type_b == BODY_KINEMATIC
    if !a_movable && !b_movable
        return
    end

    push_vec = result.normal * result.penetration

    if type_a == BODY_STATIC
        # Only B moves
        if tc_b !== nothing
            tc_b.position[] = tc_b.position[] + push_vec
            if rb_b !== nothing
                vel = rb_b.velocity
                normal_vel = vel[1]*result.normal[1] + vel[2]*result.normal[2] + vel[3]*result.normal[3]
                if normal_vel < 0
                    rb_b.velocity = vel - result.normal * normal_vel
                end
                if result.normal[2] > 0.7
                    rb_b.grounded = true
                end
            end
        end
    elseif type_b == BODY_STATIC
        # Only A moves
        if tc_a !== nothing
            tc_a.position[] = tc_a.position[] - push_vec
            if rb_a !== nothing
                vel = rb_a.velocity
                normal_vel = vel[1]*result.normal[1] + vel[2]*result.normal[2] + vel[3]*result.normal[3]
                if normal_vel > 0
                    rb_a.velocity = vel - result.normal * normal_vel
                end
                if result.normal[2] < -0.7
                    rb_a.grounded = true
                end
            end
        end
    elseif type_a == BODY_KINEMATIC && type_b != BODY_STATIC
        # Kinematic acts like static for push-out: only B moves
        if tc_b !== nothing
            tc_b.position[] = tc_b.position[] + push_vec
            if rb_b !== nothing
                vel = rb_b.velocity
                normal_vel = vel[1]*result.normal[1] + vel[2]*result.normal[2] + vel[3]*result.normal[3]
                if normal_vel < 0
                    rb_b.velocity = vel - result.normal * normal_vel
                end
                if result.normal[2] > 0.7
                    rb_b.grounded = true
                end
            end
        end
    elseif type_b == BODY_KINEMATIC && type_a != BODY_STATIC
        # Only A moves
        if tc_a !== nothing
            tc_a.position[] = tc_a.position[] - push_vec
            if rb_a !== nothing
                vel = rb_a.velocity
                normal_vel = vel[1]*result.normal[1] + vel[2]*result.normal[2] + vel[3]*result.normal[3]
                if normal_vel > 0
                    rb_a.velocity = vel - result.normal * normal_vel
                end
                if result.normal[2] < -0.7
                    rb_a.grounded = true
                end
            end
        end
    else
        # Both dynamic: split by inverse mass
        mass_a = rb_a !== nothing ? rb_a.mass : 1.0
        mass_b = rb_b !== nothing ? rb_b.mass : 1.0
        total_mass = mass_a + mass_b
        ratio_a = mass_b / total_mass
        ratio_b = mass_a / total_mass
        if tc_a !== nothing
            tc_a.position[] = tc_a.position[] - push_vec * ratio_a
        end
        if tc_b !== nothing
            tc_b.position[] = tc_b.position[] + push_vec * ratio_b
        end
    end
end

# ---- Main physics update ----

"""
    update_physics!(dt::Float64; config::PhysicsConfig = DEFAULT_PHYSICS_CONFIG)

Run one physics frame:
1. Apply gravity and integrate velocity for BODY_DYNAMIC entities.
2. Broadphase + narrowphase collision detection.
3. Resolve collisions.
"""
function update_physics!(dt::Float64; config::PhysicsConfig = DEFAULT_PHYSICS_CONFIG)
    # Reset grounded flags
    iterate_components(RigidBodyComponent) do eid, rb
        if rb.body_type == BODY_DYNAMIC
            rb.grounded = false
        end
    end

    # Gravity + velocity integration for dynamic bodies
    iterate_components(RigidBodyComponent) do eid, rb
        if rb.body_type == BODY_DYNAMIC
            tc = get_component(eid, TransformComponent)
            if tc !== nothing
                rb.velocity = rb.velocity + config.gravity * dt
                tc.position[] = tc.position[] + rb.velocity * dt
            end
        end
    end

    # Gather collidable entities
    collider_entities = entities_with_component(ColliderComponent)
    n = length(collider_entities)
    world_aabbs = Vector{Union{WorldAABB, Nothing}}(undef, n)
    for i in 1:n
        world_aabbs[i] = get_world_aabb(collider_entities[i])
    end

    # O(n^2) broadphase + narrowphase + resolve
    for i in 1:n
        a_aabb = world_aabbs[i]
        a_aabb === nothing && continue

        for j in (i+1):n
            b_aabb = world_aabbs[j]
            b_aabb === nothing && continue

            # Broadphase
            aabb_overlap(a_aabb, b_aabb) || continue

            # Narrowphase
            eid_a = collider_entities[i]
            eid_b = collider_entities[j]
            ca = get_component(eid_a, ColliderComponent)
            cb = get_component(eid_b, ColliderComponent)

            collision = nothing
            if ca.shape isa AABBShape && cb.shape isa AABBShape
                collision = narrowphase_aabb_aabb(a_aabb, b_aabb, eid_a, eid_b)
            elseif ca.shape isa SphereShape && cb.shape isa SphereShape
                collision = narrowphase_sphere_sphere(eid_a, eid_b)
            else
                # AABB vs Sphere: use AABB overlap as approximation
                collision = narrowphase_aabb_aabb(a_aabb, b_aabb, eid_a, eid_b)
            end

            if collision !== nothing
                resolve_collision!(collision)
            end
        end
    end
end
