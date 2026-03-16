# Render Graph — OpenGL Visual Test
# Demonstrates the render graph driving the full deferred pipeline on OpenGL.
# Uses all post-processing effects to exercise every decomposed pass.

using OpenReality

reset_entity_counter!()
reset_component_stores!()

# ---- Build a scene with enough visual variety to test all passes ----

s = scene([
    # Player with camera
    create_player(position=Vec3d(0, 2.0, 10)),

    # Directional light (triggers CSM shadow pass)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            color=RGB{Float32}(1.0, 0.98, 0.95),
            intensity=2.5f0
        )
    ]),

    # Point lights (test light accumulation in deferred lighting pass)
    entity([
        PointLightComponent(color=RGB{Float32}(1.0, 0.3, 0.1), intensity=8.0f0, range=15.0f0),
        transform(position=Vec3d(-4, 3, -2))
    ]),
    entity([
        PointLightComponent(color=RGB{Float32}(0.1, 0.4, 1.0), intensity=6.0f0, range=12.0f0),
        transform(position=Vec3d(4, 2, -3))
    ]),

    # Metallic sphere (tests G-buffer MRT: metallic channel + normal mapping)
    entity([
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.95, 0.95, 0.95),
            metallic=1.0f0,
            roughness=0.05f0
        ),
        transform(position=Vec3d(0, 1.0, 0)),
        ColliderComponent(shape=SphereShape(1.0f0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Rough red cube (tests diffuse in G-buffer)
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.8, 0.1, 0.1),
            metallic=0.0f0,
            roughness=0.9f0
        ),
        transform(position=Vec3d(-3, 0.5, 0)),
        ColliderComponent(shape=AABBShape(Vec3f(0.5, 0.5, 0.5))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Emissive cube (tests emissive MRT + bloom extraction)
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.1, 0.1, 0.1),
            metallic=0.0f0,
            roughness=0.5f0,
            emissive_factor=Vec3f(5.0, 2.0, 0.5)
        ),
        transform(position=Vec3d(3, 0.5, -2)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Semi-transparent sphere (tests forward transparent pass over deferred result)
    entity([
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.6, 1.0),
            metallic=0.0f0,
            roughness=0.3f0,
            opacity=0.5f0
        ),
        transform(position=Vec3d(2, 1.5, 2))
    ]),

    # Ground plane
    entity([
        plane_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.4, 0.4, 0.4),
            metallic=0.0f0,
            roughness=0.8f0
        ),
        transform(position=Vec3d(0, 0, 0), scale=Vec3d(20, 1, 20)),
        ColliderComponent(shape=AABBShape(Vec3f(20, 0.01, 20))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),
])

@info "Render Graph OpenGL Test" entities=entity_count(s)
@info "All post-processing effects enabled — exercises every decomposed graph pass"

# Enable the render graph with all post-processing effects
render(s,
    backend=OpenGLBackend(use_render_graph=true),
    width=1280,
    height=720,
    title="OpenReality — Render Graph (OpenGL)",
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=0.8f0,
        bloom_intensity=0.25f0,
        ssao_enabled=true,
        ssao_radius=0.5f0,
        tone_mapping=TONEMAP_ACES,
        fxaa_enabled=true,
        gamma=2.2f0,
        dof_enabled=true,
        dof_focus_distance=8.0f0,
        dof_focus_range=5.0f0,
        dof_bokeh_radius=3.0f0,
        motion_blur_enabled=true,
        motion_blur_intensity=0.6f0,
        motion_blur_samples=8,
        vignette_enabled=true,
        vignette_intensity=0.4f0,
        vignette_radius=0.8f0,
        vignette_softness=0.45f0,
        color_grading_enabled=true,
        color_grading_brightness=0.02f0,
        color_grading_contrast=1.1f0,
        color_grading_saturation=1.15f0
    )
)
