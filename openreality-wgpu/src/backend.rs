// Re-export types from the shared render crate.
pub use openreality_render::types::*;
pub use openreality_render::handle::HandleStore;
pub use openreality_render::render_targets;

/// Main backend state — owns all wgpu resources.
pub struct WGPUBackendState {
    pub instance: wgpu::Instance,
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub surface: wgpu::Surface<'static>,
    pub surface_config: wgpu::SurfaceConfiguration,
    pub width: u32,
    pub height: u32,

    // Resource stores (Julia holds opaque u64 handles into these)
    pub meshes: HandleStore<GPUMesh>,
    pub textures: HandleStore<GPUTexture>,
    pub framebuffers: HandleStore<RenderTarget>,

    // Deferred pipeline resources
    pub gbuffer: Option<GBuffer>,
    pub lighting_target: Option<RenderTarget>,
    pub csm: Option<CascadedShadowMap>,

    // Screen-space effects
    pub ssao: Option<SSAOPass>,
    pub ssr: Option<SSRPass>,
    pub taa: Option<TAAPass>,
    pub post_process: Option<PostProcessPipeline>,

    // Shared GPU resources
    pub per_frame_buffer: wgpu::Buffer,
    pub per_frame_bind_group_layout: wgpu::BindGroupLayout,
    pub per_object_buffer: wgpu::Buffer,
    pub material_bind_group_layout: wgpu::BindGroupLayout,
    pub light_buffer: wgpu::Buffer,
    pub default_sampler: wgpu::Sampler,

    // Deferred rendering pipeline (created on demand)
    pub deferred: Option<DeferredPipeline>,

    // Error state
    pub last_error: Option<String>,
}

impl WGPUBackendState {
    /// Create a new backend state from a raw window handle.
    pub fn new(
        window: impl raw_window_handle::HasWindowHandle + raw_window_handle::HasDisplayHandle + Send + Sync + 'static,
        width: u32,
        height: u32,
    ) -> Result<Self, String> {
        use openreality_gpu_shared::uniforms::*;

        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            ..Default::default()
        });

        let surface = instance
            .create_surface(window)
            .map_err(|e| format!("Failed to create surface: {e}"))?;

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        }))
        .ok_or("Failed to find suitable GPU adapter")?;

        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("OpenReality WebGPU Device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::default(),
            },
            None,
        ))
        .map_err(|e| format!("Failed to create device: {e}"))?;

        let surface_caps = surface.get_capabilities(&adapter);
        let surface_format = surface_caps
            .formats
            .iter()
            .find(|f| f.is_srgb())
            .copied()
            .unwrap_or(surface_caps.formats[0]);

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width,
            height,
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: surface_caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &surface_config);

        // Create per-frame uniform buffer
        let per_frame_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Per-Frame Uniforms"),
            size: std::mem::size_of::<PerFrameUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let per_frame_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("Per-Frame Bind Group Layout"),
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

        // Per-object uniform buffer
        let per_object_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Per-Object Uniforms"),
            size: std::mem::size_of::<PerObjectUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Material bind group layout
        let material_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("Material Bind Group Layout"),
                entries: &[
                    // binding 0: MaterialUBO
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Uniform,
                            has_dynamic_offset: false,
                            min_binding_size: None,
                        },
                        count: None,
                    },
                    // bindings 1-6: texture maps
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 2,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 3,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 4,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 5,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 6,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    // binding 7: sampler
                    wgpu::BindGroupLayoutEntry {
                        binding: 7,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ],
            });

        // Light uniform buffer
        let light_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Light Uniforms"),
            size: std::mem::size_of::<LightUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Default sampler
        let default_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Default Sampler"),
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::Repeat,
            address_mode_w: wgpu::AddressMode::Repeat,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        log::info!(
            "WebGPU backend initialized: {} ({})",
            adapter.get_info().name,
            adapter.get_info().backend.to_str()
        );

        Ok(Self {
            instance,
            adapter,
            device,
            queue,
            surface,
            surface_config,
            width,
            height,
            meshes: HandleStore::new(),
            textures: HandleStore::new(),
            framebuffers: HandleStore::new(),
            gbuffer: None,
            lighting_target: None,
            csm: None,
            ssao: None,
            ssr: None,
            taa: None,
            post_process: None,
            per_frame_buffer,
            per_frame_bind_group_layout,
            per_object_buffer,
            material_bind_group_layout,
            light_buffer,
            default_sampler,
            deferred: None,
            last_error: None,
        })
    }

    /// Resize the surface and recreate dependent resources.
    pub fn resize(&mut self, width: u32, height: u32) {
        if width > 0 && height > 0 {
            self.width = width;
            self.height = height;
            self.surface_config.width = width;
            self.surface_config.height = height;
            self.surface.configure(&self.device, &self.surface_config);
        }
    }

    /// Render a frame that just clears to a color (bootstrap pass).
    pub fn render_clear(&mut self, r: f64, g: f64, b: f64) -> Result<(), String> {
        let output = self
            .surface
            .get_current_texture()
            .map_err(|e| format!("Surface texture error: {e}"))?;

        let view = output
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("Clear Encoder"),
            });

        {
            let _render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Clear Pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r,
                            g,
                            b,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                ..Default::default()
            });
        }

        self.queue.submit(std::iter::once(encoder.finish()));
        output.present();

        Ok(())
    }

    /// Upload mesh data to GPU buffers.
    pub fn upload_mesh(
        &mut self,
        positions: &[f32],
        normals: &[f32],
        uvs: &[f32],
        indices: &[u32],
    ) -> u64 {
        use wgpu::util::DeviceExt;

        let vertex_buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("Vertex Position Buffer"),
                contents: bytemuck::cast_slice(positions),
                usage: wgpu::BufferUsages::VERTEX,
            });

        let normal_buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("Vertex Normal Buffer"),
                contents: bytemuck::cast_slice(normals),
                usage: wgpu::BufferUsages::VERTEX,
            });

        let uv_buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("Vertex UV Buffer"),
                contents: bytemuck::cast_slice(uvs),
                usage: wgpu::BufferUsages::VERTEX,
            });

        let index_buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("Index Buffer"),
                contents: bytemuck::cast_slice(indices),
                usage: wgpu::BufferUsages::INDEX,
            });

        let mesh = GPUMesh {
            vertex_buffer,
            normal_buffer,
            uv_buffer,
            index_buffer,
            index_count: indices.len() as u32,
            bone_weight_buffer: None,
            bone_index_buffer: None,
            has_skinning: false,
        };

        self.meshes.insert(mesh)
    }

    /// Upload texture data to GPU.
    pub fn upload_texture(
        &mut self,
        pixels: &[u8],
        width: u32,
        height: u32,
        channels: u32,
    ) -> u64 {
        // Convert to RGBA if needed
        let rgba_data: Vec<u8>;
        let data = if channels == 4 {
            pixels
        } else if channels == 3 {
            rgba_data = pixels
                .chunks(3)
                .flat_map(|rgb| [rgb[0], rgb[1], rgb[2], 255])
                .collect();
            &rgba_data
        } else if channels == 1 {
            rgba_data = pixels
                .iter()
                .flat_map(|&g| [g, g, g, 255])
                .collect();
            &rgba_data
        } else {
            self.last_error = Some(format!("Unsupported channel count: {channels}"));
            return 0;
        };

        let texture_size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };

        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Uploaded Texture"),
            size: texture_size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        self.queue.write_texture(
            wgpu::ImageCopyTexture {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            data,
            wgpu::ImageDataLayout {
                offset: 0,
                bytes_per_row: Some(4 * width),
                rows_per_image: Some(height),
            },
            texture_size,
        );

        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        let sampler = self.device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Texture Sampler"),
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::Repeat,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let gpu_texture = GPUTexture {
            texture,
            view,
            sampler,
            width,
            height,
            channels,
        };

        self.textures.insert(gpu_texture)
    }

    /// Destroy a mesh by handle.
    pub fn destroy_mesh(&mut self, handle: u64) {
        self.meshes.remove(handle);
    }

    /// Destroy a texture by handle.
    pub fn destroy_texture(&mut self, handle: u64) {
        self.textures.remove(handle);
    }

    /// Create the full deferred rendering pipeline (all pipelines and targets).
    pub fn create_deferred_pipeline(&mut self) -> Result<(), String> {
        use crate::pipeline;
        use openreality_gpu_shared::uniforms::*;

        let device = &self.device;
        let queue = &self.queue;
        let w = self.width;
        let h = self.height;
        let surface_format = self.surface_config.format;

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

        // Create all bind group layouts
        let lighting_bgl = pipeline::create_lighting_bind_group_layout(device);
        let light_data_bgl = pipeline::create_light_data_bind_group_layout(device);
        let particle_bgl = pipeline::create_particle_bgl(device);
        let ui_bgl = pipeline::create_ui_bgl(device);
        let terrain_bgl = pipeline::create_terrain_bgl(device);
        let present_bgl = pipeline::create_present_bgl(device);
        let forward_light_shadow_bgl = pipeline::create_forward_light_shadow_bgl(device);
        let bone_bgl = pipeline::create_bone_bgl(device);

        // Effect bind group layouts — dedicated layouts for shaders with non-standard binding patterns
        let ssao_bgl = pipeline::create_ssao_bind_group_layout(device);
        let ssao_blur_bgl = pipeline::create_effect_bind_group_layout(device, "SSAO Blur BGL", 1, false);
        let ssr_bgl = pipeline::create_ssr_bind_group_layout(device);
        let taa_bgl = pipeline::create_taa_bind_group_layout(device);
        let bloom_extract_bgl = pipeline::create_effect_bind_group_layout(device, "Bloom Extract BGL", 1, false);
        let bloom_blur_bgl = pipeline::create_effect_bind_group_layout(device, "Bloom Blur BGL", 1, false);
        let bloom_composite_bgl = pipeline::create_effect_bind_group_layout(device, "Bloom Composite BGL", 2, false);
        let fxaa_bgl = pipeline::create_fxaa_bind_group_layout(device);

        // Create render pipelines (with logging to diagnose driver crashes)
        log::info!("Creating G-Buffer pipeline...");
        let gbuffer_pipeline = pipeline::create_gbuffer_pipeline(
            device,
            &self.per_frame_bind_group_layout,
            &self.material_bind_group_layout,
            &per_object_bgl,
        );

        log::info!("Creating shadow pipeline...");
        let shadow_pipeline = pipeline::create_shadow_pipeline(
            device,
            &self.per_frame_bind_group_layout,
            &per_object_bgl,
        );

        log::info!("Creating lighting pipeline...");
        let lighting_pipeline = pipeline::create_lighting_pipeline(
            device,
            &lighting_bgl,
            &light_data_bgl,
        );

        log::info!("Creating forward pipeline...");
        let forward_pipeline = pipeline::create_forward_pipeline(
            device,
            &self.per_frame_bind_group_layout,
            &self.material_bind_group_layout,
            &per_object_bgl,
            &forward_light_shadow_bgl,
        );

        log::info!("Creating present pipeline...");
        let present_pipeline = pipeline::create_present_pipeline(
            device,
            &present_bgl,
            surface_format,
        );

        log::info!("Creating particle pipeline...");
        let particle_pipeline = pipeline::create_particle_pipeline(device, &particle_bgl, surface_format);
        log::info!("Creating UI pipeline...");
        let ui_pipeline = pipeline::create_ui_pipeline(device, &ui_bgl, surface_format);
        log::info!("Creating terrain pipeline...");
        let terrain_pipeline = pipeline::create_terrain_pipeline(device, &self.per_frame_bind_group_layout, &terrain_bgl);

        log::info!("Creating skinned G-Buffer pipeline...");
        let gbuffer_skinned_pipeline = pipeline::create_gbuffer_skinned_pipeline(
            device,
            &self.per_frame_bind_group_layout,
            &self.material_bind_group_layout,
            &per_object_bgl,
            &bone_bgl,
        );

        log::info!("Creating instanced G-Buffer pipeline...");
        let gbuffer_instanced_pipeline = pipeline::create_gbuffer_instanced_pipeline(
            device,
            &self.per_frame_bind_group_layout,
            &self.material_bind_group_layout,
        );

        // Effect pipelines
        use openreality_gpu_shared::shaders;
        log::info!("Creating SSAO pipeline...");
        let ssao_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "SSAO Pipeline", shaders::SSAO_FRAG, "fs_main", &ssao_bgl, render_targets::R16_FORMAT,
        );
        log::info!("Creating SSAO blur pipeline...");
        let ssao_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "SSAO Blur Pipeline", shaders::SSAO_BLUR_FRAG, "fs_main", &ssao_blur_bgl, render_targets::R16_FORMAT,
        );
        log::info!("Creating SSR pipeline...");
        let ssr_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "SSR Pipeline", shaders::SSR_FRAG, "fs_main", &ssr_bgl, render_targets::HDR_FORMAT,
        );
        log::info!("Creating TAA pipeline...");
        let taa_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "TAA Pipeline", shaders::TAA_FRAG, "fs_main", &taa_bgl, render_targets::HDR_FORMAT,
        );
        log::info!("Creating bloom extract pipeline...");
        let bloom_extract_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "Bloom Extract Pipeline", shaders::BLOOM_EXTRACT_FRAG, "fs_main", &bloom_extract_bgl, render_targets::HDR_FORMAT,
        );
        log::info!("Creating bloom blur pipeline...");
        let bloom_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "Bloom Blur Pipeline", shaders::BLOOM_BLUR_FRAG, "fs_main", &bloom_blur_bgl, render_targets::HDR_FORMAT,
        );
        log::info!("Creating bloom composite pipeline...");
        let bloom_composite_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "Bloom Composite Pipeline", shaders::BLOOM_COMPOSITE_FRAG, "fs_main", &bloom_composite_bgl, render_targets::HDR_FORMAT,
        );
        log::info!("Creating FXAA pipeline...");
        let fxaa_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "FXAA Pipeline", shaders::FXAA_FRAG, "fs_main", &fxaa_bgl, render_targets::HDR_FORMAT,
        );
        log::info!("All pipelines created successfully.");

        // Create render targets
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

        // Uniform buffers for effects
        let ssao_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("SSAO Params"),
            size: std::mem::size_of::<SSAOParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let ssr_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("SSR Params"),
            size: std::mem::size_of::<SSRParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let taa_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("TAA Params"),
            size: std::mem::size_of::<TAAParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let pp_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("PostProcess Params"),
            size: std::mem::size_of::<PostProcessParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let shadow_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Shadow Uniforms"),
            size: std::mem::size_of::<ShadowUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Particle/UI uniform buffers (view/proj for particles, projection for UI)
        let particle_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Particle Uniforms"),
            size: 128, // 2 * mat4x4<f32>
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let ui_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("UI Uniforms"),
            size: 80, // mat4x4 + 4 ints
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let terrain_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Terrain Params"),
            size: 32, // TerrainParams
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bone_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Bone Uniforms"),
            size: std::mem::size_of::<BoneUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // DOF pipelines, BGLs, and buffers
        use openreality_gpu_shared::uniforms::{DOFCoCParams, DOFBlurParams, VelocityParams, MotionBlurParams};
        let dof_coc_bgl = pipeline::create_dof_coc_bgl(device);
        let dof_blur_bgl = pipeline::create_dof_blur_bgl(device);
        let dof_composite_bgl = pipeline::create_dof_composite_bgl(device);
        let dof_coc_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "DOF CoC Pipeline", shaders::DOF_SHADER, "fs_coc", &dof_coc_bgl, render_targets::R16_FORMAT,
        );
        let dof_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "DOF Blur Pipeline", shaders::DOF_SHADER, "fs_blur", &dof_blur_bgl, render_targets::HDR_FORMAT,
        );
        let dof_composite_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "DOF Composite Pipeline", shaders::DOF_SHADER, "fs_composite", &dof_composite_bgl, render_targets::HDR_FORMAT,
        );
        let dof_coc_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("DOF CoC Params"),
            size: std::mem::size_of::<DOFCoCParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let dof_blur_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("DOF Blur Params"),
            size: std::mem::size_of::<DOFBlurParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Motion blur pipelines, BGLs, and buffers
        let mblur_velocity_bgl = pipeline::create_mblur_velocity_bgl(device);
        let mblur_blur_bgl = pipeline::create_mblur_blur_bgl(device);
        let mblur_velocity_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "Motion Blur Velocity Pipeline", shaders::MOTION_BLUR_SHADER, "fs_velocity",
            &mblur_velocity_bgl, render_targets::RG16_FORMAT,
        );
        let mblur_blur_pipeline = pipeline::create_fullscreen_effect_pipeline(
            device, "Motion Blur Pipeline", shaders::MOTION_BLUR_SHADER, "fs_blur",
            &mblur_blur_bgl, render_targets::HDR_FORMAT,
        );
        let mblur_velocity_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Motion Blur Velocity Params"),
            size: std::mem::size_of::<VelocityParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mblur_blur_params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Motion Blur Blur Params"),
            size: std::mem::size_of::<MotionBlurParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Dynamic vertex buffers (start with reasonable default size, resize as needed)
        let initial_particle_vbo_size = 1024 * 9 * 4; // 1024 vertices * 9 floats * 4 bytes
        let particle_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Particle VBO"),
            size: initial_particle_vbo_size,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let initial_ui_vbo_size = 4096 * 8 * 4; // 4096 vertices * 8 floats * 4 bytes
        let ui_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("UI VBO"),
            size: initial_ui_vbo_size,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let initial_instance_vbo_size = 256 * pipeline::INSTANCE_STRIDE; // 256 instances * 112 bytes
        let instance_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Instance VBO"),
            size: initial_instance_vbo_size,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Debug lines
        let debug_lines_bgl = pipeline::create_debug_lines_bgl(device);
        let debug_lines_pipeline = pipeline::create_debug_lines_pipeline(
            device, &debug_lines_bgl, self.surface_config.format,
        );
        let debug_lines_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Debug Lines Uniform"),
            size: 64, // mat4x4
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let initial_debug_lines_vbo_size = 1024 * 24u64; // 1024 vertices * 24 bytes
        let debug_lines_vbo = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Debug Lines VBO"),
            size: initial_debug_lines_vbo_size,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        self.deferred = Some(DeferredPipeline {
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
            particle_vbo_size: initial_particle_vbo_size,
            ui_vbo,
            ui_vbo_size: initial_ui_vbo_size,
            instance_vbo,
            instance_vbo_size: initial_instance_vbo_size,
            debug_lines_pipeline,
            debug_lines_bgl,
            debug_lines_uniform_buffer,
            debug_lines_vbo,
            debug_lines_vbo_size: initial_debug_lines_vbo_size,
            taa_first_frame: true,
        });

        log::info!("Deferred pipeline created ({}x{})", w, h);
        Ok(())
    }

    /// Resize deferred pipeline render targets (called on window resize).
    pub fn resize_deferred_pipeline(&mut self, width: u32, height: u32) {
        if let Some(ref mut dp) = self.deferred {
            let device = &self.device;

            dp.gbuffer = render_targets::create_gbuffer(device, width, height);
            dp.lighting_target = render_targets::create_hdr_target(device, width, height, "Lighting Target", true);
            dp.ssao_targets = render_targets::create_ssao_targets(device, width, height);
            dp.ssr_target = render_targets::create_ssr_target(device, width, height);
            dp.taa_targets = render_targets::create_taa_targets(device, width, height);
            dp.bloom_targets = render_targets::create_bloom_targets(device, width, height);
            dp.pp_target_a = render_targets::create_hdr_target(device, width, height, "PP Target A", false);
            dp.pp_target_b = render_targets::create_hdr_target(device, width, height, "PP Target B", false);
            dp.taa_first_frame = true;

            log::info!("Deferred pipeline resized to {}x{}", width, height);
        }
    }
}
