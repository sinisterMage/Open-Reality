# Script component for attaching lifecycle callbacks to entities

"""
    ScriptComponent <: Component

Attaches lifecycle callbacks to an entity. The callbacks are:
- `on_start(entity_id, ctx)` — called once on the first `update_scripts!` tick
- `on_update(entity_id, dt, ctx)` — called every `update_scripts!` tick
- `on_destroy(entity_id, ctx)` — called when `destroy_entity!` removes the entity;
  `ctx` is a real `GameContext` when destroyed via `despawn!` → `apply_mutations!`,
  and `nothing` when called from `destroy_entity!` without an explicit `ctx` kwarg
  (e.g. during scene switches)
"""
mutable struct ScriptComponent <: Component
    on_start::Union{Function, Nothing}
    on_update::Union{Function, Nothing}
    on_destroy::Union{Function, Nothing}
    _started::Bool

    ScriptComponent(;
        on_start::Union{Function, Nothing} = nothing,
        on_update::Union{Function, Nothing} = nothing,
        on_destroy::Union{Function, Nothing} = nothing
    ) = new(on_start, on_update, on_destroy, false)
end
