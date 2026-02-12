# Particle simulation system

const GRAVITY = Vec3f(0.0f0, -9.81f0, 0.0f0)

# ---- Particle struct ----

mutable struct Particle
    position::Vec3f
    velocity::Vec3f
    lifetime::Float32       # remaining
    max_lifetime::Float32   # initial (for lerp)
    size::Float32
    alive::Bool
end

Particle() = Particle(Vec3f(0,0,0), Vec3f(0,0,0), 0.0f0, 1.0f0, 0.1f0, false)

# ---- ParticlePool ----

mutable struct ParticlePool
    particles::Vector{Particle}
    alive_count::Int
    # Per-particle vertex data (rebuilt each frame): 6 verts * 8 floats (pos3 + uv2 + rgba3)
    vertex_data::Vector{Float32}
    vertex_count::Int
end

function ParticlePool(max_particles::Int)
    particles = [Particle() for _ in 1:max_particles]
    # 6 vertices per particle, 9 floats each (pos3 + uv2 + color4)
    vertex_data = zeros(Float32, max_particles * 6 * 9)
    ParticlePool(particles, 0, vertex_data, 0)
end

# Global pool storage
const PARTICLE_POOLS = Dict{EntityID, ParticlePool}()

"""
    reset_particle_pools!()

Clear all particle pools (for testing/cleanup).
"""
function reset_particle_pools!()
    empty!(PARTICLE_POOLS)
end

# ---- Helpers ----

@inline function _rand_range(lo::Float32, hi::Float32)::Float32
    lo + rand(Float32) * (hi - lo)
end

@inline function _rand_range_vec3(lo::Vec3f, hi::Vec3f)::Vec3f
    Vec3f(_rand_range(lo[1], hi[1]),
          _rand_range(lo[2], hi[2]),
          _rand_range(lo[3], hi[3]))
end

@inline function _lerp(a::Float32, b::Float32, t::Float32)::Float32
    a + (b - a) * t
end

# ---- Core simulation ----

"""
    _emit_particle!(pool, comp, origin)

Find a dead particle and initialize it.
"""
function _emit_particle!(pool::ParticlePool, comp::ParticleSystemComponent, origin::Vec3f)
    for p in pool.particles
        if !p.alive
            p.position = origin
            p.velocity = _rand_range_vec3(comp.velocity_min, comp.velocity_max)
            p.max_lifetime = _rand_range(comp.lifetime_min, comp.lifetime_max)
            p.lifetime = p.max_lifetime
            p.size = _rand_range(comp.start_size_min, comp.start_size_max)
            p.alive = true
            pool.alive_count += 1
            return true
        end
    end
    return false  # pool full
end

"""
    _simulate_particles!(pool, comp, dt)

Integrate physics for all alive particles.
"""
function _simulate_particles!(pool::ParticlePool, comp::ParticleSystemComponent, dt::Float32)
    gravity_accel = GRAVITY * comp.gravity_modifier
    alive = 0
    for p in pool.particles
        !p.alive && continue
        p.lifetime -= dt
        if p.lifetime <= 0.0f0
            p.alive = false
            continue
        end
        # Physics integration
        p.velocity = p.velocity + gravity_accel * dt
        if comp.damping > 0.0f0
            p.velocity = p.velocity * (1.0f0 - comp.damping * dt)
        end
        p.position = p.position + p.velocity * dt
        alive += 1
    end
    pool.alive_count = alive
end

"""
    _sort_particles_back_to_front!(pool, cam_pos)

Sort alive particles back-to-front relative to camera for correct alpha blending.
Only sorts the alive portion of the pool (partitioned to the front).
"""
function _sort_particles_back_to_front!(pool::ParticlePool, cam_pos::Vec3f)
    particles = pool.particles
    n = length(particles)
    alive_count = pool.alive_count

    # Skip sort if ≤1 alive
    alive_count <= 1 && return

    # Partition: move alive particles to the front
    write_idx = 1
    for read_idx in 1:n
        if particles[read_idx].alive
            if write_idx != read_idx
                particles[write_idx], particles[read_idx] = particles[read_idx], particles[write_idx]
            end
            write_idx += 1
        end
    end

    # Sort only alive particles (indices 1:alive_count) by distance to camera
    cx, cy, cz = cam_pos[1], cam_pos[2], cam_pos[3]
    sort!(view(particles, 1:alive_count), by = p -> begin
        dx = p.position[1] - cx
        dy = p.position[2] - cy
        dz = p.position[3] - cz
        -(dx*dx + dy*dy + dz*dz)
    end)
end

"""
    _build_billboard_vertices!(pool, comp, cam_right, cam_up)

Generate camera-facing billboard quads for all alive particles.
Returns the number of vertices written.
"""
function _build_billboard_vertices!(pool::ParticlePool, comp::ParticleSystemComponent,
                                    cam_right::Vec3f, cam_up::Vec3f)
    idx = 0  # float index into vertex_data
    vert_count = 0

    for p in pool.particles
        !p.alive && continue

        # Lifetime fraction (0 = just born, 1 = about to die)
        t = 1.0f0 - clamp(p.lifetime / p.max_lifetime, 0.0f0, 1.0f0)

        # Interpolated size
        size = _lerp(p.size, comp.end_size, t)
        half = size * 0.5f0

        # Interpolated color + alpha
        r = _lerp(comp.start_color.r, comp.end_color.r, t)
        g = _lerp(comp.start_color.g, comp.end_color.g, t)
        b = _lerp(comp.start_color.b, comp.end_color.b, t)
        a = _lerp(comp.start_alpha, comp.end_alpha, t)

        # Billboard corners
        right = cam_right * half
        up = cam_up * half
        center = p.position

        bl = center - right - up  # bottom-left
        br = center + right - up  # bottom-right
        tr = center + right + up  # top-right
        tl = center - right + up  # top-left

        # Two triangles: bl-br-tr and bl-tr-tl
        # Each vertex: pos3 + uv2 + color4 = 9 floats
        data = pool.vertex_data

        # Ensure capacity
        needed = (vert_count + 6) * 9
        if needed > length(data)
            break
        end

        # Triangle 1: bl, br, tr
        _write_particle_vertex!(data, idx, bl, 0f0, 0f0, r, g, b, a); idx += 9
        _write_particle_vertex!(data, idx, br, 1f0, 0f0, r, g, b, a); idx += 9
        _write_particle_vertex!(data, idx, tr, 1f0, 1f0, r, g, b, a); idx += 9

        # Triangle 2: bl, tr, tl
        _write_particle_vertex!(data, idx, bl, 0f0, 0f0, r, g, b, a); idx += 9
        _write_particle_vertex!(data, idx, tr, 1f0, 1f0, r, g, b, a); idx += 9
        _write_particle_vertex!(data, idx, tl, 0f0, 1f0, r, g, b, a); idx += 9

        vert_count += 6
    end

    pool.vertex_count = vert_count
    return vert_count
end

@inline function _write_particle_vertex!(data::Vector{Float32}, offset::Int,
                                          pos::Vec3f, u::Float32, v::Float32,
                                          r::Float32, g::Float32, b::Float32, a::Float32)
    data[offset + 1] = pos[1]
    data[offset + 2] = pos[2]
    data[offset + 3] = pos[3]
    data[offset + 4] = u
    data[offset + 5] = v
    data[offset + 6] = r
    data[offset + 7] = g
    data[offset + 8] = b
    data[offset + 9] = a
end

# ---- Public API ----

"""
    update_particles!(dt, cam_pos, cam_right, cam_up)

Simulate all particle systems and generate billboard geometry.
Call once per frame before rendering.
"""
function update_particles!(dt::Float32, cam_pos::Vec3f, cam_right::Vec3f, cam_up::Vec3f)
    # Track active emitters for pool cleanup
    active_emitters = Set{EntityID}()

    iterate_components(ParticleSystemComponent) do eid, comp
        !comp._active && return
        push!(active_emitters, eid)

        # Get or create pool
        pool = get!(PARTICLE_POOLS, eid) do
            ParticlePool(comp.max_particles)
        end

        # Resize pool if max_particles changed
        if length(pool.particles) < comp.max_particles
            for _ in 1:(comp.max_particles - length(pool.particles))
                push!(pool.particles, Particle())
            end
            resize!(pool.vertex_data, comp.max_particles * 6 * 9)
        end

        # World position of emitter
        world = get_world_transform(eid)
        origin = Vec3f(Float32(world[1, 4]), Float32(world[2, 4]), Float32(world[3, 4]))

        # Handle burst emission
        if comp.burst_count > 0
            for _ in 1:comp.burst_count
                _emit_particle!(pool, comp, origin) || break
            end
            comp.burst_count = 0
        end

        # Continuous emission
        if comp.emission_rate > 0.0f0
            comp._emit_accumulator += comp.emission_rate * dt
            while comp._emit_accumulator >= 1.0f0
                _emit_particle!(pool, comp, origin) || break
                comp._emit_accumulator -= 1.0f0
            end
        end

        # Simulate
        _simulate_particles!(pool, comp, dt)

        # Sort back-to-front (only alive particles)
        _sort_particles_back_to_front!(pool, cam_pos)

        # Build billboard quads
        _build_billboard_vertices!(pool, comp, cam_right, cam_up)
    end

    # Clean up pools for removed entities
    for eid in keys(PARTICLE_POOLS)
        if eid ∉ active_emitters
            delete!(PARTICLE_POOLS, eid)
        end
    end
end

"""
    update_particles!(dt)

Convenience overload that extracts camera info automatically.
"""
function update_particles!(dt::Float64)
    camera_id = find_active_camera()
    camera_id === nothing && return

    view = get_view_matrix(camera_id)

    # Extract camera vectors from view matrix (inverse of camera rotation)
    # View matrix rows = camera axes in world space
    cam_right = Vec3f(view[1,1], view[2,1], view[3,1])
    cam_up    = Vec3f(view[1,2], view[2,2], view[3,2])

    cam_world = get_world_transform(camera_id)
    cam_pos = Vec3f(Float32(cam_world[1, 4]), Float32(cam_world[2, 4]), Float32(cam_world[3, 4]))

    update_particles!(Float32(dt), cam_pos, cam_right, cam_up)
end
