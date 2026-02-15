# FPS player controller system
# Handles WASD movement + mouse look + gamepad input via InputMap

# GLFW key constants (kept for backward compatibility and escape handling)
const KEY_W     = Int(GLFW.KEY_W)
const KEY_A     = Int(GLFW.KEY_A)
const KEY_S     = Int(GLFW.KEY_S)
const KEY_D     = Int(GLFW.KEY_D)
const KEY_SPACE = Int(GLFW.KEY_SPACE)
const KEY_LCTRL = Int(GLFW.KEY_LEFT_CONTROL)
const KEY_LSHIFT = Int(GLFW.KEY_LEFT_SHIFT)
const KEY_ESCAPE = Int(GLFW.KEY_ESCAPE)

"""
    PlayerController

Manages FPS-style input processing for a player entity.
Created automatically by the render loop when a PlayerComponent is detected.

Uses an `InputMap` for action-based input — supports keyboard, mouse, and gamepad.
Custom bindings can be provided via `create_player(input_map=...)`.
"""
mutable struct PlayerController
    player_entity::EntityID
    camera_entity::Union{EntityID, Nothing}
    input_map::InputMap
    last_mouse_x::Float64
    last_mouse_y::Float64
    first_mouse::Bool
    last_time::Float64

    function PlayerController(player_entity::EntityID, camera_entity::Union{EntityID, Nothing};
                              input_map::Union{InputMap, Nothing}=nothing)
        map = input_map !== nothing ? input_map : create_default_player_map()
        new(player_entity, camera_entity, map, 0.0, 0.0, true, get_time())
    end
end

"""
    find_player_and_camera(scene::Scene) -> Union{Tuple{EntityID, Union{EntityID, Nothing}}, Nothing}

Find the player entity (has PlayerComponent) and its camera child entity.
Returns nothing if no player exists.
"""
function find_player_and_camera(scene::Scene)
    player_entities = entities_with_component(PlayerComponent)
    if isempty(player_entities)
        return nothing
    end

    player_id = first(player_entities)

    # Find camera child
    camera_id = nothing
    children = get_children(scene, player_id)
    for child in children
        if has_component(child, CameraComponent)
            camera_id = child
            break
        end
    end

    return (player_id, camera_id)
end

"""
    update_player!(controller::PlayerController, input::InputState, dt::Float64)

Process input and update player transform for one frame.

Uses the controller's InputMap for action queries. Default bindings:
- WASD / left stick: horizontal movement
- Mouse / right stick: look
- Space / A button: jump
- Left Ctrl / B button: crouch / fly down
- Left Shift / LB: sprint
"""
function update_player!(controller::PlayerController, input::InputState, dt::Float64)
    player = get_component(controller.player_entity, PlayerComponent)
    player_transform = get_component(controller.player_entity, TransformComponent)
    if player === nothing || player_transform === nothing
        return
    end

    # Poll gamepads and update action states
    poll_gamepads!(input)
    update_actions!(controller.input_map, input)
    map = controller.input_map

    # --- Mouse look ---
    mx, my = input.mouse_position

    if controller.first_mouse
        controller.last_mouse_x = mx
        controller.last_mouse_y = my
        controller.first_mouse = false
    end

    dx = mx - controller.last_mouse_x
    dy = my - controller.last_mouse_y
    controller.last_mouse_x = mx
    controller.last_mouse_y = my

    sens = Float64(player.mouse_sensitivity)
    player.yaw -= dx * sens
    player.pitch -= dy * sens

    # --- Gamepad right stick look ---
    look_x = get_axis(map, "look_right") - get_axis(map, "look_left")
    look_y = get_axis(map, "look_down") - get_axis(map, "look_up")

    if abs(look_x) > 0.01 || abs(look_y) > 0.01
        gamepad_look_speed = 2.5  # radians/sec at full deflection
        player.yaw -= Float64(look_x) * gamepad_look_speed * dt
        player.pitch -= Float64(look_y) * gamepad_look_speed * dt
    end

    # Clamp pitch to avoid gimbal lock at poles
    max_pitch = deg2rad(89.0)
    player.pitch = clamp(player.pitch, -max_pitch, max_pitch)

    # Update player entity rotation (yaw only — around Y axis)
    yaw_quat = Quaterniond(cos(player.yaw / 2), 0, sin(player.yaw / 2), 0)
    player_transform.rotation[] = yaw_quat

    # Update camera child rotation (pitch only — around X axis)
    if controller.camera_entity !== nothing
        cam_transform = get_component(controller.camera_entity, TransformComponent)
        if cam_transform !== nothing
            pitch_quat = Quaterniond(cos(player.pitch / 2), sin(player.pitch / 2), 0, 0)
            cam_transform.rotation[] = pitch_quat
        end
    end

    # --- Movement ---
    speed = Float64(player.move_speed)
    if is_action_pressed(map, "sprint")
        speed *= Float64(player.sprint_multiplier)
    end

    # Forward/right vectors derived from yaw (no pitch — keeps movement horizontal)
    forward = Vec3d(-sin(player.yaw), 0, -cos(player.yaw))
    right   = Vec3d( cos(player.yaw), 0, -sin(player.yaw))

    move = Vec3d(0, 0, 0)
    if is_action_pressed(map, "move_forward")
        move = move + forward
    end
    if is_action_pressed(map, "move_backward")
        move = move - forward
    end
    if is_action_pressed(map, "move_right")
        move = move + right
    end
    if is_action_pressed(map, "move_left")
        move = move - right
    end

    # Normalize horizontal movement
    len = sqrt(move[1]^2 + move[2]^2 + move[3]^2)
    if len > 0
        move = move / len
    end

    horizontal_delta = move * speed * dt

    # --- Gravity and jump (if RigidBodyComponent exists) ---
    rb = get_component(controller.player_entity, RigidBodyComponent)
    vertical_delta = Vec3d(0, 0, 0)

    if rb !== nothing
        # Apply gravity to player velocity
        rb.velocity = rb.velocity + Vec3d(0, -9.81, 0) * dt

        # Raycast-based ground detection
        foot_pos = player_transform.position[] - Vec3d(0, 0.9, 0)
        hit = raycast(foot_pos, Vec3d(0, -1, 0), max_distance=player.ground_ray_length)
        if hit !== nothing
            rb.grounded = true
            if rb.velocity[2] < 0
                rb.velocity = Vec3d(rb.velocity[1], 0.0, rb.velocity[3])
            end
        end

        # Jump: set upward velocity when grounded and jump just pressed
        if is_action_just_pressed(map, "jump") && rb.grounded
            rb.velocity = Vec3d(rb.velocity[1], 5.0, rb.velocity[3])
        end

        vertical_delta = Vec3d(0, rb.velocity[2] * dt, 0)
    else
        # Fallback: no physics, fly mode (original behavior)
        if is_action_pressed(map, "jump")
            vertical_delta = Vec3d(0, speed * dt, 0)
        end
        if is_action_pressed(map, "crouch")
            vertical_delta = Vec3d(0, -speed * dt, 0)
        end
    end

    # Apply movement (physics system will resolve collisions after this)
    new_pos = player_transform.position[] + horizontal_delta + vertical_delta
    player_transform.position[] = new_pos
end
