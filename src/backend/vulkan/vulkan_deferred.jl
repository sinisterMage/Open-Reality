# Vulkan deferred rendering pipeline orchestration
# G-buffer geometry pass + deferred lighting + screen-space effects

# ==================================================================
# G-Buffer Shader Sources
# ==================================================================

const VK_GBUFFER_VERT = """
#version 450

layout(set = 0, binding = 0) uniform PerFrame {
    mat4 view;
    mat4 projection;
    mat4 inv_view_proj;
    vec4 camera_pos;
    float time;
    float _pad1, _pad2, _pad3;
} frame;

layout(push_constant) uniform PerObject {
    mat4 model;
    vec4 normal_matrix_col0;
    vec4 normal_matrix_col1;
    vec4 normal_matrix_col2;
} obj;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;

#ifdef FEATURE_SKINNING
layout(location = 3) in vec4 inBoneWeights;
layout(location = 4) in uvec4 inBoneIndices;

#define MAX_BONES 128
layout(set = 2, binding = 0) uniform BoneData {
    int has_skinning;
    int _pad1, _pad2, _pad3;
    mat4 bones[MAX_BONES];
} skinning;
#endif

#ifdef FEATURE_INSTANCED
layout(location = 5) in vec4 inInstanceModelCol0;
layout(location = 6) in vec4 inInstanceModelCol1;
layout(location = 7) in vec4 inInstanceModelCol2;
layout(location = 8) in vec4 inInstanceModelCol3;
layout(location = 9) in vec3 inInstanceNormalCol0;
layout(location = 10) in vec3 inInstanceNormalCol1;
layout(location = 11) in vec3 inInstanceNormalCol2;
#endif

layout(location = 0) out vec3 fragWorldPos;
layout(location = 1) out vec3 fragNormal;
layout(location = 2) out vec2 fragUV;
layout(location = 3) out vec3 fragCameraPos;

void main() {
    vec3 localPos = inPosition;
    vec3 localNormal = inNormal;

#ifdef FEATURE_SKINNING
    if (skinning.has_skinning != 0) {
        mat4 skin = skinning.bones[inBoneIndices.x] * inBoneWeights.x
                  + skinning.bones[inBoneIndices.y] * inBoneWeights.y
                  + skinning.bones[inBoneIndices.z] * inBoneWeights.z
                  + skinning.bones[inBoneIndices.w] * inBoneWeights.w;
        localPos = (skin * vec4(inPosition, 1.0)).xyz;
        localNormal = mat3(skin) * inNormal;
    }
#endif

#ifdef FEATURE_INSTANCED
    mat4 modelMatrix = mat4(inInstanceModelCol0, inInstanceModelCol1,
                            inInstanceModelCol2, inInstanceModelCol3);
    mat3 normalMat = mat3(inInstanceNormalCol0, inInstanceNormalCol1,
                           inInstanceNormalCol2);
#else
    mat4 modelMatrix = obj.model;
    mat3 normalMat = mat3(
        obj.normal_matrix_col0.xyz,
        obj.normal_matrix_col1.xyz,
        obj.normal_matrix_col2.xyz
    );
#endif

    vec4 worldPos = modelMatrix * vec4(localPos, 1.0);
    fragWorldPos = worldPos.xyz;

    fragNormal = normalize(normalMat * localNormal);
    fragUV = inUV;
    fragCameraPos = frame.camera_pos.xyz;

    gl_Position = frame.projection * frame.view * worldPos;
}
"""

const VK_GBUFFER_FRAG = """
#version 450

// Feature flags — inserted by shader variant system:
// #define FEATURE_ALBEDO_MAP
// #define FEATURE_NORMAL_MAP
// #define FEATURE_METALLIC_ROUGHNESS_MAP
// #define FEATURE_AO_MAP
// #define FEATURE_EMISSIVE_MAP
// #define FEATURE_ALPHA_CUTOFF
// #define FEATURE_CLEARCOAT
// #define FEATURE_PARALLAX_MAPPING
// #define FEATURE_SUBSURFACE

layout(set = 1, binding = 0) uniform MaterialUBO {
    vec4 albedo;
    float metallic;
    float roughness;
    float ao;
    float alpha_cutoff;
    vec4 emissive_factor;
    float clearcoat;
    float clearcoat_roughness;
    float subsurface;
    float parallax_scale;
    int has_albedo_map;
    int has_normal_map;
    int has_metallic_roughness_map;
    int has_ao_map;
    int has_emissive_map;
    int has_height_map;
    float lod_alpha;
    int _pad2;
} material;

layout(set = 1, binding = 1) uniform sampler2D albedoMap;
layout(set = 1, binding = 2) uniform sampler2D normalMap;
layout(set = 1, binding = 3) uniform sampler2D metallicRoughnessMap;
layout(set = 1, binding = 4) uniform sampler2D aoMap;
layout(set = 1, binding = 5) uniform sampler2D emissiveMap;
layout(set = 1, binding = 6) uniform sampler2D heightMap;

layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;
layout(location = 2) in vec2 fragUV;
layout(location = 3) in vec3 fragCameraPos;

// G-Buffer MRT outputs
layout(location = 0) out vec4 outAlbedoMetallic;   // RGB = albedo, A = metallic
layout(location = 1) out vec4 outNormalRoughness;   // RGB = normal (encoded), A = roughness
layout(location = 2) out vec4 outEmissiveAO;        // RGB = emissive, A = AO
layout(location = 3) out vec4 outAdvancedMaterial;  // R = clearcoat, G = subsurface, BA = reserved

// Bayer 4x4 dithering matrix for LOD crossfade
const float bayerMatrix[16] = float[16](
    0.0/16.0,  8.0/16.0,  2.0/16.0, 10.0/16.0,
    12.0/16.0, 4.0/16.0, 14.0/16.0,  6.0/16.0,
    3.0/16.0, 11.0/16.0,  1.0/16.0,  9.0/16.0,
    15.0/16.0, 7.0/16.0, 13.0/16.0,  5.0/16.0
);

void main() {
    // LOD crossfade dithering
    if (material.lod_alpha < 1.0) {
        ivec2 pixel = ivec2(gl_FragCoord.xy) % 4;
        float threshold = bayerMatrix[pixel.y * 4 + pixel.x];
        if (material.lod_alpha < threshold)
            discard;
    }

    vec2 uv = fragUV;

    // Parallax mapping
    #ifdef FEATURE_PARALLAX_MAPPING
    if (material.has_height_map != 0 && material.parallax_scale > 0.0) {
        vec3 V = normalize(fragCameraPos - fragWorldPos);
        float height = texture(heightMap, uv).r;
        uv = uv + V.xy * (height * material.parallax_scale);
    }
    #endif

    // Albedo
    vec3 albedo = material.albedo.rgb;
    float opacity = material.albedo.a;
    #ifdef FEATURE_ALBEDO_MAP
    if (material.has_albedo_map != 0) {
        vec4 texColor = texture(albedoMap, uv);
        albedo *= texColor.rgb;
        opacity *= texColor.a;
    }
    #endif

    // Alpha cutoff
    #ifdef FEATURE_ALPHA_CUTOFF
    if (material.alpha_cutoff > 0.0 && opacity < material.alpha_cutoff)
        discard;
    #endif

    // Metallic / roughness
    float metallic = material.metallic;
    float roughness = material.roughness;
    #ifdef FEATURE_METALLIC_ROUGHNESS_MAP
    if (material.has_metallic_roughness_map != 0) {
        vec2 mr = texture(metallicRoughnessMap, uv).bg;
        metallic *= mr.x;
        roughness *= mr.y;
    }
    #endif

    // Normal
    vec3 N = normalize(fragNormal);
    #ifdef FEATURE_NORMAL_MAP
    if (material.has_normal_map != 0) {
        vec3 tangentNormal = texture(normalMap, uv).xyz * 2.0 - 1.0;
        // Simple TBN from derivatives
        vec3 dPdx = dFdx(fragWorldPos);
        vec3 dPdy = dFdy(fragWorldPos);
        vec2 dUVdx = dFdx(uv);
        vec2 dUVdy = dFdy(uv);
        vec3 T = normalize(dPdx * dUVdy.y - dPdy * dUVdx.y);
        vec3 B = normalize(cross(N, T));
        mat3 TBN = mat3(T, B, N);
        N = normalize(TBN * tangentNormal);
    }
    #endif

    // Emissive
    vec3 emissive = material.emissive_factor.rgb;
    #ifdef FEATURE_EMISSIVE_MAP
    if (material.has_emissive_map != 0) {
        emissive *= texture(emissiveMap, uv).rgb;
    }
    #endif

    // AO
    float ao = material.ao;
    #ifdef FEATURE_AO_MAP
    if (material.has_ao_map != 0) {
        ao *= texture(aoMap, uv).r;
    }
    #endif

    // Write G-Buffer MRTs
    outAlbedoMetallic = vec4(albedo, metallic);
    outNormalRoughness = vec4(N * 0.5 + 0.5, roughness);
    outEmissiveAO = vec4(emissive, ao);

    float clearcoat = 0.0;
    float sss = 0.0;
    #ifdef FEATURE_CLEARCOAT
    clearcoat = material.clearcoat;
    #endif
    #ifdef FEATURE_SUBSURFACE
    sss = material.subsurface;
    #endif
    outAdvancedMaterial = vec4(clearcoat, sss, 0.0, 1.0);
}
"""

# ==================================================================
# Deferred Lighting Shader
# ==================================================================

const VK_DEFERRED_LIGHTING_FRAG = """
#version 450

// Per-frame uniforms (set 0, binding 0)
layout(set = 0, binding = 0) uniform LightPassUBO {
    mat4 view;
    mat4 projection;
    mat4 inv_view_proj;
    vec4 camera_pos;
    float time;
    float _pad1, _pad2, _pad3;
} frame;

// G-Buffer textures (set 0, bindings 1-5)
layout(set = 0, binding = 1) uniform sampler2D gAlbedoMetallic;
layout(set = 0, binding = 2) uniform sampler2D gNormalRoughness;
layout(set = 0, binding = 3) uniform sampler2D gEmissiveAO;
layout(set = 0, binding = 4) uniform sampler2D gAdvancedMaterial;
layout(set = 0, binding = 5) uniform sampler2D gDepth;
layout(set = 0, binding = 6) uniform sampler2D ssaoTexture;
layout(set = 0, binding = 7) uniform sampler2D ssrTexture;

// Light data (set 1)
struct PointLight {
    vec4 position;
    vec4 color;
    float intensity;
    float range;
    float _pad1, _pad2;
};

struct DirLight {
    vec4 direction;
    vec4 color;
    float intensity;
    float _pad1, _pad2, _pad3;
};

layout(set = 1, binding = 0) uniform LightData {
    PointLight point_lights[16];
    DirLight dir_lights[4];
    int num_point_lights;
    int num_dir_lights;
    int has_ibl;
    float ibl_intensity;
} lights;

// IBL textures (set 1, bindings 6-8)
layout(set = 1, binding = 6) uniform samplerCube irradianceMap;
layout(set = 1, binding = 7) uniform samplerCube prefilterMap;
layout(set = 1, binding = 8) uniform sampler2D brdfLUT;

layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec4 outColor;

const float PI = 3.14159265359;

vec3 reconstructWorldPos(vec2 uv, float depth) {
    vec4 clipPos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 worldPos = frame.inv_view_proj * clipPos;
    return worldPos.xyz / worldPos.w;
}

float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    return GeometrySchlickGGX(max(dot(N, V), 0.0), roughness) *
           GeometrySchlickGGX(max(dot(N, L), 0.0), roughness);
}

vec3 FresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 FresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

void main() {
    vec4 albedoMetallic = texture(gAlbedoMetallic, fragUV);
    vec4 normalRoughness = texture(gNormalRoughness, fragUV);
    vec4 emissiveAO = texture(gEmissiveAO, fragUV);
    float depth = texture(gDepth, fragUV).r;

    // Skip background pixels (no geometry rendered)
    if (depth >= 1.0) {
        outColor = vec4(0.1, 0.1, 0.1, 1.0);
        return;
    }

    vec3 albedo = albedoMetallic.rgb;
    float metallic = albedoMetallic.a;
    vec3 N = normalize(normalRoughness.rgb * 2.0 - 1.0);
    float roughness = normalRoughness.a;
    vec3 emissive = emissiveAO.rgb;
    float ao = emissiveAO.a;

    vec3 worldPos = reconstructWorldPos(fragUV, depth);
    vec3 V = normalize(frame.camera_pos.xyz - worldPos);
    vec3 F0 = mix(vec3(0.04), albedo, metallic);

    // SSAO
    float ssao = texture(ssaoTexture, fragUV).r;

    // Ambient / IBL
    vec3 Lo;
    if (lights.has_ibl != 0) {
        float NdotV = max(dot(N, V), 0.0);
        vec3 F = FresnelSchlickRoughness(NdotV, F0, roughness);
        vec3 kD_ibl = (1.0 - F) * (1.0 - metallic);

        // Diffuse IBL (irradiance map)
        vec3 irradiance = texture(irradianceMap, N).rgb;
        vec3 diffuse_ibl = irradiance * albedo;

        // Specular IBL (prefiltered env map + BRDF LUT)
        vec3 R = reflect(-V, N);
        const float MAX_REFLECTION_LOD = 4.0;
        vec3 prefilteredColor = textureLod(prefilterMap, R, roughness * MAX_REFLECTION_LOD).rgb;
        vec2 brdf = texture(brdfLUT, vec2(NdotV, roughness)).rg;
        vec3 specular_ibl = prefilteredColor * (F * brdf.x + brdf.y);

        Lo = (kD_ibl * diffuse_ibl + specular_ibl) * ao * ssao * lights.ibl_intensity;
    } else {
        Lo = vec3(0.03) * albedo * ao * ssao;
    }

    // Directional lights
    for (int i = 0; i < lights.num_dir_lights; i++) {
        vec3 L = normalize(-lights.dir_lights[i].direction.xyz);
        vec3 H = normalize(V + L);
        float NdotL = max(dot(N, L), 0.0);

        float D = DistributionGGX(N, H, roughness);
        float G = GeometrySmith(N, V, L, roughness);
        vec3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

        vec3 specular = (D * G * F) / (4.0 * max(dot(N, V), 0.0) * NdotL + 0.0001);
        vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
        vec3 radiance = lights.dir_lights[i].color.rgb * lights.dir_lights[i].intensity;
        Lo += (kD * albedo / PI + specular) * radiance * NdotL;
    }

    // Point lights
    for (int i = 0; i < lights.num_point_lights; i++) {
        vec3 lightPos = lights.point_lights[i].position.xyz;
        vec3 L = normalize(lightPos - worldPos);
        vec3 H = normalize(V + L);
        float NdotL = max(dot(N, L), 0.0);

        float dist = length(lightPos - worldPos);
        float attenuation = 1.0 / (dist * dist + 0.0001);
        float rangeFactor = clamp(1.0 - pow(dist / max(lights.point_lights[i].range, 0.001), 4.0), 0.0, 1.0);
        attenuation *= rangeFactor * rangeFactor;

        float D = DistributionGGX(N, H, roughness);
        float G = GeometrySmith(N, V, L, roughness);
        vec3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

        vec3 specular = (D * G * F) / (4.0 * max(dot(N, V), 0.0) * NdotL + 0.0001);
        vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);
        vec3 radiance = lights.point_lights[i].color.rgb * lights.point_lights[i].intensity * attenuation;
        Lo += (kD * albedo / PI + specular) * radiance * NdotL;
    }

    // Emissive
    Lo += emissive;

    // SSR contribution
    vec4 ssr = texture(ssrTexture, fragUV);
    if (ssr.a > 0.0) {
        vec3 F = FresnelSchlick(max(dot(N, V), 0.0), F0);
        Lo += ssr.rgb * F * ssr.a * (1.0 - roughness);
    }

    outColor = vec4(Lo, 1.0);
}
"""

# ==================================================================
# Deferred Pipeline Creation
# ==================================================================

"""
    vk_create_deferred_pipeline(device, physical_device, cmd_pool, queue, width, height,
                                 per_frame_layout, per_material_layout, lighting_layout,
                                 fullscreen_layout, descriptor_pool, push_constant_range,
                                 config) -> VulkanDeferredPipeline

Create the full deferred rendering pipeline.
"""
function vk_create_deferred_pipeline(device::Device, physical_device::PhysicalDevice,
                                      command_pool::CommandPool, queue::Queue,
                                      width::Int, height::Int,
                                      per_frame_layout::DescriptorSetLayout,
                                      per_material_layout::DescriptorSetLayout,
                                      lighting_layout::DescriptorSetLayout,
                                      fullscreen_layout::DescriptorSetLayout,
                                      descriptor_pool::DescriptorPool,
                                      push_constant_range::PushConstantRange,
                                      config::PostProcessConfig)
    pipeline = VulkanDeferredPipeline()

    # Create G-Buffer
    pipeline.gbuffer = vk_create_gbuffer(device, physical_device, width, height)

    # Create lighting pass render target
    pipeline.lighting_target = vk_create_render_target(device, physical_device, width, height;
                                                        color_format=FORMAT_R16G16B16A16_SFLOAT,
                                                        has_depth=false)

    # Create G-buffer shader library with compile function for Vulkan
    # Detects FEATURE_SKINNING in the source and uses skinned bindings + bone descriptor set
    compile_fn = (vert_src::String, frag_src::String) -> begin
        is_skinned = contains(vert_src, "FEATURE_SKINNING")
        is_instanced = contains(vert_src, "FEATURE_INSTANCED")
        if is_skinned
            bindings = vk_skinned_vertex_bindings()
            attributes = vk_skinned_vertex_attributes()
            layouts = [per_frame_layout, per_material_layout, per_frame_layout]
        elseif is_instanced
            bindings = vk_instanced_vertex_bindings()
            attributes = vk_instanced_vertex_attributes()
            layouts = [per_frame_layout, per_material_layout]
        else
            bindings = vk_standard_vertex_bindings()
            attributes = vk_standard_vertex_attributes()
            layouts = [per_frame_layout, per_material_layout]
        end
        vk_compile_and_create_pipeline(device, vert_src, frag_src,
            VulkanPipelineConfig(
                pipeline.gbuffer.render_pass, UInt32(0),
                bindings, attributes,
                layouts,
                [push_constant_range],
                false,  # no blend
                true,   # depth test
                true,   # depth write
                CULL_MODE_BACK_BIT,
                FRONT_FACE_CLOCKWISE,
                4,      # 4 color MRT attachments
                width, height
            ))
    end

    pipeline.gbuffer_shader_library = ShaderLibrary{VulkanShaderProgram}(
        "vulkan_gbuffer", VK_GBUFFER_VERT, VK_GBUFFER_FRAG, compile_fn
    )

    # Create deferred lighting pipeline (set 0 = fullscreen pass, set 1 = lighting data)
    pipeline.lighting_pipeline = vk_compile_and_create_pipeline(
        device, VK_FULLSCREEN_QUAD_VERT, VK_DEFERRED_LIGHTING_FRAG,
        VulkanPipelineConfig(
            pipeline.lighting_target.render_pass, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            [fullscreen_layout, lighting_layout], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, width, height
        ))

    # Create screen-space effects
    if config.ssao_enabled
        pipeline.ssao_pass = vk_create_ssao_pass(
            device, physical_device, command_pool, queue,
            width, height, fullscreen_layout, descriptor_pool)
    end

    pipeline.ssr_pass = vk_create_ssr_pass(
        device, physical_device, width, height,
        fullscreen_layout, descriptor_pool)

    pipeline.taa_pass = vk_create_taa_pass(
        device, physical_device, width, height,
        fullscreen_layout, descriptor_pool)

    return pipeline
end

"""
    vk_destroy_deferred_pipeline!(device, pipeline)

Destroy the deferred pipeline and all its resources.
"""
function vk_destroy_deferred_pipeline!(device::Device, pipeline::VulkanDeferredPipeline)
    if pipeline.gbuffer !== nothing
        vk_destroy_gbuffer!(device, pipeline.gbuffer)
    end
    if pipeline.lighting_target !== nothing
        vk_destroy_render_target!(device, pipeline.lighting_target)
    end
    if pipeline.lighting_pipeline !== nothing
        finalize(pipeline.lighting_pipeline.pipeline)
        finalize(pipeline.lighting_pipeline.pipeline_layout)
    end
    if pipeline.gbuffer_shader_library !== nothing
        for (_, variant) in pipeline.gbuffer_shader_library.variants
            finalize(variant.pipeline)
            finalize(variant.pipeline_layout)
        end
    end
    if pipeline.ssao_pass !== nothing
        vk_destroy_ssao_pass!(device, pipeline.ssao_pass)
    end
    if pipeline.ssr_pass !== nothing
        vk_destroy_ssr_pass!(device, pipeline.ssr_pass)
    end
    if pipeline.taa_pass !== nothing
        vk_destroy_taa_pass!(device, pipeline.taa_pass)
    end
    if pipeline.ibl_env !== nothing
        vk_destroy_ibl_environment!(device, pipeline.ibl_env)
    end
    return nothing
end
