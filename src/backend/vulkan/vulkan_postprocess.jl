# Vulkan post-processing pipeline: bloom extraction/blur, tone mapping, FXAA

"""
    vk_create_post_process(device, physical_device, width, height, config,
                            fullscreen_layout, descriptor_pool) -> VulkanPostProcessPipeline

Create the full post-processing pipeline with bloom, tone mapping, and FXAA.
"""
function vk_create_post_process(device::Device, physical_device::PhysicalDevice,
                                 width::Int, height::Int, config::PostProcessConfig,
                                 fullscreen_layout::DescriptorSetLayout,
                                 descriptor_pool::DescriptorPool)
    half_w = max(1, width ÷ 2)
    half_h = max(1, height ÷ 2)

    # Scene HDR target (full resolution)
    scene_target = vk_create_render_target(device, physical_device, width, height;
                                            color_format=FORMAT_R16G16B16A16_SFLOAT, has_depth=true)

    # Bright extraction target (half resolution)
    bright_target = vk_create_render_target(device, physical_device, half_w, half_h;
                                             color_format=FORMAT_R16G16B16A16_SFLOAT, has_depth=false)

    # Two ping-pong bloom targets (half resolution)
    bloom_targets = VulkanFramebuffer[
        vk_create_render_target(device, physical_device, half_w, half_h;
                                 color_format=FORMAT_R16G16B16A16_SFLOAT, has_depth=false),
        vk_create_render_target(device, physical_device, half_w, half_h;
                                 color_format=FORMAT_R16G16B16A16_SFLOAT, has_depth=false),
    ]

    # --- Bright extraction pipeline ---
    bright_extract_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, _vk_bright_extract_frag(),
        VulkanPipelineConfig(
            bright_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, half_w, half_h
        ))

    # --- Blur pipeline (shared by both ping-pong passes) ---
    blur_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, _vk_bloom_blur_frag(),
        VulkanPipelineConfig(
            bloom_targets[1].render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, half_w, half_h
        ))

    # --- Composite pipeline (tone mapping + bloom merge) ---
    composite_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, _vk_composite_frag(),
        VulkanPipelineConfig(
            scene_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    # --- FXAA pipeline (optional) ---
    fxaa_pipeline = nothing
    if config.fxaa_enabled
        fxaa_pipeline = vk_compile_and_create_pipeline(
            device, VK_FULLSCREEN_QUAD_VERT, _vk_fxaa_frag(),
            VulkanPipelineConfig(
                scene_target.render_pass, UInt32(0),
                vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
                [fullscreen_layout], PushConstantRange[],
                false, false, false,
                CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
                1, width, height
            ))
    end

    return VulkanPostProcessPipeline(
        config, scene_target, bright_target, bloom_targets,
        composite_pipeline, bright_extract_pipeline, blur_pipeline, fxaa_pipeline,
        width, height
    )
end

function vk_destroy_post_process!(device::Device, pp::VulkanPostProcessPipeline)
    vk_destroy_render_target!(device, pp.scene_target)
    vk_destroy_render_target!(device, pp.bright_target)
    for bt in pp.bloom_targets
        vk_destroy_render_target!(device, bt)
    end
    finalize(pp.composite_pipeline.pipeline)
    finalize(pp.composite_pipeline.pipeline_layout)
    finalize(pp.bright_extract_pipeline.pipeline)
    finalize(pp.bright_extract_pipeline.pipeline_layout)
    finalize(pp.blur_pipeline.pipeline)
    finalize(pp.blur_pipeline.pipeline_layout)
    if pp.fxaa_pipeline !== nothing
        finalize(pp.fxaa_pipeline.pipeline)
        finalize(pp.fxaa_pipeline.pipeline_layout)
    end
    return nothing
end

# ==================================================================
# Post-Process Shader Sources
# ==================================================================

function _vk_bright_extract_frag()
    return """
    #version 450

    layout(set = 0, binding = 0) uniform PostProcessParams {
        float bloom_threshold;
        float bloom_intensity;
        float gamma;
        int tone_mapping_mode;
        int horizontal;
        float vignette_intensity;
        float vignette_radius;
        float vignette_softness;
        float color_brightness;
        float color_contrast;
        float color_saturation;
        float _pad1;
    } params;

    layout(set = 0, binding = 1) uniform sampler2D sceneTexture;

    layout(location = 0) in vec2 fragUV;
    layout(location = 0) out vec4 outBright;

    void main() {
        vec3 color = texture(sceneTexture, fragUV).rgb;
        float brightness = dot(color, vec3(0.2126, 0.7152, 0.0722));
        if (brightness > params.bloom_threshold) {
            outBright = vec4(color, 1.0);
        } else {
            outBright = vec4(0.0, 0.0, 0.0, 1.0);
        }
    }
    """
end

function _vk_bloom_blur_frag()
    return """
    #version 450

    layout(set = 0, binding = 0) uniform PostProcessParams {
        float bloom_threshold;
        float bloom_intensity;
        float gamma;
        int tone_mapping_mode;
        int horizontal;
        float vignette_intensity;
        float vignette_radius;
        float vignette_softness;
        float color_brightness;
        float color_contrast;
        float color_saturation;
        float _pad1;
    } params;

    layout(set = 0, binding = 1) uniform sampler2D inputTexture;

    layout(location = 0) in vec2 fragUV;
    layout(location = 0) out vec4 outBlurred;

    void main() {
        vec2 texelSize = 1.0 / textureSize(inputTexture, 0);
        const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);

        vec3 result = texture(inputTexture, fragUV).rgb * weights[0];

        if (params.horizontal != 0) {
            for (int i = 1; i < 5; i++) {
                result += texture(inputTexture, fragUV + vec2(texelSize.x * float(i), 0.0)).rgb * weights[i];
                result += texture(inputTexture, fragUV - vec2(texelSize.x * float(i), 0.0)).rgb * weights[i];
            }
        } else {
            for (int i = 1; i < 5; i++) {
                result += texture(inputTexture, fragUV + vec2(0.0, texelSize.y * float(i))).rgb * weights[i];
                result += texture(inputTexture, fragUV - vec2(0.0, texelSize.y * float(i))).rgb * weights[i];
            }
        }

        outBlurred = vec4(result, 1.0);
    }
    """
end

function _vk_composite_frag()
    return """
    #version 450

    layout(set = 0, binding = 0) uniform PostProcessParams {
        float bloom_threshold;
        float bloom_intensity;
        float gamma;
        int tone_mapping_mode;
        int horizontal;
        float vignette_intensity;
        float vignette_radius;
        float vignette_softness;
        float color_brightness;
        float color_contrast;
        float color_saturation;
        float _pad1;
    } params;

    layout(set = 0, binding = 1) uniform sampler2D sceneTexture;
    layout(set = 0, binding = 2) uniform sampler2D bloomTexture;

    layout(location = 0) in vec2 fragUV;
    layout(location = 0) out vec4 outColor;

    vec3 reinhard(vec3 color) {
        return color / (color + vec3(1.0));
    }

    vec3 aces(vec3 x) {
        float a = 2.51;
        float b = 0.03;
        float c = 2.43;
        float d = 0.59;
        float e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }

    vec3 uncharted2(vec3 x) {
        float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
        return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
    }

    void main() {
        vec3 hdrColor = texture(sceneTexture, fragUV).rgb;
        vec3 bloom = texture(bloomTexture, fragUV).rgb;

        // Add bloom
        hdrColor += bloom * params.bloom_intensity;

        // Tone mapping
        vec3 mapped;
        if (params.tone_mapping_mode == 0) {
            mapped = reinhard(hdrColor);
        } else if (params.tone_mapping_mode == 1) {
            mapped = aces(hdrColor);
        } else {
            float W = 11.2;
            mapped = uncharted2(hdrColor * 2.0) / uncharted2(vec3(W));
        }

        // Gamma correction
        mapped = pow(mapped, vec3(1.0 / params.gamma));

        // Vignette (radial darkening)
        if (params.vignette_intensity > 0.0) {
            vec2 center = fragUV - 0.5;
            float dist = length(center);
            float vignette = smoothstep(params.vignette_radius, params.vignette_radius - params.vignette_softness, dist);
            mapped *= mix(1.0, vignette, params.vignette_intensity);
        }

        // Color grading (brightness, contrast, saturation)
        mapped += params.color_brightness;
        mapped = mix(vec3(0.5), mapped, params.color_contrast);
        float luma = dot(mapped, vec3(0.2126, 0.7152, 0.0722));
        mapped = mix(vec3(luma), mapped, params.color_saturation);
        mapped = clamp(mapped, 0.0, 1.0);

        outColor = vec4(mapped, 1.0);
    }
    """
end

function _vk_fxaa_frag()
    return """
    #version 450

    layout(set = 0, binding = 0) uniform PostProcessParams {
        float bloom_threshold;
        float bloom_intensity;
        float gamma;
        int tone_mapping_mode;
        int horizontal;
        float vignette_intensity;
        float vignette_radius;
        float vignette_softness;
        float color_brightness;
        float color_contrast;
        float color_saturation;
        float _pad1;
    } params;

    layout(set = 0, binding = 1) uniform sampler2D inputTexture;

    layout(location = 0) in vec2 fragUV;
    layout(location = 0) out vec4 outColor;

    // Simplified FXAA (based on FXAA 3.11)
    void main() {
        vec2 texelSize = 1.0 / textureSize(inputTexture, 0);

        vec3 rgbNW = texture(inputTexture, fragUV + vec2(-1.0, -1.0) * texelSize).rgb;
        vec3 rgbNE = texture(inputTexture, fragUV + vec2(1.0, -1.0) * texelSize).rgb;
        vec3 rgbSW = texture(inputTexture, fragUV + vec2(-1.0, 1.0) * texelSize).rgb;
        vec3 rgbSE = texture(inputTexture, fragUV + vec2(1.0, 1.0) * texelSize).rgb;
        vec3 rgbM  = texture(inputTexture, fragUV).rgb;

        vec3 luma = vec3(0.299, 0.587, 0.114);
        float lumaNW = dot(rgbNW, luma);
        float lumaNE = dot(rgbNE, luma);
        float lumaSW = dot(rgbSW, luma);
        float lumaSE = dot(rgbSE, luma);
        float lumaM  = dot(rgbM, luma);

        float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
        float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

        float lumaRange = lumaMax - lumaMin;
        if (lumaRange < max(0.0312, lumaMax * 0.125)) {
            outColor = vec4(rgbM, 1.0);
            return;
        }

        vec2 dir;
        dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
        dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));
        float dirReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * 0.25 * 0.25, 1.0/128.0);
        float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
        dir = min(vec2(8.0), max(vec2(-8.0), dir * rcpDirMin)) * texelSize;

        vec3 rgbA = 0.5 * (
            texture(inputTexture, fragUV + dir * (1.0/3.0 - 0.5)).rgb +
            texture(inputTexture, fragUV + dir * (2.0/3.0 - 0.5)).rgb);
        vec3 rgbB = rgbA * 0.5 + 0.25 * (
            texture(inputTexture, fragUV + dir * -0.5).rgb +
            texture(inputTexture, fragUV + dir * 0.5).rgb);
        float lumaB = dot(rgbB, luma);

        if (lumaB < lumaMin || lumaB > lumaMax) {
            outColor = vec4(rgbA, 1.0);
        } else {
            outColor = vec4(rgbB, 1.0);
        }
    }
    """
end
