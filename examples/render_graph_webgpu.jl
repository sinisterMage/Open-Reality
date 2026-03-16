# Render Graph — WebGPU Visual Test
# Demonstrates the render graph driving the deferred pipeline on WebGPU
# via the Rust wgpu FFI bridge. WebGPU handles barriers automatically.

using OpenReality

if !isdefined(OpenReality, :WebGPUBackend)
    @error "WebGPU backend not available — compile the Rust FFI library first:\n  cd openreality-wgpu && cargo build --release"
    exit(1)
end

reset_entity_counter!()
reset_component_stores!()

# ---- Scene: Feature test to exercise all graph passes via WebGPU ----

s = scene([
    # Player with camera
    create_player(position=Vec3d(0, 2.5, 14)),

    # Directional light (CSM shadows via wgpu)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.2, -1.0, -0.6),
            color=RGB{Float32}(1.0, 0.95, 0.9),
            intensity=2.8f0
        )
    ]),

    # Warm point light
    entity([
        PointLightComponent(color=RGB{Float32}(1.0, 0.7, 0.3), intensity=12.0f0, range=18.0f0),
        transform(position=Vec3d(-3, 5, 2))
    ]),

    # Cool point light
    entity([
        PointLightComponent(color=RGB{Float32}(0.3, 0.6, 1.0), intensity=10.0f0, range=16.0f0),
        transform(position=Vec3d(4, 4, -1))
    ]),

    # Central metallic sphere (high specular — tests SSR + IBL in deferred)
    entity([
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.85, 0.7),
            metallic=1.0f0,
            roughness=0.08f0
        ),
        transform(position=Vec3d(0, 1.5, 0), scale=Vec3d(1.5, 1.5, 1.5)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Colored cubes forming an arc
    [entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(
                Float32(0.5 + 0.5 * cos(i * 0.7)),
                Float32(0.5 + 0.5 * sin(i * 0.5)),
                Float32(0.5 + 0.3 * cos(i * 1.1))
            ),
            metallic=Float32(0.2 + 0.1 * i),
            roughness=Float32(0.3 + 0.05 * i)
        ),
        transform(
            position=Vec3d(5 * cos(i * 0.8), 0.5, 5 * sin(i * 0.8) - 3)
        ),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]) for i in 0:7]...,

    # Bright emissive pillar (drives bloom pass)
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.02, 0.02, 0.02),
            emissive_factor=Vec3f(2.0, 6.0, 10.0)
        ),
        transform(position=Vec3d(-5, 1.5, -2), scale=Vec3d(0.3, 3.0, 0.3)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Transparent glass sphere (forward pass over deferred result)
    entity([
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.7, 0.9, 1.0),
            metallic=0.0f0,
            roughness=0.05f0,
            opacity=0.35f0
        ),
        transform(position=Vec3d(2, 1.2, 3))
    ]),

    # Ground plane
    entity([
        plane_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.3, 0.3, 0.32),
            metallic=0.0f0,
            roughness=0.85f0
        ),
        transform(position=Vec3d(0, 0, 0), scale=Vec3d(30, 1, 30)),
        ColliderComponent(shape=AABBShape(Vec3f(30, 0.01, 30))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),
])

@info "Render Graph WebGPU Test" entities=entity_count(s)
@info "WebGPU render graph — wgpu handles barriers, Julia orchestrates pass order"

# Render with WebGPU backend using the render graph
render(s,
    backend=WebGPUBackend(),
    width=1280,
    height=720,
    title="OpenReality — Render Graph (WebGPU)",
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=0.9f0,
        bloom_intensity=0.2f0,
        ssao_enabled=true,
        ssao_radius=0.5f0,
        tone_mapping=TONEMAP_ACES,
        fxaa_enabled=true,
        gamma=2.2f0,
        dof_enabled=true,
        dof_focus_distance=12.0f0,
        dof_focus_range=6.0f0,
        dof_bokeh_radius=2.0f0,
        motion_blur_enabled=true,
        motion_blur_intensity=0.5f0,
        motion_blur_samples=8,
        vignette_enabled=true,
        vignette_intensity=0.3f0,
        vignette_radius=0.85f0,
        vignette_softness=0.5f0,
        color_grading_enabled=true,
        color_grading_brightness=0.01f0,
        color_grading_contrast=1.08f0,
        color_grading_saturation=1.12f0
    )
)
