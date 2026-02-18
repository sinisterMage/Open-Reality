# GPU compute shader particle system (OpenGL 4.3+)
# Moves particle simulation entirely to the GPU via compute shaders.
# Falls back to CPU path (opengl_particles.jl / systems/particles.jl) on GL < 4.3.

# ---- Compute Shader Support Detection ----

const _COMPUTE_SUPPORTED = Ref{Union{Bool, Nothing}}(nothing)

function _has_compute_shader_support()::Bool
    major = Ref(GLint(0))
    minor = Ref(GLint(0))
    glGetIntegerv(GL_MAJOR_VERSION, major)
    glGetIntegerv(GL_MINOR_VERSION, minor)
    return (major[] > 4) || (major[] == 4 && minor[] >= 3)
end

"""
    has_gpu_particles() -> Bool

Returns true if GPU compute particle path is available (OpenGL 4.3+). Cached after first call.
"""
function has_gpu_particles()::Bool
    if _COMPUTE_SUPPORTED[] === nothing
        _COMPUTE_SUPPORTED[] = _has_compute_shader_support()
        if _COMPUTE_SUPPORTED[]
            @info "GPU particles: compute shaders supported (OpenGL 4.3+)"
        else
            @info "GPU particles: compute shaders NOT supported, using CPU fallback"
        end
    end
    return _COMPUTE_SUPPORTED[]::Bool
end

# ---- GLSL Compute Shaders ----

const GPU_PARTICLE_EMISSION_SHADER = """
#version 430 core

layout(local_size_x = 64) in;

struct Particle {
    vec4 position_lifetime;   // xyz=pos, w=remaining_lifetime
    vec4 velocity_maxlife;    // xyz=vel, w=max_lifetime
    vec4 size_data;           // x=start_size, y=end_size, z=0, w=0
    uvec4 flags_colors;       // x=alive(0/1), y=start_color_packed, z=end_color_packed, w=alpha_packed
};

layout(std430, binding = 0) buffer ParticleBuffer {
    Particle particles[];
};

layout(std430, binding = 3) buffer CounterBuffer {
    uint alive_count;
    uint compact_count;
};

uniform vec3 u_EmitterOrigin;
uniform vec3 u_VelocityMin;
uniform vec3 u_VelocityMax;
uniform float u_LifetimeMin;
uniform float u_LifetimeMax;
uniform float u_StartSizeMin;
uniform float u_StartSizeMax;
uniform float u_EndSize;
uniform vec3 u_StartColor;
uniform vec3 u_EndColor;
uniform float u_StartAlpha;
uniform float u_EndAlpha;
uniform uint u_MaxParticles;
uniform uint u_EmitCount;
uniform uint u_FrameSeed;

// PCG hash for GPU RNG
uint pcg_hash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand_float(inout uint seed) {
    seed = pcg_hash(seed);
    return float(seed) / 4294967295.0;
}

float rand_range(float lo, float hi, inout uint seed) {
    return lo + rand_float(seed) * (hi - lo);
}

vec3 rand_range_vec3(vec3 lo, vec3 hi, inout uint seed) {
    return vec3(
        rand_range(lo.x, hi.x, seed),
        rand_range(lo.y, hi.y, seed),
        rand_range(lo.z, hi.z, seed)
    );
}

// Pack RGB (0-1 each) into a single uint using 11-11-10 bit layout
uint pack_color(vec3 c) {
    uint r = uint(clamp(c.r, 0.0, 1.0) * 2047.0);
    uint g = uint(clamp(c.g, 0.0, 1.0) * 2047.0);
    uint b = uint(clamp(c.b, 0.0, 1.0) * 1023.0);
    return (r << 21u) | (g << 10u) | b;
}

// Pack two float alpha values (0-1) into a single uint (16 bits each)
uint pack_alpha(float start_a, float end_a) {
    uint sa = uint(clamp(start_a, 0.0, 1.0) * 65535.0);
    uint ea = uint(clamp(end_a, 0.0, 1.0) * 65535.0);
    return (sa << 16u) | ea;
}

void main() {
    uint emit_idx = gl_GlobalInvocationID.x;
    if (emit_idx >= u_EmitCount) return;

    uint seed = u_FrameSeed ^ (emit_idx * 1973u + 9277u);

    // Start scanning from a pseudo-random position to spread across buffer
    uint start = pcg_hash(seed) % u_MaxParticles;

    for (uint attempt = 0u; attempt < u_MaxParticles; attempt++) {
        uint slot = (start + attempt) % u_MaxParticles;

        // Atomically try to claim a dead slot (0 -> 1)
        uint old = atomicCompSwap(particles[slot].flags_colors.x, 0u, 1u);
        if (old == 0u) {
            // We claimed this slot — initialize particle
            float lifetime = rand_range(u_LifetimeMin, u_LifetimeMax, seed);
            vec3 velocity = rand_range_vec3(u_VelocityMin, u_VelocityMax, seed);
            float start_size = rand_range(u_StartSizeMin, u_StartSizeMax, seed);

            particles[slot].position_lifetime = vec4(u_EmitterOrigin, lifetime);
            particles[slot].velocity_maxlife = vec4(velocity, lifetime);
            particles[slot].size_data = vec4(start_size, u_EndSize, 0.0, 0.0);
            particles[slot].flags_colors.y = pack_color(u_StartColor);
            particles[slot].flags_colors.z = pack_color(u_EndColor);
            particles[slot].flags_colors.w = pack_alpha(u_StartAlpha, u_EndAlpha);

            atomicAdd(alive_count, 1u);
            break;
        }
    }
}
"""

const GPU_PARTICLE_SIMULATION_SHADER = """
#version 430 core

layout(local_size_x = 256) in;

struct Particle {
    vec4 position_lifetime;
    vec4 velocity_maxlife;
    vec4 size_data;
    uvec4 flags_colors;
};

layout(std430, binding = 0) buffer ParticleBuffer {
    Particle particles[];
};

uniform float u_DeltaTime;
uniform float u_GravityModifier;
uniform float u_Damping;
uniform uint u_MaxParticles;

const vec3 GRAVITY = vec3(0.0, -9.81, 0.0);

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= u_MaxParticles) return;

    // Skip dead particles
    if (particles[idx].flags_colors.x == 0u) return;

    // Decrement lifetime
    float lifetime = particles[idx].position_lifetime.w - u_DeltaTime;

    if (lifetime <= 0.0) {
        // Kill particle
        particles[idx].flags_colors.x = 0u;
        return;
    }

    particles[idx].position_lifetime.w = lifetime;

    // Physics: gravity
    vec3 vel = particles[idx].velocity_maxlife.xyz;
    vel += GRAVITY * u_GravityModifier * u_DeltaTime;

    // Physics: damping
    if (u_Damping > 0.0) {
        vel *= (1.0 - u_Damping * u_DeltaTime);
    }

    // Euler integration
    particles[idx].position_lifetime.xyz += vel * u_DeltaTime;
    particles[idx].velocity_maxlife.xyz = vel;
}
"""

const GPU_PARTICLE_COMPACT_SHADER = """
#version 430 core

layout(local_size_x = 256) in;

struct Particle {
    vec4 position_lifetime;
    vec4 velocity_maxlife;
    vec4 size_data;
    uvec4 flags_colors;
};

layout(std430, binding = 0) readonly buffer ParticleBuffer {
    Particle particles[];
};

layout(std430, binding = 2) writeonly buffer AliveIndexBuffer {
    uint alive_indices[];
};

layout(std430, binding = 3) buffer CounterBuffer {
    uint alive_count;
    uint compact_count;
};

uniform uint u_MaxParticles;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= u_MaxParticles) return;

    if (particles[idx].flags_colors.x != 0u) {
        uint write_pos = atomicAdd(compact_count, 1u);
        alive_indices[write_pos] = idx;
    }
}
"""

const GPU_PARTICLE_INDIRECT_UPDATE_SHADER = """
#version 430 core

layout(local_size_x = 1) in;

layout(std430, binding = 1) writeonly buffer DrawIndirectBuffer {
    uint draw_count;          // vertices per instance (6)
    uint draw_instanceCount;  // alive particle count
    uint draw_first;          // 0
    uint draw_baseInstance;   // 0
};

layout(std430, binding = 3) readonly buffer CounterBuffer {
    uint alive_count;
    uint compact_count;
};

void main() {
    draw_count = 6u;
    draw_instanceCount = compact_count;
    draw_first = 0u;
    draw_baseInstance = 0u;
}
"""

# ---- Render Shaders ----

const GPU_PARTICLE_RENDER_VS = """
#version 430 core

struct Particle {
    vec4 position_lifetime;
    vec4 velocity_maxlife;
    vec4 size_data;
    uvec4 flags_colors;
};

layout(std430, binding = 0) readonly buffer ParticleBuffer {
    Particle particles[];
};

layout(std430, binding = 2) readonly buffer AliveIndexBuffer {
    uint alive_indices[];
};

uniform mat4 u_View;
uniform mat4 u_Projection;
uniform vec3 u_CamRight;
uniform vec3 u_CamUp;

out vec2 v_TexCoord;
out vec4 v_Color;

// 6 vertices for a billboard quad (2 triangles)
const vec2 QUAD_OFFSETS[6] = vec2[6](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5), vec2( 0.5,  0.5),
    vec2(-0.5, -0.5), vec2( 0.5,  0.5), vec2(-0.5,  0.5)
);
const vec2 QUAD_UVS[6] = vec2[6](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
    vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
);

vec3 unpack_color(uint val) {
    float r = float((val >> 21u) & 0x7FFu) / 2047.0;
    float g = float((val >> 10u) & 0x7FFu) / 2047.0;
    float b = float(val & 0x3FFu) / 1023.0;
    return vec3(r, g, b);
}

void unpack_alpha(uint val, out float start_a, out float end_a) {
    start_a = float((val >> 16u) & 0xFFFFu) / 65535.0;
    end_a = float(val & 0xFFFFu) / 65535.0;
}

void main() {
    uint particle_idx = alive_indices[gl_InstanceID];
    Particle p = particles[particle_idx];

    int vert_id = gl_VertexID;
    vec2 offset = QUAD_OFFSETS[vert_id];
    v_TexCoord = QUAD_UVS[vert_id];

    // Lifetime fraction: 0=born, 1=dying
    float t = 1.0 - clamp(p.position_lifetime.w / p.velocity_maxlife.w, 0.0, 1.0);

    // Interpolate size
    float size = mix(p.size_data.x, p.size_data.y, t);

    // Interpolate color + alpha
    vec3 start_col = unpack_color(p.flags_colors.y);
    vec3 end_col = unpack_color(p.flags_colors.z);
    vec3 color = mix(start_col, end_col, t);

    float start_a, end_a;
    unpack_alpha(p.flags_colors.w, start_a, end_a);
    float alpha = mix(start_a, end_a, t);

    v_Color = vec4(color, alpha);

    // Billboard in world space
    vec3 world_pos = p.position_lifetime.xyz
                   + u_CamRight * offset.x * size
                   + u_CamUp * offset.y * size;

    gl_Position = u_Projection * u_View * vec4(world_pos, 1.0);
}
"""

const GPU_PARTICLE_RENDER_FS = """
#version 430 core

in vec2 v_TexCoord;
in vec4 v_Color;

out vec4 FragColor;

void main() {
    vec2 center = v_TexCoord - vec2(0.5);
    float dist = dot(center, center) * 4.0;
    float alpha = 1.0 - smoothstep(0.5, 1.0, dist);

    FragColor = vec4(v_Color.rgb, v_Color.a * alpha);
    if (FragColor.a < 0.01) discard;
}
"""

# ---- GPU State Structures ----

mutable struct GPUParticleEmitter
    max_particles::Int
    ssbo_particles::GLuint       # binding 0: particle data (80 bytes each)
    ssbo_alive_indices::GLuint   # binding 2: compacted alive indices
    ssbo_counters::GLuint        # binding 3: [alive_count, compact_count]
    indirect_draw_buf::GLuint    # binding 1: DrawArraysIndirectCommand
    initialized::Bool

    GPUParticleEmitter() = new(0, GLuint(0), GLuint(0), GLuint(0), GLuint(0), false)
end

const GPU_PARTICLE_EMITTERS = Dict{EntityID, GPUParticleEmitter}()

mutable struct GPUParticleShaders
    emission_shader::Union{ShaderProgram, Nothing}
    simulation_shader::Union{ShaderProgram, Nothing}
    compact_shader::Union{ShaderProgram, Nothing}
    indirect_update_shader::Union{ShaderProgram, Nothing}
    render_shader::Union{ShaderProgram, Nothing}
    quad_vao::GLuint   # empty VAO for instanced draw
    initialized::Bool

    GPUParticleShaders() = new(nothing, nothing, nothing, nothing, nothing, GLuint(0), false)
end

const _GPU_PARTICLE_SHADERS = GPUParticleShaders()

# ---- Per-Emitter GPU Resource Management ----

const _PARTICLE_STRUCT_SIZE = 80  # 4 × vec4/uvec4 = 4 × 16 = 64... but uvec4 = 16, total = 64
# Actually: vec4(16) + vec4(16) + vec4(16) + uvec4(16) = 64 bytes in std430
const _PARTICLE_GPU_SIZE = 64

function create_gpu_emitter!(eid::EntityID, max_particles::Int)
    emitter = GPUParticleEmitter()
    emitter.max_particles = max_particles

    # Particle SSBO (binding 0) — 64 bytes per particle, zero-initialized (all dead)
    ssbo_ref = Ref(GLuint(0))
    glGenBuffers(1, ssbo_ref)
    emitter.ssbo_particles = ssbo_ref[]
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, emitter.ssbo_particles)
    total_bytes = max_particles * _PARTICLE_GPU_SIZE
    glBufferData(GL_SHADER_STORAGE_BUFFER, total_bytes, C_NULL, GL_DYNAMIC_COPY)
    # Zero-initialize so all particles start dead (flags_colors.x = 0)
    zeros_buf = zeros(UInt8, total_bytes)
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, total_bytes, zeros_buf)
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, GLuint(0))

    # Alive indices SSBO (binding 2) — uint per particle
    alive_ref = Ref(GLuint(0))
    glGenBuffers(1, alive_ref)
    emitter.ssbo_alive_indices = alive_ref[]
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, emitter.ssbo_alive_indices)
    glBufferData(GL_SHADER_STORAGE_BUFFER, max_particles * sizeof(GLuint), C_NULL, GL_DYNAMIC_COPY)
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, GLuint(0))

    # Counter SSBO (binding 3) — 2 uints: [alive_count, compact_count]
    counter_ref = Ref(GLuint(0))
    glGenBuffers(1, counter_ref)
    emitter.ssbo_counters = counter_ref[]
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, emitter.ssbo_counters)
    zero_counters = GLuint[0, 0]
    glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(zero_counters), zero_counters, GL_DYNAMIC_COPY)
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, GLuint(0))

    # Indirect draw buffer (binding 1) — DrawArraysIndirectCommand
    indirect_ref = Ref(GLuint(0))
    glGenBuffers(1, indirect_ref)
    emitter.indirect_draw_buf = indirect_ref[]
    glBindBuffer(GL_DRAW_INDIRECT_BUFFER, emitter.indirect_draw_buf)
    # count=6 (quad verts), instanceCount=0, first=0, baseInstance=0
    cmd = GLuint[6, 0, 0, 0]
    glBufferData(GL_DRAW_INDIRECT_BUFFER, sizeof(cmd), cmd, GL_DYNAMIC_COPY)
    glBindBuffer(GL_DRAW_INDIRECT_BUFFER, GLuint(0))

    emitter.initialized = true
    GPU_PARTICLE_EMITTERS[eid] = emitter
    return emitter
end

function destroy_gpu_emitter!(emitter::GPUParticleEmitter)
    !emitter.initialized && return

    for buf_id in [emitter.ssbo_particles, emitter.ssbo_alive_indices,
                   emitter.ssbo_counters, emitter.indirect_draw_buf]
        if buf_id != GLuint(0)
            bufs = GLuint[buf_id]
            glDeleteBuffers(1, bufs)
        end
    end

    emitter.ssbo_particles = GLuint(0)
    emitter.ssbo_alive_indices = GLuint(0)
    emitter.ssbo_counters = GLuint(0)
    emitter.indirect_draw_buf = GLuint(0)
    emitter.initialized = false
end

# ---- Shader Initialization ----

function init_gpu_particle_shaders!()
    _GPU_PARTICLE_SHADERS.initialized && return
    !has_gpu_particles() && return

    _GPU_PARTICLE_SHADERS.emission_shader = create_compute_shader_program(GPU_PARTICLE_EMISSION_SHADER)
    _GPU_PARTICLE_SHADERS.simulation_shader = create_compute_shader_program(GPU_PARTICLE_SIMULATION_SHADER)
    _GPU_PARTICLE_SHADERS.compact_shader = create_compute_shader_program(GPU_PARTICLE_COMPACT_SHADER)
    _GPU_PARTICLE_SHADERS.indirect_update_shader = create_compute_shader_program(GPU_PARTICLE_INDIRECT_UPDATE_SHADER)
    _GPU_PARTICLE_SHADERS.render_shader = create_shader_program(GPU_PARTICLE_RENDER_VS, GPU_PARTICLE_RENDER_FS)

    # Create an empty VAO for instanced draw (no vertex attributes — all data from SSBOs)
    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    _GPU_PARTICLE_SHADERS.quad_vao = vao_ref[]

    _GPU_PARTICLE_SHADERS.initialized = true
    @info "GPU particle shaders compiled successfully"
end

function shutdown_gpu_particle_shaders!()
    !_GPU_PARTICLE_SHADERS.initialized && return

    for shader in [_GPU_PARTICLE_SHADERS.emission_shader,
                   _GPU_PARTICLE_SHADERS.simulation_shader,
                   _GPU_PARTICLE_SHADERS.compact_shader,
                   _GPU_PARTICLE_SHADERS.indirect_update_shader,
                   _GPU_PARTICLE_SHADERS.render_shader]
        if shader !== nothing
            destroy_shader_program!(shader)
        end
    end
    _GPU_PARTICLE_SHADERS.emission_shader = nothing
    _GPU_PARTICLE_SHADERS.simulation_shader = nothing
    _GPU_PARTICLE_SHADERS.compact_shader = nothing
    _GPU_PARTICLE_SHADERS.indirect_update_shader = nothing
    _GPU_PARTICLE_SHADERS.render_shader = nothing

    if _GPU_PARTICLE_SHADERS.quad_vao != GLuint(0)
        vaos = GLuint[_GPU_PARTICLE_SHADERS.quad_vao]
        glDeleteVertexArrays(1, vaos)
        _GPU_PARTICLE_SHADERS.quad_vao = GLuint(0)
    end

    # Clean up all emitters
    for (_, emitter) in GPU_PARTICLE_EMITTERS
        destroy_gpu_emitter!(emitter)
    end
    empty!(GPU_PARTICLE_EMITTERS)

    _GPU_PARTICLE_SHADERS.initialized = false
end

function reset_gpu_particle_emitters!()
    empty!(GPU_PARTICLE_EMITTERS)
    _COMPUTE_SUPPORTED[] = nothing
end

# ---- Per-Frame GPU Simulation ----

function update_gpu_particles!(dt::Float32, cam_pos::Vec3f, cam_right::Vec3f, cam_up::Vec3f)
    !_GPU_PARTICLE_SHADERS.initialized && return

    active_emitters = Set{EntityID}()
    frame_seed = rand(UInt32)

    iterate_components(ParticleSystemComponent) do eid, comp
        !comp._active && return
        push!(active_emitters, eid)

        # Get or create GPU emitter
        emitter = get(GPU_PARTICLE_EMITTERS, eid, nothing)
        if emitter === nothing
            emitter = create_gpu_emitter!(eid, comp.max_particles)
        elseif emitter.max_particles < comp.max_particles
            destroy_gpu_emitter!(emitter)
            emitter = create_gpu_emitter!(eid, comp.max_particles)
        end

        max_p = UInt32(comp.max_particles)

        # World position of emitter
        world = get_world_transform(eid)
        origin = Vec3f(Float32(world[1, 4]), Float32(world[2, 4]), Float32(world[3, 4]))

        # Calculate emit count this frame
        emit_count = UInt32(0)
        if comp.burst_count > 0
            emit_count += UInt32(comp.burst_count)
            comp.burst_count = 0
        end
        if comp.emission_rate > 0.0f0
            comp._emit_accumulator += comp.emission_rate * dt
            new_particles = UInt32(floor(comp._emit_accumulator))
            comp._emit_accumulator -= Float32(new_particles)
            emit_count += new_particles
        end

        # Bind particle SSBO and counter SSBO for all dispatches
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, emitter.ssbo_particles)
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, emitter.ssbo_counters)

        # ---- Step 1: Emission ----
        if emit_count > 0
            sp = _GPU_PARTICLE_SHADERS.emission_shader
            glUseProgram(sp.id)

            set_uniform!(sp, "u_EmitterOrigin", origin)
            set_uniform!(sp, "u_VelocityMin", comp.velocity_min)
            set_uniform!(sp, "u_VelocityMax", comp.velocity_max)
            set_uniform!(sp, "u_LifetimeMin", comp.lifetime_min)
            set_uniform!(sp, "u_LifetimeMax", comp.lifetime_max)
            set_uniform!(sp, "u_StartSizeMin", comp.start_size_min)
            set_uniform!(sp, "u_StartSizeMax", comp.start_size_max)
            set_uniform!(sp, "u_EndSize", comp.end_size)
            set_uniform!(sp, "u_StartColor", comp.start_color)
            set_uniform!(sp, "u_EndColor", comp.end_color)
            set_uniform!(sp, "u_StartAlpha", comp.start_alpha)
            set_uniform!(sp, "u_EndAlpha", comp.end_alpha)
            set_uniform!(sp, "u_MaxParticles", max_p)
            set_uniform!(sp, "u_EmitCount", emit_count)
            set_uniform!(sp, "u_FrameSeed", frame_seed)

            num_groups = cld(emit_count, UInt32(64))
            glDispatchCompute(num_groups, GLuint(1), GLuint(1))
            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT)
        end

        # ---- Step 2: Simulation ----
        sp = _GPU_PARTICLE_SHADERS.simulation_shader
        glUseProgram(sp.id)

        set_uniform!(sp, "u_DeltaTime", dt)
        set_uniform!(sp, "u_GravityModifier", comp.gravity_modifier)
        set_uniform!(sp, "u_Damping", comp.damping)
        set_uniform!(sp, "u_MaxParticles", max_p)

        num_groups = cld(max_p, UInt32(256))
        glDispatchCompute(num_groups, GLuint(1), GLuint(1))
        glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT)

        # ---- Step 3: Reset compact counter, then compact ----
        # Reset compact_count to 0 (second uint in counter buffer)
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, emitter.ssbo_counters)
        zero_val = UInt32[0]
        glBufferSubData(GL_SHADER_STORAGE_BUFFER, sizeof(GLuint), sizeof(GLuint), zero_val)
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, GLuint(0))

        # Re-bind counter SSBO after the raw buffer operation
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, emitter.ssbo_counters)
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, emitter.ssbo_alive_indices)

        sp = _GPU_PARTICLE_SHADERS.compact_shader
        glUseProgram(sp.id)
        set_uniform!(sp, "u_MaxParticles", max_p)

        glDispatchCompute(num_groups, GLuint(1), GLuint(1))
        glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT)

        # ---- Step 4: Update indirect draw command ----
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, emitter.indirect_draw_buf)

        sp = _GPU_PARTICLE_SHADERS.indirect_update_shader
        glUseProgram(sp.id)

        glDispatchCompute(GLuint(1), GLuint(1), GLuint(1))
        glMemoryBarrier(GL_COMMAND_BARRIER_BIT | GL_SHADER_STORAGE_BARRIER_BIT)
    end

    # Cleanup emitters for removed entities
    for eid in keys(GPU_PARTICLE_EMITTERS)
        if eid ∉ active_emitters
            destroy_gpu_emitter!(GPU_PARTICLE_EMITTERS[eid])
            delete!(GPU_PARTICLE_EMITTERS, eid)
        end
    end

    glUseProgram(GLuint(0))
end

# ---- GPU Particle Rendering ----

function render_gpu_particles!(view::Mat4f, proj::Mat4f, cam_right::Vec3f, cam_up::Vec3f)
    isempty(GPU_PARTICLE_EMITTERS) && return
    !_GPU_PARTICLE_SHADERS.initialized && return

    sp = _GPU_PARTICLE_SHADERS.render_shader
    sp === nothing && return

    glUseProgram(sp.id)
    set_uniform!(sp, "u_View", view)
    set_uniform!(sp, "u_Projection", proj)
    set_uniform!(sp, "u_CamRight", cam_right)
    set_uniform!(sp, "u_CamUp", cam_up)

    glBindVertexArray(_GPU_PARTICLE_SHADERS.quad_vao)

    # Depth test on but no writes (particles are transparent)
    glEnable(GL_DEPTH_TEST)
    glDepthMask(GL_FALSE)
    glDisable(GL_CULL_FACE)

    for (eid, emitter) in GPU_PARTICLE_EMITTERS
        !emitter.initialized && continue

        comp = get_component(eid, ParticleSystemComponent)

        # Set blend mode
        glEnable(GL_BLEND)
        if comp !== nothing && comp.additive
            glBlendFunc(GL_SRC_ALPHA, GL_ONE)
        else
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        end

        # Bind particle data SSBOs
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, emitter.ssbo_particles)
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, emitter.ssbo_alive_indices)

        # Indirect draw — GPU controls instance count
        glBindBuffer(GL_DRAW_INDIRECT_BUFFER, emitter.indirect_draw_buf)
        glDrawArraysIndirect(GL_TRIANGLES, C_NULL)
    end

    # Restore state
    glBindVertexArray(GLuint(0))
    glBindBuffer(GL_DRAW_INDIRECT_BUFFER, GLuint(0))
    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)
    glEnable(GL_CULL_FACE)
    glUseProgram(GLuint(0))
end
