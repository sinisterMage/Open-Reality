# Multithreading Demo
# Showcases the engine's parallel-first execution model. Every multithreaded
# job in OpenReality is submitted to a single engine-wide EEVDF
# (Earliest Eligible Virtual Deadline First) task scheduler with a
# persistent worker-thread pool:
#   - Parallel physics narrowphase  (weight = W_PHYSICS, foreground)
#   - Parallel frame preparation   (weight = W_CULLING, foreground)
#   - Async asset loading          (weight = W_ASYNC_IO, background)
#   - Procedural chunk streaming   (weight = W_CHUNK_GEN, background)
#
# Run with multiple threads for actual parallelism:
#   julia -t auto --project=. examples/threading_demo.jl
#
# With `julia -t 1` the scheduler still works (single worker) and every
# code path produces identical results, just sequentially.

using OpenReality

reset_entity_counter!()
reset_component_stores!()
reset_physics_world!()

# =============================================================================
# Engine is parallel-first — no toggle, the scheduler boots with the render
# loop. We log the worker count for visibility.
# =============================================================================
@info "Julia threads available" nthreads=Threads.nthreads()

# =============================================================================
# Helpers: mass-spawn entities to stress-test parallel paths
# =============================================================================

function dynamic_box(pos; size=Vec3f(0.4, 0.4, 0.4), color=RGB{Float32}(0.8, 0.3, 0.1),
                     mass=1.0, restitution=0.3f0)
    entity([
        cube_mesh(),
        MaterialComponent(color=color, metallic=0.3f0, roughness=0.5f0),
        transform(position=pos),
        ColliderComponent(shape=AABBShape(size)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=mass, restitution=restitution)
    ])
end

function dynamic_sphere(pos; radius=0.3f0, color=RGB{Float32}(0.2, 0.6, 0.9),
                         mass=1.0, restitution=0.5f0)
    entity([
        sphere_mesh(radius=radius),
        MaterialComponent(color=color, metallic=0.5f0, roughness=0.3f0),
        transform(position=pos),
        ColliderComponent(shape=SphereShape(radius)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=mass, restitution=restitution)
    ])
end

function static_pillar(pos; height=4.0, color=RGB{Float32}(0.5, 0.5, 0.5))
    entity([
        cube_mesh(),
        MaterialComponent(color=color, metallic=0.1f0, roughness=0.8f0),
        transform(position=pos, scale=Vec3d(0.3, height, 0.3)),
        ColliderComponent(shape=AABBShape(Vec3f(0.15, Float32(height/2), 0.15))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
end

# =============================================================================
# Build scene — many physics entities to exercise parallel narrowphase
# =============================================================================

# Color palette for the rain of objects
colors = [
    RGB{Float32}(0.95, 0.25, 0.20),  # red
    RGB{Float32}(0.95, 0.60, 0.15),  # orange
    RGB{Float32}(0.95, 0.90, 0.20),  # yellow
    RGB{Float32}(0.30, 0.85, 0.25),  # green
    RGB{Float32}(0.20, 0.55, 0.95),  # blue
    RGB{Float32}(0.60, 0.25, 0.90),  # purple
    RGB{Float32}(0.90, 0.30, 0.70),  # pink
]

entities = Any[]

# Player + lights
push!(entities, create_player(position=Vec3d(0, 3, 20)))
push!(entities, entity([
    DirectionalLightComponent(direction=Vec3f(0.3, -1.0, -0.4), intensity=2.5f0)
]))
push!(entities, entity([
    PointLightComponent(color=RGB{Float32}(1.0, 0.95, 0.85), intensity=60.0f0, range=40.0f0),
    transform(position=Vec3d(0, 12, 0))
]))

# Ground
push!(entities, entity([
    plane_mesh(width=50.0f0, depth=50.0f0),
    MaterialComponent(color=RGB{Float32}(0.35, 0.35, 0.38), metallic=0.0f0, roughness=0.95f0),
    transform(),
    ColliderComponent(shape=AABBShape(Vec3f(25.0, 0.01, 25.0)), offset=Vec3f(0, -0.01, 0)),
    RigidBodyComponent(body_type=BODY_STATIC)
]))

# --- DEMO 1: Rain of 200 dynamic objects ---
# These create many broadphase candidate pairs → the parallel narrowphase
# distributes collision tests across worker threads.
grid_size = 10
for ix in 1:grid_size
    for iz in 1:grid_size
        x = (ix - grid_size/2 - 0.5) * 1.2
        z = (iz - grid_size/2 - 0.5) * 1.2
        y = 3.0 + rand() * 15.0  # staggered drop heights
        c = colors[mod1(ix + iz, length(colors))]

        if rand() < 0.5
            push!(entities, dynamic_box(Vec3d(x, y, z), color=c, mass=0.5 + rand()))
        else
            push!(entities, dynamic_sphere(Vec3d(x, y, z), color=c, mass=0.5 + rand()))
        end
    end
end

# --- DEMO 2: Static pillars (many mesh entities for frame preparation) ---
# These add to the frustum culling workload that runs in parallel.
for angle in range(0, 2π, length=24)
    r = 14.0
    push!(entities, static_pillar(
        Vec3d(r * cos(angle), 2.0, r * sin(angle)),
        height=2.0 + 2.0 * abs(sin(angle * 3)),
        color=RGB{Float32}(0.6, 0.55, 0.5)
    ))
end

# --- DEMO 3: Scattered objects outside view for culling ---
# Many of these will be frustum-culled; the parallel path handles this efficiently.
for i in 1:50
    x = (rand() - 0.5) * 80.0
    z = (rand() - 0.5) * 80.0
    push!(entities, entity([
        sphere_mesh(radius=0.5f0),
        MaterialComponent(color=colors[mod1(i, length(colors))], metallic=0.7f0, roughness=0.2f0),
        transform(position=Vec3d(x, 0.5, z)),
    ]))
end

s = scene(entities)

# =============================================================================
# Summary
# =============================================================================
@info "Threading Demo Scene" entities=entity_count(s) workers=Threads.nthreads() features=[
    "EEVDF task scheduler ($(Threads.nthreads()) workers, parallel-first)",
    "Parallel narrowphase via parallel_for(W_PHYSICS)",
    "Parallel frame prep via parallel_for_chunks(W_CULLING)",
    "Async asset loading via submit_task!(W_ASYNC_IO)",
    "NaN guards (velocity clamping + impulse validation)",
    "200 dynamic physics objects stress-testing collision pairs",
    "50 scattered objects stress-testing frustum culling",
]

# =============================================================================
# Render
# =============================================================================
render(s, post_process=PostProcessConfig(
    tone_mapping=TONEMAP_ACES,
    bloom_enabled=true,
    bloom_intensity=0.3f0,
    fxaa_enabled=true
))
