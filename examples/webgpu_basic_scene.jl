#!/usr/bin/env julia
# WebGPU Basic Scene
# Run: julia --project=. examples/webgpu_basic_scene.jl
#
# Tests the WebGPU deferred PBR pipeline with a simple scene:
# - G-Buffer pass (geometry)
# - Deferred lighting (directional + point lights)
# - Cascaded shadow maps
# - Post-processing (bloom, tone mapping, FXAA)
# - FPS player controls
#
# Prerequisites:
#   cd openreality-wgpu && cargo build --release

using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    # FPS Player
    create_player(position=Vec3d(0, 1.7, 8)),

    # ====== Lighting ======

    # Directional light (sun)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=2.5f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )
    ]),

    # Warm point light
    entity([
        PointLightComponent(
            color=RGB{Float32}(1.0, 0.7, 0.4),
            intensity=25.0f0,
            range=15.0f0
        ),
        transform(position=Vec3d(-3, 3, 2))
    ]),

    # Cool point light
    entity([
        PointLightComponent(
            color=RGB{Float32}(0.4, 0.6, 1.0),
            intensity=25.0f0,
            range=15.0f0
        ),
        transform(position=Vec3d(3, 3, -2))
    ]),

    # ====== Objects ======

    # Red metallic cube
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.1, 0.1),
            metallic=0.9f0,
            roughness=0.1f0
        ),
        transform(position=Vec3d(-2, 0.5, 0)),
        ColliderComponent(shape=AABBShape(Vec3f(0.5, 0.5, 0.5))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Blue rough cube
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.1, 0.3, 0.9),
            metallic=0.0f0,
            roughness=0.8f0
        ),
        transform(position=Vec3d(2, 0.5, 0)),
        ColliderComponent(shape=AABBShape(Vec3f(0.5, 0.5, 0.5))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Green sphere
    entity([
        sphere_mesh(radius=0.6f0),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.8, 0.2),
            metallic=0.3f0,
            roughness=0.4f0
        ),
        transform(position=Vec3d(0, 0.6, 0)),
        ColliderComponent(shape=SphereShape(0.6f0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Tall column (shadow caster)
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.7, 0.7, 0.7),
            metallic=0.1f0,
            roughness=0.5f0
        ),
        transform(position=Vec3d(3, 2.0, -4), scale=Vec3d(0.5, 4.0, 0.5)),
        ColliderComponent(shape=AABBShape(Vec3f(0.5, 4.0, 0.5))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(
            color=RGB{Float32}(0.4, 0.4, 0.4),
            metallic=0.0f0,
            roughness=0.9f0
        ),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

@info """
WebGPU Basic Scene
===================
Tests: G-Buffer, deferred lighting, CSM shadows, bloom, tone mapping, FXAA

Objects: Red metallic cube, blue rough cube, green sphere, column, floor
Lights:  Directional (sun) + 2 point lights (warm/cool)

Controls: WASD move, Mouse look, Shift sprint, ESC release cursor

Scene: $(entity_count(s)) entities
"""

render(s,
    backend=WebGPUBackend(),
    width=1280,
    height=720,
    title="OpenReality — WebGPU Basic Scene",
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=1.0f0,
        bloom_intensity=0.2f0,
        tone_mapping=TONEMAP_ACES,
        fxaa_enabled=true,
        gamma=2.2f0
    )
)
