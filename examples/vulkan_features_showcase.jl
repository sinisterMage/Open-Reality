#!/usr/bin/env julia
# Vulkan Features Showcase
#
# Run with:
#   julia --project=. examples/vulkan_features_showcase.jl
#
# Mirrors examples/features_showcase.jl with a focus on the Vulkan-specific
# features that landed when Vulkan became the primary backend:
# - Forward transparent pass (alpha-blended geometry on top of deferred output)
# - Screen-Space Reflections (SSR) on glossy materials
# - Bloom + ACES tone mapping + FXAA + DOF + motion blur
# - SSAO, TAA, cascaded shadow maps, IBL (procedural sky)
# - Immediate-mode UI overlay
#
# Use this scene to eyeball Vulkan vs OpenGL parity.

using OpenReality

reset_entity_counter!()
reset_component_stores!()

# =============================================================================
# Scene
# =============================================================================

s = scene([
    create_player(position=Vec3d(0, 2.0, 10)),

    # ----- Lighting -----
    entity([
        IBLComponent(environment_path="sky", intensity=1.2f0, enabled=true)
    ]),
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=3.0f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )
    ]),
    entity([
        PointLightComponent(
            color=RGB{Float32}(1.0, 0.7, 0.4),
            intensity=30.0f0,
            range=20.0f0
        ),
        transform(position=Vec3d(-5, 4, 3))
    ]),
    entity([
        PointLightComponent(
            color=RGB{Float32}(0.4, 0.6, 1.0),
            intensity=30.0f0,
            range=20.0f0
        ),
        transform(position=Vec3d(5, 4, 3))
    ]),

    # ----- Glossy floor (good SSR candidate) -----
    entity([
        plane_mesh(width=40.0f0, depth=40.0f0),
        MaterialComponent(
            color=RGB{Float32}(0.10, 0.10, 0.12),
            metallic=0.0f0,
            roughness=0.2f0
        ),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(20.0, 0.01, 20.0)),
                          offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # ----- Opaque PBR row (deferred path) -----
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(color=RGB{Float32}(0.9, 0.8, 0.5),
                          metallic=1.0f0, roughness=0.05f0),
        transform(position=Vec3d(-3, 1.0, 0)),
    ]),
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(color=RGB{Float32}(0.85, 0.55, 0.4),
                          metallic=1.0f0, roughness=0.35f0),
        transform(position=Vec3d(-1, 1.0, 0)),
    ]),
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(color=RGB{Float32}(0.8, 0.1, 0.1),
                          metallic=0.0f0, roughness=0.4f0),
        transform(position=Vec3d(1, 1.0, 0)),
    ]),
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(color=RGB{Float32}(0.95, 0.95, 0.95),
                          metallic=1.0f0, roughness=0.0f0,
                          clearcoat=1.0f0, clearcoat_roughness=0.03f0),
        transform(position=Vec3d(3, 1.0, 0)),
    ]),

    # ----- Transparent overlay (forward path) -----
    # These exercise the new Vulkan forward transparent pass: depth-tested
    # against the deferred G-Buffer depth, additively blended on top of the
    # composited scene.
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.3, 0.7, 1.0),
                          metallic=0.0f0, roughness=0.05f0,
                          opacity=0.35f0),
        transform(position=Vec3d(-2, 1.0, 2),
                  scale=Vec3d(0.8, 1.6, 0.8))
    ]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(1.0, 0.4, 0.6),
                          metallic=0.0f0, roughness=0.1f0,
                          opacity=0.5f0),
        transform(position=Vec3d(2, 1.0, 2),
                  scale=Vec3d(0.8, 1.6, 0.8))
    ]),
])

@info """
Vulkan Features Showcase
========================
Use this scene to eyeball Vulkan vs OpenGL parity.

Demonstrates:
- Cascaded shadow maps (4 cascades)
- IBL (procedural sky)
- Deferred PBR (opaque row of spheres)
- Forward transparent pass (two coloured glass cubes in front)
- Screen-space reflections off the glossy floor
- SSAO + TAA + bloom + ACES tone mapping + FXAA
- DOF + motion blur

Controls: WASD move, Mouse look, Shift sprint, ESC release cursor
"""

# Default backend on Linux/Windows is now VulkanBackend; pass it explicitly
# to make the test self-documenting.
render(s,
    backend=VulkanBackend(),
    width=1280,
    height=720,
    title="OpenReality — Vulkan Features Showcase",
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=1.0f0,
        bloom_intensity=0.4f0,
        ssao_enabled=true,
        ssao_radius=0.6f0,
        tone_mapping=TONEMAP_ACES,
        fxaa_enabled=true,
        gamma=2.2f0,
        dof_enabled=true,
        dof_focus_distance=10.0f0,
        dof_focus_range=4.0f0,
        dof_bokeh_radius=2.0f0,
        motion_blur_enabled=true,
        motion_blur_intensity=0.6f0,
        vignette_enabled=true,
        vignette_intensity=0.3f0,
    ),
    ui = ctx -> begin
        ui_text(ctx, "Vulkan Features Showcase", x=20, y=20, size=24)
        ui_text(ctx, "Forward transparent pass + SSR + bloom + ACES + FXAA",
                x=20, y=52, size=16)
    end,
)
