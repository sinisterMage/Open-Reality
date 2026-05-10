# PBR rendering pipeline: backend-agnostic render loop
# NOTE: OpenGL-specific code (PBR shaders, upload_lights!) moved to backend/opengl/

# Global UI state — set by run_render_loop!, read by render_frame!
const _UI_CALLBACK = Ref{Union{Function, Nothing}}(nothing)
const _UI_CONTEXT = Ref{Union{UIContext, Nothing}}(nothing)

# =============================================================================
# GPU Resource Lifecycle Management
# =============================================================================

"""
    flush_gpu_cleanup!(backend::AbstractBackend)

Drain the GPU cleanup queue and destroy GPU resources (meshes, bounding spheres)
for entities that were removed since the last flush.
Called once per frame before `render_frame!`.
"""
function flush_gpu_cleanup!(backend::AbstractBackend)
    entities = drain_gpu_cleanup_queue!()
    isempty(entities) && return nothing

    if hasproperty(backend, :gpu_cache)
        cache = backend.gpu_cache
        for eid in entities
            if haskey(cache.meshes, eid)
                destroy_gpu_mesh!(cache.meshes[eid])
                delete!(cache.meshes, eid)
            end
        end
    end

    if hasproperty(backend, :bounds_cache)
        for eid in entities
            delete!(backend.bounds_cache, eid)
        end
    end

    return nothing
end

"""
    cleanup_all_gpu_resources!(backend::AbstractBackend)

Destroy ALL GPU resources in the backend's caches. Used during scene switches
to prevent leaked resources from the previous scene.
"""
function cleanup_all_gpu_resources!(backend::AbstractBackend)
    drain_gpu_cleanup_queue!()

    if hasproperty(backend, :gpu_cache)
        destroy_all!(backend.gpu_cache)
    end

    if hasproperty(backend, :texture_cache)
        destroy_all_textures!(backend.texture_cache)
    end

    if hasproperty(backend, :bounds_cache)
        empty!(backend.bounds_cache)
    end

    return nothing
end

function _execute_scene_switch!(backend::AbstractBackend, new_defs::Vector, on_scene_switch::Union{Function, Nothing})
    # Snapshot on_destroy callbacks BEFORE reset
    script_entities = entities_with_component(ScriptComponent)
    for eid in script_entities
        comp = get_component(eid, ScriptComponent)
        if comp !== nothing && comp.on_destroy !== nothing
            try
                comp.on_destroy(eid, nothing)  # No GameContext during scene switch; on_destroy receives nothing
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
    # Destroy all GPU resources from the previous scene to prevent leaks
    cleanup_all_gpu_resources!(backend)
    # Build the new scene AFTER reset
    return scene(new_defs)
end

# =============================================================================
# Backend capability predicates
# =============================================================================
# Some backends (currently only OpenGL) keep their UI / particle / terrain GPU
# state in module-level globals that the run-loop must explicitly initialize and
# tear down. Newer backends (Vulkan, Metal, WebGPU) own that state inside the
# backend struct and manage it inside `initialize!` / `shutdown!`. These
# predicates encode that distinction so the loop stays backend-agnostic.

"""
    _uses_global_particle_renderer(backend) -> Bool

True for backends whose particle renderer lives in module-level globals and
must be initialized via `init_particle_renderer!()` before first use.
"""
_uses_global_particle_renderer(backend::AbstractBackend) = backend isa OpenGLBackend

"""
    _uses_global_ui_renderer(backend) -> Bool

True for backends whose UI renderer (and font atlas) lives in module-level
globals and must be initialized via `init_ui_renderer!()` before first use.
"""
_uses_global_ui_renderer(backend::AbstractBackend) = backend isa OpenGLBackend

"""
    _uses_global_terrain_caches(backend) -> Bool

True for backends whose terrain GPU caches live in module-level globals and
must be reset via `reset_terrain_gpu_caches!()` on shutdown / scene switch.
"""
_uses_global_terrain_caches(backend::AbstractBackend) = backend isa OpenGLBackend

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
    run_render_loop!(scene::Scene; backend=default_backend(), width=1280, height=720, title="OpenReality", ui=nothing, on_update=nothing, on_scene_switch=nothing)

Main render loop. Creates a window, initializes the backend, and renders the scene
until the window is closed.

The default backend is platform-aware: `VulkanBackend()` on Linux/Windows and
`MetalBackend()` on macOS. Pass `backend=OpenGLBackend()` for the legacy OpenGL path.

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
                          backend::AbstractBackend = default_backend(),
                          width::Int = 1280,
                          height::Int = 720,
                          title::String = "OpenReality",
                          post_process::Union{PostProcessConfig, Nothing} = nothing,
                          ui::Union{Function, Nothing} = nothing,
                          on_update::Union{Function, Nothing} = nothing,
                          on_scene_switch::Union{Function, Nothing} = nothing)
    initialize!(backend, width=width, height=height, title=title)

    # Spin up the engine-wide EEVDF task scheduler so the first frame
    # doesn't pay worker spawn cost. Torn down in the finally block.
    init_scheduler!()

    current_scene = initial_scene

    # Initialize audio system
    init_audio!()

    # Initialize global particle renderer for backends that need it (OpenGL).
    # Backends that own their particle renderer internally (Vulkan/Metal/WebGPU) skip this.
    if _uses_global_particle_renderer(backend)
        init_particle_renderer!()
    end

    # Initialize UI renderer if callback provided
    if ui !== nothing
        if _uses_global_ui_renderer(backend)
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
            ctx = GameContext(current_scene, backend_get_input(backend))

            # Clear per-frame caches
            clear_world_transform_cache!()

            # Poll async asset loads — spawn completed models via GameContext
            if _ASYNC_LOADER[] !== nothing
                for result in poll_async_loads!(_ASYNC_LOADER[])
                    if result.entities !== nothing
                        for edef in result.entities
                            spawn!(ctx, edef)
                        end
                    else
                        @warn "Async load failed" path=result.path error=result.error
                    end
                end
            end

            # Update UI input state
            if _UI_CONTEXT[] !== nothing && _UI_CALLBACK[] !== nothing
                ui_ctx = _UI_CONTEXT[]
                input = backend_get_input(backend)
                mx, my = get_mouse_position(input)
                mouse_down_now = 0 in input.mouse_buttons  # GLFW.MOUSE_BUTTON_LEFT = 0
                ui_ctx.mouse_x = mx
                ui_ctx.mouse_y = my
                ui_ctx.mouse_clicked = mouse_down_now && !prev_mouse_down
                ui_ctx.mouse_down = mouse_down_now
                prev_mouse_down = mouse_down_now

                # Update screen dimensions
                if hasproperty(backend, :window)
                    ui_ctx.width = backend.window.width
                    ui_ctx.height = backend.window.height
                end

                # Initialize the global font atlas on first frame for backends that
                # rely on it (OpenGL needs a live GL context). Vulkan/Metal/WebGPU
                # build per-backend atlases lazily on demand.
                if _uses_global_ui_renderer(backend) && isempty(ui_ctx.font_atlas.glyphs) && isempty(ui_ctx.font_path)
                    ui_ctx.font_atlas = get_or_create_font_atlas!("", 32)
                end

                # Sync keyboard and scroll state from input into UI context
                ui_ctx.typed_chars = copy(input.typed_chars)
                ui_ctx.keys_pressed = copy(input.keys_pressed)
                ui_ctx.prev_keys_pressed = copy(input.prev_keys)
                ui_ctx.scroll_x = input.scroll_delta[1]
                ui_ctx.scroll_y = input.scroll_delta[2]
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

            profiler_begin_frame!()

            # Animation step
            profiler_scope!("Animation") do
                update_animations!(dt)
                update_blend_tree!(dt)
            end

            # Skinning step (compute bone matrices after animation)
            update_skinned_meshes!()

            # Physics step (collision detection, gravity, resolution)
            profiler_scope!("Physics") do
                update_physics!(dt)
            end

            # Script step (per-entity script callbacks)
            profiler_scope!("Scripts") do
                update_scripts!(dt, ctx)
            end

            # Gameplay systems step
            profiler_scope!("Gameplay") do
                update_timers!(dt)
                update_coroutines!(dt)
                update_tweens!(dt)
                update_behavior_trees!(dt)
                update_nav_agents!(dt)
                update_health_system!(ctx)
                update_pickups!(dt, ctx)
            end

            # Audio step (sync listener/source positions with transforms)
            update_audio!(dt)

            # Particle step (emission, simulation, billboard generation)
            profiler_scope!("Particles") do
                update_particles!(dt)
            end

            # Terrain step (initialize new terrains, update chunk LODs)
            _cam_id = find_active_camera()
            if _cam_id !== nothing
                _cam_world = get_world_transform(_cam_id)
                _cam_pos = Vec3f(Float32(_cam_world[1, 4]), Float32(_cam_world[2, 4]), Float32(_cam_world[3, 4]))
                _view = get_view_matrix(_cam_id)
                _proj = get_projection_matrix(_cam_id)
                _frustum = extract_frustum(_proj * _view)
                update_terrain!(_cam_pos, _frustum)
                update_vegetation!(_cam_pos)
                update_structures!(_cam_pos)
            end

            # Dialogue & debug console input (consume before game logic)
            update_dialogue_input!(backend_get_input(backend))
            update_debug_console!(backend_get_input(backend), dt)

            # Game config + script hot-reload
            check_config_reload!()
            check_hot_reload!()

            # on_update callback — return Vector{EntityDef} to trigger scene switch
            if on_update !== nothing
                result = on_update(current_scene, dt, ctx)
                if result isa Vector
                    current_scene = _execute_scene_switch!(backend, result, on_scene_switch)
                    controller = _init_player_controller(current_scene, backend)
                    continue
                end
            end

            current_scene = apply_mutations!(ctx, current_scene)
            flush_deferred_events!()

            # Free GPU resources for entities removed this frame
            flush_gpu_cleanup!(backend)

            # render_frame! handles 3D rendering + UI + swap_buffers
            profiler_scope!("Render") do
                render_frame!(backend, current_scene)
            end

            profiler_end_frame!()
            flush_debug_draw!()
        end
    finally
        if _UI_CONTEXT[] !== nothing
            if _uses_global_ui_renderer(backend)
                shutdown_ui_renderer!()
            end
            _UI_CONTEXT[] = nothing
            _UI_CALLBACK[] = nothing
        end
        if _uses_global_particle_renderer(backend)
            shutdown_particle_renderer!()
        end
        if _uses_global_terrain_caches(backend)
            reset_terrain_gpu_caches!()
        end
        reset_particle_pools!()
        reset_terrain_cache!()
        reset_async_loader!()
        shutdown_audio!()
        cleanup_all_gpu_resources!(backend)
        # Tear down the engine-wide EEVDF scheduler last so any cleanup
        # paths above are still able to submit/await scheduler tasks.
        shutdown_scheduler!()
        shutdown!(backend)
    end

    return nothing
end

"""
    run_render_loop!(fsm::GameStateMachine; backend=default_backend(), width=1280, height=720, title="OpenReality", post_process=nothing, ui=nothing, on_scene_switch=nothing)

FSM-driven render loop. Uses a `GameStateMachine` to manage game states and transitions
instead of a single `on_update` callback. Each state receives `on_enter!`, `on_update!`,
and `on_exit!` lifecycle hooks. Return a `StateTransition` from `on_update!` to switch states.

The default backend is platform-aware (see [`default_backend`](@ref)).
"""
function run_render_loop!(fsm::GameStateMachine;
                          backend::AbstractBackend = default_backend(),
                          width::Int = 1280,
                          height::Int = 720,
                          title::String = "OpenReality",
                          post_process::Union{PostProcessConfig, Nothing} = nothing,
                          ui::Union{Function, Nothing} = nothing,
                          on_scene_switch::Union{Function, Nothing} = nothing)
    initialize!(backend, width=width, height=height, title=title)

    # Spin up the engine-wide EEVDF task scheduler. Torn down in finally.
    init_scheduler!()

    current_scene = scene(fsm.initial_scene_defs)

    # Initialize audio system
    init_audio!()

    # Initialize global particle renderer for backends that need it (OpenGL).
    # Backends that own their particle renderer internally (Vulkan/Metal/WebGPU) skip this.
    if _uses_global_particle_renderer(backend)
        init_particle_renderer!()
    end

    # Initialize global UI renderer for backends that need it (OpenGL).
    if _uses_global_ui_renderer(backend)
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
            ctx = GameContext(current_scene, backend_get_input(backend))

            # Clear per-frame caches
            clear_world_transform_cache!()

            # Poll async asset loads — spawn completed models via GameContext
            if _ASYNC_LOADER[] !== nothing
                for result in poll_async_loads!(_ASYNC_LOADER[])
                    if result.entities !== nothing
                        for edef in result.entities
                            spawn!(ctx, edef)
                        end
                    else
                        @warn "Async load failed" path=result.path error=result.error
                    end
                end
            end

            # Update UI input state
            if _UI_CONTEXT[] !== nothing
                ui_ctx = _UI_CONTEXT[]
                input = backend_get_input(backend)
                mx, my = get_mouse_position(input)
                mouse_down_now = 0 in input.mouse_buttons  # GLFW.MOUSE_BUTTON_LEFT = 0
                ui_ctx.mouse_x = mx
                ui_ctx.mouse_y = my
                ui_ctx.mouse_clicked = mouse_down_now && !prev_mouse_down
                ui_ctx.mouse_down = mouse_down_now
                prev_mouse_down = mouse_down_now

                # Update screen dimensions
                if hasproperty(backend, :window)
                    ui_ctx.width = backend.window.width
                    ui_ctx.height = backend.window.height
                end

                # Initialize the global font atlas on first frame for backends that
                # rely on it (OpenGL needs a live GL context). Vulkan/Metal/WebGPU
                # build per-backend atlases lazily on demand.
                if _uses_global_ui_renderer(backend) && isempty(ui_ctx.font_atlas.glyphs) && isempty(ui_ctx.font_path)
                    ui_ctx.font_atlas = get_or_create_font_atlas!("", 32)
                end

                # Sync keyboard and scroll state from input into UI context
                ui_ctx.typed_chars = copy(input.typed_chars)
                ui_ctx.keys_pressed = copy(input.keys_pressed)
                ui_ctx.prev_keys_pressed = copy(input.prev_keys)
                ui_ctx.scroll_x = input.scroll_delta[1]
                ui_ctx.scroll_y = input.scroll_delta[2]
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

            profiler_begin_frame!()

            # Animation step
            profiler_scope!("Animation") do
                update_animations!(dt)
                update_blend_tree!(dt)
            end

            # Skinning step (compute bone matrices after animation)
            update_skinned_meshes!()

            # Physics step (collision detection, gravity, resolution)
            profiler_scope!("Physics") do
                update_physics!(dt)
            end

            # Script step (per-entity script callbacks)
            profiler_scope!("Scripts") do
                update_scripts!(dt, ctx)
            end

            # Gameplay systems step
            profiler_scope!("Gameplay") do
                update_timers!(dt)
                update_coroutines!(dt)
                update_tweens!(dt)
                update_behavior_trees!(dt)
                update_nav_agents!(dt)
                update_health_system!(ctx)
                update_pickups!(dt, ctx)
            end

            # Audio step (sync listener/source positions with transforms)
            update_audio!(dt)

            # Particle step (emission, simulation, billboard generation)
            profiler_scope!("Particles") do
                update_particles!(dt)
            end

            # Terrain step (initialize new terrains, update chunk LODs)
            _cam_id = find_active_camera()
            if _cam_id !== nothing
                _cam_world = get_world_transform(_cam_id)
                _cam_pos = Vec3f(Float32(_cam_world[1, 4]), Float32(_cam_world[2, 4]), Float32(_cam_world[3, 4]))
                _view = get_view_matrix(_cam_id)
                _proj = get_projection_matrix(_cam_id)
                _frustum = extract_frustum(_proj * _view)
                update_terrain!(_cam_pos, _frustum)
                update_vegetation!(_cam_pos)
                update_structures!(_cam_pos)
            end

            # Dialogue & debug console input (consume before game logic)
            update_dialogue_input!(backend_get_input(backend))
            update_debug_console!(backend_get_input(backend), dt)

            # Game config + script hot-reload
            check_config_reload!()
            check_hot_reload!()

            # FSM on_update! — return StateTransition to switch states
            transition = nothing
            try
                transition = on_update!(current_state, current_scene, Float64(dt), ctx)
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

                # Apply queued mutations if the scene was not replaced
                if transition.new_scene_defs === nothing
                    current_scene = apply_mutations!(ctx, current_scene)
                end
                flush_deferred_events!()
                continue  # skip render this frame
            end

            current_scene = apply_mutations!(ctx, current_scene)
            flush_deferred_events!()

            # Wire UI callback from current state (falls back to ui kwarg)
            ui_cb = get_ui_callback(current_state)
            if ui_cb !== nothing
                _UI_CALLBACK[] = ui_cb
            elseif ui !== nothing
                _UI_CALLBACK[] = ui
            end

            # Free GPU resources for entities removed this frame
            flush_gpu_cleanup!(backend)

            # render_frame! handles 3D rendering + UI + swap_buffers
            profiler_scope!("Render") do
                render_frame!(backend, current_scene)
            end

            profiler_end_frame!()
            flush_debug_draw!()
        end
    finally
        if _UI_CONTEXT[] !== nothing
            if _uses_global_ui_renderer(backend)
                shutdown_ui_renderer!()
            end
            _UI_CONTEXT[] = nothing
            _UI_CALLBACK[] = nothing
        end
        if _uses_global_particle_renderer(backend)
            shutdown_particle_renderer!()
        end
        if _uses_global_terrain_caches(backend)
            reset_terrain_gpu_caches!()
        end
        reset_particle_pools!()
        reset_terrain_cache!()
        reset_async_loader!()
        shutdown_audio!()
        cleanup_all_gpu_resources!(backend)
        # Tear down the engine-wide EEVDF scheduler last.
        shutdown_scheduler!()
        shutdown!(backend)
    end

    return nothing
end

render(fsm::GameStateMachine; kwargs...) = run_render_loop!(fsm; kwargs...)
