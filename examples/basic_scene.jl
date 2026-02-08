# Basic scene example
# Demonstrates creating a PBR scene with OpenReality

using OpenReality

reset_entity_counter!()
reset_component_stores!()

# Build a PBR scene with FPS player, lights, and objects
s = scene([
    # Player with FPS controls (WASD + mouse look)
    create_player(position=Vec3d(0, 1.7, 8)),

    # Directional light (sun)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=2.0f0
        )
    ]),

    # Point light
    entity([
        PointLightComponent(
            color=RGB{Float32}(1.0, 0.9, 0.8),
            intensity=30.0f0,
            range=20.0f0
        ),
        transform(position=Vec3d(3, 4, 2))
    ]),

    # Red metallic cube
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.1, 0.1),
            metallic=0.9f0,
            roughness=0.1f0
        ),
        transform(position=Vec3d(-2, 0.5, 0))
    ]),

    # Blue rough cube
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.1, 0.3, 0.9),
            metallic=0.0f0,
            roughness=0.8f0
        ),
        transform(position=Vec3d(2, 0.5, 0))
    ]),

    # Green sphere
    entity([
        sphere_mesh(radius=0.6f0),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.8, 0.2),
            metallic=0.3f0,
            roughness=0.4f0
        ),
        transform(position=Vec3d(0, 0.6, 0))
    ]),

    # Gray floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(
            color=RGB{Float32}(0.5, 0.5, 0.5),
            metallic=0.0f0,
            roughness=0.9f0
        ),
        transform()
    ])
])

@info "Scene created with $(entity_count(s)) entities"
render(s)
