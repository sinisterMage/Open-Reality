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

Fields:
- `body_type`: BODY_STATIC, BODY_KINEMATIC, or BODY_DYNAMIC
- `velocity`: Linear velocity (m/s)
- `angular_velocity`: Angular velocity (rad/s)
- `mass`: Mass in kg (0 = infinite mass for static/kinematic)
- `inv_mass`: Inverse mass (precomputed, 0 for static/kinematic)
- `inv_inertia_local`: Inverse inertia tensor in local space
- `inv_inertia_world`: Inverse inertia tensor in world space (updated each frame)
- `restitution`: Bounciness coefficient [0,1]
- `friction`: Friction coefficient [0,1+]
- `linear_damping`: Linear velocity damping per second
- `angular_damping`: Angular velocity damping per second
- `grounded`: True if resting on a surface (set by physics)
- `sleeping`: True if body is asleep (not simulated)
- `sleep_timer`: Time below velocity threshold
- `ccd_mode`: Continuous collision detection mode
"""
mutable struct RigidBodyComponent <: Component
    body_type::BodyType
    velocity::Vec3d
    angular_velocity::Vec3d
    mass::Float64
    inv_mass::Float64
    inv_inertia_local::SMatrix{3, 3, Float64, 9}
    inv_inertia_world::SMatrix{3, 3, Float64, 9}
    restitution::Float32
    friction::Float64
    linear_damping::Float64
    angular_damping::Float64
    grounded::Bool
    sleeping::Bool
    sleep_timer::Float64
    ccd_mode::CCDMode

    function RigidBodyComponent(;
        body_type::BodyType = BODY_DYNAMIC,
        velocity::Vec3d = Vec3d(0, 0, 0),
        angular_velocity::Vec3d = Vec3d(0, 0, 0),
        mass::Float64 = 1.0,
        restitution::Float32 = 0.0f0,
        friction::Float64 = 0.5,
        linear_damping::Float64 = 0.01,
        angular_damping::Float64 = 0.05,
        grounded::Bool = false,
        sleeping::Bool = false,
        ccd_mode::CCDMode = CCD_NONE
    )
        inv_mass = (body_type == BODY_DYNAMIC && mass > 0.0) ? 1.0 / mass : 0.0
        zero_inertia = SMatrix{3, 3, Float64, 9}(0,0,0, 0,0,0, 0,0,0)
        new(body_type, velocity, angular_velocity, mass, inv_mass,
            zero_inertia, zero_inertia, restitution, friction,
            linear_damping, angular_damping, grounded, sleeping, 0.0, ccd_mode)
    end
end

"""
    initialize_rigidbody_inertia!(entity_id::EntityID)

Compute and set the inverse inertia tensor for a rigid body based on its collider shape.
Called once when the entity is created or the collider changes.
"""
function initialize_rigidbody_inertia!(entity_id::EntityID)
    rb = get_component(entity_id, RigidBodyComponent)
    rb === nothing && return
    rb.body_type == BODY_DYNAMIC || return

    collider = get_component(entity_id, ColliderComponent)
    collider === nothing && return

    tc = get_component(entity_id, TransformComponent)
    scale = tc !== nothing ? tc.scale[] : Vec3d(1, 1, 1)

    rb.inv_inertia_local = compute_inverse_inertia(collider.shape, rb.mass, scale)
    rb.inv_inertia_world = rb.inv_inertia_local  # Will be updated each physics frame
end
