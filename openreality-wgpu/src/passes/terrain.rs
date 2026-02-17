//! Terrain G-Buffer rendering pass — splatmap blending.

use crate::backend::{GBuffer, GPUMesh};

/// Render terrain chunks into the G-Buffer.
pub fn render_terrain_gbuffer(
    encoder: &mut wgpu::CommandEncoder,
    gbuffer: &GBuffer,
    pipeline: &wgpu::RenderPipeline,
    per_frame_bg: &wgpu::BindGroup,
    terrain_bg: &wgpu::BindGroup,
    chunks: &[&GPUMesh],
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Terrain G-Buffer Pass"),
        color_attachments: &[
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.albedo_metallic_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load, // Preserve existing G-Buffer data
                    store: wgpu::StoreOp::Store,
                },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.normal_roughness_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.emissive_ao_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.advanced_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,
                    store: wgpu::StoreOp::Store,
                },
            }),
        ],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: &gbuffer.depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Load,
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, per_frame_bg, &[]);
    pass.set_bind_group(1, terrain_bg, &[]);

    for mesh in chunks {
        pass.set_vertex_buffer(0, mesh.vertex_buffer.slice(..));
        pass.set_vertex_buffer(1, mesh.normal_buffer.slice(..));
        pass.set_vertex_buffer(2, mesh.uv_buffer.slice(..));
        pass.set_index_buffer(mesh.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        pass.draw_indexed(0..mesh.index_count, 0, 0..1);
    }
}
