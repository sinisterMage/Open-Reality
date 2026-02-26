# First-Person Dungeon Crawler
# Demonstrates: procedural dungeon generation, FSM game states, enemy AI,
# melee combat, pickups, HUD, particles, lighting, and post-processing.
#
# Run with:
#   julia --project=. examples/dungeon_crawler.jl

using OpenReality

# =============================================================================
# Constants
# =============================================================================

const CELL_SIZE      = 2.0
const WALL_HEIGHT    = 3.5
const PLAYER_RADIUS  = 0.35
const PLAYER_EYE_Y   = 1.7

# Dungeon generation
const GRID_W         = 40
const GRID_H         = 40
const NUM_ROOMS      = 8
const ROOM_MIN       = 4
const ROOM_MAX       = 8

# Gameplay
const PLAYER_MAX_HP        = 100.0
const ENEMY_BASIC_HP       = 30.0
const ENEMY_BOSS_HP        = 150.0
const ATTACK_RANGE         = 2.5
const ATTACK_DAMAGE        = 15.0
const ATTACK_COOLDOWN      = 0.5
const ENEMY_DAMAGE         = 10.0
const ENEMY_DAMAGE_CD      = 1.0
const ENEMY_DETECT_RANGE   = 8.0
const ENEMY_CHASE_SPEED    = 2.5
const ENEMY_PATROL_SPEED   = 1.5
const POTION_HEAL          = 25.0
const KEYS_REQUIRED        = 2

# =============================================================================
# Data Structures
# =============================================================================

struct Room
    x::Int   # left column (grid)
    y::Int   # top row (grid)
    w::Int   # width
    h::Int   # height
end

room_center(r::Room) = (r.y + r.h ÷ 2, r.x + r.w ÷ 2)

mutable struct EnemyData
    hp::Float64
    is_boss::Bool
    patrol_points::Vector{Vec3d}
    patrol_index::Int
    chasing::Bool
    damage_cd::Float64
end

# =============================================================================
# Shared Mutable State (Refs for cross-closure access)
# =============================================================================

@webref player_hp           = Ref(PLAYER_MAX_HP)
@webref player_keys         = Ref(0)
@webref player_alive        = Ref(true)
@webref attack_cd_timer     = Ref(0.0)
@webref damage_cd_timer     = Ref(0.0)
@webref player_attacking    = Ref(false)
@webref boss_defeated       = Ref(false)
@webref boss_door_open      = Ref(false)
@webref start_requested     = Ref(false)
@webref restart_requested   = Ref(false)

@webref prev_mouse_down     = Ref(false)   # manual tracking (input.prev_mouse_buttons is unreliable)

const enemy_entities      = Ref(Dict{EntityID, EnemyData}())
const entities_to_despawn = Ref(EntityID[])
const dungeon_grid        = Ref(zeros(Int, GRID_W, GRID_H))
const dungeon_rooms       = Ref(Room[])
const boss_door_row_col   = Ref((1, 1))

# =============================================================================
# Dungeon Generation
# =============================================================================

function rooms_overlap(a::Room, b::Room; pad::Int=1)
    return !(a.x + a.w + pad <= b.x || b.x + b.w + pad <= a.x ||
             a.y + a.h + pad <= b.y || b.y + b.h + pad <= a.y)
end

function carve_room!(grid::Matrix{Int}, r::Room)
    for row in r.y:(r.y + r.h - 1), col in r.x:(r.x + r.w - 1)
        if 1 <= row <= size(grid, 1) && 1 <= col <= size(grid, 2)
            grid[row, col] = 0
        end
    end
end

function carve_corridor!(grid::Matrix{Int}, r1::Int, c1::Int, r2::Int, c2::Int)
    # Horizontal first, then vertical
    c = c1
    while c != c2
        if 1 <= r1 <= size(grid, 1) && 1 <= c <= size(grid, 2)
            grid[r1, c] = 0
        end
        c += c2 > c1 ? 1 : -1
    end
    r = r1
    while r != r2
        if 1 <= r <= size(grid, 1) && 1 <= c2 <= size(grid, 2)
            grid[r, c2] = 0
        end
        r += r2 > r1 ? 1 : -1
    end
    if 1 <= r2 <= size(grid, 1) && 1 <= c2 <= size(grid, 2)
        grid[r2, c2] = 0
    end
end

function generate_dungeon!()
    grid = ones(Int, GRID_H, GRID_W)
    rooms = Room[]

    for _ in 1:NUM_ROOMS * 10
        length(rooms) >= NUM_ROOMS && break
        w = rand(ROOM_MIN:ROOM_MAX)
        h = rand(ROOM_MIN:ROOM_MAX)
        x = rand(2:(GRID_W - w - 1))
        y = rand(2:(GRID_H - h - 1))
        candidate = Room(x, y, w, h)
        if !any(r -> rooms_overlap(r, candidate), rooms)
            push!(rooms, candidate)
            carve_room!(grid, candidate)
        end
    end

    # Sort rooms by center-x for corridor connectivity
    sort!(rooms, by = r -> room_center(r)[2])

    # Connect consecutive rooms with corridors
    for i in 1:(length(rooms) - 1)
        r1, c1 = room_center(rooms[i])
        r2, c2 = room_center(rooms[i + 1])
        carve_corridor!(grid, r1, c1, r2, c2)
    end

    # Find boss door position: first wall cell in corridor leading to last room
    if length(rooms) >= 2
        boss = rooms[end]
        br, bc = room_center(boss)
        prev = rooms[end - 1]
        pr, pc = room_center(prev)
        # Walk from prev center toward boss center, find first cell adjacent to boss room
        door_r, door_c = pr, pc
        c = pc
        while c != bc
            c += bc > pc ? 1 : -1
            if grid[pr, c] == 0 && c >= boss.x - 1 && c <= boss.x + boss.w
                door_r, door_c = pr, c
                break
            end
        end
        # Place door: set cell to wall (2 = door marker)
        grid[door_r, door_c] = 2
        boss_door_row_col[] = (door_r, door_c)
    end

    dungeon_grid[] = grid
    dungeon_rooms[] = rooms
end

# =============================================================================
# Grid ↔ World Conversion
# =============================================================================

function grid_to_world(row::Int, col::Int)
    x = (col - 1 - (GRID_W - 1) / 2) * CELL_SIZE
    z = (row - 1 - (GRID_H - 1) / 2) * CELL_SIZE
    return (x, z)
end

function world_to_grid(x::Real, z::Real)
    col = round(Int, x / CELL_SIZE + (GRID_W - 1) / 2) + 1
    row = round(Int, z / CELL_SIZE + (GRID_H - 1) / 2) + 1
    return (row, col)
end

function is_wall_at(x::Real, z::Real)
    row, col = world_to_grid(x, z)
    grid = dungeon_grid[]
    rows, cols = size(grid)
    (row < 1 || row > rows || col < 1 || col > cols) && return true
    return grid[row, col] != 0
end

# =============================================================================
# Entity Builders
# =============================================================================

# --- Dungeon Geometry ---

function build_dungeon_entities()
    entities = Any[]
    grid = dungeon_grid[]
    rows, cols = size(grid)

    wall_color   = RGB{Float32}(0.35, 0.30, 0.28)
    floor_color  = RGB{Float32}(0.25, 0.22, 0.20)
    ceil_color   = RGB{Float32}(0.15, 0.15, 0.18)

    for row in 1:rows, col in 1:cols
        cell = grid[row, col]
        (cell == 0) && continue  # floor cell, skip wall
        (cell == 2) && continue  # boss door handled separately

        x, z = grid_to_world(row, col)
        push!(entities, entity([
            cube_mesh(size=Float32(CELL_SIZE)),
            MaterialComponent(color=wall_color, roughness=0.9f0, metallic=0.0f0),
            transform(position=Vec3d(x, WALL_HEIGHT / 2, z),
                     scale=Vec3d(1.0, WALL_HEIGHT / CELL_SIZE, 1.0)),
            ColliderComponent(shape=AABBShape(Vec3f(
                Float32(CELL_SIZE / 2), Float32(WALL_HEIGHT / 2), Float32(CELL_SIZE / 2)))),
            RigidBodyComponent(body_type=BODY_STATIC)
        ]))
    end

    # Floor
    floor_size = Float32(max(rows, cols) * CELL_SIZE)
    push!(entities, entity([
        plane_mesh(width=floor_size, depth=floor_size),
        MaterialComponent(color=floor_color, roughness=0.95f0, metallic=0.0f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(floor_size / 2, 0.01f0, floor_size / 2)),
                         offset=Vec3f(0, -0.01f0, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]))

    # Ceiling
    push!(entities, entity([
        plane_mesh(width=floor_size, depth=floor_size),
        MaterialComponent(color=ceil_color, roughness=0.95f0),
        transform(position=Vec3d(0, WALL_HEIGHT, 0),
                 rotation=Quaterniond(cos(π / 2), sin(π / 2), 0.0, 0.0))
    ]))

    return entities
end

# --- Torches ---

function build_torch(wx::Float64, wz::Float64; color::RGB{Float32}=RGB{Float32}(1.0, 0.7, 0.3))
    entity([
        transform(position=Vec3d(wx, WALL_HEIGHT * 0.65, wz)),
        cube_mesh(size=0.15f0),
        MaterialComponent(color=RGB{Float32}(0.4, 0.3, 0.15), roughness=0.8f0),
        PointLightComponent(color=color, intensity=12.0f0, range=10.0f0),
        ParticleSystemComponent(
            max_particles=40,
            emission_rate=15.0f0,
            lifetime_min=0.3f0,
            lifetime_max=0.8f0,
            velocity_min=Vec3f(-0.1f0, 0.5f0, -0.1f0),
            velocity_max=Vec3f(0.1f0, 1.5f0, 0.1f0),
            gravity_modifier=-0.2f0,
            start_size_min=0.04f0,
            start_size_max=0.08f0,
            end_size=0.01f0,
            start_color=RGB{Float32}(color.r, color.g * 0.8f0, 0.1f0),
            end_color=RGB{Float32}(color.r, 0.1f0, 0.0f0),
            start_alpha=0.9f0,
            end_alpha=0.0f0,
            additive=true
        )
    ])
end

# --- Enemies ---

const ENEMY_ATTACK_RANGE = 1.5  # XZ distance at which enemies deal damage

function make_enemy_ai(data::EnemyData)
    @webscript function(eid, dt, ctx)
        player_alive[] || return
        tc = get_component(eid, TransformComponent)
        tc === nothing && return
        pos = tc.position[]

        # Find player
        pids = entities_with_component(PlayerComponent)
        isempty(pids) && return
        ptc = get_component(first(pids), TransformComponent)
        ptc === nothing && return
        ppos = ptc.position[]

        dx = ppos[1] - pos[1]
        dz = ppos[3] - pos[3]
        dist = sqrt(dx * dx + dz * dz)

        data.damage_cd = max(0.0, data.damage_cd - dt)

        if dist < ENEMY_DETECT_RANGE
            # Chase player
            data.chasing = true
            if dist > 0.8
                speed = ENEMY_CHASE_SPEED * dt
                nx, nz = dx / dist, dz / dist
                new_x = pos[1] + nx * speed
                new_z = pos[3] + nz * speed
                if !is_wall_at(new_x, new_z)
                    tc.position[] = Vec3d(new_x, pos[2], new_z)
                end
            end

            # Distance-based damage (replaces collision callback)
            if dist < ENEMY_ATTACK_RANGE && data.damage_cd <= 0.0 && damage_cd_timer[] <= 0.0
                player_hp[] = max(0.0, player_hp[] - ENEMY_DAMAGE)
                data.damage_cd = ENEMY_DAMAGE_CD
                damage_cd_timer[] = ENEMY_DAMAGE_CD
            end
        else
            # Patrol
            data.chasing = false
            if !isempty(data.patrol_points)
                target = data.patrol_points[data.patrol_index]
                tx = target[1] - pos[1]
                tz = target[3] - pos[3]
                tdist = sqrt(tx * tx + tz * tz)
                if tdist < 0.5
                    data.patrol_index = mod1(data.patrol_index + 1, length(data.patrol_points))
                elseif tdist > 0.01
                    speed = ENEMY_PATROL_SPEED * dt
                    nx, nz = tx / tdist, tz / tdist
                    new_x = pos[1] + nx * speed
                    new_z = pos[3] + nz * speed
                    if !is_wall_at(new_x, new_z)
                        tc.position[] = Vec3d(new_x, pos[2], new_z)
                    end
                end
            end
        end
    end
end

function build_enemy(pos::Vec3d, data::EnemyData)
    radius = data.is_boss ? 0.6f0 : 0.35f0
    color  = data.is_boss ? RGB{Float32}(0.8, 0.1, 0.1) : RGB{Float32}(0.9, 0.2, 0.15)
    emissive = data.is_boss ? Vec3f(0.5f0, 0.0f0, 0.0f0) : Vec3f(0.2f0, 0.0f0, 0.0f0)

    ai_fn = make_enemy_ai(data)
    start_fn = @webscript function(eid, ctx)
        enemy_entities[][eid] = data
    end
    destroy_fn = @webscript function(eid, ctx)
        delete!(enemy_entities[], eid)
    end

    entity([
        sphere_mesh(radius=radius),
        MaterialComponent(color=color, metallic=0.3f0, roughness=0.5f0,
                         emissive_factor=emissive),
        transform(position=pos),
        ColliderComponent(shape=SphereShape(radius)),
        RigidBodyComponent(body_type=BODY_KINEMATIC),
        ScriptComponent(on_start=start_fn, on_update=ai_fn, on_destroy=destroy_fn),
        PointLightComponent(color=color, intensity=3.0f0, range=4.0f0)
    ])
end

# --- Health Potions ---

function build_health_potion(pos::Vec3d)
    bob_time = Ref(0.0)
    base_y = pos[2]
    bob_fn = @webscript function(eid, dt, ctx)
        bob_time[] += dt
        tc = get_component(eid, TransformComponent)
        tc === nothing && return
        p = tc.position[]
        new_y = base_y + 0.2 * sin(bob_time[] * 3.0)
        tc.position[] = Vec3d(p[1], new_y, p[3])
    end
    collect_fn = function(trigger_eid, other_eid)
        pc = get_component(other_eid, PlayerComponent)
        pc === nothing && return
        player_hp[] = min(player_hp[] + POTION_HEAL, PLAYER_MAX_HP)
        push!(entities_to_despawn[], trigger_eid)
    end

    entity([
        sphere_mesh(radius=0.25f0),
        MaterialComponent(color=RGB{Float32}(0.1, 0.9, 0.3), metallic=0.4f0,
                         roughness=0.2f0, emissive_factor=Vec3f(0.1f0, 0.5f0, 0.1f0)),
        transform(position=pos),
        ColliderComponent(shape=SphereShape(0.5f0), is_trigger=true),
        RigidBodyComponent(body_type=BODY_KINEMATIC),
        ScriptComponent(on_update=bob_fn),
        TriggerComponent(on_enter=collect_fn),
        ParticleSystemComponent(
            max_particles=30, emission_rate=8.0f0,
            lifetime_min=0.5f0, lifetime_max=1.0f0,
            velocity_min=Vec3f(-0.2f0, 0.3f0, -0.2f0),
            velocity_max=Vec3f(0.2f0, 0.8f0, 0.2f0),
            gravity_modifier=0.0f0,
            start_size_min=0.02f0, start_size_max=0.04f0, end_size=0.01f0,
            start_color=RGB{Float32}(0.2, 1.0, 0.4),
            end_color=RGB{Float32}(0.0, 0.5, 0.2),
            start_alpha=0.8f0, end_alpha=0.0f0,
            additive=true
        )
    ])
end

# --- Keys ---

function build_key(pos::Vec3d)
    bob_time = Ref(0.0)
    base_y = pos[2]
    bob_spin_fn = @webscript function(eid, dt, ctx)
        bob_time[] += dt
        tc = get_component(eid, TransformComponent)
        tc === nothing && return
        p = tc.position[]
        new_y = base_y + 0.15 * sin(bob_time[] * 2.5)
        tc.position[] = Vec3d(p[1], new_y, p[3])
        angle = 1.5 * dt
        rot_delta = Quaterniond(cos(angle / 2), 0.0, sin(angle / 2), 0.0)
        tc.rotation[] = tc.rotation[] * rot_delta
    end
    collect_fn = function(trigger_eid, other_eid)
        pc = get_component(other_eid, PlayerComponent)
        pc === nothing && return
        player_keys[] += 1
        push!(entities_to_despawn[], trigger_eid)
    end

    entity([
        cube_mesh(size=0.3f0),
        MaterialComponent(color=RGB{Float32}(0.95, 0.8, 0.2), metallic=0.9f0,
                         roughness=0.1f0, emissive_factor=Vec3f(0.5f0, 0.4f0, 0.1f0)),
        transform(position=pos),
        ColliderComponent(shape=SphereShape(0.5f0), is_trigger=true),
        RigidBodyComponent(body_type=BODY_KINEMATIC),
        ScriptComponent(on_update=bob_spin_fn),
        TriggerComponent(on_enter=collect_fn)
    ])
end

# --- Boss Door ---

function build_boss_door(pos::Vec3d)
    door_fn = @webscript function(eid, dt, ctx)
        if player_keys[] >= KEYS_REQUIRED && !boss_door_open[]
            boss_door_open[] = true
            push!(entities_to_despawn[], eid)
            # Clear grid cell so wall collision allows passage
            dr, dc = boss_door_row_col[]
            dungeon_grid[][dr, dc] = 0
        end
    end

    entity([
        cube_mesh(size=Float32(CELL_SIZE)),
        MaterialComponent(color=RGB{Float32}(0.6, 0.5, 0.15), metallic=0.7f0,
                         roughness=0.3f0, emissive_factor=Vec3f(0.3f0, 0.25f0, 0.05f0)),
        transform(position=Vec3d(pos[1], WALL_HEIGHT / 2, pos[3]),
                 scale=Vec3d(1.0, WALL_HEIGHT / CELL_SIZE, 1.0)),
        ColliderComponent(shape=AABBShape(Vec3f(
            Float32(CELL_SIZE / 2), Float32(WALL_HEIGHT / 2), Float32(CELL_SIZE / 2)))),
        RigidBodyComponent(body_type=BODY_STATIC),
        ScriptComponent(on_update=door_fn)
    ])
end

# =============================================================================
# Player Scripts (combined: wall collision + attack)
# =============================================================================

function make_player_script()
    @webscript function(eid, dt, ctx)
        player_alive[] || return
        tc = get_component(eid, TransformComponent)
        tc === nothing && return
        pos = tc.position[]

        # --- Wall collision (grid-based AABB push-out) ---
        x, z = pos[1], pos[3]
        grid = dungeon_grid[]
        rows, cols = size(grid)
        half = CELL_SIZE / 2.0

        for dr in -1:1, dc in -1:1
            row, col = world_to_grid(x, z)
            r, c = row + dr, col + dc
            (r < 1 || r > rows || c < 1 || c > cols) && continue
            grid[r, c] == 0 && continue

            wx, wz = grid_to_world(r, c)
            cx = clamp(x, wx - half, wx + half)
            cz = clamp(z, wz - half, wz + half)
            ddx = x - cx
            ddz = z - cz
            dist = sqrt(ddx * ddx + ddz * ddz)

            if dist < PLAYER_RADIUS && dist > 1e-6
                nx, nz = ddx / dist, ddz / dist
                push_dist = PLAYER_RADIUS - dist
                x += nx * push_dist
                z += nz * push_dist
            elseif dist < 1e-6
                to_left  = (x - (wx - half))
                to_right = ((wx + half) - x)
                to_back  = (z - (wz - half))
                to_front = ((wz + half) - z)
                min_pen = min(to_left, to_right, to_back, to_front)
                if min_pen == to_left;      x = wx - half - PLAYER_RADIUS
                elseif min_pen == to_right;  x = wx + half + PLAYER_RADIUS
                elseif min_pen == to_back;   z = wz - half - PLAYER_RADIUS
                else;                        z = wz + half + PLAYER_RADIUS
                end
            end
        end
        tc.position[] = Vec3d(x, pos[2], z)

        # --- Cooldowns ---
        attack_cd_timer[] = max(0.0, attack_cd_timer[] - dt)
        damage_cd_timer[] = max(0.0, damage_cd_timer[] - dt)

        # --- Melee attack (left click) ---
        # NOTE: input.prev_mouse_buttons is unreliable (begin_frame! runs after poll_events
        # in the render loop, so prev always equals current). Track manually instead.
        input = ctx.input
        mouse_down = 0 in input.mouse_buttons
        mouse_clicked = mouse_down && !prev_mouse_down[]
        prev_mouse_down[] = mouse_down

        if mouse_clicked && attack_cd_timer[] <= 0.0
            attack_cd_timer[] = ATTACK_COOLDOWN
            player_attacking[] = true

            player_pos = tc.position[]
            killed = EntityID[]
            for (enemy_eid, edata) in enemy_entities[]
                etc = get_component(enemy_eid, TransformComponent)
                etc === nothing && continue
                epos = etc.position[]
                edx = epos[1] - player_pos[1]
                edz = epos[3] - player_pos[3]
                edist = sqrt(edx * edx + edz * edz)

                if edist < ATTACK_RANGE
                    edata.hp -= ATTACK_DAMAGE
                    if edata.hp <= 0.0
                        push!(killed, enemy_eid)
                        if edata.is_boss
                            boss_defeated[] = true
                        end
                        # Death particles
                        spawn!(ctx, entity([
                            transform(position=epos),
                            ParticleSystemComponent(
                                max_particles=50, emission_rate=0.0f0,
                                burst_count=50,
                                lifetime_min=0.3f0, lifetime_max=0.8f0,
                                velocity_min=Vec3f(-2f0, 1f0, -2f0),
                                velocity_max=Vec3f(2f0, 4f0, 2f0),
                                gravity_modifier=1.0f0,
                                start_size_min=0.05f0, start_size_max=0.1f0,
                                end_size=0.0f0,
                                start_color=RGB{Float32}(1.0, 0.2, 0.1),
                                end_color=RGB{Float32}(0.5, 0.0, 0.0),
                                start_alpha=1.0f0, end_alpha=0.0f0,
                                additive=true
                            )
                        ]))
                    end
                end
            end
            for k in killed
                push!(entities_to_despawn[], k)
                delete!(enemy_entities[], k)
            end
        else
            player_attacking[] = false
        end
    end
end

# =============================================================================
# Scene Builder
# =============================================================================

function build_playing_scene()
    generate_dungeon!()
    rooms = dungeon_rooms[]
    length(rooms) < 2 && error("Dungeon generation failed: not enough rooms")

    dungeon_ents = build_dungeon_entities()

    # Player
    sr, sc = room_center(rooms[1])
    sx, sz = grid_to_world(sr, sc)
    player_def = create_player(position=Vec3d(sx, PLAYER_EYE_Y, sz))
    push!(player_def.components, ScriptComponent(on_update=make_player_script()))

    scene_defs = Any[player_def]

    # Dim ambient light
    push!(scene_defs, entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.4),
            intensity=0.4f0,
            color=RGB{Float32}(0.7, 0.7, 0.85)
        )
    ]))

    # Torches — 2 per room
    for (i, room) in enumerate(rooms)
        is_boss_room = (i == length(rooms))
        torch_color = is_boss_room ? RGB{Float32}(1.0, 0.2, 0.1) : RGB{Float32}(1.0, 0.7, 0.3)
        corners = [
            grid_to_world(room.y + 1, room.x + 1),
            grid_to_world(room.y + room.h - 2, room.x + room.w - 2)
        ]
        for (tx, tz) in corners
            push!(scene_defs, build_torch(tx, tz, color=torch_color))
        end
    end

    # Enemies — 1 per middle room
    for i in 2:(length(rooms) - 1)
        room = rooms[i]
        cr, cc = room_center(room)
        cx, cz = grid_to_world(cr, cc)
        pt1 = Vec3d(cx - 2, 0.5, cz)
        pt2 = Vec3d(cx + 2, 0.5, cz)
        edata = EnemyData(ENEMY_BASIC_HP, false, [pt1, pt2], 1, false, 0.0)
        push!(scene_defs, build_enemy(Vec3d(cx, 0.5, cz), edata))
    end

    # Boss in last room
    boss_room = rooms[end]
    br, bc = room_center(boss_room)
    bx, bz = grid_to_world(br, bc)
    boss_data = EnemyData(ENEMY_BOSS_HP, true, Vec3d[], 1, false, 0.0)
    push!(scene_defs, build_enemy(Vec3d(bx, 0.8, bz), boss_data))

    # Boss room ambient red light
    push!(scene_defs, entity([
        PointLightComponent(color=RGB{Float32}(1.0, 0.1, 0.05), intensity=20.0f0, range=15.0f0),
        transform(position=Vec3d(bx, WALL_HEIGHT - 0.5, bz))
    ]))

    # Keys — in rooms 2 and 3
    for i in 2:min(1 + KEYS_REQUIRED, length(rooms) - 1)
        kr, kc = room_center(rooms[i])
        kx, kz = grid_to_world(kr, kc)
        push!(scene_defs, build_key(Vec3d(kx + 1.0, 0.8, kz)))
    end

    # Health potions — in rooms 3 to 6
    for i in 3:min(6, length(rooms) - 1)
        pr, pc_val = room_center(rooms[i])
        px, pz = grid_to_world(pr, pc_val)
        push!(scene_defs, build_health_potion(Vec3d(px - 1.0, 0.6, pz + 1.0)))
    end

    # Boss door
    dr, dc = boss_door_row_col[]
    dx, dz = grid_to_world(dr, dc)
    push!(scene_defs, build_boss_door(Vec3d(dx, 0.0, dz)))

    # Dungeon geometry
    append!(scene_defs, dungeon_ents)

    return scene_defs
end

# =============================================================================
# Game States
# =============================================================================

# --- Menu ---

mutable struct MenuState <: GameState end

function OpenReality.on_update!(state::MenuState, sc::Scene, dt::Float64, ctx::GameContext)
    if start_requested[]
        start_requested[] = false
        # Reset all game state
        player_hp[] = PLAYER_MAX_HP
        player_keys[] = 0
        player_alive[] = true
        boss_defeated[] = false
        boss_door_open[] = false
        attack_cd_timer[] = 0.0
        damage_cd_timer[] = 0.0
        player_attacking[] = false
        prev_mouse_down[] = false
        empty!(enemy_entities[])
        empty!(entities_to_despawn[])
        return StateTransition(:playing, build_playing_scene())
    end
    return nothing
end

function OpenReality.get_ui_callback(state::MenuState)
    function(ctx::UIContext)
        ui_rect(ctx, x=0, y=0, width=ctx.width, height=ctx.height,
                color=RGB{Float32}(0.05, 0.03, 0.08), alpha=0.95f0)

        cx = ctx.width / 2
        cy = ctx.height / 2

        ui_text(ctx, "DUNGEON CRAWLER",
                x=cx - 200, y=cy - 120, size=52,
                color=RGB{Float32}(0.9, 0.7, 0.2))
        ui_text(ctx, "A Dark Descent",
                x=cx - 100, y=cy - 55, size=24,
                color=RGB{Float32}(0.6, 0.6, 0.6))

        if ui_button(ctx, "Enter the Dungeon",
                     x=cx - 120, y=cy + 20, width=240, height=50,
                     color=RGB{Float32}(0.6, 0.15, 0.1),
                     hover_color=RGB{Float32}(0.8, 0.2, 0.15),
                     text_size=22)
            start_requested[] = true
        end

        ui_text(ctx, "WASD: Move | Mouse: Look | Left-Click: Attack | Shift: Sprint",
                x=cx - 270, y=cy + 100, size=16,
                color=RGB{Float32}(0.4, 0.4, 0.4))
        ui_text(ctx, "Find $(KEYS_REQUIRED) keys to unlock the boss room. Defeat the boss to win!",
                x=cx - 260, y=cy + 125, size=16,
                color=RGB{Float32}(0.4, 0.4, 0.4))
    end
end

# --- Playing ---

mutable struct PlayingState <: GameState
    elapsed::Float64
end

function OpenReality.on_enter!(state::PlayingState, sc::Scene)
    state.elapsed = 0.0
end

function OpenReality.on_update!(state::PlayingState, sc::Scene, dt::Float64, ctx::GameContext)
    state.elapsed += dt

    # Process deferred despawns
    for eid in entities_to_despawn[]
        if has_entity(sc, eid)
            despawn!(ctx, eid)
        end
    end
    empty!(entities_to_despawn[])

    # Check death
    if player_hp[] <= 0.0 && player_alive[]
        player_alive[] = false
        return StateTransition(:game_over)
    end

    # Check victory
    if boss_defeated[]
        return StateTransition(:victory)
    end

    return nothing
end

function OpenReality.get_ui_callback(state::PlayingState)
    function(ctx::UIContext)
        # HP bar background
        ui_rect(ctx, x=10, y=10, width=230, height=38,
                color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.8f0)
        ui_text(ctx, "HP", x=15, y=15, size=18,
                color=RGB{Float32}(0.9, 0.2, 0.2))
        hp_frac = Float32(clamp(player_hp[] / PLAYER_MAX_HP, 0.0, 1.0))
        hp_color = hp_frac > 0.5 ? RGB{Float32}(0.2, 0.8, 0.2) :
                   hp_frac > 0.25 ? RGB{Float32}(0.8, 0.6, 0.1) :
                   RGB{Float32}(0.9, 0.1, 0.1)
        ui_progress_bar(ctx, hp_frac, x=48, y=17, width=180, height=20,
                       color=hp_color, bg_color=RGB{Float32}(0.15, 0.05, 0.05))

        # Key count
        key_color = player_keys[] >= KEYS_REQUIRED ?
            RGB{Float32}(0.95, 0.85, 0.2) : RGB{Float32}(0.6, 0.5, 0.2)
        ui_text(ctx, "Keys: $(player_keys[]) / $(KEYS_REQUIRED)",
                x=15, y=52, size=18, color=key_color)

        # Boss door hint
        if player_keys[] >= KEYS_REQUIRED && !boss_door_open[]
            ui_text(ctx, "The boss door is unlocking...",
                    x=ctx.width / 2 - 140, y=80, size=20,
                    color=RGB{Float32}(0.95, 0.8, 0.2))
        end

        # Crosshair
        ui_rect(ctx, x=ctx.width / 2 - 1, y=ctx.height / 2 - 12,
                width=2, height=24, color=RGB{Float32}(1, 1, 1), alpha=0.5f0)
        ui_rect(ctx, x=ctx.width / 2 - 12, y=ctx.height / 2 - 1,
                width=24, height=2, color=RGB{Float32}(1, 1, 1), alpha=0.5f0)

        # Attack indicator
        if player_attacking[]
            ui_text(ctx, "ATTACK!", x=ctx.width / 2 - 40, y=ctx.height / 2 + 30,
                    size=20, color=RGB{Float32}(1.0, 0.3, 0.1))
        end

        # Timer (top-right)
        t_str = string(round(state.elapsed, digits=1), "s")
        ui_text(ctx, t_str, x=ctx.width - 100, y=15, size=18,
                color=RGB{Float32}(0.6, 0.6, 0.6))

        # Enemy count
        n_enemies = length(enemy_entities[])
        ui_text(ctx, "Enemies: $n_enemies", x=15, y=75, size=16,
                color=RGB{Float32}(0.7, 0.3, 0.3))

        # Controls hint
        ui_text(ctx, "WASD: Move | Mouse: Look | LMB: Attack | Shift: Sprint",
                x=ctx.width / 2 - 250, y=ctx.height - 20, size=13,
                color=RGB{Float32}(0.4, 0.4, 0.4))
    end
end

# --- Game Over ---

mutable struct GameOverState <: GameState end

function OpenReality.on_update!(state::GameOverState, sc::Scene, dt::Float64, ctx::GameContext)
    if restart_requested[]
        restart_requested[] = false
        return StateTransition(:menu, build_menu_scene())
    end
    return nothing
end

function OpenReality.get_ui_callback(state::GameOverState)
    function(ctx::UIContext)
        ui_rect(ctx, x=0, y=0, width=ctx.width, height=ctx.height,
                color=RGB{Float32}(0.3, 0.0, 0.0), alpha=0.75f0)
        cx = ctx.width / 2
        cy = ctx.height / 2
        ui_text(ctx, "YOU DIED", x=cx - 110, y=cy - 40, size=56,
                color=RGB{Float32}(0.9, 0.1, 0.1))
        if ui_button(ctx, "Try Again", x=cx - 80, y=cy + 30, width=160, height=45,
                     color=RGB{Float32}(0.5, 0.1, 0.1),
                     hover_color=RGB{Float32}(0.7, 0.15, 0.15), text_size=20)
            restart_requested[] = true
        end
    end
end

# --- Victory ---

mutable struct VictoryState <: GameState end

function OpenReality.on_update!(state::VictoryState, sc::Scene, dt::Float64, ctx::GameContext)
    if restart_requested[]
        restart_requested[] = false
        return StateTransition(:menu, build_menu_scene())
    end
    return nothing
end

function OpenReality.get_ui_callback(state::VictoryState)
    function(ctx::UIContext)
        ui_rect(ctx, x=0, y=0, width=ctx.width, height=ctx.height,
                color=RGB{Float32}(0.05, 0.05, 0.02), alpha=0.8f0)
        cx = ctx.width / 2
        cy = ctx.height / 2
        ui_text(ctx, "VICTORY!", x=cx - 120, y=cy - 50, size=56,
                color=RGB{Float32}(0.95, 0.85, 0.2))
        ui_text(ctx, "The dungeon is conquered.",
                x=cx - 130, y=cy + 10, size=22,
                color=RGB{Float32}(0.7, 0.65, 0.4))
        if ui_button(ctx, "Play Again", x=cx - 80, y=cy + 55, width=160, height=45,
                     color=RGB{Float32}(0.15, 0.4, 0.1),
                     hover_color=RGB{Float32}(0.2, 0.6, 0.15), text_size=20)
            restart_requested[] = true
        end
    end
end

# =============================================================================
# Menu Scene
# =============================================================================

function build_menu_scene()
    [
        create_player(position=Vec3d(0, PLAYER_EYE_Y, 0)),
        entity([
            DirectionalLightComponent(direction=Vec3f(0, -1, 0), intensity=0.2f0,
                                     color=RGB{Float32}(0.5, 0.3, 0.2))
        ]),
        entity([
            plane_mesh(width=10.0f0, depth=10.0f0),
            MaterialComponent(color=RGB{Float32}(0.15, 0.12, 0.1), roughness=0.95f0),
            transform(),
            ColliderComponent(shape=AABBShape(Vec3f(5f0, 0.01f0, 5f0)),
                             offset=Vec3f(0, -0.01f0, 0)),
            RigidBodyComponent(body_type=BODY_STATIC)
        ]),
        build_torch(0.0, -3.0)
    ]
end

# =============================================================================
# Startup
# =============================================================================

println("=" ^ 60)
println("  OpenReality — Dungeon Crawler")
println("=" ^ 60)
println()
println("  Explore the dungeon, find keys, defeat the boss!")
println("  Controls: WASD move, Mouse look, Left-Click attack, Shift sprint")
println("  Collect $(KEYS_REQUIRED) keys to unlock the boss room.")
println()
println("=" ^ 60)

reset_entity_counter!()
reset_component_stores!()

menu_defs = build_menu_scene()

fsm = GameStateMachine(:menu, menu_defs)
add_state!(fsm, :menu, MenuState())
add_state!(fsm, :playing, PlayingState(0.0))
add_state!(fsm, :game_over, GameOverState())
add_state!(fsm, :victory, VictoryState())

scene_switch_hook = function(old_scene, new_defs)
    reset_engine_state!()
    clear_audio_sources!()
end

render(fsm,
    on_scene_switch=scene_switch_hook,
    title="OpenReality — Dungeon Crawler",
    width=1280,
    height=720,
    post_process=PostProcessConfig(
        tone_mapping=TONEMAP_ACES,
        bloom_enabled=true,
        bloom_threshold=0.6f0,
        bloom_intensity=0.5f0,
        fxaa_enabled=true,
        vignette_enabled=true,
        vignette_intensity=0.5f0,
        vignette_radius=0.75f0
    )
)
