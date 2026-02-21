// Bloom composite + tone mapping + gamma correction.

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
@group(0) @binding(2) var bloom_texture: texture_2d<f32>;
@group(0) @binding(3) var tex_sampler: sampler;

struct FragmentInput {
    @location(0) uv: vec2<f32>,
};

fn reinhard(color: vec3<f32>) -> vec3<f32> {
    return color / (color + vec3<f32>(1.0));
}

fn aces(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn uncharted2_tonemap(x: vec3<f32>) -> vec3<f32> {
    let A = 0.15;
    let B = 0.50;
    let C = 0.10;
    let D = 0.20;
    let E = 0.02;
    let F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

@fragment
fn fs_main(in: FragmentInput) -> @location(0) vec4<f32> {
    var hdr_color = textureSample(scene_texture, tex_sampler, in.uv).rgb;
    let bloom = textureSample(bloom_texture, tex_sampler, in.uv).rgb;

    // Add bloom
    hdr_color += bloom * params.bloom_intensity;

    // Tone mapping
    var mapped: vec3<f32>;
    if params.tone_mapping_mode == 0 {
        mapped = reinhard(hdr_color);
    } else if params.tone_mapping_mode == 1 {
        mapped = aces(hdr_color);
    } else {
        let W = 11.2;
        mapped = uncharted2_tonemap(hdr_color * 2.0) / uncharted2_tonemap(vec3<f32>(W));
    }

    // Gamma correction
    mapped = pow(mapped, vec3<f32>(1.0 / params.gamma));

    // Vignette (radial darkening)
    if params.vignette_intensity > 0.0 {
        let center = in.uv - 0.5;
        let dist = length(center);
        let vignette = smoothstep(params.vignette_radius, params.vignette_radius - params.vignette_softness, dist);
        mapped *= mix(1.0, vignette, params.vignette_intensity);
    }

    // Color grading (brightness, contrast, saturation)
    mapped += params.color_brightness;
    mapped = mix(vec3<f32>(0.5), mapped, params.color_contrast);
    let luma = dot(mapped, vec3<f32>(0.2126, 0.7152, 0.0722));
    mapped = mix(vec3<f32>(luma), mapped, params.color_saturation);
    mapped = clamp(mapped, vec3<f32>(0.0), vec3<f32>(1.0));

    return vec4<f32>(mapped, 1.0);
}
