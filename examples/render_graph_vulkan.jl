# Render Graph — Vulkan Visual Test
# Demonstrates the render graph driving the deferred pipeline on Vulkan
# with automatic barrier pre-computation replacing manual layout transitions.

using OpenReality

if Sys.isapple()
    @error "Vulkan is not supported on macOS — use render_graph_opengl.jl or Metal"
    exit(1)
end

reset_entity_counter!()
reset_component_stores!()

# ---- Scene: PBR showcase to exercise all deferred passes ----

s = scene([
    # Player with camera
    create_player(position=Vec3d(0, 2.0, 12)),

    # Directional light (CSM shadows)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.4, -1.0, -0.3),
            color=RGB{Float32}(1.0, 0.97, 0.92),
            intensity=3.0f0
        )
    ]),

    # Point lights
    entity([
        PointLightComponent(color=RGB{Float32}(1.0, 0.6, 0.2), intensity=10.0f0, range=20.0f0),
        transform(position=Vec3d(-5, 4, 0))
    ]),
    entity([
        PointLightComponent(color=RGB{Float32}(0.2, 0.5, 1.0), intensity=8.0f0, range=15.0f0),
        transform(position=Vec3d(5, 3, -3))
    ]),

    # Row of spheres with varying roughness (PBR metallic workflow)
    [entity([
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.9, 0.9),
            metallic=1.0f0,
            roughness=Float32(i / 6.0)
        ),
        transform(position=Vec3d(-5 + 2i, 1.0, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]) for i in 0:5]...,

    # Row of colored dielectric spheres
    [entity([
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(
                Float32(0.2 + 0.15 * i),
                Float32(0.8 - 0.1 * i),
                Float32(0.3 + 0.1 * i)
            ),
            metallic=0.0f0,
            roughness=0.4f0
        ),
        transform(position=Vec3d(-5 + 2i, 1.0, -4)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]) for i in 0:5]...,

    # Emissive cubes for bloom
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.05, 0.05, 0.05),
            emissive_factor=Vec3f(8.0, 1.0, 0.2)
        ),
        transform(position=Vec3d(-3, 0.5, 4)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.05, 0.05, 0.05),
            emissive_factor=Vec3f(0.3, 3.0, 8.0)
        ),
        transform(position=Vec3d(3, 0.5, 4)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Transparent objects
    entity([
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(1.0, 0.3, 0.3),
            opacity=0.4f0,
            roughness=0.1f0
        ),
        transform(position=Vec3d(0, 2.0, 3))
    ]),

    # Ground
    entity([
        plane_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.35, 0.35, 0.35),
            metallic=0.0f0,
            roughness=0.9f0
        ),
        transform(position=Vec3d(0, 0, 0), scale=Vec3d(25, 1, 25)),
        ColliderComponent(shape=AABBShape(Vec3f(25, 0.01, 25))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),
])

@info "Render Graph Vulkan Test" entities=entity_count(s)
@info "Vulkan render graph with automatic barrier pre-computation"

# Render with Vulkan backend using the render graph
render(s,
    backend=VulkanBackend(),
    width=1280,
    height=720,
    title="OpenReality — Render Graph (Vulkan)",
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=1.0f0,
        bloom_intensity=0.3f0,
        ssao_enabled=true,
        ssao_radius=0.5f0,
        tone_mapping=TONEMAP_ACES,
        fxaa_enabled=true,
        gamma=2.2f0,
        dof_enabled=true,
        dof_focus_distance=10.0f0,
        dof_focus_range=6.0f0,
        dof_bokeh_radius=2.5f0,
        motion_blur_enabled=true,
        motion_blur_intensity=0.5f0,
        motion_blur_samples=8,
        vignette_enabled=true,
        vignette_intensity=0.35f0,
        vignette_radius=0.85f0,
        vignette_softness=0.5f0,
        color_grading_enabled=true,
        color_grading_brightness=0.01f0,
        color_grading_contrast=1.05f0,
        color_grading_saturation=1.1f0
    )
)
