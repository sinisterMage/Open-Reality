// Final present pass — blit post-processed result to swapchain.
// Bloom composite already handles tone mapping + gamma correction,
// so this pass just copies the final result.

struct PresentParams {
    bloom_threshold: f32,
    bloom_intensity: f32,
    gamma: f32,
    tone_mapping_mode: i32,
    horizontal: i32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};

@group(0) @binding(0) var<uniform> params: PresentParams;
@group(0) @binding(1) var scene_texture: texture_2d<f32>;
@group(0) @binding(2) var tex_sampler: sampler;

struct FragmentInput {
    @location(0) uv: vec2<f32>,
};

@fragment
fn fs_main(in: FragmentInput) -> @location(0) vec4<f32> {
    let color = textureSample(scene_texture, tex_sampler, in.uv).rgb;
    return vec4<f32>(color, 1.0);
}
