# Vulkan Motion Blur pass: velocity buffer from reprojection + directional blur

# ---- GLSL 450 Motion Blur Shaders ----

const VK_MBLUR_VELOCITY_FRAG = """
#version 450

layout(set = 0, binding = 0) uniform MotionBlurUBO {
    mat4 inv_view_proj;
    mat4 prev_view_proj;
    float max_velocity;
    int samples;
    float intensity;
    float _pad1;
} params;

layout(set = 0, binding = 1) uniform sampler2D u_DepthTexture;

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec2 outVelocity;

void main()
{
    float depth = texture(u_DepthTexture, fragUV).r;

    // Reconstruct clip-space position
    vec4 clip_pos = vec4(fragUV * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);

    // Reconstruct world-space position
    vec4 world_pos = params.inv_view_proj * clip_pos;
    world_pos /= world_pos.w;

    // Project to previous frame's clip space
    vec4 prev_clip = params.prev_view_proj * world_pos;
    prev_clip /= prev_clip.w;
    vec2 prev_uv = prev_clip.xy * 0.5 + 0.5;

    // Screen-space velocity
    vec2 velocity = fragUV - prev_uv;

    // Clamp velocity magnitude
    float speed = length(velocity);
    float max_speed = params.max_velocity / textureSize(u_DepthTexture, 0).x;
    if (speed > max_speed)
        velocity = velocity / speed * max_speed;

    outVelocity = velocity;
}
"""

const VK_MBLUR_BLUR_FRAG = """
#version 450

layout(set = 0, binding = 0) uniform MotionBlurUBO {
    mat4 inv_view_proj;
    mat4 prev_view_proj;
    float max_velocity;
    int samples;
    float intensity;
    float _pad1;
} params;

layout(set = 0, binding = 1) uniform sampler2D u_SceneTexture;
layout(set = 0, binding = 2) uniform sampler2D u_VelocityTexture;

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 FragColor;

void main()
{
    vec2 velocity = texture(u_VelocityTexture, fragUV).rg * params.intensity;

    vec3 result = texture(u_SceneTexture, fragUV).rgb;
    float total = 1.0;

    for (int i = 1; i < params.samples; ++i) {
        float t = float(i) / float(params.samples - 1) - 0.5;
        vec2 offset = velocity * t;
        result += texture(u_SceneTexture, fragUV + offset).rgb;
        total += 1.0;
    }

    FragColor = vec4(result / total, 1.0);
}
"""

# ---- Motion Blur UBO ----

struct VulkanMotionBlurUniforms
    inv_view_proj::NTuple{16, Float32}   # mat4 column-major
    prev_view_proj::NTuple{16, Float32}  # mat4 column-major
    max_velocity::Float32
    samples::Int32
    intensity::Float32
    _pad1::Float32
end

# ---- Lifecycle ----

"""
    vk_create_motion_blur_pass(device, physical_device, width, height,
                                fullscreen_layout, descriptor_pool) -> VulkanMotionBlurPass

Create the motion blur pass with velocity and blur render targets + pipelines.
"""
function vk_create_motion_blur_pass(device::Device, physical_device::PhysicalDevice,
                                     width::Int, height::Int,
                                     fullscreen_layout::DescriptorSetLayout,
                                     descriptor_pool::DescriptorPool)
    # Velocity target: RG16F at full resolution
    velocity_target = vk_create_render_target(device, physical_device, width, height;
        color_format=FORMAT_R16G16_SFLOAT, has_depth=false)

    # Blur target: RGBA16F at full resolution
    blur_target = vk_create_render_target(device, physical_device, width, height;
        has_depth=false)

    # Velocity pipeline
    velocity_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, VK_MBLUR_VELOCITY_FRAG,
        VulkanPipelineConfig(
            velocity_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    # Blur pipeline
    blur_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, VK_MBLUR_BLUR_FRAG,
        VulkanPipelineConfig(
            blur_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    return VulkanMotionBlurPass(velocity_target, blur_target,
                                 velocity_pipeline, blur_pipeline,
                                 Mat4f(I), width, height)
end

# ---- Rendering ----

"""
    _render_motion_blur_pass!(cmd, backend, frame_idx, source_view,
                               vk_proj, view, width, height) -> ImageView

Execute motion blur: velocity buffer → directional blur.
Returns the blurred result view, or source_view if motion blur is disabled.
"""
function _render_motion_blur_pass!(cmd::CommandBuffer, backend::VulkanBackend,
                                    frame_idx::Int, source_view::ImageView,
                                    vk_proj::Mat4f, view::Mat4f,
                                    width::Int, height::Int)
    mb = backend.motion_blur_pass
    mb === nothing && return source_view
    config = backend.post_process_config
    config === nothing && return source_view
    !config.motion_blur_enabled && return source_view

    dp = backend.deferred_pipeline
    dp === nothing && return source_view
    gb = dp.gbuffer
    gb === nothing && return source_view

    sampler = backend.default_texture.sampler

    # Compute current inverse view-projection
    current_vp = vk_proj * view
    inv_vp = Mat4f(inv(current_vp))

    # --- Pass 1: Velocity buffer (full res, RG16F) ---
    velocity_uniforms = VulkanMotionBlurUniforms(
        ntuple(i -> inv_vp[i], 16),
        ntuple(i -> mb.prev_view_proj[i], 16),
        config.motion_blur_max_velocity,
        Int32(config.motion_blur_samples),
        config.motion_blur_intensity,
        0.0f0
    )
    vel_ubo, vel_mem = vk_create_uniform_buffer(backend.device, backend.physical_device, velocity_uniforms)
    push!(backend.frame_temp_buffers[frame_idx], (vel_ubo, vel_mem))

    vel_ds = vk_allocate_descriptor_set(backend.device,
        backend.transient_pools[frame_idx], backend.fullscreen_layout)
    vk_update_ubo_descriptor!(backend.device, vel_ds, 0, vel_ubo, sizeof(VulkanMotionBlurUniforms))
    vk_update_texture_descriptor!(backend.device, vel_ds, 1, gb.depth)
    for b in 2:8
        vk_update_texture_descriptor!(backend.device, vel_ds, b, backend.default_texture)
    end

    _render_fullscreen_pass!(cmd, mb.velocity_target, mb.velocity_pipeline, vel_ds,
        backend.quad_buffer, width, height)

    # --- Pass 2: Directional blur (full res, RGBA16F) ---
    blur_ds = vk_allocate_descriptor_set(backend.device,
        backend.transient_pools[frame_idx], backend.fullscreen_layout)
    vk_update_ubo_descriptor!(backend.device, blur_ds, 0, vel_ubo, sizeof(VulkanMotionBlurUniforms))
    vk_update_image_sampler_descriptor!(backend.device, blur_ds, 1, source_view, sampler)
    vk_update_image_sampler_descriptor!(backend.device, blur_ds, 2,
        mb.velocity_target.color_view, sampler)
    for b in 3:8
        vk_update_texture_descriptor!(backend.device, blur_ds, b, backend.default_texture)
    end

    _render_fullscreen_pass!(cmd, mb.blur_target, mb.blur_pipeline, blur_ds,
        backend.quad_buffer, width, height)

    # Update prev_view_proj for next frame
    mb.prev_view_proj = current_vp

    return mb.blur_target.color_view
end

# ---- Cleanup ----

function vk_destroy_motion_blur_pass!(device::Device, mb::VulkanMotionBlurPass)
    vk_destroy_render_target!(device, mb.velocity_target)
    vk_destroy_render_target!(device, mb.blur_target)
    for pipeline in (mb.velocity_pipeline, mb.blur_pipeline)
        finalize(pipeline.pipeline)
        finalize(pipeline.pipeline_layout)
        pipeline.vert_module !== nothing && finalize(pipeline.vert_module)
        pipeline.frag_module !== nothing && finalize(pipeline.frag_module)
    end
    return nothing
end
