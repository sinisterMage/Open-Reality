// Motion Blur — camera-based per-pixel velocity blur.
// Two passes: velocity buffer computation, directional blur along velocity vectors.
// Uses fullscreen_quad.wgsl vertex shader (vertex index-based full-screen triangle).

// ---- Pass 1: Velocity Buffer ----

struct VelocityParams {
    inv_view_proj: mat4x4<f32>,
    prev_view_proj: mat4x4<f32>,
    max_velocity: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};

@group(0) @binding(0) var<uniform> velocity_params: VelocityParams;
@group(0) @binding(1) var depth_texture: texture_depth_2d;
@group(0) @binding(2) var depth_sampler: sampler;

struct FragmentInput {
    @location(0) uv: vec2<f32>,
};

@fragment
fn fs_velocity(in: FragmentInput) -> @location(0) vec2<f32> {
    let depth = textureSample(depth_texture, depth_sampler, in.uv);

    // Reconstruct clip-space position
    let clip_pos = vec4<f32>(in.uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);

    // Reconstruct world-space position
    var world_pos = velocity_params.inv_view_proj * clip_pos;
    world_pos /= world_pos.w;

    // Project to previous frame's clip space
    var prev_clip = velocity_params.prev_view_proj * world_pos;
    prev_clip /= prev_clip.w;
    let prev_uv = prev_clip.xy * 0.5 + 0.5;

    // Screen-space velocity
    var velocity = in.uv - prev_uv;

    // Clamp velocity magnitude
    let speed = length(velocity);
    let tex_size = vec2<f32>(textureDimensions(depth_texture));
    let max_speed = velocity_params.max_velocity / tex_size.x;
    if speed > max_speed {
        velocity = velocity / speed * max_speed;
    }

    return velocity;
}

// ---- Pass 2: Directional Blur ----

struct BlurParams {
    samples: i32,
    intensity: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var<uniform> blur_params: BlurParams;
@group(0) @binding(1) var scene_texture: texture_2d<f32>;
@group(0) @binding(2) var velocity_texture: texture_2d<f32>;
@group(0) @binding(3) var blur_sampler: sampler;

@fragment
fn fs_blur(in: FragmentInput) -> @location(0) vec4<f32> {
    let velocity = textureSample(velocity_texture, blur_sampler, in.uv).rg * blur_params.intensity;

    var result = textureSample(scene_texture, blur_sampler, in.uv).rgb;
    var total = 1.0;

    for (var i = 1; i < blur_params.samples; i++) {
        let t = f32(i) / f32(blur_params.samples - 1) - 0.5;
        let offset = velocity * t;
        result += textureSample(scene_texture, blur_sampler, in.uv + offset).rgb;
        total += 1.0;
    }

    return vec4<f32>(result / total, 1.0);
}
