# Game Manager — helpers for building and managing the FSM

function add_state!(fsm::GameStateMachine, name::Symbol, state::GameState)
    fsm.states[name] = state
    return fsm
end
