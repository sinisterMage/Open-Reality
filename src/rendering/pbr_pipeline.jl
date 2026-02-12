# PBR rendering pipeline: backend-agnostic render loop
# NOTE: OpenGL-specific code (PBR shaders, upload_lights!) moved to backend/opengl/

"""
    run_render_loop!(scene::Scene; backend=OpenGLBackend(), width=1280, height=720, title="OpenReality")

Main render loop. Creates a window, initializes the backend, and renders the scene
until the window is closed.

If a PlayerComponent exists in the scene, FPS controls are automatically enabled:
WASD movement, mouse look, Space/Ctrl for up/down, Shift to sprint, Escape to
release cursor.
"""
function run_render_loop!(scene::Scene;
                          backend::AbstractBackend = OpenGLBackend(),
                          width::Int = 1280,
                          height::Int = 720,
                          title::String = "OpenReality",
                          post_process::Union{PostProcessConfig, Nothing} = nothing)
    initialize!(backend, width=width, height=height, title=title)

    # Apply post_process config after initialization (backend fields are now initialized)
    if post_process !== nothing
        if hasproperty(backend, :post_process) && backend.post_process !== nothing
            backend.post_process.config = post_process
        end
        if hasproperty(backend, :post_process_config)
            backend.post_process_config = post_process
        end
    end

    # Auto-detect player and set up FPS controller
    controller = nothing
    result = find_player_and_camera(scene)
    if result !== nothing
        player_id, camera_id = result
        controller = PlayerController(player_id, camera_id)
        backend_capture_cursor!(backend)
        @info "Player controller active — WASD to move, mouse to look, Shift to sprint, Escape to release cursor"
    end

    last_time = backend_get_time(backend)

    try
        while !backend_should_close(backend)
            # Delta time
            now = backend_get_time(backend)
            dt = now - last_time
            last_time = now

            backend_poll_events!(backend)

            # Update player
            if controller !== nothing
                # Escape toggles cursor capture
                if backend_is_key_pressed(backend, KEY_ESCAPE)
                    backend_release_cursor!(backend)
                end

                update_player!(controller, backend_get_input(backend), dt)
            end

            # Animation step
            update_animations!(dt)

            # Physics step (collision detection, gravity, resolution)
            update_physics!(dt)

            render_frame!(backend, scene)
        end
    finally
        shutdown!(backend)
    end

    return nothing
end
