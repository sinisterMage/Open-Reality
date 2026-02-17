//! Particle rendering pass — streams vertex data each frame.

/// Render particles as billboard quads.
/// `vertex_data` is interleaved: pos3 + uv2 + color4 = 9 floats per vertex.
pub fn render_particle_pass(
    encoder: &mut wgpu::CommandEncoder,
    surface_view: &wgpu::TextureView,
    depth_view: &wgpu::TextureView,
    pipeline: &wgpu::RenderPipeline,
    uniforms_bg: &wgpu::BindGroup,
    vertex_buffer: &wgpu::Buffer,
    vertex_count: u32,
    _additive: bool,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Particle Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: surface_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Load, // Preserve scene
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Load,
                store: wgpu::StoreOp::Discard, // Read-only depth
            }),
            stencil_ops: None,
        }),
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, uniforms_bg, &[]);
    pass.set_vertex_buffer(0, vertex_buffer.slice(..));
    pass.draw(0..vertex_count, 0..1);
}
