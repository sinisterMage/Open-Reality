# API Reference

Complete reference for all public types, functions, and components in OpenReality.

---

## Core Functions

### `render`

```julia
render(scene::Scene;
       backend::AbstractBackend = OpenGLBackend(),
       width::Int = 1280,
       height::Int = 720,
       title::String = "OpenReality",
       post_process::Union{PostProcessConfig, Nothing} = nothing,
       ui::Union{Function, Nothing} = nothing)
```

Opens a window and starts the render loop for the given scene. Blocks until the window is closed.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `scene` | *(required)* | The scene to render |
| `backend` | `OpenGLBackend()` | Rendering backend (`OpenGLBackend`, `VulkanBackend`, `MetalBackend`, `WebGPUBackend`) |
| `width` | `1280` | Window width in pixels |
| `height` | `720` | Window height in pixels |
| `title` | `"OpenReality"` | Window title |
| `post_process` | `nothing` | Post-processing configuration |
| `ui` | `nothing` | UI callback function `(ctx::UIContext) -> nothing`, called every frame |

---

### `scene`

```julia
scene(entity_defs::Vector) -> Scene
```

Creates a `Scene` from a vector of `EntityDef` values. Entities are materialized with real `EntityID`s, components are registered in the global ECS, and parent-child hierarchies are established.

```julia
s = scene([
    entity([TransformComponent(), MeshComponent()]),
    entity([CameraComponent()])
])
```

---

### `entity`

```julia
entity(components::Vector; children::Vector = []) -> EntityDef
```

Creates an `EntityDef` — a blueprint for an entity with its components and optional children. Entity defs are not live entities; they become real entities when passed to `scene()`.

```julia
parent = entity([
    cube_mesh(),
    MaterialComponent(),
    transform(position=Vec3d(0, 1, 0))
], children=[
    entity([CameraComponent(), transform()])
])
```

---

### `create_player`

```julia
create_player(;
    position::Vec3d = Vec3d(0, 1.7, 0),
    move_speed::Float32 = 5.0f0,
    sprint_multiplier::Float32 = 2.0f0,
    mouse_sensitivity::Float32 = 0.002f0,
    mesh::Union{MeshComponent, Nothing} = nothing,
    material::Union{MaterialComponent, Nothing} = nothing,
    fov::Float32 = 70.0f0,
    aspect::Float32 = Float32(16/9),
    near::Float32 = 0.1f0,
    far::Float32 = 500.0f0
) -> EntityDef
```

Convenience function that creates a player entity with FPS controls and an attached camera child.

The returned entity includes:
- `PlayerComponent` with the given movement settings
- `TransformComponent` at the given position
- `ColliderComponent` with AABB shape `(0.3, 0.9, 0.3)` half-extents
- `RigidBodyComponent` with `BODY_KINEMATIC` type
- A child entity with `CameraComponent` and a local `transform()`

| Parameter | Default | Description |
|-----------|---------|-------------|
| `position` | `Vec3d(0, 1.7, 0)` | Spawn position |
| `move_speed` | `5.0` | Movement speed (units/sec) |
| `sprint_multiplier` | `2.0` | Speed multiplier when holding Shift |
| `mouse_sensitivity` | `0.002` | Mouse look sensitivity |
| `mesh` | `nothing` | Optional visible body mesh |
| `material` | `nothing` | Optional material for visible body |
| `fov` | `70.0` | Camera field of view (degrees) |
| `aspect` | `16/9` | Camera aspect ratio |
| `near` | `0.1` | Near clipping plane |
| `far` | `500.0` | Far clipping plane |

---

### `load_model`

```julia
load_model(path::String; kwargs...) -> Vector{EntityDef}
```

Loads a 3D model file and returns a vector of `EntityDef` values ready for use with `scene()`.

**Supported formats:**
- `.obj` — Wavefront OBJ (keyword: `default_material::MaterialComponent`)
- `.gltf`, `.glb` — glTF 2.0 (keyword: `base_dir::String` for texture paths)

---

## Components

All components are subtypes of `abstract type Component end`.

### `TransformComponent`

```julia
TransformComponent(;
    position::Union{Vec3d, Observable{Vec3d}} = Vec3d(0, 0, 0),
    rotation::Union{Quaterniond, Observable{Quaterniond}} = Quaterniond(1, 0, 0, 0),
    scale::Union{Vec3d, Observable{Vec3d}} = Vec3d(1, 1, 1),
    parent::Union{EntityID, Nothing} = nothing
)
```

Position, rotation, and scale of an entity. Properties are wrapped in `Observable` for reactive updates. Rotation is a quaternion in `(w, x, y, z)` format where `w=1` is the identity.

**Convenience constructor:**

```julia
transform(;
    position = Vec3d(0, 0, 0),
    rotation = Quaterniond(1, 0, 0, 0),
    scale = Vec3d(1, 1, 1)
) -> TransformComponent
```

The `transform()` helper is the recommended way to create transforms in scene definitions.

---

### `MeshComponent`

```julia
MeshComponent(;
    vertices::Vector{Point3f} = Point3f[],
    indices::Vector{UInt32} = UInt32[],
    normals::Vector{Vec3f} = Vec3f[],
    uvs::Vector{Vec2f} = Vec2f[]
)
```

Raw 3D mesh data. In practice, use the built-in primitives or `load_model()` instead of constructing this directly.

---

### `MaterialComponent`

```julia
MaterialComponent(;
    color::RGB{Float32} = RGB{Float32}(1, 1, 1),
    metallic::Float32 = 0.0f0,
    roughness::Float32 = 0.5f0,
    albedo_map::Union{TextureRef, Nothing} = nothing,
    normal_map::Union{TextureRef, Nothing} = nothing,
    metallic_roughness_map::Union{TextureRef, Nothing} = nothing,
    ao_map::Union{TextureRef, Nothing} = nothing,
    emissive_map::Union{TextureRef, Nothing} = nothing,
    emissive_factor::Vec3f = Vec3f(0, 0, 0),
    opacity::Float32 = 1.0f0,
    alpha_cutoff::Float32 = 0.0f0,
    clearcoat::Float32 = 0.0f0,
    clearcoat_roughness::Float32 = 0.0f0,
    clearcoat_map::Union{TextureRef, Nothing} = nothing,
    height_map::Union{TextureRef, Nothing} = nothing,
    parallax_height_scale::Float32 = 0.0f0,
    subsurface::Float32 = 0.0f0,
    subsurface_color::Vec3f = Vec3f(1, 1, 1)
)
```

PBR material using the metallic/roughness workflow.

**Core PBR properties:**

| Field | Default | Description |
|-------|---------|-------------|
| `color` | `RGB(1,1,1)` | Base color (albedo) |
| `metallic` | `0.0` | 0 = dielectric, 1 = metal |
| `roughness` | `0.5` | 0 = mirror, 1 = rough |
| `opacity` | `1.0` | 0 = transparent, 1 = opaque |
| `alpha_cutoff` | `0.0` | Fragments below this alpha are discarded |

**Texture maps:**

| Field | Description |
|-------|-------------|
| `albedo_map` | Base color texture (overrides `color`) |
| `normal_map` | Tangent-space normal map |
| `metallic_roughness_map` | Combined metallic (B) + roughness (G) texture |
| `ao_map` | Ambient occlusion map |
| `emissive_map` | Emissive texture |
| `clearcoat_map` | Clear coat intensity map |
| `height_map` | Height map for parallax occlusion mapping |

Textures are referenced via `TextureRef("path/to/texture.png")` and loaded lazily at render time.

**Advanced features:**

| Field | Default | Description |
|-------|---------|-------------|
| `emissive_factor` | `Vec3f(0,0,0)` | Emissive color/intensity (HDR values for bloom) |
| `clearcoat` | `0.0` | Clear coat layer intensity (car paint, lacquer) |
| `clearcoat_roughness` | `0.0` | Clear coat roughness |
| `parallax_height_scale` | `0.0` | Parallax mapping displacement scale |
| `subsurface` | `0.0` | Subsurface scattering intensity (skin, wax, leaves) |
| `subsurface_color` | `Vec3f(1,1,1)` | Color tint for subsurface scattering |

---

### `CameraComponent`

```julia
CameraComponent(;
    fov::Float32 = 60.0f0,
    near::Float32 = 0.1f0,
    far::Float32 = 1000.0f0,
    aspect::Float32 = 16.0f0 / 9.0f0
)
```

| Field | Default | Description |
|-------|---------|-------------|
| `fov` | `60.0` | Field of view in degrees |
| `near` | `0.1` | Near clipping plane distance |
| `far` | `1000.0` | Far clipping plane distance |
| `aspect` | `16/9` | Width-to-height ratio |

---

### `PointLightComponent`

```julia
PointLightComponent(;
    color::RGB{Float32} = RGB{Float32}(1, 1, 1),
    intensity::Float32 = 1.0f0,
    range::Float32 = 10.0f0
)
```

Omnidirectional point light. Place it in the scene with a `transform()`.

---

### `DirectionalLightComponent`

```julia
DirectionalLightComponent(;
    color::RGB{Float32} = RGB{Float32}(1, 1, 1),
    intensity::Float32 = 1.0f0,
    direction::Vec3f = Vec3f(0, -1, 0)
)
```

Infinite-distance directional light (like the sun). Casts cascaded shadow maps automatically.

---

### `IBLComponent`

```julia
IBLComponent(;
    environment_path::String = "",
    intensity::Float32 = 1.0f0,
    enabled::Bool = true
)
```

Image-Based Lighting for photorealistic environment lighting and reflections. Use `environment_path="sky"` for a procedural sky, or provide a path to an HDR environment map. Only one IBL should be active per scene.

---

### `PlayerComponent`

```julia
PlayerComponent(;
    move_speed::Float32 = 5.0f0,
    sprint_multiplier::Float32 = 2.0f0,
    mouse_sensitivity::Float32 = 0.002f0,
    yaw::Float64 = 0.0,
    pitch::Float64 = 0.0
)
```

Marks an entity as the player for FPS controls. Typically created via `create_player()` rather than directly.

---

### `ColliderComponent`

```julia
ColliderComponent(;
    shape::ColliderShape = AABBShape(Vec3f(0.5, 0.5, 0.5)),
    offset::Vec3f = Vec3f(0, 0, 0),
    is_trigger::Bool = false
)
```

Attaches a collision shape to an entity. The shape is defined in local space; the physics system positions it using the entity's world transform. Set `is_trigger=true` to make the collider generate trigger events instead of contact forces.

**Shapes:**
- `AABBShape(half_extents::Vec3f)` — axis-aligned bounding box
- `SphereShape(radius::Float32)` — sphere
- `CapsuleShape(; radius, half_height, axis)` — cylinder with hemispherical caps
- `OBBShape(half_extents::Vec3f)` — oriented bounding box (uses entity rotation)
- `ConvexHullShape(vertices::Vector{Vec3f})` — arbitrary convex hull
- `CompoundShape(children::Vector{CompoundChild})` — multi-shape collider

**CompoundChild:**
```julia
CompoundChild(shape::ColliderShape; position::Vec3d=Vec3d(0,0,0), rotation::Quaterniond=Quaterniond(1,0,0,0))
```

**CapsuleAxis enum:**
- `CAPSULE_X`, `CAPSULE_Y` (default), `CAPSULE_Z`

**Helper functions:**
- `collider_from_mesh(mesh::MeshComponent) -> ColliderComponent` — auto-generates an AABB from mesh bounds
- `sphere_collider_from_mesh(mesh::MeshComponent) -> ColliderComponent` — auto-generates a bounding sphere from mesh vertices

---

### `RigidBodyComponent`

```julia
RigidBodyComponent(;
    body_type::BodyType = BODY_DYNAMIC,
    velocity::Vec3d = Vec3d(0, 0, 0),
    angular_velocity::Vec3d = Vec3d(0, 0, 0),
    mass::Float64 = 1.0,
    restitution::Float32 = 0.0f0,
    friction::Float64 = 0.5,
    linear_damping::Float64 = 0.01,
    angular_damping::Float64 = 0.05,
    grounded::Bool = false,
    sleeping::Bool = false,
    ccd_mode::CCDMode = CCD_NONE
)
```

| Field | Default | Description |
|-------|---------|-------------|
| `body_type` | `BODY_DYNAMIC` | How the entity participates in physics |
| `velocity` | `Vec3d(0,0,0)` | Linear velocity (m/s) |
| `angular_velocity` | `Vec3d(0,0,0)` | Angular velocity (rad/s) |
| `mass` | `1.0` | Mass in kg |
| `restitution` | `0.0` | Bounciness (0 = no bounce, 1 = perfectly elastic) |
| `friction` | `0.5` | Friction coefficient |
| `linear_damping` | `0.01` | Linear velocity damping per second |
| `angular_damping` | `0.05` | Angular velocity damping per second |
| `grounded` | `false` | Whether the entity is on a surface (set by physics) |
| `sleeping` | `false` | Whether the body is asleep (not simulated) |
| `ccd_mode` | `CCD_NONE` | Continuous collision detection mode |

**Body types (`BodyType` enum):**
- `BODY_STATIC` — never moves (walls, floors, terrain)
- `BODY_KINEMATIC` — moved by code, not by physics forces (player controller)
- `BODY_DYNAMIC` — affected by gravity and collision response

**CCD modes (`CCDMode` enum):**
- `CCD_NONE` — discrete collision detection (default)
- `CCD_SWEPT` — swept collision test prevents tunneling through thin objects

---

### `JointComponent`

```julia
JointComponent(joint::JointConstraint)
```

Attaches a joint constraint to an entity. The joint connects two entities at anchor points.

**Joint types:**

```julia
BallSocketJoint(entity_a, entity_b; local_anchor_a=Vec3d(0,0,0), local_anchor_b=Vec3d(0,0,0))
DistanceJoint(entity_a, entity_b; target_distance=1.0, local_anchor_a=Vec3d(0,0,0), local_anchor_b=Vec3d(0,0,0))
HingeJoint(entity_a, entity_b; axis=Vec3d(0,1,0), lower_limit=NaN, upper_limit=NaN)
FixedJoint(entity_a, entity_b; local_anchor_a=Vec3d(0,0,0), local_anchor_b=Vec3d(0,0,0))
SliderJoint(entity_a, entity_b; axis=Vec3d(1,0,0), lower_limit=NaN, upper_limit=NaN)
```

---

### `TriggerComponent`

```julia
TriggerComponent(;
    on_enter::Union{Function, Nothing} = nothing,
    on_stay::Union{Function, Nothing} = nothing,
    on_exit::Union{Function, Nothing} = nothing
)
```

Makes a collider act as a trigger volume. The entity must also have a `ColliderComponent` with `is_trigger=true`. Callbacks receive `(trigger_entity_id, other_entity_id)`.

---

## Physics Functions

### `raycast`

```julia
raycast(origin::Vec3d, direction::Vec3d; max_distance::Float64=Inf) -> Union{RaycastHit, Nothing}
```

Cast a ray and return the closest hit. Returns a `RaycastHit` with fields: `entity`, `point`, `normal`, `distance`.

### `raycast_all`

```julia
raycast_all(origin::Vec3d, direction::Vec3d; max_distance::Float64=Inf) -> Vector{RaycastHit}
```

Cast a ray and return all hits sorted by distance.

### `PhysicsWorldConfig`

```julia
PhysicsWorldConfig(;
    gravity::Vec3d = Vec3d(0, -9.81, 0),
    fixed_dt::Float64 = 1/120,
    max_substeps::Int = 8,
    solver_iterations::Int = 10,
    position_correction::Float64 = 0.2,
    slop::Float64 = 0.005,
    sleep_linear_threshold::Float64 = 0.01,
    sleep_angular_threshold::Float64 = 0.05,
    sleep_time::Float64 = 0.5
)
```

### `reset_physics_world!`

```julia
reset_physics_world!()
```

Reset the physics world singleton. Call this alongside `reset_entity_counter!()` and `reset_component_stores!()` when starting a fresh scene.

---

### `AnimationComponent`

```julia
AnimationComponent(;
    clips::Vector{AnimationClip} = AnimationClip[],
    active_clip::Int = 1,
    time::Float32 = 0.0f0,
    playing::Bool = true,
    looping::Bool = true
)
```

Keyframe-based animation. Typically populated by `load_model()` from glTF files.

**Related types:**

```julia
struct AnimationClip
    name::String
    channels::Vector{AnimationChannel}
    duration::Float32
end

struct AnimationChannel
    target_entity::EntityID
    target_property::Symbol    # :position, :rotation, or :scale
    times::Vector{Float32}
    values::Vector{Float32}
    interpolation::InterpolationMode  # INTERP_STEP, INTERP_LINEAR, INTERP_CUBICSPLINE
end
```

---

### `AudioListenerComponent`

```julia
AudioListenerComponent(;
    gain::Float32 = 1.0f0
)
```

Marks an entity as the audio listener (i.e. the "ears" of the scene). There should be one per scene, typically attached to the player or camera entity. The listener's world transform determines the position and orientation for 3D audio.

| Field | Default | Description |
|-------|---------|-------------|
| `gain` | `1.0` | Master volume (0.0 = silent, 1.0 = full) |

---

### `AudioSourceComponent`

```julia
AudioSourceComponent(;
    audio_path::String = "",
    playing::Bool = false,
    looping::Bool = false,
    gain::Float32 = 1.0f0,
    pitch::Float32 = 1.0f0,
    spatial::Bool = true,
    reference_distance::Float32 = 1.0f0,
    max_distance::Float32 = 100.0f0,
    rolloff_factor::Float32 = 1.0f0
)
```

Plays audio from a `.wav` file. The source's world transform determines its 3D position for spatial audio.

| Field | Default | Description |
|-------|---------|-------------|
| `audio_path` | `""` | Path to a `.wav` audio file |
| `playing` | `false` | Set to `true` to start playback |
| `looping` | `false` | Loop the audio when it reaches the end |
| `gain` | `1.0` | Volume (0.0 = silent, 1.0 = full) |
| `pitch` | `1.0` | Playback speed / pitch multiplier |
| `spatial` | `true` | Enable 3D positional audio (false = 2D, no attenuation) |
| `reference_distance` | `1.0` | Distance at which gain is 1.0 (no attenuation) |
| `max_distance` | `100.0` | Distance beyond which no further attenuation occurs |
| `rolloff_factor` | `1.0` | How quickly sound attenuates with distance |

---

### `ParticleSystemComponent`

```julia
ParticleSystemComponent(;
    max_particles::Int = 256,
    emission_rate::Float32 = 20.0f0,
    burst_count::Int = 0,
    lifetime_min::Float32 = 1.0f0,
    lifetime_max::Float32 = 2.0f0,
    velocity_min::Vec3f = Vec3f(-0.5, 1.0, -0.5),
    velocity_max::Vec3f = Vec3f(0.5, 3.0, 0.5),
    gravity_modifier::Float32 = 1.0f0,
    damping::Float32 = 0.0f0,
    start_size_min::Float32 = 0.1f0,
    start_size_max::Float32 = 0.3f0,
    end_size::Float32 = 0.0f0,
    start_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
    end_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
    start_alpha::Float32 = 1.0f0,
    end_alpha::Float32 = 0.0f0,
    additive::Bool = false
)
```

CPU-simulated billboard particle system. Particles are emitted from the entity's world position and rendered as camera-facing quads.

**Emission:**

| Field | Default | Description |
|-------|---------|-------------|
| `max_particles` | `256` | Maximum number of live particles |
| `emission_rate` | `20.0` | Particles emitted per second (0 = burst only) |
| `burst_count` | `0` | One-shot burst count (consumed on first frame, then reset to 0) |

**Lifetime & Velocity:**

| Field | Default | Description |
|-------|---------|-------------|
| `lifetime_min` | `1.0` | Minimum particle lifetime (seconds) |
| `lifetime_max` | `2.0` | Maximum particle lifetime (seconds) |
| `velocity_min` | `Vec3f(-0.5, 1.0, -0.5)` | Minimum initial velocity (randomized per-component) |
| `velocity_max` | `Vec3f(0.5, 3.0, 0.5)` | Maximum initial velocity (randomized per-component) |

**Physics:**

| Field | Default | Description |
|-------|---------|-------------|
| `gravity_modifier` | `1.0` | Multiplier on gravity `(0, -9.81, 0)` |
| `damping` | `0.0` | Velocity damping per second |

**Size over lifetime:**

| Field | Default | Description |
|-------|---------|-------------|
| `start_size_min` | `0.1` | Minimum initial size |
| `start_size_max` | `0.3` | Maximum initial size |
| `end_size` | `0.0` | Size at end of lifetime (lerped) |

**Color over lifetime:**

| Field | Default | Description |
|-------|---------|-------------|
| `start_color` | `RGB(1,1,1)` | Color at birth |
| `end_color` | `RGB(1,1,1)` | Color at death (lerped) |
| `start_alpha` | `1.0` | Alpha at birth |
| `end_alpha` | `0.0` | Alpha at death (lerped) |
| `additive` | `false` | Additive blending (true) vs alpha blending (false) |

---

### `BoneComponent`

```julia
BoneComponent(;
    inverse_bind_matrix::Mat4f = Mat4f(I),
    bone_index::Int = 0,
    name::String = ""
)
```

Represents a bone in a skeleton hierarchy. Typically created automatically by `load_model()` when loading glTF files with skins.

| Field | Default | Description |
|-------|---------|-------------|
| `inverse_bind_matrix` | `Mat4f(I)` | Transforms from mesh space to bone-local space |
| `bone_index` | `0` | Index into the bone array (0-based, matching glTF) |
| `name` | `""` | Bone name from the model file |

---

### `SkinnedMeshComponent`

```julia
SkinnedMeshComponent(;
    bone_entities::Vector{EntityID} = EntityID[],
    bone_matrices::Vector{Mat4f} = Mat4f[]
)
```

Attaches skeletal skinning to a mesh entity. Bone matrices are computed each frame by `update_skinned_meshes!()` and uploaded to the vertex shader. Maximum 128 bones per skinned mesh.

| Field | Default | Description |
|-------|---------|-------------|
| `bone_entities` | `EntityID[]` | Ordered list of bone entity IDs (matches joint order in skin) |
| `bone_matrices` | `Mat4f[]` | Per-frame computed bone matrices (set by skinning system) |

---

### `LODComponent`

```julia
LODComponent(;
    levels::Vector{LODLevel} = LODLevel[],
    transition_mode::LODTransitionMode = LOD_TRANSITION_DITHER,
    transition_width::Float32 = 2.0f0,
    hysteresis::Float32 = 1.1f0
)
```

Level-of-detail component. Switches between mesh variants based on camera distance. Levels should be ordered from highest detail (closest) to lowest.

| Field | Default | Description |
|-------|---------|-------------|
| `levels` | `LODLevel[]` | LOD levels, each with a mesh and max distance |
| `transition_mode` | `LOD_TRANSITION_DITHER` | How to blend between LOD levels |
| `transition_width` | `2.0` | Distance range for crossfade (when using dither) |
| `hysteresis` | `1.1` | Multiplier to prevent LOD flickering (e.g., 1.1 = 10% band) |

**LODLevel:**

```julia
LODLevel(; mesh::MeshComponent, max_distance::Float32)
```

**LODTransitionMode enum:**
- `LOD_TRANSITION_INSTANT` — hard swap, no blending
- `LOD_TRANSITION_DITHER` — Bayer dither pattern crossfade

---

### `TerrainComponent`

```julia
TerrainComponent(;
    heightmap::HeightmapSource = HeightmapSource(),
    terrain_size::Vec2f = Vec2f(256.0, 256.0),
    max_height::Float32 = 50.0f0,
    chunk_size::Int = 33,
    num_lod_levels::Int = 3,
    splatmap_path::String = "",
    layers::Vector{TerrainLayer} = TerrainLayer[]
)
```

Heightmap-based terrain with chunk-based LOD and optional splatmap texturing.

| Field | Default | Description |
|-------|---------|-------------|
| `heightmap` | `HeightmapSource()` | Height data source (image, Perlin noise, or flat) |
| `terrain_size` | `Vec2f(256, 256)` | World-space dimensions (width, depth) |
| `max_height` | `50.0` | Maximum terrain height |
| `chunk_size` | `33` | Vertices per chunk side (must be 2^n + 1) |
| `num_lod_levels` | `3` | Number of terrain LOD levels |
| `splatmap_path` | `""` | Path to RGBA splatmap texture (each channel blends a layer) |
| `layers` | `TerrainLayer[]` | Terrain material layers (up to 4, blended by splatmap) |

**HeightmapSource:**

```julia
HeightmapSource(;
    source_type::HeightmapSourceType = HEIGHTMAP_PERLIN,
    image_path::String = "",
    perlin_octaves::Int = 6,
    perlin_frequency::Float32 = 0.01f0,
    perlin_persistence::Float32 = 0.5f0,
    perlin_seed::Int = 42
)
```

**HeightmapSourceType enum:**
- `HEIGHTMAP_IMAGE` — load heights from a grayscale image
- `HEIGHTMAP_PERLIN` — procedurally generate with Perlin noise
- `HEIGHTMAP_FLAT` — flat terrain at height 0

**TerrainLayer:**

```julia
TerrainLayer(;
    albedo_path::String = "",
    normal_path::String = "",
    uv_scale::Float32 = 10.0f0
)
```

---

## Primitives

### `cube_mesh`

```julia
cube_mesh(; size::Float32 = 1.0f0) -> MeshComponent
```

Unit cube centered at the origin with proper face normals and UV coordinates.

### `sphere_mesh`

```julia
sphere_mesh(; radius::Float32 = 0.5f0, segments::Int = 32, rings::Int = 16) -> MeshComponent
```

UV sphere centered at the origin.

### `plane_mesh`

```julia
plane_mesh(; width::Float32 = 1.0f0, depth::Float32 = 1.0f0) -> MeshComponent
```

Horizontal plane at Y=0, facing up (+Y).

---

## Post-Processing

### `PostProcessConfig`

```julia
PostProcessConfig(;
    bloom_enabled::Bool = false,
    bloom_threshold::Float32 = 1.0f0,
    bloom_intensity::Float32 = 0.3f0,
    ssao_enabled::Bool = false,
    ssao_radius::Float32 = 0.5f0,
    ssao_samples::Int = 16,
    tone_mapping::ToneMappingMode = TONEMAP_REINHARD,
    fxaa_enabled::Bool = false,
    gamma::Float32 = 2.2f0
)
```

| Field | Default | Description |
|-------|---------|-------------|
| `bloom_enabled` | `false` | Bloom glow effect |
| `bloom_threshold` | `1.0` | Brightness threshold for bloom |
| `bloom_intensity` | `0.3` | Bloom strength |
| `ssao_enabled` | `false` | Screen-space ambient occlusion |
| `ssao_radius` | `0.5` | SSAO sampling radius |
| `ssao_samples` | `16` | Number of SSAO samples per pixel |
| `tone_mapping` | `TONEMAP_REINHARD` | HDR-to-LDR tone mapping operator |
| `fxaa_enabled` | `false` | Fast approximate anti-aliasing |
| `gamma` | `2.2` | Gamma correction value |

### `ToneMappingMode`

```julia
@enum ToneMappingMode TONEMAP_REINHARD TONEMAP_ACES TONEMAP_UNCHARTED2
```

- `TONEMAP_REINHARD` — classic, preserves color
- `TONEMAP_ACES` — filmic, cinematic look
- `TONEMAP_UNCHARTED2` — Uncharted 2 tone curve

---

## Backends

### `OpenGLBackend`

Default backend. Works on all platforms. Uses OpenGL 3.3 core profile.

### `VulkanBackend`

Available on Linux and Windows. Requires Vulkan SDK and compatible GPU drivers.

### `MetalBackend`

Available on macOS only. Uses the native Metal graphics API.

### `WebGPUBackend`

Experimental backend using wgpu via a Rust FFI library. Requires the `openreality-wgpu` compiled library. Available on Linux and Windows.

---

## Audio Functions

### `init_audio!` / `shutdown_audio!`

```julia
init_audio!()           # Initialize OpenAL device and context
shutdown_audio!()       # Release OpenAL resources
```

Called automatically by the render loop. Only needed if managing audio outside `render()`.

### `update_audio!`

```julia
update_audio!(dt::Float64; config::AudioConfig = DEFAULT_AUDIO_CONFIG)
```

Updates listener position/orientation and all audio source states. Called automatically each frame by the render loop.

### `AudioConfig`

```julia
AudioConfig(;
    doppler_factor::Float32 = 1.0f0,
    speed_of_sound::Float32 = 343.3f0
)
```

| Field | Default | Description |
|-------|---------|-------------|
| `doppler_factor` | `1.0` | Doppler effect intensity (0 = disabled) |
| `speed_of_sound` | `343.3` | Speed of sound for Doppler calculations (m/s) |

---

## Particle Functions

### `update_particles!`

```julia
update_particles!(dt::Float64)
```

Simulates all particle systems: emits new particles, advances lifetimes, applies gravity and damping, updates vertex data for rendering. Called automatically each frame.

### `reset_particle_pools!`

```julia
reset_particle_pools!()
```

Clears all particle pools. Call alongside `reset_component_stores!()` when starting a fresh scene.

---

## Skinning Functions

### `update_skinned_meshes!`

```julia
update_skinned_meshes!()
```

Computes bone matrices for all entities with `SkinnedMeshComponent`. For each bone: `bone_matrix = inverse(mesh_world) * bone_world * inverse_bind_matrix`. Called automatically each frame after animation updates.

### `MAX_BONES`

```julia
const MAX_BONES = 128
```

Maximum number of bones per skinned mesh. Bone matrices are uploaded as a uniform array to the vertex shader.

---

## Scene Export

### `export_scene`

```julia
export_scene(scene::Scene, path::String;
             physics_config::PhysicsWorldConfig = PhysicsWorldConfig(),
             compress_textures::Bool = true)
```

Exports a scene to the binary ORSB (OpenReality Scene Binary) format. This is used for web deployment via WASM runtimes. All components, textures, and physics configuration are serialized into a single file.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `scene` | *(required)* | The scene to export |
| `path` | *(required)* | Output file path (`.orsb`) |
| `physics_config` | `PhysicsWorldConfig()` | Physics settings to embed |
| `compress_textures` | `true` | Whether to compress embedded textures |

---

## UI Functions

The UI system provides immediate-mode widgets rendered as an overlay on top of the 3D scene. Pass a callback function to the `ui` parameter of `render()`:

```julia
render(s, ui = function(ctx::UIContext)
    ui_text(ctx, "Score: 100", x=10, y=10, size=24)
    if ui_button(ctx, "Restart", x=10, y=50)
        # handle click
    end
end)
```

### `ui_rect`

```julia
ui_rect(ctx::UIContext;
        x::Real = 0, y::Real = 0,
        width::Real = 100, height::Real = 100,
        color::RGB{Float32} = RGB{Float32}(1, 1, 1),
        alpha::Float32 = 1.0f0)
```

Draws a solid colored rectangle.

### `ui_text`

```julia
ui_text(ctx::UIContext, text::String;
        x::Real = 0, y::Real = 0,
        size::Int = 24,
        color::RGB{Float32} = RGB{Float32}(1, 1, 1),
        alpha::Float32 = 1.0f0)
```

Renders text using the FreeType font atlas. Supports newlines. Coordinates are in screen pixels (top-left origin).

### `ui_button`

```julia
ui_button(ctx::UIContext, label::String;
          x::Real = 0, y::Real = 0,
          width::Real = 120, height::Real = 40,
          color::RGB{Float32} = RGB{Float32}(0.3, 0.3, 0.3),
          hover_color::RGB{Float32} = RGB{Float32}(0.4, 0.4, 0.4),
          text_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
          text_size::Int = 20,
          alpha::Float32 = 1.0f0) -> Bool
```

Draws a clickable button. Returns `true` on the frame it is clicked. Changes color on hover.

### `ui_progress_bar`

```julia
ui_progress_bar(ctx::UIContext, fraction::Real;
                x::Real = 0, y::Real = 0,
                width::Real = 200, height::Real = 20,
                color::RGB{Float32} = RGB{Float32}(0.2, 0.8, 0.2),
                bg_color::RGB{Float32} = RGB{Float32}(0.2, 0.2, 0.2),
                alpha::Float32 = 1.0f0)
```

Draws a horizontal progress bar. `fraction` is 0.0 to 1.0.

### `ui_image`

```julia
ui_image(ctx::UIContext, texture_id::UInt32;
         x::Real = 0, y::Real = 0,
         width::Real = 64, height::Real = 64,
         alpha::Float32 = 1.0f0)
```

Draws a textured quad. The `texture_id` must be a pre-uploaded GPU texture handle.

### `measure_text`

```julia
measure_text(atlas::FontAtlas, text::String; size::Int = 24) -> (width::Float32, height::Float32)
```

Returns the pixel dimensions that text would occupy when rendered at the given size. Useful for centering or layout.

---

## ECS Operations

### Entity Management

```julia
create_entity_id() -> EntityID          # Generate a new unique entity ID
reset_entity_counter!()                 # Reset the ID counter (for fresh scenes)
reset_component_stores!()               # Clear all component data
```

### Component Operations

```julia
add_component!(entity_id, component)    # Add or replace a component on an entity
get_component(entity_id, Type)          # Get a component (throws if missing)
has_component(entity_id, Type)          # Check if entity has a component type
remove_component!(entity_id, Type)      # Remove a component from an entity
```

### Component Queries

```julia
collect_components(Type)                # Get all components of a type as Vector
entities_with_component(Type)           # Get all entity IDs that have this type
component_count(Type)                   # Count of entities with this component type
iterate_components(f, Type)             # Call f(entity_id, component) for each
```

---

## Scene Operations

```julia
add_entity(scene, entity_id; parent=nothing) -> Scene   # Add entity to scene
remove_entity(scene, entity_id) -> Scene                 # Remove entity and descendants
get_children(scene, entity_id) -> Vector{EntityID}       # Direct children
get_parent(scene, entity_id) -> Union{EntityID, Nothing} # Parent entity
has_entity(scene, entity_id) -> Bool                     # Check membership
is_root(scene, entity_id) -> Bool                        # Is a root entity?
entity_count(scene) -> Int                               # Total entity count
get_all_descendants(scene, entity_id) -> Vector{EntityID}
get_ancestors(scene, entity_id) -> Vector{EntityID}
traverse_scene(scene, visitor_fn)                        # DFS traversal
traverse_entity(scene, entity_id, visitor_fn)            # DFS from entity
```

All scene operations return a **new Scene** — the original is never mutated.

---

## Type Aliases

```julia
const Point3f = Point{3, Float32}
const Vec3f = Vec{3, Float32}
const Vec2f = Vec{2, Float32}
const Mat4f = SMatrix{4, 4, Float32, 16}
const Mat3f = SMatrix{3, 3, Float32, 9}
const Vec3d = Vec{3, Float64}
const Quaterniond = Quaternion{Float64}
```

- Use `Vec3d` for positions and transforms (double precision for numerical stability)
- Use `Vec3f` for directions, normals, and material properties (single precision for GPU)

---

## Game Loop

### render()

```julia
# Basic scene rendering
render(scene::Scene; backend, width, height, title, post_process, ui, on_update, on_scene_switch, shadows)

# FSM-driven rendering
render(fsm::GameStateMachine; backend, width, height, title, post_process, shadows)
```

**Parameters:**
- `scene` — Scene to render
- `backend` — `OpenGLBackend()`, `VulkanBackend()`, `MetalBackend()`, or `WebGPUBackend()`
- `width`, `height` — Window dimensions (default: 1280x720)
- `title` — Window title
- `post_process` — `PostProcessConfig(...)` for bloom, tone mapping, etc.
- `ui` — `function(ctx::UIContext)` callback for immediate-mode UI
- `on_update` — `function(scene, dt, input)::Scene` called each frame
- `on_scene_switch` — `function(new_scene)` called when FSM transitions rebuild the scene
- `shadows` — `true`/`false` to enable/disable shadow mapping

---

## Game State Machine

```julia
abstract type GameState end

mutable struct StateTransition
    target::Symbol
    new_scene_defs::Union{Vector, Nothing}
end

mutable struct GameStateMachine
    states::Dict{Symbol, GameState}
    initial_state::Symbol
    initial_scene_defs::Vector
end
```

**Overridable callbacks:**
```julia
on_enter!(state::GameState, sc::Scene)
on_update!(state::GameState, sc::Scene, dt::Float64, ctx::GameContext)
on_exit!(state::GameState, sc::Scene)
get_ui_callback(state::GameState) -> Union{Function, Nothing}
```

Return a `StateTransition` from `on_update!` to switch states. If `new_scene_defs` is provided, the scene is rebuilt from those definitions.

---

## GameContext

```julia
mutable struct GameContext
    scene::Scene
    input::InputState
end

spawn!(ctx::GameContext, entity_def::EntityDef) -> EntityID
spawn!(ctx::GameContext, prefab::Prefab; kwargs...) -> EntityID
despawn!(ctx::GameContext, entity_id::EntityID)
apply_mutations!(ctx::GameContext, scene::Scene) -> Scene
```

Deferred entity creation and removal. Mutations are collected during `on_update!` and applied atomically after the callback returns.

---

## ScriptComponent

```julia
ScriptComponent(;
    on_start::Union{Function, Nothing} = nothing,
    on_update::Union{Function, Nothing} = nothing,
    on_destroy::Union{Function, Nothing} = nothing
)
```

**Callback signatures:**
- `on_start(entity_id, ctx)` — called once on first tick
- `on_update(entity_id, dt, ctx)` — called every frame
- `on_destroy(entity_id, ctx)` — called when entity is destroyed

Error budget: after 5 consecutive errors, the script is auto-disabled.

---

## CollisionCallbackComponent

```julia
CollisionCallbackComponent(;
    on_collision_enter = nothing,
    on_collision_stay = nothing,
    on_collision_exit = nothing
)
```

Callbacks receive `(this_entity, other_entity, manifold)`. The `manifold` is `nothing` for exit events.

---

## Prefab

```julia
struct Prefab
    factory::Function
end

instantiate(prefab::Prefab; kwargs...) -> EntityDef
```

Reusable entity templates. The factory function receives keyword arguments and returns an `EntityDef`.

---

## EventBus

```julia
abstract type GameEvent end

subscribe!(::Type{T}, callback::Function) where T <: GameEvent
emit!(event::T) where T <: GameEvent
unsubscribe!(::Type{T}, callback::Function) where T <: GameEvent
reset_event_bus!()
```

Publish-subscribe system for decoupled game events.

---

## Camera Controllers

```julia
# Third-person camera that orbits a target entity
ThirdPersonCamera(target_entity, distance, ...)

# Orbit camera around a fixed point
OrbitCamera(target_position, distance, ...)

# Cinematic camera with path-based movement
CinematicCamera(move_speed, sensitivity, path, ...)
```

Updated automatically by `update_camera_controllers!()` each frame.

---

## Input Mapping

```julia
struct InputMap
    bindings::Dict{String, ActionBinding}
    states::Dict{String, ActionState}
end

bind!(map, action_name, source::InputSource) -> InputMap
is_action_pressed(map, name) -> Bool
is_action_just_pressed(map, name) -> Bool
get_axis(map, name) -> Float32
create_default_player_map() -> InputMap
```

Sources: `KeyboardKey(key)`, `MouseButton(button)`, `GamepadButton(joystick_id, button_index)`, `GamepadAxis(joystick_id, axis_index, positive)`.

---

## Animation Blend Trees

```julia
AnimationBlendTreeComponent(
    root::BlendNode,
    parameters::Dict{String, Float32},
    ...
)
```

Blend nodes: `ClipNode(clip)`, `Blend1DNode(parameter, thresholds, children)`, `Blend2DNode(param_x, param_y, positions, children)`.

---

## Post-Processing (Full Reference)

```julia
PostProcessConfig(;
    bloom_enabled=false, bloom_threshold=1.0f0, bloom_intensity=0.3f0,
    ssao_enabled=false, ssao_radius=0.5f0, ssao_samples=16,
    tone_mapping=TONEMAP_REINHARD,  # TONEMAP_ACES, TONEMAP_UNCHARTED2
    fxaa_enabled=false, gamma=2.2f0,
    dof_enabled=false, dof_focus_distance=10.0f0, dof_focus_range=5.0f0, dof_bokeh_radius=3.0f0,
    motion_blur_enabled=false, motion_blur_intensity=1.0f0, motion_blur_samples=8,
    vignette_enabled=false, vignette_intensity=0.4f0, vignette_radius=0.8f0,
    color_grading_enabled=false, color_grading_brightness=0.0f0, color_grading_contrast=1.0f0, color_grading_saturation=1.0f0
)
```

---

## Threading

```julia
use_threading(val::Bool=true)     # Enable/disable multithreading
threading_enabled() -> Bool        # Check if threading is on
snapshot_transforms() -> Dict{EntityID, TransformSnapshot}  # Thread-safe read
snapshot_components(::Type{T}) -> Dict{EntityID, T}
```

Opt-in multithreading with snapshot-based reads for safe parallel access.

---

## Asset Management

```julia
get_model(path::String) -> Vector{EntityDef}     # Load or retrieve from cache
preload!(path::String)                             # Warm the cache
load_model_async(loader, path; kwargs...)           # Non-blocking load
poll_async_loads!(loader) -> Vector{AsyncLoadResult}
```

---

## Save/Load

```julia
save_game(scene::Scene, path::String)    # Serialize scene to binary file
load_game(path::String) -> Scene          # Deserialize scene from file
```

Uses Julia's `Serialization` stdlib. Components registered as non-serializable (e.g., `ScriptComponent`) are skipped.

---

## Debug Drawing

```julia
debug_line!(start_pos::Vec3f, end_pos::Vec3f, color=RGB{Float32}(0,1,0))
debug_box!(center::Vec3f, half_extents::Vec3f, color=RGB{Float32}(0,1,0))
debug_sphere!(center::Vec3f, radius::Float32, color=RGB{Float32}(0,1,0))
```

Enabled by setting `ENV["OPENREALITY_DEBUG"] = "true"` before loading the module. No-ops otherwise.
