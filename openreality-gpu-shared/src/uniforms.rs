use bytemuck::{Pod, Zeroable};

/// Per-frame uniform data — matches GPU bind group 0, binding 0.
/// Padded to 256-byte alignment for WebGPU requirements.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct PerFrameUniforms {
    pub view: [[f32; 4]; 4],
    pub projection: [[f32; 4]; 4],
    pub inv_view_proj: [[f32; 4]; 4],
    pub camera_pos: [f32; 4],
    pub time: f32,
    pub _pad1: f32,
    pub _pad2: f32,
    pub _pad3: f32,
    /// Padding to 256-byte alignment for WebGPU minUniformBufferOffsetAlignment.
    pub _alignment_pad: [f32; 8],
}

/// Material uniform data — matches GPU bind group 1, binding 0.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct MaterialUniforms {
    pub albedo: [f32; 4],
    pub metallic: f32,
    pub roughness: f32,
    pub ao: f32,
    pub alpha_cutoff: f32,
    pub emissive_factor: [f32; 4],
    pub clearcoat: f32,
    pub clearcoat_roughness: f32,
    pub subsurface: f32,
    pub parallax_scale: f32,
    pub has_albedo_map: i32,
    pub has_normal_map: i32,
    pub has_metallic_roughness_map: i32,
    pub has_ao_map: i32,
    pub has_emissive_map: i32,
    pub has_height_map: i32,
    /// LOD crossfade alpha (stored as f32 bits in i32 for Pod compat; 0x3f800000 = 1.0 = fully visible).
    pub lod_alpha_bits: i32,
    pub _pad2: i32,
}

/// Per-object push data — model matrix + normal matrix columns.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct PerObjectUniforms {
    pub model: [[f32; 4]; 4],
    pub normal_matrix_col0: [f32; 4],
    pub normal_matrix_col1: [f32; 4],
    pub normal_matrix_col2: [f32; 4],
    pub _pad: [f32; 4],
}

/// Point light data.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct PointLightData {
    pub position: [f32; 4],
    pub color: [f32; 4],
    pub intensity: f32,
    pub range: f32,
    pub _pad1: f32,
    pub _pad2: f32,
}

/// Directional light data.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct DirLightData {
    pub direction: [f32; 4],
    pub color: [f32; 4],
    pub intensity: f32,
    pub _pad1: f32,
    pub _pad2: f32,
    pub _pad3: f32,
}

/// Light uniform buffer — matches GPU bind group 1, binding 0 in lighting pass.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct LightUniforms {
    pub point_lights: [PointLightData; 16],
    pub dir_lights: [DirLightData; 4],
    pub num_point_lights: i32,
    pub num_dir_lights: i32,
    pub has_ibl: i32,
    pub ibl_intensity: f32,
}

/// SSAO parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct SSAOParams {
    pub samples: [[f32; 4]; 64],
    pub projection: [[f32; 4]; 4],
    pub kernel_size: i32,
    pub radius: f32,
    pub bias: f32,
    pub power: f32,
    pub screen_width: f32,
    pub screen_height: f32,
    pub _pad1: f32,
    pub _pad2: f32,
}

/// SSR parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct SSRParams {
    pub projection: [[f32; 4]; 4],
    pub view: [[f32; 4]; 4],
    pub inv_projection: [[f32; 4]; 4],
    pub camera_pos: [f32; 4],
    pub screen_size: [f32; 2],
    pub max_steps: i32,
    pub max_distance: f32,
    pub thickness: f32,
    pub _pad1: f32,
    pub _pad2: f32,
    pub _pad3: f32,
}

/// TAA parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct TAAParams {
    pub prev_view_proj: [[f32; 4]; 4],
    pub feedback: f32,
    pub first_frame: i32,
    pub screen_width: f32,
    pub screen_height: f32,
}

/// Post-processing parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct PostProcessParams {
    pub bloom_threshold: f32,
    pub bloom_intensity: f32,
    pub gamma: f32,
    pub tone_mapping_mode: i32,
    pub horizontal: i32,
    pub vignette_intensity: f32,
    pub vignette_radius: f32,
    pub vignette_softness: f32,
    pub color_brightness: f32,
    pub color_contrast: f32,
    pub color_saturation: f32,
    pub _pad1: f32,
}

/// Bone matrix uniforms for skeletal animation.
/// 128 bones * mat4x4 = 8192 bytes + 16-byte header = 8208 bytes.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct BoneUniforms {
    pub has_skinning: i32,
    pub _pad1: i32,
    pub _pad2: i32,
    pub _pad3: i32,
    pub bone_matrices: [[[f32; 4]; 4]; 128],
}

/// Shadow cascade data.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct CascadeData {
    pub light_view_proj: [[f32; 4]; 4],
    pub split_depth: f32,
    pub _pad1: f32,
    pub _pad2: f32,
    pub _pad3: f32,
}

/// Shadow uniform buffer.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct ShadowUniforms {
    pub cascades: [CascadeData; 4],
    pub num_cascades: i32,
    pub shadow_bias: f32,
    pub _pad1: f32,
    pub _pad2: f32,
}

/// DOF Circle of Confusion parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct DOFCoCParams {
    pub focus_distance: f32,
    pub focus_range: f32,
    pub near_plane: f32,
    pub far_plane: f32,
}

/// DOF separable blur parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct DOFBlurParams {
    pub horizontal: i32,
    pub bokeh_radius: f32,
    pub _pad1: f32,
    pub _pad2: f32,
}

/// Motion blur velocity buffer parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct VelocityParams {
    pub inv_view_proj: [[f32; 4]; 4],
    pub prev_view_proj: [[f32; 4]; 4],
    pub max_velocity: f32,
    pub _pad1: f32,
    pub _pad2: f32,
    pub _pad3: f32,
}

/// Motion blur directional blur parameters.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct MotionBlurParams {
    pub samples: i32,
    pub intensity: f32,
    pub _pad1: f32,
    pub _pad2: f32,
}
