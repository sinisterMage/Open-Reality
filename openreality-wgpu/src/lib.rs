//! OpenReality WebGPU Backend — C FFI entry points.
//!
//! This crate is compiled as a cdylib and loaded by Julia via ccall.
//! All public functions use `extern "C"` ABI with `#[no_mangle]`.

mod backend;
mod handle;
mod render_targets;
mod pipeline;
mod passes;
mod ibl;

use backend::WGPUBackendState;
use handle::HandleStore;
use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::Mutex;

// Global store of backend instances (usually just one).
static BACKENDS: std::sync::LazyLock<Mutex<HandleStore<WGPUBackendState>>> =
    std::sync::LazyLock::new(|| Mutex::new(HandleStore::new()));

// ============================================================
// Window handle wrapper for raw-window-handle integration
// ============================================================

/// Wrapper that implements HasWindowHandle + HasDisplayHandle for X11.
#[cfg(target_os = "linux")]
struct X11WindowHandle {
    window: u64,
    display: *mut std::ffi::c_void,
}

#[cfg(target_os = "linux")]
unsafe impl Send for X11WindowHandle {}
#[cfg(target_os = "linux")]
unsafe impl Sync for X11WindowHandle {}

#[cfg(target_os = "linux")]
impl raw_window_handle::HasWindowHandle for X11WindowHandle {
    fn window_handle(&self) -> Result<raw_window_handle::WindowHandle<'_>, raw_window_handle::HandleError> {
        let raw = raw_window_handle::RawWindowHandle::Xlib(raw_window_handle::XlibWindowHandle::new(self.window as _));
        Ok(unsafe { raw_window_handle::WindowHandle::borrow_raw(raw) })
    }
}

#[cfg(target_os = "linux")]
impl raw_window_handle::HasDisplayHandle for X11WindowHandle {
    fn display_handle(&self) -> Result<raw_window_handle::DisplayHandle<'_>, raw_window_handle::HandleError> {
        let raw = raw_window_handle::RawDisplayHandle::Xlib(
            raw_window_handle::XlibDisplayHandle::new(
                std::ptr::NonNull::new(self.display),
                0,
            ),
        );
        Ok(unsafe { raw_window_handle::DisplayHandle::borrow_raw(raw) })
    }
}

/// Wrapper for Windows (Win32).
#[cfg(target_os = "windows")]
struct Win32WindowHandle {
    hwnd: *mut std::ffi::c_void,
}

#[cfg(target_os = "windows")]
unsafe impl Send for Win32WindowHandle {}
#[cfg(target_os = "windows")]
unsafe impl Sync for Win32WindowHandle {}

#[cfg(target_os = "windows")]
impl raw_window_handle::HasWindowHandle for Win32WindowHandle {
    fn window_handle(&self) -> Result<raw_window_handle::WindowHandle<'_>, raw_window_handle::HandleError> {
        let raw = raw_window_handle::RawWindowHandle::Win32(
            raw_window_handle::Win32WindowHandle::new(
                std::num::NonZeroIsize::new(self.hwnd as isize).unwrap(),
            ),
        );
        Ok(unsafe { raw_window_handle::WindowHandle::borrow_raw(raw) })
    }
}

#[cfg(target_os = "windows")]
impl raw_window_handle::HasDisplayHandle for Win32WindowHandle {
    fn display_handle(&self) -> Result<raw_window_handle::DisplayHandle<'_>, raw_window_handle::HandleError> {
        let raw = raw_window_handle::RawDisplayHandle::Windows(raw_window_handle::WindowsDisplayHandle::new());
        Ok(unsafe { raw_window_handle::DisplayHandle::borrow_raw(raw) })
    }
}

// ============================================================
// FFI: Lifecycle
// ============================================================

/// Initialize the WebGPU backend with a raw window handle.
///
/// On Linux: `window_handle` is the X11 Window (u64), `display_handle` is the X11 Display*.
/// On Windows: `window_handle` is the HWND, `display_handle` is unused.
///
/// Returns a backend handle (> 0) on success, 0 on failure.
#[no_mangle]
pub extern "C" fn or_wgpu_initialize(
    window_handle: u64,
    display_handle: *mut std::ffi::c_void,
    width: i32,
    height: i32,
) -> u64 {
    let _ = env_logger::try_init();

    let w = width as u32;
    let h = height as u32;

    #[cfg(target_os = "linux")]
    let result = {
        let handle = X11WindowHandle {
            window: window_handle,
            display: display_handle,
        };
        WGPUBackendState::new(handle, w, h)
    };

    #[cfg(target_os = "windows")]
    let result = {
        let handle = Win32WindowHandle {
            hwnd: window_handle as *mut std::ffi::c_void,
        };
        WGPUBackendState::new(handle, w, h)
    };

    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    let result: Result<WGPUBackendState, String> = Err("Unsupported platform".into());

    match result {
        Ok(state) => {
            let mut backends = BACKENDS.lock().unwrap();
            backends.insert(state)
        }
        Err(e) => {
            log::error!("WebGPU initialization failed: {e}");
            0
        }
    }
}

/// Shutdown the backend and release all GPU resources.
#[no_mangle]
pub extern "C" fn or_wgpu_shutdown(backend: u64) {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.remove(backend) {
        // Drop state — all wgpu resources are released
        drop(state);
        log::info!("WebGPU backend shut down");
    }
}

/// Resize the rendering surface.
#[no_mangle]
pub extern "C" fn or_wgpu_resize(backend: u64, width: i32, height: i32) {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        state.resize(width as u32, height as u32);
    }
}

// ============================================================
// FFI: Simple rendering
// ============================================================

/// Render a frame that clears to the given color (bootstrap test).
#[no_mangle]
pub extern "C" fn or_wgpu_render_clear(backend: u64, r: f64, g: f64, b: f64) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        match state.render_clear(r, g, b) {
            Ok(()) => 0,
            Err(e) => {
                state.last_error = Some(e);
                -1
            }
        }
    } else {
        -1
    }
}

// ============================================================
// FFI: Mesh operations
// ============================================================

/// Upload mesh data to GPU. Returns mesh handle (> 0) or 0 on failure.
#[no_mangle]
pub extern "C" fn or_wgpu_upload_mesh(
    backend: u64,
    positions: *const f32,
    num_vertices: u32,
    normals: *const f32,
    uvs: *const f32,
    indices: *const u32,
    num_indices: u32,
) -> u64 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let pos_slice = unsafe { std::slice::from_raw_parts(positions, (num_vertices * 3) as usize) };
        let norm_slice = unsafe { std::slice::from_raw_parts(normals, (num_vertices * 3) as usize) };
        let uv_slice = unsafe { std::slice::from_raw_parts(uvs, (num_vertices * 2) as usize) };
        let idx_slice = unsafe { std::slice::from_raw_parts(indices, num_indices as usize) };
        state.upload_mesh(pos_slice, norm_slice, uv_slice, idx_slice)
    } else {
        0
    }
}

/// Destroy a mesh and free its GPU resources.
#[no_mangle]
pub extern "C" fn or_wgpu_destroy_mesh(backend: u64, mesh: u64) {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        state.destroy_mesh(mesh);
    }
}

// ============================================================
// FFI: Texture operations
// ============================================================

/// Upload texture data to GPU. Returns texture handle (> 0) or 0 on failure.
#[no_mangle]
pub extern "C" fn or_wgpu_upload_texture(
    backend: u64,
    pixels: *const u8,
    width: i32,
    height: i32,
    channels: i32,
) -> u64 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let data_len = (width * height * channels) as usize;
        let pixel_slice = unsafe { std::slice::from_raw_parts(pixels, data_len) };
        state.upload_texture(pixel_slice, width as u32, height as u32, channels as u32)
    } else {
        0
    }
}

/// Destroy a texture and free its GPU resources.
#[no_mangle]
pub extern "C" fn or_wgpu_destroy_texture(backend: u64, texture: u64) {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        state.destroy_texture(texture);
    }
}

// ============================================================
// FFI: Error handling
// ============================================================

/// Get the last error message. Returns a C string (valid until next FFI call) or null.
#[no_mangle]
pub extern "C" fn or_wgpu_last_error(backend: u64) -> *const c_char {
    let backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get(backend) {
        if let Some(ref err) = state.last_error {
            // Leak the CString so the pointer remains valid until next call
            let c_str = CString::new(err.as_str()).unwrap();
            c_str.into_raw() as *const c_char
        } else {
            std::ptr::null()
        }
    } else {
        std::ptr::null()
    }
}

// ============================================================
// FFI: Advanced resource creation (stubs for now)
// ============================================================

/// Create cascaded shadow maps. Returns CSM handle or 0.
#[no_mangle]
pub extern "C" fn or_wgpu_create_csm(
    backend: u64,
    num_cascades: i32,
    resolution: i32,
    _near: f32,
    _far: f32,
) -> u64 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let res = resolution as u32;
        let n = num_cascades as u32;

        let sampler = state.device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Shadow Sampler"),
            compare: Some(wgpu::CompareFunction::LessEqual),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let mut depth_textures = Vec::new();
        let mut depth_views = Vec::new();

        for i in 0..n {
            let texture = state.device.create_texture(&wgpu::TextureDescriptor {
                label: Some(&format!("Shadow Cascade {i}")),
                size: wgpu::Extent3d {
                    width: res,
                    height: res,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            depth_textures.push(texture);
            depth_views.push(view);
        }

        state.csm = Some(backend::CascadedShadowMap {
            depth_textures,
            depth_views,
            sampler,
            num_cascades: n,
            resolution: res,
        });

        1 // Success (non-zero)
    } else {
        0
    }
}

/// Create post-processing pipeline. Returns 1 on success, 0 on failure.
#[no_mangle]
pub extern "C" fn or_wgpu_create_post_process(
    _backend: u64,
    _width: i32,
    _height: i32,
    _bloom_threshold: f32,
    _bloom_intensity: f32,
    _gamma: f32,
    _tone_mapping_mode: i32,
    _fxaa_enabled: i32,
) -> u64 {
    // Post-processing is handled by the deferred pipeline
    1
}

// ============================================================
// FFI: Deferred Pipeline Setup
// ============================================================

/// Create the full deferred rendering pipeline (all pipelines and render targets).
/// Call once after initialize. Returns 0 on success, -1 on failure.
#[no_mangle]
pub extern "C" fn or_wgpu_create_deferred_pipeline(backend: u64, width: i32, height: i32) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        state.resize(width as u32, height as u32);
        match state.create_deferred_pipeline() {
            Ok(()) => 0,
            Err(e) => {
                state.last_error = Some(e);
                -1
            }
        }
    } else {
        -1
    }
}

/// Resize the deferred pipeline render targets.
#[no_mangle]
pub extern "C" fn or_wgpu_resize_pipeline(backend: u64, width: i32, height: i32) {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        state.resize(width as u32, height as u32);
        state.resize_deferred_pipeline(width as u32, height as u32);
    }
}

// ============================================================
// FFI: Per-Frame Rendering Calls
// ============================================================

/// Begin frame: upload per-frame uniforms (view, projection, inv_view_proj, camera_pos, time).
/// `per_frame_ptr` points to a PerFrameUniforms struct.
#[no_mangle]
pub extern "C" fn or_wgpu_begin_frame(
    backend: u64,
    per_frame_ptr: *const u8,
    per_frame_size: u32,
) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let data = unsafe { std::slice::from_raw_parts(per_frame_ptr, per_frame_size as usize) };
        state.queue.write_buffer(&state.per_frame_buffer, 0, data);
        0
    } else {
        -1
    }
}

/// Upload light data (LightUniforms struct).
#[no_mangle]
pub extern "C" fn or_wgpu_upload_lights(
    backend: u64,
    light_data_ptr: *const u8,
    light_data_size: u32,
) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let data = unsafe { std::slice::from_raw_parts(light_data_ptr, light_data_size as usize) };
        state.queue.write_buffer(&state.light_buffer, 0, data);
        0
    } else {
        -1
    }
}

/// Shadow pass: render depth for all cascades.
/// `cascade_matrices_ptr` points to 4 mat4x4<f32> (cascade light-space VP matrices).
/// `entity_models_ptr` points to N mat4x4<f32> model matrices (one per entity).
/// `entity_mesh_handles_ptr` points to N u64 mesh handles.
#[no_mangle]
pub extern "C" fn or_wgpu_shadow_pass(
    backend: u64,
    entity_mesh_handles_ptr: *const u64,
    entity_models_ptr: *const f32,
    entity_count: u32,
    cascade_matrices_ptr: *const f32,
    num_cascades: i32,
) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };
        let csm = match state.csm.as_ref() {
            Some(csm) => csm,
            None => { state.last_error = Some("CSM not created".into()); return -1; }
        };

        let mesh_handles = unsafe { std::slice::from_raw_parts(entity_mesh_handles_ptr, entity_count as usize) };
        let model_data = unsafe { std::slice::from_raw_parts(entity_models_ptr, (entity_count * 16) as usize) };
        let cascade_data = unsafe { std::slice::from_raw_parts(cascade_matrices_ptr, (num_cascades * 16) as usize) };

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Shadow Encoder"),
        });

        for c in 0..(num_cascades as usize).min(csm.num_cascades as usize) {
            // Upload cascade VP matrix as per-frame data for this cascade
            let cascade_vp: [[f32; 4]; 4] = {
                let base = c * 16;
                [
                    [cascade_data[base], cascade_data[base + 1], cascade_data[base + 2], cascade_data[base + 3]],
                    [cascade_data[base + 4], cascade_data[base + 5], cascade_data[base + 6], cascade_data[base + 7]],
                    [cascade_data[base + 8], cascade_data[base + 9], cascade_data[base + 10], cascade_data[base + 11]],
                    [cascade_data[base + 12], cascade_data[base + 13], cascade_data[base + 14], cascade_data[base + 15]],
                ]
            };

            // Write cascade VP to per-frame buffer (view slot = identity, projection slot = cascade VP)
            let shadow_frame = openreality_gpu_shared::uniforms::PerFrameUniforms {
                view: [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]],
                projection: cascade_vp,
                inv_view_proj: [[0.0; 4]; 4],
                camera_pos: [0.0; 4],
                time: 0.0,
                _pad1: 0.0,
                _pad2: 0.0,
                _pad3: 0.0,
                _alignment_pad: [0.0; 8],
            };
            state.queue.write_buffer(&state.per_frame_buffer, 0, bytemuck::bytes_of(&shadow_frame));

            let per_frame_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("Shadow Per-Frame BG"),
                layout: &state.per_frame_bind_group_layout,
                entries: &[wgpu::BindGroupEntry {
                    binding: 0,
                    resource: state.per_frame_buffer.as_entire_binding(),
                }],
            });

            // Collect entities for this cascade
            let mut shadow_meshes = Vec::new();
            for i in 0..entity_count as usize {
                let mesh_handle = mesh_handles[i];
                if let Some(mesh) = state.meshes.get(mesh_handle) {
                    let base = i * 16;
                    let model: [[f32; 4]; 4] = [
                        [model_data[base], model_data[base + 1], model_data[base + 2], model_data[base + 3]],
                        [model_data[base + 4], model_data[base + 5], model_data[base + 6], model_data[base + 7]],
                        [model_data[base + 8], model_data[base + 9], model_data[base + 10], model_data[base + 11]],
                        [model_data[base + 12], model_data[base + 13], model_data[base + 14], model_data[base + 15]],
                    ];
                    shadow_meshes.push((mesh_handle, mesh, model));
                }
            }

            passes::shadow::render_shadow_cascade(
                &mut encoder,
                csm,
                c,
                &dp.shadow_pipeline,
                &per_frame_bg,
                &dp.per_object_bgl,
                &state.device,
                &state.queue,
                &state.per_object_buffer,
                &shadow_meshes,
            );
        }

        state.queue.submit(std::iter::once(encoder.finish()));
        0
    } else {
        -1
    }
}

/// G-Buffer pass: render all opaque entities.
/// Each entity is described by: mesh_handle (u64), model_matrix (16 f32), normal_matrix (12 f32),
/// material (MaterialUniforms bytes), texture_handles (6 u64).
/// `entities_ptr` points to packed EntityDrawData array.
/// `entity_stride` is the byte size of each EntityDrawData.
#[no_mangle]
pub extern "C" fn or_wgpu_gbuffer_pass(
    backend: u64,
    entities_ptr: *const u8,
    entity_count: u32,
    entity_stride: u32,
) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let per_frame_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("GBuffer Per-Frame BG"),
            layout: &state.per_frame_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: state.per_frame_buffer.as_entire_binding(),
            }],
        });

        // Parse entities from packed data
        let entities_data = unsafe { std::slice::from_raw_parts(entities_ptr, (entity_count * entity_stride) as usize) };
        let mut gbuffer_entities = Vec::new();

        for i in 0..entity_count as usize {
            let offset = i * entity_stride as usize;
            let entity_bytes = &entities_data[offset..offset + entity_stride as usize];

            // Parse EntityDrawData layout:
            // 0: mesh_handle u64 (8 bytes)
            // 8: model mat4 (64 bytes)
            // 72: normal_col0 vec4 (16 bytes)
            // 88: normal_col1 vec4 (16 bytes)
            // 104: normal_col2 vec4 (16 bytes)
            // 120: material (MaterialUniforms, 96 bytes)
            // 216: texture_handles [6]u64 (48 bytes)
            // Total: 264 bytes

            let mesh_handle = u64::from_le_bytes(entity_bytes[0..8].try_into().unwrap());
            let mesh = match state.meshes.get(mesh_handle) {
                Some(m) => m,
                None => continue,
            };

            let model: [[f32; 4]; 4] = *bytemuck::from_bytes(&entity_bytes[8..72]);
            let nc0: [f32; 4] = *bytemuck::from_bytes(&entity_bytes[72..88]);
            let nc1: [f32; 4] = *bytemuck::from_bytes(&entity_bytes[88..104]);
            let nc2: [f32; 4] = *bytemuck::from_bytes(&entity_bytes[104..120]);
            let material: openreality_gpu_shared::uniforms::MaterialUniforms =
                *bytemuck::from_bytes(&entity_bytes[120..216]);

            let tex_handles: [u64; 6] = *bytemuck::from_bytes(&entity_bytes[216..264]);

            // Look up texture views
            let mut texture_views: [Option<&wgpu::TextureView>; 6] = [None; 6];
            for (j, &handle) in tex_handles.iter().enumerate() {
                if handle != 0 {
                    if let Some(tex) = state.textures.get(handle) {
                        texture_views[j] = Some(&tex.view);
                    }
                }
            }

            gbuffer_entities.push(passes::gbuffer::GBufferEntity {
                mesh,
                per_object: openreality_gpu_shared::uniforms::PerObjectUniforms {
                    model,
                    normal_matrix_col0: nc0,
                    normal_matrix_col1: nc1,
                    normal_matrix_col2: nc2,
                    _pad: [0.0; 4],
                },
                material,
                texture_views,
            });
        }

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("GBuffer Encoder"),
        });

        passes::gbuffer::render_gbuffer_pass(
            &mut encoder,
            &dp.gbuffer,
            &dp.gbuffer_pipeline,
            &per_frame_bg,
            &dp.per_object_bgl,
            &state.material_bind_group_layout,
            &state.device,
            &state.queue,
            &state.per_object_buffer,
            &gbuffer_entities,
            &dp.default_texture_view,
            &state.default_sampler,
        );

        state.queue.submit(std::iter::once(encoder.finish()));
        0
    } else {
        -1
    }
}

/// Deferred lighting pass: fullscreen PBR lighting.
#[no_mangle]
pub extern "C" fn or_wgpu_lighting_pass(backend: u64) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let depth_sampler = &dp.depth_sampler;

        // Use SSAO if available, else use default white texture
        let ssao_view = &dp.ssao_targets.blur.color_view;
        let ssr_view = &dp.ssr_target.color_view;

        let lighting_bg = passes::lighting::create_lighting_bind_group(
            &state.device,
            &dp.lighting_bgl,
            &state.per_frame_buffer,
            &dp.gbuffer,
            ssao_view,
            ssr_view,
            &state.default_sampler,
            depth_sampler,
        );

        let light_data_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Light Data BG"),
            layout: &dp.light_data_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: state.light_buffer.as_entire_binding(),
            }],
        });

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Lighting Encoder"),
        });

        passes::lighting::render_lighting_pass(
            &mut encoder,
            &dp.lighting_target,
            &dp.lighting_pipeline,
            &lighting_bg,
            &light_data_bg,
        );

        state.queue.submit(std::iter::once(encoder.finish()));
        0
    } else {
        -1
    }
}

/// SSAO pass: compute ambient occlusion from G-Buffer.
/// `params_ptr` points to SSAOParams struct.
#[no_mangle]
pub extern "C" fn or_wgpu_ssao_pass(backend: u64, params_ptr: *const u8) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let params_size = std::mem::size_of::<openreality_gpu_shared::uniforms::SSAOParams>();
        let data = unsafe { std::slice::from_raw_parts(params_ptr, params_size) };
        state.queue.write_buffer(&dp.ssao_params_buffer, 0, data);

        // Create SSAO bind group (matches ssao.wgsl: uniform, depth, normal, noise, 2 samplers)
        let ssao_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("SSAO BG"),
            layout: &dp.ssao_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.ssao_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.gbuffer.depth_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dp.gbuffer.normal_roughness_view) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&dp.ssao_noise_view) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::Sampler(&dp.depth_sampler) },
            ],
        });

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("SSAO Encoder"),
        });
        passes::ssao::render_ssao_pass(&mut encoder, &dp.ssao_targets.ao, &dp.ssao_pipeline, &ssao_bg);

        // Blur pass
        let blur_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("SSAO Blur BG"),
            layout: &dp.ssao_blur_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.ssao_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.ssao_targets.ao.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
            ],
        });
        passes::ssao::render_ssao_blur(&mut encoder, &dp.ssao_targets.blur, &dp.ssao_blur_pipeline, &blur_bg);

        state.queue.submit(std::iter::once(encoder.finish()));
        0
    } else {
        -1
    }
}

/// SSR pass: screen-space reflections.
#[no_mangle]
pub extern "C" fn or_wgpu_ssr_pass(backend: u64, params_ptr: *const u8) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let params_size = std::mem::size_of::<openreality_gpu_shared::uniforms::SSRParams>();
        let data = unsafe { std::slice::from_raw_parts(params_ptr, params_size) };
        state.queue.write_buffer(&dp.ssr_params_buffer, 0, data);

        let ssr_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("SSR BG"),
            layout: &dp.ssr_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.ssr_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.gbuffer.depth_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dp.gbuffer.normal_roughness_view) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&dp.lighting_target.color_view) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::Sampler(&dp.depth_sampler) },
            ],
        });

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("SSR Encoder"),
        });
        passes::ssr::render_ssr_pass(&mut encoder, &dp.ssr_target, &dp.ssr_pipeline, &ssr_bg);
        state.queue.submit(std::iter::once(encoder.finish()));
        0
    } else {
        -1
    }
}

/// TAA pass: temporal anti-aliasing.
#[no_mangle]
pub extern "C" fn or_wgpu_taa_pass(backend: u64, params_ptr: *const u8) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_mut() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let params_size = std::mem::size_of::<openreality_gpu_shared::uniforms::TAAParams>();
        let data = unsafe { std::slice::from_raw_parts(params_ptr, params_size) };
        state.queue.write_buffer(&dp.taa_params_buffer, 0, data);

        let taa_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("TAA BG"),
            layout: &dp.taa_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.taa_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.lighting_target.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dp.taa_targets.history_view) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&dp.gbuffer.depth_view) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::Sampler(&dp.depth_sampler) },
            ],
        });

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("TAA Encoder"),
        });
        passes::taa::render_taa_pass(&mut encoder, &dp.taa_targets.current, &dp.taa_pipeline, &taa_bg);

        // Copy to history
        let w = dp.taa_targets.current.width;
        let h = dp.taa_targets.current.height;
        passes::taa::copy_taa_to_history(
            &mut encoder,
            &dp.taa_targets.current.color_texture,
            &dp.taa_targets.history_texture,
            w,
            h,
        );

        state.queue.submit(std::iter::once(encoder.finish()));
        dp.taa_first_frame = false;
        0
    } else {
        -1
    }
}

/// Post-process pass: bloom + tone mapping + FXAA.
#[no_mangle]
pub extern "C" fn or_wgpu_postprocess_pass(backend: u64, params_ptr: *const u8) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let params_size = std::mem::size_of::<openreality_gpu_shared::uniforms::PostProcessParams>();
        let data = unsafe { std::slice::from_raw_parts(params_ptr, params_size) };
        state.queue.write_buffer(&dp.pp_params_buffer, 0, data);

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("PostProcess Encoder"),
        });

        // Bloom extract
        let extract_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Extract BG"),
            layout: &dp.bloom_extract_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.lighting_target.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_extract(&mut encoder, &dp.bloom_targets.extract, &dp.bloom_extract_pipeline, &extract_bg);

        // Bloom blur horizontal
        let blur_h_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Blur H BG"),
            layout: &dp.bloom_blur_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.bloom_targets.extract.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_blur(&mut encoder, &dp.bloom_targets.blur_h, &dp.bloom_blur_pipeline, &blur_h_bg, "Bloom Blur H");

        // Bloom blur vertical
        let blur_v_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Blur V BG"),
            layout: &dp.bloom_blur_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.bloom_targets.blur_h.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_blur(&mut encoder, &dp.bloom_targets.blur_v, &dp.bloom_blur_pipeline, &blur_v_bg, "Bloom Blur V");

        // Bloom composite (scene + bloom)
        let composite_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Bloom Composite BG"),
            layout: &dp.bloom_composite_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.lighting_target.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&dp.bloom_targets.blur_v.color_view) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
            ],
        });
        passes::postprocess::render_bloom_composite(&mut encoder, &dp.pp_target_a, &dp.bloom_composite_pipeline, &composite_bg);

        // FXAA (no uniform buffer — just texture + sampler)
        let fxaa_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("FXAA BG"),
            layout: &dp.fxaa_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&dp.pp_target_a.color_view) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
            ],
        });
        passes::postprocess::render_fxaa(&mut encoder, &dp.pp_target_b, &dp.fxaa_pipeline, &fxaa_bg);

        state.queue.submit(std::iter::once(encoder.finish()));
        0
    } else {
        -1
    }
}

/// Forward pass: render transparent objects.
/// Same entity format as gbuffer_pass.
#[no_mangle]
pub extern "C" fn or_wgpu_forward_pass(
    backend: u64,
    entities_ptr: *const u8,
    entity_count: u32,
    entity_stride: u32,
) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(_state) = backends.get_mut(backend) {
        // Forward pass uses same entity parsing as gbuffer_pass
        // For now return success — will be filled in when Julia side packs data
        let _ = (entities_ptr, entity_count, entity_stride);
        0
    } else {
        -1
    }
}

/// Particle pass: render particle billboard quads.
/// `vertices_ptr` points to interleaved vertex data (pos3 + uv2 + color4 = 9 floats per vertex).
/// `view_ptr` and `proj_ptr` point to mat4x4<f32>.
#[no_mangle]
pub extern "C" fn or_wgpu_particle_pass(
    backend: u64,
    vertices_ptr: *const f32,
    vertex_count: u32,
    view_ptr: *const f32,
    proj_ptr: *const f32,
) -> i32 {
    if vertex_count == 0 {
        return 0;
    }
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_mut() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let float_count = (vertex_count * 9) as usize;
        let vertex_data = unsafe { std::slice::from_raw_parts(vertices_ptr, float_count) };
        let byte_size = (float_count * 4) as u64;

        // Resize VBO if needed
        if byte_size > dp.particle_vbo_size {
            dp.particle_vbo = state.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("Particle VBO"),
                size: byte_size,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            dp.particle_vbo_size = byte_size;
        }

        state.queue.write_buffer(&dp.particle_vbo, 0, bytemuck::cast_slice(vertex_data));

        // Upload view + proj
        let view_data = unsafe { std::slice::from_raw_parts(view_ptr, 16) };
        let proj_data = unsafe { std::slice::from_raw_parts(proj_ptr, 16) };
        let mut uniform_data = [0f32; 32];
        uniform_data[..16].copy_from_slice(view_data);
        uniform_data[16..32].copy_from_slice(proj_data);
        state.queue.write_buffer(&dp.particle_uniform_buffer, 0, bytemuck::cast_slice(&uniform_data));

        let particle_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Particle BG"),
            layout: &dp.particle_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: dp.particle_uniform_buffer.as_entire_binding(),
            }],
        });

        // Get surface texture for rendering
        let output = match state.surface.get_current_texture() {
            Ok(o) => o,
            Err(e) => { state.last_error = Some(format!("Surface error: {e}")); return -1; }
        };
        let surface_view = output.texture.create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Particle Encoder"),
        });

        passes::particles::render_particle_pass(
            &mut encoder,
            &surface_view,
            &dp.gbuffer.depth_view,
            &dp.particle_pipeline,
            &particle_bg,
            &dp.particle_vbo,
            vertex_count,
            false, // TODO: per-emitter additive blending
        );

        state.queue.submit(std::iter::once(encoder.finish()));
        output.present();
        0
    } else {
        -1
    }
}

/// UI pass: render 2D UI overlay.
/// `vertices_ptr` points to interleaved vertex data (pos2 + uv2 + color4 = 8 floats per vertex).
/// `draw_cmds_ptr` points to packed UIDrawCommand array.
#[no_mangle]
pub extern "C" fn or_wgpu_ui_pass(
    backend: u64,
    vertices_ptr: *const f32,
    vertex_count: u32,
    screen_width: f32,
    screen_height: f32,
) -> i32 {
    if vertex_count == 0 {
        return 0;
    }
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let _dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };
        // UI rendering will be wired up with draw commands
        let _ = (vertices_ptr, vertex_count, screen_width, screen_height);
        0
    } else {
        -1
    }
}

/// Present: blit the final post-processed result to the swapchain.
#[no_mangle]
pub extern "C" fn or_wgpu_present(backend: u64) -> i32 {
    let mut backends = BACKENDS.lock().unwrap();
    if let Some(state) = backends.get_mut(backend) {
        let dp = match state.deferred.as_ref() {
            Some(dp) => dp,
            None => { state.last_error = Some("Deferred pipeline not created".into()); return -1; }
        };

        let output = match state.surface.get_current_texture() {
            Ok(o) => o,
            Err(e) => { state.last_error = Some(format!("Surface error: {e}")); return -1; }
        };
        let surface_view = output.texture.create_view(&wgpu::TextureViewDescriptor::default());

        let present_bg = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Present BG"),
            layout: &dp.present_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: dp.pp_params_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&dp.pp_target_b.color_view) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&state.default_sampler) },
            ],
        });

        let mut encoder = state.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Present Encoder"),
        });

        passes::present::render_present_pass(&mut encoder, &surface_view, &dp.present_pipeline, &present_bg);

        state.queue.submit(std::iter::once(encoder.finish()));
        output.present();
        0
    } else {
        -1
    }
}
