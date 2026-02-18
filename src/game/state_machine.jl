# Game State Machine — abstract state type, transitions, and FSM container

abstract type GameState end

mutable struct StateTransition
    target::Symbol
    new_scene_defs::Union{Vector, Nothing}
end

StateTransition(target::Symbol) = StateTransition(target, nothing)

mutable struct GameStateMachine
    states::Dict{Symbol, GameState}
    initial_state::Symbol
    initial_scene_defs::Vector
end

GameStateMachine(initial_state::Symbol, initial_scene_defs::Vector) =
    GameStateMachine(Dict{Symbol, GameState}(), initial_state, initial_scene_defs)

# Default dispatch implementations — users only override what they need
on_enter!(state::GameState, sc::Scene) = nothing
on_update!(state::GameState, sc::Scene, dt::Float64, ctx::GameContext) = nothing
on_exit!(state::GameState, sc::Scene) = nothing
get_ui_callback(state::GameState) = nothing
