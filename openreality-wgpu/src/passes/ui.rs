//! UI rendering pass — immediate-mode 2D overlay.

/// Render UI elements with orthographic projection.
/// `vertex_data` is interleaved: pos2 + uv2 + color4 = 8 floats per vertex.
pub fn render_ui_pass(
    encoder: &mut wgpu::CommandEncoder,
    surface_view: &wgpu::TextureView,
    pipeline: &wgpu::RenderPipeline,
    vertex_buffer: &wgpu::Buffer,
    draw_commands: &[UIDrawCommand],
    bind_groups: &[&wgpu::BindGroup],
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("UI Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: surface_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Load, // Preserve scene
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: None,
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_vertex_buffer(0, vertex_buffer.slice(..));

    for (i, cmd) in draw_commands.iter().enumerate() {
        if i < bind_groups.len() {
            pass.set_bind_group(0, bind_groups[i], &[]);
        }
        pass.draw(cmd.first_vertex..cmd.first_vertex + cmd.vertex_count, 0..1);
    }
}

/// A single UI draw command.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct UIDrawCommand {
    pub first_vertex: u32,
    pub vertex_count: u32,
    pub texture_handle: u64,
    pub is_font: u32,
}
