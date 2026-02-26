//! GPU resource type definitions for the deferred rendering pipeline.
//! These types are platform-independent and shared between native (FFI) and WASM backends.

use crate::render_targets;

/// GPU mesh with vertex and index buffers.
pub struct GPUMesh {
    pub vertex_buffer: wgpu::Buffer,
    pub normal_buffer: wgpu::Buffer,
    pub uv_buffer: wgpu::Buffer,
    pub index_buffer: wgpu::Buffer,
    pub index_count: u32,
    // Optional skinning data (bone weights + bone indices per vertex)
    pub bone_weight_buffer: Option<wgpu::Buffer>,
    pub bone_index_buffer: Option<wgpu::Buffer>,
    pub has_skinning: bool,
}

/// GPU texture with associated view and sampler.
pub struct GPUTexture {
    pub texture: wgpu::Texture,
    pub view: wgpu::TextureView,
    pub sampler: wgpu::Sampler,
    pub width: u32,
    pub height: u32,
    pub channels: u32,
}

/// Render target (framebuffer equivalent).
pub struct RenderTarget {
    pub color_texture: wgpu::Texture,
    pub color_view: wgpu::TextureView,
    pub depth_texture: Option<wgpu::Texture>,
    pub depth_view: Option<wgpu::TextureView>,
    pub width: u32,
    pub height: u32,
}

/// G-Buffer with multiple render targets for deferred shading.
pub struct GBuffer {
    /// RGB = albedo, A = metallic
    pub albedo_metallic: wgpu::Texture,
    pub albedo_metallic_view: wgpu::TextureView,
    /// RGB = encoded normal, A = roughness
    pub normal_roughness: wgpu::Texture,
    pub normal_roughness_view: wgpu::TextureView,
    /// RGB = emissive, A = AO
    pub emissive_ao: wgpu::Texture,
    pub emissive_ao_view: wgpu::TextureView,
    /// R = clearcoat, G = subsurface, BA = reserved
    pub advanced: wgpu::Texture,
    pub advanced_view: wgpu::TextureView,
    /// Depth buffer
    pub depth: wgpu::Texture,
    pub depth_view: wgpu::TextureView,
    pub width: u32,
    pub height: u32,
}

/// Cascaded shadow map.
pub struct CascadedShadowMap {
    pub depth_textures: Vec<wgpu::Texture>,
    pub depth_views: Vec<wgpu::TextureView>,
    pub sampler: wgpu::Sampler,
    pub num_cascades: u32,
    pub resolution: u32,
}

/// Post-processing pipeline state.
pub struct PostProcessPipeline {
    pub bloom_extract_pipeline: wgpu::RenderPipeline,
    pub bloom_blur_pipeline: wgpu::RenderPipeline,
    pub bloom_composite_pipeline: wgpu::RenderPipeline,
    pub fxaa_pipeline: Option<wgpu::RenderPipeline>,
    pub bloom_targets: Vec<RenderTarget>,
    pub params_buffer: wgpu::Buffer,
    pub params_bind_group_layout: wgpu::BindGroupLayout,
}

/// SSAO pass state.
pub struct SSAOPass {
    pub pipeline: wgpu::RenderPipeline,
    pub blur_pipeline: wgpu::RenderPipeline,
    pub target: RenderTarget,
    pub blur_target: RenderTarget,
    pub noise_texture: GPUTexture,
    pub params_buffer: wgpu::Buffer,
    pub bind_group_layout: wgpu::BindGroupLayout,
}

/// SSR pass state.
pub struct SSRPass {
    pub pipeline: wgpu::RenderPipeline,
    pub target: RenderTarget,
    pub params_buffer: wgpu::Buffer,
    pub bind_group_layout: wgpu::BindGroupLayout,
}

/// TAA pass state.
pub struct TAAPass {
    pub pipeline: wgpu::RenderPipeline,
    pub history_texture: wgpu::Texture,
    pub history_view: wgpu::TextureView,
    pub target: RenderTarget,
    pub params_buffer: wgpu::Buffer,
    pub bind_group_layout: wgpu::BindGroupLayout,
    pub first_frame: bool,
}

/// The full deferred rendering pipeline — all render pipelines, targets, and shared resources.
pub struct DeferredPipeline {
    // Render pipelines
    pub gbuffer_pipeline: wgpu::RenderPipeline,
    pub lighting_pipeline: wgpu::RenderPipeline,
    pub shadow_pipeline: wgpu::RenderPipeline,
    pub forward_pipeline: wgpu::RenderPipeline,
    pub present_pipeline: wgpu::RenderPipeline,
    pub particle_pipeline: wgpu::RenderPipeline,
    pub ui_pipeline: wgpu::RenderPipeline,
    pub terrain_pipeline: wgpu::RenderPipeline,
    pub gbuffer_skinned_pipeline: wgpu::RenderPipeline,
    pub gbuffer_instanced_pipeline: wgpu::RenderPipeline,

    // Effect pipelines
    pub ssao_pipeline: wgpu::RenderPipeline,
    pub ssao_blur_pipeline: wgpu::RenderPipeline,
    pub ssr_pipeline: wgpu::RenderPipeline,
    pub taa_pipeline: wgpu::RenderPipeline,
    pub bloom_extract_pipeline: wgpu::RenderPipeline,
    pub bloom_blur_pipeline: wgpu::RenderPipeline,
    pub bloom_composite_pipeline: wgpu::RenderPipeline,
    pub fxaa_pipeline: wgpu::RenderPipeline,

    // Render targets
    pub gbuffer: GBuffer,
    pub lighting_target: RenderTarget,
    pub ssao_targets: render_targets::SSAOTargets,
    pub ssr_target: RenderTarget,
    pub taa_targets: render_targets::TAATargets,
    pub bloom_targets: render_targets::BloomTargets,
    pub dof_targets: render_targets::DOFTargets,
    pub mblur_targets: render_targets::MotionBlurTargets,

    // DOF pipelines
    pub dof_coc_pipeline: wgpu::RenderPipeline,
    pub dof_blur_pipeline: wgpu::RenderPipeline,
    pub dof_composite_pipeline: wgpu::RenderPipeline,
    pub dof_coc_bgl: wgpu::BindGroupLayout,
    pub dof_blur_bgl: wgpu::BindGroupLayout,
    pub dof_composite_bgl: wgpu::BindGroupLayout,
    pub dof_coc_params_buffer: wgpu::Buffer,
    pub dof_blur_params_buffer: wgpu::Buffer,

    // Motion blur pipelines
    pub mblur_velocity_pipeline: wgpu::RenderPipeline,
    pub mblur_blur_pipeline: wgpu::RenderPipeline,
    pub mblur_velocity_bgl: wgpu::BindGroupLayout,
    pub mblur_blur_bgl: wgpu::BindGroupLayout,
    pub mblur_velocity_params_buffer: wgpu::Buffer,
    pub mblur_blur_params_buffer: wgpu::Buffer,

    // Post-process intermediate targets (for ping-pong)
    pub pp_target_a: RenderTarget,
    pub pp_target_b: RenderTarget,

    // Default resources
    pub default_texture: wgpu::Texture,
    pub default_texture_view: wgpu::TextureView,
    pub ssao_noise_texture: wgpu::Texture,
    pub ssao_noise_view: wgpu::TextureView,
    pub fullscreen_quad_vbo: wgpu::Buffer,

    // Bind group layouts
    pub lighting_bgl: wgpu::BindGroupLayout,
    pub light_data_bgl: wgpu::BindGroupLayout,
    pub per_object_bgl: wgpu::BindGroupLayout,
    pub particle_bgl: wgpu::BindGroupLayout,
    pub ui_bgl: wgpu::BindGroupLayout,
    pub terrain_bgl: wgpu::BindGroupLayout,
    pub present_bgl: wgpu::BindGroupLayout,
    pub forward_light_shadow_bgl: wgpu::BindGroupLayout,
    pub bone_bgl: wgpu::BindGroupLayout,

    // Effect bind group layouts
    pub ssao_bgl: wgpu::BindGroupLayout,
    pub ssao_blur_bgl: wgpu::BindGroupLayout,
    pub ssr_bgl: wgpu::BindGroupLayout,
    pub taa_bgl: wgpu::BindGroupLayout,
    pub bloom_extract_bgl: wgpu::BindGroupLayout,
    pub bloom_blur_bgl: wgpu::BindGroupLayout,
    pub bloom_composite_bgl: wgpu::BindGroupLayout,
    pub fxaa_bgl: wgpu::BindGroupLayout,

    // Uniform buffers for effects
    pub ssao_params_buffer: wgpu::Buffer,
    pub ssr_params_buffer: wgpu::Buffer,
    pub taa_params_buffer: wgpu::Buffer,
    pub pp_params_buffer: wgpu::Buffer,
    pub shadow_uniform_buffer: wgpu::Buffer,
    pub particle_uniform_buffer: wgpu::Buffer,
    pub ui_uniform_buffer: wgpu::Buffer,
    pub terrain_params_buffer: wgpu::Buffer,
    pub bone_uniform_buffer: wgpu::Buffer,

    // Samplers
    pub depth_sampler: wgpu::Sampler,
    pub shadow_comparison_sampler: wgpu::Sampler,

    // Dynamic vertex buffers for streaming data
    pub particle_vbo: wgpu::Buffer,
    pub particle_vbo_size: u64,
    pub ui_vbo: wgpu::Buffer,
    pub ui_vbo_size: u64,
    pub instance_vbo: wgpu::Buffer,
    pub instance_vbo_size: u64,

    // Debug lines
    pub debug_lines_pipeline: wgpu::RenderPipeline,
    pub debug_lines_bgl: wgpu::BindGroupLayout,
    pub debug_lines_uniform_buffer: wgpu::Buffer,
    pub debug_lines_vbo: wgpu::Buffer,
    pub debug_lines_vbo_size: u64,

    // TAA state
    pub taa_first_frame: bool,
}
