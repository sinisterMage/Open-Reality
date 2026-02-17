//! Post-processing pass — bloom extract/blur/composite, tone mapping, FXAA.

use crate::backend::RenderTarget;

/// Render a generic fullscreen effect (bloom extract, blur, composite, FXAA, etc.).
pub fn render_fullscreen_effect(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
    label: &str,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some(label),
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

/// Render bloom extract pass (threshold high-intensity pixels).
pub fn render_bloom_extract(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
) {
    render_fullscreen_effect(encoder, target, pipeline, bind_group, "Bloom Extract");
}

/// Render bloom blur pass (separable Gaussian blur).
pub fn render_bloom_blur(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
    label: &str,
) {
    render_fullscreen_effect(encoder, target, pipeline, bind_group, label);
}

/// Render bloom composite pass (add bloom to scene).
pub fn render_bloom_composite(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
) {
    render_fullscreen_effect(encoder, target, pipeline, bind_group, "Bloom Composite");
}

/// Render FXAA pass.
pub fn render_fxaa(
    encoder: &mut wgpu::CommandEncoder,
    target: &RenderTarget,
    pipeline: &wgpu::RenderPipeline,
    bind_group: &wgpu::BindGroup,
) {
    render_fullscreen_effect(encoder, target, pipeline, bind_group, "FXAA");
}
