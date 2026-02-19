<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Components Reference - OpenReality Docs',
  ogTitle: 'Components Reference - OpenReality Docs',
  description: 'Complete reference for all OpenReality components: Transform, Mesh, Material, Camera, Lights, Collider, RigidBody, Animation, Audio, Skeleton, Particles, and more.',
  ogDescription: 'Complete reference for all OpenReality components: Transform, Mesh, Material, Camera, Lights, Collider, RigidBody, Animation, Audio, Skeleton, Particles, and more.',
})

const transformCode = `transform(
    position=Vec3d(0, 0, 0),     # 3D position (Float64)
    rotation=Quaterniond(1,0,0,0), # quaternion (w,x,y,z)
    scale=Vec3d(1, 1, 1)         # scale factors
)`

const meshCode = `# Built-in primitives
cube_mesh()
sphere_mesh()
plane_mesh()

# Or provide custom geometry
MeshComponent(
    vertices=Point3f[...],
    indices=UInt32[...],
    normals=Vec3f[...],
    uvs=Vec2f[...]
)`

const materialCode = `MaterialComponent(
    color=RGB{Float32}(1, 1, 1),
    metallic=0.0f0,
    roughness=0.5f0,
    albedo_map=TextureRef("albedo.png"),
    normal_map=TextureRef("normal.png"),
    metallic_roughness_map=TextureRef("mr.png"),
    ao_map=TextureRef("ao.png"),
    emissive_map=TextureRef("emissive.png"),
    emissive_factor=Vec3f(0, 0, 0),
    opacity=1.0f0,
    alpha_cutoff=0.0f0,
    # Advanced
    clearcoat=0.0f0,
    clearcoat_roughness=0.0f0,
    height_map=TextureRef("height.png"),
    parallax_height_scale=0.05f0,
    subsurface=0.0f0,
    subsurface_color=Vec3f(1, 1, 1)
)`

const cameraCode = `CameraComponent(
    fov=60.0,      # vertical field of view (degrees)
    near=0.1,      # near clipping plane
    far=1000.0,    # far clipping plane
    aspect=16/9    # aspect ratio
)`

const lightsCode = `# Directional light (sun)
DirectionalLightComponent(
    direction=Vec3f(0, -1, -0.5),
    color=RGB{Float32}(1, 1, 1),
    intensity=1.5f0
)

# Point light
PointLightComponent(
    color=RGB{Float32}(1, 0.8, 0.6),
    intensity=5.0f0,
    range=20.0f0
)

# Image-based lighting
IBLComponent(
    environment_path="env.hdr",
    intensity=1.0f0
)`

const colliderCode = `ColliderComponent(
    shape=AABBShape(),      # or:
    # shape=SphereShape(1.0f0)
    # shape=CapsuleShape(0.5f0, 2.0f0, :Y)
    # shape=OBBShape(Vec3f(1,1,1))
    # shape=ConvexHullShape(points)
    # shape=HeightmapShape(data, w, h, scale)
    offset=Vec3f(0, 0, 0),
    is_trigger=false
)`

const rigidbodyCode = `RigidBodyComponent(
    body_type=BODY_DYNAMIC,  # BODY_STATIC, BODY_KINEMATIC
    mass=1.0,
    restitution=0.3,
    friction=0.5,
    linear_damping=0.01,
    angular_damping=0.05,
    ccd_mode=CCD_NONE        # or CCD_SWEPT
)`

const animationCode = `AnimationComponent(
    clips=[AnimationClip(
        name="walk",
        channels=[AnimationChannel(
            target_entity=entity_id,
            target_property=:position,  # or :rotation, :scale
            times=Float32[0, 0.5, 1.0],
            values=[Vec3d(0,0,0), Vec3d(0,1,0), Vec3d(0,0,0)],
            interpolation=INTERP_LINEAR  # INTERP_STEP, INTERP_LINEAR, INTERP_CUBICSPLINE
        )],
        duration=1.0f0
    )],
    active_clip=1,
    playing=true,
    looping=true,
    speed=1.0f0
)`

const audioCode = `# Listener (one per scene, follows camera)
AudioListenerComponent(gain=1.0f0)

# Source (3D positional)
AudioSourceComponent(
    audio_path="sounds/explosion.wav",
    playing=true,
    looping=false,
    gain=0.8f0,
    pitch=1.0f0,
    spatial=true,
    reference_distance=1.0f0,
    max_distance=50.0f0,
    rolloff_factor=1.0f0
)`

const skeletonCode = `# Bone (one per joint in the skeleton)
BoneComponent(
    inverse_bind_matrix=Mat4f(I),
    bone_index=0,
    name="spine"
)

# Skinned mesh (links mesh to bones)
SkinnedMeshComponent(
    bone_entities=EntityID[...],
    bone_matrices=Mat4f[...]
)`

const particleCode = `ParticleSystemComponent(
    emission_rate=50.0f0,
    max_particles=1000,
    lifetime_min=0.5f0,
    lifetime_max=2.0f0,
    velocity_min=Vec3f(-1, 2, -1),
    velocity_max=Vec3f(1, 5, 1),
    gravity_modifier=1.0f0,    # multiplier on (0, -9.81, 0)
    damping=0.98f0,
    start_size_min=0.1f0,
    start_size_max=0.3f0,
    end_size=0.0f0,
    start_color=RGB{Float32}(1, 0.5, 0),
    end_color=RGB{Float32}(1, 0, 0),
    start_alpha=1.0f0,
    end_alpha=0.0f0,
    additive=false
)`

const playerCode = `PlayerComponent(
    move_speed=5.0f0,
    sprint_multiplier=2.0f0,
    mouse_sensitivity=0.002f0
)
# Enables FPS controls automatically:
# WASD, mouse look, Space/Ctrl, Shift sprint

# Or use create_player() for a ready-made entity:
create_player(position=Vec3d(0, 2, 5))`

const components = [
  { id: 'transform', title: 'TransformComponent', code: transformCode, desc: 'Position, rotation, and scale with Observable reactivity. Uses Float64 for CPU-side precision. Parent-child transform inheritance is handled automatically by the scene graph.' },
  { id: 'mesh', title: 'MeshComponent', code: meshCode, desc: 'Vertex geometry data. Use the built-in primitives or supply custom positions, normals, UVs, and indices. Supports bone weights and bone indices for skeletal animation.' },
  { id: 'material', title: 'MaterialComponent', code: materialCode, desc: 'PBR material with full texture support. Includes advanced features: clear coat for lacquered surfaces, parallax occlusion mapping for depth, and subsurface scattering for translucent materials.' },
  { id: 'camera', title: 'CameraComponent', code: cameraCode, desc: 'Perspective camera with configurable field of view, clipping planes, and aspect ratio.' },
  { id: 'lights', title: 'Light Components', code: lightsCode, desc: 'Three light types: DirectionalLight for sun-like illumination, PointLight for local light sources, and IBL for image-based environment lighting.' },
  { id: 'collider', title: 'ColliderComponent', code: colliderCode, desc: 'Collision shape attached to an entity. Supports AABB, Sphere, Capsule, OBB, ConvexHull, Compound, and Heightmap shapes. Set is_trigger=true for non-physical event volumes.' },
  { id: 'rigidbody', title: 'RigidBodyComponent', code: rigidbodyCode, desc: 'Physics body with mass, damping, restitution, and friction. Three body types: STATIC (immovable), KINEMATIC (script-driven), DYNAMIC (physics-driven). Float64 precision for stable long simulations.' },
  { id: 'animation', title: 'AnimationComponent', code: animationCode, desc: 'Keyframe animation with clips and channels. Each channel targets an entity property (position, rotation, or scale) with step, linear, or cubic spline interpolation.' },
  { id: 'audio', title: 'Audio Components', code: audioCode, desc: 'OpenAL-based 3D positional audio. AudioListenerComponent follows the camera; AudioSourceComponent emits sound from entity positions with configurable attenuation.' },
  { id: 'skeleton', title: 'Skeleton Components', code: skeletonCode, desc: 'BoneComponent represents a joint in the skeleton hierarchy. SkinnedMeshComponent links a mesh to its bones. Bone matrices are updated each frame during the skinning system pass.' },
  { id: 'particle', title: 'ParticleSystemComponent', code: particleCode, desc: 'CPU-simulated billboard particles with emission rate, lifetime, velocity ranges, gravity, damping, and color/size interpolation over lifetime.' },
  { id: 'player', title: 'PlayerComponent', code: playerCode, desc: 'FPS-style player controller. When present in the scene, the render loop automatically enables WASD movement, mouse look, sprinting, and cursor capture.' },
]
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Components Reference</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        Components are plain Julia structs that attach data to entities.
        All components subtype <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Component</code>.
      </p>
    </div>

    <!-- Quick nav -->
    <nav class="flex flex-wrap gap-2">
      <a
        v-for="c in components"
        :key="c.id"
        :href="`#${c.id}`"
        class="px-2 py-1 text-xs font-mono rounded border border-or-border text-or-text-dim hover:text-or-green hover:border-or-green/50 transition-colors"
      >
        {{ c.title }}
      </a>
    </nav>

    <!-- Component sections -->
    <section v-for="c in components" :key="c.id" :id="c.id" class="scroll-mt-20">
      <h2 class="text-xl font-mono font-bold text-or-text mb-3">
        <span class="text-or-green">#</span> {{ c.title }}
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">{{ c.desc }}</p>
      <CodeBlock :code="c.code" lang="julia" :filename="c.id + '.jl'" />
    </section>
  </div>
</template>
