// UI rendering — 2D overlay with font atlas, texture, and solid color support.
// Vertex layout: pos2 + uv2 + color4 (interleaved, 8 floats per vertex).
// Uses orthographic projection (top-left origin).

struct UIUniforms {
    projection: mat4x4<f32>,
    has_texture: i32,
    is_font: i32,
    _pad1: i32,
    _pad2: i32,
};

@group(0) @binding(0) var<uniform> uniforms: UIUniforms;
@group(0) @binding(1) var ui_texture: texture_2d<f32>;
@group(0) @binding(2) var ui_sampler: sampler;

struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.uv = in.uv;
    out.color = in.color;
    out.clip_position = uniforms.projection * vec4<f32>(in.position, 0.0, 1.0);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    if uniforms.has_texture == 1 {
        if uniforms.is_font == 1 {
            // Font atlas: single channel (red), use as alpha
            let alpha = textureSample(ui_texture, ui_sampler, in.uv).r;
            return vec4<f32>(in.color.rgb, in.color.a * alpha);
        } else {
            // Regular texture
            let tex_color = textureSample(ui_texture, ui_sampler, in.uv);
            return tex_color * in.color;
        }
    } else {
        // Solid color
        return in.color;
    }
}
