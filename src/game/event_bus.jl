# =============================================================================
# Event Bus — lightweight publish/subscribe for game events
# =============================================================================

"""
    GameEvent

Abstract base type for all game events.
Define concrete event types by subtyping:

```julia
struct EnemyDefeated <: GameEvent
    enemy_id::EntityID
    score::Int
end
```
"""
abstract type GameEvent end

"""
    EventBus

Central event dispatcher. Holds a registry of listeners keyed by event type.
Use the global singleton via `get_event_bus()` rather than constructing directly.
"""
mutable struct EventBus
    listeners::Dict{DataType, Vector{Function}}

    EventBus() = new(Dict{DataType, Vector{Function}}())
end

# ---------------------------------------------------------------------------
# Global singleton
# ---------------------------------------------------------------------------

const _EVENT_BUS = Ref{Union{EventBus, Nothing}}(nothing)

"""
    get_event_bus() -> EventBus

Return the global `EventBus` singleton, creating it lazily on first access.
"""
function get_event_bus()::EventBus
    if _EVENT_BUS[] === nothing
        _EVENT_BUS[] = EventBus()
    end
    return _EVENT_BUS[]
end

"""
    reset_event_bus!()

Destroy the global `EventBus` singleton so that the next `get_event_bus()` call
creates a fresh instance. Called automatically by `reset_engine_state!()`.
"""
function reset_event_bus!()
    _EVENT_BUS[] = nothing
    return nothing
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    subscribe!(::Type{T}, callback::Function) where T <: GameEvent

Register `callback` to be invoked whenever an event of type `T` is emitted.
Listeners are called in registration order.
"""
function subscribe!(::Type{T}, callback::Function) where T <: GameEvent
    bus = get_event_bus()
    listeners = get!(bus.listeners, T) do
        Function[]
    end
    push!(listeners, callback)
    return nothing
end

"""
    unsubscribe!(::Type{T}, callback::Function) where T <: GameEvent

Remove `callback` from the listener list for event type `T`.
Identity comparison (`===`) is used, so pass the same function object that was
originally subscribed.
"""
function unsubscribe!(::Type{T}, callback::Function) where T <: GameEvent
    bus = get_event_bus()
    haskey(bus.listeners, T) || return nothing
    filter!(f -> f !== callback, bus.listeners[T])
    return nothing
end

"""
    emit!(event::T) where T <: GameEvent

Dispatch `event` to all registered listeners for `typeof(event)`.
Listeners are called in registration order. A listener that throws an exception
is caught and logged via `@warn`; remaining listeners still execute.
"""
function emit!(event::T) where T <: GameEvent
    bus = get_event_bus()
    cbs = get(bus.listeners, typeof(event), nothing)
    cbs === nothing && return nothing
    isempty(cbs) && return nothing
    for cb in copy(cbs)
        try
            cb(event)
        catch err
            @warn "EventBus listener threw" exception=(err, catch_backtrace())
        end
    end
    return nothing
end
