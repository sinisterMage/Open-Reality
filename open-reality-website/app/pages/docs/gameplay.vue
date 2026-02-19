<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Gameplay Systems - OpenReality Docs',
  ogTitle: 'Gameplay Systems - OpenReality Docs',
  description: 'GameStateMachine, GameContext, Prefabs, EventBus, and scene switching for building game logic in OpenReality.',
  ogDescription: 'GameStateMachine, GameContext, Prefabs, EventBus, and scene switching for building game logic in OpenReality.',
})

const fsmCode = `# Define your game states by subtyping GameState
struct MenuState <: GameState end
struct PlayState <: GameState end
struct PauseState <: GameState end

# Create the FSM with an initial state and scene
fsm = GameStateMachine(:menu, menu_scene_defs)
fsm.states[:menu] = MenuState()
fsm.states[:play] = PlayState()
fsm.states[:pause] = PauseState()`

const stateCallbacksCode = `# Override these for each concrete state type:

# Called when entering this state (scene is already built)
on_enter!(state::PlayState, sc::Scene) = begin
    @info "Entering play state"
end

# Called every frame — return StateTransition to switch states
on_update!(state::PlayState, sc::Scene, dt::Float64, ctx::GameContext) = begin
    if should_pause()
        return StateTransition(:pause)
    end
    return nothing  # stay in current state
end

# Called when leaving this state
on_exit!(state::PlayState, sc::Scene) = begin
    @info "Leaving play state"
end

# Optional: return a UI callback for this state
get_ui_callback(state::PlayState) = function(ui_ctx::UIContext)
    ui_text(ui_ctx, 10, 10, "Playing...")
end`

const contextCode = `# GameContext provides deferred entity creation/removal.
# Scripts receive it as the ctx parameter.

# Spawn a new entity (deferred until apply_mutations!)
new_id = spawn!(ctx, entity([
    transform(position=Vec3d(0, 5, 0)),
    cube_mesh(),
    MaterialComponent(color=RGB{Float32}(1, 0, 0))
]))

# Remove an entity (deferred until apply_mutations!)
despawn!(ctx, entity_id)

# The engine calls apply_mutations! once per frame
# to flush all queued spawns and despawns.
# Despawns are processed first, then spawns.`

const prefabCode = `# Define a reusable entity template
enemy_prefab = Prefab(; position=Vec3d(0,0,0), health=100) do (; position, health)
    entity([
        transform(; position),
        sphere_mesh(),
        MaterialComponent(color=RGB{Float32}(1, 0, 0)),
        ColliderComponent(shape=SphereShape(0.5f0)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0),
    ])
end

# Instantiate with default values
def = instantiate(enemy_prefab)

# Or override specific parameters
def = instantiate(enemy_prefab; position=Vec3d(10, 0, 5), health=200)

# Spawn via GameContext (preferred in scripts)
eid = spawn!(ctx, enemy_prefab; position=Vec3d(3, 0, 0))`

const eventBusCode = `# Define custom event types
struct EnemyDefeated <: GameEvent
    enemy_id::EntityID
    score::Int
end

struct LevelComplete <: GameEvent
    level::Int
    time_elapsed::Float64
end

# Subscribe to events
subscribe!(EnemyDefeated, function(event)
    @info "Enemy \$(event.enemy_id) defeated! +\$(event.score) pts"
end)

# Emit events from anywhere
emit!(EnemyDefeated(enemy_id, 50))

# Unsubscribe (pass the same function object)
handler = event -> handle_defeat(event)
subscribe!(EnemyDefeated, handler)
unsubscribe!(EnemyDefeated, handler)`

const sceneTransitionCode = `# Return a StateTransition from on_update! to switch states.
# Providing new_scene_defs rebuilds the scene entirely.

on_update!(state::MenuState, sc::Scene, dt::Float64, ctx::GameContext) = begin
    if start_pressed()
        # Switch to :play with a new scene
        return StateTransition(:play, [
            entity([
                transform(position=Vec3d(0, 0, 0)),
                plane_mesh(),
                MaterialComponent(color=RGB{Float32}(0.3, 0.3, 0.3)),
            ]),
            entity([
                transform(position=Vec3d(0, 2, 5)),
                CameraComponent(fov=60.0),
            ]),
        ])
    end
    return nothing
end

# Without new_scene_defs, the existing scene is preserved:
StateTransition(:pause)        # keep current scene
StateTransition(:play, defs)   # rebuild scene from defs`

const renderFsmCode = `# Launch the engine with an FSM-driven render loop
render(fsm;
    backend = OpenGLBackend(),
    width = 1280,
    height = 720,
    title = "My Game",
    post_process = PostProcessConfig(
        bloom_enabled=true,
        tone_mapping=TONEMAP_ACES
    )
)

# The render loop automatically:
# 1. Calls on_enter! for the initial state
# 2. Each frame: on_update! → check for StateTransition
# 3. On transition: on_exit!(old) → rebuild scene → on_enter!(new)
# 4. Passes get_ui_callback(state) to the UI overlay`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Gameplay Systems</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        OpenReality provides a <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">GameStateMachine</code>
        for managing game states, a <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">GameContext</code>
        for deferred entity mutations, <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Prefab</code> templates,
        and an <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">EventBus</code> for pub/sub messaging.
      </p>
    </div>

    <!-- GameStateMachine -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> GameStateMachine
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        The FSM manages distinct game states (menu, playing, paused, etc.).
        Define concrete states by subtyping <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">GameState</code>,
        register them with the machine, and let the render loop drive transitions.
      </p>
      <CodeBlock :code="fsmCode" lang="julia" filename="state_machine.jl" />
    </section>

    <!-- State Callbacks -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> State Callbacks
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Each state type can override four lifecycle hooks. Only override the ones you need &mdash;
        defaults are no-ops that return <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">nothing</code>.
      </p>
      <CodeBlock :code="stateCallbacksCode" lang="julia" filename="state_callbacks.jl" />
    </section>

    <!-- GameContext -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> GameContext
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">GameContext</code>
        provides a command buffer for deferred entity spawning and despawning. Scripts call
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">spawn!</code> and
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">despawn!</code> during
        the frame, and the engine flushes all mutations at once via
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">apply_mutations!</code>.
      </p>
      <CodeBlock :code="contextCode" lang="julia" filename="game_context.jl" />
    </section>

    <!-- Prefab -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Prefab
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        A <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">Prefab</code> wraps
        a factory function that returns an <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">EntityDef</code>.
        Use <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">instantiate</code> to create
        entity definitions with optional parameter overrides, or
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">spawn!</code> to instantiate
        and enqueue in one step.
      </p>
      <CodeBlock :code="prefabCode" lang="julia" filename="prefab.jl" />
    </section>

    <!-- EventBus -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> EventBus
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        The <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">EventBus</code> is a global
        pub/sub system for game events. Define event types by subtyping
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">GameEvent</code>, subscribe
        with callbacks, and emit from anywhere. Listener exceptions are caught and logged without
        stopping other listeners.
      </p>
      <CodeBlock :code="eventBusCode" lang="julia" filename="event_bus.jl" />
    </section>

    <!-- Scene Switching -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Scene Switching
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Return a <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">StateTransition</code>
        from <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">on_update!</code> to switch
        states. Providing <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">new_scene_defs</code>
        rebuilds the entire scene; omitting it preserves the current scene.
      </p>
      <CodeBlock :code="sceneTransitionCode" lang="julia" filename="scene_transition.jl" />
    </section>

    <!-- FSM-driven Render -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> FSM-driven Render Loop
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Pass the <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">GameStateMachine</code>
        to <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">render</code> to launch the
        engine with automatic state management, scene rebuilding, and UI overlay routing.
      </p>
      <CodeBlock :code="renderFsmCode" lang="julia" filename="render_fsm.jl" />
    </section>
  </div>
</template>
