//! SSAO pass — screen-space ambient occlusion with blur.

use crate::backend::RenderTarget;

/// Render SSAO from G-Buffer depth + normals.
pub fn render_ssao_pass(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("SSAO Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: &target.color_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::WHITE),
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: None,
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, bind_group, &[]);
    pass.draw(0..3, 0..1);
}

/// Render SSAO blur pass.
pub fn render_ssao_blur(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("SSAO Blur Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: &target.color_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::WHITE),
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: None,
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, bind_group, &[]);
    pass.draw(0..3, 0..1);
}
