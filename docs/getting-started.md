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

**Vulkan SDK** (recommended on Linux/Windows — Vulkan is the default backend there):

| OS | Command |
|----|---------|
| Ubuntu / Debian | `sudo apt install vulkan-tools libvulkan-dev` |
| Arch Linux | `sudo pacman -S vulkan-icd-loader vulkan-tools` |
| Fedora | `sudo dnf install vulkan-tools vulkan-loader-devel` |
| macOS | `brew install molten-vk` (only if you want Vulkan; Metal is the macOS default) |
| Windows | Download from [lunarg.com](https://vulkan.lunarg.com/sdk/home) |

If you can't install Vulkan, pass `backend=OpenGLBackend()` to `render(...)` to
use the legacy OpenGL path instead.

## Installation

### One-liner (recommended)

```bash
# Linux / macOS
curl -fsSL https://open-reality.com/install.sh | sh

# Windows PowerShell
irm https://open-reality.com/install.ps1 | iex
```

### Build from source

Clone the repository and install dependencies:

```bash
git clone https://github.com/sinisterMage/Open-Reality.git
cd OpenReality
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Then load it in your scripts:

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

`render(scene)` automatically picks a backend via `default_backend()`:

| Platform | Default | Override |
|----------|---------|----------|
| Linux / Windows | `VulkanBackend()` | `backend=OpenGLBackend()` for legacy OpenGL |
| macOS | `MetalBackend()` | `backend=OpenGLBackend()` if Metal isn't available |

You can always pass an explicit `backend=` to opt into a specific renderer:

```julia
# Vulkan (Linux / Windows default)
render(s, backend=VulkanBackend())

# Metal (macOS default)
render(s, backend=MetalBackend())

# OpenGL — legacy / fallback when Vulkan or Metal isn't usable
render(s, backend=OpenGLBackend())

# WebGPU (experimental, Rust FFI required)
render(s, backend=WebGPUBackend())
```

All backends support the same features: deferred rendering, PBR, cascaded shadow maps, IBL, SSR, SSAO, TAA, forward transparent pass, and post-processing.

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

---

## Tutorial 15: Timers & Coroutines

Use timers for delayed actions and coroutines for sequential logic spanning multiple frames.

```julia
using OpenReality

# One-shot timer
timer_once!(3.0, () -> @info "3 seconds passed!")

# Repeating timer
timer_interval!(1.0, () -> @info "Tick!"; repeats=5)

# Entity-scoped timer (auto-cancels on despawn)
timer_once!(2.0, () -> explode!(eid); owner=eid)

# Cooperative coroutine
start_coroutine!() do ctx
    yield_wait(ctx, 1.0)        # wait 1 second
    @info "1 second passed"
    yield_frames(ctx, 60)       # wait 60 frames
    @info "60 frames passed"
    yield_until(ctx, () -> is_quest_completed(:rescue))
    @info "Quest completed!"
end
```

---

## Tutorial 16: Tweens & Easing

Animate entity properties over time with configurable easing curves.

```julia
using OpenReality

# Tween position with cubic easing
tween!(eid, :position, Vec3d(10, 5, 0), 2.0;
       easing=ease_in_out_cubic)

# Ping-pong scale animation (loops forever)
tween!(eid, :scale, Vec3d(1.5, 1.5, 1.5), 0.8;
       easing=ease_in_out_sine,
       loop_mode=TWEEN_PING_PONG,
       loop_count=-1)

# Chain tweens into a sequence
a = tween!(eid, :position, Vec3d(5, 0, 0), 1.0)
b = tween!(eid, :position, Vec3d(5, 5, 0), 1.0)
c = tween!(eid, :position, Vec3d(0, 0, 0), 1.0)
tween_sequence!([a, b, c])
```

Available easings: `ease_linear`, `ease_in/out/in_out_quad`, `ease_in/out/in_out_cubic`, `ease_in/out/in_out_sine`, `ease_in/out_expo`, `ease_in/out_back`, `ease_in/out_bounce`, `ease_in/out_elastic`.

---

## Tutorial 17: Behavior Trees

Build composable AI with behavior trees. Each entity gets a per-entity blackboard for shared state.

```julia
using OpenReality

tree = bt_selector(
    bt_sequence(
        bt_condition((eid, bb) -> bb_get(bb, :player_distance, Inf) < 10.0),
        bt_move_to(:player_pos; speed=5.0),
        bt_action((eid, bb, dt) -> begin
            apply_damage!(bb_get(bb, :player_eid), 10.0; damage_type=DAMAGE_PHYSICAL)
            return BT_SUCCESS
        end)
    ),
    bt_sequence(
        bt_move_to(:patrol_target; speed=3.0),
        bt_wait(2.0)
    )
)

# Attach to entity
entity([
    cube_mesh(),
    MaterialComponent(color=RGB{Float32}(0.8, 0.2, 0.2)),
    transform(position=Vec3d(5, 0.5, 0)),
    BehaviorTreeComponent(tree)
])
```

---

## Tutorial 18: Health & Damage

Add HP, armor, and typed damage resistances to entities.

```julia
using OpenReality

entity([
    cube_mesh(),
    MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.1)),
    transform(),
    HealthComponent(
        max_hp=100.0f0,
        armor=10.0f0,
        resistances=Dict(DAMAGE_FIRE => 0.5f0),
        auto_despawn=true
    )
])

# Apply damage (respects armor + resistances)
apply_damage!(target, 25.0; damage_type=DAMAGE_FIRE, knockback=Vec3d(0, 2, -5))

# Heal
heal!(target, 30.0)

# Listen for death events
subscribe!(DeathEvent, event -> begin
    @info "Entity $(event.entity) died"
end)
```

---

## Tutorial 19: Inventory & Items

Register item definitions and place pickups in the world.

```julia
using OpenReality

register_item!(ItemDef(
    id=:health_potion,
    name="Health Potion",
    item_type=ITEM_CONSUMABLE,
    stackable=true, max_stack=10,
    on_use=(eid) -> heal!(eid, 30.0)
))

# Entity with inventory
entity([
    transform(),
    cube_mesh(),
    MaterialComponent(),
    InventoryComponent(max_slots=20, max_weight=50.0f0)
])

# World pickup
entity([
    sphere_mesh(radius=0.2f0),
    MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.1)),
    transform(position=Vec3d(5, 0.5, 0)),
    PickupComponent(:health_potion; count=1, auto_pickup_radius=1.5f0)
])
```

---

## Tutorial 20: Quests & Objectives

Define quests with typed objectives and automatic event-driven tracking.

```julia
using OpenReality

register_quest!(QuestDef(
    id=:goblin_slayer,
    name="Goblin Slayer",
    description="Defeat 5 goblins",
    objectives=[ObjectiveDef(description="Kill goblins", type=OBJ_KILL, required=5)]
))

start_quest!(:goblin_slayer)

# Auto-track kills via EventBus
subscribe!(DeathEvent, event -> begin
    if is_quest_active(:goblin_slayer)
        advance_objective!(:goblin_slayer, 1)
    end
end)

# Check completion
is_quest_completed(:goblin_slayer)
```

---

## Tutorial 21: Dialogue System

Build branching NPC dialogue with per-choice conditions and quest integration.

```julia
using OpenReality

tree = DialogueTree(:elder, [
    DialogueNode(id=:start, speaker="Elder",
        text="Welcome! Will you help us?",
        choices=[
            DialogueChoice("I'll help!", :accept),
            DialogueChoice("Not now.", :decline)
        ]
    ),
    DialogueNode(id=:accept, speaker="Elder",
        text="Defeat the goblins in the east.",
        choices=[],
        on_enter=() -> start_quest!(:goblin_slayer)
    ),
    DialogueNode(id=:decline, speaker="Elder",
        text="Come back when you're ready.",
        choices=[]
    )
])

start_dialogue!(tree)
# Engine handles input + UI rendering automatically
```

---

## Tutorial 22: Game Config & Debug Console

Use the config system for tunable values and the debug console for development.

```julia
using OpenReality

# Config
set_config!("player.max_hp", 100.0)
register_difficulty!(:easy, Dict("player.max_hp" => 150.0, "enemy.speed" => 3.0))
apply_difficulty!(:easy)

hp = get_config(Float64, "player.max_hp"; default=100.0)

# Debug console (toggle with backtick key in-game)
register_command!("heal", args -> begin
    heal!(player_eid[], parse(Float32, args[1]))
    return "Healed $(args[1]) HP"
end; help="heal <amount>")

watch!("FPS", () -> round(1.0 / dt[]))
watch!("Player HP", () -> get_hp(player_eid[]))
```
