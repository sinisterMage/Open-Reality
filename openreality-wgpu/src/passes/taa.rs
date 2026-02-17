//! TAA pass — temporal anti-aliasing with reprojection.

use crate::backend::RenderTarget;

/// Render TAA: blend current frame with reprojected history.
pub fn render_taa_pass(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("TAA Pass"),
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
    pass.set_bind_group(0, bind_group, &[]);
    pass.draw(0..3, 0..1);
}

/// Copy TAA output to history texture for next frame's reprojection.
pub fn copy_taa_to_history(
    encoder: &mut wgpu::CommandEncoder,
    source: &wgpu::Texture,
    history: &wgpu::Texture,
    width: u32,
    height: u32,
) {
    encoder.copy_texture_to_texture(
        wgpu::ImageCopyTexture {
            texture: source,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        wgpu::ImageCopyTexture {
            texture: history,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
    );
}
