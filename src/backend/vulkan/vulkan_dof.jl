# Vulkan Depth of Field pass: CoC computation, separable bokeh blur, composite

# ---- GLSL 450 DOF Shaders ----

const VK_DOF_COC_FRAG = """
#version 450

layout(set = 0, binding = 0) uniform DOFUBO {
    float focus_distance;
    float focus_range;
    float near_plane;
    float far_plane;
    int horizontal;
    float bokeh_radius;
    float _pad1, _pad2;
} params;

layout(set = 0, binding = 1) uniform sampler2D u_DepthTexture;

layout(location = 0) in vec2 fragUV;
layout(location = 0) out float outCoC;

float linearize_depth(float d)
{
    float z = d * 2.0 - 1.0;
    return (2.0 * params.near_plane * params.far_plane) /
           (params.far_plane + params.near_plane - z * (params.far_plane - params.near_plane));
}

void main()
{
    float depth = texture(u_DepthTexture, fragUV).r;
    float linear_depth = linearize_depth(depth);
    float coc = clamp(abs(linear_depth - params.focus_distance) / params.focus_range, 0.0, 1.0);
    outCoC = coc;
}
"""

const VK_DOF_BLUR_FRAG = """
#version 450

layout(set = 0, binding = 0) uniform DOFUBO {
    float focus_distance;
    float focus_range;
    float near_plane;
    float far_plane;
    int horizontal;
    float bokeh_radius;
    float _pad1, _pad2;
} params;

layout(set = 0, binding = 1) uniform sampler2D u_SceneTexture;
layout(set = 0, binding = 2) uniform sampler2D u_CoCTexture;

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 FragColor;

const float weights[9] = float[](0.0625, 0.09375, 0.125, 0.15625, 0.15625,
                                  0.15625, 0.125, 0.09375, 0.0625);

void main()
{
    vec2 texel_size = 1.0 / textureSize(u_SceneTexture, 0);
    float center_coc = texture(u_CoCTexture, fragUV).r;

    vec3 result = vec3(0.0);
    float total_weight = 0.0;

    for (int i = -4; i <= 4; ++i) {
        vec2 offset = params.horizontal == 1
            ? vec2(texel_size.x * float(i) * params.bokeh_radius, 0.0)
            : vec2(0.0, texel_size.y * float(i) * params.bokeh_radius);

        vec2 sample_uv = fragUV + offset;
        float sample_coc = texture(u_CoCTexture, sample_uv).r;

        float w = weights[i + 4] * max(center_coc, sample_coc);
        result += texture(u_SceneTexture, sample_uv).rgb * w;
        total_weight += w;
    }

    if (total_weight > 0.0)
        result /= total_weight;
    else
        result = texture(u_SceneTexture, fragUV).rgb;

    FragColor = vec4(result, 1.0);
}
"""

const VK_DOF_COMPOSITE_FRAG = """
#version 450

layout(set = 0, binding = 0) uniform DOFUBO {
    float focus_distance;
    float focus_range;
    float near_plane;
    float far_plane;
    int horizontal;
    float bokeh_radius;
    float _pad1, _pad2;
} params;

layout(set = 0, binding = 1) uniform sampler2D u_SharpTexture;
layout(set = 0, binding = 2) uniform sampler2D u_BlurredTexture;
layout(set = 0, binding = 3) uniform sampler2D u_CoCTexture;

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 FragColor;

void main()
{
    vec3 sharp = texture(u_SharpTexture, fragUV).rgb;
    vec3 blurred = texture(u_BlurredTexture, fragUV).rgb;
    float coc = texture(u_CoCTexture, fragUV).r;

    vec3 color = mix(sharp, blurred, smoothstep(0.0, 1.0, coc));
    FragColor = vec4(color, 1.0);
}
"""

# ---- DOF UBO ----

struct VulkanDOFUniforms
    focus_distance::Float32
    focus_range::Float32
    near_plane::Float32
    far_plane::Float32
    horizontal::Int32
    bokeh_radius::Float32
    _pad1::Float32
    _pad2::Float32
end

# ---- Lifecycle ----

"""
    vk_create_dof_pass(device, physical_device, width, height,
                        fullscreen_layout, descriptor_pool) -> VulkanDOFPass

Create the DOF pass with 3 render targets and 3 pipelines.
"""
function vk_create_dof_pass(device::Device, physical_device::PhysicalDevice,
                             width::Int, height::Int,
                             fullscreen_layout::DescriptorSetLayout,
                             descriptor_pool::DescriptorPool)
    half_w = max(1, width ÷ 2)
    half_h = max(1, height ÷ 2)

    # CoC target: R16F at full resolution
    coc_target = vk_create_render_target(device, physical_device, width, height;
        color_format=FORMAT_R16_SFLOAT, has_depth=false)

    # Blur targets: RGBA16F at half resolution
    blur_h_target = vk_create_render_target(device, physical_device, half_w, half_h;
        has_depth=false)
    blur_v_target = vk_create_render_target(device, physical_device, half_w, half_h;
        has_depth=false)

    # Composite target: RGBA16F at full resolution
    composite_target = vk_create_render_target(device, physical_device, width, height;
        has_depth=false)

    # CoC pipeline
    coc_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, VK_DOF_COC_FRAG,
        VulkanPipelineConfig(
            coc_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    # Blur pipeline (horizontal + vertical use same pipeline with different UBO)
    blur_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, VK_DOF_BLUR_FRAG,
        VulkanPipelineConfig(
            blur_h_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, half_w, half_h
        ))

    # Composite pipeline
    composite_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, VK_DOF_COMPOSITE_FRAG,
        VulkanPipelineConfig(
            composite_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    return VulkanDOFPass(coc_target, blur_h_target, blur_v_target, composite_target,
                          coc_pipeline, blur_pipeline, composite_pipeline,
                          width, height)
end

# ---- Rendering ----

"""
    _render_dof_pass!(cmd, backend, frame_idx, source_view, width, height) -> ImageView

Execute DOF pipeline: CoC → H blur → V blur → composite.
Returns the composited DOF result view, or source_view if DOF is disabled.
"""
function _render_dof_pass!(cmd::CommandBuffer, backend::VulkanBackend,
                            frame_idx::Int, source_view::ImageView,
                            width::Int, height::Int)
    dof = backend.dof_pass
    dof === nothing && return source_view
    config = backend.post_process_config
    config === nothing && return source_view
    !config.dof_enabled && return source_view

    dp = backend.deferred_pipeline
    dp === nothing && return source_view
    gb = dp.gbuffer
    gb === nothing && return source_view

    sampler = backend.default_texture.sampler
    half_w = max(1, width ÷ 2)
    half_h = max(1, height ÷ 2)

    # --- Pass 1: CoC computation (full res, R16F) ---
    coc_uniforms = VulkanDOFUniforms(
        config.dof_focus_distance, config.dof_focus_range,
        0.1f0, 500.0f0,  # near/far planes
        Int32(0), config.dof_bokeh_radius,
        0.0f0, 0.0f0
    )
    coc_ubo, coc_mem = vk_create_uniform_buffer(backend.device, backend.physical_device, coc_uniforms)
    push!(backend.frame_temp_buffers[frame_idx], (coc_ubo, coc_mem))

    coc_ds = vk_allocate_descriptor_set(backend.device,
        backend.transient_pools[frame_idx], backend.fullscreen_layout)
    vk_update_ubo_descriptor!(backend.device, coc_ds, 0, coc_ubo, sizeof(VulkanDOFUniforms))
    vk_update_texture_descriptor!(backend.device, coc_ds, 1, gb.depth)
    for b in 2:8
        vk_update_texture_descriptor!(backend.device, coc_ds, b, backend.default_texture)
    end

    _render_fullscreen_pass!(cmd, dof.coc_target, dof.coc_pipeline, coc_ds,
        backend.quad_buffer, width, height)

    # --- Pass 2: Horizontal blur (half res) ---
    blur_h_uniforms = VulkanDOFUniforms(
        config.dof_focus_distance, config.dof_focus_range,
        0.1f0, 500.0f0,
        Int32(1), config.dof_bokeh_radius,
        0.0f0, 0.0f0
    )
    blur_h_ubo, blur_h_mem = vk_create_uniform_buffer(backend.device, backend.physical_device, blur_h_uniforms)
    push!(backend.frame_temp_buffers[frame_idx], (blur_h_ubo, blur_h_mem))

    blur_h_ds = vk_allocate_descriptor_set(backend.device,
        backend.transient_pools[frame_idx], backend.fullscreen_layout)
    vk_update_ubo_descriptor!(backend.device, blur_h_ds, 0, blur_h_ubo, sizeof(VulkanDOFUniforms))
    vk_update_image_sampler_descriptor!(backend.device, blur_h_ds, 1, source_view, sampler)
    vk_update_image_sampler_descriptor!(backend.device, blur_h_ds, 2,
        dof.coc_target.color_view, sampler)
    for b in 3:8
        vk_update_texture_descriptor!(backend.device, blur_h_ds, b, backend.default_texture)
    end

    _render_fullscreen_pass!(cmd, dof.blur_h_target, dof.blur_pipeline, blur_h_ds,
        backend.quad_buffer, half_w, half_h)

    # --- Pass 3: Vertical blur (half res) ---
    blur_v_uniforms = VulkanDOFUniforms(
        config.dof_focus_distance, config.dof_focus_range,
        0.1f0, 500.0f0,
        Int32(0), config.dof_bokeh_radius,
        0.0f0, 0.0f0
    )
    blur_v_ubo, blur_v_mem = vk_create_uniform_buffer(backend.device, backend.physical_device, blur_v_uniforms)
    push!(backend.frame_temp_buffers[frame_idx], (blur_v_ubo, blur_v_mem))

    blur_v_ds = vk_allocate_descriptor_set(backend.device,
        backend.transient_pools[frame_idx], backend.fullscreen_layout)
    vk_update_ubo_descriptor!(backend.device, blur_v_ds, 0, blur_v_ubo, sizeof(VulkanDOFUniforms))
    vk_update_image_sampler_descriptor!(backend.device, blur_v_ds, 1,
        dof.blur_h_target.color_view, sampler)
    vk_update_image_sampler_descriptor!(backend.device, blur_v_ds, 2,
        dof.coc_target.color_view, sampler)
    for b in 3:8
        vk_update_texture_descriptor!(backend.device, blur_v_ds, b, backend.default_texture)
    end

    _render_fullscreen_pass!(cmd, dof.blur_v_target, dof.blur_pipeline, blur_v_ds,
        backend.quad_buffer, half_w, half_h)

    # --- Pass 4: Composite (full res) ---
    comp_ds = vk_allocate_descriptor_set(backend.device,
        backend.transient_pools[frame_idx], backend.fullscreen_layout)
    vk_update_ubo_descriptor!(backend.device, comp_ds, 0, coc_ubo, sizeof(VulkanDOFUniforms))
    vk_update_image_sampler_descriptor!(backend.device, comp_ds, 1, source_view, sampler)
    vk_update_image_sampler_descriptor!(backend.device, comp_ds, 2,
        dof.blur_v_target.color_view, sampler)
    vk_update_image_sampler_descriptor!(backend.device, comp_ds, 3,
        dof.coc_target.color_view, sampler)
    for b in 4:8
        vk_update_texture_descriptor!(backend.device, comp_ds, b, backend.default_texture)
    end

    _render_fullscreen_pass!(cmd, dof.composite_target, dof.composite_pipeline, comp_ds,
        backend.quad_buffer, width, height)

    return dof.composite_target.color_view
end

# ---- Cleanup ----

function vk_destroy_dof_pass!(device::Device, dof::VulkanDOFPass)
    for target in (dof.coc_target, dof.blur_h_target, dof.blur_v_target, dof.composite_target)
        vk_destroy_render_target!(device, target)
    end
    for pipeline in (dof.coc_pipeline, dof.blur_pipeline, dof.composite_pipeline)
        finalize(pipeline.pipeline)
        finalize(pipeline.pipeline_layout)
        pipeline.vert_module !== nothing && finalize(pipeline.vert_module)
        pipeline.frag_module !== nothing && finalize(pipeline.frag_module)
    end
    return nothing
end
