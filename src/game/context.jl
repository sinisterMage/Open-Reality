# GameContext — deferred spawn/despawn command buffer for gameplay scripts

"""
    GameContext

Mutable game context that holds the current scene, input state, and
deferred spawn/despawn queues.  Gameplay scripts enqueue mutations via
`spawn!` and `despawn!`; the engine flushes them once per frame with
`apply_mutations!`.
"""
mutable struct GameContext
    scene::Scene
    input::InputState
    _spawn_queue::Vector{Tuple{EntityID, EntityDef}}
    _despawn_queue::Vector{EntityID}

    function GameContext(scene::Scene, input::InputState)
        new(scene, input, Tuple{EntityID, EntityDef}[], EntityID[])
    end
end

"""
    spawn!(ctx::GameContext, entity_def::EntityDef) -> EntityID

Enqueue a new entity for deferred spawning.  Returns the pre-allocated
`EntityID` immediately so callers can reference it before the next
`apply_mutations!` flush.
"""
function spawn!(ctx::GameContext, entity_def::EntityDef)::EntityID
    eid = create_entity!(World())
    push!(ctx._spawn_queue, (eid, entity_def))
    return eid
end

"""
    despawn!(ctx::GameContext, entity_id::EntityID)

Enqueue an entity for deferred removal.  The entity (and its descendants)
will be destroyed on the next `apply_mutations!` call.
"""
function despawn!(ctx::GameContext, entity_id::EntityID)
    push!(ctx._despawn_queue, entity_id)
    return nothing
end

"""
    apply_mutations!(ctx::GameContext, scene::Scene) -> Scene

Flush all queued spawns and despawns, returning the updated `Scene`.
Despawns are processed first so that recycled IDs cannot collide with
pending spawns.
"""
function apply_mutations!(ctx::GameContext, scene::Scene)::Scene
    # --- despawns ---
    for eid in ctx._despawn_queue
        scene = destroy_entity!(scene, eid; ctx=ctx)
    end

    # --- spawns ---
    for (eid, entity_def) in ctx._spawn_queue
        # Register components in ECS
        for comp in entity_def.components
            if comp isa Component
                add_component!(eid, comp)
            end
        end

        # Add the root entity to the scene graph (no parent)
        scene = add_entity(scene, eid, nothing)

        # Recursively add children via the existing helper
        for child_def in entity_def.children
            if child_def isa EntityDef
                scene = add_entity_from_def(scene, child_def, eid)
            end
        end
    end

    # Clear queues
    empty!(ctx._spawn_queue)
    empty!(ctx._despawn_queue)

    return scene
end

"""
    spawn!(ctx::GameContext, prefab::Prefab; kwargs...) -> EntityID

Instantiate a `Prefab` with the given keyword overrides and enqueue the
resulting entity for deferred spawning.  Keyword arguments are forwarded
to the prefab's factory via `instantiate`.
"""
function spawn!(ctx::GameContext, prefab::Prefab; kwargs...)::EntityID
    entity_def = instantiate(prefab; kwargs...)
    return spawn!(ctx, entity_def)
end
