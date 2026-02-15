# Action-based input mapping system
# Maps logical actions (e.g. "jump") to physical inputs (keyboard, mouse, gamepad)

# --- Gamepad constants (standard Xbox/PS layout for raw GLFW joystick API) ---

const GAMEPAD_BUTTON_A     = 0
const GAMEPAD_BUTTON_B     = 1
const GAMEPAD_BUTTON_X     = 2
const GAMEPAD_BUTTON_Y     = 3
const GAMEPAD_BUTTON_LB    = 4
const GAMEPAD_BUTTON_RB    = 5
const GAMEPAD_BUTTON_BACK  = 6
const GAMEPAD_BUTTON_START = 7
const GAMEPAD_BUTTON_LSTICK = 8
const GAMEPAD_BUTTON_RSTICK = 9

const GAMEPAD_AXIS_LEFT_X       = 0
const GAMEPAD_AXIS_LEFT_Y       = 1
const GAMEPAD_AXIS_RIGHT_X      = 2
const GAMEPAD_AXIS_RIGHT_Y      = 3
const GAMEPAD_AXIS_TRIGGER_LEFT  = 4
const GAMEPAD_AXIS_TRIGGER_RIGHT = 5

# --- Input source types ---

"""
    InputSource

Abstract type for physical input sources that can be bound to actions.
"""
abstract type InputSource end

"""
    KeyboardKey <: InputSource

A keyboard key identified by its GLFW key code.
"""
struct KeyboardKey <: InputSource
    key::Int
end

"""
    MouseButton <: InputSource

A mouse button identified by its GLFW button code.
"""
struct MouseButton <: InputSource
    button::Int
end

"""
    GamepadButton <: InputSource

A gamepad button on a specific joystick.

- `joystick_id`: GLFW joystick index (1-based, matching GLFW.JOYSTICK_1 etc.)
- `button_index`: 0-based button index (use GAMEPAD_BUTTON_* constants)
"""
struct GamepadButton <: InputSource
    joystick_id::Int
    button_index::Int
end

"""
    GamepadAxis <: InputSource

A gamepad axis direction on a specific joystick.

- `joystick_id`: GLFW joystick index (1-based)
- `axis_index`: 0-based axis index (use GAMEPAD_AXIS_* constants)
- `positive`: true = positive axis direction, false = negative
- `deadzone`: axis values below this threshold are ignored (default 0.15)
"""
struct GamepadAxis <: InputSource
    joystick_id::Int
    axis_index::Int
    positive::Bool
    deadzone::Float32

    GamepadAxis(joystick_id::Int, axis_index::Int, positive::Bool, deadzone::Float32=0.15f0) =
        new(joystick_id, axis_index, positive, deadzone)
end

# --- Action state ---

"""
    ActionState

Tracks the current state of a logical action for one frame.
"""
mutable struct ActionState
    pressed::Bool           # Currently active this frame
    just_pressed::Bool      # Became active this frame (rising edge)
    just_released::Bool     # Became inactive this frame (falling edge)
    axis_value::Float32     # Analog value 0.0–1.0 (for GamepadAxis sources)
    prev_pressed::Bool      # Was active last frame (internal)

    ActionState() = new(false, false, false, 0.0f0, false)
end

# --- Action binding ---

"""
    ActionBinding

Maps a logical action name to one or more physical input sources.
Multiple sources use OR logic — the action is active if *any* source is active.
"""
struct ActionBinding
    name::String
    sources::Vector{InputSource}
end

# --- InputMap ---

"""
    InputMap

Holds all action bindings and their current states.
Create with `InputMap()`, add bindings with `bind!()`, query with `is_action_pressed()` etc.

# Example
```julia
map = InputMap()
bind!(map, "jump", KeyboardKey(GLFW.KEY_SPACE))
bind!(map, "jump", GamepadButton(1, GAMEPAD_BUTTON_A))

# Each frame:
update_actions!(map, input_state)
if is_action_just_pressed(map, "jump")
    # player jumps
end
```
"""
mutable struct InputMap
    bindings::Dict{String, ActionBinding}
    states::Dict{String, ActionState}

    InputMap() = new(Dict{String, ActionBinding}(), Dict{String, ActionState}())
end

# --- Binding API ---

"""
    bind!(map::InputMap, action_name::String, source::InputSource)

Add an input source to an action. Multiple sources per action use OR logic.
If the action doesn't exist yet, it is created.
"""
function bind!(map::InputMap, action_name::String, source::InputSource)
    if !haskey(map.bindings, action_name)
        map.bindings[action_name] = ActionBinding(action_name, InputSource[])
        map.states[action_name] = ActionState()
    end
    push!(map.bindings[action_name].sources, source)
    return map
end

"""
    unbind!(map::InputMap, action_name::String)

Remove an action and all its bindings.
"""
function unbind!(map::InputMap, action_name::String)
    delete!(map.bindings, action_name)
    delete!(map.states, action_name)
    return map
end

"""
    unbind!(map::InputMap, action_name::String, source::InputSource)

Remove a specific input source from an action.
"""
function unbind!(map::InputMap, action_name::String, source::InputSource)
    if haskey(map.bindings, action_name)
        filter!(s -> s != source, map.bindings[action_name].sources)
    end
    return map
end

# --- Source evaluation ---

"""Check if a single input source is active and return its analog value."""
function _evaluate_source(source::KeyboardKey, input::InputState)::Tuple{Bool, Float32}
    pressed = source.key in input.keys_pressed
    return (pressed, pressed ? 1.0f0 : 0.0f0)
end

function _evaluate_source(source::MouseButton, input::InputState)::Tuple{Bool, Float32}
    pressed = source.button in input.mouse_buttons
    return (pressed, pressed ? 1.0f0 : 0.0f0)
end

function _evaluate_source(source::GamepadButton, input::InputState)::Tuple{Bool, Float32}
    buttons = get(input.gamepad_buttons, source.joystick_id, nothing)
    if buttons === nothing
        return (false, 0.0f0)
    end
    idx = source.button_index + 1  # 0-based → 1-based Julia indexing
    if idx < 1 || idx > length(buttons)
        return (false, 0.0f0)
    end
    pressed = buttons[idx]
    return (pressed, pressed ? 1.0f0 : 0.0f0)
end

function _evaluate_source(source::GamepadAxis, input::InputState)::Tuple{Bool, Float32}
    axes = get(input.gamepad_axes, source.joystick_id, nothing)
    if axes === nothing
        return (false, 0.0f0)
    end
    idx = source.axis_index + 1  # 0-based → 1-based Julia indexing
    if idx < 1 || idx > length(axes)
        return (false, 0.0f0)
    end
    raw = axes[idx]
    # Check direction
    value = source.positive ? raw : -raw
    # Apply deadzone
    if value < source.deadzone
        return (false, 0.0f0)
    end
    # Remap deadzone..1.0 → 0.0..1.0 for smooth analog response
    remapped = (value - source.deadzone) / (1.0f0 - source.deadzone)
    return (true, clamp(remapped, 0.0f0, 1.0f0))
end

# --- Action state update ---

"""
    update_actions!(map::InputMap, input::InputState)

Evaluate all action bindings against the current input state.
Call once per frame, after `begin_frame!()` and `poll_gamepads!()`.
"""
function update_actions!(map::InputMap, input::InputState)
    for (name, binding) in map.bindings
        state = map.states[name]
        state.prev_pressed = state.pressed

        # Evaluate all sources (OR logic), take max axis value
        active = false
        max_axis = 0.0f0
        for source in binding.sources
            pressed, axis_val = _evaluate_source(source, input)
            if pressed
                active = true
            end
            if axis_val > max_axis
                max_axis = axis_val
            end
        end

        state.pressed = active
        state.axis_value = max_axis
        state.just_pressed = active && !state.prev_pressed
        state.just_released = !active && state.prev_pressed
    end
    return nothing
end

# --- Query API ---

"""
    is_action_pressed(map::InputMap, name::String) -> Bool

Returns true while the action is held down.
"""
function is_action_pressed(map::InputMap, name::String)::Bool
    state = get(map.states, name, nothing)
    return state !== nothing && state.pressed
end

"""
    is_action_just_pressed(map::InputMap, name::String) -> Bool

Returns true only on the frame the action was first pressed (rising edge).
"""
function is_action_just_pressed(map::InputMap, name::String)::Bool
    state = get(map.states, name, nothing)
    return state !== nothing && state.just_pressed
end

"""
    is_action_just_released(map::InputMap, name::String) -> Bool

Returns true only on the frame the action was released (falling edge).
"""
function is_action_just_released(map::InputMap, name::String)::Bool
    state = get(map.states, name, nothing)
    return state !== nothing && state.just_released
end

"""
    get_axis(map::InputMap, name::String) -> Float32

Returns the analog axis value (0.0–1.0) for the action.
For digital inputs (keyboard/mouse/gamepad button) this is 0.0 or 1.0.
For gamepad axes, returns the remapped value after deadzone.
"""
function get_axis(map::InputMap, name::String)::Float32
    state = get(map.states, name, nothing)
    return state !== nothing ? state.axis_value : 0.0f0
end

# --- Default player bindings ---

"""
    create_default_player_map() -> InputMap

Create an InputMap with standard FPS player bindings:
WASD + mouse for keyboard, left/right stick + face buttons for gamepad.
"""
function create_default_player_map()
    map = InputMap()

    # Movement — keyboard
    bind!(map, "move_forward",  KeyboardKey(Int(GLFW.KEY_W)))
    bind!(map, "move_backward", KeyboardKey(Int(GLFW.KEY_S)))
    bind!(map, "move_left",     KeyboardKey(Int(GLFW.KEY_A)))
    bind!(map, "move_right",    KeyboardKey(Int(GLFW.KEY_D)))

    # Movement — gamepad left stick (joystick 1)
    bind!(map, "move_forward",  GamepadAxis(1, GAMEPAD_AXIS_LEFT_Y, false))  # Y- = forward
    bind!(map, "move_backward", GamepadAxis(1, GAMEPAD_AXIS_LEFT_Y, true))   # Y+ = backward
    bind!(map, "move_left",     GamepadAxis(1, GAMEPAD_AXIS_LEFT_X, false))  # X- = left
    bind!(map, "move_right",    GamepadAxis(1, GAMEPAD_AXIS_LEFT_X, true))   # X+ = right

    # Jump
    bind!(map, "jump", KeyboardKey(Int(GLFW.KEY_SPACE)))
    bind!(map, "jump", GamepadButton(1, GAMEPAD_BUTTON_A))

    # Crouch / fly down
    bind!(map, "crouch", KeyboardKey(Int(GLFW.KEY_LEFT_CONTROL)))
    bind!(map, "crouch", GamepadButton(1, GAMEPAD_BUTTON_B))

    # Sprint
    bind!(map, "sprint", KeyboardKey(Int(GLFW.KEY_LEFT_SHIFT)))
    bind!(map, "sprint", GamepadButton(1, GAMEPAD_BUTTON_LB))

    # Look — gamepad right stick (mouse look handled separately)
    bind!(map, "look_right", GamepadAxis(1, GAMEPAD_AXIS_RIGHT_X, true,  0.1f0))
    bind!(map, "look_left",  GamepadAxis(1, GAMEPAD_AXIS_RIGHT_X, false, 0.1f0))
    bind!(map, "look_down",  GamepadAxis(1, GAMEPAD_AXIS_RIGHT_Y, true,  0.1f0))
    bind!(map, "look_up",    GamepadAxis(1, GAMEPAD_AXIS_RIGHT_Y, false, 0.1f0))

    return map
end
