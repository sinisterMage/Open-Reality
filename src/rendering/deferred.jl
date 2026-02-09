# Deferred Rendering Pipeline
# G-Buffer geometry pass + deferred lighting pass

# =============================================================================
# G-Buffer Geometry Pass Shaders
# =============================================================================

const GBUFFER_VERTEX_SHADER = """
#version 330 core

layout(location = 0) in vec3 a_Position;
layout(location = 1) in vec3 a_Normal;
layout(location = 2) in vec2 a_TexCoord;

uniform mat4 u_Model;
uniform mat4 u_View;
uniform mat4 u_Projection;
uniform mat3 u_NormalMatrix;

out vec3 v_WorldPos;
out vec3 v_Normal;
out vec2 v_TexCoord;

void main()
{
    vec4 worldPos = u_Model * vec4(a_Position, 1.0);
    v_WorldPos = worldPos.xyz;
    v_Normal = normalize(u_NormalMatrix * a_Normal);
    v_TexCoord = a_TexCoord;
    gl_Position = u_Projection * u_View * worldPos;
}
"""

const GBUFFER_FRAGMENT_SHADER = """
#version 330 core

// Feature flags (defined by shader permutation system)
// #define FEATURE_ALBEDO_MAP
// #define FEATURE_NORMAL_MAP
// #define FEATURE_METALLIC_ROUGHNESS_MAP
// #define FEATURE_AO_MAP
// #define FEATURE_EMISSIVE_MAP
// #define FEATURE_ALPHA_CUTOFF

in vec3 v_WorldPos;
in vec3 v_Normal;
in vec2 v_TexCoord;

// G-Buffer outputs (MRT)
layout(location = 0) out vec4 gAlbedoMetallic;
layout(location = 1) out vec4 gNormalRoughness;
layout(location = 2) out vec4 gEmissiveAO;

// Material uniforms
uniform vec3 u_Albedo;
uniform float u_Metallic;
uniform float u_Roughness;
uniform float u_AO;
uniform vec3 u_EmissiveFactor;
uniform float u_Opacity;
uniform float u_AlphaCutoff;

// Texture maps
#ifdef FEATURE_ALBEDO_MAP
uniform sampler2D u_AlbedoMap;
#endif

#ifdef FEATURE_NORMAL_MAP
uniform sampler2D u_NormalMap;
#endif

#ifdef FEATURE_METALLIC_ROUGHNESS_MAP
uniform sampler2D u_MetallicRoughnessMap;
#endif

#ifdef FEATURE_AO_MAP
uniform sampler2D u_AOMap;
#endif

#ifdef FEATURE_EMISSIVE_MAP
uniform sampler2D u_EmissiveMap;
#endif

// Normal mapping via screen-space derivatives
vec3 getNormalFromMap()
{
#ifdef FEATURE_NORMAL_MAP
    vec3 tangentNormal = texture(u_NormalMap, v_TexCoord).xyz * 2.0 - 1.0;

    vec3 Q1  = dFdx(v_WorldPos);
    vec3 Q2  = dFdy(v_WorldPos);
    vec2 st1 = dFdx(v_TexCoord);
    vec2 st2 = dFdy(v_TexCoord);

    vec3 N   = normalize(v_Normal);
    vec3 T   = normalize(Q1 * st2.t - Q2 * st1.t);
    vec3 B   = -normalize(cross(N, T));
    mat3 TBN = mat3(T, B, N);

    return normalize(TBN * tangentNormal);
#else
    return normalize(v_Normal);
#endif
}

void main()
{
    // Sample albedo
    vec3 albedo = u_Albedo;
    float alpha = u_Opacity;

#ifdef FEATURE_ALBEDO_MAP
    vec4 albedoSample = texture(u_AlbedoMap, v_TexCoord);
    albedo = pow(albedoSample.rgb, vec3(2.2)); // sRGB to linear
    alpha = u_Opacity * albedoSample.a;
#endif

#ifdef FEATURE_ALPHA_CUTOFF
    if (alpha < u_AlphaCutoff)
        discard;
#endif

    // Sample metallic and roughness
    float metallic = u_Metallic;
    float roughness = u_Roughness;

#ifdef FEATURE_METALLIC_ROUGHNESS_MAP
    vec4 mr = texture(u_MetallicRoughnessMap, v_TexCoord);
    metallic = mr.b;  // Blue channel = metallic
    roughness = mr.g; // Green channel = roughness
#endif

    // Sample AO
    float ao = u_AO;

#ifdef FEATURE_AO_MAP
    ao = texture(u_AOMap, v_TexCoord).r;
#endif

    // Sample emissive
    vec3 emissive = u_EmissiveFactor;

#ifdef FEATURE_EMISSIVE_MAP
    emissive = texture(u_EmissiveMap, v_TexCoord).rgb * u_EmissiveFactor;
#endif

    // Get world-space normal (with normal mapping if available)
    vec3 normal = getNormalFromMap();

    // Write to G-Buffer
    // Pack normal from [-1, 1] to [0, 1] for storage
    gAlbedoMetallic = vec4(albedo, metallic);
    gNormalRoughness = vec4(normal * 0.5 + 0.5, roughness);
    gEmissiveAO = vec4(emissive, ao);
}
"""

# =============================================================================
# Deferred Lighting Pass Shaders
# =============================================================================

const DEFERRED_LIGHTING_VERTEX_SHADER = """
#version 330 core

layout(location = 0) in vec2 a_Position;
layout(location = 1) in vec2 a_TexCoord;

out vec2 v_TexCoord;

void main()
{
    v_TexCoord = a_TexCoord;
    gl_Position = vec4(a_Position, 0.0, 1.0);
}
"""

const DEFERRED_LIGHTING_FRAGMENT_SHADER = """
#version 330 core

#define MAX_POINT_LIGHTS 256
#define MAX_DIR_LIGHTS 16

in vec2 v_TexCoord;
out vec4 FragColor;

// G-Buffer textures
uniform sampler2D gAlbedoMetallic;
uniform sampler2D gNormalRoughness;
uniform sampler2D gEmissiveAO;
uniform sampler2D gDepth;

// Camera
uniform vec3 u_CameraPos;
uniform mat4 u_InvViewProj;

// Point lights
uniform int u_NumPointLights;
uniform vec3 u_PointLightPositions[MAX_POINT_LIGHTS];
uniform vec3 u_PointLightColors[MAX_POINT_LIGHTS];
uniform float u_PointLightIntensities[MAX_POINT_LIGHTS];
uniform float u_PointLightRanges[MAX_POINT_LIGHTS];

// Directional lights
uniform int u_NumDirLights;
uniform vec3 u_DirLightDirections[MAX_DIR_LIGHTS];
uniform vec3 u_DirLightColors[MAX_DIR_LIGHTS];
uniform float u_DirLightIntensities[MAX_DIR_LIGHTS];

// Cascaded Shadow Mapping (CSM)
#define MAX_CASCADES 4
uniform sampler2D u_CascadeShadowMaps[MAX_CASCADES];
uniform mat4 u_CascadeMatrices[MAX_CASCADES];
uniform float u_CascadeSplits[MAX_CASCADES + 1];  // View-space split distances
uniform int u_NumCascades;
uniform int u_HasShadows;

// Image-Based Lighting (IBL)
uniform samplerCube u_IrradianceMap;
uniform samplerCube u_PrefilterMap;
uniform sampler2D u_BRDFLUT;
uniform float u_IBLIntensity;
uniform int u_HasIBL;

const float PI = 3.14159265359;

// Reconstruct world position from depth
vec3 reconstructWorldPos(vec2 texCoord, float depth)
{
    vec4 clipPos = vec4(texCoord * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 worldPos = u_InvViewProj * clipPos;
    return worldPos.xyz / worldPos.w;
}

// Normal Distribution Function: Trowbridge-Reitz GGX
float DistributionGGX(vec3 N, vec3 H, float roughness)
{
    float a  = roughness * roughness;
    float a2 = a * a;
    float NdotH  = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return a2 / max(denom, 0.0000001);
}

// Geometry Function: Schlick-GGX
float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// Geometry Function: Smith's method
float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

// Fresnel: Schlick approximation
vec3 FresnelSchlick(float cosTheta, vec3 F0)
{
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Fresnel-Schlick with roughness (for IBL)
vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Compute radiance contribution from a single light direction
vec3 computeRadiance(vec3 N, vec3 V, vec3 L, vec3 radiance,
                     vec3 albedo, float metallic, float roughness, vec3 F0)
{
    vec3 H = normalize(V + L);

    float NDF = DistributionGGX(N, H, roughness);
    float G   = GeometrySmith(N, V, L, roughness);
    vec3  F   = FresnelSchlick(max(dot(H, V), 0.0), F0);

    // Specular (Cook-Torrance)
    vec3 numerator    = NDF * G * F;
    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
    vec3 specular     = numerator / denominator;

    // Energy conservation
    vec3 kS = F;
    vec3 kD = vec3(1.0) - kS;
    kD *= 1.0 - metallic;

    float NdotL = max(dot(N, L), 0.0);
    return (kD * albedo / PI + specular) * radiance * NdotL;
}

// Helper function to compute shadow for a specific cascade (with constant index)
float computeShadowForCascade(vec3 worldPos, vec3 N, vec3 L, int cascadeIdx, sampler2D shadowMap, mat4 cascadeMatrix)
{
    // Transform to cascade's light space
    vec4 fragPosLightSpace = cascadeMatrix * vec4(worldPos, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;
    projCoords = projCoords * 0.5 + 0.5;

    // Outside shadow map range
    if (projCoords.z > 1.0 || projCoords.x < 0.0 || projCoords.x > 1.0 ||
        projCoords.y < 0.0 || projCoords.y > 1.0)
        return 0.0;

    // Adaptive bias based on cascade
    float bias = max(0.005 * (1.0 - dot(N, L)), 0.001);
    bias *= 1.0 / (float(cascadeIdx + 1) * 0.5 + 1.0);  // Reduce bias for closer cascades

    // 3x3 PCF
    float shadow = 0.0;
    vec2 texelSize = 1.0 / textureSize(shadowMap, 0);
    for (int x = -1; x <= 1; ++x)
    {
        for (int y = -1; y <= 1; ++y)
        {
            float pcfDepth = texture(shadowMap, projCoords.xy + vec2(x, y) * texelSize).r;
            shadow += projCoords.z - bias > pcfDepth ? 1.0 : 0.0;
        }
    }
    shadow /= 9.0;
    return shadow;
}

// Cascaded Shadow Map computation with 3x3 PCF
float computeShadow(vec3 worldPos, vec3 N, vec3 L, float viewDepth)
{
    if (u_HasShadows == 0 || u_NumCascades == 0)
        return 0.0;

    // Select cascade based on view-space depth
    int cascadeIndex = u_NumCascades - 1;
    for (int i = 0; i < u_NumCascades; ++i)
    {
        if (viewDepth < u_CascadeSplits[i + 1])
        {
            cascadeIndex = i;
            break;
        }
    }

    // Use switch to avoid dynamic indexing of sampler arrays (GLSL 3.3 limitation)
    switch (cascadeIndex)
    {
        case 0:
            return computeShadowForCascade(worldPos, N, L, 0, u_CascadeShadowMaps[0], u_CascadeMatrices[0]);
        case 1:
            return computeShadowForCascade(worldPos, N, L, 1, u_CascadeShadowMaps[1], u_CascadeMatrices[1]);
        case 2:
            return computeShadowForCascade(worldPos, N, L, 2, u_CascadeShadowMaps[2], u_CascadeMatrices[2]);
        case 3:
            return computeShadowForCascade(worldPos, N, L, 3, u_CascadeShadowMaps[3], u_CascadeMatrices[3]);
        default:
            return 0.0;
    }
}

void main()
{
    // Sample G-Buffer
    vec4 albedoMetallic = texture(gAlbedoMetallic, v_TexCoord);
    vec4 normalRoughness = texture(gNormalRoughness, v_TexCoord);
    vec4 emissiveAO = texture(gEmissiveAO, v_TexCoord);
    float depth = texture(gDepth, v_TexCoord).r;

    // Early exit for skybox/background (depth = 1.0)
    if (depth >= 1.0)
    {
        // TODO: Render skybox from environment map
        FragColor = vec4(0.1, 0.1, 0.1, 1.0);
        return;
    }

    // Unpack G-Buffer
    vec3 albedo = albedoMetallic.rgb;
    float metallic = albedoMetallic.a;
    vec3 normal = normalize(normalRoughness.rgb * 2.0 - 1.0); // Unpack from [0,1] to [-1,1]
    float roughness = normalRoughness.a;
    vec3 emissive = emissiveAO.rgb;
    float ao = emissiveAO.a;

    // Reconstruct world position
    vec3 worldPos = reconstructWorldPos(v_TexCoord, depth);
    vec3 V = normalize(u_CameraPos - worldPos);

    // Base reflectivity: dielectrics ~0.04, metals use albedo
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);

    vec3 Lo = vec3(0.0);

    // Point lights
    for (int i = 0; i < u_NumPointLights; ++i)
    {
        vec3 L = u_PointLightPositions[i] - worldPos;
        float dist = length(L);
        L = normalize(L);

        float attenuation = 1.0 / (dist * dist);
        float rangeFactor = clamp(1.0 - pow(dist / u_PointLightRanges[i], 4.0), 0.0, 1.0);
        attenuation *= rangeFactor * rangeFactor;

        vec3 radiance = u_PointLightColors[i] * u_PointLightIntensities[i] * attenuation;
        Lo += computeRadiance(normal, V, L, radiance, albedo, metallic, roughness, F0);
    }

    // Compute view-space depth for cascade selection
    float viewDepth = length(u_CameraPos - worldPos);

    // Directional lights
    for (int i = 0; i < u_NumDirLights; ++i)
    {
        vec3 L = normalize(-u_DirLightDirections[i]);
        vec3 radiance = u_DirLightColors[i] * u_DirLightIntensities[i];

        // Apply shadows (first directional light only)
        float shadow = (i == 0) ? computeShadow(worldPos, normal, L, viewDepth) : 0.0;
        Lo += computeRadiance(normal, V, L, radiance, albedo, metallic, roughness, F0) * (1.0 - shadow);
    }

    // Ambient lighting with IBL or fallback
    vec3 ambient = vec3(0.0);

    if (u_HasIBL > 0)
    {
        // Image-Based Lighting (split-sum approximation)
        vec3 F = fresnelSchlickRoughness(max(dot(normal, V), 0.0), F0, roughness);

        // Diffuse contribution (kD)
        vec3 kD = vec3(1.0) - F;
        kD *= 1.0 - metallic;  // Metallic surfaces don't have diffuse

        // Sample irradiance map for diffuse
        vec3 irradiance = texture(u_IrradianceMap, normal).rgb;
        vec3 diffuse = irradiance * albedo;

        // Sample prefiltered specular map based on roughness
        vec3 R = reflect(-V, normal);
        const float MAX_REFLECTION_LOD = 4.0;
        vec3 prefilteredColor = textureLod(u_PrefilterMap, R, roughness * MAX_REFLECTION_LOD).rgb;

        // Sample BRDF integration LUT
        vec2 brdf = texture(u_BRDFLUT, vec2(max(dot(normal, V), 0.0), roughness)).rg;
        vec3 specular = prefilteredColor * (F * brdf.x + brdf.y);

        // Combine diffuse and specular IBL
        ambient = (kD * diffuse + specular) * u_IBLIntensity * ao;
    }
    else
    {
        // Fallback ambient lighting (simple constant)
        ambient = vec3(0.03) * albedo * ao;
    }

    // Final color
    vec3 color = ambient + Lo + emissive;

    FragColor = vec4(color, 1.0);
}
"""

# =============================================================================
# Deferred Pipeline Structure
# =============================================================================

"""
    DeferredPipeline

Deferred rendering pipeline with G-Buffer and lighting pass.
"""
mutable struct DeferredPipeline
    # G-Buffer
    gbuffer::GBuffer

    # Lighting accumulation framebuffer (HDR)
    lighting_fbo::Framebuffer

    # Shaders
    gbuffer_shader_library::Union{ShaderLibrary, Nothing}
    lighting_shader::Union{ShaderProgram, Nothing}

    # IBL environment (optional)
    ibl_env::Union{IBLEnvironment, Nothing}

    # Screen-space reflections (optional)
    ssr_pass::Union{SSRPass, Nothing}

    # Screen-space ambient occlusion (optional)
    ssao_pass::Union{SSAOPass, Nothing}

    # Fullscreen quad for lighting pass
    quad_vao::GLuint
    quad_vbo::GLuint

    DeferredPipeline() = new(
        GBuffer(),
        Framebuffer(),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        GLuint(0),
        GLuint(0)
    )
end

"""
    create_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)

Initialize the deferred rendering pipeline.
"""
function create_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)
    # Create G-Buffer
    create_gbuffer!(pipeline.gbuffer, width, height)

    # Create lighting accumulation framebuffer (HDR)
    create_framebuffer!(pipeline.lighting_fbo, width, height)

    # Create shader library for G-Buffer pass (with permutations)
    pipeline.gbuffer_shader_library = ShaderLibrary(
        "GBuffer",
        GBUFFER_VERTEX_SHADER,
        GBUFFER_FRAGMENT_SHADER
    )

    # Create deferred lighting shader
    pipeline.lighting_shader = create_shader_program(
        DEFERRED_LIGHTING_VERTEX_SHADER,
        DEFERRED_LIGHTING_FRAGMENT_SHADER
    )

    # Create fullscreen quad for lighting pass
    quad_vertices = Float32[
        # Position    TexCoord
        -1.0, -1.0,   0.0, 0.0,
         1.0, -1.0,   1.0, 0.0,
         1.0,  1.0,   1.0, 1.0,
        -1.0, -1.0,   0.0, 0.0,
         1.0,  1.0,   1.0, 1.0,
        -1.0,  1.0,   0.0, 1.0
    ]

    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    pipeline.quad_vao = vao_ref[]

    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    pipeline.quad_vbo = vbo_ref[]

    glBindVertexArray(pipeline.quad_vao)
    glBindBuffer(GL_ARRAY_BUFFER, pipeline.quad_vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad_vertices), quad_vertices, GL_STATIC_DRAW)

    # Position attribute
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(0))
    glEnableVertexAttribArray(0)

    # TexCoord attribute
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(2 * sizeof(Float32)))
    glEnableVertexAttribArray(1)

    glBindVertexArray(GLuint(0))

    # Create SSR pass (optional, can be enabled/disabled)
    pipeline.ssr_pass = SSRPass(width=width, height=height)
    create_ssr_pass!(pipeline.ssr_pass, width, height)

    # Create SSAO pass (optional, can be enabled/disabled)
    pipeline.ssao_pass = SSAOPass(width=width, height=height)
    create_ssao_pass!(pipeline.ssao_pass, width, height)

    @info "Created deferred pipeline" width=width height=height

    return nothing
end

"""
    destroy_deferred_pipeline!(pipeline::DeferredPipeline)

Release GPU resources for the deferred pipeline.
"""
function destroy_deferred_pipeline!(pipeline::DeferredPipeline)
    destroy_gbuffer!(pipeline.gbuffer)
    destroy_framebuffer!(pipeline.lighting_fbo)

    if pipeline.gbuffer_shader_library !== nothing
        destroy_shader_library!(pipeline.gbuffer_shader_library)
        pipeline.gbuffer_shader_library = nothing
    end

    if pipeline.lighting_shader !== nothing
        destroy_shader_program!(pipeline.lighting_shader)
        pipeline.lighting_shader = nothing
    end

    if pipeline.quad_vao != GLuint(0)
        glDeleteVertexArrays(1, Ref(pipeline.quad_vao))
        pipeline.quad_vao = GLuint(0)
    end

    if pipeline.quad_vbo != GLuint(0)
        glDeleteBuffers(1, Ref(pipeline.quad_vbo))
        pipeline.quad_vbo = GLuint(0)
    end

    if pipeline.ssr_pass !== nothing
        destroy_ssr_pass!(pipeline.ssr_pass)
        pipeline.ssr_pass = nothing
    end

    if pipeline.ssao_pass !== nothing
        destroy_ssao_pass!(pipeline.ssao_pass)
        pipeline.ssao_pass = nothing
    end

    return nothing
end

"""
    resize_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)

Resize the deferred pipeline framebuffers.
"""
function resize_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)
    resize_gbuffer!(pipeline.gbuffer, width, height)
    resize_framebuffer!(pipeline.lighting_fbo, width, height)

    if pipeline.ssr_pass !== nothing
        resize_ssr_pass!(pipeline.ssr_pass, width, height)
    end

    if pipeline.ssao_pass !== nothing
        resize_ssao_pass!(pipeline.ssao_pass, width, height)
    end
end
