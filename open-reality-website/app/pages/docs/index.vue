<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Getting Started - OpenReality Docs',
  ogTitle: 'Getting Started - OpenReality Docs',
  description: 'Install OpenReality, create your first scene, and render it with Julia. Prerequisites, setup guide, and first project walkthrough.',
  ogDescription: 'Install OpenReality, create your first scene, and render it with Julia. Prerequisites, setup guide, and first project walkthrough.',
})

const installCode = `# Clone the repository
git clone https://github.com/sinisterMage/Open-Reality.git
cd OpenReality

# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'`

const helloCode = `using OpenReality

s = scene([
    # Camera
    entity([
        transform(position=Vec3d(0, 2, 5)),
        CameraComponent(fov=60.0)
    ]),
    # Light
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0, -1, -0.5),
            intensity=1.5f0
        )
    ]),
    # A green cube
    entity([
        transform(),
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.8, 0.3),
            roughness=0.5f0
        )
    ]),
])

render(s)`

const testCode = `julia --project=. -e 'using Pkg; Pkg.test()'`

const runCode = `julia --project=. examples/hello_cube.jl`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Getting Started</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        Get OpenReality running on your machine and render your first scene.
      </p>
    </div>

    <!-- Prerequisites -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Prerequisites
      </h2>
      <ul class="space-y-2 text-or-text-dim">
        <li class="flex items-start gap-2">
          <span class="text-or-green mt-0.5">&#8226;</span>
          <span><strong class="text-or-text">Julia 1.10+</strong> &mdash; Install via <a href="https://julialang.org/downloads/" target="_blank" class="text-or-cyan hover:underline">julialang.org</a> or <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">juliaup</code></span>
        </li>
        <li class="flex items-start gap-2">
          <span class="text-or-green mt-0.5">&#8226;</span>
          <span><strong class="text-or-text">OpenGL 3.3+</strong> &mdash; Available on most modern GPUs. Metal and Vulkan backends available for macOS and Linux/Windows respectively.</span>
        </li>
        <li class="flex items-start gap-2">
          <span class="text-or-green mt-0.5">&#8226;</span>
          <span><strong class="text-or-text">Git</strong> &mdash; For cloning the repository.</span>
        </li>
      </ul>
    </section>

    <!-- Installation -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Installation
      </h2>
      <CodeBlock :code="installCode" lang="bash" filename="terminal" />
    </section>

    <!-- First scene -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Your First Scene
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Create a new file <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">hello.jl</code> in the project root with the following content:
      </p>
      <CodeBlock :code="helloCode" lang="julia" filename="hello.jl" />
      <p class="text-or-text-dim mt-4 leading-relaxed">
        This creates a scene with a camera, a directional light, and a green cube. The <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">render(s)</code> call opens a window and starts the render loop using the default OpenGL backend.
      </p>
    </section>

    <!-- Running -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Running
      </h2>
      <CodeBlock :code="runCode" lang="bash" filename="terminal" />
      <p class="text-or-text-dim mt-4 leading-relaxed">
        A window should appear rendering your scene. Close it to exit. Use WASD to move if a <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">PlayerComponent</code> is present.
      </p>
    </section>

    <!-- Testing -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Running Tests
      </h2>
      <CodeBlock :code="testCode" lang="bash" filename="terminal" />
      <p class="text-or-text-dim mt-4 leading-relaxed">
        The test suite covers ECS, scene graph, physics, rendering abstractions, audio, UI, skeletal animation, particles, and scene export. All 938 tests should pass.
      </p>
    </section>

    <!-- Next steps -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Next Steps
      </h2>
      <div class="grid sm:grid-cols-2 gap-4">
        <NuxtLink to="/docs/architecture" class="block p-4 rounded-lg border border-or-border bg-or-surface hover:border-or-green/50 transition-colors">
          <h4 class="font-mono font-bold text-or-text">Architecture</h4>
          <p class="text-or-text-dim text-sm mt-1">Learn about the ECS, scene graph, and rendering pipeline.</p>
        </NuxtLink>
        <NuxtLink to="/docs/components" class="block p-4 rounded-lg border border-or-border bg-or-surface hover:border-or-green/50 transition-colors">
          <h4 class="font-mono font-bold text-or-text">Components</h4>
          <p class="text-or-text-dim text-sm mt-1">Explore the 16+ built-in component types.</p>
        </NuxtLink>
        <NuxtLink to="/docs/physics" class="block p-4 rounded-lg border border-or-border bg-or-surface hover:border-or-green/50 transition-colors">
          <h4 class="font-mono font-bold text-or-text">Physics</h4>
          <p class="text-or-text-dim text-sm mt-1">Add rigid body dynamics and collision detection.</p>
        </NuxtLink>
        <NuxtLink to="/docs/rendering" class="block p-4 rounded-lg border border-or-border bg-or-surface hover:border-or-green/50 transition-colors">
          <h4 class="font-mono font-bold text-or-text">Rendering</h4>
          <p class="text-or-text-dim text-sm mt-1">Configure PBR, shadows, and post-processing.</p>
        </NuxtLink>
      </div>
    </section>
  </div>
</template>
