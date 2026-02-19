<script setup lang="ts">
const heroCode = `using OpenReality

s = scene([
    entity([
        transform(position=Vec3d(0, 3, 8)),
        CameraComponent(fov=60.0)
    ]),
    entity([
        DirectionalLightComponent(
            direction=Vec3f(-0.5, -1, -0.3),
            intensity=2.0f0
        )
    ]),
    entity([
        transform(position=Vec3d(0, 5, 0)),
        cube_mesh(),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.8, 0.4),
            metallic=0.3f0
        ),
        ColliderComponent(shape=AABBShape()),
        RigidBodyComponent(body_type=BODY_DYNAMIC)
    ]),
])

render(s, backend=VulkanBackend())`
</script>

<template>
  <section class="relative overflow-hidden">
    <div class="absolute inset-0 bg-[linear-gradient(rgba(0,255,159,0.03)_1px,transparent_1px),linear-gradient(90deg,rgba(0,255,159,0.03)_1px,transparent_1px)] bg-[size:50px_50px]" />

    <div class="relative max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-24 lg:py-32">
      <div class="grid lg:grid-cols-2 gap-12 items-center">
        <div>
          <div class="inline-flex items-center gap-2 px-3 py-1 rounded-full border border-or-border text-or-text-dim text-xs font-mono mb-6">
            <span class="w-2 h-2 rounded-full bg-or-green animate-pulse" />
            v0.1 &mdash; 938 tests passing
          </div>

          <h1 class="text-4xl sm:text-5xl lg:text-6xl font-bold font-mono leading-tight">
            <span class="text-or-green">&gt;</span> Open<br />
            <span class="text-or-text">Reality</span>
          </h1>

          <p class="text-or-text-dim text-lg mt-6 max-w-lg leading-relaxed">
            A declarative, code-first game engine built in Julia.
            ECS architecture. Immutable scene graph. Four rendering backends.
          </p>

          <div class="flex flex-wrap gap-4 mt-8">
            <NuxtLink
              to="/docs"
              class="px-6 py-3 bg-or-green text-or-bg font-mono font-bold rounded hover:shadow-glow-green transition-all"
            >
              Get Started
            </NuxtLink>
            <a
              href="https://github.com/sinisterMage/Open-Reality"
              target="_blank"
              class="px-6 py-3 border border-or-border text-or-text font-mono rounded hover:border-or-green hover:text-or-green transition-all"
            >
              View Source
            </a>
          </div>
        </div>

        <div class="lg:pl-4">
          <CodeBlock :code="heroCode" lang="julia" filename="game.jl" />
        </div>
      </div>
    </div>
  </section>
</template>
