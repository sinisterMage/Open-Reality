use std::sync::{Arc, Mutex};
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::HtmlCanvasElement;

use openreality_render::scene_renderer::{SceneRenderer, CameraParams, SceneLights, EntityRenderData};
use openreality_gpu_shared::uniforms::{MaterialUniforms, PerObjectUniforms, DirLightData, PointLightData};
use crate::scene::LoadedScene;
use crate::input::{self, InputState};
use crate::scripting::ScriptEngine;
use crate::{animation, transform, skinning};

/// Main application state for the WASM runtime.
#[wasm_bindgen]
pub struct App {
    scene: LoadedScene,
    input: Arc<Mutex<InputState>>,
    scripts: ScriptEngine,
    renderer: SceneRenderer,
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    surface_config: wgpu::SurfaceConfiguration,
    last_time: f64,
    canvas: HtmlCanvasElement,
    total_time: f32,
}

#[wasm_bindgen]
impl App {
    /// Create a new App from canvas ID and ORSB scene data.
    pub async fn new(canvas_id: &str, scene_data: &[u8]) -> Result<App, JsValue> {
        let window = web_sys::window().ok_or("No window")?;
        let document = window.document().ok_or("No document")?;
        let canvas = document
            .get_element_by_id(canvas_id)
            .ok_or("Canvas not found")?
            .dyn_into::<HtmlCanvasElement>()
            .map_err(|_| "Element is not a canvas")?;

        let width = canvas.width();
        let height = canvas.height();

        // Parse ORSB scene
        let scene = LoadedScene::from_orsb(scene_data)
            .map_err(|e| JsValue::from_str(&format!("Failed to load scene: {e}")))?;

        log::info!(
            "Loaded scene: {} entities, {} meshes, {} textures, {} scripts",
            scene.num_entities(),
            scene.num_meshes(),
            scene.num_textures(),
            scene.scripts.len(),
        );

        // Initialize WebGPU
        // Request adapter first (without surface) to avoid browser context provider issues,
        // then create the surface and configure it.
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::BROWSER_WEBGPU,
            ..Default::default()
        });

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: None,
                force_fallback_adapter: false,
            })
            .await
            .ok_or("No suitable GPU adapter found. Make sure WebGPU is enabled in your browser.")?;

        log::info!("Got adapter: {:?}", adapter.get_info());

        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("OpenReality Device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::downlevel_webgl2_defaults()
                        .using_resolution(adapter.limits()),
                    memory_hints: wgpu::MemoryHints::MemoryUsage,
                },
                None,
            )
            .await
            .map_err(|e| JsValue::from_str(&format!("Failed to get device: {e}")))?;

        let surface_target = wgpu::SurfaceTarget::Canvas(canvas.clone());
        let surface = instance.create_surface(surface_target)
            .map_err(|e| JsValue::from_str(&format!("Failed to create surface: {e}")))?;

        let surface_caps = surface.get_capabilities(&adapter);
        let surface_format = if surface_caps.formats.is_empty() {
            // Fallback for WebGPU — bgra8unorm is the standard web format
            wgpu::TextureFormat::Bgra8UnormSrgb
        } else {
            surface_caps
                .formats
                .iter()
                .find(|f| f.is_srgb())
                .copied()
                .unwrap_or(surface_caps.formats[0])
        };

        let surface_config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width,
            height,
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode: surface_caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &surface_config);

        // Create renderer
        let mut renderer = SceneRenderer::new(&device, &queue, width, height, surface_format)
            .map_err(|e| JsValue::from_str(&format!("Failed to create renderer: {e}")))?;

        // Upload meshes to GPU
        for (i, mesh) in scene.meshes.iter().enumerate() {
            renderer.upload_mesh(
                &device,
                &mesh.positions,
                &mesh.normals,
                &mesh.uvs,
                &mesh.indices,
                mesh.bone_weights.as_deref(),
                mesh.bone_indices.as_deref(),
            );
            log::info!("Uploaded mesh {} ({} verts, {} indices)", i,
                mesh.positions.len() / 3, mesh.indices.len());
        }

        // Upload textures to GPU
        for (i, tex) in scene.textures.iter().enumerate() {
            let is_png = tex.compression > 0;
            renderer.upload_texture(&device, &queue, tex.width, tex.height, tex.channels, &tex.data, is_png);
            log::info!("Uploaded texture {} ({}x{})", i, tex.width, tex.height);
        }

        // Create script engine
        let scripts = ScriptEngine::new(
            &scene.scripts,
            &scene.game_refs,
            scene.num_entities(),
        );

        // Set up input with event bindings
        let input_state = Arc::new(Mutex::new(InputState::new()));
        input::bind_events(&canvas, &document, input_state.clone());

        log::info!("OpenReality Web Runtime ready ({}x{}, {:?})", width, height, surface_format);

        Ok(App {
            scene,
            input: input_state,
            scripts,
            renderer,
            device,
            queue,
            surface,
            surface_config,
            last_time: 0.0,
            canvas,
            total_time: 0.0,
        })
    }

    /// Run one frame of the game loop. Called from requestAnimationFrame.
    pub fn frame(&mut self, time: f64) {
        let dt = if self.last_time > 0.0 {
            ((time - self.last_time) / 1000.0).min(0.1) as f32
        } else {
            0.016
        };
        self.last_time = time;
        self.total_time += dt;

        // Take input snapshot and reset deltas
        let input_snapshot = {
            let mut inp = self.input.lock().unwrap();
            let snapshot = InputState {
                keys_down: inp.keys_down,
                mouse_x: inp.mouse_x,
                mouse_y: inp.mouse_y,
                mouse_dx: inp.mouse_dx,
                mouse_dy: inp.mouse_dy,
                mouse_buttons: inp.mouse_buttons,
                mouse_clicked: inp.mouse_clicked,
            };
            inp.update();
            snapshot
        };

        // Run on_start scripts (once)
        self.scripts.run_start(&mut self.scene);

        // Run on_update scripts
        self.scripts.run_update(&mut self.scene, &input_snapshot, dt);

        // Update systems
        animation::update_animations(&mut self.scene, dt);
        transform::compute_world_transforms(&mut self.scene);
        skinning::update_skinned_meshes(&mut self.scene);

        // Render
        let surface_texture = match self.surface.get_current_texture() {
            Ok(tex) => tex,
            Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                self.surface.configure(&self.device, &self.surface_config);
                return;
            }
            Err(e) => {
                log::error!("Surface error: {}", e);
                return;
            }
        };

        let surface_view = surface_texture.texture.create_view(&wgpu::TextureViewDescriptor::default());

        let camera = self.build_camera();
        let lights = self.build_lights();
        let entities = self.build_entities();

        self.renderer.render_frame(
            &self.device,
            &self.queue,
            &surface_view,
            &camera,
            &lights,
            &entities,
            self.total_time,
        );

        surface_texture.present();
    }

    /// Handle canvas resize.
    pub fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        self.surface_config.width = width;
        self.surface_config.height = height;
        self.surface.configure(&self.device, &self.surface_config);
        self.renderer.resize(&self.device, width, height);
    }

    /// Get the canvas width.
    pub fn width(&self) -> u32 {
        self.canvas.width()
    }

    /// Get the canvas height.
    pub fn height(&self) -> u32 {
        self.canvas.height()
    }
}

// Private helpers
impl App {
    fn build_camera(&self) -> CameraParams {
        use glam::{Mat4, Vec3};

        let aspect = self.surface_config.width as f32 / self.surface_config.height.max(1) as f32;

        // Find first camera entity
        if let Some(cam) = self.scene.cameras.first() {
            let fov = cam.fov;
            let near = cam.near;
            let far = cam.far;

            // TODO: Once scripts can drive the camera, use the camera entity's transform.
            // For now, place a default camera looking toward the origin.
            let pos = Vec3::new(0.0, 2.0, 5.0);
            let target = Vec3::ZERO;
            let up = Vec3::Y;

            let view = Mat4::look_at_rh(pos, target, up);
            let projection = Mat4::perspective_rh(fov, aspect, near, far);

            CameraParams { view, projection, position: pos, near, far }
        } else {
            let pos = Vec3::new(0.0, 2.0, 5.0);
            let view = Mat4::look_at_rh(pos, Vec3::ZERO, Vec3::Y);
            let projection = Mat4::perspective_rh(60.0_f32.to_radians(), aspect, 0.1, 1000.0);

            CameraParams { view, projection, position: pos, near: 0.1, far: 1000.0 }
        }
    }

    fn build_lights(&self) -> SceneLights {
        let mut dir_lights = Vec::new();
        for dl in &self.scene.dir_lights {
            dir_lights.push(DirLightData {
                direction: [dl.direction[0], dl.direction[1], dl.direction[2], 0.0],
                color: [dl.color[0], dl.color[1], dl.color[2], 1.0],
                intensity: dl.intensity,
                _pad1: 0.0,
                _pad2: 0.0,
                _pad3: 0.0,
            });
        }
        // Default directional light if none in scene
        if dir_lights.is_empty() {
            dir_lights.push(DirLightData {
                direction: [0.0, -1.0, -0.5, 0.0],
                color: [1.0, 1.0, 1.0, 1.0],
                intensity: 1.0,
                _pad1: 0.0,
                _pad2: 0.0,
                _pad3: 0.0,
            });
        }

        let mut point_lights = Vec::new();
        for pl in &self.scene.point_lights {
            point_lights.push(PointLightData {
                position: [pl.position[0], pl.position[1], pl.position[2], 1.0],
                color: [pl.color[0], pl.color[1], pl.color[2], 1.0],
                intensity: pl.intensity,
                range: pl.range,
                _pad1: 0.0,
                _pad2: 0.0,
            });
        }

        SceneLights { dir_lights, point_lights }
    }

    fn build_entities(&self) -> Vec<EntityRenderData> {
        use bytemuck::Zeroable;

        let mut entities = Vec::new();
        for entity in &self.scene.entities {
            if let (Some(mesh_idx), Some(mat_idx)) = (entity.mesh_index, entity.material_index) {
                let wt = entity.world_transform;
                let normal_matrix = wt.inverse().transpose();

                let per_object = PerObjectUniforms {
                    model: wt.to_cols_array_2d(),
                    normal_matrix_col0: [normal_matrix.x_axis.x, normal_matrix.x_axis.y, normal_matrix.x_axis.z, 0.0],
                    normal_matrix_col1: [normal_matrix.y_axis.x, normal_matrix.y_axis.y, normal_matrix.y_axis.z, 0.0],
                    normal_matrix_col2: [normal_matrix.z_axis.x, normal_matrix.z_axis.y, normal_matrix.z_axis.z, 0.0],
                    _pad: [0.0; 4],
                };

                // Build material uniforms from scene material
                let mat = if mat_idx < self.scene.materials.len() {
                    let m = &self.scene.materials[mat_idx];
                    MaterialUniforms {
                        albedo: m.color,
                        metallic: m.metallic,
                        roughness: m.roughness,
                        ao: 1.0,
                        alpha_cutoff: m.alpha_cutoff,
                        emissive_factor: [m.emissive[0], m.emissive[1], m.emissive[2], 1.0],
                        clearcoat: m.clearcoat,
                        clearcoat_roughness: 0.0,
                        subsurface: m.subsurface,
                        parallax_scale: 0.0,
                        has_albedo_map: if m.texture_indices[0] >= 0 { 1 } else { 0 },
                        has_normal_map: if m.texture_indices[1] >= 0 { 1 } else { 0 },
                        has_metallic_roughness_map: if m.texture_indices[2] >= 0 { 1 } else { 0 },
                        has_ao_map: if m.texture_indices[3] >= 0 { 1 } else { 0 },
                        has_emissive_map: if m.texture_indices[4] >= 0 { 1 } else { 0 },
                        has_height_map: if m.texture_indices[5] >= 0 { 1 } else { 0 },
                        lod_alpha_bits: 0x3f800000_u32 as i32, // 1.0 in f32 bits
                        _pad2: 0,
                    }
                } else {
                    MaterialUniforms::zeroed()
                };

                let texture_indices = if mat_idx < self.scene.materials.len() {
                    self.scene.materials[mat_idx].texture_indices
                } else {
                    [-1; 7]
                };

                let is_transparent = if mat_idx < self.scene.materials.len() {
                    self.scene.materials[mat_idx].opacity < 1.0
                } else {
                    false
                };

                entities.push(EntityRenderData {
                    mesh_index: Some(mesh_idx),
                    material_index: Some(mat_idx),
                    per_object,
                    texture_indices,
                    material: mat,
                    is_transparent,
                    has_skinning: false,
                });
            }
        }
        entities
    }
}
