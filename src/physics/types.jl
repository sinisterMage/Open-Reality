# Core physics types, constants, and configuration

"""
    PhysicsWorldConfig

Configuration for the physics simulation.
"""
struct PhysicsWorldConfig
    gravity::Vec3d
    fixed_dt::Float64           # Fixed timestep (default 1/120)
    max_substeps::Int           # Maximum substeps per frame
    solver_iterations::Int      # PGS solver iterations
    position_correction::Float64 # Baumgarte stabilization factor
    slop::Float64               # Penetration allowance before correction
    sleep_linear_threshold::Float64  # Linear velocity threshold for sleeping
    sleep_angular_threshold::Float64 # Angular velocity threshold for sleeping
    sleep_time::Float64         # Time below threshold before sleeping

    PhysicsWorldConfig(;
        gravity::Vec3d = Vec3d(0, -9.81, 0),
        fixed_dt::Float64 = 1.0 / 120.0,
        max_substeps::Int = 8,
        solver_iterations::Int = 10,
        position_correction::Float64 = 0.2,
        slop::Float64 = 0.005,
        sleep_linear_threshold::Float64 = 0.01,
        sleep_angular_threshold::Float64 = 0.05,
        sleep_time::Float64 = 0.5
    ) = new(gravity, fixed_dt, max_substeps, solver_iterations,
            position_correction, slop, sleep_linear_threshold,
            sleep_angular_threshold, sleep_time)
end

"""
    CCDMode

Continuous collision detection mode for a rigid body.
"""
@enum CCDMode CCD_NONE CCD_SWEPT

"""
    ContactPoint

A single contact point between two colliding bodies.
Stores accumulated impulses for warm-starting across frames.
"""
mutable struct ContactPoint
    position::Vec3d          # World-space contact point
    normal::Vec3d            # Contact normal (A → B)
    penetration::Float64     # Penetration depth (positive = overlapping)
    normal_impulse::Float64  # Accumulated normal impulse (warm-start)
    tangent_impulse1::Float64 # Accumulated friction impulse (tangent 1)
    tangent_impulse2::Float64 # Accumulated friction impulse (tangent 2)
    # Pre-computed solver data (filled during pre-step)
    normal_mass::Float64     # Effective mass along normal
    tangent_mass1::Float64   # Effective mass along tangent 1
    tangent_mass2::Float64   # Effective mass along tangent 2
    bias::Float64            # Velocity bias for position correction
end

function ContactPoint(position::Vec3d, normal::Vec3d, penetration::Float64)
    ContactPoint(position, normal, penetration,
                 0.0, 0.0, 0.0,  # accumulated impulses
                 0.0, 0.0, 0.0,  # effective masses
                 0.0)             # bias
end

"""
    ContactManifold

A set of contact points between two entities.
Up to 4 contact points are maintained for stable contact.
"""
mutable struct ContactManifold
    entity_a::EntityID
    entity_b::EntityID
    normal::Vec3d           # Average contact normal (A → B)
    points::Vector{ContactPoint}
    friction::Float64       # Combined friction coefficient
    restitution::Float64    # Combined restitution coefficient
end

function ContactManifold(entity_a::EntityID, entity_b::EntityID, normal::Vec3d)
    ContactManifold(entity_a, entity_b, normal, ContactPoint[], 0.0, 0.0)
end

"""
    CollisionPair

Output of broadphase: a pair of entity IDs that may be colliding.
"""
struct CollisionPair
    entity_a::EntityID
    entity_b::EntityID
end

"""
    AABB3D

Axis-aligned bounding box in world space (Float64 for physics).
"""
struct AABB3D
    min_pt::Vec3d
    max_pt::Vec3d
end

"""
    aabb_overlap(a::AABB3D, b::AABB3D) -> Bool

Test if two AABBs overlap.
"""
function aabb_overlap(a::AABB3D, b::AABB3D)::Bool
    return a.min_pt[1] <= b.max_pt[1] && a.max_pt[1] >= b.min_pt[1] &&
           a.min_pt[2] <= b.max_pt[2] && a.max_pt[2] >= b.min_pt[2] &&
           a.min_pt[3] <= b.max_pt[3] && a.max_pt[3] >= b.min_pt[3]
end

"""
    RaycastHit

Result of a raycast query.
"""
struct RaycastHit
    entity::EntityID
    point::Vec3d        # World-space hit point
    normal::Vec3d       # Surface normal at hit
    distance::Float64   # Ray parameter t
end
