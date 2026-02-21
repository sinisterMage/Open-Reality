// Bloom bright pixel extraction pass.

struct PostProcessParams {
    bloom_threshold: f32,
    bloom_intensity: f32,
    gamma: f32,
    tone_mapping_mode: i32,
    horizontal: i32,
    vignette_intensity: f32,
    vignette_radius: f32,
    vignette_softness: f32,
    color_brightness: f32,
    color_contrast: f32,
    color_saturation: f32,
    _pad1: f32,
};

@group(0) @binding(0) var<uniform> params: PostProcessParams;
@group(0) @binding(1) var scene_texture: texture_2d<f32>;
@group(0) @binding(2) var tex_sampler: sampler;

struct FragmentInput {
    @location(0) uv: vec2<f32>,
};

@fragment
fn fs_main(in: FragmentInput) -> @location(0) vec4<f32> {
    let color = textureSample(scene_texture, tex_sampler, in.uv).rgb;
    let brightness = dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));

    if brightness > params.bloom_threshold {
        return vec4<f32>(color, 1.0);
    } else {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
}
