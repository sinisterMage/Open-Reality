// Forward PBR pass — used for transparent objects in deferred mode.
// Full Cook-Torrance BRDF with CSM shadows, point + directional lights.

const PI: f32 = 3.14159265359;
const MAX_CASCADES: u32 = 4u;

struct PerFrame {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    camera_pos: vec4<f32>,
    time: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};

struct PerObject {
    model: mat4x4<f32>,
    normal_matrix_col0: vec4<f32>,
    normal_matrix_col1: vec4<f32>,
    normal_matrix_col2: vec4<f32>,
    _pad: vec4<f32>,
};

struct MaterialUBO {
    albedo: vec4<f32>,
    metallic: f32,
    roughness: f32,
    ao: f32,
    alpha_cutoff: f32,
    emissive_factor: vec4<f32>,
    clearcoat: f32,
    clearcoat_roughness: f32,
    subsurface: f32,
    parallax_scale: f32,
    has_albedo_map: i32,
    has_normal_map: i32,
    has_metallic_roughness_map: i32,
    has_ao_map: i32,
    has_emissive_map: i32,
    has_height_map: i32,
    _pad1: i32,
    _pad2: i32,
};

struct PointLight {
    position: vec4<f32>,
    color: vec4<f32>,
    intensity: f32,
    range: f32,
    _pad1: f32,
    _pad2: f32,
};

struct DirLight {
    direction: vec4<f32>,
    color: vec4<f32>,
    intensity: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};

struct LightData {
    point_lights: array<PointLight, 16>,
    dir_lights: array<DirLight, 4>,
    num_point_lights: i32,
    num_dir_lights: i32,
    has_ibl: i32,
    ibl_intensity: f32,
};

struct CascadeData {
    matrix: mat4x4<f32>,
};

struct ShadowUniforms {
    cascades: array<CascadeData, 4>,
    splits: vec4<f32>,
    num_cascades: i32,
    shadow_bias: f32,
    _pad1: f32,
    _pad2: f32,
};

// Bind group 0: per-frame
@group(0) @binding(0) var<uniform> frame: PerFrame;

// Bind group 1: material + textures
@group(1) @binding(0) var<uniform> material: MaterialUBO;
@group(1) @binding(1) var albedo_map: texture_2d<f32>;
@group(1) @binding(2) var normal_map: texture_2d<f32>;
@group(1) @binding(3) var metallic_roughness_map: texture_2d<f32>;
@group(1) @binding(4) var ao_map: texture_2d<f32>;
@group(1) @binding(5) var emissive_map: texture_2d<f32>;
@group(1) @binding(6) var height_map: texture_2d<f32>;
@group(1) @binding(7) var material_sampler: sampler;

// Bind group 2: per-object
@group(2) @binding(0) var<uniform> object: PerObject;

// Bind group 3: lights + shadows
@group(3) @binding(0) var<uniform> lights: LightData;
@group(3) @binding(1) var<uniform> shadow: ShadowUniforms;
@group(3) @binding(2) var shadow_map_0: texture_depth_2d;
@group(3) @binding(3) var shadow_map_1: texture_depth_2d;
@group(3) @binding(4) var shadow_map_2: texture_depth_2d;
@group(3) @binding(5) var shadow_map_3: texture_depth_2d;
@group(3) @binding(6) var shadow_sampler: sampler_comparison;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) world_pos: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    let world_pos = object.model * vec4<f32>(in.position, 1.0);
    out.world_pos = world_pos.xyz;

    let normal_matrix = mat3x3<f32>(
        object.normal_matrix_col0.xyz,
        object.normal_matrix_col1.xyz,
        object.normal_matrix_col2.xyz,
    );
    out.normal = normalize(normal_matrix * in.normal);
    out.uv = in.uv;
    out.clip_position = frame.projection * frame.view * world_pos;

    return out;
}

// ---- PBR BRDF functions ----

fn distribution_ggx(N: vec3<f32>, H: vec3<f32>, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let NdotH = max(dot(N, H), 0.0);
    let denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

fn geometry_schlick_ggx(NdotV: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

fn geometry_smith(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>, roughness: f32) -> f32 {
    return geometry_schlick_ggx(max(dot(N, V), 0.0), roughness) *
           geometry_schlick_ggx(max(dot(N, L), 0.0), roughness);
}

fn fresnel_schlick(cos_theta: f32, F0: vec3<f32>) -> vec3<f32> {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

fn compute_radiance(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>, radiance: vec3<f32>,
                    albedo: vec3<f32>, metallic: f32, roughness: f32, F0: vec3<f32>) -> vec3<f32> {
    let H = normalize(V + L);

    let D = distribution_ggx(N, H, roughness);
    let G = geometry_smith(N, V, L, roughness);
    let F = fresnel_schlick(max(dot(H, V), 0.0), F0);

    let specular = (D * G * F) / (4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001);
    let kD = (vec3<f32>(1.0) - F) * (1.0 - metallic);
    let NdotL = max(dot(N, L), 0.0);
    return (kD * albedo / PI + specular) * radiance * NdotL;
}

// ---- CSM Shadow ----

fn compute_shadow_for_cascade(world_pos: vec3<f32>, N: vec3<f32>, L: vec3<f32>,
                               cascade_idx: i32, cascade_matrix: mat4x4<f32>,
                               shadow_tex: texture_depth_2d) -> f32 {
    let frag_pos_light = cascade_matrix * vec4<f32>(world_pos, 1.0);
    let proj_coords = frag_pos_light.xyz / frag_pos_light.w;
    let uv = proj_coords.xy * 0.5 + 0.5;
    let depth = proj_coords.z;

    // Out of bounds check
    if depth > 1.0 || uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 {
        return 0.0;
    }

    // Slope-scaled bias
    let bias = max(0.005 * (1.0 - dot(N, L)), 0.001) / (f32(cascade_idx + 1) * 0.5 + 1.0);

    // 3x3 PCF
    let tex_size = vec2<f32>(textureDimensions(shadow_tex));
    let texel_size = 1.0 / tex_size;
    var shadow_sum = 0.0;
    for (var x = -1; x <= 1; x++) {
        for (var y = -1; y <= 1; y++) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel_size;
            shadow_sum += textureSampleCompare(shadow_tex, shadow_sampler,
                                                uv + offset, depth - bias);
        }
    }
    // textureSampleCompare returns 1.0 when NOT in shadow, so invert
    return 1.0 - shadow_sum / 9.0;
}

fn compute_csm_shadow(world_pos: vec3<f32>, N: vec3<f32>, L: vec3<f32>) -> f32 {
    if shadow.num_cascades == 0 {
        return 0.0;
    }

    let view_depth = length(frame.camera_pos.xyz - world_pos);

    // Select cascade based on view depth
    var cascade_idx = shadow.num_cascades - 1;
    if view_depth < shadow.splits.x {
        cascade_idx = 0;
    } else if view_depth < shadow.splits.y {
        cascade_idx = 1;
    } else if view_depth < shadow.splits.z {
        cascade_idx = 2;
    } else if view_depth < shadow.splits.w {
        cascade_idx = 3;
    }

    // Select shadow map and matrix (WGSL requires static texture access)
    switch cascade_idx {
        case 0: { return compute_shadow_for_cascade(world_pos, N, L, 0, shadow.cascades[0].matrix, shadow_map_0); }
        case 1: { return compute_shadow_for_cascade(world_pos, N, L, 1, shadow.cascades[1].matrix, shadow_map_1); }
        case 2: { return compute_shadow_for_cascade(world_pos, N, L, 2, shadow.cascades[2].matrix, shadow_map_2); }
        case 3: { return compute_shadow_for_cascade(world_pos, N, L, 3, shadow.cascades[3].matrix, shadow_map_3); }
        default: { return 0.0; }
    }
}

// ---- Normal mapping ----

fn get_normal_from_map(world_pos: vec3<f32>, normal: vec3<f32>, uv: vec2<f32>) -> vec3<f32> {
    if material.has_normal_map == 0 {
        return normalize(normal);
    }

    let tangent_normal = textureSample(normal_map, material_sampler, uv).xyz * 2.0 - 1.0;

    let dPdx_val = dpdx(world_pos);
    let dPdy_val = dpdy(world_pos);
    let dUVdx = dpdx(uv);
    let dUVdy = dpdy(uv);

    let N = normalize(normal);
    let T = normalize(dPdx_val * dUVdy.y - dPdy_val * dUVdx.y);
    let B = normalize(cross(N, T));
    let TBN = mat3x3<f32>(T, B, N);

    return normalize(TBN * tangent_normal);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // Albedo
    var albedo = material.albedo.rgb;
    var opacity = material.albedo.a;
    if material.has_albedo_map != 0 {
        let tex_color = textureSample(albedo_map, material_sampler, in.uv);
        albedo *= tex_color.rgb;
        opacity *= tex_color.a;
    }

    // Alpha cutoff
    if material.alpha_cutoff > 0.0 && opacity < material.alpha_cutoff {
        discard;
    }

    // Metallic / roughness
    var metallic = material.metallic;
    var roughness = material.roughness;
    if material.has_metallic_roughness_map != 0 {
        let mr = textureSample(metallic_roughness_map, material_sampler, in.uv).bg;
        metallic *= mr.x;
        roughness *= mr.y;
    }

    // AO
    var ao = material.ao;
    if material.has_ao_map != 0 {
        ao *= textureSample(ao_map, material_sampler, in.uv).r;
    }

    let N = get_normal_from_map(in.world_pos, in.normal, in.uv);
    let V = normalize(frame.camera_pos.xyz - in.world_pos);

    let F0 = mix(vec3<f32>(0.04), albedo, metallic);

    var Lo = vec3<f32>(0.0);

    // Point lights
    for (var i = 0; i < lights.num_point_lights; i++) {
        let light_pos = lights.point_lights[i].position.xyz;
        let L_vec = light_pos - in.world_pos;
        let dist = length(L_vec);
        let L = normalize(L_vec);

        var attenuation = 1.0 / (dist * dist + 0.0001);
        let range_factor = clamp(1.0 - pow(dist / max(lights.point_lights[i].range, 0.001), 4.0), 0.0, 1.0);
        attenuation *= range_factor * range_factor;

        let radiance = lights.point_lights[i].color.rgb * lights.point_lights[i].intensity * attenuation;
        Lo += compute_radiance(N, V, L, radiance, albedo, metallic, roughness, F0);
    }

    // Directional lights (first light casts shadows via CSM)
    for (var i = 0; i < lights.num_dir_lights; i++) {
        let L = normalize(-lights.dir_lights[i].direction.xyz);
        let radiance = lights.dir_lights[i].color.rgb * lights.dir_lights[i].intensity;
        var contrib = compute_radiance(N, V, L, radiance, albedo, metallic, roughness, F0);

        // Apply shadow to first directional light
        if i == 0 && shadow.num_cascades > 0 {
            let shadow_factor = compute_csm_shadow(in.world_pos, N, L);
            contrib *= (1.0 - shadow_factor);
        }

        Lo += contrib;
    }

    // Ambient
    let ambient = vec3<f32>(0.03) * albedo * ao;
    var color = ambient + Lo;

    // Emissive
    if material.has_emissive_map != 0 {
        color += textureSample(emissive_map, material_sampler, in.uv).rgb * material.emissive_factor.rgb;
    }

    // Output linear HDR — post-processing handles tone mapping and gamma
    return vec4<f32>(color, opacity);
}
