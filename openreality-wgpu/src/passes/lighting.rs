//! Deferred lighting pass — fullscreen PBR lighting with Cook-Torrance BRDF.

use crate::backend::{GBuffer, RenderTarget};

/// Render the deferred lighting pass into the lighting target.
pub fn render_lighting_pass(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    lighting_bg: &wgpu::BindGroup,
    light_data_bg: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Deferred Lighting Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: &target.color_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: None,
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, lighting_bg, &[]);
    pass.set_bind_group(1, light_data_bg, &[]);

    // Full-screen triangle via vertex index (no vertex buffer needed)
    pass.draw(0..3, 0..1);
}

/// Create the lighting bind group with G-Buffer textures and SSAO/SSR.
pub fn create_lighting_bind_group(
    device: &wgpu::Device,
    layout: &wgpu::BindGroupLayout,
    per_frame_buffer: &wgpu::Buffer,
    gbuffer: &GBuffer,
    ssao_view: &wgpu::TextureView,
    ssr_view: &wgpu::TextureView,
    gbuffer_sampler: &wgpu::Sampler,
    depth_sampler: &wgpu::Sampler,
) -> wgpu::BindGroup {
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Lighting Bind Group"),
        layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: per_frame_buffer.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(&gbuffer.albedo_metallic_view),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::TextureView(&gbuffer.normal_roughness_view),
            },
            wgpu::BindGroupEntry {
                binding: 3,
                resource: wgpu::BindingResource::TextureView(&gbuffer.emissive_ao_view),
            },
            wgpu::BindGroupEntry {
                binding: 4,
                resource: wgpu::BindingResource::TextureView(&gbuffer.advanced_view),
            },
            wgpu::BindGroupEntry {
                binding: 5,
                resource: wgpu::BindingResource::TextureView(&gbuffer.depth_view),
            },
            wgpu::BindGroupEntry {
                binding: 6,
                resource: wgpu::BindingResource::TextureView(ssao_view),
            },
            wgpu::BindGroupEntry {
                binding: 7,
                resource: wgpu::BindingResource::TextureView(ssr_view),
            },
            wgpu::BindGroupEntry {
                binding: 8,
                resource: wgpu::BindingResource::Sampler(gbuffer_sampler),
            },
            wgpu::BindGroupEntry {
                binding: 9,
                resource: wgpu::BindingResource::Sampler(depth_sampler),
            },
        ],
    })
}
