<script setup lang="ts">
useSeoMeta({
  title: 'OpenReality - Declarative Julia Game Engine',
  ogTitle: 'OpenReality - Declarative Julia Game Engine',
  description: 'A declarative, code-first game engine built in Julia. ECS architecture, immutable scene graph, PBR rendering, physics engine, and 4 GPU backends.',
  ogDescription: 'A declarative, code-first game engine built in Julia. ECS architecture, immutable scene graph, PBR rendering, physics engine, and 4 GPU backends.',
  twitterCard: 'summary_large_image',
})

const features = [
  {
    tag: 'ECS',
    title: 'Entity Component System',
    description: 'Compose game objects from reusable components. Functional, immutable scene graph with declarative DSL.',
  },
  {
    tag: 'GPU',
    title: '4 Rendering Backends',
    description: 'OpenGL 3.3, Metal, Vulkan, and WebGPU. Choose the right backend for your platform.',
  },
  {
    tag: 'PHY',
    title: 'Physics Engine',
    description: 'Impulse-based PGS solver with GJK+EPA collision, joints, CCD, and spatial hash broadphase.',
  },
  {
    tag: 'PBR',
    title: 'PBR Pipeline',
    description: 'Deferred rendering with CSM shadows, IBL, SSAO, SSR, TAA, bloom, and tone mapping.',
  },
  {
    tag: 'ANI',
    title: 'Animation System',
    description: 'Keyframe and skeletal animation with glTF 2.0 loading. Vertex skinning computed in shaders.',
  },
  {
    tag: 'SND',
    title: '3D Positional Audio',
    description: 'OpenAL backend with AudioListener and AudioSource components. Spatial attenuation built in.',
  },
  {
    tag: 'WEB',
    title: 'WASM Export',
    description: 'Export scenes to .orsb binary format. Run in browsers via the WebGPU runtime.',
  },
  {
    tag: 'CLI',
    title: 'Developer Tooling',
    description: 'Rust TUI dashboard, Bazel monorepo management, 938 tests. Built for real development.',
  },
]

const physicsCode = `# Add physics to any entity
entity([
    transform(position=Vec3d(0, 10, 0)),
    sphere_mesh(),
    MaterialComponent(
        color=RGB{Float32}(0.9, 0.3, 0.1),
        roughness=0.4f0
    ),
    ColliderComponent(shape=SphereShape(1.0f0)),
    RigidBodyComponent(
        body_type=BODY_DYNAMIC,
        mass=2.0,
        restitution=0.7
    )
])`

const postprocessCode = `# Full post-processing pipeline
render(s,
    backend=OpenGLBackend(),
    post_process=PostProcessConfig(
        bloom_enabled=true,
        bloom_threshold=1.0f0,
        tone_mapping=TONEMAP_ACES,
        fxaa_enabled=true
    )
)`

const sceneCode = `# Declarative scene with hierarchy
s = scene([
    entity([
        transform(position=Vec3d(0, 0, 0)),
        cube_mesh(),
        MaterialComponent(
            albedo_map=TextureRef("wood.png"),
            normal_map=TextureRef("wood_n.png"),
            roughness=0.6f0
        )
    ], children=[
        entity([
            transform(position=Vec3d(0, 2, 0)),
            sphere_mesh(),
            MaterialComponent(
                color=RGB{Float32}(1, 0.8, 0),
                metallic=1.0f0,
                roughness=0.1f0
            )
        ])
    ])
])`

const installCode = `# Clone the repository
git clone https://github.com/sinisterMage/Open-Reality.git
cd OpenReality

# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run the test suite
julia --project=. -e 'using Pkg; Pkg.test()'`
</script>

<template>
  <div>
    <!-- Hero -->
    <HeroSection />

    <!-- Stats -->
    <section class="border-y border-or-border bg-or-surface">
      <div class="max-w-7xl mx-auto px-4 grid grid-cols-2 md:grid-cols-4 divide-x divide-or-border">
        <StatBadge value="938" label="Tests Passing" />
        <StatBadge value="4" label="Render Backends" />
        <StatBadge value="ECS" label="Architecture" />
        <StatBadge value="PBR" label="Full Pipeline" />
      </div>
    </section>

    <!-- Features -->
    <section id="features" class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-24">
      <div class="text-center mb-12">
        <h2 class="text-3xl font-mono font-bold text-or-text">
          <span class="text-or-green">#</span> Features
        </h2>
        <p class="text-or-text-dim mt-3 max-w-2xl mx-auto">
          Everything you need to build 3D applications, from rendering to physics to audio.
        </p>
      </div>
      <div class="grid md:grid-cols-2 lg:grid-cols-4 gap-4">
        <FeatureCard
          v-for="f in features"
          :key="f.title"
          :tag="f.tag"
          :title="f.title"
          :description="f.description"
        />
      </div>
    </section>

    <!-- Architecture -->
    <section class="border-y border-or-border bg-or-surface py-24">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div class="text-center mb-12">
          <h2 class="text-3xl font-mono font-bold text-or-text">
            <span class="text-or-green">#</span> Architecture
          </h2>
          <p class="text-or-text-dim mt-3 max-w-2xl mx-auto">
            A clean pipeline from declarative scene definition to GPU rendering.
          </p>
        </div>
        <div class="max-w-3xl mx-auto">
          <TerminalWindow title="architecture">
            <pre class="font-mono text-sm leading-relaxed">
<span class="text-or-green">Scene DSL</span>        <span class="text-or-text-dim">──▶</span>  <span class="text-or-cyan">ECS Store</span>       <span class="text-or-text-dim">──▶</span>  <span class="text-or-amber">Systems</span>          <span class="text-or-text-dim">──▶</span>  <span class="text-or-green">Backend</span>

<span class="text-or-text-dim">scene([</span>              EntityID +         Physics             OpenGL 3.3
<span class="text-or-text-dim">  entity([...])</span>       Components         Animation            Metal
<span class="text-or-text-dim">  entity([...])</span>       ComponentStore     Skinning             Vulkan
<span class="text-or-text-dim">])</span>                                        Audio               WebGPU
                                        Particles
                                        <span class="text-or-text-dim">───────────</span>
                                        Rendering
                                         ├─ Deferred PBR
                                         ├─ CSM Shadows
                                         ├─ Post-processing
                                         └─ Frustum Culling</pre>
          </TerminalWindow>
        </div>
      </div>
    </section>

    <!-- Code Examples -->
    <section id="examples" class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-24">
      <div class="text-center mb-12">
        <h2 class="text-3xl font-mono font-bold text-or-text">
          <span class="text-or-green">#</span> Code Examples
        </h2>
        <p class="text-or-text-dim mt-3 max-w-2xl mx-auto">
          Expressive, declarative API. Build scenes with composable components.
        </p>
      </div>

      <div class="space-y-16">
        <!-- Scene hierarchy -->
        <div class="grid lg:grid-cols-2 gap-8 items-start">
          <div>
            <h3 class="font-mono font-bold text-or-text text-xl mb-3">Hierarchical Scenes</h3>
            <p class="text-or-text-dim leading-relaxed mb-4">
              Build scene graphs with parent-child relationships. Child transforms inherit from parents automatically.
              Materials support full PBR with texture maps, normal maps, and metallic-roughness workflows.
            </p>
            <ul class="space-y-2 text-sm text-or-text-dim">
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> Immutable, functional scene graph
              </li>
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> Automatic transform propagation
              </li>
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> glTF 2.0 + OBJ model loading
              </li>
            </ul>
          </div>
          <CodeBlock :code="sceneCode" lang="julia" filename="scene.jl" />
        </div>

        <!-- Physics -->
        <div class="grid lg:grid-cols-2 gap-8 items-start">
          <CodeBlock :code="physicsCode" lang="julia" filename="physics.jl" />
          <div>
            <h3 class="font-mono font-bold text-or-text text-xl mb-3">Built-in Physics</h3>
            <p class="text-or-text-dim leading-relaxed mb-4">
              Add rigid body dynamics to any entity with just two components.
              The physics engine handles collision detection, resolution, and constraint solving automatically.
            </p>
            <ul class="space-y-2 text-sm text-or-text-dim">
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> 7 collision shapes including convex hulls
              </li>
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> GJK+EPA narrowphase detection
              </li>
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> Joint constraints and triggers
              </li>
            </ul>
          </div>
        </div>

        <!-- Post-processing -->
        <div class="grid lg:grid-cols-2 gap-8 items-start">
          <div>
            <h3 class="font-mono font-bold text-or-text text-xl mb-3">Post-Processing</h3>
            <p class="text-or-text-dim leading-relaxed mb-4">
              HDR rendering pipeline with configurable post-processing.
              Choose between Reinhard, ACES, and Uncharted 2 tone mapping, add bloom, FXAA, and more.
            </p>
            <ul class="space-y-2 text-sm text-or-text-dim">
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> HDR framebuffer with bloom
              </li>
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> SSAO, SSR, TAA
              </li>
              <li class="flex items-center gap-2">
                <span class="text-or-green">&#10003;</span> Depth of field and motion blur
              </li>
            </ul>
          </div>
          <CodeBlock :code="postprocessCode" lang="julia" filename="render.jl" />
        </div>
      </div>
    </section>

    <!-- Getting Started -->
    <section class="border-t border-or-border bg-or-surface py-24">
      <div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8">
        <div class="text-center mb-12">
          <h2 class="text-3xl font-mono font-bold text-or-text">
            <span class="text-or-green">#</span> Get Started
          </h2>
          <p class="text-or-text-dim mt-3">
            Clone, install, and run in three commands.
          </p>
        </div>
        <CodeBlock :code="installCode" lang="bash" filename="terminal" />
        <div class="text-center mt-8">
          <NuxtLink
            to="/docs"
            class="inline-block px-8 py-3 bg-or-green text-or-bg font-mono font-bold rounded hover:shadow-glow-green transition-all"
          >
            Read the Docs
          </NuxtLink>
        </div>
      </div>
    </section>
  </div>
</template>
