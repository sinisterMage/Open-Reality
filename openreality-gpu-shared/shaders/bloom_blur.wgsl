// Bloom Gaussian blur pass (separable, 5-tap).
// Fully unrolled to avoid array<f32, N> constructor which can crash some NVIDIA drivers.

struct PostProcessParams {
    bloom_threshold: f32,
    bloom_intensity: f32,
    gamma: f32,
    tone_mapping_mode: i32,
    horizontal: i32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};

@group(0) @binding(0) var<uniform> params: PostProcessParams;
@group(0) @binding(1) var input_texture: texture_2d<f32>;
@group(0) @binding(2) var tex_sampler: sampler;

struct FragmentInput {
    @location(0) uv: vec2<f32>,
};

// Gaussian weights
const W0: f32 = 0.227027;
const W1: f32 = 0.1945946;
const W2: f32 = 0.1216216;
const W3: f32 = 0.054054;
const W4: f32 = 0.016216;

@fragment
fn fs_main(in: FragmentInput) -> @location(0) vec4<f32> {
    let tex_size = vec2<f32>(textureDimensions(input_texture, 0));
    let texel_size = 1.0 / tex_size;

    var result = textureSample(input_texture, tex_sampler, in.uv).rgb * W0;

    if params.horizontal != 0 {
        let dx1 = vec2<f32>(texel_size.x, 0.0);
        let dx2 = vec2<f32>(texel_size.x * 2.0, 0.0);
        let dx3 = vec2<f32>(texel_size.x * 3.0, 0.0);
        let dx4 = vec2<f32>(texel_size.x * 4.0, 0.0);
        result += (textureSample(input_texture, tex_sampler, in.uv + dx1).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dx1).rgb) * W1;
        result += (textureSample(input_texture, tex_sampler, in.uv + dx2).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dx2).rgb) * W2;
        result += (textureSample(input_texture, tex_sampler, in.uv + dx3).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dx3).rgb) * W3;
        result += (textureSample(input_texture, tex_sampler, in.uv + dx4).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dx4).rgb) * W4;
    } else {
        let dy1 = vec2<f32>(0.0, texel_size.y);
        let dy2 = vec2<f32>(0.0, texel_size.y * 2.0);
        let dy3 = vec2<f32>(0.0, texel_size.y * 3.0);
        let dy4 = vec2<f32>(0.0, texel_size.y * 4.0);
        result += (textureSample(input_texture, tex_sampler, in.uv + dy1).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dy1).rgb) * W1;
        result += (textureSample(input_texture, tex_sampler, in.uv + dy2).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dy2).rgb) * W2;
        result += (textureSample(input_texture, tex_sampler, in.uv + dy3).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dy3).rgb) * W3;
        result += (textureSample(input_texture, tex_sampler, in.uv + dy4).rgb +
                   textureSample(input_texture, tex_sampler, in.uv - dy4).rgb) * W4;
    }

    return vec4<f32>(result, 1.0);
}
