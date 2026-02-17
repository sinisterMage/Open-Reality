#!/usr/bin/env julia
# WebGPU Features Test
# Run: julia --project=. examples/webgpu_features_test.jl
#
# Comprehensive test of the WebGPU backend exercising all render passes:
# - Deferred PBR (G-Buffer + lighting)
# - Cascaded shadow maps
# - SSAO, SSR, TAA
# - Bloom, tone mapping, FXAA
# - Forward pass (transparent objects)
# - Particle rendering (fire + sparks)
# - UI overlay (text, rectangles, progress bar)
# - Physics (falling cubes)
#
# Prerequisites:
#   cd openreality-wgpu && cargo build --release

using OpenReality

reset_entity_counter!()
reset_component_stores!()

# ============================================================================
# Scene
# ============================================================================

s = scene([
    # FPS Player
    create_player(position=Vec3d(0, 2.0, 14)),

    # ====== Lighting ======

    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.4, -1.0, -0.3),
            intensity=3.0f0,
            color=RGB{Float32}(1.0, 0.95, 0.85)
        )
    ]),

    entity([
        PointLightComponent(color=RGB{Float32}(1.0, 0.6, 0.3), intensity=20.0f0, range=18.0f0),
        transform(position=Vec3d(-5, 4, 3))
    ]),

    entity([
        PointLightComponent(color=RGB{Float32}(0.3, 0.5, 1.0), intensity=20.0f0, range=18.0f0),
        transform(position=Vec3d(5, 4, 3))
    ]),

    # ====== Ground ======

    entity([
        plane_mesh(width=30.0f0, depth=30.0f0),
        MaterialComponent(color=RGB{Float32}(0.3, 0.35, 0.3), metallic=0.0f0, roughness=0.9f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(15.0, 0.01, 15.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # ====== PBR Objects ======

    # Gold sphere
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(color=RGB{Float32}(1.0, 0.84, 0.0), metallic=1.0f0, roughness=0.05f0),
        transform(position=Vec3d(-4, 0.8, 0))
    ]),

    # Silver cube with clearcoat
    entity([
        cube_mesh(size=1.2f0),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.9, 0.92),
            metallic=1.0f0,
            roughness=0.1f0,
            clearcoat=0.8f0,
            clearcoat_roughness=0.05f0
        ),
        transform(position=Vec3d(-1.5, 0.6, 0))
    ]),

    # Emissive sphere (bloom test)
    entity([
        sphere_mesh(radius=0.5f0),
        MaterialComponent(
            color=RGB{Float32}(0.05, 0.05, 0.15),
            metallic=0.0f0,
            roughness=0.5f0,
            emissive_factor=Vec3f(1.0f0, 2.0f0, 5.0f0)
        ),
        transform(position=Vec3d(1.5, 0.5, 0))
    ]),

    # Rough red pedestal
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.6, 0.15, 0.1), metallic=0.0f0, roughness=0.8f0),
        transform(position=Vec3d(4, 0.3, 0), scale=Vec3d(1.5, 0.6, 1.5))
    ]),

    # ====== Transparent objects (forward pass) ======

    entity([
        sphere_mesh(radius=0.7f0),
        MaterialComponent(
            color=RGB{Float32}(0.3, 0.6, 1.0),
            metallic=0.0f0,
            roughness=0.15f0,
            opacity=0.35f0
        ),
        transform(position=Vec3d(-3, 0.7, 4))
    ]),

    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.3, 0.1),
            metallic=0.0f0,
            roughness=0.3f0,
            opacity=0.5f0
        ),
        transform(position=Vec3d(0, 0.5, 4))
    ]),

    # ====== Particle systems ======

    # Fire
    entity([
        transform(position=Vec3d(4, 0.6, 0)),
        ParticleSystemComponent(
            max_particles=250,
            emission_rate=70.0f0,
            lifetime_min=0.3f0,
            lifetime_max=1.0f0,
            velocity_min=Vec3f(-0.3f0, 1.5f0, -0.3f0),
            velocity_max=Vec3f(0.3f0, 3.0f0, 0.3f0),
            gravity_modifier=0.0f0,
            damping=0.3f0,
            start_size_min=0.12f0,
            start_size_max=0.3f0,
            end_size=0.04f0,
            start_color=RGB{Float32}(1.0, 0.6, 0.1),
            end_color=RGB{Float32}(1.0, 0.1, 0.0),
            start_alpha=0.9f0,
            end_alpha=0.0f0,
            additive=true
        )
    ]),

    # Sparks
    entity([
        transform(position=Vec3d(-6, 3.0, -3)),
        ParticleSystemComponent(
            max_particles=150,
            emission_rate=30.0f0,
            burst_count=20,
            lifetime_min=0.5f0,
            lifetime_max=2.0f0,
            velocity_min=Vec3f(-2.0f0, -1.0f0, -2.0f0),
            velocity_max=Vec3f(2.0f0, 4.0f0, 2.0f0),
            gravity_modifier=1.0f0,
            damping=0.05f0,
            start_size_min=0.03f0,
            start_size_max=0.07f0,
            end_size=0.01f0,
            start_color=RGB{Float32}(1.0, 0.9, 0.5),
            end_color=RGB{Float32}(1.0, 0.3, 0.0),
            start_alpha=1.0f0,
            end_alpha=0.0f0,
            additive=true
        )
    ]),

    # ====== Dynamic physics cubes ======

    entity([
        cube_mesh(size=0.6f0),
        MaterialComponent(color=RGB{Float32}(0.9, 0.5, 0.2), metallic=0.4f0, roughness=0.4f0),
        transform(position=Vec3d(-1, 8, -2)),
        ColliderComponent(shape=AABBShape(Vec3f(0.3, 0.3, 0.3))),
        RigidBodyComponent(body_type=BODY_DYNAMIC)
    ]),

    entity([
        cube_mesh(size=0.6f0),
        MaterialComponent(color=RGB{Float32}(0.2, 0.5, 0.9), metallic=0.4f0, roughness=0.4f0),
        transform(position=Vec3d(0.5, 10, -2)),
        ColliderComponent(shape=AABBShape(Vec3f(0.3, 0.3, 0.3))),
        RigidBodyComponent(body_type=BODY_DYNAMIC)
    ]),

    entity([
        cube_mesh(size=0.6f0),
        MaterialComponent(color=RGB{Float32}(0.7, 0.2, 0.8), metallic=0.4f0, roughness=0.4f0),
        transform(position=Vec3d(1, 12, -2)),
        ColliderComponent(shape=AABBShape(Vec3f(0.3, 0.3, 0.3))),
        RigidBodyComponent(body_type=BODY_DYNAMIC)
    ]),

    # ====== Shadow-casting columns ======

    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), metallic=0.1f0, roughness=0.6f0),
        transform(position=Vec3d(-7, 2.0, -5), scale=Vec3d(0.5, 4.0, 0.5))
    ]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), metallic=0.1f0, roughness=0.6f0),
        transform(position=Vec3d(7, 2.0, -5), scale=Vec3d(0.5, 4.0, 0.5))
    ]),
])

# ============================================================================
# UI Overlay
# ============================================================================

frame_count = Ref(0)

ui_callback = function(ctx::UIContext)
    frame_count[] += 1

    # Title bar
    ui_rect(ctx, x=0, y=0, width=ctx.width, height=45,
            color=RGB{Float32}(0.0, 0.0, 0.0), alpha=0.6f0)
    ui_text(ctx, "OpenReality — WebGPU Features Test", x=15, y=10, size=26,
            color=RGB{Float32}(1.0, 1.0, 1.0))

    # Feature checklist panel
    panel_x = 10
    panel_y = ctx.height - 220
    panel_w = 260
    panel_h = 210

    ui_rect(ctx, x=panel_x, y=panel_y, width=panel_w, height=panel_h,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.75f0)

    ui_text(ctx, "Render Passes", x=panel_x+10, y=panel_y+8, size=20,
            color=RGB{Float32}(0.9, 0.9, 0.2))

    passes = [
        "G-Buffer + Deferred PBR",
        "Cascaded Shadow Maps",
        "SSAO + SSR + TAA",
        "Bloom + Tone Mapping",
        "FXAA",
        "Forward Transparency",
        "Particles",
        "UI Overlay",
    ]
    for (i, name) in enumerate(passes)
        ui_text(ctx, "* $name", x=panel_x+15, y=panel_y+25+i*21, size=16,
                color=RGB{Float32}(0.4, 0.9, 0.4))
    end

    # Particle stats
    total_particles = sum(pool.alive_count for (_, pool) in PARTICLE_POOLS; init=0)
    stats_w = 200
    ui_rect(ctx, x=ctx.width-stats_w-10, y=55, width=stats_w, height=55,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.75f0)
    ui_text(ctx, "Particles: $total_particles", x=ctx.width-stats_w, y=60, size=18,
            color=RGB{Float32}(1.0, 0.8, 0.3))
    ui_text(ctx, "Frame: $(frame_count[])", x=ctx.width-stats_w, y=82, size=16,
            color=RGB{Float32}(0.7, 0.7, 0.7))

    # Animated progress bar
    progress = Float32((sin(frame_count[] * 0.02) + 1.0) / 2.0)
    ui_progress_bar(ctx, progress, x=ctx.width-310, y=ctx.height-35, width=300, height=22,
                    color=RGB{Float32}(0.2, 0.7, 0.9))

    # Controls hint
    ui_text(ctx, "WASD: Move | Mouse: Look | Shift: Sprint | Esc: Release cursor",
            x=ctx.width-520, y=ctx.height-12, size=13,
            color=RGB{Float32}(0.5, 0.5, 0.5))
end

# ============================================================================
# Render
# ============================================================================

@info """
WebGPU Features Test
=====================
Tests ALL WebGPU render passes in a single scene:

  Deferred:     G-Buffer geometry + PBR lighting + IBL
  Shadows:      4-cascade CSM
  Effects:      SSAO, SSR, TAA
  Post-Process: Bloom + ACES tone mapping + FXAA
  Forward:      2 transparent objects (blue sphere, red cube)
  Particles:    Fire emitter + spark emitter
  UI:           Text, panels, stats, progress bar
  Physics:      3 falling dynamic cubes

Controls: WASD move, Mouse look, Shift sprint, ESC release cursor

Scene: $(entity_count(s)) entities
"""

render(s,
    backend=WebGPUBackend(),
    width=1280,
    height=720,
    title="OpenReality — WebGPU Features Test",
    ui=ui_callback,
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
