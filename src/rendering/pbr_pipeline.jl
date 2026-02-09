# PBR rendering pipeline
# Cook-Torrance BRDF shader sources and main render loop

const PBR_VERTEX_SHADER = """
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

const PBR_FRAGMENT_SHADER = """
#version 330 core

#define MAX_POINT_LIGHTS 16
#define MAX_DIR_LIGHTS 4

in vec3 v_WorldPos;
in vec3 v_Normal;
in vec2 v_TexCoord;

out vec4 FragColor;

// Material uniforms (fallback values when no texture)
uniform vec3 u_Albedo;
uniform float u_Metallic;
uniform float u_Roughness;
uniform float u_AO;

// Texture maps
uniform sampler2D u_AlbedoMap;
uniform sampler2D u_NormalMap;
uniform sampler2D u_MetallicRoughnessMap;
uniform sampler2D u_AOMap;
uniform sampler2D u_EmissiveMap;

// Texture flags (1 = use texture, 0 = use uniform)
uniform int u_HasAlbedoMap;
uniform int u_HasNormalMap;
uniform int u_HasMetallicRoughnessMap;
uniform int u_HasAOMap;
uniform int u_HasEmissiveMap;

uniform vec3 u_EmissiveFactor;

// Camera
uniform vec3 u_CameraPos;

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

const float PI = 3.14159265359;

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

// Normal mapping via screen-space derivatives (no stored tangents needed)
vec3 getNormalFromMap()
{
    if (u_HasNormalMap == 0) return normalize(v_Normal);

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
}

void main()
{
    // Sample or use fallback values
    vec3 albedo = u_HasAlbedoMap == 1
        ? pow(texture(u_AlbedoMap, v_TexCoord).rgb, vec3(2.2))
        : u_Albedo;
    float metallic = u_HasMetallicRoughnessMap == 1
        ? texture(u_MetallicRoughnessMap, v_TexCoord).b
        : u_Metallic;
    float roughness = u_HasMetallicRoughnessMap == 1
        ? texture(u_MetallicRoughnessMap, v_TexCoord).g
        : u_Roughness;
    float ao = u_HasAOMap == 1
        ? texture(u_AOMap, v_TexCoord).r
        : u_AO;

    vec3 N = getNormalFromMap();
    vec3 V = normalize(u_CameraPos - v_WorldPos);

    // Base reflectivity: dielectrics ~0.04, metals use albedo
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);

    vec3 Lo = vec3(0.0);

    // Point lights
    for (int i = 0; i < u_NumPointLights; ++i)
    {
        vec3 L = u_PointLightPositions[i] - v_WorldPos;
        float dist = length(L);
        L = normalize(L);

        float attenuation = 1.0 / (dist * dist);
        float rangeFactor = clamp(1.0 - pow(dist / u_PointLightRanges[i], 4.0), 0.0, 1.0);
        attenuation *= rangeFactor * rangeFactor;

        vec3 radiance = u_PointLightColors[i] * u_PointLightIntensities[i] * attenuation;
        Lo += computeRadiance(N, V, L, radiance, albedo, metallic, roughness, F0);
    }

    // Directional lights
    for (int i = 0; i < u_NumDirLights; ++i)
    {
        vec3 L = normalize(-u_DirLightDirections[i]);
        vec3 radiance = u_DirLightColors[i] * u_DirLightIntensities[i];
        Lo += computeRadiance(N, V, L, radiance, albedo, metallic, roughness, F0);
    }

    // Ambient
    vec3 ambient = vec3(0.03) * albedo * ao;
    vec3 color = ambient + Lo;

    // Emissive
    if (u_HasEmissiveMap == 1) {
        color += texture(u_EmissiveMap, v_TexCoord).rgb * u_EmissiveFactor;
    }

    // HDR tonemapping (Reinhard)
    color = color / (color + vec3(1.0));

    // Gamma correction
    color = pow(color, vec3(1.0 / 2.2));

    FragColor = vec4(color, 1.0);
}
"""

"""
    upload_lights!(sp::ShaderProgram)

Query all light components from ECS and upload to shader uniforms.
"""
function upload_lights!(sp::ShaderProgram)
    # Point lights
    point_entities = entities_with_component(PointLightComponent)
    num_point = min(length(point_entities), 16)
    set_uniform!(sp, "u_NumPointLights", Int32(num_point))

    for i in 1:num_point
        eid = point_entities[i]
        light = get_component(eid, PointLightComponent)
        world = get_world_transform(eid)
        # Extract position from column 4 of the world transform matrix
        pos = Vec3f(Float32(world[1, 4]), Float32(world[2, 4]), Float32(world[3, 4]))

        idx = i - 1
        set_uniform!(sp, "u_PointLightPositions[$idx]", pos)
        set_uniform!(sp, "u_PointLightColors[$idx]", light.color)
        set_uniform!(sp, "u_PointLightIntensities[$idx]", light.intensity)
        set_uniform!(sp, "u_PointLightRanges[$idx]", light.range)
    end

    # Directional lights
    dir_entities = entities_with_component(DirectionalLightComponent)
    num_dir = min(length(dir_entities), 4)
    set_uniform!(sp, "u_NumDirLights", Int32(num_dir))

    for i in 1:num_dir
        eid = dir_entities[i]
        light = get_component(eid, DirectionalLightComponent)

        idx = i - 1
        set_uniform!(sp, "u_DirLightDirections[$idx]", light.direction)
        set_uniform!(sp, "u_DirLightColors[$idx]", light.color)
        set_uniform!(sp, "u_DirLightIntensities[$idx]", light.intensity)
    end
end

"""
    run_render_loop!(scene::Scene; backend=OpenGLBackend(), width=1280, height=720, title="OpenReality")

Main render loop. Creates a window, initializes OpenGL, and renders the scene
until the window is closed.

If a PlayerComponent exists in the scene, FPS controls are automatically enabled:
WASD movement, mouse look, Space/Ctrl for up/down, Shift to sprint, Escape to
release cursor.
"""
function run_render_loop!(scene::Scene;
                          backend::AbstractBackend = OpenGLBackend(),
                          width::Int = 1280,
                          height::Int = 720,
                          title::String = "OpenReality")
    initialize!(backend, width=width, height=height, title=title)

    # Auto-detect player and set up FPS controller
    controller = nothing
    result = find_player_and_camera(scene)
    if result !== nothing
        player_id, camera_id = result
        controller = PlayerController(player_id, camera_id)
        capture_cursor!(backend.window)
        @info "Player controller active — WASD to move, mouse to look, Shift to sprint, Escape to release cursor"
    end

    last_time = get_time()

    try
        while !should_close(backend.window)
            # Delta time
            now = get_time()
            dt = now - last_time
            last_time = now

            poll_events!()

            # Update player
            if controller !== nothing
                # Escape toggles cursor capture
                if is_key_pressed(backend.input, KEY_ESCAPE)
                    release_cursor!(backend.window)
                end

                update_player!(controller, backend.input, dt)
            end

            # Physics step (collision detection, gravity, resolution)
            update_physics!(dt)

            render_frame!(backend, scene)
        end
    finally
        shutdown!(backend)
    end

    return nothing
end
