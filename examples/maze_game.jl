# First-Person 3D Maze Game
# Demonstrates gameplay features: FSM, ScriptComponent, physics colliders,
# triggers, collision callbacks, particles, UI overlay, and post-processing.
#
# Navigate the maze to reach the glowing goal. A timer tracks your speed.
#
# Run with:
#   julia --project=. examples/maze_game.jl

using OpenReality

# =============================================================================
# Maze Layout (15×15 grid: 1 = wall, 0 = path, 2 = goal)
# =============================================================================

const MAZE = [
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
    1 0 0 0 1 0 0 0 0 0 1 0 0 0 1
    1 0 1 0 1 0 1 1 1 0 1 0 1 0 1
    1 0 1 0 0 0 0 0 1 0 0 0 1 0 1
    1 0 1 1 1 1 1 0 1 1 1 0 1 0 1
    1 0 0 0 0 0 1 0 0 0 0 0 1 0 1
    1 1 1 1 1 0 1 1 1 1 1 1 1 0 1
    1 0 0 0 0 0 0 0 0 0 0 0 0 0 1
    1 0 1 1 1 1 1 0 1 1 1 1 1 0 1
    1 0 1 0 0 0 1 0 1 0 0 0 0 0 1
    1 0 1 0 1 0 0 0 1 0 1 1 1 1 1
    1 0 0 0 1 1 1 0 1 0 0 0 0 0 1
    1 0 1 0 0 0 1 0 1 1 1 1 1 0 1
    1 0 1 0 1 0 0 0 0 0 0 0 0 2 1
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
]

const WALL_HEIGHT = 3.0
const CELL_SIZE = 2.0   # each cell is 2×2 units

# =============================================================================
# Maze Builder — creates wall entities, floor, and goal marker
# =============================================================================

function grid_to_world(row::Int, col::Int)
    # Center the maze around the origin
    rows, cols = size(MAZE)
    x = (col - 1 - (cols - 1) / 2) * CELL_SIZE
    z = (row - 1 - (rows - 1) / 2) * CELL_SIZE
    return (x, z)
end

function world_to_grid(x::Real, z::Real)
    rows, cols = size(MAZE)
    col = round(Int, x / CELL_SIZE + (cols - 1) / 2) + 1
    row = round(Int, z / CELL_SIZE + (rows - 1) / 2) + 1
    return (row, col)
end

function is_wall_at(x::Real, z::Real)
    row, col = world_to_grid(x, z)
    rows, cols = size(MAZE)
    (row < 1 || row > rows || col < 1 || col > cols) && return true
    return MAZE[row, col] == 1
end

const PLAYER_RADIUS = 0.35

function build_maze_entities()
    entities = Any[]
    rows, cols = size(MAZE)
    goal_pos = Vec3d(0, 0, 0)

    # Wall material
    wall_color = RGB{Float32}(0.45, 0.42, 0.38)
    floor_color = RGB{Float32}(0.3, 0.3, 0.32)
    goal_color = RGB{Float32}(0.1, 1.0, 0.4)

    for row in 1:rows, col in 1:cols
        x, z = grid_to_world(row, col)
        cell = MAZE[row, col]

        if cell == 1
            # Wall block — cube fills the full cell
            push!(entities, entity([
                cube_mesh(size=Float32(CELL_SIZE)),
                MaterialComponent(
                    color=wall_color,
                    roughness=0.85f0,
                    metallic=0.0f0
                ),
                transform(position=Vec3d(x, WALL_HEIGHT / 2, z),
                         scale=Vec3d(1.0, WALL_HEIGHT / CELL_SIZE, 1.0)),
                ColliderComponent(shape=AABBShape(Vec3f(
                    Float32(CELL_SIZE / 2),
                    Float32(WALL_HEIGHT / 2),
                    Float32(CELL_SIZE / 2)
                ))),
                RigidBodyComponent(body_type=BODY_STATIC)
            ]))
        elseif cell == 2
            # Goal position
            goal_pos = Vec3d(x, 0, z)
        end
    end

    # Floor
    floor_size = Float32(max(rows, cols) * CELL_SIZE)
    push!(entities, entity([
        plane_mesh(width=floor_size, depth=floor_size),
        MaterialComponent(color=floor_color, roughness=0.9f0, metallic=0.0f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(floor_size / 2, 0.01f0, floor_size / 2)),
                         offset=Vec3f(0, -0.01f0, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]))

    # Ceiling (optional — makes the maze feel enclosed)
    push!(entities, entity([
        plane_mesh(width=floor_size, depth=floor_size),
        MaterialComponent(color=RGB{Float32}(0.2, 0.2, 0.22), roughness=0.95f0),
        transform(position=Vec3d(0, WALL_HEIGHT, 0),
                 rotation=Quaterniond(cos(π / 2), sin(π / 2), 0.0, 0.0))
    ]))

    return entities, goal_pos
end

# =============================================================================
# Game States
# =============================================================================

mutable struct PlayingState <: GameState
    elapsed::Float64
    won::Bool
    goal_entity::EntityID
end

mutable struct WinState <: GameState
    final_time::Float64
end

# --- Playing State ---

function OpenReality.on_enter!(state::PlayingState, sc::Scene)
    state.elapsed = 0.0
    state.won = false
    println("  [Maze] Game started! Find the glowing goal.")
end

function OpenReality.on_update!(state::PlayingState, sc::Scene, dt::Float64, ctx::GameContext)
    state.elapsed += dt

    # Check if player reached the goal via collision callback
    if state.won
        return StateTransition(:win)
    end

    return nothing
end

function OpenReality.get_ui_callback(state::PlayingState)
    return function(ctx::UIContext)
        # Timer display
        ui_rect(ctx, x=0, y=0, width=ctx.width, height=40,
                color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.85f0)
        ui_text(ctx, "Maze Runner",
                x=12, y=8, size=24, color=RGB{Float32}(0.1, 1.0, 0.4))

        time_str = string(round(state.elapsed, digits=1), "s")
        ui_text(ctx, "Time: $time_str",
                x=ctx.width - 180, y=8, size=24, color=RGB{Float32}(1.0, 1.0, 1.0))

        # Controls hint
        ui_text(ctx, "WASD: Move  |  Mouse: Look  |  Shift: Sprint  |  Find the green glow!",
                x=ctx.width / 2 - 260, y=ctx.height - 20, size=13,
                color=RGB{Float32}(0.5, 0.5, 0.5))
    end
end

# --- Win State ---

function OpenReality.on_enter!(state::WinState, sc::Scene)
    println("  [Maze] Completed in $(round(state.final_time, digits=2))s!")
end

function OpenReality.on_update!(state::WinState, sc::Scene, dt::Float64, ctx::GameContext)
    # Press R to restart
    if ctx.input.keys_pressed[Int(GLFW.KEY_R) + 1]
        maze_entities, goal_pos = build_maze_entities()
        playing = PlayingState(0.0, false, EntityID(0))
        new_defs = build_full_scene(goal_pos, playing)
        return StateTransition(:playing, new_defs)
    end
    return nothing
end

function OpenReality.get_ui_callback(state::WinState)
    return function(ctx::UIContext)
        # Dark overlay
        ui_rect(ctx, x=0, y=0, width=ctx.width, height=ctx.height,
                color=RGB{Float32}(0.0, 0.0, 0.0), alpha=0.6f0)

        # Victory text
        cx = ctx.width / 2
        cy = ctx.height / 2
        ui_text(ctx, "MAZE COMPLETE!",
                x=cx - 140, y=cy - 50, size=40,
                color=RGB{Float32}(0.1, 1.0, 0.4))

        time_str = string(round(state.final_time, digits=2), "s")
        ui_text(ctx, "Your time: $time_str",
                x=cx - 100, y=cy + 10, size=28,
                color=RGB{Float32}(1.0, 1.0, 1.0))

        ui_text(ctx, "Press R to restart",
                x=cx - 80, y=cy + 60, size=20,
                color=RGB{Float32}(0.6, 0.6, 0.6))
    end
end

# =============================================================================
# Scene Builder
# =============================================================================

function build_full_scene(goal_pos::Vec3d, playing_state::PlayingState)
    maze_entities, _ = build_maze_entities()

    # Callbacks (extracted to avoid begin...end parsing issues in kwargs)
    win_callback = function(this_eid, other_eid, manifold)
        pc = get_component(other_eid, PlayerComponent)
        if pc !== nothing
            playing_state.won = true
        end
    end

    bob_callback = function(eid, dt, ctx)
        tc = get_component(eid, TransformComponent)
        tc === nothing && return
        pos = tc.position[]
        t = time()
        new_y = 1.0 + 0.3 * sin(t * 2.5)
        tc.position[] = Vec3d(pos[1], new_y, pos[3])
    end

    # Grid-based collision: push player out of walls each frame
    maze_collide = function(eid, dt, ctx)
        tc = get_component(eid, TransformComponent)
        tc === nothing && return
        pos = tc.position[]
        x, z = pos[1], pos[3]

        # Check the 4 axis-aligned directions for wall overlap
        half = CELL_SIZE / 2.0
        rows, cols = size(MAZE)

        for dr in -1:1, dc in -1:1
            row, col = world_to_grid(x, z)
            r, c = row + dr, col + dc
            (r < 1 || r > rows || c < 1 || c > cols) && continue
            MAZE[r, c] != 1 && continue

            # Wall center
            wx, wz = grid_to_world(r, c)

            # Nearest point on wall AABB to player
            cx = clamp(x, wx - half, wx + half)
            cz = clamp(z, wz - half, wz + half)
            dx = x - cx
            dz = z - cz
            dist = sqrt(dx * dx + dz * dz)

            if dist < PLAYER_RADIUS && dist > 1e-6
                # Push player out
                nx, nz = dx / dist, dz / dist
                push_dist = PLAYER_RADIUS - dist
                x += nx * push_dist
                z += nz * push_dist
            elseif dist < 1e-6
                # Player center is inside the wall — push to nearest edge
                to_left  = (x - (wx - half))
                to_right = ((wx + half) - x)
                to_back  = (z - (wz - half))
                to_front = ((wz + half) - z)
                min_pen = min(to_left, to_right, to_back, to_front)
                if min_pen == to_left
                    x = wx - half - PLAYER_RADIUS
                elseif min_pen == to_right
                    x = wx + half + PLAYER_RADIUS
                elseif min_pen == to_back
                    z = wz - half - PLAYER_RADIUS
                else
                    z = wz + half + PLAYER_RADIUS
                end
            end
        end

        tc.position[] = Vec3d(x, pos[2], z)
    end

    # Start position (first open cell after top-left corner)
    start_x, start_z = grid_to_world(2, 2)

    # Player with maze collision script
    player_def = create_player(position=Vec3d(start_x, 1.7, start_z))
    push!(player_def.components, ScriptComponent(on_update=maze_collide))

    scene_defs = Any[
        # --- Player ---
        player_def,

        # --- Lighting ---
        entity([
            DirectionalLightComponent(
                direction=Vec3f(0.3, -1.0, -0.4),
                intensity=1.5f0,
                color=RGB{Float32}(0.9, 0.9, 1.0)
            )
        ]),

        # Ambient-like point lights scattered in the maze
        entity([
            PointLightComponent(
                color=RGB{Float32}(1.0, 0.85, 0.7),
                intensity=15.0f0,
                range=25.0f0
            ),
            transform(position=Vec3d(0, WALL_HEIGHT - 0.5, 0))
        ]),

        # --- Goal Trigger + Particles ---
        entity([
            transform(position=Vec3d(goal_pos[1], 1.0, goal_pos[3])),
            ColliderComponent(
                shape=SphereShape(1.2f0),
                is_trigger=true
            ),
            RigidBodyComponent(body_type=BODY_STATIC),
            # Glowing goal sphere
            sphere_mesh(radius=0.3f0),
            MaterialComponent(
                color=RGB{Float32}(0.1, 1.0, 0.4),
                metallic=0.3f0,
                roughness=0.2f0,
                emissive_factor=Vec3f(0.2f0, 1.5f0, 0.5f0)
            ),
            # Particle sparkle effect
            ParticleSystemComponent(
                max_particles=100,
                emission_rate=25.0f0,
                lifetime_min=0.5f0,
                lifetime_max=1.5f0,
                velocity_min=Vec3f(-0.3f0, 0.5f0, -0.3f0),
                velocity_max=Vec3f(0.3f0, 2.0f0, 0.3f0),
                gravity_modifier=0.0f0,
                damping=0.1f0,
                start_size_min=0.02f0,
                start_size_max=0.05f0,
                end_size=0.01f0,
                start_color=RGB{Float32}(0.2, 1.0, 0.4),
                end_color=RGB{Float32}(0.0, 0.5, 0.2),
                start_alpha=0.9f0,
                end_alpha=0.0f0,
                additive=true
            ),
            # Win detection via collision callback
            CollisionCallbackComponent(
                on_collision_enter=win_callback
            ),
            # Bobbing animation for the goal
            ScriptComponent(
                on_update=bob_callback
            ),
            # Goal light
            PointLightComponent(
                color=RGB{Float32}(0.1, 1.0, 0.4),
                intensity=10.0f0,
                range=8.0f0
            ),
        ]),
    ]

    # Add all maze wall entities
    append!(scene_defs, maze_entities)

    return scene_defs
end

# =============================================================================
# Startup
# =============================================================================

println("=" ^ 60)
println("  OpenReality — First-Person 3D Maze Game")
println("=" ^ 60)
println()
println("  Navigate the maze to find the glowing green goal!")
println("  Controls: WASD to move, mouse to look, Shift to sprint")
println()
println("=" ^ 60)
println()

reset_entity_counter!()
reset_component_stores!()

# Build initial scene
maze_entities, goal_pos = build_maze_entities()
playing = PlayingState(0.0, false, EntityID(0))
initial_defs = build_full_scene(goal_pos, playing)

# Set up FSM
fsm = GameStateMachine(:playing, initial_defs)
add_state!(fsm, :playing, playing)
add_state!(fsm, :win, WinState(0.0))

# Scene switch hook — transfers timer to win state
scene_switch_hook = function(old_scene, new_defs)
    win = fsm.states[:win]
    if win isa WinState
        win.final_time = playing.elapsed
    end
    reset_engine_state!()
end

render(fsm,
    on_scene_switch=scene_switch_hook,
    title="OpenReality — Maze Game",
    width=1280,
    height=720,
    post_process=PostProcessConfig(
        tone_mapping=TONEMAP_ACES,
        bloom_enabled=true,
        bloom_threshold=0.8f0,
        bloom_intensity=0.4f0,
        fxaa_enabled=true,
        vignette_enabled=true,
        vignette_intensity=0.3f0,
        vignette_radius=0.9f0
    )
)
