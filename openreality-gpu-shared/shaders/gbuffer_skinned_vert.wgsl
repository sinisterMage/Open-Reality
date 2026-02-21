// G-Buffer geometry pass — skinned vertex shader (skeletal animation).

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

struct PerObject {
    model: mat4x4<f32>,
    normal_matrix_col0: vec4<f32>,
    normal_matrix_col1: vec4<f32>,
    normal_matrix_col2: vec4<f32>,
    _pad: vec4<f32>,
};

struct BoneData {
    has_skinning: i32,
    _pad1: i32,
    _pad2: i32,
    _pad3: i32,
    bone_matrices: array<mat4x4<f32>, 128>,
};

@group(0) @binding(0) var<uniform> frame: PerFrame;
@group(2) @binding(0) var<uniform> object: PerObject;
@group(3) @binding(0) var<uniform> bones: BoneData;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) bone_weights: vec4<f32>,
    @location(4) bone_indices: vec4<u32>,
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

    var skinned_pos = vec4<f32>(in.position, 1.0);
    var skinned_normal = vec4<f32>(in.normal, 0.0);

    if bones.has_skinning != 0 {
        let m0 = bones.bone_matrices[in.bone_indices.x];
        let m1 = bones.bone_matrices[in.bone_indices.y];
        let m2 = bones.bone_matrices[in.bone_indices.z];
        let m3 = bones.bone_matrices[in.bone_indices.w];

        let w0 = in.bone_weights.x;
        let w1 = in.bone_weights.y;
        let w2 = in.bone_weights.z;
        let w3 = in.bone_weights.w;

        skinned_pos = m0 * vec4<f32>(in.position, 1.0) * w0
                    + m1 * vec4<f32>(in.position, 1.0) * w1
                    + m2 * vec4<f32>(in.position, 1.0) * w2
                    + m3 * vec4<f32>(in.position, 1.0) * w3;

        skinned_normal = m0 * vec4<f32>(in.normal, 0.0) * w0
                       + m1 * vec4<f32>(in.normal, 0.0) * w1
                       + m2 * vec4<f32>(in.normal, 0.0) * w2
                       + m3 * vec4<f32>(in.normal, 0.0) * w3;
    }

    let world_pos = object.model * skinned_pos;
    out.world_pos = world_pos.xyz;

    let normal_matrix = mat3x3<f32>(
        object.normal_matrix_col0.xyz,
        object.normal_matrix_col1.xyz,
        object.normal_matrix_col2.xyz,
    );
    out.normal = normalize(normal_matrix * skinned_normal.xyz);
    out.uv = in.uv;
    out.camera_pos = frame.camera_pos.xyz;
    out.clip_position = frame.projection * frame.view * world_pos;

    return out;
}
