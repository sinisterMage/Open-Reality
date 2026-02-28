//! High-level scene renderer that takes uploaded scene data and drives the
//! full deferred PBR pipeline. Used by both native and WASM backends.

use crate::types::*;
use crate::{pipeline, render_targets};
use crate::passes;
use bytemuck::Zeroable;
use openreality_gpu_shared::uniforms::*;
use openreality_gpu_shared::shaders;

/// GPU-uploaded mesh reference.
pub struct UploadedMesh {
    pub gpu_mesh: GPUMesh,
}

/// GPU-uploaded texture reference.
pub struct UploadedTexture {
    pub gpu_texture: GPUTexture,
}

/// Per-entity rendering data (computed per frame).
pub struct EntityRenderData {
    pub mesh_index: Option<usize>,
    pub material_index: Option<usize>,
    pub per_object: PerObjectUniforms,
    pub texture_indices: [i32; 7],
    pub material: MaterialUniforms,
    pub is_transparent: bool,
    pub has_skinning: bool,
}

/// Camera parameters for rendering.
pub struct CameraParams {
    pub view: glam::Mat4,
    pub projection: glam::Mat4,
    pub position: glam::Vec3,
    pub near: f32,
    pub far: f32,
}

/// Light data for the scene.
pub struct SceneLights {
    pub dir_lights: Vec<DirLightData>,
    pub point_lights: Vec<PointLightData>,
}

/// High-level scene renderer — owns all GPU resources for the deferred PBR pipeline.
///
/// This is the main entry point for rendering. Both the native FFI backend and
/// the WASM web runtime create one of these and call `render_frame()` each tick.
pub struct SceneRenderer {
    pub deferred: DeferredPipeline,

    // Shared GPU resources
    pub per_frame_buffer: wgpu::Buffer,
    pub per_frame_bgl: wgpu::BindGroupLayout,
    pub per_object_buffer: wgpu::Buffer,
    pub material_bgl: wgpu::BindGroupLayout,
    pub light_buffer: wgpu::Buffer,
    pub default_sampler: wgpu::Sampler,

    // Uploaded scene resources
    pub meshes: Vec<UploadedMesh>,
    pub textures: Vec<UploadedTexture>,

    // CSM (created on demand)
    pub csm: Option<CascadedShadowMap>,

    // Dimensions
    pub width: u32,
    pub height: u32,
    pub surface_format: wgpu::TextureFormat,
}

impl SceneRenderer {
    /// Create a new scene renderer with all pipelines and render targets.
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        width: u32,
        height: u32,
        surface_format: wgpu::TextureFormat,
    ) -> Result<Self, String> {
        // Per-frame uniform buffer
        let per_frame_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Per-Frame Uniforms"),
            size: std::mem::size_of::<PerFrameUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Per-frame bind group layout (group 0)
        let per_frame_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Per-Frame BGL"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        // Material bind group layout (group 1)
        let material_bgl = pipeline::create_material_bind_group_layout(device);

        // Per-object uniform buffer
        let per_object_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Per-Object Uniforms"),
            size: std::mem::size_of::<PerObjectUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Light buffer
        let light_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Light Uniforms"),
            size: std::mem::size_of::<LightUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Default sampler
        let default_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Default Sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::Repeat,
            ..Default::default()
        });

        // Create the full deferred pipeline
        let deferred = Self::create_deferred_pipeline_inner(
            device, queue, width, height, surface_format,
            &per_frame_bgl, &material_bgl,
        )?;

        Ok(Self {
            deferred,
            per_frame_buffer,
            per_frame_bgl,
            per_object_buffer,
            material_bgl,
            light_buffer,
            default_sampler,
            meshes: Vec::new(),
            textures: Vec::new(),
            csm: None,
            width,
            height,
            surface_format,
        })
    }

    /// Upload a mesh to the GPU.
    pub fn upload_mesh(
        &mut self,
        device: &wgpu::Device,
        positions: &[f32],
        normals: &[f32],
        uvs: &[f32],
        indices: &[u32],
        bone_weights: Option<&[f32]>,
        bone_indices: Option<&[u16]>,
    ) -> usize {
        use wgpu::util::DeviceExt;

        let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Mesh Positions"),
            contents: bytemuck::cast_slice(positions),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let normal_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Mesh Normals"),
            contents: bytemuck::cast_slice(normals),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let uv_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Mesh UVs"),
            contents: bytemuck::cast_slice(uvs),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Mesh Indices"),
            contents: bytemuck::cast_slice(indices),
            usage: wgpu::BufferUsages::INDEX,
        });

        let bone_weight_buffer = bone_weights.map(|bw| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("Bone Weights"),
                contents: bytemuck::cast_slice(bw),
                usage: wgpu::BufferUsages::VERTEX,
            })
        });
        let bone_index_buffer = bone_indices.map(|bi| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("Bone Indices"),
                contents: bytemuck::cast_slice(bi),
                usage: wgpu::BufferUsages::VERTEX,
            })
        });

        let has_skinning = bone_weights.is_some() && bone_indices.is_some();
        let idx = self.meshes.len();
        self.meshes.push(UploadedMesh {
            gpu_mesh: GPUMesh {
                vertex_buffer,
                normal_buffer,
                uv_buffer,
                index_buffer,
                index_count: indices.len() as u32,
                bone_weight_buffer,
                bone_index_buffer,
                has_skinning,
            },
        });
        idx
    }

    /// Upload a texture to the GPU (decodes PNG if needed).
    pub fn upload_texture(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        width: u32,
        height: u32,
        channels: u32,
        data: &[u8],
        is_compressed_png: bool,
    ) -> usize {
        let rgba_data = if is_compressed_png {
            // Decode PNG
            match image::load_from_memory(data) {
                Ok(img) => img.to_rgba8().into_raw(),
                Err(e) => {
                    log::warn!("Failed to decode texture PNG: {}", e);
                    vec![255u8; (width * height * 4) as usize]
                }
            }
        } else if channels == 3 {
            // Convert RGB to RGBA
            let mut rgba = Vec::with_capacity((width * height * 4) as usize);
            for chunk in data.chunks(3) {
                rgba.extend_from_slice(chunk);
                rgba.push(255);
            }
            rgba
        } else {
            data.to_vec()
        };

        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Scene Texture"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        queue.write_texture(
            wgpu::ImageCopyTexture {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &rgba_data,
            wgpu::ImageDataLayout {
                offset: 0,
                bytes_per_row: Some(4 * width),
                rows_per_image: Some(height),
            },
            wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        );

        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Texture Sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Linear,
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::Repeat,
            ..Default::default()
        });

        let idx = self.textures.len();
        self.textures.push(UploadedTexture {
            gpu_texture: GPUTexture {
                texture,
                view,
                sampler,
                width,
                height,
                channels: 4,
            },
        });
        idx
    }

    /// Create cascaded shadow maps.
    pub fn create_csm(&mut self, device: &wgpu::Device, num_cascades: u32, resolution: u32) {
        let mut depth_textures = Vec::new();
        let mut depth_views = Vec::new();

        for i in 0..num_cascades {
            let tex = device.create_texture(&wgpu::TextureDescriptor {
                label: Some(&format!("CSM Cascade {}", i)),
                size: wgpu::Extent3d {
                    width: resolution,
                    height: resolution,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            let view = tex.create_view(&wgpu::TextureViewDescriptor::default());
            depth_textures.push(tex);
            depth_views.push(view);
        }

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("CSM Sampler"),
            compare: Some(wgpu::CompareFunction::LessEqual),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        self.csm = Some(CascadedShadowMap {
            depth_textures,
            depth_views,
            sampler,
            num_cascades,
            resolution,
        });
    }

    /// Render a full frame using the deferred PBR pipeline.
    ///
    /// This drives the complete pass sequence:
    /// 1. Shadow pass (CSM)
    /// 2. G-Buffer pass (opaque geometry)
    /// 3. Lighting pass (deferred)
    /// 4. SSAO
    /// 5. SSR
    /// 6. TAA
    /// 7. Bloom (extract → blur → composite)
    /// 8. FXAA
    /// 9. Forward pass (transparent geometry)
    /// 10. Present (tone map to swapchain)
    pub fn render_frame(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        surface_view: &wgpu::TextureView,
        camera: &CameraParams,
        lights: &SceneLights,
        entities: &[EntityRenderData],
        time: f32,
    ) {
        let dp = &self.deferred;

        // Update per-frame uniforms
        let inv_view_proj = (camera.projection * camera.view).inverse();
        let per_frame = PerFrameUniforms {
            view: camera.view.to_cols_array_2d(),
            projection: camera.projection.to_cols_array_2d(),
            inv_view_proj: inv_view_proj.to_cols_array_2d(),
            camera_pos: [camera.position.x, camera.position.y, camera.position.z, 1.0],
            time,
            _pad1: 0.0,
            _pad2: 0.0,
            _pad3: 0.0,
            _alignment_pad: [0.0; 8],
        };
        queue.write_buffer(&self.per_frame_buffer, 0, bytemuck::bytes_of(&per_frame));

        // Update light uniforms
        let mut light_uniforms = LightUniforms::zeroed();
        for (i, dl) in lights.dir_lights.iter().enumerate().take(4) {
            light_uniforms.dir_lights[i] = *dl;
        }
        light_uniforms.num_dir_lights = lights.dir_lights.len().min(4) as i32;
        for (i, pl) in lights.point_lights.iter().enumerate().take(16) {
            light_uniforms.point_lights[i] = *pl;
        }
        light_uniforms.num_point_lights = lights.point_lights.len().min(16) as i32;
        queue.write_buffer(&self.light_buffer, 0, bytemuck::bytes_of(&light_uniforms));

        // Create per-frame bind group
        let per_frame_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Per-Frame BG"),
            layout: &self.per_frame_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: self.per_frame_buffer.as_entire_binding(),
            }],
        });

        // Separate opaque and transparent entities
        let opaque: Vec<_> = entities.iter().filter(|e| !e.is_transparent && e.mesh_index.is_some()).collect();
        let transparent: Vec<_> = entities.iter().filter(|e| e.is_transparent && e.mesh_index.is_some()).collect();

        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Scene Render Encoder"),
        });

        // --- 1. Shadow pass ---
        if let Some(ref csm) = self.csm {
            for cascade_idx in 0..csm.num_cascades as usize {
                if cascade_idx < csm.depth_views.len() {
                    let shadow_meshes: Vec<_> = opaque.iter().map(|e| {
                        let mi = e.mesh_index.unwrap();
                        (0u64, &self.meshes[mi].gpu_mesh, e.per_object.model)
                    }).collect();

                    passes::shadow::render_shadow_cascade(
                        &mut encoder,
                        csm,
                        cascade_idx,
                        &dp.shadow_pipeline,
                        &per_frame_bg,
                        &dp.per_object_bgl,
                        device,
                        queue,
                        &self.per_object_buffer,
                        &shadow_meshes,
                    );
                }
            }
        }

        // --- 2. G-Buffer pass ---
        let gbuffer_entities: Vec<passes::gbuffer::GBufferEntity> = opaque.iter().filter(|e| !e.has_skinning).map(|e| {
            let mi = e.mesh_index.unwrap();
            let mesh = &self.meshes[mi].gpu_mesh;
            let tex_views: Vec<Option<&wgpu::TextureView>> = e.texture_indices.iter().map(|&ti| {
                if ti >= 0 && (ti as usize) < self.textures.len() {
                    Some(&self.textures[ti as usize].gpu_texture.view)
                } else {
                    None
                }
            }).collect();
            passes::gbuffer::GBufferEntity {
                mesh,
                per_object: e.per_object,
                material: e.material,
                texture_views: [
                    tex_views.get(0).copied().flatten(),
                    tex_views.get(1).copied().flatten(),
                    tex_views.get(2).copied().flatten(),
                    tex_views.get(3).copied().flatten(),
                    tex_views.get(4).copied().flatten(),
                    tex_views.get(5).copied().flatten(),
                ],
            }
        }).collect();

        passes::gbuffer::render_gbuffer_pass(
            &mut encoder,
            &dp.gbuffer,
            &dp.gbuffer_pipeline,
            &per_frame_bg,
            &dp.per_object_bgl,
            &self.material_bgl,
            device,
            queue,
            &self.per_object_buffer,
            &gbuffer_entities,
            &dp.default_texture_view,
            &self.default_sampler,
        );

        // --- 3. Lighting pass ---
        let lighting_bg = passes::lighting::create_lighting_bind_group(
            device,
            &dp.lighting_bgl,
            &self.per_frame_buffer,
            &dp.gbuffer,
            &dp.ssao_targets.blur.color_view,
            &dp.ssr_target.color_view,
            &self.default_sampler,
            &dp.depth_sampler,
        );
        let light_data_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Light Data BG"),
            layout: &dp.light_data_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: self.light_buffer.as_entire_binding(),
            }],
        });

        passes::lighting::render_lighting_pass(
            &mut encoder,
            &dp.lighting_target,
            &dp.lighting_pipeline,
            &lighting_bg,
            &light_data_bg,
        );

        // --- 4. SSAO ---
        let ssao_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("SSAO BG"),
            layout: &dp.ssao_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.ssao_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.gbuffer.depth_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dp.gbuffer.normal_roughness_view) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&dp.ssao_noise_view) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::Sampler(&dp.depth_sampler) },
            ],
        });
        passes::ssao::render_ssao_pass(&mut encoder, &dp.ssao_targets.ao, &dp.ssao_pipeline, &ssao_bg);

        // SSAO blur
        let ssao_blur_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("SSAO Blur BG"),
            layout: &dp.ssao_blur_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.ssao_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.ssao_targets.ao.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
            ],
        });
        passes::ssao::render_ssao_blur(&mut encoder, &dp.ssao_targets.blur, &dp.ssao_blur_pipeline, &ssao_blur_bg);

        // --- 5. Bloom (extract → blur H → blur V → composite) ---
        let bloom_extract_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Extract BG"),
            layout: &dp.bloom_extract_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.lighting_target.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_extract(&mut encoder, &dp.bloom_targets.extract, &dp.bloom_extract_pipeline, &bloom_extract_bg);

        let bloom_blur_h_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Blur H BG"),
            layout: &dp.bloom_blur_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.bloom_targets.extract.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_blur(&mut encoder, &dp.bloom_targets.blur_h, &dp.bloom_blur_pipeline, &bloom_blur_h_bg, "Bloom Blur H");

        let bloom_blur_v_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Blur V BG"),
            layout: &dp.bloom_blur_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.bloom_targets.blur_h.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_blur(&mut encoder, &dp.bloom_targets.blur_v, &dp.bloom_blur_pipeline, &bloom_blur_v_bg, "Bloom Blur V");

        let bloom_composite_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Composite BG"),
            layout: &dp.bloom_composite_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.lighting_target.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dp.bloom_targets.blur_v.color_view) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_composite(&mut encoder, &dp.pp_target_a, &dp.bloom_composite_pipeline, &bloom_composite_bg);

        // --- 6. FXAA ---
        let fxaa_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("FXAA BG"),
            layout: &dp.fxaa_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&dp.pp_target_a.color_view) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
            ],
        });
        passes::postprocess::render_fxaa(&mut encoder, &dp.pp_target_b, &dp.fxaa_pipeline, &fxaa_bg);

        // --- 7. Present (tone map to swapchain) ---
        let present_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Present BG"),
            layout: &dp.present_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.pp_target_b.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.default_sampler) },
            ],
        });
        passes::present::render_present_pass(&mut encoder, surface_view, &dp.present_pipeline, &present_bg);

        queue.submit(std::iter::once(encoder.finish()));
    }

    /// Resize all render targets (called on window/canvas resize).
    pub fn resize(&mut self, device: &wgpu::Device, width: u32, height: u32) {
        self.width = width;
        self.height = height;

        let dp = &mut self.deferred;
        dp.gbuffer = render_targets::create_gbuffer(device, width, height);
        dp.lighting_target = render_targets::create_hdr_target(device, width, height, "Lighting Target", true);
        dp.ssao_targets = render_targets::create_ssao_targets(device, width, height);
        dp.ssr_target = render_targets::create_ssr_target(device, width, height);
        dp.taa_targets = render_targets::create_taa_targets(device, width, height);
        dp.bloom_targets = render_targets::create_bloom_targets(device, width, height);
        dp.pp_target_a = render_targets::create_hdr_target(device, width, height, "PP Target A", false);
        dp.pp_target_b = render_targets::create_hdr_target(device, width, height, "PP Target B", false);
        dp.dof_targets = render_targets::create_dof_targets(device, width, height);
        dp.mblur_targets = render_targets::create_motion_blur_targets(device, width, height);
        dp.taa_first_frame = true;

        log::info!("SceneRenderer resized to {}x{}", width, height);
    }

    /// Internal: create the full deferred pipeline.
    fn create_deferred_pipeline_inner(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        w: u32,
        h: u32,
        surface_format: wgpu::TextureFormat,
        per_frame_bgl: &wgpu::BindGroupLayout,
        material_bgl: &wgpu::BindGroupLayout,
    ) -> Result<DeferredPipeline, String> {
        // Per-object bind group layout
        let per_object_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Per-Object BGL"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        // Bind group layouts
        let lighting_bgl = pipeline::create_lighting_bind_group_layout(device);
        let light_data_bgl = pipeline::create_light_data_bind_group_layout(device);
        let particle_bgl = pipeline::create_particle_bgl(device);
        let ui_bgl = pipeline::create_ui_bgl(device);
        let terrain_bgl = pipeline::create_terrain_bgl(device);
        let present_bgl = pipeline::create_present_bgl(device);
        let forward_light_shadow_bgl = pipeline::create_forward_light_shadow_bgl(device);
        let bone_bgl = pipeline::create_bone_bgl(device);

        // Effect BGLs
        let ssao_bgl = pipeline::create_ssao_bind_group_layout(device);
        let ssao_blur_bgl = pipeline::create_effect_bind_group_layout(device, "SSAO Blur BGL", 1, false);
        let ssr_bgl = pipeline::create_ssr_bind_group_layout(device);
        let taa_bgl = pipeline::create_taa_bind_group_layout(device);
        let bloom_extract_bgl = pipeline::create_effect_bind_group_layout(device, "Bloom Extract BGL", 1, false);
        let bloom_blur_bgl = pipeline::create_effect_bind_group_layout(device, "Bloom Blur BGL", 1, false);
        let bloom_composite_bgl = pipeline::create_effect_bind_group_layout(device, "Bloom Composite BGL", 2, false);
        let fxaa_bgl = pipeline::create_fxaa_bind_group_layout(device);

        // Render pipelines
        let gbuffer_pipeline = pipeline::create_gbuffer_pipeline(device, per_frame_bgl, material_bgl, &per_object_bgl);
        let shadow_pipeline = pipeline::create_shadow_pipeline(device, per_frame_bgl, &per_object_bgl);
        let lighting_pipeline = pipeline::create_lighting_pipeline(device, &lighting_bgl, &light_data_bgl);
        let forward_pipeline = pipeline::create_forward_pipeline(device, per_frame_bgl, material_bgl, &per_object_bgl, &forward_light_shadow_bgl);
        let present_pipeline = pipeline::create_present_pipeline(device, &present_bgl, surface_format);
        let particle_pipeline = pipeline::create_particle_pipeline(device, &particle_bgl, surface_format);
        let ui_pipeline = pipeline::create_ui_pipeline(device, &ui_bgl, surface_format);
        let terrain_pipeline = pipeline::create_terrain_pipeline(device, per_frame_bgl, &terrain_bgl);
        let gbuffer_skinned_pipeline = pipeline::create_gbuffer_skinned_pipeline(device, per_frame_bgl, material_bgl, &per_object_bgl, &bone_bgl);
        let gbuffer_instanced_pipeline = pipeline::create_gbuffer_instanced_pipeline(device, per_frame_bgl, material_bgl);

        // Effect pipelines
        let ssao_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "SSAO Pipeline", shaders::SSAO_FRAG, "fs_main", &ssao_bgl, render_targets::R16_FORMAT);
        let ssao_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "SSAO Blur Pipeline", shaders::SSAO_BLUR_FRAG, "fs_main", &ssao_blur_bgl, render_targets::R16_FORMAT);
        let ssr_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "SSR Pipeline", shaders::SSR_FRAG, "fs_main", &ssr_bgl, render_targets::HDR_FORMAT);
        let taa_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "TAA Pipeline", shaders::TAA_FRAG, "fs_main", &taa_bgl, render_targets::HDR_FORMAT);
        let bloom_extract_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "Bloom Extract", shaders::BLOOM_EXTRACT_FRAG, "fs_main", &bloom_extract_bgl, render_targets::HDR_FORMAT);
        let bloom_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "Bloom Blur", shaders::BLOOM_BLUR_FRAG, "fs_main", &bloom_blur_bgl, render_targets::HDR_FORMAT);
        let bloom_composite_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "Bloom Composite", shaders::BLOOM_COMPOSITE_FRAG, "fs_main", &bloom_composite_bgl, render_targets::HDR_FORMAT);
        let fxaa_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "FXAA", shaders::FXAA_FRAG, "fs_main", &fxaa_bgl, render_targets::HDR_FORMAT);

        // DOF
        let dof_coc_bgl = pipeline::create_dof_coc_bgl(device);
        let dof_blur_bgl = pipeline::create_dof_blur_bgl(device);
        let dof_composite_bgl = pipeline::create_dof_composite_bgl(device);
        let dof_coc_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "DOF CoC", shaders::DOF_SHADER, "fs_coc", &dof_coc_bgl, render_targets::R16_FORMAT);
        let dof_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "DOF Blur", shaders::DOF_SHADER, "fs_blur", &dof_blur_bgl, render_targets::HDR_FORMAT);
        let dof_composite_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "DOF Composite", shaders::DOF_SHADER, "fs_composite", &dof_composite_bgl, render_targets::HDR_FORMAT);

        // Motion blur
        let mblur_velocity_bgl = pipeline::create_mblur_velocity_bgl(device);
        let mblur_blur_bgl = pipeline::create_mblur_blur_bgl(device);
        let mblur_velocity_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "MBlur Velocity", shaders::MOTION_BLUR_SHADER, "fs_velocity", &mblur_velocity_bgl, render_targets::RG16_FORMAT);
        let mblur_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(device, "MBlur Blur", shaders::MOTION_BLUR_SHADER, "fs_blur", &mblur_blur_bgl, render_targets::HDR_FORMAT);

        // Render targets
        let gbuffer = render_targets::create_gbuffer(device, w, h);
        let lighting_target = render_targets::create_hdr_target(device, w, h, "Lighting Target", true);
        let ssao_targets = render_targets::create_ssao_targets(device, w, h);
        let ssr_target = render_targets::create_ssr_target(device, w, h);
        let taa_targets = render_targets::create_taa_targets(device, w, h);
        let bloom_targets = render_targets::create_bloom_targets(device, w, h);
        let pp_target_a = render_targets::create_hdr_target(device, w, h, "PP Target A", false);
        let pp_target_b = render_targets::create_hdr_target(device, w, h, "PP Target B", false);
        let dof_targets = render_targets::create_dof_targets(device, w, h);
        let mblur_targets = render_targets::create_motion_blur_targets(device, w, h);

        // Default resources
        let (default_texture, default_texture_view) = render_targets::create_default_texture(device, queue);
        let (ssao_noise_texture, ssao_noise_view) = render_targets::create_ssao_noise_texture(device, queue);
        let fullscreen_quad_vbo = render_targets::create_fullscreen_quad_vbo(device);

        // Samplers
        let depth_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Depth Sampler"),
            mag_filter: wgpu::FilterMode::Nearest,
            min_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });
        let shadow_comparison_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Shadow Comparison Sampler"),
            compare: Some(wgpu::CompareFunction::LessEqual),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        // Uniform buffers
        let ssao_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("SSAO Params"), size: std::mem::size_of::<SSAOParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let ssr_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("SSR Params"), size: std::mem::size_of::<SSRParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let taa_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("TAA Params"), size: std::mem::size_of::<TAAParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let pp_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("PostProcess Params"), size: std::mem::size_of::<PostProcessParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let shadow_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Shadow Uniforms"), size: std::mem::size_of::<ShadowUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let particle_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Particle Uniforms"), size: 128,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let ui_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("UI Uniforms"), size: 80,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let terrain_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Terrain Params"), size: 32,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let bone_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Bone Uniforms"), size: std::mem::size_of::<BoneUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let dof_coc_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("DOF CoC Params"), size: std::mem::size_of::<DOFCoCParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let dof_blur_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("DOF Blur Params"), size: std::mem::size_of::<DOFBlurParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let mblur_velocity_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("MBlur Velocity Params"), size: std::mem::size_of::<VelocityParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let mblur_blur_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("MBlur Blur Params"), size: std::mem::size_of::<MotionBlurParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });

        // Dynamic vertex buffers
        let particle_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Particle VBO"), size: 1024 * 9 * 4,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let ui_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("UI VBO"), size: 4096 * 8 * 4,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let instance_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Instance VBO"), size: 256 * pipeline::INSTANCE_STRIDE,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });

        // Debug lines
        let debug_lines_bgl = pipeline::create_debug_lines_bgl(device);
        let debug_lines_pipeline = pipeline::create_debug_lines_pipeline(device, &debug_lines_bgl, surface_format);
        let debug_lines_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Debug Lines Uniform"), size: 64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });
        let debug_lines_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Debug Lines VBO"), size: 1024 * 24,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false,
        });

        Ok(DeferredPipeline {
            gbuffer_pipeline,
            lighting_pipeline,
            shadow_pipeline,
            forward_pipeline,
            present_pipeline,
            particle_pipeline,
            ui_pipeline,
            terrain_pipeline,
            gbuffer_skinned_pipeline,
            gbuffer_instanced_pipeline,
            ssao_pipeline,
            ssao_blur_pipeline,
            ssr_pipeline,
            taa_pipeline,
            bloom_extract_pipeline,
            bloom_blur_pipeline,
            bloom_composite_pipeline,
            fxaa_pipeline,
            gbuffer,
            lighting_target,
            ssao_targets,
            ssr_target,
            taa_targets,
            bloom_targets,
            dof_targets,
            mblur_targets,
            dof_coc_pipeline,
            dof_blur_pipeline,
            dof_composite_pipeline,
            dof_coc_bgl,
            dof_blur_bgl,
            dof_composite_bgl,
            dof_coc_params_buffer,
            dof_blur_params_buffer,
            mblur_velocity_pipeline,
            mblur_blur_pipeline,
            mblur_velocity_bgl,
            mblur_blur_bgl,
            mblur_velocity_params_buffer,
            mblur_blur_params_buffer,
            pp_target_a,
            pp_target_b,
            default_texture,
            default_texture_view,
            ssao_noise_texture,
            ssao_noise_view,
            fullscreen_quad_vbo,
            lighting_bgl,
            light_data_bgl,
            per_object_bgl,
            particle_bgl,
            ui_bgl,
            terrain_bgl,
            present_bgl,
            forward_light_shadow_bgl,
            bone_bgl,
            ssao_bgl,
            ssao_blur_bgl,
            ssr_bgl,
            taa_bgl,
            bloom_extract_bgl,
            bloom_blur_bgl,
            bloom_composite_bgl,
            fxaa_bgl,
            ssao_params_buffer,
            ssr_params_buffer,
            taa_params_buffer,
            pp_params_buffer,
            shadow_uniform_buffer,
            particle_uniform_buffer,
            ui_uniform_buffer,
            terrain_params_buffer,
            bone_uniform_buffer,
            depth_sampler,
            shadow_comparison_sampler,
            particle_vbo,
            particle_vbo_size: 1024 * 9 * 4,
            ui_vbo,
            ui_vbo_size: 4096 * 8 * 4,
            instance_vbo,
            instance_vbo_size: 256 * pipeline::INSTANCE_STRIDE,
            debug_lines_pipeline,
            debug_lines_bgl,
            debug_lines_uniform_buffer,
            debug_lines_vbo,
            debug_lines_vbo_size: 1024 * 24,
            taa_first_frame: true,
        })
    }
}
