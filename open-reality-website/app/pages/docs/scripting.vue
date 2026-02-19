<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Scripting Guide - OpenReality Docs',
  ogTitle: 'Scripting Guide - OpenReality Docs',
  description: 'ScriptComponent lifecycle callbacks, error budgets, and CollisionCallbackComponent for entity scripting in OpenReality.',
  ogDescription: 'ScriptComponent lifecycle callbacks, error budgets, and CollisionCallbackComponent for entity scripting in OpenReality.',
})

const scriptCode = `ScriptComponent(
    on_start  = (entity_id, ctx) -> ...,  # called once on first tick
    on_update = (entity_id, dt, ctx) -> ...,  # called every frame
    on_destroy = (entity_id, ctx) -> ...  # called on entity removal
)

# ctx is a GameContext when destroyed via despawn! → apply_mutations!
# ctx is nothing when destroyed via destroy_entity! (e.g. scene switches)`

const errorBudgetCode = `# Each ScriptComponent tracks its own error count.
# After 5 errors (default), callbacks are auto-disabled.
# Adjust the global budget:
SCRIPT_ERROR_BUDGET[] = 10   # allow 10 errors per script
SCRIPT_ERROR_BUDGET[] = 0    # disable the budget (infinite errors)

# Internal fields (read-only):
# script._error_count  — current accumulated errors
# script._disabled     — true when budget exceeded`

const rotatingCubeCode = `# A cube that rotates 90°/sec around the Y axis
entity([
    transform(position=Vec3d(0, 1, 0)),
    cube_mesh(),
    MaterialComponent(color=RGB{Float32}(0.2, 0.6, 1.0)),
    ScriptComponent(
        on_start = (eid, ctx) -> begin
            @info "Cube \$eid started!"
        end,
        on_update = (eid, dt, ctx) -> begin
            tc = get_component(eid, TransformComponent)
            if tc !== nothing
                angle = dt * π / 2  # 90°/sec
                q = Quaterniond(cos(angle/2), 0, sin(angle/2), 0)
                tc.rotation[] = tc.rotation[] * q
            end
        end,
        on_destroy = (eid, ctx) -> begin
            @info "Cube \$eid destroyed!"
        end
    )
])`

const callbackSignaturesCode = `# on_start(entity_id::EntityID, ctx)
#   Called once on the first update_scripts! tick.
#   ctx is a GameContext (or nothing if no FSM).

# on_update(entity_id::EntityID, dt::Float64, ctx)
#   Called every frame during update_scripts!.
#   dt is the frame delta time in seconds.

# on_destroy(entity_id::EntityID, ctx)
#   Called when the entity is removed from the scene.
#   ctx is GameContext when using despawn!/apply_mutations!,
#   nothing when using destroy_entity! directly.`

const collisionCallbackCode = `CollisionCallbackComponent(
    on_collision_enter = (this_entity, other_entity, manifold) -> ...,
    on_collision_stay  = (this_entity, other_entity, manifold) -> ...,
    on_collision_exit  = (this_entity, other_entity, manifold) -> ...
)

# manifold is Union{ContactManifold, Nothing}
#   — contains contact points and normals for enter/stay
#   — nothing for exit events`

const collisionExampleCode = `# A pickup item that despawns on contact
entity([
    transform(position=Vec3d(3, 0.5, 0)),
    sphere_mesh(),
    MaterialComponent(color=RGB{Float32}(1.0, 0.84, 0.0)),
    ColliderComponent(shape=SphereShape(0.5f0), is_trigger=true),
    RigidBodyComponent(body_type=BODY_STATIC),
    CollisionCallbackComponent(
        on_collision_enter = (this_eid, other_eid, manifold) -> begin
            @info "Pickup collected by entity \$other_eid"
            # Despawn via GameContext if available:
            # despawn!(ctx, this_eid)
        end
    )
])`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Scripting Guide</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        Attach gameplay logic to entities using <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">ScriptComponent</code>
        lifecycle callbacks and <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">CollisionCallbackComponent</code> for
        collision events.
      </p>
    </div>

    <!-- ScriptComponent -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> ScriptComponent
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">ScriptComponent</code> attaches
        three lifecycle callbacks to an entity: <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">on_start</code>,
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">on_update</code>, and
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">on_destroy</code>.
        All callbacks are optional &mdash; only provide the ones you need.
      </p>
      <CodeBlock :code="scriptCode" lang="julia" filename="script_component.jl" />
    </section>

    <!-- Callback Signatures -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Callback Signatures
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Each callback receives the entity ID and a context object. The <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">on_update</code>
        callback additionally receives the frame delta time.
      </p>
      <CodeBlock :code="callbackSignaturesCode" lang="julia" filename="signatures.jl" />
    </section>

    <!-- Error Budget -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Error Budget
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Scripts that throw exceptions accumulate an error count. After exceeding the budget (default: 5 errors),
        the script's callbacks are automatically disabled to prevent log spam and performance degradation.
      </p>
      <CodeBlock :code="errorBudgetCode" lang="julia" filename="error_budget.jl" />
    </section>

    <!-- Example: Rotating Cube -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Example: Rotating Cube
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        A complete example attaching a script that rotates a cube around the Y axis at 90 degrees per second.
      </p>
      <CodeBlock :code="rotatingCubeCode" lang="julia" filename="rotating_cube.jl" />
    </section>

    <!-- CollisionCallbackComponent -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> CollisionCallbackComponent
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">CollisionCallbackComponent</code>
        provides enter/stay/exit collision events. The engine tracks collision pairs across frames using a
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">CollisionEventCache</code>
        to determine transitions.
      </p>
      <CodeBlock :code="collisionCallbackCode" lang="julia" filename="collision_callback.jl" />
    </section>

    <!-- Example: Collision Detection -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Example: Collision Detection
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        A pickup item that logs a message when another entity enters its trigger volume.
      </p>
      <CodeBlock :code="collisionExampleCode" lang="julia" filename="collision_example.jl" />
    </section>
  </div>
</template>
