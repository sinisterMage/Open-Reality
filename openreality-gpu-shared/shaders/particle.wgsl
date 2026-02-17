// Particle rendering — billboard quads with soft circular falloff.
// Vertex layout: pos3 + uv2 + color4 (interleaved, 9 floats per vertex).

struct ParticleUniforms {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleUniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
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
    out.clip_position = uniforms.projection * uniforms.view * vec4<f32>(in.position, 1.0);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Soft circular falloff (no texture needed for basic particles)
    let center = in.uv - vec2<f32>(0.5);
    let dist = dot(center, center) * 4.0;  // 0 at center, 1 at edges
    let alpha = 1.0 - smoothstep(0.5, 1.0, dist);

    let color = vec4<f32>(in.color.rgb, in.color.a * alpha);
    if color.a < 0.01 {
        discard;
    }
    return color;
}
