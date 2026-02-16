# Input handling

"""
    InputState

Current state of input devices (keyboard, mouse, gamepads).
"""
mutable struct InputState
    keys_pressed::Set{Int}
    mouse_position::Tuple{Float64, Float64}
    mouse_buttons::Set{Int}

    # Gamepad state — joystick_id => axis/button vectors
    gamepad_axes::Dict{Int, Vector{Float32}}
    gamepad_buttons::Dict{Int, Vector{Bool}}

    # Previous frame state for edge detection
    prev_keys::Set{Int}
    prev_mouse_buttons::Set{Int}
    prev_gamepad_buttons::Dict{Int, Vector{Bool}}

    InputState() = new(
        Set{Int}(), (0.0, 0.0), Set{Int}(),
        Dict{Int, Vector{Float32}}(),
        Dict{Int, Vector{Bool}}(),
        Set{Int}(), Set{Int}(),
        Dict{Int, Vector{Bool}}()
    )
end

"""
    is_key_pressed(state::InputState, key::Int) -> Bool

Check if a key is currently pressed.
"""
function is_key_pressed(state::InputState, key::Int)
    return key in state.keys_pressed
end

"""
    is_key_just_pressed(state::InputState, key::Int) -> Bool

Check if a key was pressed this frame (rising edge).
"""
function is_key_just_pressed(state::InputState, key::Int)
    return (key in state.keys_pressed) && !(key in state.prev_keys)
end

"""
    is_key_just_released(state::InputState, key::Int) -> Bool

Check if a key was released this frame (falling edge).
"""
function is_key_just_released(state::InputState, key::Int)
    return !(key in state.keys_pressed) && (key in state.prev_keys)
end

"""
    get_mouse_position(state::InputState) -> Tuple{Float64, Float64}

Get the current mouse position.
"""
function get_mouse_position(state::InputState)
    return state.mouse_position
end

"""
    begin_frame!(input::InputState)

Snapshot current input state as previous frame. Call at the start of each frame,
before polling gamepads or processing input.
"""
function begin_frame!(input::InputState)
    input.prev_keys = copy(input.keys_pressed)
    input.prev_mouse_buttons = copy(input.mouse_buttons)
    # Deep copy gamepad button state
    empty!(input.prev_gamepad_buttons)
    for (jid, buttons) in input.gamepad_buttons
        input.prev_gamepad_buttons[jid] = copy(buttons)
    end
    return nothing
end

"""
    poll_gamepads!(input::InputState)

Read connected gamepad axes and buttons via GLFW raw joystick API.
Call once per frame after `begin_frame!()`.
"""
const _GLFW_JOYSTICKS = [
    GLFW.JOYSTICK_1,  GLFW.JOYSTICK_2,  GLFW.JOYSTICK_3,  GLFW.JOYSTICK_4,
    GLFW.JOYSTICK_5,  GLFW.JOYSTICK_6,  GLFW.JOYSTICK_7,  GLFW.JOYSTICK_8,
    GLFW.JOYSTICK_9,  GLFW.JOYSTICK_10, GLFW.JOYSTICK_11, GLFW.JOYSTICK_12,
    GLFW.JOYSTICK_13, GLFW.JOYSTICK_14, GLFW.JOYSTICK_15, GLFW.JOYSTICK_16,
]

function poll_gamepads!(input::InputState)
    for (idx, joy) in enumerate(_GLFW_JOYSTICKS)
        if GLFW.JoystickPresent(joy)
            axes = GLFW.GetJoystickAxes(joy)
            if axes !== nothing
                input.gamepad_axes[idx] = Float32[Float32(a) for a in axes]
            end
            buttons = GLFW.GetJoystickButtons(joy)
            if buttons !== nothing
                input.gamepad_buttons[idx] = Bool[b != 0 for b in buttons]
            end
        else
            delete!(input.gamepad_axes, idx)
            delete!(input.gamepad_buttons, idx)
        end
    end
    return nothing
end

"""
    setup_input_callbacks!(window::Window, input::InputState)

Register GLFW key, cursor, and mouse button callbacks that update the InputState.
"""
function setup_input_callbacks!(window::Window, input::InputState)
    GLFW.SetKeyCallback(window.handle, (_, key, _, action, _) -> begin
        if action == GLFW.PRESS
            push!(input.keys_pressed, Int(key))
        elseif action == GLFW.RELEASE
            delete!(input.keys_pressed, Int(key))
        end
    end)

    GLFW.SetCursorPosCallback(window.handle, (_, x, y) -> begin
        input.mouse_position = (x, y)
    end)

    GLFW.SetMouseButtonCallback(window.handle, (_, button, action, _) -> begin
        if action == GLFW.PRESS
            push!(input.mouse_buttons, Int(button))
        elseif action == GLFW.RELEASE
            delete!(input.mouse_buttons, Int(button))
        end
    end)

    return nothing
end
