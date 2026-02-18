# PhysicsWorld: orchestrates the full physics pipeline per frame

"""
    PhysicsWorld

The central physics simulation state. Owns the broadphase, contact cache,
and solver bodies. Created once and reused across frames.
"""
mutable struct PhysicsWorld
    config::PhysicsWorldConfig
    broadphase::SpatialHashGrid
    contact_cache::ContactCache
    solver_bodies::Dict{EntityID, SolverBody}
    constraints::Vector{JointConstraint}
    accumulator::Float64
    collision_cache::CollisionEventCache
end

function PhysicsWorld(; config::PhysicsWorldConfig = PhysicsWorldConfig())
    PhysicsWorld(config,
                 SpatialHashGrid(cell_size=config.fixed_dt > 0 ? 2.0 : 2.0),
                 ContactCache(),
                 Dict{EntityID, SolverBody}(),
                 JointConstraint[],
                 0.0,
                 CollisionEventCache())
end

# Global singleton (lazily initialized)
const _PHYSICS_WORLD = Ref{Union{PhysicsWorld, Nothing}}(nothing)

"""
    get_physics_world(; config=PhysicsWorldConfig()) -> PhysicsWorld

Get or create the global PhysicsWorld singleton.
"""
function get_physics_world(; config::PhysicsWorldConfig = PhysicsWorldConfig())
    if _PHYSICS_WORLD[] === nothing
        _PHYSICS_WORLD[] = PhysicsWorld(config=config)
    end
    return _PHYSICS_WORLD[]
end

"""
    reset_physics_world!()

Reset the physics world (useful when resetting the scene).
"""
function reset_physics_world!()
    _PHYSICS_WORLD[] = nothing
end

"""
    _narrowphase_parallel(candidate_pairs, transform_snap, collider_snap) -> Vector{ContactManifold}

Parallel narrowphase: each collision pair is tested independently using
snapshot data. Results are written to per-index slots (no contention).
"""
function _narrowphase_parallel(candidate_pairs::Vector{CollisionPair},
                                transform_snap::Dict{EntityID, TransformSnapshot},
                                collider_snap::Dict{EntityID, ColliderComponent})
    n = length(candidate_pairs)
    results = Vector{Union{ContactManifold, Nothing}}(nothing, n)
    Threads.@threads for i in 1:n
        pair = candidate_pairs[i]
        ta = get(transform_snap, pair.entity_a, nothing)
        tb = get(transform_snap, pair.entity_b, nothing)
        ca = get(collider_snap, pair.entity_a, nothing)
        cb = get(collider_snap, pair.entity_b, nothing)
        (ta === nothing || tb === nothing || ca === nothing || cb === nothing) && continue
        results[i] = _collide_shapes(
            ca.shape, ta.position, ta.rotation, ta.scale, ca.offset,
            cb.shape, tb.position, tb.rotation, tb.scale, cb.offset,
            pair.entity_a, pair.entity_b)
    end
    return ContactManifold[r for r in results if r !== nothing]
end

"""
    update_collision_callbacks!(world::PhysicsWorld)

Detect collision enter/stay/exit events and fire registered callbacks.
Called each physics step after triggers.
"""
function update_collision_callbacks!(world::PhysicsWorld)
    cache = world.collision_cache

    enter_pairs = setdiff(cache.current_pairs, cache.prev_pairs)
    stay_pairs  = intersect(cache.current_pairs, cache.prev_pairs)
    exit_pairs  = setdiff(cache.prev_pairs, cache.current_pairs)

    # --- Enter events ---
    for key in enter_pairs
        entity_a, entity_b = key
        manifold = get(cache.current_manifolds, key, nothing)

        cb_a = get_component(entity_a, CollisionCallbackComponent)
        if cb_a !== nothing && cb_a.on_collision_enter !== nothing
            try
                cb_a.on_collision_enter(entity_a, entity_b, manifold)
            catch e
                @warn "CollisionCallbackComponent error" exception=e
            end
        end

        cb_b = get_component(entity_b, CollisionCallbackComponent)
        if cb_b !== nothing && cb_b.on_collision_enter !== nothing
            try
                cb_b.on_collision_enter(entity_b, entity_a, manifold)
            catch e
                @warn "CollisionCallbackComponent error" exception=e
            end
        end
    end

    # --- Stay events ---
    for key in stay_pairs
        entity_a, entity_b = key
        manifold = get(cache.current_manifolds, key, nothing)

        cb_a = get_component(entity_a, CollisionCallbackComponent)
        if cb_a !== nothing && cb_a.on_collision_stay !== nothing
            try
                cb_a.on_collision_stay(entity_a, entity_b, manifold)
            catch e
                @warn "CollisionCallbackComponent error" exception=e
            end
        end

        cb_b = get_component(entity_b, CollisionCallbackComponent)
        if cb_b !== nothing && cb_b.on_collision_stay !== nothing
            try
                cb_b.on_collision_stay(entity_b, entity_a, manifold)
            catch e
                @warn "CollisionCallbackComponent error" exception=e
            end
        end
    end

    # --- Exit events (skip if both bodies are sleeping) ---
    for key in exit_pairs
        entity_a, entity_b = key

        rb_a = get_component(entity_a, RigidBodyComponent)
        rb_b = get_component(entity_b, RigidBodyComponent)
        if rb_a !== nothing && rb_b !== nothing && rb_a.sleeping && rb_b.sleeping
            continue
        end

        manifold = get(cache.current_manifolds, key, nothing)

        cb_a = get_component(entity_a, CollisionCallbackComponent)
        if cb_a !== nothing && cb_a.on_collision_exit !== nothing
            try
                cb_a.on_collision_exit(entity_a, entity_b, manifold)
            catch e
                @warn "CollisionCallbackComponent error" exception=e
            end
        end

        cb_b = get_component(entity_b, CollisionCallbackComponent)
        if cb_b !== nothing && cb_b.on_collision_exit !== nothing
            try
                cb_b.on_collision_exit(entity_b, entity_a, manifold)
            catch e
                @warn "CollisionCallbackComponent error" exception=e
            end
        end
    end

    # Cycle the cache
    cache.prev_pairs = copy(cache.current_pairs)
    empty!(cache.current_pairs)
    empty!(cache.current_manifolds)
end

"""
    step!(world::PhysicsWorld, dt::Float64)

Advance the physics simulation by dt seconds using fixed timestep sub-stepping.
"""
function step!(world::PhysicsWorld, dt::Float64)
    world.accumulator += dt
    substeps = 0

    while world.accumulator >= world.config.fixed_dt && substeps < world.config.max_substeps
        fixed_step!(world, world.config.fixed_dt)
        world.accumulator -= world.config.fixed_dt
        substeps += 1
    end

    # Prevent spiral of death: clamp accumulator
    if world.accumulator > world.config.fixed_dt * world.config.max_substeps
        world.accumulator = 0.0
    end
end

"""
    fixed_step!(world::PhysicsWorld, dt::Float64)

One fixed-timestep physics step:
1. Update inertia tensors (world-space)
2. Apply gravity and integrate velocities
3. Broadphase collision detection
4. Narrowphase collision detection
5. Solve velocity constraints
6. Integrate positions
7. Update grounded flags
"""
function fixed_step!(world::PhysicsWorld, dt::Float64)
    # --- Phase 1: Update inertia tensors ---
    iterate_components(RigidBodyComponent) do eid, rb
        if rb.body_type == BODY_DYNAMIC
            tc = get_component(eid, TransformComponent)
            collider = get_component(eid, ColliderComponent)
            if tc !== nothing && collider !== nothing
                rb.inv_inertia_world = rotate_inverse_inertia(rb.inv_inertia_local, tc.rotation[])
            end
        end
    end

    # --- Phase 2: Apply gravity and external forces, reset grounded ---
    iterate_components(RigidBodyComponent) do eid, rb
        if rb.body_type == BODY_DYNAMIC && !rb.sleeping
            rb.grounded = false
            # Gravity
            rb.velocity = rb.velocity + world.config.gravity * dt
            # Damping
            rb.velocity = rb.velocity * (1.0 - rb.linear_damping * dt)
            rb.angular_velocity = rb.angular_velocity * (1.0 - rb.angular_damping * dt)
            # NaN guard: clamp velocities to prevent simulation explosion
            clamp_velocity!(rb)
        end
    end

    # --- Phase 3: Broadphase ---
    clear!(world.broadphase)
    collider_entities = entities_with_component(ColliderComponent)
    for eid in collider_entities
        collider = get_component(eid, ColliderComponent)
        collider === nothing && continue
        # Skip triggers in collision broadphase (they're handled separately)
        collider.is_trigger && continue
        aabb = get_entity_physics_aabb(eid)
        aabb === nothing && continue
        insert!(world.broadphase, eid, aabb)
    end
    candidate_pairs = query_pairs(world.broadphase)

    # --- Phase 4: Narrowphase ---
    manifolds = if threading_enabled()
        # Parallel path: snapshot component data then test pairs on worker threads
        transform_snap = snapshot_transforms()
        collider_snap = snapshot_components(ColliderComponent)
        _narrowphase_parallel(candidate_pairs, transform_snap, collider_snap)
    else
        # Serial path (original)
        _manifolds = ContactManifold[]
        for pair in candidate_pairs
            manifold = collide(pair.entity_a, pair.entity_b)
            if manifold !== nothing
                push!(_manifolds, manifold)
            end
        end
        _manifolds
    end

    # Update contact cache (warm-starting)
    update_cache!(world.contact_cache, manifolds)

    # Populate collision event cache for enter/stay/exit detection
    empty!(world.collision_cache.current_pairs)
    empty!(world.collision_cache.current_manifolds)
    for manifold in manifolds
        key = _canonical_key(manifold.entity_a, manifold.entity_b)
        push!(world.collision_cache.current_pairs, key)
        world.collision_cache.current_manifolds[key] = manifold
    end

    # --- Phase 5: Solve velocity constraints ---
    prepare_solver_bodies!(world.solver_bodies)
    pre_step!(manifolds, world.solver_bodies, world.config, dt)
    warm_start!(manifolds, world.solver_bodies)

    # Collect joint constraints from ECS
    empty!(world.constraints)
    iterate_components(JointComponent) do eid, jc
        push!(world.constraints, jc.joint)
    end

    # Prepare joint constraints
    for joint in world.constraints
        prepare_constraint!(joint, world.solver_bodies, dt)
    end

    # Interleaved solving: contacts + joints
    for _ in 1:world.config.solver_iterations
        # Solve contact velocity constraints (one iteration)
        for manifold in manifolds
            haskey(world.solver_bodies, manifold.entity_a) || continue
            haskey(world.solver_bodies, manifold.entity_b) || continue
            body_a = world.solver_bodies[manifold.entity_a]
            body_b = world.solver_bodies[manifold.entity_b]
            for cp in manifold.points
                n = cp.normal
                ra = cp.position - body_a.position
                rb_vec = cp.position - body_b.position
                tangent1, tangent2 = _compute_tangent_basis(n)

                rel_vel_n = _compute_relative_velocity(body_a, body_b, ra, rb_vec, n)
                delta_n = cp.normal_mass * (-rel_vel_n + cp.bias)
                old_n = cp.normal_impulse
                cp.normal_impulse = max(old_n + delta_n, 0.0)
                _apply_impulse!(body_a, body_b, n * (cp.normal_impulse - old_n), ra, rb_vec)

                max_friction = manifold.friction * cp.normal_impulse
                rel_vel_t1 = _compute_relative_velocity(body_a, body_b, ra, rb_vec, tangent1)
                old_t1 = cp.tangent_impulse1
                cp.tangent_impulse1 = clamp(old_t1 + cp.tangent_mass1 * (-rel_vel_t1), -max_friction, max_friction)
                _apply_impulse!(body_a, body_b, tangent1 * (cp.tangent_impulse1 - old_t1), ra, rb_vec)

                rel_vel_t2 = _compute_relative_velocity(body_a, body_b, ra, rb_vec, tangent2)
                old_t2 = cp.tangent_impulse2
                cp.tangent_impulse2 = clamp(old_t2 + cp.tangent_mass2 * (-rel_vel_t2), -max_friction, max_friction)
                _apply_impulse!(body_a, body_b, tangent2 * (cp.tangent_impulse2 - old_t2), ra, rb_vec)
            end
        end

        # Solve joint constraints (one iteration)
        for joint in world.constraints
            solve_constraint!(joint, world.solver_bodies)
        end
    end

    write_back_velocities!(world.solver_bodies)

    # --- Phase 5b: CCD (continuous collision detection) ---
    apply_ccd!(world, dt)

    # --- Phase 6: Integrate positions ---
    iterate_components(RigidBodyComponent) do eid, rb
        if rb.body_type == BODY_DYNAMIC && !rb.sleeping
            tc = get_component(eid, TransformComponent)
            if tc !== nothing
                # Linear integration
                tc.position[] = tc.position[] + rb.velocity * dt

                # Angular integration (quaternion update)
                ang_vel = rb.angular_velocity
                speed = vec3d_length(ang_vel)
                if speed > COLLISION_EPSILON
                    axis = ang_vel / speed
                    half_angle = speed * dt * 0.5
                    dq = Quaternion(cos(half_angle),
                                    axis[1] * sin(half_angle),
                                    axis[2] * sin(half_angle),
                                    axis[3] * sin(half_angle))
                    q = tc.rotation[]
                    new_q = dq * q
                    # Normalize to prevent drift
                    norm_sq = new_q.s^2 + new_q.v1^2 + new_q.v2^2 + new_q.v3^2
                    if norm_sq > 0
                        inv_norm = 1.0 / sqrt(norm_sq)
                        tc.rotation[] = Quaternion(new_q.s * inv_norm, new_q.v1 * inv_norm,
                                                    new_q.v2 * inv_norm, new_q.v3 * inv_norm)
                    end
                end
            end
        end
    end

    # --- Phase 7: Update grounded flags from contacts ---
    for manifold in manifolds
        for cp in manifold.points
            # If normal points upward relative to entity_a, then entity_a is grounded
            if cp.normal[2] < -0.7
                rb_a = get_component(manifold.entity_a, RigidBodyComponent)
                if rb_a !== nothing
                    rb_a.grounded = true
                end
            end
            # If normal points upward relative to entity_b, then entity_b is grounded
            if cp.normal[2] > 0.7
                rb_b = get_component(manifold.entity_b, RigidBodyComponent)
                if rb_b !== nothing
                    rb_b.grounded = true
                end
            end
        end
    end

    # --- Phase 8: Trigger detection ---
    update_triggers!()

    # --- Phase 8b: Collision callbacks ---
    update_collision_callbacks!(world)

    # --- Phase 9: Island-based sleeping ---
    update_islands!(world, dt)
end
