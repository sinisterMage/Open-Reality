# Vulkan Temporal Anti-Aliasing (TAA) pass

"""
    vk_create_taa_pass(device, physical_device, width, height,
                        fullscreen_layout, descriptor_pool) -> VulkanTAAPass
"""
function vk_create_taa_pass(device::Device, physical_device::PhysicalDevice,
                             width::Int, height::Int,
                             fullscreen_layout::DescriptorSetLayout,
                             descriptor_pool::DescriptorPool)
    history_target = vk_create_render_target(device, physical_device, width, height;
                                              color_format=FORMAT_R16G16B16A16_SFLOAT, has_depth=false)
    current_target = vk_create_render_target(device, physical_device, width, height;
                                              color_format=FORMAT_R16G16B16A16_SFLOAT, has_depth=false)

    taa_ds = vk_allocate_descriptor_set(device, descriptor_pool, fullscreen_layout)

    frag_src = """
    #version 450

    layout(set = 0, binding = 0) uniform TAAParams {
        mat4 prev_view_proj;
        mat4 inv_view_proj;
        float feedback;
        int first_frame;
        float screen_width;
        float screen_height;
    } params;

    layout(set = 0, binding = 1) uniform sampler2D currentFrame;
    layout(set = 0, binding = 2) uniform sampler2D historyFrame;
    layout(set = 0, binding = 3) uniform sampler2D depthTexture;

    layout(location = 0) in vec2 fragUV;
    layout(location = 0) out vec4 outColor;

    void main() {
        vec4 currentColor = texture(currentFrame, fragUV);

        if (params.first_frame != 0) {
            outColor = currentColor;
            return;
        }

        // Reconstruct world position from depth + inverse view-projection
        float depth = texture(depthTexture, fragUV).r;
        vec4 clipPos = vec4(fragUV * 2.0 - 1.0, depth, 1.0);
        vec4 worldPos = params.inv_view_proj * clipPos;
        worldPos /= worldPos.w;

        // Reproject to previous frame's screen space
        vec4 prevClip = params.prev_view_proj * worldPos;
        vec2 historyUV = prevClip.xy / prevClip.w * 0.5 + 0.5;

        // Reject pixels that reproject outside the screen
        if (historyUV.x < 0.0 || historyUV.x > 1.0 ||
            historyUV.y < 0.0 || historyUV.y > 1.0) {
            outColor = currentColor;
            return;
        }

        vec4 historyColor = texture(historyFrame, historyUV);

        // Neighborhood clamping (3x3 AABB) to reduce ghosting
        vec2 texelSize = 1.0 / vec2(params.screen_width, params.screen_height);
        vec3 minColor = currentColor.rgb;
        vec3 maxColor = currentColor.rgb;

        for (int x = -1; x <= 1; x++) {
            for (int y = -1; y <= 1; y++) {
                vec3 neighbor = texture(currentFrame, fragUV + vec2(float(x), float(y)) * texelSize).rgb;
                minColor = min(minColor, neighbor);
                maxColor = max(maxColor, neighbor);
            }
        }

        vec3 clampedHistory = clamp(historyColor.rgb, minColor, maxColor);

        vec3 result = mix(currentColor.rgb, clampedHistory, params.feedback);
        outColor = vec4(result, 1.0);
    }
    """

    taa_pipeline = vk_compile_and_create_pipeline(device, VK_FULLSCREEN_QUAD_VERT, frag_src,
        VulkanPipelineConfig(
            current_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    return VulkanTAAPass(history_target, current_target, taa_pipeline, taa_ds,
                          0.9f0, 0, Mat4f(I), true, width, height)
end

function vk_destroy_taa_pass!(device::Device, taa::VulkanTAAPass)
    vk_destroy_render_target!(device, taa.history_target)
    vk_destroy_render_target!(device, taa.current_target)
    finalize(taa.taa_pipeline.pipeline)
    finalize(taa.taa_pipeline.pipeline_layout)
    return nothing
end
