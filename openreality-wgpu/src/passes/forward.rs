//! Forward PBR pass — render transparent objects with blending.

use crate::backend::RenderTarget;
use crate::passes::gbuffer::GBufferEntity;
use openreality_gpu_shared::uniforms::MaterialUniforms;

/// Render transparent entities with the forward PBR pipeline.
/// Entities should be sorted back-to-front before calling.
pub fn render_forward_pass(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    depth_view: &wgpu::TextureView,
    pipeline: &wgpu::RenderPipeline,
    per_frame_bg: &wgpu::BindGroup,
    light_shadow_bg: &wgpu::BindGroup,
    per_object_bgl: &wgpu::BindGroupLayout,
    material_bgl: &wgpu::BindGroupLayout,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    per_object_buffer: &wgpu::Buffer,
    entities: &[GBufferEntity<'_>],
    default_texture_view: &wgpu::TextureView,
    default_sampler: &wgpu::Sampler,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Forward Transparent Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: &target.color_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Load, // Preserve lighting result
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Load, // Preserve G-Buffer depth
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, per_frame_bg, &[]);
    pass.set_bind_group(3, light_shadow_bg, &[]);

    for entity in entities {
        queue.write_buffer(per_object_buffer, 0, bytemuck::bytes_of(&entity.per_object));

        let obj_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Forward Per-Object BG"),
            layout: per_object_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: per_object_buffer.as_entire_binding(),
            }],
        });

        let mat_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Forward Material UBO"),
            size: std::mem::size_of::<MaterialUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&mat_buffer, 0, bytemuck::bytes_of(&entity.material));

        let tex_views: Vec<&wgpu::TextureView> = entity
            .texture_views
            .iter()
            .map(|v| v.unwrap_or(default_texture_view))
            .collect();

        let mat_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Forward Material BG"),
            layout: material_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: mat_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(tex_views[0]) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(tex_views[1]) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(tex_views[2]) },
                wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(tex_views[3]) },
                wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::TextureView(tex_views[4]) },
                wgpu::BindGroupEntry { binding: 6, resource: wgpu::BindingResource::TextureView(tex_views[5]) },
                wgpu::BindGroupEntry { binding: 7, resource: wgpu::BindingResource::Sampler(default_sampler) },
            ],
        });

        pass.set_bind_group(1, &mat_bg, &[]);
        pass.set_bind_group(2, &obj_bg, &[]);

        pass.set_vertex_buffer(0, entity.mesh.vertex_buffer.slice(..));
        pass.set_vertex_buffer(1, entity.mesh.normal_buffer.slice(..));
        pass.set_vertex_buffer(2, entity.mesh.uv_buffer.slice(..));
        pass.set_index_buffer(entity.mesh.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        pass.draw_indexed(0..entity.mesh.index_count, 0, 0..1);
    }
}
