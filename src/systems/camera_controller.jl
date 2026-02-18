# Camera controller systems
# Updates ThirdPersonCamera, OrbitCamera, and CinematicCamera components each frame.

# Module-level mouse tracking state (mirrors PlayerController pattern)
const _CAM_PREV_MOUSE_X = Ref{Float64}(0.0)
const _CAM_PREV_MOUSE_Y = Ref{Float64}(0.0)
const _CAM_FIRST_MOUSE = Ref{Bool}(true)

# Register reset hook so tests don't see stale state
push!(_RESET_HOOKS, () -> begin
    _CAM_PREV_MOUSE_X[] = 0.0
    _CAM_PREV_MOUSE_Y[] = 0.0
    _CAM_FIRST_MOUSE[] = true
end)

"""
    update_camera_controllers!(input::InputState, dt::Float64)

Update all camera controller components (ThirdPersonCamera, OrbitCamera, CinematicCamera).
"""
function update_camera_controllers!(input::InputState, dt::Float64)
    # Compute mouse delta
    mx, my = input.mouse_position
    if _CAM_FIRST_MOUSE[]
        _CAM_PREV_MOUSE_X[] = mx
        _CAM_PREV_MOUSE_Y[] = my
        _CAM_FIRST_MOUSE[] = false
        dx = 0.0
        dy = 0.0
    else
        dx = mx - _CAM_PREV_MOUSE_X[]
        dy = my - _CAM_PREV_MOUSE_Y[]
    end
    _CAM_PREV_MOUSE_X[] = mx
    _CAM_PREV_MOUSE_Y[] = my

    # --- ThirdPersonCamera ---
    iterate_components(ThirdPersonCamera) do eid, cam
        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        # Get target world position
        target_world = get_world_transform(cam.target_entity)
        target_pos = Vec3d(target_world[1, 4], target_world[2, 4], target_world[3, 4])

        # Apply mouse delta to yaw/pitch
        cam.yaw -= dx * Float64(cam.sensitivity)
        cam.pitch -= dy * Float64(cam.sensitivity)
        cam.pitch = clamp(cam.pitch, cam.min_pitch, cam.max_pitch)

        # Compute desired position (spherical coordinates around target)
        dist = Float64(cam.distance)
        cp = cos(cam.pitch)
        desired_pos = target_pos + Vec3d(cam.offset) + Vec3d(
            dist * cp * sin(cam.yaw),
            dist * sin(cam.pitch),
            dist * cp * cos(cam.yaw)
        )

        # Camera collision
        if cam.collision_enabled
            dir = desired_pos - target_pos
            dir_len = sqrt(dir[1]^2 + dir[2]^2 + dir[3]^2)
            if dir_len > 0.0
                dir_norm = Vec3d(dir[1] / dir_len, dir[2] / dir_len, dir[3] / dir_len)
                hit = raycast(target_pos, dir_norm; max_distance=dist)
                if hit !== nothing
                    desired_pos = target_pos + dir_norm * (hit.distance * 0.9)
                end
            end
        end

        # Smoothing lerp
        current_pos = tc.position[]
        alpha = clamp(Float64(cam.smoothing) * dt, 0.0, 1.0)
        new_pos = current_pos + (desired_pos - current_pos) * alpha
        tc.position[] = new_pos

        # Look-at quaternion toward target
        forward = target_pos - new_pos
        fwd_len = sqrt(forward[1]^2 + forward[2]^2 + forward[3]^2)
        if fwd_len > 1e-8
            forward = Vec3d(forward[1] / fwd_len, forward[2] / fwd_len, forward[3] / fwd_len)
            look_yaw = atan(-forward[1], -forward[3])
            look_pitch = asin(clamp(forward[2], -1.0, 1.0))
            yaw_quat = Quaterniond(cos(look_yaw / 2), 0.0, sin(look_yaw / 2), 0.0)
            pitch_quat = Quaterniond(cos(look_pitch / 2), sin(look_pitch / 2), 0.0, 0.0)
            tc.rotation[] = yaw_quat * pitch_quat
        end
    end

    # --- OrbitCamera ---
    iterate_components(OrbitCamera) do eid, cam
        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        # Right mouse button rotates (GLFW.MOUSE_BUTTON_RIGHT = 1)
        if 1 in input.mouse_buttons
            cam.yaw -= dx * 0.01
            cam.pitch -= dy * 0.01
        end

        # Scroll zoom
        cam.distance -= Float32(input.scroll_delta[2]) * cam.zoom_speed
        cam.distance = max(cam.distance, 0.1f0)

        # Compute desired position (spherical coordinates)
        dist = Float64(cam.distance)
        cp = cos(cam.pitch)
        desired_pos = cam.target_position + Vec3d(
            dist * cp * sin(cam.yaw),
            dist * sin(cam.pitch),
            dist * cp * cos(cam.yaw)
        )

        # Smoothing lerp
        current_pos = tc.position[]
        alpha = clamp(Float64(cam.smoothing) * dt, 0.0, 1.0)
        new_pos = current_pos + (desired_pos - current_pos) * alpha
        tc.position[] = new_pos

        # Look-at quaternion toward target
        forward = cam.target_position - new_pos
        fwd_len = sqrt(forward[1]^2 + forward[2]^2 + forward[3]^2)
        if fwd_len > 1e-8
            forward = Vec3d(forward[1] / fwd_len, forward[2] / fwd_len, forward[3] / fwd_len)
            look_yaw = atan(-forward[1], -forward[3])
            look_pitch = asin(clamp(forward[2], -1.0, 1.0))
            yaw_quat = Quaterniond(cos(look_yaw / 2), 0.0, sin(look_yaw / 2), 0.0)
            pitch_quat = Quaterniond(cos(look_pitch / 2), sin(look_pitch / 2), 0.0, 0.0)
            tc.rotation[] = yaw_quat * pitch_quat
        end
    end

    # --- CinematicCamera ---
    iterate_components(CinematicCamera) do eid, cam
        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        if cam.playing && !isempty(cam.path)
            cam.current_time += Float32(dt)
            if cam.looping
                cam.current_time = mod(cam.current_time, cam.path_times[end])
            else
                cam.current_time = min(cam.current_time, cam.path_times[end])
            end
            (idx_a, idx_b, lerp_t) = _find_keyframe_pair(cam.path_times, cam.current_time)
            new_pos = _lerp_vec3d(cam.path[idx_a], cam.path[idx_b], lerp_t)
            tc.position[] = new_pos
        elseif !cam.playing
            # Free-fly mode: WASD movement
            rot = tc.rotation[]
            # Extract yaw and pitch from current rotation quaternion
            fly_yaw = atan(2.0 * (rot.s * rot.v2 + rot.v1 * rot.v3),
                           1.0 - 2.0 * (rot.v2^2 + rot.v1^2))
            fly_pitch = asin(clamp(2.0 * (rot.s * rot.v1 - rot.v3 * rot.v2), -1.0, 1.0))

            # Apply mouse delta to yaw and pitch
            fly_yaw -= dx * Float64(cam.sensitivity)
            fly_pitch -= dy * Float64(cam.sensitivity)
            fly_pitch = clamp(fly_pitch, -deg2rad(89.0), deg2rad(89.0))

            forward = Vec3d(-sin(fly_yaw), 0.0, -cos(fly_yaw))
            right = Vec3d(cos(fly_yaw), 0.0, -sin(fly_yaw))

            move = Vec3d(0.0, 0.0, 0.0)
            if KEY_W in input.keys_pressed
                move = move + forward
            end
            if KEY_S in input.keys_pressed
                move = move - forward
            end
            if KEY_D in input.keys_pressed
                move = move + right
            end
            if KEY_A in input.keys_pressed
                move = move - right
            end

            len = sqrt(move[1]^2 + move[2]^2 + move[3]^2)
            if len > 0.0
                move = move / len
            end

            tc.position[] = tc.position[] + move * Float64(cam.move_speed) * dt

            # Rebuild quaternion from updated yaw/pitch
            yaw_quat = Quaterniond(cos(fly_yaw / 2), 0.0, sin(fly_yaw / 2), 0.0)
            pitch_quat = Quaterniond(cos(fly_pitch / 2), sin(fly_pitch / 2), 0.0, 0.0)
            tc.rotation[] = yaw_quat * pitch_quat
        end
    end

    return nothing
end
