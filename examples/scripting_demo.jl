# Scripting & Scene Switching Demo (FSM version)
# Demonstrates all recently added features using the GameStateMachine API:
#   1. ScriptComponent      — entity lifecycle callbacks (on_start/on_update/on_destroy)
#   2. Script System         — update_scripts! runs each frame automatically
#   3. CollisionCallbacks    — on_collision_enter/stay/exit detection
#   4. Scene Switching       — FSM StateTransition triggers scene switch
#   5. destroy_entity!       — removes entities at runtime, fires on_destroy
#   6. reset_engine_state!   — clears all ECS/physics/particles during scene switch
#   7. clear_audio_sources!  — stops OpenAL sources between scenes
#   8. GameStateMachine      — structured state management with on_enter!/on_update!/on_exit!
#
# Run with:
#   julia --project=. examples/scripting_demo.jl

using OpenReality

# =============================================================================
# Shared State (persists across scene switches via Refs)
# =============================================================================

const scene_name        = Ref("Arena")
const timer_seconds     = Ref(30.0)
const switch_requested  = Ref(false)
const total_switches    = Ref(0)
const frame_count       = Ref(0)

# =============================================================================
# Scene 1: "The Arena" — collectibles, physics, collision callbacks
# =============================================================================

function make_bobbing_script(base_y::Float64; speed::Float64=3.0, amplitude::Float64=0.5)
    time_acc = Ref(0.0)
    ScriptComponent(
        on_start = (eid, ctx) -> println("  [Script] Collectible $eid spawned at y=$base_y"),
        on_update = (eid, dt, ctx) -> begin
            time_acc[] += dt
            tc = get_component(eid, TransformComponent)
            tc === nothing && return
            pos = tc.position[]
            new_y = base_y + amplitude * sin(speed * time_acc[])
            tc.position[] = Vec3d(pos[1], new_y, pos[3])
        end,
        on_destroy = (eid, ctx) -> begin
            println("  [Script] Collectible $eid destroyed!")
        end
    )
end

function make_spin_script(rotation_speed::Float64=1.0)
    ScriptComponent(
        on_update = (eid, dt, ctx) -> begin
            tc = get_component(eid, TransformComponent)
            tc === nothing && return
            angle = rotation_speed * dt
            rot_delta = Quaterniond(cos(angle / 2), 0.0, sin(angle / 2), 0.0)
            tc.rotation[] = tc.rotation[] * rot_delta
        end,
        on_destroy = (eid, ctx) -> println("  [Script] Spinning box $eid removed")
    )
end

function collectible(pos::Vec3d, color::RGB{Float32}, entities_to_destroy::Vector{EntityID}, collision_count::Ref{Int}; base_y::Float64=pos[2])
    entity([
        sphere_mesh(radius=0.4f0),
        MaterialComponent(
            color=color,
            metallic=0.5f0,
            roughness=0.3f0,
            emissive_factor=Vec3f(color.r * 0.3f0, color.g * 0.3f0, color.b * 0.3f0)
        ),
        transform(position=pos),
        ColliderComponent(shape=SphereShape(0.4f0)),
        RigidBodyComponent(body_type=BODY_KINEMATIC),
        make_bobbing_script(base_y),
        CollisionCallbackComponent(
            on_collision_enter = (this_eid, other_eid, manifold) -> begin
                collision_count[] += 1
                println("  [Collision] Collectible $(this_eid) hit by $(other_eid)!")
                push!(entities_to_destroy, this_eid)
            end
        )
    ])
end

function spinning_box(pos::Vec3d, color::RGB{Float32}; mass=1.0, speed=1.5)
    entity([
        cube_mesh(),
        MaterialComponent(color=color, metallic=0.6f0, roughness=0.3f0),
        transform(position=pos),
        ColliderComponent(shape=AABBShape(Vec3f(0.5, 0.5, 0.5))),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=mass, restitution=0.4f0),
        make_spin_script(speed),
        CollisionCallbackComponent(
            on_collision_enter = (this_eid, other_eid, manifold) -> begin
                println("  [Collision] Box $this_eid hit entity $other_eid")
            end
        )
    ])
end

function build_arena_defs(entities_to_destroy::Vector{EntityID}, collision_count::Ref{Int})
    [
        # --- Player ---
        create_player(position=Vec3d(0, 2.0, 12)),

        # --- Lighting ---
        entity([
            DirectionalLightComponent(
                direction=Vec3f(0.4, -1.0, -0.3),
                intensity=3.0f0,
                color=RGB{Float32}(1.0, 0.95, 0.85)
            )
        ]),
        entity([
            PointLightComponent(
                color=RGB{Float32}(1.0, 0.7, 0.4),
                intensity=25.0f0,
                range=20.0f0
            ),
            transform(position=Vec3d(3, 5, 2))
        ]),

        # --- Ground ---
        entity([
            plane_mesh(width=30.0f0, depth=30.0f0),
            MaterialComponent(
                color=RGB{Float32}(0.35, 0.38, 0.35),
                metallic=0.0f0,
                roughness=0.9f0
            ),
            transform(),
            ColliderComponent(shape=AABBShape(Vec3f(15.0, 0.01, 15.0)), offset=Vec3f(0, -0.01, 0)),
            RigidBodyComponent(body_type=BODY_STATIC)
        ]),

        # --- Bobbing Collectibles ---
        collectible(Vec3d(-3, 1.5, 0),  RGB{Float32}(0.2, 0.9, 0.3), entities_to_destroy, collision_count),
        collectible(Vec3d( 0, 1.5, -3), RGB{Float32}(0.9, 0.8, 0.1), entities_to_destroy, collision_count),
        collectible(Vec3d( 3, 1.5, 2),  RGB{Float32}(0.1, 0.7, 0.9), entities_to_destroy, collision_count),

        # --- Dynamic Spinning Boxes ---
        spinning_box(Vec3d(-2, 5, -2), RGB{Float32}(0.9, 0.2, 0.2), speed=2.0),
        spinning_box(Vec3d( 2, 7, -1), RGB{Float32}(0.2, 0.3, 0.9), speed=1.2),
    ]
end

# =============================================================================
# Scene 2: "The Gallery" — rotating pedestals, particles, calm atmosphere
# =============================================================================

function make_pedestal_script(label::String; speed::Float64=0.8)
    ScriptComponent(
        on_start = (eid, ctx) -> println("  [Script] Pedestal '$label' (entity $eid) initialized"),
        on_update = (eid, dt, ctx) -> begin
            tc = get_component(eid, TransformComponent)
            tc === nothing && return
            angle = speed * dt
            rot_delta = Quaterniond(cos(angle / 2), 0.0, sin(angle / 2), 0.0)
            tc.rotation[] = tc.rotation[] * rot_delta
        end,
        on_destroy = (eid, ctx) -> println("  [Script] Pedestal '$label' (entity $eid) teardown")
    )
end

function build_gallery_defs()
    bob_time = Ref(0.0)

    [
        # --- Player ---
        create_player(position=Vec3d(0, 2.0, 8)),

        # --- Cooler lighting ---
        entity([
            DirectionalLightComponent(
                direction=Vec3f(0.2, -0.9, -0.5),
                intensity=2.0f0,
                color=RGB{Float32}(0.85, 0.9, 1.0)
            )
        ]),
        entity([
            PointLightComponent(
                color=RGB{Float32}(0.4, 0.5, 1.0),
                intensity=20.0f0,
                range=18.0f0
            ),
            transform(position=Vec3d(0, 5, 0))
        ]),

        # --- Ground ---
        entity([
            plane_mesh(width=20.0f0, depth=20.0f0),
            MaterialComponent(
                color=RGB{Float32}(0.25, 0.25, 0.3),
                metallic=0.0f0,
                roughness=0.85f0
            ),
            transform(),
            ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
            RigidBodyComponent(body_type=BODY_STATIC)
        ]),

        # --- Rotating Pedestals ---
        entity([
            cube_mesh(size=1.2f0),
            MaterialComponent(
                color=RGB{Float32}(0.95, 0.8, 0.2),   # gold
                metallic=0.95f0,
                roughness=0.1f0
            ),
            transform(position=Vec3d(-3, 0.6, 0)),
            make_pedestal_script("Gold", speed=0.6),
        ]),
        entity([
            cube_mesh(size=1.2f0),
            MaterialComponent(
                color=RGB{Float32}(0.85, 0.85, 0.9),   # silver
                metallic=0.9f0,
                roughness=0.15f0
            ),
            transform(position=Vec3d(0, 0.6, 0)),
            make_pedestal_script("Silver", speed=0.8),
        ]),
        entity([
            cube_mesh(size=1.2f0),
            MaterialComponent(
                color=RGB{Float32}(0.8, 0.5, 0.2),   # bronze
                metallic=0.85f0,
                roughness=0.2f0
            ),
            transform(position=Vec3d(3, 0.6, 0)),
            make_pedestal_script("Bronze", speed=1.0),
        ]),

        # --- Sparkle Particle Emitter ---
        entity([
            transform(position=Vec3d(0, 3, 0)),
            ParticleSystemComponent(
                max_particles=150,
                emission_rate=30.0f0,
                lifetime_min=0.8f0,
                lifetime_max=2.5f0,
                velocity_min=Vec3f(-0.5f0, 0.5f0, -0.5f0),
                velocity_max=Vec3f(0.5f0, 2.0f0, 0.5f0),
                gravity_modifier=0.0f0,
                damping=0.2f0,
                start_size_min=0.02f0,
                start_size_max=0.06f0,
                end_size=0.01f0,
                start_color=RGB{Float32}(0.8, 0.9, 1.0),
                end_color=RGB{Float32}(0.3, 0.5, 1.0),
                start_alpha=0.8f0,
                end_alpha=0.0f0,
                additive=true
            ),
            ScriptComponent(
                on_start = (eid, ctx) -> println("  [Script] Gallery sparkles active"),
                on_destroy = (eid, ctx) -> println("  [Script] Gallery sparkles deactivated")
            )
        ]),

        # --- Bobbing Sentinel Sphere ---
        entity([
            sphere_mesh(radius=0.5f0),
            MaterialComponent(
                color=RGB{Float32}(0.2, 0.4, 0.9),
                metallic=0.3f0,
                roughness=0.4f0,
                emissive_factor=Vec3f(0.15f0, 0.3f0, 0.7f0)
            ),
            transform(position=Vec3d(0, 2, -4)),
            ScriptComponent(
                on_start = (eid, ctx) -> println("  [Script] Sentinel sphere $eid watching..."),
                on_update = (eid, dt, ctx) -> begin
                    bob_time[] += dt
                    tc = get_component(eid, TransformComponent)
                    tc === nothing && return
                    pos = tc.position[]
                    tc.position[] = Vec3d(pos[1], 2.0 + 0.4 * sin(bob_time[] * 2.0), pos[3])
                end,
                on_destroy = (eid, ctx) -> println("  [Script] Sentinel sphere $eid deactivated")
            )
        ]),
    ]
end

# =============================================================================
# Game States
# =============================================================================

mutable struct ArenaState <: GameState
    timer::Float64
    collision_count::Int
    destroyed_count::Int
    entities_to_destroy::Vector{EntityID}
end

mutable struct GalleryState <: GameState
    timer::Float64
end

function OpenReality.on_enter!(state::ArenaState, sc::Scene)
    state.timer = 30.0
    state.collision_count = 0
    state.destroyed_count = 0
    empty!(state.entities_to_destroy)
    scene_name[] = "Arena"
    timer_seconds[] = state.timer
    println("  [FSM] Entered Arena state")
end

function OpenReality.on_update!(state::ArenaState, sc::Scene, dt::Float64, ctx::GameContext)
    frame_count[] += 1

    # Process deferred entity destructions (queued by collision callbacks)
    for eid in state.entities_to_destroy
        if has_entity(sc, eid)
            state.destroyed_count += 1
            despawn!(ctx, eid)
        end
    end
    empty!(state.entities_to_destroy)

    # Decrement timer
    state.timer -= dt
    timer_seconds[] = state.timer

    # Check for scene switch request
    if switch_requested[] || state.timer <= 0
        switch_requested[] = false
        total_switches[] += 1
        return StateTransition(:gallery, build_gallery_defs())
    end

    return nothing
end

function OpenReality.on_exit!(state::ArenaState, sc::Scene)
    println("  [FSM] Exiting Arena state (collisions: $(state.collision_count), destroyed: $(state.destroyed_count))")
end

function OpenReality.on_enter!(state::GalleryState, sc::Scene)
    state.timer = 30.0
    scene_name[] = "Gallery"
    timer_seconds[] = state.timer
    println("  [FSM] Entered Gallery state")
end

function OpenReality.on_update!(state::GalleryState, sc::Scene, dt::Float64, ctx::GameContext)
    frame_count[] += 1

    # Decrement timer
    state.timer -= dt
    timer_seconds[] = state.timer

    # Check for scene switch request
    if switch_requested[] || state.timer <= 0
        switch_requested[] = false
        total_switches[] += 1
        arena_state = ArenaState(30.0, 0, 0, EntityID[])
        return StateTransition(:arena, build_arena_defs(arena_state.entities_to_destroy, Ref(arena_state.collision_count)))
    end

    return nothing
end

function OpenReality.on_exit!(state::GalleryState, sc::Scene)
    println("  [FSM] Exiting Gallery state")
end

# =============================================================================
# Scene Switching Hook
# =============================================================================

function custom_scene_switch(old_scene, new_defs)
    println()
    println("=" ^ 50)
    println("  [Scene Switch] Leaving '$(scene_name[])'")
    println("  [Scene Switch] Cleaning up...")
    reset_engine_state!()
    clear_audio_sources!()
    println("  [Scene Switch] Engine state reset. Building new scene...")
    println("=" ^ 50)
    println()
end

# =============================================================================
# UI Overlay
# =============================================================================

ui_callback = function(ctx::UIContext)
    # ── Title bar ──────────────────────────────────────────────────────
    ui_rect(ctx, x=0, y=0, width=ctx.width, height=48,
            color=RGB{Float32}(0.05, 0.05, 0.12), alpha=0.85f0)
    ui_text(ctx, "OpenReality — Scripting Demo  [$(scene_name[])]",
            x=12, y=12, size=26, color=RGB{Float32}(1.0, 1.0, 1.0))

    # ── Features panel (left) ──────────────────────────────────────────
    panel_x = 10
    panel_y = 60
    panel_w = 290
    panel_h = 260

    ui_rect(ctx, x=panel_x, y=panel_y, width=panel_w, height=panel_h,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.8f0)
    ui_text(ctx, "New Features", x=panel_x + 10, y=panel_y + 8, size=22,
            color=RGB{Float32}(0.9, 0.8, 0.3))

    features = [
        ("ScriptComponent",       RGB{Float32}(0.3, 1.0, 0.4)),
        ("Script System",         RGB{Float32}(0.3, 0.9, 0.5)),
        ("CollisionCallbacks",    RGB{Float32}(1.0, 0.5, 0.3)),
        ("Scene Switching",       RGB{Float32}(0.4, 0.7, 1.0)),
        ("destroy_entity!",       RGB{Float32}(1.0, 0.4, 0.4)),
        ("reset_engine_state!",   RGB{Float32}(0.8, 0.6, 1.0)),
        ("clear_audio_sources!",  RGB{Float32}(0.6, 0.8, 0.9)),
        ("GameStateMachine",      RGB{Float32}(0.9, 0.6, 0.2)),
    ]
    for (i, (name, color)) in enumerate(features)
        ui_text(ctx, "* $name", x=panel_x + 15, y=panel_y + 22 + i * 26, size=16, color=color)
    end

    # ── Stats panel (right) ────────────────────────────────────────────
    stats_w = 240
    stats_x = ctx.width - stats_w - 10
    stats_y = 60

    ui_rect(ctx, x=stats_x, y=stats_y, width=stats_w, height=180,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.8f0)
    ui_text(ctx, "Live Stats", x=stats_x + 10, y=stats_y + 8, size=22,
            color=RGB{Float32}(0.3, 0.8, 1.0))

    timer_color = timer_seconds[] > 10 ? RGB{Float32}(0.8, 0.8, 0.8) : RGB{Float32}(1.0, 0.3, 0.3)
    stats = [
        ("Scene: $(scene_name[])",                         RGB{Float32}(0.8, 0.8, 0.8)),
        ("Timer: $(round(max(timer_seconds[], 0.0), digits=1))s", timer_color),
        ("Scene Switches: $(total_switches[])",            RGB{Float32}(0.4, 0.7, 1.0)),
    ]
    for (i, (text, color)) in enumerate(stats)
        ui_text(ctx, text, x=stats_x + 15, y=stats_y + 22 + i * 28, size=17, color=color)
    end

    # ── Scene switch button (bottom-center) ────────────────────────────
    target = scene_name[] == "Arena" ? "Gallery" : "Arena"
    btn_w = 200
    btn_x = (ctx.width - btn_w) / 2
    btn_y = ctx.height - 60

    if ui_button(ctx, "Switch to $target", x=btn_x, y=btn_y, width=btn_w, height=40,
                 color=RGB{Float32}(0.2, 0.5, 0.8),
                 hover_color=RGB{Float32}(0.3, 0.6, 0.9),
                 text_size=18)
        switch_requested[] = true
    end

    # ── Timer progress bar ─────────────────────────────────────────────
    progress = Float32(clamp(timer_seconds[] / 30.0, 0.0, 1.0))
    ui_progress_bar(ctx, progress, x=btn_x - 50, y=btn_y + 46, width=btn_w + 100, height=10,
                    color=timer_seconds[] > 10 ? RGB{Float32}(0.2, 0.7, 0.3) : RGB{Float32}(0.9, 0.2, 0.2))

    # ── Controls hint ──────────────────────────────────────────────────
    ui_text(ctx, "WASD: Move  |  Mouse: Look  |  Shift: Sprint  |  Esc: Release cursor",
            x=ctx.width - 530, y=ctx.height - 15, size=13,
            color=RGB{Float32}(0.5, 0.5, 0.5))
end

# =============================================================================
# Startup
# =============================================================================

println("=" ^ 70)
println("  OpenReality — Scripting & Scene Switching Demo (FSM)")
println("=" ^ 70)
println()
println("  New features demonstrated:")
println("    1. ScriptComponent      — on_start / on_update / on_destroy lifecycle")
println("    2. Script System        — update_scripts! runs each frame automatically")
println("    3. CollisionCallbacks   — on_collision_enter / stay / exit detection")
println("    4. Scene Switching      — FSM StateTransition triggers scene switch")
println("    5. destroy_entity!      — runtime entity removal, fires on_destroy")
println("    6. reset_engine_state!  — central cleanup during scene switch")
println("    7. clear_audio_sources! — safe audio teardown between scenes")
println("    8. GameStateMachine     — structured state management")
println()
println("  Controls: WASD to move, mouse to look, Shift to sprint, Esc to release cursor")
println("            Click 'Switch Scene' button or wait 30s for automatic switch")
println("=" ^ 70)
println()

reset_entity_counter!()
reset_component_stores!()

arena = ArenaState(30.0, 0, 0, EntityID[])
fsm = GameStateMachine(:arena, build_arena_defs(arena.entities_to_destroy, Ref(arena.collision_count)))
add_state!(fsm, :arena, arena)
add_state!(fsm, :gallery, GalleryState(30.0))

render(fsm,
    on_scene_switch=custom_scene_switch,
    ui=ui_callback,
    title="OpenReality — Scripting Demo",
    post_process=PostProcessConfig(
        tone_mapping=TONEMAP_ACES,
        bloom_enabled=true,
        bloom_intensity=0.3f0,
        fxaa_enabled=true
    )
)
