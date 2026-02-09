# Rigid body component for physics simulation

"""
    BodyType

Determines how an entity participates in physics.
- `BODY_STATIC`: Never moves (walls, floors, terrain).
- `BODY_KINEMATIC`: Moved by code (player controller), not by physics forces.
- `BODY_DYNAMIC`: Affected by gravity and collision response.
"""
@enum BodyType BODY_STATIC BODY_KINEMATIC BODY_DYNAMIC

"""
    RigidBodyComponent <: Component

Physics body that determines how an entity participates in the physics simulation.
"""
mutable struct RigidBodyComponent <: Component
    body_type::BodyType
    velocity::Vec3d
    mass::Float64
    restitution::Float32
    grounded::Bool

    RigidBodyComponent(;
        body_type::BodyType = BODY_DYNAMIC,
        velocity::Vec3d = Vec3d(0, 0, 0),
        mass::Float64 = 1.0,
        restitution::Float32 = 0.0f0,
        grounded::Bool = false
    ) = new(body_type, velocity, mass, restitution, grounded)
end
