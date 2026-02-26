//! IBL (Image-Based Lighting) environment generation.
//! Generates a procedural sky cubemap and computes irradiance/prefilter maps.
//! This is a simplified version — for production, accept pre-processed HDR cubemaps.

/// IBL environment state.
pub struct IBLEnvironment {
    pub irradiance_cubemap: wgpu::Texture,
    pub irradiance_view: wgpu::TextureView,
    pub prefilter_cubemap: wgpu::Texture,
    pub prefilter_view: wgpu::TextureView,
    pub brdf_lut: wgpu::Texture,
    pub brdf_lut_view: wgpu::TextureView,
}

/// Generate a BRDF integration LUT (2D texture).
/// This is a precomputed lookup table for the split-sum approximation.
pub fn generate_brdf_lut(device: &wgpu::Device, queue: &wgpu::Queue) -> (wgpu::Texture, wgpu::TextureView) {
    let size = 256u32;
    let mut data = vec![0u8; (size * size * 4) as usize]; // RG16F packed as RGBA8 for simplicity

    for y in 0..size {
        for x in 0..size {
            let n_dot_v = (x as f32 + 0.5) / size as f32;
            let roughness = (y as f32 + 0.5) / size as f32;

            let (scale, bias) = integrate_brdf(n_dot_v.max(0.001), roughness);

            let idx = ((y * size + x) * 4) as usize;
            data[idx] = (scale.clamp(0.0, 1.0) * 255.0) as u8;
            data[idx + 1] = (bias.clamp(0.0, 1.0) * 255.0) as u8;
            data[idx + 2] = 0;
            data[idx + 3] = 255;
        }
    }

    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("BRDF LUT"),
        size: wgpu::Extent3d {
            width: size,
            height: size,
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
        &data,
        wgpu::ImageDataLayout {
            offset: 0,
            bytes_per_row: Some(4 * size),
            rows_per_image: Some(size),
        },
        wgpu::Extent3d {
            width: size,
            height: size,
            depth_or_array_layers: 1,
        },
    );

    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    (texture, view)
}

/// Generate a simple procedural sky cubemap (gradient sky).
pub fn generate_procedural_sky_cubemap(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    size: u32,
) -> (wgpu::Texture, wgpu::TextureView) {
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("Procedural Sky Cubemap"),
        size: wgpu::Extent3d {
            width: size,
            height: size,
            depth_or_array_layers: 6,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });

    // Simple gradient: sky blue at top, horizon white, ground dark
    let mut face_data = vec![0u8; (size * size * 4) as usize];

    for face in 0..6u32 {
        for y in 0..size {
            for x in 0..size {
                let dir = cubemap_direction(face, x, y, size);
                let up = dir[1]; // Y component

                // Sky gradient
                let (r, g, b) = if up > 0.0 {
                    // Sky: lerp from horizon white to zenith blue
                    let t = up;
                    (
                        lerp(0.8, 0.3, t),
                        lerp(0.85, 0.5, t),
                        lerp(0.9, 0.9, t),
                    )
                } else {
                    // Ground: dark gray
                    let t = (-up).min(1.0);
                    (
                        lerp(0.5, 0.2, t),
                        lerp(0.5, 0.2, t),
                        lerp(0.5, 0.2, t),
                    )
                };

                let idx = ((y * size + x) * 4) as usize;
                face_data[idx] = (r * 255.0) as u8;
                face_data[idx + 1] = (g * 255.0) as u8;
                face_data[idx + 2] = (b * 255.0) as u8;
                face_data[idx + 3] = 255;
            }
        }

        queue.write_texture(
            wgpu::ImageCopyTexture {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d {
                    x: 0,
                    y: 0,
                    z: face,
                },
                aspect: wgpu::TextureAspect::All,
            },
            &face_data,
            wgpu::ImageDataLayout {
                offset: 0,
                bytes_per_row: Some(4 * size),
                rows_per_image: Some(size),
            },
            wgpu::Extent3d {
                width: size,
                height: size,
                depth_or_array_layers: 1,
            },
        );
    }

    let view = texture.create_view(&wgpu::TextureViewDescriptor {
        dimension: Some(wgpu::TextureViewDimension::Cube),
        ..Default::default()
    });

    (texture, view)
}

// ---- Internal helpers ----

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

/// Get the world-space direction for a cubemap texel.
fn cubemap_direction(face: u32, x: u32, y: u32, size: u32) -> [f32; 3] {
    let u = (x as f32 + 0.5) / size as f32 * 2.0 - 1.0;
    let v = (y as f32 + 0.5) / size as f32 * 2.0 - 1.0;

    let dir = match face {
        0 => [1.0, -v, -u],   // +X
        1 => [-1.0, -v, u],   // -X
        2 => [u, 1.0, v],     // +Y
        3 => [u, -1.0, -v],   // -Y
        4 => [u, -v, 1.0],    // +Z
        _ => [-u, -v, -1.0],  // -Z
    };

    let len = (dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]).sqrt();
    [dir[0] / len, dir[1] / len, dir[2] / len]
}

/// Numerically integrate the BRDF split-sum for a given NdotV and roughness.
fn integrate_brdf(n_dot_v: f32, roughness: f32) -> (f32, f32) {
    let v = [
        (1.0 - n_dot_v * n_dot_v).sqrt(),
        0.0f32,
        n_dot_v,
    ];

    let mut a = 0.0f32;
    let mut b = 0.0f32;
    let sample_count = 64u32;

    for i in 0..sample_count {
        let xi = hammersley(i, sample_count);
        let h = importance_sample_ggx(xi, roughness);

        let l = [
            2.0 * (v[0] * h[0] + v[1] * h[1] + v[2] * h[2]) * h[0] - v[0],
            2.0 * (v[0] * h[0] + v[1] * h[1] + v[2] * h[2]) * h[1] - v[1],
            2.0 * (v[0] * h[0] + v[1] * h[1] + v[2] * h[2]) * h[2] - v[2],
        ];

        let n_dot_l = l[2].max(0.0);
        let n_dot_h = h[2].max(0.0);
        let v_dot_h = (v[0] * h[0] + v[1] * h[1] + v[2] * h[2]).max(0.0);

        if n_dot_l > 0.0 {
            let g = geometry_smith_ibl(n_dot_v, n_dot_l, roughness);
            let g_vis = (g * v_dot_h) / (n_dot_h * n_dot_v).max(0.001);
            let fc = (1.0 - v_dot_h).powi(5);

            a += (1.0 - fc) * g_vis;
            b += fc * g_vis;
        }
    }

    (a / sample_count as f32, b / sample_count as f32)
}

fn hammersley(i: u32, n: u32) -> [f32; 2] {
    [i as f32 / n as f32, radical_inverse_vdc(i)]
}

fn radical_inverse_vdc(mut bits: u32) -> f32 {
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
    bits as f32 * 2.3283064365386963e-10
}

fn importance_sample_ggx(xi: [f32; 2], roughness: f32) -> [f32; 3] {
    let a = roughness * roughness;
    let phi = 2.0 * std::f32::consts::PI * xi[0];
    let cos_theta = ((1.0 - xi[1]) / (1.0 + (a * a - 1.0) * xi[1])).sqrt();
    let sin_theta = (1.0 - cos_theta * cos_theta).sqrt();

    [phi.cos() * sin_theta, phi.sin() * sin_theta, cos_theta]
}

fn geometry_smith_ibl(n_dot_v: f32, n_dot_l: f32, roughness: f32) -> f32 {
    let k = (roughness * roughness) / 2.0;
    let ggx_v = n_dot_v / (n_dot_v * (1.0 - k) + k);
    let ggx_l = n_dot_l / (n_dot_l * (1.0 - k) + k);
    ggx_v * ggx_l
}
