# Examples

Annotated code samples demonstrating common patterns in OpenReality.

---

## Basic Scene

A complete scene with FPS controls, lighting, and PBR objects.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    # FPS player at eye height
    create_player(position=Vec3d(0, 1.7, 8)),

    # Sunlight
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=2.0f0
        )
    ]),

    # Warm point light, elevated and offset
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
        transform(position=Vec3d(-2, 0.5, 0)),
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

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), roughness=0.9f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

render(s)
```

---

## PBR Material Variations

Demonstrates how `metallic` and `roughness` affect appearance.

```julia
# Metallic gold, varying roughness (mirror → rough)
for (i, r) in enumerate([0.0f0, 0.3f0, 0.6f0, 1.0f0])
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.8, 0.6),   # Gold
            metallic=1.0f0,
            roughness=r
        ),
        transform(position=Vec3d(-6 + (i-1)*2, 1.5, 0)),
        ColliderComponent(shape=SphereShape(0.8f0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
end

# Dielectric (non-metallic) colored spheres
for (i, (r, g, b)) in enumerate([(0.8,0.2,0.2), (0.2,0.8,0.2), (0.2,0.2,0.8)])
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(r, g, b),
            metallic=0.0f0,
            roughness=0.3f0 + i * 0.2f0
        ),
        transform(position=Vec3d(2 + (i-1)*2, 1.5, 0)),
        ColliderComponent(shape=SphereShape(0.8f0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
end
```

---

## Advanced Materials

### Clear Coat (car paint, lacquer)

```julia
entity([
    sphere_mesh(radius=0.8f0),
    MaterialComponent(
        color=RGB{Float32}(0.8, 0.1, 0.1),       # Deep red base
        metallic=0.9f0,
        roughness=0.4f0,
        clearcoat=1.0f0,                           # Full clear coat
        clearcoat_roughness=0.03f0                  # Very smooth top layer
    ),
    transform(position=Vec3d(0, 1.5, 0))
])
```

### Subsurface Scattering (skin, wax, jade)

```julia
# Skin-like material
entity([
    sphere_mesh(radius=0.8f0),
    MaterialComponent(
        color=RGB{Float32}(0.9, 0.7, 0.5),
        metallic=0.0f0,
        roughness=0.6f0,
        subsurface=0.8f0,
        subsurface_color=Vec3f(1.0f0, 0.2f0, 0.1f0)  # Reddish glow
    ),
    transform(position=Vec3d(-2, 1.5, 0))
])

# Jade-like material
entity([
    sphere_mesh(radius=0.8f0),
    MaterialComponent(
        color=RGB{Float32}(0.3, 0.7, 0.4),
        metallic=0.0f0,
        roughness=0.3f0,
        subsurface=0.6f0,
        subsurface_color=Vec3f(0.1f0, 0.8f0, 0.2f0)  # Green glow
    ),
    transform(position=Vec3d(2, 1.5, 0))
])
```

### Emissive (glowing objects)

```julia
entity([
    cube_mesh(),
    MaterialComponent(
        color=RGB{Float32}(1.0, 1.0, 1.0),
        emissive_factor=Vec3f(5.0f0, 1.5f0, 0.3f0)   # Warm orange glow
    ),
    transform(position=Vec3d(0, 1, 0))
])
```

Emissive values above 1.0 will trigger bloom when `bloom_enabled=true` in the post-process config.

---

## Image-Based Lighting + Cascaded Shadows

For photorealistic outdoor scenes, combine IBL with a directional light for CSM shadows.

```julia
s = scene([
    create_player(position=Vec3d(0, 2.0, 15)),

    # Procedural sky IBL
    entity([
        IBLComponent(
            environment_path="sky",
            intensity=1.0f0,
            enabled=true
        )
    ]),

    # Sun with warm tint (triggers CSM automatically)
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=3.0f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )
    ]),

    # Colored point lights to showcase deferred multi-light rendering
    entity([
        PointLightComponent(color=RGB{Float32}(1.0, 0.3, 0.3), intensity=25.0f0, range=15.0f0),
        transform(position=Vec3d(-8, 3, 0))
    ]),
    entity([
        PointLightComponent(color=RGB{Float32}(0.3, 1.0, 0.3), intensity=25.0f0, range=15.0f0),
        transform(position=Vec3d(8, 3, 0))
    ]),
    entity([
        PointLightComponent(color=RGB{Float32}(0.3, 0.3, 1.0), intensity=25.0f0, range=15.0f0),
        transform(position=Vec3d(0, 3, -8))
    ]),

    # Scene geometry...
    entity([
        plane_mesh(width=100.0f0, depth=100.0f0),
        MaterialComponent(color=RGB{Float32}(0.3, 0.3, 0.3), roughness=0.9f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(50.0, 0.01, 50.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

render(s, post_process=PostProcessConfig(
    bloom_enabled=true,
    bloom_threshold=1.0f0,
    bloom_intensity=0.3f0,
    tone_mapping=TONEMAP_ACES,
    fxaa_enabled=true,
    gamma=2.2f0
))
```

---

## Post-Processing Configurations

### Cinematic (film look)

```julia
PostProcessConfig(
    bloom_enabled=true,
    bloom_threshold=1.0f0,
    bloom_intensity=0.3f0,
    tone_mapping=TONEMAP_ACES,
    fxaa_enabled=true,
    gamma=2.2f0
)
```

### High-Quality (maximum visual fidelity)

```julia
PostProcessConfig(
    bloom_enabled=true,
    bloom_threshold=0.8f0,
    bloom_intensity=0.4f0,
    ssao_enabled=true,
    ssao_radius=0.5f0,
    ssao_samples=16,
    tone_mapping=TONEMAP_ACES,
    fxaa_enabled=true,
    gamma=2.2f0
)
```

### Minimal (best performance)

```julia
PostProcessConfig(
    tone_mapping=TONEMAP_REINHARD,
    gamma=2.2f0
)
```

---

## Loading 3D Models

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

# Load a glTF model — returns Vector{EntityDef}
entities = load_model("assets/helmet.gltf")

s = scene([
    create_player(position=Vec3d(0, 1.7, 3)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),
    entity([IBLComponent(environment_path="sky", intensity=1.0f0)]),
    entities...   # Splat model entities into the scene
])

render(s)
```

Supported formats:
- `.gltf` / `.glb` — glTF 2.0 (meshes, materials, hierarchy, animations)
- `.obj` — Wavefront OBJ (meshes only, optional material override)

---

## Hierarchical Entities

Create parent-child relationships for grouped transforms.

```julia
# A "table" made from a top and four legs
table = entity([
    transform(position=Vec3d(0, 0.75, 0))
], children=[
    # Table top
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.6, 0.4, 0.2), roughness=0.7f0),
        transform(scale=Vec3d(2.0, 0.1, 1.0))
    ]),
    # Legs (positioned relative to parent)
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.5, 0.3, 0.1), roughness=0.8f0),
        transform(position=Vec3d(-0.9, -0.4, -0.4), scale=Vec3d(0.1, 0.7, 0.1))
    ]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.5, 0.3, 0.1), roughness=0.8f0),
        transform(position=Vec3d(0.9, -0.4, -0.4), scale=Vec3d(0.1, 0.7, 0.1))
    ]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.5, 0.3, 0.1), roughness=0.8f0),
        transform(position=Vec3d(-0.9, -0.4, 0.4), scale=Vec3d(0.1, 0.7, 0.1))
    ]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.5, 0.3, 0.1), roughness=0.8f0),
        transform(position=Vec3d(0.9, -0.4, 0.4), scale=Vec3d(0.1, 0.7, 0.1))
    ])
])
```

Child transforms are relative to their parent. Moving the parent moves all children together.

---

## Generating Entities Programmatically

Use Julia's standard array comprehensions and splatting to generate entities:

```julia
# Row of cubes extending into the distance
cubes = [entity([
    cube_mesh(),
    MaterialComponent(
        color=RGB{Float32}(0.6, 0.4, 0.2),
        roughness=0.7f0
    ),
    transform(
        position=Vec3d(0, 0.5, -Float64(i * 5)),
        scale=Vec3d(0.8, 1.0, 0.8)
    ),
    ColliderComponent(shape=AABBShape(Vec3f(0.8, 1.0, 0.8))),
    RigidBodyComponent(body_type=BODY_STATIC)
]) for i in 1:20]

s = scene([
    create_player(position=Vec3d(0, 1.7, 5)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),
    entity([plane_mesh(width=100.0f0, depth=100.0f0), MaterialComponent(roughness=0.9f0), transform()]),
    cubes...   # Splat generated entities
])
```

---

## Using Different Backends

```julia
# OpenGL (default)
render(s)
render(s, backend=OpenGLBackend())

# Vulkan (Linux/Windows)
render(s, backend=VulkanBackend(), title="OpenReality — Vulkan")

# Metal (macOS)
render(s, backend=MetalBackend())

# Custom window size
render(s, width=1920, height=1080, title="Full HD Scene")
```

All three backends support the full feature set: deferred rendering, PBR, CSM, IBL, SSR, SSAO, TAA, and post-processing.

---

## Physics: Stacking Boxes with Friction

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()
reset_physics_world!()

# Helper for dynamic boxes
function dynamic_box(pos; size=Vec3f(0.5, 0.5, 0.5), color=RGB{Float32}(0.8, 0.3, 0.1), mass=1.0)
    entity([
        cube_mesh(),
        MaterialComponent(color=color, metallic=0.2f0, roughness=0.6f0),
        transform(position=pos),
        ColliderComponent(shape=AABBShape(size)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=mass, friction=0.5)
    ])
end

s = scene([
    create_player(position=Vec3d(0, 2, 8)),
    entity([DirectionalLightComponent(direction=Vec3f(0.4, -1.0, -0.3), intensity=2.5f0)]),

    # Ground
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.45, 0.45, 0.45), roughness=0.95f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Tower of boxes — should stay stacked thanks to friction
    dynamic_box(Vec3d(0, 0.5, 0), color=RGB{Float32}(0.9, 0.2, 0.2)),
    dynamic_box(Vec3d(0, 1.5, 0), color=RGB{Float32}(0.8, 0.4, 0.1)),
    dynamic_box(Vec3d(0, 2.5, 0), color=RGB{Float32}(0.7, 0.6, 0.1)),
    dynamic_box(Vec3d(0, 3.5, 0), color=RGB{Float32}(0.5, 0.8, 0.2)),
])

render(s, post_process=PostProcessConfig(tone_mapping=TONEMAP_ACES, fxaa_enabled=true))
```

---

## Physics: Joints and Constraints

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()
reset_physics_world!()

s = scene([
    create_player(position=Vec3d(0, 3, 10)),
    entity([DirectionalLightComponent(direction=Vec3f(0.4, -1.0, -0.3), intensity=2.5f0)]),
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.4, 0.4, 0.4), roughness=0.9f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

# Pendulum: static anchor + dynamic bob connected by ball-socket joint
anchor_id = create_entity_id()
add_component!(anchor_id, transform(position=Vec3d(0, 6, 0)))
add_component!(anchor_id, ColliderComponent(shape=SphereShape(0.1f0)))
add_component!(anchor_id, RigidBodyComponent(body_type=BODY_STATIC))

bob_id = create_entity_id()
add_component!(bob_id, transform(position=Vec3d(0, 4, 0)))
add_component!(bob_id, cube_mesh())
add_component!(bob_id, MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.5)))
add_component!(bob_id, ColliderComponent(shape=SphereShape(0.3f0)))
add_component!(bob_id, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=2.0,
                                          velocity=Vec3d(3.0, 0.0, 0.0)))
add_component!(bob_id, JointComponent(
    BallSocketJoint(anchor_id, bob_id,
                    local_anchor_a=Vec3d(0,0,0),
                    local_anchor_b=Vec3d(0,2,0))
))

add_entity(s, anchor_id)
add_entity(s, bob_id)

render(s)
```

---

## Physics: Trigger Volumes and Raycasting

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()
reset_physics_world!()

# Setup scene...

# Trigger volume: semi-transparent zone that fires callbacks
trigger_id = create_entity_id()
add_component!(trigger_id, transform(position=Vec3d(0, 1, 0)))
add_component!(trigger_id, ColliderComponent(
    shape=AABBShape(Vec3f(2.0, 2.0, 2.0)),
    is_trigger=true
))
add_component!(trigger_id, cube_mesh())
add_component!(trigger_id, MaterialComponent(
    color=RGB{Float32}(0.0, 1.0, 0.3), opacity=0.2f0
))
add_component!(trigger_id, TriggerComponent(
    on_enter = (trigger, other) -> @info("Entity $other ENTERED trigger!"),
    on_exit  = (trigger, other) -> @info("Entity $other EXITED trigger!")
))

# Raycast: find what's below a point
hit = raycast(Vec3d(0, 10, 0), Vec3d(0, -1, 0), max_distance=50.0)
if hit !== nothing
    @info "Raycast hit" entity=hit.entity point=hit.point distance=hit.distance
end
```

---

## Physics: CCD (Fast-Moving Objects)

```julia
# Thin wall
entity([
    cube_mesh(),
    MaterialComponent(color=RGB{Float32}(0.4, 0.4, 0.4)),
    transform(position=Vec3d(8, 1, 0), scale=Vec3d(0.1, 2, 2)),
    ColliderComponent(shape=AABBShape(Vec3f(0.05, 1.0, 1.0))),
    RigidBodyComponent(body_type=BODY_STATIC)
])

# Fast bullet with CCD — won't tunnel through the wall
entity([
    sphere_mesh(radius=0.15f0),
    MaterialComponent(color=RGB{Float32}(1.0, 0.0, 0.0), metallic=0.9f0),
    transform(position=Vec3d(4, 1, 0)),
    ColliderComponent(shape=SphereShape(0.15f0)),
    RigidBodyComponent(body_type=BODY_DYNAMIC, mass=0.5,
                       ccd_mode=CCD_SWEPT,
                       velocity=Vec3d(50.0, 0.0, 0.0))
])
```

---

## 3D Audio

Place spatial audio sources in the scene. Sound attenuates with distance from the listener.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    # Player with audio listener attached
    entity([
        PlayerComponent(),
        transform(position=Vec3d(0, 1.7, 10)),
        AudioListenerComponent(gain=1.0f0),
        ColliderComponent(shape=AABBShape(Vec3f(0.3, 0.9, 0.3))),
        RigidBodyComponent(body_type=BODY_KINEMATIC)
    ], children=[
        entity([CameraComponent(), transform()])
    ]),

    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),

    # Audio source on a visible object — walk toward it to hear it louder
    entity([
        sphere_mesh(radius=0.3f0),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.6, 1.0),
            emissive_factor=Vec3f(0.5, 1.0, 2.0)   # Glowing to mark the source
        ),
        transform(position=Vec3d(0, 1.5, 0)),
        AudioSourceComponent(
            audio_path="sounds/loop.wav",
            playing=true,
            looping=true,
            gain=1.0f0,
            spatial=true,
            reference_distance=2.0f0,
            max_distance=40.0f0
        )
    ]),

    # A second source further away, different sound
    entity([
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(1.0, 0.4, 0.2),
            emissive_factor=Vec3f(2.0, 0.5, 0.1)
        ),
        transform(position=Vec3d(10, 1, -5)),
        AudioSourceComponent(
            audio_path="sounds/alert.wav",
            playing=true,
            looping=true,
            gain=0.8f0,
            spatial=true,
            reference_distance=3.0f0,
            max_distance=30.0f0,
            rolloff_factor=1.5f0
        )
    ]),

    # Floor
    entity([
        plane_mesh(width=40.0f0, depth=40.0f0),
        MaterialComponent(color=RGB{Float32}(0.4, 0.4, 0.4), roughness=0.9f0),
        transform()
    ])
])

render(s, post_process=PostProcessConfig(
    bloom_enabled=true, bloom_threshold=1.0f0,
    tone_mapping=TONEMAP_ACES, fxaa_enabled=true
))
```

Walk around the scene — sound pans left/right and gets louder/quieter based on distance.

---

## UI / HUD Overlay

Add a game-style HUD with health bar, score, and a button.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    create_player(position=Vec3d(0, 1.7, 5)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),

    # Some scene geometry
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.8, 0.3, 0.1), metallic=0.5f0, roughness=0.3f0),
        transform(position=Vec3d(0, 0.5, 0)),
        ColliderComponent(shape=AABBShape(Vec3f(0.5, 0.5, 0.5))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), roughness=0.9f0),
        transform()
    ])
])

score = 0
health = 0.8

render(s, ui = function(ctx)
    # Background panel
    ui_rect(ctx, x=5, y=5, width=260, height=110,
            color=RGB{Float32}(0, 0, 0), alpha=0.4f0)

    # Score display
    ui_text(ctx, "Score: $score", x=15, y=15, size=28,
            color=RGB{Float32}(1.0, 0.9, 0.3))

    # Health bar with label
    ui_text(ctx, "HP", x=15, y=55, size=18,
            color=RGB{Float32}(0.9, 0.9, 0.9))
    ui_progress_bar(ctx, health,
                    x=45, y=53, width=200, height=22,
                    color=RGB{Float32}(0.1, 0.9, 0.2),
                    bg_color=RGB{Float32}(0.4, 0.1, 0.1))

    # Buttons
    if ui_button(ctx, "+10 Score", x=15, y=85, width=110, height=25,
                 color=RGB{Float32}(0.2, 0.5, 0.2),
                 hover_color=RGB{Float32}(0.3, 0.7, 0.3))
        score += 10
    end

    if ui_button(ctx, "Heal", x=135, y=85, width=110, height=25,
                 color=RGB{Float32}(0.2, 0.2, 0.6),
                 hover_color=RGB{Float32}(0.3, 0.3, 0.8))
        health = min(1.0, health + 0.1)
    end
end)
```

The UI callback runs every frame. All positioning is in screen pixels from the top-left corner.

---

## Particle Effects

Combine multiple particle systems for varied visual effects.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    create_player(position=Vec3d(0, 2, 10)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=1.5f0)]),

    # Fire particles (additive blending for bright glow)
    entity([
        transform(position=Vec3d(0, 0.2, 0)),
        ParticleSystemComponent(
            max_particles=512,
            emission_rate=80.0f0,
            lifetime_min=0.3f0,
            lifetime_max=1.0f0,
            velocity_min=Vec3f(-0.4, 2.0, -0.4),
            velocity_max=Vec3f(0.4, 5.0, 0.4),
            gravity_modifier=0.2f0,
            start_size_min=0.08f0,
            start_size_max=0.15f0,
            end_size=0.0f0,
            start_color=RGB{Float32}(1.0, 0.9, 0.3),
            end_color=RGB{Float32}(1.0, 0.1, 0.0),
            start_alpha=1.0f0,
            end_alpha=0.0f0,
            additive=true
        )
    ]),

    # Smoke rising above the fire (alpha blending, slower, larger)
    entity([
        transform(position=Vec3d(0, 1.5, 0)),
        ParticleSystemComponent(
            max_particles=64,
            emission_rate=5.0f0,
            lifetime_min=3.0f0,
            lifetime_max=5.0f0,
            velocity_min=Vec3f(-0.3, 0.3, -0.3),
            velocity_max=Vec3f(0.3, 1.0, 0.3),
            gravity_modifier=-0.05f0,
            damping=0.3f0,
            start_size_min=0.3f0,
            start_size_max=0.5f0,
            end_size=2.0f0,
            start_color=RGB{Float32}(0.4, 0.4, 0.4),
            end_color=RGB{Float32}(0.2, 0.2, 0.2),
            start_alpha=0.5f0,
            end_alpha=0.0f0,
            additive=false
        )
    ]),

    # Spark burst (one-shot, then done)
    entity([
        transform(position=Vec3d(-4, 1, 0)),
        ParticleSystemComponent(
            max_particles=100,
            emission_rate=0.0f0,
            burst_count=100,
            lifetime_min=0.5f0,
            lifetime_max=1.5f0,
            velocity_min=Vec3f(-3, 1, -3),
            velocity_max=Vec3f(3, 6, 3),
            gravity_modifier=1.0f0,
            start_size_min=0.03f0,
            start_size_max=0.06f0,
            end_size=0.0f0,
            start_color=RGB{Float32}(1.0, 0.8, 0.3),
            end_color=RGB{Float32}(1.0, 0.3, 0.0),
            start_alpha=1.0f0,
            end_alpha=0.0f0,
            additive=true
        )
    ]),

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.3, 0.3, 0.3), roughness=0.95f0),
        transform()
    ])
])

render(s, post_process=PostProcessConfig(
    bloom_enabled=true, bloom_threshold=0.8f0, bloom_intensity=0.5f0,
    tone_mapping=TONEMAP_ACES, fxaa_enabled=true
))
```

Tips:
- Use `additive=true` for bright effects (fire, sparks, magic).
- Use `additive=false` for opaque effects (smoke, dust, snow).
- `burst_count` fires once; `emission_rate` emits continuously.
- Negative `gravity_modifier` makes particles float upward.

---

## Skeletal Animation

Load and display a skinned, animated character from a glTF file.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

# Load a glTF model with skeleton and animations
# The loader extracts: meshes, bone hierarchy, skin data, animation clips
model = load_model("assets/character.glb")

s = scene([
    create_player(position=Vec3d(0, 1.7, 5)),

    entity([
        DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.5f0)
    ]),
    entity([
        IBLComponent(environment_path="sky", intensity=0.8f0)
    ]),

    # Splat the model entities — includes skinned mesh, bones, and animations
    model...,

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.45, 0.45, 0.45), roughness=0.9f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

render(s, post_process=PostProcessConfig(
    tone_mapping=TONEMAP_ACES, fxaa_enabled=true
))
```

What the loader creates:
- A hierarchy of bone entities with `BoneComponent` (inverse bind matrices)
- A mesh entity with `MeshComponent` (includes `bone_weights` and `bone_indices`), `SkinnedMeshComponent` (links to bone entities), and `MaterialComponent`
- An `AnimationComponent` with clips that drive bone transforms

The engine automatically calls `update_animations!(dt)` and `update_skinned_meshes!()` each frame.

---

## Terrain

Generate procedural terrain with Perlin noise and splatmap texturing.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    create_player(position=Vec3d(128, 30, 128)),

    entity([
        DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.5f0)
    ]),
    entity([
        IBLComponent(environment_path="sky", intensity=0.6f0)
    ]),

    # Procedural terrain
    entity([
        TerrainComponent(
            heightmap=HeightmapSource(
                source_type=HEIGHTMAP_PERLIN,
                perlin_octaves=6,
                perlin_frequency=0.008f0,
                perlin_persistence=0.5f0,
                perlin_seed=123
            ),
            terrain_size=Vec2f(256.0, 256.0),
            max_height=40.0f0,
            chunk_size=33,
            num_lod_levels=3,
            splatmap_path="textures/splatmap.png",
            layers=[
                TerrainLayer(
                    albedo_path="textures/grass_albedo.png",
                    normal_path="textures/grass_normal.png",
                    uv_scale=15.0f0
                ),
                TerrainLayer(
                    albedo_path="textures/rock_albedo.png",
                    normal_path="textures/rock_normal.png",
                    uv_scale=8.0f0
                ),
                TerrainLayer(
                    albedo_path="textures/sand_albedo.png",
                    normal_path="textures/sand_normal.png",
                    uv_scale=20.0f0
                )
            ]
        ),
        transform()
    ])
])

render(s, post_process=PostProcessConfig(
    bloom_enabled=true, bloom_threshold=1.5f0,
    ssao_enabled=true, ssao_radius=0.5f0,
    tone_mapping=TONEMAP_ACES, fxaa_enabled=true
))
```

Key concepts:
- **Heightmap sources**: `HEIGHTMAP_PERLIN` (procedural), `HEIGHTMAP_IMAGE` (from file), `HEIGHTMAP_FLAT`
- **Chunks**: The terrain is split into chunks for frustum culling and LOD selection
- **Splatmap**: An RGBA texture where each channel controls the blend weight of a terrain layer (up to 4 layers)
- **`uv_scale`**: Controls texture tiling frequency per layer

---

## ScriptComponent

```julia
# Entities with custom behavior
entity([
    cube_mesh(),
    MaterialComponent(color=RGB{Float32}(0.8, 0.2, 0.2)),
    transform(),
    ScriptComponent(
        on_start = (eid, ctx) -> println("Started!"),
        on_update = (eid, dt, ctx) -> begin
            t = get_component(eid, TransformComponent)
            t !== nothing && (t.position[] += Vec3d(0, sin(dt) * 0.01, 0))
        end,
        on_destroy = (eid, ctx) -> println("Destroyed!")
    )
])
```

---

## Game State Machine

```julia
mutable struct GameplayState <: GameState
    score::Int
end
GameplayState() = GameplayState(0)

function on_update!(state::GameplayState, sc::Scene, dt::Float64, ctx::GameContext)
    # Spawn entities dynamically
    spawn!(ctx, entity([
        sphere_mesh(),
        MaterialComponent(color=RGB{Float32}(rand(), rand(), rand())),
        transform(position=Vec3d(randn()*5, 10, randn()*5)),
        ColliderComponent(shape=SphereShape(0.5f0)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0)
    ]))
    return nothing
end

function get_ui_callback(state::GameplayState)
    return ctx -> ui_text(ctx, 10, 10, "Score: $(state.score)", size=24)
end
```

---

## Prefab System

```julia
# Define a reusable entity template
coin_prefab = Prefab() do (; position=Vec3d(0,0,0), color=RGB{Float32}(1,0.8,0))
    entity([
        sphere_mesh(),
        MaterialComponent(color=color, metallic=0.9f0, roughness=0.1f0),
        transform(position=position),
        ColliderComponent(shape=SphereShape(0.3f0), is_trigger=true)
    ])
end

# Instantiate multiple coins
spawn!(ctx, coin_prefab, position=Vec3d(5, 1, 0))
spawn!(ctx, coin_prefab, position=Vec3d(10, 1, 0))
```

---

## Event Bus

```julia
# Define a custom event
struct CoinCollected <: GameEvent
    entity_id::EntityID
    value::Int
end

# Subscribe to events
subscribe!(CoinCollected) do event
    println("Collected coin worth $(event.value)!")
end

# Emit from game logic
emit!(CoinCollected(some_entity_id, 10))
```

---

## Animation Blend Trees

```julia
# Create a 1D blend tree for walk/run animation
tree = AnimationBlendTreeComponent(
    Blend1DNode("speed", Float32[0, 0.5, 1.0], [
        ClipNode(idle_clip),
        ClipNode(walk_clip),
        ClipNode(run_clip)
    ]),
    Dict{String, Float32}("speed" => 0.0f0),
    Dict{String, Bool}(),
    Set{String}(),
    0.0, false, 0.3f0, 0.0f0, nothing
)

# Update the blend parameter at runtime
tree.parameters["speed"] = 0.7f0  # blends between walk and run
```
