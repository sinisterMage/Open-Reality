# Trigger volumes with enter/stay/exit callbacks

"""
    TriggerComponent <: Component

Makes a collider act as a trigger volume. When other entities enter, stay in,
or exit the trigger volume, the corresponding callbacks are invoked.

The entity must also have a ColliderComponent with `is_trigger=true`.

Callbacks receive (trigger_entity_id, other_entity_id) as arguments.
"""
mutable struct TriggerComponent <: Component
    on_enter::Union{Function, Nothing}
    on_stay::Union{Function, Nothing}
    on_exit::Union{Function, Nothing}

    TriggerComponent(;
        on_enter::Union{Function, Nothing} = nothing,
        on_stay::Union{Function, Nothing} = nothing,
        on_exit::Union{Function, Nothing} = nothing
    ) = new(on_enter, on_stay, on_exit)
end

"""
    TriggerState

Tracks which entities are currently overlapping with trigger volumes.
Used to detect enter/exit transitions.
"""
mutable struct TriggerState
    # Key: trigger entity, Value: set of overlapping entities
    overlaps::Dict{EntityID, Set{EntityID}}
end

TriggerState() = TriggerState(Dict{EntityID, Set{EntityID}}())

# Global trigger state
const _TRIGGER_STATE = Ref{Union{TriggerState, Nothing}}(nothing)

function get_trigger_state()
    if _TRIGGER_STATE[] === nothing
        _TRIGGER_STATE[] = TriggerState()
    end
    return _TRIGGER_STATE[]
end

function reset_trigger_state!()
    _TRIGGER_STATE[] = nothing
end

"""
    update_triggers!()

Detect trigger overlaps and fire enter/stay/exit callbacks.
Called each physics step after broadphase.
"""
function update_triggers!()
    state = get_trigger_state()

    # Collect trigger entities
    trigger_entities = entities_with_component(TriggerComponent)
    if isempty(trigger_entities)
        return
    end

    # Collect all collidable (non-trigger) entities with their AABBs
    collidable = Tuple{EntityID, AABB3D}[]
    iterate_components(ColliderComponent) do eid, collider
        collider.is_trigger && return
        aabb = get_entity_physics_aabb(eid)
        aabb === nothing && return
        push!(collidable, (eid, aabb))
    end

    # For each trigger, test overlaps
    for trigger_eid in trigger_entities
        trigger_comp = get_component(trigger_eid, TriggerComponent)
        trigger_comp === nothing && continue
        trigger_collider = get_component(trigger_eid, ColliderComponent)
        trigger_collider === nothing && continue

        trigger_aabb = get_entity_physics_aabb(trigger_eid)
        trigger_aabb === nothing && continue

        current_overlaps = Set{EntityID}()

        for (other_eid, other_aabb) in collidable
            other_eid == trigger_eid && continue

            # Broadphase: AABB overlap
            if !aabb_overlap(trigger_aabb, other_aabb)
                continue
            end

            # Narrowphase: actual shape test
            manifold = collide(trigger_eid, other_eid)
            if manifold !== nothing
                push!(current_overlaps, other_eid)
            end
        end

        # Get previous overlaps
        prev_overlaps = get(state.overlaps, trigger_eid, Set{EntityID}())

        # Detect enter events
        for eid in current_overlaps
            if !(eid in prev_overlaps)
                if trigger_comp.on_enter !== nothing
                    try
                        trigger_comp.on_enter(trigger_eid, eid)
                    catch e
                        @warn "Trigger on_enter callback error" exception=e
                    end
                end
            end
        end

        # Detect stay events
        for eid in current_overlaps
            if eid in prev_overlaps
                if trigger_comp.on_stay !== nothing
                    try
                        trigger_comp.on_stay(trigger_eid, eid)
                    catch e
                        @warn "Trigger on_stay callback error" exception=e
                    end
                end
            end
        end

        # Detect exit events
        for eid in prev_overlaps
            if !(eid in current_overlaps)
                if trigger_comp.on_exit !== nothing
                    try
                        trigger_comp.on_exit(trigger_eid, eid)
                    catch e
                        @warn "Trigger on_exit callback error" exception=e
                    end
                end
            end
        end

        state.overlaps[trigger_eid] = current_overlaps
    end
end
