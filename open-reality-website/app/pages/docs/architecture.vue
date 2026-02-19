<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Architecture - OpenReality Docs',
  ogTitle: 'Architecture - OpenReality Docs',
  description: 'Learn about OpenReality\'s ECS architecture, immutable scene graph, systems pipeline, and multi-backend rendering abstraction.',
  ogDescription: 'Learn about OpenReality\'s ECS architecture, immutable scene graph, systems pipeline, and multi-backend rendering abstraction.',
})

const ecsCode = `# Create entities and add components
entity_id = create_entity_id()
add_component!(entity_id, TransformComponent(position=Vec3d(1, 2, 3)))
add_component!(entity_id, MeshComponent(...))

# Query components
transform = get_component(entity_id, TransformComponent)
has_component(entity_id, MeshComponent)  # true

# Iterate all entities with a component type
iterate_components(TransformComponent) do entity_id, transform
    println("Entity \$entity_id at \$(transform.position[])")
end`

const sceneCode = `# Declarative scene construction
s = scene([
    entity([
        transform(position=Vec3d(0, 0, 0)),
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(1, 0, 0))
    ], children=[
        entity([
            transform(position=Vec3d(2, 0, 0)),
            sphere_mesh(),
            MaterialComponent(metallic=1.0f0)
        ]),
        entity([
            transform(position=Vec3d(-2, 0, 0)),
            sphere_mesh(),
            MaterialComponent(roughness=0.1f0)
        ])
    ]),
    entity([CameraComponent(fov=60.0)]),
])`

const traversalCode = `# Depth-first traversal
traverse_scene(s) do entity_id
    println(entity_id)
end

# With depth tracking
traverse_scene_with_depth(s) do entity_id, depth
    println("  " ^ depth, entity_id)
end

# Query hierarchy
children = get_children(s, parent_id)
parent = get_parent(s, child_id)
ancestors = get_ancestors(s, entity_id)`

const renderCode = `# Render with default OpenGL backend
render(s)

# Render with specific backend and options
render(s,
    backend=VulkanBackend(),
    width=1920,
    height=1080,
    title="My Game",
    post_process=PostProcessConfig(
        bloom_enabled=true,
        tone_mapping=TONEMAP_ACES
    )
)`

const systemsCode = `# The render loop runs these systems automatically:
# 1. clear_world_transform_cache!()
# 2. update_player!(controller, input, dt)
# 3. update_camera_controllers!(scene, dt)
# 4. update_animations!(dt)
# 5. update_blend_trees!(dt)
# 6. update_skinned_meshes!()
# 7. update_physics!(dt)
# 8. update_scripts!(scene, dt, ctx)
# 9. update_audio!(dt)
# 10. update_particles!(dt)
# 11. render_frame!(backend, scene)`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Architecture</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        OpenReality is built on three core abstractions: an Entity Component System for data,
        an immutable Scene graph for structure, and a Systems pipeline for behavior.
      </p>
    </div>

    <!-- ECS -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Entity Component System
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Every game object is an <strong class="text-or-text">EntityID</strong> (a unique <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">UInt64</code>).
        Behavior and data are attached as <strong class="text-or-text">Components</strong> &mdash; plain Julia structs that subtype <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Component</code>.
        Components are stored in type-specific <strong class="text-or-text">ComponentStores</strong> with contiguous arrays for cache-friendly iteration.
      </p>
      <div class="mb-4 p-4 rounded-lg border border-or-border bg-or-surface">
        <h4 class="font-mono text-sm font-bold text-or-text mb-2">Key properties:</h4>
        <ul class="space-y-1 text-sm text-or-text-dim">
          <li><span class="text-or-green">&#8226;</span> O(1) component lookup via EntityID &rarr; index mapping</li>
          <li><span class="text-or-green">&#8226;</span> O(1) removal via swap-and-pop deletion</li>
          <li><span class="text-or-green">&#8226;</span> Non-allocating iteration over all instances of a component type</li>
          <li><span class="text-or-green">&#8226;</span> Global registry &mdash; components are accessible from anywhere</li>
        </ul>
      </div>
      <CodeBlock :code="ecsCode" lang="julia" filename="ecs.jl" />
    </section>

    <!-- Scene Graph -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Immutable Scene Graph
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Scenes are <strong class="text-or-text">immutable structs</strong>. All mutations return a new <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Scene</code> instance.
        The declarative <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">scene([entity([...])])</code> DSL builds the entire hierarchy in one expression,
        automatically creating entities, registering components, and establishing parent-child relationships.
      </p>
      <CodeBlock :code="sceneCode" lang="julia" filename="scene.jl" />
    </section>

    <!-- Traversal -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Scene Traversal
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Traverse the scene graph depth-first, query parent-child relationships,
        or collect all descendants of a subtree.
      </p>
      <CodeBlock :code="traversalCode" lang="julia" filename="traversal.jl" />
    </section>

    <!-- Systems Pipeline -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Systems Pipeline
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Each frame, the engine runs a fixed sequence of systems. These operate on components
        in the ECS store, updating transforms, physics, animation, audio, and particles before rendering.
      </p>
      <CodeBlock :code="systemsCode" lang="julia" filename="pipeline.jl" />
    </section>

    <!-- Backend Abstraction -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Backend Abstraction
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        All rendering backends implement <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">AbstractBackend</code>.
        Switching backends is a one-line change &mdash; the rest of the engine is backend-agnostic.
      </p>
      <CodeBlock :code="renderCode" lang="julia" filename="render.jl" />

      <div class="mt-4 grid sm:grid-cols-2 gap-4">
        <div class="p-4 rounded-lg border border-or-border bg-or-surface">
          <h4 class="font-mono text-sm font-bold text-or-text">OpenGLBackend</h4>
          <p class="text-or-text-dim text-sm mt-1">OpenGL 3.3 core profile. Works on all platforms. Default backend.</p>
        </div>
        <div class="p-4 rounded-lg border border-or-border bg-or-surface">
          <h4 class="font-mono text-sm font-bold text-or-text">VulkanBackend</h4>
          <p class="text-or-text-dim text-sm mt-1">Full deferred PBR, CSM, IBL, SSAO, SSR, TAA. Linux and Windows.</p>
        </div>
        <div class="p-4 rounded-lg border border-or-border bg-or-surface">
          <h4 class="font-mono text-sm font-bold text-or-text">MetalBackend</h4>
          <p class="text-or-text-dim text-sm mt-1">Native macOS Metal API via FFI bridge.</p>
        </div>
        <div class="p-4 rounded-lg border border-or-border bg-or-surface">
          <h4 class="font-mono text-sm font-bold text-or-text">WebGPUBackend</h4>
          <p class="text-or-text-dim text-sm mt-1">Browser-ready via Rust FFI and WASM export.</p>
        </div>
      </div>
    </section>
  </div>
</template>
