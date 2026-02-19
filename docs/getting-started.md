# Getting Started with OpenReality

This guide walks you through installing OpenReality and building your first 3D scene.

## Prerequisites

### Julia

OpenReality requires **Julia 1.9** or later. Download it from [julialang.org](https://julialang.org/downloads/).

### System Dependencies

**GLFW** (required for windowing and input):

| OS | Command |
|----|---------|
| Ubuntu / Debian | `sudo apt install libglfw3 libglfw3-dev` |
| Arch Linux | `sudo pacman -S glfw-x11` (or `glfw-wayland`) |
| Fedora | `sudo dnf install glfw glfw-devel` |
| macOS | `brew install glfw` |
| Windows | Download from [glfw.org](https://www.glfw.org/download.html) |

**Vulkan SDK** (optional, only needed for the Vulkan backend):

Download from [lunarg.com](https://vulkan.lunarg.com/sdk/home). On Linux you can also install via your package manager (e.g. `sudo apt install vulkan-tools libvulkan-dev`).

## Installation

Clone the repository and install it as a development package:

```julia
using Pkg
Pkg.develop(path="/path/to/OpenReality")
```

Then load it:

```julia
using OpenReality
```

The first load will precompile all dependencies. This may take a minute.

---

## Tutorial 1: Your First Scene

Let's create a minimal scene with a floor, a light, and a camera you can fly around with.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    # FPS camera — gives you WASD + mouse look controls
    create_player(position=Vec3d(0, 1.7, 5)),

    # Sun light
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=2.0f0
        )
    ]),

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.4, 0.4, 0.4), roughness=0.9f0),
        transform()
    ])
])

render(s)
```

Save this as `my_scene.jl` and run it with `julia my_scene.jl`. A window opens with a gray floor lit by sunlight. Use the controls below to look around.

### Controls

| Key | Action |
|-----|--------|
| W / A / S / D | Move forward / left / back / right |
| Mouse | Look around |
| Shift | Sprint (2x speed) |
| Space | Move up |
| Ctrl | Move down |
| Escape | Release / capture cursor |

---

## Tutorial 2: Adding Objects

Add some geometry to the scene. OpenReality provides three built-in primitives: `cube_mesh()`, `sphere_mesh()`, and `plane_mesh()`.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    create_player(position=Vec3d(0, 1.7, 8)),

    # Sun
    entity([
        DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)
    ]),

    # Warm point light
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

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), roughness=0.9f0),
        transform()
    ])
])

render(s)
```

Each entity is a list of components. The `MaterialComponent` uses a PBR metallic/roughness workflow:

- **metallic** `0.0` = dielectric (plastic, wood, stone) / `1.0` = metal (gold, chrome)
- **roughness** `0.0` = mirror-smooth / `1.0` = completely rough

---

## Tutorial 3: Physics

Add colliders and rigid bodies to make objects interact physically.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    create_player(position=Vec3d(0, 1.7, 8)),

    entity([
        DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)
    ]),

    # A ball that falls under gravity
    entity([
        sphere_mesh(radius=0.5f0),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.3, 0.1),
            metallic=0.0f0,
            roughness=0.5f0
        ),
        transform(position=Vec3d(0, 5, 0)),
        ColliderComponent(shape=SphereShape(0.5f0)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0, restitution=0.6f0)
    ]),

    # Static floor (won't move, but will stop falling objects)
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

Key concepts:
- **`BODY_STATIC`**: Never moves. Use for floors, walls, and terrain.
- **`BODY_KINEMATIC`**: Moved by code (e.g. the player controller), not by forces.
- **`BODY_DYNAMIC`**: Affected by gravity and collisions.
- **`restitution`**: Bounciness. `0.0` = no bounce, `1.0` = perfectly elastic.
- **`friction`**: How much objects resist sliding. Default `0.5`.
- **`ColliderComponent`** defines the collision shape. Available shapes:
  - `AABBShape(half_extents)` — axis-aligned box
  - `SphereShape(radius)` — sphere
  - `CapsuleShape(; radius, half_height, axis)` — cylinder + hemisphere caps
  - `OBBShape(half_extents)` — oriented box (uses entity rotation)
  - `ConvexHullShape(vertices)` — arbitrary convex shape
  - `CompoundShape(children)` — multi-shape collider

### Advanced Physics Features

The physics engine also supports:

**Joints** — connect two entities with constraints:
```julia
# Ball-socket joint (pendulum)
add_component!(bob_id, JointComponent(
    BallSocketJoint(anchor_id, bob_id,
                    local_anchor_a=Vec3d(0,0,0),
                    local_anchor_b=Vec3d(0,2,0))
))

# Distance joint (rope)
add_component!(entity_b, JointComponent(
    DistanceJoint(entity_a, entity_b, target_distance=2.0)
))
```

**Trigger volumes** — detect when entities enter/exit a region:
```julia
ColliderComponent(shape=AABBShape(Vec3f(2,2,2)), is_trigger=true)
TriggerComponent(
    on_enter = (trigger, other) -> @info("$other entered!"),
    on_exit  = (trigger, other) -> @info("$other exited!")
)
```

**Raycasting** — cast rays to find what's at a location:
```julia
hit = raycast(Vec3d(0, 10, 0), Vec3d(0, -1, 0), max_distance=50.0)
if hit !== nothing
    @info "Hit entity $(hit.entity) at $(hit.point)"
end
```

**CCD** — prevent fast objects from tunneling through walls:
```julia
RigidBodyComponent(body_type=BODY_DYNAMIC, mass=0.5,
                   ccd_mode=CCD_SWEPT,
                   velocity=Vec3d(50, 0, 0))
```

See `examples/physics_demo.jl` for a comprehensive showcase of all physics features.

---

## Tutorial 4: Post-Processing

Enable bloom, tone mapping, and anti-aliasing by passing a `PostProcessConfig` to `render()`.

```julia
render(s, post_process=PostProcessConfig(
    bloom_enabled=true,
    bloom_threshold=1.0f0,
    bloom_intensity=0.3f0,
    tone_mapping=TONEMAP_ACES,
    fxaa_enabled=true,
    gamma=2.2f0
))
```

Available tone mapping modes:
- `TONEMAP_REINHARD` — classic, preserves color
- `TONEMAP_ACES` — filmic, cinematic look (recommended)
- `TONEMAP_UNCHARTED2` — similar to the game's tone curve

You can also enable **SSAO** (Screen-Space Ambient Occlusion) for subtle contact shadows:

```julia
render(s, post_process=PostProcessConfig(
    ssao_enabled=true,
    ssao_radius=0.5f0,
    ssao_samples=16,
    tone_mapping=TONEMAP_ACES
))
```

---

## Tutorial 5: Switching Backends

OpenReality supports three rendering backends. Pass the backend you want to `render()`:

```julia
# OpenGL (default, works everywhere)
render(s, backend=OpenGLBackend())

# Vulkan (Linux / Windows)
render(s, backend=VulkanBackend())

# Metal (macOS)
render(s, backend=MetalBackend())
```

All backends support the same features: deferred rendering, PBR, cascaded shadow maps, IBL, SSR, SSAO, TAA, and post-processing.

---

## Tutorial 6: Loading 3D Models

Import glTF 2.0 (`.gltf` / `.glb`) or Wavefront OBJ (`.obj`) models:

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

# load_model returns a Vector{EntityDef}
model_entities = load_model("path/to/model.gltf")

s = scene([
    create_player(position=Vec3d(0, 1.7, 5)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),
    model_entities...
])

render(s)
```

The loader automatically extracts meshes, materials, transforms, and animations from the file.

---

## Tutorial 7: Advanced Materials

OpenReality's PBR material system supports several advanced effects:

```julia
# Car paint with clear coat
MaterialComponent(
    color=RGB{Float32}(0.8, 0.1, 0.1),
    metallic=0.9f0,
    roughness=0.4f0,
    clearcoat=1.0f0,
    clearcoat_roughness=0.03f0
)

# Subsurface scattering (skin, wax, jade)
MaterialComponent(
    color=RGB{Float32}(0.9, 0.7, 0.5),
    metallic=0.0f0,
    roughness=0.6f0,
    subsurface=0.8f0,
    subsurface_color=Vec3f(1.0f0, 0.2f0, 0.1f0)
)

# Emissive (glowing objects — works great with bloom)
MaterialComponent(
    color=RGB{Float32}(1.0, 1.0, 1.0),
    emissive_factor=Vec3f(5.0f0, 1.5f0, 0.3f0)
)

# Textured material
MaterialComponent(
    albedo_map=TextureRef("textures/albedo.png"),
    normal_map=TextureRef("textures/normal.png"),
    metallic_roughness_map=TextureRef("textures/mr.png"),
    ao_map=TextureRef("textures/ao.png")
)
```

---

## Tutorial 8: Audio

Add 3D positional audio to your scene. You need an `AudioListenerComponent` (the "ears") and one or more `AudioSourceComponent` entities.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    # Player with audio listener — sound is heard from this entity's position
    entity([
        PlayerComponent(),
        transform(position=Vec3d(0, 1.7, 5)),
        AudioListenerComponent(gain=1.0f0),
        ColliderComponent(shape=AABBShape(Vec3f(0.3, 0.9, 0.3))),
        RigidBodyComponent(body_type=BODY_KINEMATIC)
    ], children=[
        entity([CameraComponent(), transform()])
    ]),

    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),

    # A looping sound source — gets louder as you walk toward it
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.2, 0.8, 0.9), metallic=0.5f0, roughness=0.3f0),
        transform(position=Vec3d(0, 1, 0)),
        AudioSourceComponent(
            audio_path="sounds/ambient.wav",
            playing=true,
            looping=true,
            gain=1.0f0,
            spatial=true,
            reference_distance=2.0f0,
            max_distance=50.0f0,
            rolloff_factor=1.0f0
        )
    ]),

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), roughness=0.9f0),
        transform()
    ])
])

render(s)
```

Key concepts:
- **`spatial=true`**: Sound attenuates with distance (3D positional audio).
- **`spatial=false`**: Sound plays at constant volume regardless of position (e.g. background music).
- **`reference_distance`**: Distance at which gain is 1.0 (no attenuation). Closer than this, sound is at full volume.
- **`max_distance`**: Beyond this distance, no further attenuation occurs.
- **`rolloff_factor`**: How quickly sound fades. Higher values = faster falloff.
- Audio files must be `.wav` format (mono or stereo, 8-bit or 16-bit PCM).

---

## Tutorial 9: UI / HUD

Overlay 2D elements on top of the 3D scene by passing a `ui` callback to `render()`.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    create_player(position=Vec3d(0, 1.7, 5)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.1), metallic=0.5f0, roughness=0.3f0),
        transform(position=Vec3d(0, 0.5, 0))
    ]),
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.5, 0.5, 0.5), roughness=0.9f0),
        transform()
    ])
])

health = 0.75

render(s, ui = function(ctx)
    # Title text (top-left corner)
    ui_text(ctx, "My Game", x=10, y=10, size=32,
            color=RGB{Float32}(1, 1, 1))

    # Health bar
    ui_text(ctx, "HP", x=10, y=60, size=18,
            color=RGB{Float32}(0.8, 0.8, 0.8))
    ui_progress_bar(ctx, health,
                    x=40, y=58, width=200, height=20,
                    color=RGB{Float32}(0.2, 0.8, 0.2),
                    bg_color=RGB{Float32}(0.3, 0.1, 0.1))

    # A clickable button
    if ui_button(ctx, "Reset", x=10, y=100, width=100, height=30,
                 color=RGB{Float32}(0.3, 0.3, 0.6),
                 hover_color=RGB{Float32}(0.4, 0.4, 0.8))
        health = 1.0
    end

    # Semi-transparent background panel
    ui_rect(ctx, x=10, y=150, width=220, height=40,
            color=RGB{Float32}(0, 0, 0), alpha=0.5f0)
    ui_text(ctx, "Score: 1250", x=20, y=160, size=24,
            color=RGB{Float32}(1, 0.9, 0.3))
end)
```

Key concepts:
- The `ui` callback is called **every frame**. It's immediate-mode — you rebuild the UI each frame.
- Coordinates are in screen pixels, with `(0, 0)` at the top-left.
- `ui_button` returns `true` on the frame it is clicked.
- Use `ui_rect` with low `alpha` for background panels.
- Text rendering uses a FreeType font atlas, generated on demand.

---

## Tutorial 10: Particle Systems

Add particle effects to entities. Particles are CPU-simulated and rendered as camera-facing billboards.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

s = scene([
    create_player(position=Vec3d(0, 1.7, 8)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),

    # Fire-like particle fountain
    entity([
        transform(position=Vec3d(0, 0.5, 0)),
        ParticleSystemComponent(
            max_particles=512,
            emission_rate=60.0f0,
            lifetime_min=0.5f0,
            lifetime_max=1.5f0,
            velocity_min=Vec3f(-0.3, 2.0, -0.3),
            velocity_max=Vec3f(0.3, 4.0, 0.3),
            gravity_modifier=0.3f0,
            start_size_min=0.1f0,
            start_size_max=0.2f0,
            end_size=0.0f0,
            start_color=RGB{Float32}(1.0, 0.8, 0.2),
            end_color=RGB{Float32}(1.0, 0.1, 0.0),
            start_alpha=1.0f0,
            end_alpha=0.0f0,
            additive=true
        )
    ]),

    # Smoke-like particles (slower, larger, alpha blend)
    entity([
        transform(position=Vec3d(3, 0.5, 0)),
        ParticleSystemComponent(
            max_particles=128,
            emission_rate=10.0f0,
            lifetime_min=2.0f0,
            lifetime_max=4.0f0,
            velocity_min=Vec3f(-0.2, 0.5, -0.2),
            velocity_max=Vec3f(0.2, 1.5, 0.2),
            gravity_modifier=-0.1f0,
            damping=0.5f0,
            start_size_min=0.2f0,
            start_size_max=0.4f0,
            end_size=1.5f0,
            start_color=RGB{Float32}(0.5, 0.5, 0.5),
            end_color=RGB{Float32}(0.3, 0.3, 0.3),
            start_alpha=0.6f0,
            end_alpha=0.0f0,
            additive=false
        )
    ]),

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(color=RGB{Float32}(0.4, 0.4, 0.4), roughness=0.9f0),
        transform()
    ])
])

render(s, post_process=PostProcessConfig(
    bloom_enabled=true, bloom_threshold=1.0f0, bloom_intensity=0.5f0,
    tone_mapping=TONEMAP_ACES, fxaa_enabled=true
))
```

Key concepts:
- **`emission_rate`**: Continuous emission (particles/sec). Set to 0 for burst-only.
- **`burst_count`**: Emit this many particles all at once on the first frame, then reset to 0.
- **`gravity_modifier`**: Multiplier on world gravity. Negative values make particles rise.
- **`damping`**: Slows particles over time (good for smoke).
- **`additive=true`**: Particles add brightness (fire, sparks). `false` = standard alpha blend (smoke, dust).
- Color and size lerp from start to end over each particle's lifetime.
- Particles are billboarded (always face the camera).

---

## Tutorial 11: Skeletal Animation

Load animated 3D characters from glTF 2.0 files. The loader extracts meshes, skeletons, and animation clips automatically.

```julia
using OpenReality

reset_entity_counter!()
reset_component_stores!()

# Load a glTF model with skeleton and animations
model = load_model("assets/character.glb")

s = scene([
    create_player(position=Vec3d(0, 1.7, 5)),
    entity([DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.5), intensity=2.0f0)]),
    entity([IBLComponent(environment_path="sky", intensity=0.8f0)]),
    model...
])

render(s)
```

The glTF loader handles everything: meshes with bone weights/indices, `BoneComponent` entities in the skeleton hierarchy, `SkinnedMeshComponent` linking bones to the mesh, and `AnimationComponent` with keyframe clips.

### How It Works

1. **BoneComponent** — each bone is an entity with an inverse bind matrix and a bone index.
2. **SkinnedMeshComponent** — attached to the mesh entity, references all bone entities. Each frame, the skinning system computes: `bone_matrix = inverse(mesh_world) * bone_world * inverse_bind`.
3. **AnimationComponent** — drives bone transforms (position, rotation, scale) via keyframe interpolation.
4. **MeshComponent** — contains `bone_weights` and `bone_indices` per vertex (up to 4 bones per vertex).

Animation playback is controlled via the `AnimationComponent`:
- `playing` — start/stop
- `looping` — loop when finished
- `speed` — playback speed multiplier
- `active_clip` — which animation clip to play (1-based index)

Maximum 128 bones per skinned mesh.

---

## Troubleshooting

### "GLFW not found" or window fails to open
Make sure GLFW is installed on your system (see Prerequisites above). On Linux, you may also need `libgl1-mesa-dev`.

### Vulkan backend crashes or shows no output
Ensure the Vulkan SDK is installed and your GPU drivers support Vulkan. Run `vulkaninfo` in your terminal to verify.

### Long first load time
Julia compiles everything on first use. Subsequent loads in the same session are instant. Consider using [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) for faster startup.

### Objects are invisible
Make sure every visible entity has both a `MeshComponent` (or a primitive like `cube_mesh()`) and a `MaterialComponent`. Also ensure there is at least one light in the scene.

---

## Next Steps

- [API Reference](api-reference.md) — full documentation of every component, function, and type
- [Architecture](architecture.md) — how the engine works internally
- [Examples](examples.md) — annotated code samples for common patterns

---

## Tutorial 12: Scripting with ScriptComponent

Add custom behavior to entities using lifecycle callbacks.

```julia
using OpenReality

# A rotating cube script
s = scene([
    create_player(position=Vec3d(0, 2, 5)),
    entity([DirectionalLightComponent(direction=Vec3f(0, -1, -0.5), intensity=2.0f0)]),
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.2, 0.6, 1.0)),
        transform(),
        ScriptComponent(
            on_start = (eid, ctx) -> println("Entity $eid started!"),
            on_update = (eid, dt, ctx) -> begin
                t = get_component(eid, TransformComponent)
                if t !== nothing
                    current = t.rotation[]
                    rot = Quaterniond(cos(dt), 0, sin(dt), 0)
                    t.rotation[] = current * rot
                end
            end
        )
    ])
])

render(s)
```

---

## Tutorial 13: Game States with FSM

Use `GameStateMachine` for multi-state games with scene transitions.

```julia
using OpenReality

mutable struct MenuState <: GameState end
mutable struct PlayState <: GameState end

function on_enter!(state::MenuState, sc::Scene)
    println("Entered menu")
end

function on_update!(state::MenuState, sc::Scene, dt::Float64, ctx::GameContext)
    if ctx.input.keys_pressed[Int(GLFW.KEY_ENTER)+1]
        return StateTransition(:play, [
            create_player(position=Vec3d(0, 2, 5)),
            entity([DirectionalLightComponent(direction=Vec3f(0, -1, -0.5), intensity=2.0f0)]),
            entity([cube_mesh(), MaterialComponent(), transform()])
        ])
    end
    return nothing
end

function get_ui_callback(state::MenuState)
    return ctx -> ui_text(ctx, 400, 300, "Press ENTER to play", size=32)
end

function on_update!(state::PlayState, sc::Scene, dt::Float64, ctx::GameContext)
    return nothing
end

menu_scene = [entity([CameraComponent(fov=60.0), transform(position=Vec3d(0, 2, 5))])]

fsm = GameStateMachine(:menu, menu_scene)
fsm.states[:menu] = MenuState()
fsm.states[:play] = PlayState()

render(fsm)
```

---

## Tutorial 14: Camera Controllers

Use third-person, orbit, or cinematic cameras instead of the default FPS controller.

```julia
using OpenReality

# Third-person camera following a target entity
s = scene([
    # Target entity
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.2, 0.8, 0.2)),
        transform()
    ]),
    # Camera with controller (target_entity resolved after scene creation)
    entity([
        CameraComponent(fov=60.0),
        OrbitCamera(
            target_position=Vec3d(0, 0, 0),
            distance=10.0f0,
            yaw=0.0, pitch=-0.3,
            zoom_speed=2.0f0,
            pan_speed=1.0f0,
            smoothing=0.1f0
        ),
        transform(position=Vec3d(0, 5, 10))
    ]),
    entity([DirectionalLightComponent(direction=Vec3f(0, -1, -0.5), intensity=2.0f0)]),
    entity([plane_mesh(), MaterialComponent(), transform()])
])

render(s)
```
