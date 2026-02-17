// Terrain G-Buffer pass — splatmap blending with up to 4 terrain layers.
// Terrain vertices are already in world space (no model matrix needed).

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

struct TerrainParams {
    num_layers: i32,
    layer0_uv_scale: f32,
    layer1_uv_scale: f32,
    layer2_uv_scale: f32,
    layer3_uv_scale: f32,
    _pad1: f32,
    _pad2: f32,
    _pad3: f32,
};

@group(0) @binding(0) var<uniform> frame: PerFrame;

@group(1) @binding(0) var<uniform> terrain: TerrainParams;
@group(1) @binding(1) var splatmap: texture_2d<f32>;
@group(1) @binding(2) var layer0_albedo: texture_2d<f32>;
@group(1) @binding(3) var layer1_albedo: texture_2d<f32>;
@group(1) @binding(4) var layer2_albedo: texture_2d<f32>;
@group(1) @binding(5) var layer3_albedo: texture_2d<f32>;
@group(1) @binding(6) var terrain_sampler: sampler;

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

// G-Buffer output matching deferred pipeline layout
struct GBufferOutput {
    @location(0) albedo_metallic: vec4<f32>,
    @location(1) normal_roughness: vec4<f32>,
    @location(2) emissive_ao: vec4<f32>,
    @location(3) advanced_material: vec4<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.world_pos = in.position;  // Terrain vertices are already in world space
    out.normal = in.normal;
    out.uv = in.uv;
    out.clip_position = frame.projection * frame.view * vec4<f32>(in.position, 1.0);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> GBufferOutput {
    // Sample splatmap weights (RGBA = 4 layers)
    let splat = textureSample(splatmap, terrain_sampler, in.uv);

    // World-space XZ for tiling (prevents stretching on slopes)
    let world_uv = in.world_pos.xz;

    // Blend albedo from layers using splatmap weights
    var albedo = vec3<f32>(0.3, 0.6, 0.2);  // Default green if no layers

    if terrain.num_layers >= 1 {
        let c0 = textureSample(layer0_albedo, terrain_sampler, world_uv * terrain.layer0_uv_scale).rgb;
        albedo = c0 * splat.r;
    }
    if terrain.num_layers >= 2 {
        let c1 = textureSample(layer1_albedo, terrain_sampler, world_uv * terrain.layer1_uv_scale).rgb;
        albedo += c1 * splat.g;
    }
    if terrain.num_layers >= 3 {
        let c2 = textureSample(layer2_albedo, terrain_sampler, world_uv * terrain.layer2_uv_scale).rgb;
        albedo += c2 * splat.b;
    }
    if terrain.num_layers >= 4 {
        let c3 = textureSample(layer3_albedo, terrain_sampler, world_uv * terrain.layer3_uv_scale).rgb;
        albedo += c3 * splat.a;
    }

    // Normalize if total weight < 1 (avoid darkening)
    var total_weight = splat.r;
    if terrain.num_layers >= 2 { total_weight += splat.g; }
    if terrain.num_layers >= 3 { total_weight += splat.b; }
    if terrain.num_layers >= 4 { total_weight += splat.a; }
    if total_weight > 0.001 {
        albedo /= total_weight;
    }

    // G-Buffer output
    var out: GBufferOutput;
    out.albedo_metallic = vec4<f32>(albedo, 0.0);   // Metallic = 0 for terrain
    out.normal_roughness = vec4<f32>(normalize(in.normal) * 0.5 + 0.5, 0.85);  // Roughness = 0.85
    out.emissive_ao = vec4<f32>(0.0, 0.0, 0.0, 1.0);  // No emissive, full AO
    out.advanced_material = vec4<f32>(0.0, 0.0, 0.0, 1.0);  // No clearcoat/SSS
    return out;
}
