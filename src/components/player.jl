# Player component for FPS-style movement

"""
    PlayerComponent <: Component

Marks an entity as the player and stores FPS movement settings.
Attach to an entity with a TransformComponent. A CameraComponent child entity
will be used for view rendering.

Yaw and pitch are stored here (rather than derived from the quaternion) so that
FPS mouse-look stays numerically stable.
"""
mutable struct PlayerComponent <: Component
    move_speed::Float32
    sprint_multiplier::Float32
    mouse_sensitivity::Float32
    yaw::Float64    # radians, rotation around Y axis
    pitch::Float64  # radians, rotation around X axis (clamped ±89°)
    ground_ray_length::Float64  # Raycast distance for ground detection
    input_map::Union{InputMap, Nothing}  # Custom input bindings (nothing = use defaults)

    PlayerComponent(;
        move_speed::Float32 = 5.0f0,
        sprint_multiplier::Float32 = 2.0f0,
        mouse_sensitivity::Float32 = 0.002f0,
        yaw::Float64 = 0.0,
        pitch::Float64 = 0.0,
        ground_ray_length::Float64 = 1.1,
        input_map::Union{InputMap, Nothing} = nothing
    ) = new(move_speed, sprint_multiplier, mouse_sensitivity, yaw, pitch, ground_ray_length, input_map)
end

"""
    create_player(; position, mesh, material, fov, aspect, near, far, kwargs...) -> EntityDef

Convenience function to create a player entity with an attached camera child.

Returns an EntityDef suitable for use in `scene([...])`.

Optionally pass a `mesh` and `material` to give the player a visible body.

# Example
```julia
s = scene([
    create_player(position=Vec3d(0, 2, 8)),
    entity([cube_mesh(), MaterialComponent(), transform()])
])
render(s)
```
"""
function create_player(;
    position::Vec3d = Vec3d(0, 1.7, 0),
    move_speed::Float32 = 5.0f0,
    sprint_multiplier::Float32 = 2.0f0,
    mouse_sensitivity::Float32 = 0.002f0,
    input_map::Union{InputMap, Nothing} = nothing,
    mesh::Union{MeshComponent, Nothing} = nothing,
    material::Union{MaterialComponent, Nothing} = nothing,
    fov::Float32 = 70.0f0,
    aspect::Float32 = Float32(16/9),
    near::Float32 = 0.1f0,
    far::Float32 = 500.0f0
)
    # Player entity components
    components = Any[
        PlayerComponent(
            move_speed=move_speed,
            sprint_multiplier=sprint_multiplier,
            mouse_sensitivity=mouse_sensitivity,
            input_map=input_map
        ),
        transform(position=position),
        ColliderComponent(shape=AABBShape(Vec3f(0.3f0, 0.9f0, 0.3f0))),
        RigidBodyComponent(body_type=BODY_KINEMATIC)
    ]

    # Optional visible body
    if mesh !== nothing
        push!(components, mesh)
    end
    if material !== nothing
        push!(components, material)
    end

    # Camera as child entity (inherits player's transform)
    camera_child = entity([
        CameraComponent(fov=fov, aspect=aspect, near=near, far=far),
        transform()  # local offset (0,0,0) — sits at player position
    ])

    return entity(components, children=[camera_child])
end
