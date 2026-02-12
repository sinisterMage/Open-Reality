# PBR rendering pipeline: backend-agnostic render loop
# NOTE: OpenGL-specific code (PBR shaders, upload_lights!) moved to backend/opengl/

# Global UI state — set by run_render_loop!, read by render_frame!
const _UI_CALLBACK = Ref{Union{Function, Nothing}}(nothing)
const _UI_CONTEXT = Ref{Union{UIContext, Nothing}}(nothing)

"""
    run_render_loop!(scene::Scene; backend=OpenGLBackend(), width=1280, height=720, title="OpenReality", ui=nothing)

Main render loop. Creates a window, initializes the backend, and renders the scene
until the window is closed.

If a PlayerComponent exists in the scene, FPS controls are automatically enabled:
WASD movement, mouse look, Space/Ctrl for up/down, Shift to sprint, Escape to
release cursor.

Pass a `ui` callback `ctx::UIContext -> nothing` to render immediate-mode UI each frame.
"""
function run_render_loop!(scene::Scene;
                          backend::AbstractBackend = OpenGLBackend(),
                          width::Int = 1280,
                          height::Int = 720,
                          title::String = "OpenReality",
                          post_process::Union{PostProcessConfig, Nothing} = nothing,
                          ui::Union{Function, Nothing} = nothing)
    initialize!(backend, width=width, height=height, title=title)

    # Initialize audio system
    init_audio!()

    # Initialize particle renderer
    init_particle_renderer!()

    # Initialize UI renderer if callback provided
    if ui !== nothing
        init_ui_renderer!()
        _UI_CONTEXT[] = UIContext()
        _UI_CALLBACK[] = ui
    end

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
    prev_mouse_down = false

    try
        while !backend_should_close(backend)
            # Delta time
            now = backend_get_time(backend)
            dt = now - last_time
            last_time = now

            backend_poll_events!(backend)

            # Clear per-frame caches
            clear_world_transform_cache!()

            # Update UI input state
            if _UI_CONTEXT[] !== nothing && _UI_CALLBACK[] !== nothing
                ctx = _UI_CONTEXT[]
                input = backend_get_input(backend)
                mx, my = get_mouse_position(input)
                mouse_down_now = 0 in input.mouse_buttons  # GLFW.MOUSE_BUTTON_LEFT = 0
                ctx.mouse_x = mx
                ctx.mouse_y = my
                ctx.mouse_clicked = mouse_down_now && !prev_mouse_down
                ctx.mouse_down = mouse_down_now
                prev_mouse_down = mouse_down_now

                # Update screen dimensions
                if hasproperty(backend, :window)
                    ctx.width = backend.window.width
                    ctx.height = backend.window.height
                end

                # Initialize font atlas on first frame (needs OpenGL context)
                if isempty(ctx.font_atlas.glyphs) && isempty(ctx.font_path)
                    ctx.font_atlas = get_or_create_font_atlas!("", 32)
                end
            end

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

            # Skinning step (compute bone matrices after animation)
            update_skinned_meshes!()

            # Physics step (collision detection, gravity, resolution)
            update_physics!(dt)

            # Audio step (sync listener/source positions with transforms)
            update_audio!(dt)

            # Particle step (emission, simulation, billboard generation)
            update_particles!(dt)

            # render_frame! handles 3D rendering + UI + swap_buffers
            render_frame!(backend, scene)
        end
    finally
        if _UI_CONTEXT[] !== nothing
            shutdown_ui_renderer!()
            _UI_CONTEXT[] = nothing
            _UI_CALLBACK[] = nothing
        end
        shutdown_particle_renderer!()
        reset_particle_pools!()
        shutdown_audio!()
        shutdown!(backend)
    end

    return nothing
end
