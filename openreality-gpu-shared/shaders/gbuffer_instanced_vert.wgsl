// G-Buffer geometry pass — instanced vertex shader.
// Reads per-instance model + normal matrices from vertex attributes (step_mode=Instance).

struct PerFrame {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    camera_pos: vec4<f32>,
    time: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};

@group(0) @binding(0) var<uniform> frame: PerFrame;

struct VertexInput {
    // Per-vertex data
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    // Per-instance data (model matrix as 4 column vectors)
    @location(3) model_col0: vec4<f32>,
    @location(4) model_col1: vec4<f32>,
    @location(5) model_col2: vec4<f32>,
    @location(6) model_col3: vec4<f32>,
    // Per-instance normal matrix (3 column vectors, padded to vec4)
    @location(7) normal_col0: vec4<f32>,
    @location(8) normal_col1: vec4<f32>,
    @location(9) normal_col2: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) camera_pos: vec3<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    let model = mat4x4<f32>(
        in.model_col0,
        in.model_col1,
        in.model_col2,
        in.model_col3,
    );

    let world_pos = model * vec4<f32>(in.position, 1.0);
    out.world_pos = world_pos.xyz;

    let normal_matrix = mat3x3<f32>(
        in.normal_col0.xyz,
        in.normal_col1.xyz,
        in.normal_col2.xyz,
    );
    out.normal = normalize(normal_matrix * in.normal);
    out.uv = in.uv;
    out.camera_pos = frame.camera_pos.xyz;
    out.clip_position = frame.projection * frame.view * world_pos;

    return out;
}
