# FPS player controller system
# Handles WASD movement + mouse look

# GLFW key constants
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
"""
mutable struct PlayerController
    player_entity::EntityID
    camera_entity::Union{EntityID, Nothing}
    last_mouse_x::Float64
    last_mouse_y::Float64
    first_mouse::Bool
    last_time::Float64

    function PlayerController(player_entity::EntityID, camera_entity::Union{EntityID, Nothing})
        new(player_entity, camera_entity, 0.0, 0.0, true, get_time())
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

- WASD: horizontal movement relative to facing direction
- Mouse: yaw (horizontal) and pitch (vertical) look
- Space: move up
- Left Ctrl: move down
- Left Shift: sprint
- Escape: release mouse cursor
"""
function update_player!(controller::PlayerController, input::InputState, dt::Float64)
    player = get_component(controller.player_entity, PlayerComponent)
    player_transform = get_component(controller.player_entity, TransformComponent)
    if player === nothing || player_transform === nothing
        return
    end

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

    # --- WASD movement ---
    speed = Float64(player.move_speed)
    if is_key_pressed(input, KEY_LSHIFT)
        speed *= Float64(player.sprint_multiplier)
    end

    # Forward/right vectors derived from yaw (no pitch — keeps movement horizontal)
    forward = Vec3d(-sin(player.yaw), 0, -cos(player.yaw))
    right   = Vec3d( cos(player.yaw), 0, -sin(player.yaw))

    move = Vec3d(0, 0, 0)
    if is_key_pressed(input, KEY_W)
        move = move + forward
    end
    if is_key_pressed(input, KEY_S)
        move = move - forward
    end
    if is_key_pressed(input, KEY_D)
        move = move + right
    end
    if is_key_pressed(input, KEY_A)
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

        # Jump: set upward velocity when grounded and space pressed
        if is_key_pressed(input, KEY_SPACE) && rb.grounded
            rb.velocity = Vec3d(rb.velocity[1], 5.0, rb.velocity[3])
        end

        vertical_delta = Vec3d(0, rb.velocity[2] * dt, 0)
    else
        # Fallback: no physics, fly mode (original behavior)
        if is_key_pressed(input, KEY_SPACE)
            vertical_delta = Vec3d(0, speed * dt, 0)
        end
        if is_key_pressed(input, KEY_LCTRL)
            vertical_delta = Vec3d(0, -speed * dt, 0)
        end
    end

    # Apply movement (physics system will resolve collisions after this)
    new_pos = player_transform.position[] + horizontal_delta + vertical_delta
    player_transform.position[] = new_pos
end
