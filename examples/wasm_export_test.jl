#!/usr/bin/env julia
# WASM Export Pipeline Test
# Run: julia --project=. examples/wasm_export_test.jl
#
# Creates a test scene with various entities and exports it to ORSB format
# for loading in the browser WASM runtime.
#
# After running this, the .orsb file will be placed in openreality-web/
# alongside index.html, ready for browser testing.

using OpenReality

reset_entity_counter!()
reset_component_stores!()

println("═══════════════════════════════════════════")
println("  OpenReality — WASM Export Pipeline Test")
println("═══════════════════════════════════════════")
println()

# ── 1. Build the scene ──
println("[1/3] Building test scene...")

s = scene([
    # Camera
    entity([
        CameraComponent(fov=60.0f0, aspect=16.0f0/9.0f0),
        transform(position=Vec3d(0, 3, 8))
    ]),

    # Directional light (sun)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=2.0f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )
    ]),

    # Point light
    entity([
        PointLightComponent(
            color=RGB{Float32}(1.0, 0.8, 0.6),
            intensity=40.0f0,
            range=25.0f0
        ),
        transform(position=Vec3d(3, 5, 2))
    ]),

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

    # Blue rough sphere
    entity([
        sphere_mesh(radius=0.6f0),
        MaterialComponent(
            color=RGB{Float32}(0.1, 0.3, 0.9),
            metallic=0.0f0,
            roughness=0.8f0
        ),
        transform(position=Vec3d(2, 0.6, 0)),
        ColliderComponent(shape=SphereShape(0.6f0)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0)
    ]),

    # Green emissive cube with child
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.8, 0.2),
            metallic=0.3f0,
            roughness=0.4f0,
            emissive_factor=Vec3f(0.5f0, 2.0f0, 0.5f0)
        ),
        transform(position=Vec3d(0, 1.0, -2))
    ], children=[
        entity([
            cube_mesh(size=0.3f0),
            MaterialComponent(color=RGB{Float32}(1.0, 1.0, 0.0)),
            transform(position=Vec3d(0, 1.0, 0))
        ])
    ]),

    # Gray floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(
            color=RGB{Float32}(0.5, 0.5, 0.5),
            metallic=0.0f0,
            roughness=0.9f0
        ),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

num_ents = length(s.entities)
println("  ✓ Scene created with $num_ents entities")

# ── 2. Export to ORSB ──
orsb_path = joinpath(@__DIR__, "..", "openreality-web", "scene.orsb")
println("[2/3] Exporting to ORSB: $orsb_path")

export_scene(s, orsb_path)

file_size = filesize(orsb_path)
println("  ✓ Exported: $(round(file_size / 1024, digits=1)) KB")

# ── 3. Verify the binary ──
println("[3/3] Verifying ORSB binary...")

data = read(orsb_path)
# Check magic
@assert data[1:4] == UInt8['O', 'R', 'S', 'B'] "Bad magic"
# Check version
version = reinterpret(UInt32, data[5:8])[1]
@assert version == 1 "Bad version: $version"
# Read counts from header
n_entities = reinterpret(UInt32, data[13:16])[1]
n_meshes = reinterpret(UInt32, data[17:20])[1]
n_textures = reinterpret(UInt32, data[21:24])[1]
n_materials = reinterpret(UInt32, data[25:28])[1]

println("  ✓ Magic: ORSB, Version: $version")
println("  ✓ Entities: $n_entities, Meshes: $n_meshes, Textures: $n_textures, Materials: $n_materials")
println()
println("═══════════════════════════════════════════")
println("  Export successful!")
println()
println("  To test in browser:")
println("    cd openreality-web && python3 -m http.server 8080")
println("    Then open: http://localhost:8080")
println("═══════════════════════════════════════════")
