//! G-Buffer geometry pass — render all opaque entities to the G-Buffer MRTs.

use crate::backend::{GBuffer, GPUMesh};
use openreality_gpu_shared::uniforms::{MaterialUniforms, PerObjectUniforms};

/// Render all opaque entities into the G-Buffer.
pub fn render_gbuffer_pass(
    encoder: &mut wgpu::CommandEncoder,
    gbuffer: &GBuffer,
    pipeline: &wgpu::RenderPipeline,
    per_frame_bg: &wgpu::BindGroup,
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
        label: Some("G-Buffer Pass"),
        color_attachments: &[
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.albedo_metallic_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                    store: wgpu::StoreOp::Store,
                },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.normal_roughness_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {
                        r: 0.5,
                        g: 0.5,
                        b: 1.0,
                        a: 0.5,
                    }),
                    store: wgpu::StoreOp::Store,
                },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.emissive_ao_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {
                        r: 0.0,
                        g: 0.0,
                        b: 0.0,
                        a: 1.0,
                    }),
                    store: wgpu::StoreOp::Store,
                },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.advanced_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                    store: wgpu::StoreOp::Store,
                },
            }),
        ],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: &gbuffer.depth_view,
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

    for entity in entities {
        // Create per-entity object buffer (can't reuse a single buffer because
        // queue.write_buffer is staged and only the last write would survive).
        let obj_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Per-Object UBO"),
            size: std::mem::size_of::<PerObjectUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&obj_buffer, 0, bytemuck::bytes_of(&entity.per_object));

        let obj_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("GBuffer Per-Object BG"),
            layout: per_object_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: obj_buffer.as_entire_binding(),
            }],
        });

        // Create material bind group with textures
        let mat_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Material UBO"),
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
            label: Some("GBuffer Material BG"),
            layout: material_bgl,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: mat_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(tex_views[0]),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(tex_views[1]),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(tex_views[2]),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::TextureView(tex_views[3]),
                },
                wgpu::BindGroupEntry {
                    binding: 5,
                    resource: wgpu::BindingResource::TextureView(tex_views[4]),
                },
                wgpu::BindGroupEntry {
                    binding: 6,
                    resource: wgpu::BindingResource::TextureView(tex_views[5]),
                },
                wgpu::BindGroupEntry {
                    binding: 7,
                    resource: wgpu::BindingResource::Sampler(default_sampler),
                },
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

/// Data needed to render one entity in the G-Buffer pass.
pub struct GBufferEntity<'a> {
    pub mesh: &'a GPUMesh,
    pub per_object: PerObjectUniforms,
    pub material: MaterialUniforms,
    /// Texture views: [albedo, normal, metallic_roughness, ao, emissive, height]
    /// None = use default white texture.
    pub texture_views: [Option<&'a wgpu::TextureView>; 6],
}

/// Render skinned entities into the G-Buffer using the skeletal animation pipeline.
/// Called after the main gbuffer pass with LoadOp::Load to preserve existing G-Buffer data.
pub fn render_gbuffer_skinned_pass(
    encoder: &mut wgpu::CommandEncoder,
    gbuffer: &GBuffer,
    pipeline: &wgpu::RenderPipeline,
    per_frame_bg: &wgpu::BindGroup,
    per_object_bgl: &wgpu::BindGroupLayout,
    material_bgl: &wgpu::BindGroupLayout,
    bone_bg: &wgpu::BindGroup,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    entities: &[GBufferEntity<'_>],
    default_texture_view: &wgpu::TextureView,
    default_sampler: &wgpu::Sampler,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("G-Buffer Skinned Pass"),
        color_attachments: &[
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.albedo_metallic_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.normal_roughness_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.emissive_ao_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.advanced_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
        ],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: &gbuffer.depth_view,
            depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store }),
            stencil_ops: None,
        }),
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, per_frame_bg, &[]);
    pass.set_bind_group(3, bone_bg, &[]);

    for entity in entities {
        if !entity.mesh.has_skinning {
            continue;
        }

        let obj_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Skinned Per-Object UBO"),
            size: std::mem::size_of::<PerObjectUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&obj_buffer, 0, bytemuck::bytes_of(&entity.per_object));

        let obj_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Skinned Per-Object BG"),
            layout: per_object_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: obj_buffer.as_entire_binding(),
            }],
        });

        let mat_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Skinned Material UBO"),
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
            label: Some("Skinned Material BG"),
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
        if let Some(ref bw) = entity.mesh.bone_weight_buffer {
            pass.set_vertex_buffer(3, bw.slice(..));
        }
        if let Some(ref bi) = entity.mesh.bone_index_buffer {
            pass.set_vertex_buffer(4, bi.slice(..));
        }
        pass.set_index_buffer(entity.mesh.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
        pass.draw_indexed(0..entity.mesh.index_count, 0, 0..1);
    }
}

/// Render an instanced batch into the G-Buffer using the instanced pipeline.
/// Called after the main gbuffer pass with LoadOp::Load to preserve existing G-Buffer data.
/// All instances share the same mesh + material; per-instance transforms come from
/// a vertex buffer at slot 3 with step_mode=Instance.
pub fn render_gbuffer_instanced_pass(
    encoder: &mut wgpu::CommandEncoder,
    gbuffer: &GBuffer,
    pipeline: &wgpu::RenderPipeline,
    per_frame_bg: &wgpu::BindGroup,
    material_bgl: &wgpu::BindGroupLayout,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    mesh: &GPUMesh,
    material: MaterialUniforms,
    texture_views: [Option<&wgpu::TextureView>; 6],
    instance_buffer: &wgpu::Buffer,
    instance_count: u32,
    default_texture_view: &wgpu::TextureView,
    default_sampler: &wgpu::Sampler,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("G-Buffer Instanced Pass"),
        color_attachments: &[
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.albedo_metallic_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.normal_roughness_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.emissive_ao_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
            Some(wgpu::RenderPassColorAttachment {
                view: &gbuffer.advanced_view,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
            }),
        ],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: &gbuffer.depth_view,
            depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store }),
            stencil_ops: None,
        }),
        ..Default::default()
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, per_frame_bg, &[]);

    // Create material bind group
    let mat_buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("Instanced Material UBO"),
        size: std::mem::size_of::<MaterialUniforms>() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    queue.write_buffer(&mat_buffer, 0, bytemuck::bytes_of(&material));

    let tex_views: Vec<&wgpu::TextureView> = texture_views
        .iter()
        .map(|v| v.unwrap_or(default_texture_view))
        .collect();

    let mat_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Instanced Material BG"),
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

    // Bind mesh vertex buffers
    pass.set_vertex_buffer(0, mesh.vertex_buffer.slice(..));
    pass.set_vertex_buffer(1, mesh.normal_buffer.slice(..));
    pass.set_vertex_buffer(2, mesh.uv_buffer.slice(..));

    // Bind instance buffer at slot 3
    pass.set_vertex_buffer(3, instance_buffer.slice(..));

    pass.set_index_buffer(mesh.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
    pass.draw_indexed(0..mesh.index_count, 0, 0..instance_count);
}
