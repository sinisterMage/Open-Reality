# PBR rendering pipeline: backend-agnostic render loop
# NOTE: OpenGL-specific code (PBR shaders, upload_lights!) moved to backend/opengl/

# Global UI state — set by run_render_loop!, read by render_frame!
const _UI_CALLBACK = Ref{Union{Function, Nothing}}(nothing)
const _UI_CONTEXT = Ref{Union{UIContext, Nothing}}(nothing)

function _execute_scene_switch!(backend::AbstractBackend, new_defs::Vector, on_scene_switch::Union{Function, Nothing})
    # Snapshot on_destroy callbacks BEFORE reset
    script_entities = entities_with_component(ScriptComponent)
    for eid in script_entities
        comp = get_component(eid, ScriptComponent)
        if comp !== nothing && comp.on_destroy !== nothing
            try
                comp.on_destroy(eid)
            catch e
                @warn "ScriptComponent on_destroy error during scene switch" exception=e
            end
        end
    end
    # Reset or delegate to custom hook
    if on_scene_switch !== nothing
        on_scene_switch(nothing, new_defs)
    else
        reset_engine_state!()
        clear_audio_sources!()
    end
    # Build the new scene AFTER reset
    return scene(new_defs)
end

function _init_player_controller(scene::Scene, backend::AbstractBackend)
    result = find_player_and_camera(scene)
    if result !== nothing
        player_id, camera_id = result
        player_comp = get_component(player_id, PlayerComponent)
        player_input_map = player_comp !== nothing ? player_comp.input_map : nothing
        controller = PlayerController(player_id, camera_id; input_map=player_input_map)
        backend_capture_cursor!(backend)
        @info "Player controller active — WASD/gamepad to move, mouse/right stick to look, Shift/LB to sprint, Escape to release cursor"
        return controller
    end
    return nothing
end

"""
    run_render_loop!(scene::Scene; backend=OpenGLBackend(), width=1280, height=720, title="OpenReality", ui=nothing, on_update=nothing, on_scene_switch=nothing)

Main render loop. Creates a window, initializes the backend, and renders the scene
until the window is closed.

If a PlayerComponent exists in the scene, FPS controls are automatically enabled:
WASD movement, mouse look, Space/Ctrl for up/down, Shift to sprint, Escape to
release cursor.

Pass a `ui` callback `ctx::UIContext -> nothing` to render immediate-mode UI each frame.

Pass `on_update` as a callback `(scene, dt) -> result` called each frame after systems
update. Return a `Vector{EntityDef}` to trigger a scene switch; return `nothing` to continue.
The engine will reset all globals and build the new scene after reset, ensuring ECS is clean.

Pass `on_scene_switch` as a callback `(old_scene, new_defs::Vector{EntityDef}) -> nothing`
to customise scene-switch cleanup (default: `reset_engine_state!()` + `clear_audio_sources!()`).
"""
function run_render_loop!(initial_scene::Scene;
                          backend::AbstractBackend = OpenGLBackend(),
                          width::Int = 1280,
                          height::Int = 720,
                          title::String = "OpenReality",
                          post_process::Union{PostProcessConfig, Nothing} = nothing,
                          ui::Union{Function, Nothing} = nothing,
                          on_update::Union{Function, Nothing} = nothing,
                          on_scene_switch::Union{Function, Nothing} = nothing)
    initialize!(backend, width=width, height=height, title=title)

    current_scene = initial_scene

    # Initialize audio system
    init_audio!()

    # Initialize particle renderer (OpenGL only — other backends handle particles in render_frame!)
    if backend isa OpenGLBackend
        init_particle_renderer!()
    end

    # Initialize UI renderer if callback provided
    if ui !== nothing
        if backend isa OpenGLBackend
            init_ui_renderer!()
        end
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
    controller = _init_player_controller(current_scene, backend)

    last_time = backend_get_time(backend)
    prev_mouse_down = false

    try
        while !backend_should_close(backend)
            # Delta time
            now = backend_get_time(backend)
            dt = now - last_time
            last_time = now

            backend_poll_events!(backend)

            # Snapshot input state for edge detection (just_pressed / just_released)
            begin_frame!(backend_get_input(backend))

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
                if backend isa OpenGLBackend && isempty(ctx.font_atlas.glyphs) && isempty(ctx.font_path)
                    ctx.font_atlas = get_or_create_font_atlas!("", 32)
                end

                # Sync keyboard and scroll state from input into UI context
                ctx.typed_chars = copy(input.typed_chars)
                ctx.keys_pressed = copy(input.keys_pressed)
                ctx.prev_keys_pressed = copy(input.prev_keys)
                ctx.scroll_x = input.scroll_delta[1]
                ctx.scroll_y = input.scroll_delta[2]
            end

            # Update player
            if controller !== nothing
                # Escape toggles cursor capture (always active regardless of UI focus)
                if backend_is_key_pressed(backend, KEY_ESCAPE)
                    backend_release_cursor!(backend)
                end

                # Suppress player movement when UI has keyboard focus
                if !(_UI_CONTEXT[] !== nothing && _UI_CONTEXT[].has_keyboard_focus)
                    update_player!(controller, backend_get_input(backend), dt)
                end
            end

            # Camera controllers step
            update_camera_controllers!(backend_get_input(backend), dt)

            # Animation step
            update_animations!(dt)
            update_blend_tree!(dt)

            # Skinning step (compute bone matrices after animation)
            update_skinned_meshes!()

            # Physics step (collision detection, gravity, resolution)
            update_physics!(dt)

            # Script step (per-entity script callbacks)
            update_scripts!(dt)

            # Audio step (sync listener/source positions with transforms)
            update_audio!(dt)

            # Particle step (emission, simulation, billboard generation)
            update_particles!(dt)

            # Terrain step (initialize new terrains, update chunk LODs)
            _cam_id = find_active_camera()
            if _cam_id !== nothing
                _cam_world = get_world_transform(_cam_id)
                _cam_pos = Vec3f(Float32(_cam_world[1, 4]), Float32(_cam_world[2, 4]), Float32(_cam_world[3, 4]))
                _view = get_view_matrix(_cam_id)
                _proj = get_projection_matrix(_cam_id)
                _frustum = extract_frustum(_proj * _view)
                update_terrain!(_cam_pos, _frustum)
            end

            # on_update callback — return Vector{EntityDef} to trigger scene switch
            if on_update !== nothing
                result = on_update(current_scene, dt)
                if result isa Vector
                    current_scene = _execute_scene_switch!(backend, result, on_scene_switch)
                    controller = _init_player_controller(current_scene, backend)
                    continue
                end
            end

            # render_frame! handles 3D rendering + UI + swap_buffers
            render_frame!(backend, current_scene)
        end
    finally
        if _UI_CONTEXT[] !== nothing
            if backend isa OpenGLBackend
                shutdown_ui_renderer!()
            end
            _UI_CONTEXT[] = nothing
            _UI_CALLBACK[] = nothing
        end
        if backend isa OpenGLBackend
            shutdown_particle_renderer!()
            reset_terrain_gpu_caches!()
        end
        reset_particle_pools!()
        reset_terrain_cache!()
        shutdown_audio!()
        shutdown!(backend)
    end

    return nothing
end

"""
    run_render_loop!(fsm::GameStateMachine; backend=OpenGLBackend(), width=1280, height=720, title="OpenReality", post_process=nothing, ui=nothing, on_scene_switch=nothing)

FSM-driven render loop. Uses a `GameStateMachine` to manage game states and transitions
instead of a single `on_update` callback. Each state receives `on_enter!`, `on_update!`,
and `on_exit!` lifecycle hooks. Return a `StateTransition` from `on_update!` to switch states.
"""
function run_render_loop!(fsm::GameStateMachine;
                          backend::AbstractBackend = OpenGLBackend(),
                          width::Int = 1280,
                          height::Int = 720,
                          title::String = "OpenReality",
                          post_process::Union{PostProcessConfig, Nothing} = nothing,
                          ui::Union{Function, Nothing} = nothing,
                          on_scene_switch::Union{Function, Nothing} = nothing)
    initialize!(backend, width=width, height=height, title=title)

    current_scene = scene(fsm.initial_scene_defs)

    # Initialize audio system
    init_audio!()

    # Initialize particle renderer (OpenGL only — other backends handle particles in render_frame!)
    if backend isa OpenGLBackend
        init_particle_renderer!()
    end

    # Initialize UI renderer
    if backend isa OpenGLBackend
        init_ui_renderer!()
    end
    _UI_CONTEXT[] = UIContext()
    _UI_CALLBACK[] = ui

    # Apply post_process config after initialization (backend fields are now initialized)
    if post_process !== nothing
        if hasproperty(backend, :post_process) && backend.post_process !== nothing
            backend.post_process.config = post_process
        end
        if hasproperty(backend, :post_process_config)
            backend.post_process_config = post_process
        end
    end

    # FSM state
    current_state_name = fsm.initial_state
    current_state = fsm.states[current_state_name]

    # Enter initial state
    try
        on_enter!(current_state, current_scene)
    catch e
        @warn "on_enter! error for state $current_state_name" exception=e
    end

    # Auto-detect player and set up FPS controller
    controller = _init_player_controller(current_scene, backend)

    last_time = backend_get_time(backend)
    prev_mouse_down = false

    try
        while !backend_should_close(backend)
            # Delta time
            now = backend_get_time(backend)
            dt = now - last_time
            last_time = now

            backend_poll_events!(backend)

            # Snapshot input state for edge detection (just_pressed / just_released)
            begin_frame!(backend_get_input(backend))

            # Clear per-frame caches
            clear_world_transform_cache!()

            # Update UI input state
            if _UI_CONTEXT[] !== nothing
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
                if backend isa OpenGLBackend && isempty(ctx.font_atlas.glyphs) && isempty(ctx.font_path)
                    ctx.font_atlas = get_or_create_font_atlas!("", 32)
                end

                # Sync keyboard and scroll state from input into UI context
                ctx.typed_chars = copy(input.typed_chars)
                ctx.keys_pressed = copy(input.keys_pressed)
                ctx.prev_keys_pressed = copy(input.prev_keys)
                ctx.scroll_x = input.scroll_delta[1]
                ctx.scroll_y = input.scroll_delta[2]
            end

            # Update player
            if controller !== nothing
                # Escape toggles cursor capture (always active regardless of UI focus)
                if backend_is_key_pressed(backend, KEY_ESCAPE)
                    backend_release_cursor!(backend)
                end

                # Suppress player movement when UI has keyboard focus
                if !(_UI_CONTEXT[] !== nothing && _UI_CONTEXT[].has_keyboard_focus)
                    update_player!(controller, backend_get_input(backend), dt)
                end
            end

            # Camera controllers step
            update_camera_controllers!(backend_get_input(backend), dt)

            # Animation step
            update_animations!(dt)
            update_blend_tree!(dt)

            # Skinning step (compute bone matrices after animation)
            update_skinned_meshes!()

            # Physics step (collision detection, gravity, resolution)
            update_physics!(dt)

            # Script step (per-entity script callbacks)
            update_scripts!(dt)

            # Audio step (sync listener/source positions with transforms)
            update_audio!(dt)

            # Particle step (emission, simulation, billboard generation)
            update_particles!(dt)

            # Terrain step (initialize new terrains, update chunk LODs)
            _cam_id = find_active_camera()
            if _cam_id !== nothing
                _cam_world = get_world_transform(_cam_id)
                _cam_pos = Vec3f(Float32(_cam_world[1, 4]), Float32(_cam_world[2, 4]), Float32(_cam_world[3, 4]))
                _view = get_view_matrix(_cam_id)
                _proj = get_projection_matrix(_cam_id)
                _frustum = extract_frustum(_proj * _view)
                update_terrain!(_cam_pos, _frustum)
            end

            # FSM on_update! — return StateTransition to switch states
            transition = nothing
            try
                transition = on_update!(current_state, current_scene, Float64(dt))
            catch e
                @warn "on_update! error for state $current_state_name" exception=e
            end

            if transition isa StateTransition
                # Exit current state
                try
                    on_exit!(current_state, current_scene)
                catch e
                    @warn "on_exit! error for state $current_state_name" exception=e
                end

                # Scene switch if new defs provided
                if transition.new_scene_defs !== nothing
                    current_scene = _execute_scene_switch!(backend, transition.new_scene_defs, on_scene_switch)
                    controller = _init_player_controller(current_scene, backend)
                end

                # Transition to new state
                current_state_name = transition.target
                current_state = fsm.states[current_state_name]

                # Enter new state
                try
                    on_enter!(current_state, current_scene)
                catch e
                    @warn "on_enter! error for state $current_state_name" exception=e
                end

                continue  # skip render this frame
            end

            # Wire UI callback from current state (falls back to ui kwarg)
            ui_cb = get_ui_callback(current_state)
            if ui_cb !== nothing
                _UI_CALLBACK[] = ui_cb
            elseif ui !== nothing
                _UI_CALLBACK[] = ui
            end

            # render_frame! handles 3D rendering + UI + swap_buffers
            render_frame!(backend, current_scene)
        end
    finally
        if _UI_CONTEXT[] !== nothing
            if backend isa OpenGLBackend
                shutdown_ui_renderer!()
            end
            _UI_CONTEXT[] = nothing
            _UI_CALLBACK[] = nothing
        end
        if backend isa OpenGLBackend
            shutdown_particle_renderer!()
            reset_terrain_gpu_caches!()
        end
        reset_particle_pools!()
        reset_terrain_cache!()
        shutdown_audio!()
        shutdown!(backend)
    end

    return nothing
end

render(fsm::GameStateMachine; kwargs...) = run_render_loop!(fsm; kwargs...)
