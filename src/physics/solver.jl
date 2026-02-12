# Sequential Impulse Solver (Projected Gauss-Seidel)
# Solves velocity constraints for contact and friction

"""
    SolverBody

Cached body data for the solver to avoid repeated ECS lookups.
"""
mutable struct SolverBody
    entity_id::EntityID
    inv_mass::Float64
    inv_inertia_world::Mat3d
    velocity::Vec3d
    angular_velocity::Vec3d
    position::Vec3d
    body_type::BodyType
end

"""
    prepare_solver_bodies!(bodies::Dict{EntityID, SolverBody})

Collect all rigid bodies into solver-friendly structs.
"""
function prepare_solver_bodies!(bodies::Dict{EntityID, SolverBody})
    empty!(bodies)
    iterate_components(RigidBodyComponent) do eid, rb
        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        collider = get_component(eid, ColliderComponent)

        inv_mass = rb.body_type == BODY_DYNAMIC ? rb.inv_mass : 0.0
        inv_inertia = rb.body_type == BODY_DYNAMIC ? rb.inv_inertia_world : ZERO_MAT3D

        bodies[eid] = SolverBody(
            eid, inv_mass, inv_inertia,
            rb.velocity, rb.angular_velocity,
            tc.position[], rb.body_type
        )
    end
end

"""
    pre_step!(manifolds::Vector{ContactManifold}, bodies::Dict{EntityID, SolverBody}, config::PhysicsWorldConfig, dt::Float64)

Pre-compute solver data for all contacts: effective mass, bias, tangent directions.
"""
function pre_step!(manifolds::Vector{ContactManifold}, bodies::Dict{EntityID, SolverBody},
                   config::PhysicsWorldConfig, dt::Float64)
    inv_dt = dt > 0.0 ? 1.0 / dt : 0.0

    for manifold in manifolds
        haskey(bodies, manifold.entity_a) || continue
        haskey(bodies, manifold.entity_b) || continue

        body_a = bodies[manifold.entity_a]
        body_b = bodies[manifold.entity_b]

        # Combine material properties
        rb_a = get_component(manifold.entity_a, RigidBodyComponent)
        rb_b = get_component(manifold.entity_b, RigidBodyComponent)
        f_a = rb_a !== nothing ? rb_a.friction : 0.5
        f_b = rb_b !== nothing ? rb_b.friction : 0.5
        r_a = rb_a !== nothing ? Float64(rb_a.restitution) : 0.0
        r_b = rb_b !== nothing ? Float64(rb_b.restitution) : 0.0
        manifold.friction = combine_friction(f_a, f_b)
        manifold.restitution = combine_restitution(r_a, r_b)

        for cp in manifold.points
            n = cp.normal
            ra = cp.position - body_a.position
            rb_vec = cp.position - body_b.position

            # Compute effective mass for normal constraint
            # K = 1/m_a + 1/m_b + (I_a⁻¹ * (ra × n)) × ra · n + (I_b⁻¹ * (rb × n)) × rb · n
            ra_cross_n = vec3d_cross(ra, n)
            rb_cross_n = vec3d_cross(rb_vec, n)

            ang_a = body_a.inv_inertia_world * ra_cross_n
            ang_b = body_b.inv_inertia_world * rb_cross_n

            k_normal = body_a.inv_mass + body_b.inv_mass +
                       vec3d_dot(vec3d_cross(ang_a, ra), n) +
                       vec3d_dot(vec3d_cross(ang_b, rb_vec), n)

            cp.normal_mass = k_normal > 0.0 ? 1.0 / k_normal : 0.0

            # Compute tangent directions (perpendicular to normal)
            tangent1, tangent2 = _compute_tangent_basis(n)

            # Effective mass for tangent constraints
            ra_cross_t1 = vec3d_cross(ra, tangent1)
            rb_cross_t1 = vec3d_cross(rb_vec, tangent1)
            ang_a_t1 = body_a.inv_inertia_world * ra_cross_t1
            ang_b_t1 = body_b.inv_inertia_world * rb_cross_t1
            k_tangent1 = body_a.inv_mass + body_b.inv_mass +
                         vec3d_dot(vec3d_cross(ang_a_t1, ra), tangent1) +
                         vec3d_dot(vec3d_cross(ang_b_t1, rb_vec), tangent1)
            cp.tangent_mass1 = k_tangent1 > 0.0 ? 1.0 / k_tangent1 : 0.0

            ra_cross_t2 = vec3d_cross(ra, tangent2)
            rb_cross_t2 = vec3d_cross(rb_vec, tangent2)
            ang_a_t2 = body_a.inv_inertia_world * ra_cross_t2
            ang_b_t2 = body_b.inv_inertia_world * rb_cross_t2
            k_tangent2 = body_a.inv_mass + body_b.inv_mass +
                         vec3d_dot(vec3d_cross(ang_a_t2, ra), tangent2) +
                         vec3d_dot(vec3d_cross(ang_b_t2, rb_vec), tangent2)
            cp.tangent_mass2 = k_tangent2 > 0.0 ? 1.0 / k_tangent2 : 0.0

            # Baumgarte velocity bias for position correction
            pen_correction = max(cp.penetration - config.slop, 0.0)
            cp.bias = config.position_correction * inv_dt * pen_correction

            # Restitution bias
            rel_vel = _compute_relative_velocity(body_a, body_b, ra, rb_vec, n)
            if rel_vel < -1.0  # Only add restitution for approaching contacts
                cp.bias += -manifold.restitution * rel_vel
            end
        end
    end
end

"""
    warm_start!(manifolds::Vector{ContactManifold}, bodies::Dict{EntityID, SolverBody})

Apply cached impulses from previous frame to bootstrap the solver.
"""
function warm_start!(manifolds::Vector{ContactManifold}, bodies::Dict{EntityID, SolverBody})
    for manifold in manifolds
        haskey(bodies, manifold.entity_a) || continue
        haskey(bodies, manifold.entity_b) || continue

        body_a = bodies[manifold.entity_a]
        body_b = bodies[manifold.entity_b]

        for cp in manifold.points
            n = cp.normal
            ra = cp.position - body_a.position
            rb_vec = cp.position - body_b.position
            tangent1, tangent2 = _compute_tangent_basis(n)

            # Apply accumulated impulse
            impulse = n * cp.normal_impulse + tangent1 * cp.tangent_impulse1 + tangent2 * cp.tangent_impulse2

            _apply_impulse!(body_a, body_b, impulse, ra, rb_vec)
        end
    end
end

"""
    solve_velocities!(manifolds::Vector{ContactManifold}, bodies::Dict{EntityID, SolverBody}, iterations::Int)

Iteratively solve velocity constraints for all contacts.
"""
function solve_velocities!(manifolds::Vector{ContactManifold}, bodies::Dict{EntityID, SolverBody},
                           iterations::Int)
    for _ in 1:iterations
        for manifold in manifolds
            haskey(bodies, manifold.entity_a) || continue
            haskey(bodies, manifold.entity_b) || continue

            body_a = bodies[manifold.entity_a]
            body_b = bodies[manifold.entity_b]

            for cp in manifold.points
                n = cp.normal
                ra = cp.position - body_a.position
                rb_vec = cp.position - body_b.position
                tangent1, tangent2 = _compute_tangent_basis(n)

                # --- Normal impulse (non-penetration) ---
                rel_vel_n = _compute_relative_velocity(body_a, body_b, ra, rb_vec, n)
                delta_impulse_n = cp.normal_mass * (-rel_vel_n + cp.bias)

                # Clamp: accumulated normal impulse >= 0 (can only push apart)
                old_impulse = cp.normal_impulse
                cp.normal_impulse = max(old_impulse + delta_impulse_n, 0.0)
                delta_impulse_n = cp.normal_impulse - old_impulse

                _apply_impulse!(body_a, body_b, n * delta_impulse_n, ra, rb_vec)

                # --- Friction impulse (tangent 1) ---
                rel_vel_t1 = _compute_relative_velocity(body_a, body_b, ra, rb_vec, tangent1)
                delta_impulse_t1 = cp.tangent_mass1 * (-rel_vel_t1)

                # Clamp to Coulomb friction cone
                max_friction = manifold.friction * cp.normal_impulse
                old_tangent1 = cp.tangent_impulse1
                cp.tangent_impulse1 = clamp(old_tangent1 + delta_impulse_t1, -max_friction, max_friction)
                delta_impulse_t1 = cp.tangent_impulse1 - old_tangent1

                _apply_impulse!(body_a, body_b, tangent1 * delta_impulse_t1, ra, rb_vec)

                # --- Friction impulse (tangent 2) ---
                rel_vel_t2 = _compute_relative_velocity(body_a, body_b, ra, rb_vec, tangent2)
                delta_impulse_t2 = cp.tangent_mass2 * (-rel_vel_t2)

                old_tangent2 = cp.tangent_impulse2
                cp.tangent_impulse2 = clamp(old_tangent2 + delta_impulse_t2, -max_friction, max_friction)
                delta_impulse_t2 = cp.tangent_impulse2 - old_tangent2

                _apply_impulse!(body_a, body_b, tangent2 * delta_impulse_t2, ra, rb_vec)
            end
        end
    end
end

"""
    write_back_velocities!(bodies::Dict{EntityID, SolverBody})

Write solver velocities back to the ECS components.
"""
function write_back_velocities!(bodies::Dict{EntityID, SolverBody})
    for (eid, body) in bodies
        body.body_type == BODY_DYNAMIC || continue
        rb = get_component(eid, RigidBodyComponent)
        rb === nothing && continue
        rb.velocity = body.velocity
        rb.angular_velocity = body.angular_velocity
    end
end

# =============================================================================
# Internal helpers
# =============================================================================

"""
    _compute_tangent_basis(n::Vec3d) -> (Vec3d, Vec3d)

Compute two tangent vectors perpendicular to the normal.
"""
function _compute_tangent_basis(n::Vec3d)
    if abs(n[1]) > 0.9
        t1 = vec3d_normalize(vec3d_cross(Vec3d(0, 1, 0), n))
    else
        t1 = vec3d_normalize(vec3d_cross(Vec3d(1, 0, 0), n))
    end
    t2 = vec3d_cross(n, t1)
    return t1, t2
end

"""
    _compute_relative_velocity(body_a, body_b, ra, rb, direction) -> Float64

Compute the relative velocity at the contact point along a direction.
"""
@inline function _compute_relative_velocity(body_a::SolverBody, body_b::SolverBody,
                                             ra::Vec3d, rb::Vec3d, direction::Vec3d)
    vel_a = body_a.velocity + vec3d_cross(body_a.angular_velocity, ra)
    vel_b = body_b.velocity + vec3d_cross(body_b.angular_velocity, rb)
    return vec3d_dot(vel_b - vel_a, direction)
end

"""
    _apply_impulse!(body_a, body_b, impulse, ra, rb)

Apply an impulse to two bodies at the contact point.
"""
@inline function _apply_impulse!(body_a::SolverBody, body_b::SolverBody,
                                  impulse::Vec3d, ra::Vec3d, rb::Vec3d)
    body_a.velocity = body_a.velocity - impulse * body_a.inv_mass
    body_a.angular_velocity = body_a.angular_velocity - body_a.inv_inertia_world * vec3d_cross(ra, impulse)
    body_b.velocity = body_b.velocity + impulse * body_b.inv_mass
    body_b.angular_velocity = body_b.angular_velocity + body_b.inv_inertia_world * vec3d_cross(rb, impulse)
end
