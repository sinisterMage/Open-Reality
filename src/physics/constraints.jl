# Joint constraints for the sequential impulse solver
# Each joint type provides prepare!() and solve!() methods

"""
    JointConstraint

Abstract base type for joint constraints between two bodies.
"""
abstract type JointConstraint end

"""
    JointComponent <: Component

Stores a joint constraint between two entities.
"""
mutable struct JointComponent <: Component
    joint::JointConstraint
end

# =============================================================================
# Ball-Socket Joint (3 DOF removed — prevents translation at anchor point)
# =============================================================================

"""
    BallSocketJoint <: JointConstraint

Constrains two bodies to share a common point (the anchor).
Allows free rotation around the anchor.
"""
mutable struct BallSocketJoint <: JointConstraint
    entity_a::EntityID
    entity_b::EntityID
    local_anchor_a::Vec3d  # Anchor point in A's local space
    local_anchor_b::Vec3d  # Anchor point in B's local space
    # Solver data
    r_a::Vec3d             # World-space lever arm A
    r_b::Vec3d             # World-space lever arm B
    effective_mass::SMatrix{3, 3, Float64, 9}
    impulse::Vec3d         # Accumulated impulse
    bias::Vec3d            # Position error correction

    function BallSocketJoint(entity_a::EntityID, entity_b::EntityID;
                              local_anchor_a::Vec3d = Vec3d(0, 0, 0),
                              local_anchor_b::Vec3d = Vec3d(0, 0, 0))
        zero3 = Vec3d(0, 0, 0)
        zero33 = SMatrix{3,3,Float64,9}(0,0,0, 0,0,0, 0,0,0)
        new(entity_a, entity_b, local_anchor_a, local_anchor_b,
            zero3, zero3, zero33, zero3, zero3)
    end
end

# =============================================================================
# Distance Joint (maintains fixed distance between anchor points)
# =============================================================================

"""
    DistanceJoint <: JointConstraint

Maintains a fixed distance between two anchor points on two bodies.
"""
mutable struct DistanceJoint <: JointConstraint
    entity_a::EntityID
    entity_b::EntityID
    local_anchor_a::Vec3d
    local_anchor_b::Vec3d
    target_distance::Float64
    # Solver data
    r_a::Vec3d
    r_b::Vec3d
    normal::Vec3d          # Direction from A anchor to B anchor
    effective_mass::Float64
    impulse::Float64
    bias::Float64

    function DistanceJoint(entity_a::EntityID, entity_b::EntityID;
                            local_anchor_a::Vec3d = Vec3d(0, 0, 0),
                            local_anchor_b::Vec3d = Vec3d(0, 0, 0),
                            target_distance::Float64 = 1.0)
        new(entity_a, entity_b, local_anchor_a, local_anchor_b, target_distance,
            Vec3d(0,0,0), Vec3d(0,0,0), Vec3d(1,0,0), 0.0, 0.0, 0.0)
    end
end

# =============================================================================
# Hinge Joint (1 DOF rotation around axis)
# =============================================================================

"""
    HingeJoint <: JointConstraint

Constrains two bodies to rotate only around a shared axis.
Optionally has angular limits.
"""
mutable struct HingeJoint <: JointConstraint
    entity_a::EntityID
    entity_b::EntityID
    local_anchor_a::Vec3d
    local_anchor_b::Vec3d
    axis::Vec3d            # Hinge axis in world space
    lower_limit::Float64   # Radians (NaN = no limit)
    upper_limit::Float64   # Radians (NaN = no limit)
    # Solver data (point constraint + angular constraint)
    r_a::Vec3d
    r_b::Vec3d
    point_mass::SMatrix{3, 3, Float64, 9}
    point_impulse::Vec3d
    point_bias::Vec3d

    function HingeJoint(entity_a::EntityID, entity_b::EntityID;
                         local_anchor_a::Vec3d = Vec3d(0, 0, 0),
                         local_anchor_b::Vec3d = Vec3d(0, 0, 0),
                         axis::Vec3d = Vec3d(0, 1, 0),
                         lower_limit::Float64 = NaN,
                         upper_limit::Float64 = NaN)
        zero3 = Vec3d(0, 0, 0)
        zero33 = SMatrix{3,3,Float64,9}(0,0,0, 0,0,0, 0,0,0)
        new(entity_a, entity_b, local_anchor_a, local_anchor_b, axis,
            lower_limit, upper_limit,
            zero3, zero3, zero33, zero3, zero3)
    end
end

# =============================================================================
# Fixed Joint (0 DOF — rigid connection)
# =============================================================================

"""
    FixedJoint <: JointConstraint

Rigidly connects two bodies at anchor points (no relative movement or rotation).
"""
mutable struct FixedJoint <: JointConstraint
    entity_a::EntityID
    entity_b::EntityID
    local_anchor_a::Vec3d
    local_anchor_b::Vec3d
    # Solver data
    r_a::Vec3d
    r_b::Vec3d
    point_mass::SMatrix{3, 3, Float64, 9}
    point_impulse::Vec3d
    point_bias::Vec3d

    function FixedJoint(entity_a::EntityID, entity_b::EntityID;
                         local_anchor_a::Vec3d = Vec3d(0, 0, 0),
                         local_anchor_b::Vec3d = Vec3d(0, 0, 0))
        zero3 = Vec3d(0, 0, 0)
        zero33 = SMatrix{3,3,Float64,9}(0,0,0, 0,0,0, 0,0,0)
        new(entity_a, entity_b, local_anchor_a, local_anchor_b,
            zero3, zero3, zero33, zero3, zero3)
    end
end

# =============================================================================
# Slider Joint (1 DOF translation along axis)
# =============================================================================

"""
    SliderJoint <: JointConstraint

Constrains two bodies to slide along a single axis.
"""
mutable struct SliderJoint <: JointConstraint
    entity_a::EntityID
    entity_b::EntityID
    axis::Vec3d            # Sliding axis in world space
    lower_limit::Float64   # Min slide distance (NaN = no limit)
    upper_limit::Float64   # Max slide distance (NaN = no limit)
    # Solver data
    effective_mass::Float64
    impulse::Float64
    bias::Float64

    function SliderJoint(entity_a::EntityID, entity_b::EntityID;
                          axis::Vec3d = Vec3d(1, 0, 0),
                          lower_limit::Float64 = NaN,
                          upper_limit::Float64 = NaN)
        new(entity_a, entity_b, axis, lower_limit, upper_limit, 0.0, 0.0, 0.0)
    end
end

# =============================================================================
# Constraint preparation and solving
# =============================================================================

const CONSTRAINT_BAUMGARTE = 0.2
const CONSTRAINT_SLOP = 0.005

"""
    prepare_constraint!(joint::JointConstraint, bodies::Dict{EntityID, SolverBody}, dt::Float64)

Pre-compute solver data for a joint constraint.
"""
function prepare_constraint!(joint::BallSocketJoint, bodies::Dict{EntityID, SolverBody}, dt::Float64)
    haskey(bodies, joint.entity_a) || return
    haskey(bodies, joint.entity_b) || return
    body_a = bodies[joint.entity_a]
    body_b = bodies[joint.entity_b]

    tc_a = get_component(joint.entity_a, TransformComponent)
    tc_b = get_component(joint.entity_b, TransformComponent)
    (tc_a === nothing || tc_b === nothing) && return

    # Compute world-space anchor positions
    R_a = rotation_matrix(tc_a.rotation[])
    R_b = rotation_matrix(tc_b.rotation[])
    joint.r_a = Vec3d(
        R_a[1,1]*joint.local_anchor_a[1] + R_a[1,2]*joint.local_anchor_a[2] + R_a[1,3]*joint.local_anchor_a[3],
        R_a[2,1]*joint.local_anchor_a[1] + R_a[2,2]*joint.local_anchor_a[2] + R_a[2,3]*joint.local_anchor_a[3],
        R_a[3,1]*joint.local_anchor_a[1] + R_a[3,2]*joint.local_anchor_a[2] + R_a[3,3]*joint.local_anchor_a[3]
    )
    joint.r_b = Vec3d(
        R_b[1,1]*joint.local_anchor_b[1] + R_b[1,2]*joint.local_anchor_b[2] + R_b[1,3]*joint.local_anchor_b[3],
        R_b[2,1]*joint.local_anchor_b[1] + R_b[2,2]*joint.local_anchor_b[2] + R_b[2,3]*joint.local_anchor_b[3],
        R_b[3,1]*joint.local_anchor_b[1] + R_b[3,2]*joint.local_anchor_b[2] + R_b[3,3]*joint.local_anchor_b[3]
    )

    # Position error
    world_a = body_a.position + joint.r_a
    world_b = body_b.position + joint.r_b
    error = world_b - world_a

    inv_dt = dt > 0 ? 1.0 / dt : 0.0
    joint.bias = error * (CONSTRAINT_BAUMGARTE * inv_dt)

    # Compute effective mass matrix: K = m_a⁻¹ I + m_b⁻¹ I - [r_a×]I_a⁻¹[r_a×] - [r_b×]I_b⁻¹[r_b×]
    I3 = SMatrix{3,3,Float64,9}(1,0,0, 0,1,0, 0,0,1)
    K = I3 * (body_a.inv_mass + body_b.inv_mass)
    K = K - _skew(joint.r_a) * body_a.inv_inertia_world * _skew(joint.r_a)
    K = K - _skew(joint.r_b) * body_b.inv_inertia_world * _skew(joint.r_b)

    det_K = det(K)
    if abs(det_K) > 1e-10
        joint.effective_mass = inv(K)
    else
        joint.effective_mass = I3
    end
end

function prepare_constraint!(joint::DistanceJoint, bodies::Dict{EntityID, SolverBody}, dt::Float64)
    haskey(bodies, joint.entity_a) || return
    haskey(bodies, joint.entity_b) || return
    body_a = bodies[joint.entity_a]
    body_b = bodies[joint.entity_b]

    tc_a = get_component(joint.entity_a, TransformComponent)
    tc_b = get_component(joint.entity_b, TransformComponent)
    (tc_a === nothing || tc_b === nothing) && return

    R_a = rotation_matrix(tc_a.rotation[])
    R_b = rotation_matrix(tc_b.rotation[])
    joint.r_a = _rotate_vec(R_a, joint.local_anchor_a)
    joint.r_b = _rotate_vec(R_b, joint.local_anchor_b)

    world_a = body_a.position + joint.r_a
    world_b = body_b.position + joint.r_b
    diff = world_b - world_a
    dist = vec3d_length(diff)

    joint.normal = dist > COLLISION_EPSILON ? diff / dist : Vec3d(1, 0, 0)

    # Effective mass along the constraint axis
    ra_cross_n = vec3d_cross(joint.r_a, joint.normal)
    rb_cross_n = vec3d_cross(joint.r_b, joint.normal)
    k = body_a.inv_mass + body_b.inv_mass +
        vec3d_dot(body_a.inv_inertia_world * ra_cross_n, ra_cross_n) +
        vec3d_dot(body_b.inv_inertia_world * rb_cross_n, rb_cross_n)
    joint.effective_mass = k > 0 ? 1.0 / k : 0.0

    error = dist - joint.target_distance
    inv_dt = dt > 0 ? 1.0 / dt : 0.0
    joint.bias = CONSTRAINT_BAUMGARTE * inv_dt * error
end

# Generic fallback for unimplemented prepare
function prepare_constraint!(joint::JointConstraint, bodies::Dict{EntityID, SolverBody}, dt::Float64)
    # Hinge, Fixed, Slider use simplified point-constraint preparation
    _prepare_point_constraint!(joint, bodies, dt)
end

"""
    solve_constraint!(joint::JointConstraint, bodies::Dict{EntityID, SolverBody})

Solve one iteration of the joint constraint.
"""
function solve_constraint!(joint::BallSocketJoint, bodies::Dict{EntityID, SolverBody})
    haskey(bodies, joint.entity_a) || return
    haskey(bodies, joint.entity_b) || return
    body_a = bodies[joint.entity_a]
    body_b = bodies[joint.entity_b]

    # Relative velocity at anchor points
    vel_a = body_a.velocity + vec3d_cross(body_a.angular_velocity, joint.r_a)
    vel_b = body_b.velocity + vec3d_cross(body_b.angular_velocity, joint.r_b)
    rel_vel = vel_b - vel_a

    # Compute impulse: lambda = K⁻¹ * (-Cdot - bias)
    rhs = -(rel_vel + joint.bias)
    impulse = joint.effective_mass * rhs

    joint.impulse = joint.impulse + impulse

    # Apply impulse
    body_a.velocity = body_a.velocity - impulse * body_a.inv_mass
    body_a.angular_velocity = body_a.angular_velocity - body_a.inv_inertia_world * vec3d_cross(joint.r_a, impulse)
    body_b.velocity = body_b.velocity + impulse * body_b.inv_mass
    body_b.angular_velocity = body_b.angular_velocity + body_b.inv_inertia_world * vec3d_cross(joint.r_b, impulse)
end

function solve_constraint!(joint::DistanceJoint, bodies::Dict{EntityID, SolverBody})
    haskey(bodies, joint.entity_a) || return
    haskey(bodies, joint.entity_b) || return
    body_a = bodies[joint.entity_a]
    body_b = bodies[joint.entity_b]

    vel_a = body_a.velocity + vec3d_cross(body_a.angular_velocity, joint.r_a)
    vel_b = body_b.velocity + vec3d_cross(body_b.angular_velocity, joint.r_b)
    rel_vel_n = vec3d_dot(vel_b - vel_a, joint.normal)

    impulse_scalar = joint.effective_mass * (-rel_vel_n - joint.bias)
    joint.impulse += impulse_scalar

    impulse = joint.normal * impulse_scalar
    body_a.velocity = body_a.velocity - impulse * body_a.inv_mass
    body_a.angular_velocity = body_a.angular_velocity - body_a.inv_inertia_world * vec3d_cross(joint.r_a, impulse)
    body_b.velocity = body_b.velocity + impulse * body_b.inv_mass
    body_b.angular_velocity = body_b.angular_velocity + body_b.inv_inertia_world * vec3d_cross(joint.r_b, impulse)
end

# Fallback solver for joints using point constraint
function solve_constraint!(joint::JointConstraint, bodies::Dict{EntityID, SolverBody})
    _solve_point_constraint!(joint, bodies)
end

# =============================================================================
# Helpers
# =============================================================================

"""
    _skew(v::Vec3d) -> SMatrix{3,3,Float64,9}

Skew-symmetric matrix for cross product: [v]× such that [v]× * w = v × w.
"""
function _skew(v::Vec3d)
    return SMatrix{3,3,Float64,9}(
         0,     v[3], -v[2],
        -v[3],  0,     v[1],
         v[2], -v[1],  0
    )
end

function _rotate_vec(R::Mat4d, v::Vec3d)
    return Vec3d(
        R[1,1]*v[1] + R[1,2]*v[2] + R[1,3]*v[3],
        R[2,1]*v[1] + R[2,2]*v[2] + R[2,3]*v[3],
        R[3,1]*v[1] + R[3,2]*v[2] + R[3,3]*v[3]
    )
end

# Simplified point constraint (used by Hinge, Fixed, Slider as fallback)
function _prepare_point_constraint!(joint, bodies, dt)
    ea = hasproperty(joint, :entity_a) ? joint.entity_a : return
    eb = hasproperty(joint, :entity_b) ? joint.entity_b : return
    haskey(bodies, ea) || return
    haskey(bodies, eb) || return

    if hasproperty(joint, :local_anchor_a) && hasproperty(joint, :r_a)
        body_a = bodies[ea]
        body_b = bodies[eb]
        tc_a = get_component(ea, TransformComponent)
        tc_b = get_component(eb, TransformComponent)
        (tc_a === nothing || tc_b === nothing) && return

        R_a = rotation_matrix(tc_a.rotation[])
        R_b = rotation_matrix(tc_b.rotation[])
        joint.r_a = _rotate_vec(R_a, joint.local_anchor_a)
        joint.r_b = _rotate_vec(R_b, joint.local_anchor_b)

        world_a = body_a.position + joint.r_a
        world_b = body_b.position + joint.r_b
        error = world_b - world_a

        inv_dt = dt > 0 ? 1.0 / dt : 0.0
        joint.point_bias = error * (CONSTRAINT_BAUMGARTE * inv_dt)

        I3 = SMatrix{3,3,Float64,9}(1,0,0, 0,1,0, 0,0,1)
        K = I3 * (body_a.inv_mass + body_b.inv_mass)
        K = K - _skew(joint.r_a) * body_a.inv_inertia_world * _skew(joint.r_a)
        K = K - _skew(joint.r_b) * body_b.inv_inertia_world * _skew(joint.r_b)

        det_K = det(K)
        if abs(det_K) > 1e-10
            joint.point_mass = inv(K)
        else
            joint.point_mass = I3
        end
    end
end

function _solve_point_constraint!(joint, bodies)
    ea = hasproperty(joint, :entity_a) ? joint.entity_a : return
    eb = hasproperty(joint, :entity_b) ? joint.entity_b : return
    haskey(bodies, ea) || return
    haskey(bodies, eb) || return

    if hasproperty(joint, :r_a) && hasproperty(joint, :point_mass)
        body_a = bodies[ea]
        body_b = bodies[eb]

        vel_a = body_a.velocity + vec3d_cross(body_a.angular_velocity, joint.r_a)
        vel_b = body_b.velocity + vec3d_cross(body_b.angular_velocity, joint.r_b)
        rel_vel = vel_b - vel_a

        impulse = joint.point_mass * (-(rel_vel + joint.point_bias))
        joint.point_impulse = joint.point_impulse + impulse

        body_a.velocity = body_a.velocity - impulse * body_a.inv_mass
        body_a.angular_velocity = body_a.angular_velocity - body_a.inv_inertia_world * vec3d_cross(joint.r_a, impulse)
        body_b.velocity = body_b.velocity + impulse * body_b.inv_mass
        body_b.angular_velocity = body_b.angular_velocity + body_b.inv_inertia_world * vec3d_cross(joint.r_b, impulse)
    end
end
