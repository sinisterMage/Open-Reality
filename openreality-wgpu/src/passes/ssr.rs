//! SSR pass — screen-space reflections via ray marching.

use crate::backend::RenderTarget;

/// Render SSR from G-Buffer depth + normals + lit scene.
pub fn render_ssr_pass(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("SSR Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: &target.color_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
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
