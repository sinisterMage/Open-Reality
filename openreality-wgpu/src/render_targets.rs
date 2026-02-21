//! Render target creation for the deferred pipeline.
//! G-Buffer, lighting FBO, SSAO/SSR/TAA targets, bloom mip chain, DOF/motion blur targets.

use crate::backend::{GBuffer, RenderTarget};

/// HDR color format used throughout the pipeline.
pub const HDR_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
/// Depth format.
pub const DEPTH_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;
/// Single-channel float format (CoC, SSAO).
pub const R16_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::R16Float;
/// Two-channel float format (velocity buffer).
pub const RG16_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rg16Float;

/// Create G-Buffer with 4 color attachments + depth.
pub fn create_gbuffer(device: &wgpu::Device, width: u32, height: u32) -> GBuffer {
    let size = wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };

    let usage = wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING
        | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::COPY_DST;

    let albedo_metallic = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("GBuffer Albedo+Metallic"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: HDR_FORMAT,
        usage,
        view_formats: &[],
    });

    let normal_roughness = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("GBuffer Normal+Roughness"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: HDR_FORMAT,
        usage,
        view_formats: &[],
    });

    let emissive_ao = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("GBuffer Emissive+AO"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: HDR_FORMAT,
        usage,
        view_formats: &[],
    });

    let advanced = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("GBuffer Advanced Material"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: HDR_FORMAT,
        usage,
        view_formats: &[],
    });

    let depth = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("GBuffer Depth"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: DEPTH_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });

    let view_desc = wgpu::TextureViewDescriptor::default();

    GBuffer {
        albedo_metallic_view: albedo_metallic.create_view(&view_desc),
        albedo_metallic,
        normal_roughness_view: normal_roughness.create_view(&view_desc),
        normal_roughness,
        emissive_ao_view: emissive_ao.create_view(&view_desc),
        emissive_ao,
        advanced_view: advanced.create_view(&view_desc),
        advanced,
        depth_view: depth.create_view(&view_desc),
        depth,
        width,
        height,
    }
}

/// Create a single HDR render target with optional depth.
pub fn create_hdr_target(
    device: &wgpu::Device,
    width: u32,
    height: u32,
    label: &str,
    with_depth: bool,
) -> RenderTarget {
    create_render_target(device, width, height, label, HDR_FORMAT, with_depth)
}

/// Create a render target with a specific format.
pub fn create_render_target(
    device: &wgpu::Device,
    width: u32,
    height: u32,
    label: &str,
    format: wgpu::TextureFormat,
    with_depth: bool,
) -> RenderTarget {
    let size = wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };

    let color_texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING
            | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    let color_view = color_texture.create_view(&wgpu::TextureViewDescriptor::default());

    let (depth_texture, depth_view) = if with_depth {
        let dt = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(&format!("{label} Depth")),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: DEPTH_FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let dv = dt.create_view(&wgpu::TextureViewDescriptor::default());
        (Some(dt), Some(dv))
    } else {
        (None, None)
    };

    RenderTarget {
        color_texture,
        color_view,
        depth_texture,
        depth_view,
        width,
        height,
    }
}

/// SSAO targets: AO texture + blur texture.
pub struct SSAOTargets {
    pub ao: RenderTarget,
    pub blur: RenderTarget,
}

pub fn create_ssao_targets(device: &wgpu::Device, width: u32, height: u32) -> SSAOTargets {
    SSAOTargets {
        ao: create_render_target(device, width, height, "SSAO AO", R16_FORMAT, false),
        blur: create_render_target(device, width, height, "SSAO Blur", R16_FORMAT, false),
    }
}

/// SSR target: reflection color + alpha.
pub fn create_ssr_target(device: &wgpu::Device, width: u32, height: u32) -> RenderTarget {
    create_hdr_target(device, width, height, "SSR", false)
}

/// TAA targets: current + history.
pub struct TAATargets {
    pub current: RenderTarget,
    pub history_texture: wgpu::Texture,
    pub history_view: wgpu::TextureView,
}

pub fn create_taa_targets(device: &wgpu::Device, width: u32, height: u32) -> TAATargets {
    // TAA current needs COPY_SRC because we copy it to history each frame.
    let size = wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };
    let current_texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("TAA Current"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: HDR_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::TEXTURE_BINDING
            | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let current_view = current_texture.create_view(&wgpu::TextureViewDescriptor::default());
    let current = RenderTarget {
        color_texture: current_texture,
        color_view: current_view,
        depth_texture: None,
        depth_view: None,
        width,
        height,
    };

    let size = wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };
    let history_texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("TAA History"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: HDR_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::TEXTURE_BINDING
            | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    let history_view = history_texture.create_view(&wgpu::TextureViewDescriptor::default());

    TAATargets {
        current,
        history_texture,
        history_view,
    }
}

/// Bloom targets: multi-resolution mip chain for extract, blur, composite.
pub struct BloomTargets {
    pub extract: RenderTarget,
    pub blur_h: RenderTarget,
    pub blur_v: RenderTarget,
}

pub fn create_bloom_targets(device: &wgpu::Device, width: u32, height: u32) -> BloomTargets {
    let half_w = (width / 2).max(1);
    let half_h = (height / 2).max(1);
    BloomTargets {
        extract: create_hdr_target(device, half_w, half_h, "Bloom Extract", false),
        blur_h: create_hdr_target(device, half_w, half_h, "Bloom Blur H", false),
        blur_v: create_hdr_target(device, half_w, half_h, "Bloom Blur V", false),
    }
}

/// DOF targets: CoC (R16F), blur horizontal, blur vertical.
pub struct DOFTargets {
    pub coc: RenderTarget,
    pub blur_h: RenderTarget,
    pub blur_v: RenderTarget,
}

pub fn create_dof_targets(device: &wgpu::Device, width: u32, height: u32) -> DOFTargets {
    let half_w = (width / 2).max(1);
    let half_h = (height / 2).max(1);
    DOFTargets {
        coc: create_render_target(device, width, height, "DOF CoC", R16_FORMAT, false),
        blur_h: create_hdr_target(device, half_w, half_h, "DOF Blur H", false),
        blur_v: create_hdr_target(device, half_w, half_h, "DOF Blur V", false),
    }
}

/// Motion blur targets: velocity buffer (RG16F), blur output.
pub struct MotionBlurTargets {
    pub velocity: RenderTarget,
    pub blur: RenderTarget,
}

pub fn create_motion_blur_targets(
    device: &wgpu::Device,
    width: u32,
    height: u32,
) -> MotionBlurTargets {
    MotionBlurTargets {
        velocity: create_render_target(
            device,
            width,
            height,
            "Motion Blur Velocity",
            RG16_FORMAT,
            false,
        ),
        blur: create_hdr_target(device, width, height, "Motion Blur Output", false),
    }
}

/// Create a 1x1 white default texture for fallback.
pub fn create_default_texture(device: &wgpu::Device, queue: &wgpu::Queue) -> (wgpu::Texture, wgpu::TextureView) {
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("Default 1x1 White"),
        size: wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
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
        &[255u8, 255, 255, 255],
        wgpu::ImageDataLayout {
            offset: 0,
            bytes_per_row: Some(4),
            rows_per_image: Some(1),
        },
        wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
    );

    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    (texture, view)
}

/// Create a fullscreen quad vertex buffer (2 triangles, pos2 + uv2).
pub fn create_fullscreen_quad_vbo(device: &wgpu::Device) -> wgpu::Buffer {
    use wgpu::util::DeviceExt;

    // Full-screen quad: 2 triangles covering [-1,1] in clip space.
    #[rustfmt::skip]
    let vertices: [f32; 24] = [
        // pos.x, pos.y, uv.x, uv.y
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
         1.0,  1.0, 1.0, 0.0,
        -1.0, -1.0, 0.0, 1.0,
         1.0,  1.0, 1.0, 0.0,
        -1.0,  1.0, 0.0, 0.0,
    ];

    device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Fullscreen Quad VBO"),
        contents: bytemuck::cast_slice(&vertices),
        usage: wgpu::BufferUsages::VERTEX,
    })
}

/// Generate SSAO noise texture (4x4 random rotation vectors).
pub fn create_ssao_noise_texture(device: &wgpu::Device, queue: &wgpu::Queue) -> (wgpu::Texture, wgpu::TextureView) {
    use std::f32::consts::PI;

    let mut noise_data = Vec::with_capacity(4 * 4 * 4);
    // Deterministic pseudo-random for reproducibility
    for i in 0..(4 * 4) {
        let angle = (i as f32 / 16.0) * 2.0 * PI + 0.37;
        let x = angle.cos();
        let y = angle.sin();
        // Store as RGBA16Float: convert to u8 for Rgba8Unorm encoding [-1,1] -> [0,255]
        noise_data.push(((x * 0.5 + 0.5) * 255.0) as u8);
        noise_data.push(((y * 0.5 + 0.5) * 255.0) as u8);
        noise_data.push(0u8);
        noise_data.push(255u8);
    }

    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("SSAO Noise"),
        size: wgpu::Extent3d {
            width: 4,
            height: 4,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
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
        &noise_data,
        wgpu::ImageDataLayout {
            offset: 0,
            bytes_per_row: Some(4 * 4),
            rows_per_image: Some(4),
        },
        wgpu::Extent3d {
            width: 4,
            height: 4,
            depth_or_array_layers: 1,
        },
    );

    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    (texture, view)
}
