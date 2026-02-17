// Depth of Field — CoC-based with separable bokeh blur.
// Three passes: CoC computation, separable blur, composite.
// Uses fullscreen_quad.wgsl vertex shader (vertex index-based full-screen triangle).

// ---- Pass 1: Circle of Confusion ----

struct DOFCoCParams {
    focus_distance: f32,
    focus_range: f32,
    near_plane: f32,
    far_plane: f32,
};

@group(0) @binding(0) var<uniform> coc_params: DOFCoCParams;
@group(0) @binding(1) var depth_texture: texture_depth_2d;
@group(0) @binding(2) var depth_sampler: sampler;

struct FragmentInput {
    @location(0) uv: vec2<f32>,
};

fn linearize_depth(d: f32, near: f32, far: f32) -> f32 {
    let z = d * 2.0 - 1.0;
    return (2.0 * near * far) / (far + near - z * (far - near));
}

@fragment
fn fs_coc(in: FragmentInput) -> @location(0) f32 {
    let depth = textureSample(depth_texture, depth_sampler, in.uv);
    let linear_depth = linearize_depth(depth, coc_params.near_plane, coc_params.far_plane);

    // CoC: distance from focus plane, normalized by focus range
    return clamp(abs(linear_depth - coc_params.focus_distance) / coc_params.focus_range, 0.0, 1.0);
}

// ---- Pass 2: Separable Blur (run twice: horizontal then vertical) ----

struct DOFBlurParams {
    horizontal: i32,
    bokeh_radius: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var<uniform> blur_params: DOFBlurParams;
@group(0) @binding(1) var scene_texture: texture_2d<f32>;
@group(0) @binding(2) var coc_texture: texture_2d<f32>;
@group(0) @binding(3) var blur_sampler: sampler;

// 9-tap Gaussian kernel
const WEIGHTS: array<f32, 9> = array<f32, 9>(
    0.0625, 0.09375, 0.125, 0.15625, 0.15625, 0.15625, 0.125, 0.09375, 0.0625
);

@fragment
fn fs_blur(in: FragmentInput) -> @location(0) vec4<f32> {
    let tex_size = vec2<f32>(textureDimensions(scene_texture));
    let texel_size = 1.0 / tex_size;
    let center_coc = textureSample(coc_texture, blur_sampler, in.uv).r;

    var result = vec3<f32>(0.0);
    var total_weight = 0.0;

    for (var i = -4; i <= 4; i++) {
        var offset: vec2<f32>;
        if blur_params.horizontal == 1 {
            offset = vec2<f32>(texel_size.x * f32(i) * blur_params.bokeh_radius, 0.0);
        } else {
            offset = vec2<f32>(0.0, texel_size.y * f32(i) * blur_params.bokeh_radius);
        }

        let sample_uv = in.uv + offset;
        let sample_coc = textureSample(coc_texture, blur_sampler, sample_uv).r;

        // Weight by max of center and sample CoC to prevent sharp objects bleeding into blur
        let w = WEIGHTS[i + 4] * max(center_coc, sample_coc);
        result += textureSample(scene_texture, blur_sampler, sample_uv).rgb * w;
        total_weight += w;
    }

    if total_weight > 0.0 {
        result /= total_weight;
    } else {
        result = textureSample(scene_texture, blur_sampler, in.uv).rgb;
    }

    return vec4<f32>(result, 1.0);
}

// ---- Pass 3: Composite ----

@group(0) @binding(0) var sharp_texture: texture_2d<f32>;
@group(0) @binding(1) var blurred_texture: texture_2d<f32>;
@group(0) @binding(2) var composite_coc_texture: texture_2d<f32>;
@group(0) @binding(3) var composite_sampler: sampler;

@fragment
fn fs_composite(in: FragmentInput) -> @location(0) vec4<f32> {
    let sharp = textureSample(sharp_texture, composite_sampler, in.uv).rgb;
    let blurred = textureSample(blurred_texture, composite_sampler, in.uv).rgb;
    let coc = textureSample(composite_coc_texture, composite_sampler, in.uv).r;

    // Smooth blend between sharp and blurred based on CoC
    let color = mix(sharp, blurred, smoothstep(0.0, 1.0, coc));
    return vec4<f32>(color, 1.0);
}
