//! Cascaded shadow map depth pass.

use crate::backend::{CascadedShadowMap, GPUMesh};

/// Render shadow depth for one cascade.
pub fn render_shadow_cascade(
    encoder: &mut wgpu::CommandEncoder,
    csm: &CascadedShadowMap,
    cascade_index: usize,
    pipeline: &wgpu::RenderPipeline,
    per_frame_bg: &wgpu::BindGroup,
    per_object_bgl: &wgpu::BindGroupLayout,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    per_object_buffer: &wgpu::Buffer,
    meshes: &[(u64, &GPUMesh, [[f32; 4]; 4])], // (entity, mesh, model_matrix)
) {
    let depth_view = &csm.depth_views[cascade_index];

    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some(&format!("Shadow Cascade {cascade_index}")),
        color_attachments: &[],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Clear(1.0),
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, per_frame_bg, &[]);

    for (_, mesh, model) in meshes {
        // Create per-entity object buffer (can't reuse a single buffer because
        // queue.write_buffer is staged and only the last write would survive).
        let obj = openreality_gpu_shared::uniforms::PerObjectUniforms {
            model: *model,
            normal_matrix_col0: [0.0; 4], // Not needed for depth-only
            normal_matrix_col1: [0.0; 4],
            normal_matrix_col2: [0.0; 4],
            _pad: [0.0; 4],
        };
        let obj_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Shadow Per-Object UBO"),
            size: std::mem::size_of::<openreality_gpu_shared::uniforms::PerObjectUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&obj_buffer, 0, bytemuck::bytes_of(&obj));

        let obj_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Shadow Per-Object BG"),
            layout: per_object_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: obj_buffer.as_entire_binding(),
            }],
        });
        pass.set_bind_group(1, &obj_bg, &[]);

        pass.set_vertex_buffer(0, mesh.vertex_buffer.slice(..));
        pass.set_index_buffer(mesh.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        pass.draw_indexed(0..mesh.index_count, 0, 0..1);
    }
}
