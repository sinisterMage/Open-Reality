#!/usr/bin/env julia
# WebGPU PBR Material Showcase
# Run: julia --project=. examples/webgpu_pbr_showcase.jl
#
# Tests the full WebGPU deferred PBR pipeline:
# - Multiple PBR materials (metallic/dielectric, varying roughness)
# - Clearcoat, emissive, subsurface materials
# - Image-based lighting (procedural sky)
# - Cascaded shadow maps
# - SSAO (screen-space ambient occlusion)
# - SSR (screen-space reflections)
# - TAA (temporal anti-aliasing)
# - Bloom + ACES tone mapping + FXAA
# - Transparent objects (forward pass)
#
# Prerequisites:
#   cd openreality-wgpu && cargo build --release

using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    # FPS Player
    create_player(position=Vec3d(0, 2.0, 10)),

    # ====== Lighting ======

    # IBL environment (procedural sky)
    entity([
        IBLComponent(environment_path="sky", intensity=1.0f0, enabled=true)
    ]),

    # Directional light (sun)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=3.0f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )
    ]),

    # Warm fill light
    entity([
        PointLightComponent(
            color=RGB{Float32}(1.0, 0.7, 0.4),
            intensity=30.0f0,
            range=20.0f0
        ),
        transform(position=Vec3d(-5, 4, 3))
    ]),

    # Cool fill light
    entity([
        PointLightComponent(
            color=RGB{Float32}(0.4, 0.6, 1.0),
            intensity=30.0f0,
            range=20.0f0
        ),
        transform(position=Vec3d(5, 4, -3))
    ]),

    # ====== Row 1: Metallic roughness gradient (back row) ======

    # Roughness 0.0 (mirror)
    entity([
        sphere_mesh(radius=0.7f0),
        MaterialComponent(
            color=RGB{Float32}(0.95, 0.95, 0.95),
            metallic=1.0f0,
            roughness=0.0f0
        ),
        transform(position=Vec3d(-6, 1.5, -4))
    ]),

    # Roughness 0.25
    entity([
        sphere_mesh(radius=0.7f0),
        MaterialComponent(
            color=RGB{Float32}(0.95, 0.95, 0.95),
            metallic=1.0f0,
            roughness=0.25f0
        ),
        transform(position=Vec3d(-3, 1.5, -4))
    ]),

    # Roughness 0.5
    entity([
        sphere_mesh(radius=0.7f0),
        MaterialComponent(
            color=RGB{Float32}(0.95, 0.95, 0.95),
            metallic=1.0f0,
            roughness=0.5f0
        ),
        transform(position=Vec3d(0, 1.5, -4))
    ]),

    # Roughness 0.75
    entity([
        sphere_mesh(radius=0.7f0),
        MaterialComponent(
            color=RGB{Float32}(0.95, 0.95, 0.95),
            metallic=1.0f0,
            roughness=0.75f0
        ),
        transform(position=Vec3d(3, 1.5, -4))
    ]),

    # Roughness 1.0
    entity([
        sphere_mesh(radius=0.7f0),
        MaterialComponent(
            color=RGB{Float32}(0.95, 0.95, 0.95),
            metallic=1.0f0,
            roughness=1.0f0
        ),
        transform(position=Vec3d(6, 1.5, -4))
    ]),

    # ====== Row 2: Colored metals (front row) ======

    # Gold
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(1.0, 0.84, 0.0),
            metallic=1.0f0,
            roughness=0.05f0
        ),
        transform(position=Vec3d(-4, 1.5, 0))
    ]),

    # Copper
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(0.85, 0.55, 0.4),
            metallic=1.0f0,
            roughness=0.35f0
        ),
        transform(position=Vec3d(-2, 1.5, 0))
    ]),

    # Red plastic (dielectric)
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(0.8, 0.1, 0.1),
            metallic=0.0f0,
            roughness=0.2f0
        ),
        transform(position=Vec3d(0, 1.5, 0))
    ]),

    # Green rubber (dielectric, rough)
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.7, 0.2),
            metallic=0.0f0,
            roughness=0.8f0
        ),
        transform(position=Vec3d(2, 1.5, 0))
    ]),

    # Chrome with clearcoat
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(0.95, 0.95, 0.95),
            metallic=1.0f0,
            roughness=0.0f0,
            clearcoat=1.0f0,
            clearcoat_roughness=0.03f0
        ),
        transform(position=Vec3d(4, 1.5, 0))
    ]),

    # ====== Special materials ======

    # Emissive sphere (glowing blue)
    entity([
        sphere_mesh(radius=0.5f0),
        MaterialComponent(
            color=RGB{Float32}(0.1, 0.1, 0.3),
            metallic=0.0f0,
            roughness=0.5f0,
            emissive_factor=Vec3f(0.5f0, 1.0f0, 2.0f0)
        ),
        transform(position=Vec3d(-6, 1.0, 3))
    ]),

    # Subsurface sphere
    entity([
        sphere_mesh(radius=0.5f0),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.7, 0.6),
            metallic=0.0f0,
            roughness=0.6f0,
            subsurface=0.8f0
        ),
        transform(position=Vec3d(-4, 1.0, 3))
    ]),

    # ====== Transparent objects (forward pass test) ======

    # Semi-transparent blue cube
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.4, 0.9),
            metallic=0.0f0,
            roughness=0.3f0,
            opacity=0.4f0
        ),
        transform(position=Vec3d(4, 0.5, 3))
    ]),

    # Semi-transparent red sphere
    entity([
        sphere_mesh(radius=0.6f0),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.2, 0.2),
            metallic=0.0f0,
            roughness=0.2f0,
            opacity=0.5f0
        ),
        transform(position=Vec3d(6, 0.6, 3))
    ]),

    # ====== Geometry ======

    # Pedestal for row 2
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.35, 0.35, 0.35),
            metallic=0.2f0,
            roughness=0.4f0
        ),
        transform(position=Vec3d(0, 0.25, 0), scale=Vec3d(7.0, 0.5, 2.0))
    ]),

    # Shadow-casting columns
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.6, 0.4, 0.2), metallic=0.0f0, roughness=0.6f0),
        transform(position=Vec3d(-7, 1.5, -2), scale=Vec3d(0.4, 3.0, 0.4))
    ]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.6, 0.4, 0.2), metallic=0.0f0, roughness=0.6f0),
        transform(position=Vec3d(7, 1.5, -2), scale=Vec3d(0.4, 3.0, 0.4))
    ]),

    # Floor (reflective for SSR test)
    entity([
        plane_mesh(width=30.0f0, depth=30.0f0),
        MaterialComponent(
            color=RGB{Float32}(0.25, 0.25, 0.25),
            metallic=0.3f0,
            roughness=0.5f0
        ),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(15.0, 0.01, 15.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

@info """
WebGPU PBR Material Showcase
==============================
Tests: G-Buffer, deferred PBR, IBL, CSM shadows, SSAO, SSR, TAA, bloom, FXAA, forward transparency

Row 1 (back):  Metallic roughness gradient 0.0 → 1.0
Row 2 (front): Gold, Copper, Red Plastic, Green Rubber, Chrome+Clearcoat
Special:       Emissive (blue glow), Subsurface (skin-like)
Transparent:   Blue cube (40%%), Red sphere (50%%)

Controls: WASD move, Mouse look, Shift sprint, ESC release cursor

Scene: $(entity_count(s)) entities
"""

render(s,
    backend=WebGPUBackend(),
    width=1280,
    height=720,
    title="OpenReality — WebGPU PBR Showcase",
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=1.0f0,
        bloom_intensity=0.3f0,
        ssao_enabled=true,
        tone_mapping=TONEMAP_ACES,
        fxaa_enabled=true,
        gamma=2.2f0
    )
)
