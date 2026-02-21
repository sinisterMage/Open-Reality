# Vulkan Image-Based Lighting (IBL) environment creation
# Preprocessing pipeline: equirectangular HDR → cubemap → irradiance → prefilter → BRDF LUT

# ==================================================================
# Constants
# ==================================================================

const IBL_CUBEMAP_SIZE = 512
const IBL_IRRADIANCE_SIZE = 32
const IBL_PREFILTER_SIZE = 128
const IBL_PREFILTER_MIP_LEVELS = 5
const IBL_BRDF_LUT_SIZE = 512

# Push constant struct for cubemap rendering
struct IBLPushConstants
    projection::NTuple{16, Float32}
    view::NTuple{16, Float32}
    roughness::Float32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

# 90° perspective projection (column-major, Y-flipped for Vulkan)
const _IBL_CUBE_PROJ = Mat4f(
    1.0f0, 0.0f0, 0.0f0, 0.0f0,
    0.0f0, -1.0f0, 0.0f0, 0.0f0,
    0.0f0, 0.0f0, Float32(-10.1/9.9), -1.0f0,
    0.0f0, 0.0f0, Float32(-2.0/9.9), 0.0f0
)

# View matrices for 6 cubemap faces (column-major)
# +X, -X, +Y, -Y, +Z, -Z
const _IBL_CUBE_VIEWS = Mat4f[
    Mat4f(0,0,-1,0, 0,-1,0,0, -1,0,0,0, 0,0,0,1),  # +X
    Mat4f(0,0,1,0, 0,-1,0,0, 1,0,0,0, 0,0,0,1),     # -X
    Mat4f(1,0,0,0, 0,0,-1,0, 0,1,0,0, 0,0,0,1),      # +Y
    Mat4f(1,0,0,0, 0,0,1,0, 0,-1,0,0, 0,0,0,1),      # -Y
    Mat4f(1,0,0,0, 0,-1,0,0, 0,0,-1,0, 0,0,0,1),     # +Z
    Mat4f(-1,0,0,0, 0,-1,0,0, 0,0,1,0, 0,0,0,1),     # -Z
]

# Unit cube vertices (36 vertices × 3 floats = 108 floats)
const _IBL_CUBE_VERTICES = Float32[
    # Back face (-Z)
    -1,-1,-1,  1,1,-1,  1,-1,-1,  1,1,-1,  -1,-1,-1,  -1,1,-1,
    # Front face (+Z)
    -1,-1,1,  1,-1,1,  1,1,1,  1,1,1,  -1,1,1,  -1,-1,1,
    # Left face (-X)
    -1,1,1,  -1,1,-1,  -1,-1,-1,  -1,-1,-1,  -1,-1,1,  -1,1,1,
    # Right face (+X)
    1,1,1,  1,-1,-1,  1,1,-1,  1,-1,-1,  1,1,1,  1,-1,1,
    # Bottom face (-Y)
    -1,-1,-1,  1,-1,-1,  1,-1,1,  1,-1,1,  -1,-1,1,  -1,-1,-1,
    # Top face (+Y)
    -1,1,-1,  1,1,1,  1,1,-1,  1,1,1,  -1,1,-1,  -1,1,1,
]

# ==================================================================
# GLSL 450 Shaders
# ==================================================================

const _IBL_CUBE_VERT = """
#version 450
layout(location = 0) in vec3 aPosition;
layout(location = 0) out vec3 vLocalPos;

layout(push_constant) uniform PushConstants {
    mat4 projection;
    mat4 view;
    float roughness;
    float _pad1, _pad2, _pad3;
} pc;

void main() {
    vLocalPos = aPosition;
    gl_Position = pc.projection * pc.view * vec4(aPosition, 1.0);
}
"""

const _IBL_EQUIRECT_FRAG = """
#version 450
layout(location = 0) in vec3 vLocalPos;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D equirectMap;

const float PI = 3.14159265359;

void main() {
    vec3 v = normalize(vLocalPos);
    vec2 uv = vec2(atan(v.z, v.x), asin(v.y));
    uv *= vec2(0.1591, 0.3183);
    uv += 0.5;
    outColor = vec4(texture(equirectMap, uv).rgb, 1.0);
}
"""

const _IBL_IRRADIANCE_FRAG = """
#version 450
layout(location = 0) in vec3 vLocalPos;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform samplerCube envMap;

const float PI = 3.14159265359;

void main() {
    vec3 N = normalize(vLocalPos);
    vec3 irradiance = vec3(0.0);

    vec3 up = vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(up, N));
    up = normalize(cross(N, right));

    float sampleDelta = 0.025;
    float nrSamples = 0.0;

    for (float phi = 0.0; phi < 2.0 * PI; phi += sampleDelta) {
        for (float theta = 0.0; theta < 0.5 * PI; theta += sampleDelta) {
            vec3 tangentSample = vec3(
                sin(theta) * cos(phi),
                sin(theta) * sin(phi),
                cos(theta)
            );
            vec3 sampleVec = tangentSample.x * right + tangentSample.y * up + tangentSample.z * N;
            irradiance += texture(envMap, sampleVec).rgb * cos(theta) * sin(theta);
            nrSamples++;
        }
    }

    irradiance = PI * irradiance / nrSamples;
    outColor = vec4(irradiance, 1.0);
}
"""

const _IBL_PREFILTER_FRAG = """
#version 450
layout(location = 0) in vec3 vLocalPos;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform samplerCube envMap;

layout(push_constant) uniform PushConstants {
    mat4 projection;
    mat4 view;
    float roughness;
    float _pad1, _pad2, _pad3;
} pc;

const float PI = 3.14159265359;
const uint SAMPLE_COUNT = 1024u;

float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

float RadicalInverse_VdC(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

vec2 Hammersley(uint i, uint N) {
    return vec2(float(i) / float(N), RadicalInverse_VdC(i));
}

vec3 ImportanceSampleGGX(vec2 Xi, vec3 N, float roughness) {
    float a = roughness * roughness;
    float phi = 2.0 * PI * Xi.x;
    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

    vec3 H = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, N));
    vec3 bitangent = cross(N, tangent);

    return normalize(tangent * H.x + bitangent * H.y + N * H.z);
}

void main() {
    vec3 N = normalize(vLocalPos);
    vec3 R = N;
    vec3 V = R;

    float totalWeight = 0.0;
    vec3 prefilteredColor = vec3(0.0);

    for (uint i = 0u; i < SAMPLE_COUNT; i++) {
        vec2 Xi = Hammersley(i, SAMPLE_COUNT);
        vec3 H = ImportanceSampleGGX(Xi, N, pc.roughness);
        vec3 L = normalize(2.0 * dot(V, H) * H - V);

        float NdotL = max(dot(N, L), 0.0);
        if (NdotL > 0.0) {
            prefilteredColor += texture(envMap, L).rgb * NdotL;
            totalWeight += NdotL;
        }
    }

    prefilteredColor /= max(totalWeight, 0.001);
    outColor = vec4(prefilteredColor, 1.0);
}
"""

const _IBL_BRDF_VERT = """
#version 450
layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 0) out vec2 fragUV;
void main() {
    fragUV = inUV;
    gl_Position = vec4(inPosition, 0.0, 1.0);
}
"""

const _IBL_BRDF_FRAG = """
#version 450
layout(location = 0) in vec2 fragUV;
layout(location = 0) out vec2 outBRDF;

const float PI = 3.14159265359;
const uint SAMPLE_COUNT = 1024u;

float RadicalInverse_VdC(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;
}

vec2 Hammersley(uint i, uint N) {
    return vec2(float(i) / float(N), RadicalInverse_VdC(i));
}

vec3 ImportanceSampleGGX(vec2 Xi, vec3 N, float roughness) {
    float a = roughness * roughness;
    float phi = 2.0 * PI * Xi.x;
    float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

    vec3 H = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

    vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
    vec3 tangent = normalize(cross(up, N));
    vec3 bitangent = cross(N, tangent);

    return normalize(tangent * H.x + bitangent * H.y + N * H.z);
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float a = roughness;
    float k = (a * a) / 2.0;  // IBL variant
    return NdotV / (NdotV * (1.0 - k) + k);
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

void main() {
    float NdotV = fragUV.x;
    float roughness = fragUV.y;

    vec3 V = vec3(sqrt(1.0 - NdotV * NdotV), 0.0, NdotV);
    vec3 N = vec3(0.0, 0.0, 1.0);

    float A = 0.0;
    float B = 0.0;

    for (uint i = 0u; i < SAMPLE_COUNT; i++) {
        vec2 Xi = Hammersley(i, SAMPLE_COUNT);
        vec3 H = ImportanceSampleGGX(Xi, N, roughness);
        vec3 L = normalize(2.0 * dot(V, H) * H - V);

        float NdotL = max(L.z, 0.0);
        float NdotH = max(H.z, 0.0);
        float VdotH = max(dot(V, H), 0.0);

        if (NdotL > 0.0) {
            float G = GeometrySmith(N, V, L, roughness);
            float G_Vis = (G * VdotH) / (NdotH * NdotV + 0.0001);
            float Fc = pow(1.0 - VdotH, 5.0);

            A += (1.0 - Fc) * G_Vis;
            B += Fc * G_Vis;
        }
    }

    A /= float(SAMPLE_COUNT);
    B /= float(SAMPLE_COUNT);
    outBRDF = vec2(A, B);
}
"""

# ==================================================================
# Cubemap Helpers
# ==================================================================

"""Create a cubemap image with 6 array layers, return (image, memory, cube_view, face_views, sampler)."""
function _ibl_create_cubemap(device::Device, physical_device::PhysicalDevice,
                              size::Int, format::Format; mip_levels::Int=1)
    image, memory = vk_create_image(
        device, physical_device, size, size, format,
        IMAGE_TILING_OPTIMAL,
        IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        mip_levels=mip_levels, array_layers=6,
        flags=IMAGE_CREATE_CUBE_COMPATIBLE_BIT
    )

    # Full cubemap view (for sampling as a cubemap)
    cube_view = unwrap(create_image_view(device, ImageViewCreateInfo(
        image, IMAGE_VIEW_TYPE_CUBE, format,
        ComponentMapping(COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                         COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY),
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(mip_levels), UInt32(0), UInt32(6))
    )))

    # Per-face views (for framebuffer attachment) — one per face, mip 0 only
    face_views = ImageView[]
    for face in 0:5
        fv = unwrap(create_image_view(device, ImageViewCreateInfo(
            image, IMAGE_VIEW_TYPE_2D, format,
            ComponentMapping(COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                             COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY),
            ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(1), UInt32(face), UInt32(1))
        )))
        push!(face_views, fv)
    end

    # Cubemap sampler with clamp-to-edge
    sampler = unwrap(create_sampler(device, SamplerCreateInfo(
        FILTER_LINEAR, FILTER_LINEAR,
        mip_levels > 1 ? SAMPLER_MIPMAP_MODE_LINEAR : SAMPLER_MIPMAP_MODE_NEAREST,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        0.0f0, false, 1.0f0, false, COMPARE_OP_ALWAYS,
        0.0f0, mip_levels > 1 ? Float32(mip_levels) : 0.0f0,
        BORDER_COLOR_FLOAT_OPAQUE_BLACK, false
    )))

    return image, memory, cube_view, face_views, sampler
end

"""Create per-face views for a specific mip level of a cubemap."""
function _ibl_create_mip_face_views(device::Device, image::Image, format::Format, mip::Int)
    views = ImageView[]
    for face in 0:5
        fv = unwrap(create_image_view(device, ImageViewCreateInfo(
            image, IMAGE_VIEW_TYPE_2D, format,
            ComponentMapping(COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                             COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY),
            ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(mip), UInt32(1), UInt32(face), UInt32(1))
        )))
        push!(views, fv)
    end
    return views
end

"""Create a color-only render pass for IBL offline rendering."""
function _ibl_create_render_pass(device::Device, format::Format)
    attachment = AttachmentDescription(
        format, SAMPLE_COUNT_1_BIT,
        ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
        ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
        IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
    )
    ref = AttachmentReference(UInt32(0), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    subpass = SubpassDescription(PIPELINE_BIND_POINT_GRAPHICS, [], [ref], [])
    dep = SubpassDependency(
        VK_SUBPASS_EXTERNAL, UInt32(0),
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        AccessFlag(0), ACCESS_COLOR_ATTACHMENT_WRITE_BIT
    )
    return unwrap(create_render_pass(device, RenderPassCreateInfo([attachment], [subpass], [dep])))
end

"""Transition a cubemap (all faces, all mip levels) to SHADER_READ_ONLY_OPTIMAL."""
function _ibl_transition_cubemap_to_readable!(cmd::CommandBuffer, image::Image;
                                               mip_levels::Int=1)
    barrier = ImageMemoryBarrier(
        C_NULL,
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT, ACCESS_SHADER_READ_BIT,
        IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
        image,
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(mip_levels), UInt32(0), UInt32(6))
    )
    cmd_pipeline_barrier(cmd, [], [], [barrier];
        src_stage_mask=PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        dst_stage_mask=PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        dependency_flags=DependencyFlag(0))
end

"""Render one cubemap face using the given pipeline and push constants."""
function _ibl_render_face!(cmd::CommandBuffer, render_pass::RenderPass,
                             framebuffer::Vulkan.Framebuffer, pipeline::VulkanShaderProgram,
                             cube_buffer::Buffer, push_data::IBLPushConstants,
                             size::Int;
                             descriptor_set::Union{DescriptorSet, Nothing}=nothing)
    clear = [ClearValue(ClearColorValue((0.0f0, 0.0f0, 0.0f0, 1.0f0)))]
    rp_begin = RenderPassBeginInfo(
        render_pass, framebuffer,
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(size), UInt32(size))),
        clear
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)
    cmd_set_viewport(cmd, [Viewport(0.0f0, 0.0f0, Float32(size), Float32(size), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd, [Rect2D(Offset2D(0, 0), Extent2D(UInt32(size), UInt32(size)))])

    cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline)

    if descriptor_set !== nothing
        cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline_layout,
            UInt32(0), [descriptor_set], UInt32[])
    end

    # Push constants
    push_ref = Ref(push_data)
    GC.@preserve push_ref cmd_push_constants(cmd, pipeline.pipeline_layout,
        SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
        UInt32(0), UInt32(sizeof(IBLPushConstants)),
        Base.unsafe_convert(Ptr{Cvoid}, Base.cconvert(Ptr{Cvoid}, push_ref)))

    # Draw cube (36 vertices, vec3 position)
    cmd_bind_vertex_buffers(cmd, [cube_buffer], [UInt64(0)])
    cmd_draw(cmd, UInt32(36), UInt32(1), UInt32(0), UInt32(0))

    cmd_end_render_pass(cmd)
end

# ==================================================================
# Main IBL Pipeline
# ==================================================================

"""
    vk_create_ibl_environment(device, physical_device, cmd_pool, queue, path, intensity) -> VulkanIBLEnvironment

Create an IBL environment from an HDR equirectangular map.
Generates cubemap, irradiance convolution, prefiltered specular, and BRDF LUT.
"""
function vk_create_ibl_environment(device::Device, physical_device::PhysicalDevice,
                                    command_pool::CommandPool, queue::Queue,
                                    path::String, intensity::Float32)
    # 1. Load HDR environment map
    env_pixels, env_w, env_h = _load_hdr_image(path)
    equirect_tex = vk_upload_texture(device, physical_device, command_pool, queue,
                                       env_pixels, env_w, env_h, 4;
                                       format=FORMAT_R16G16B16A16_SFLOAT,
                                       generate_mipmaps=false)

    # 2. Create cube vertex buffer
    cube_data = copy(_IBL_CUBE_VERTICES)
    buf_size = length(cube_data) * sizeof(Float32)
    staging_buf, staging_mem = vk_create_buffer(device, physical_device, buf_size,
        BUFFER_USAGE_TRANSFER_SRC_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT)
    ptr = unwrap(map_memory(device, staging_mem, UInt64(0), UInt64(buf_size)))
    GC.@preserve cube_data unsafe_copyto!(Ptr{Float32}(ptr), pointer(cube_data), length(cube_data))
    unmap_memory(device, staging_mem)

    cube_buffer, cube_mem = vk_create_buffer(device, physical_device, buf_size,
        BUFFER_USAGE_TRANSFER_DST_BIT | BUFFER_USAGE_VERTEX_BUFFER_BIT,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT)

    cmd_tmp = vk_begin_single_time_commands(device, command_pool)
    cmd_copy_buffer(cmd_tmp, staging_buf, cube_buffer, [BufferCopy(UInt64(0), UInt64(0), UInt64(buf_size))])
    vk_end_single_time_commands(device, command_pool, queue, cmd_tmp)
    finalize(staging_buf); finalize(staging_mem)

    # 3. Create descriptor set layout (1 combined image sampler)
    ibl_ds_layout = unwrap(create_descriptor_set_layout(device, DescriptorSetLayoutCreateInfo([
        DescriptorSetLayoutBinding(UInt32(0), DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            SHADER_STAGE_FRAGMENT_BIT; descriptor_count=1)
    ])))

    # 4. Create descriptor pool
    ibl_pool = unwrap(create_descriptor_pool(device, DescriptorPoolCreateInfo(
        UInt32(4), [DescriptorPoolSize(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, UInt32(4))];
        flags=DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT
    )))

    # 5. Push constant range
    ibl_push_range = PushConstantRange(
        SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
        UInt32(0), UInt32(sizeof(IBLPushConstants))
    )

    # 6. Render passes
    rgba16f_rp = _ibl_create_render_pass(device, FORMAT_R16G16B16A16_SFLOAT)
    rg16f_rp = _ibl_create_render_pass(device, FORMAT_R16G16_SFLOAT)

    # 7. Cube vertex input
    cube_bindings = [VertexInputBindingDescription(UInt32(0), UInt32(3 * sizeof(Float32)), VERTEX_INPUT_RATE_VERTEX)]
    cube_attributes = [VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32B32_SFLOAT, UInt32(0))]

    # ============================================================
    # Stage 1: Equirectangular → Cubemap
    # ============================================================
    env_image, env_mem, env_cube_view, env_face_views, env_sampler =
        _ibl_create_cubemap(device, physical_device, IBL_CUBEMAP_SIZE, FORMAT_R16G16B16A16_SFLOAT)

    equirect_pipeline = vk_compile_and_create_pipeline(device, _IBL_CUBE_VERT, _IBL_EQUIRECT_FRAG,
        VulkanPipelineConfig(rgba16f_rp, UInt32(0), cube_bindings, cube_attributes,
            [ibl_ds_layout], [ibl_push_range], false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE, 1, IBL_CUBEMAP_SIZE, IBL_CUBEMAP_SIZE))

    # Descriptor set with equirectangular source texture
    equirect_ds = vk_allocate_descriptor_set(device, ibl_pool, ibl_ds_layout)
    vk_update_texture_descriptor!(device, equirect_ds, 0, equirect_tex)

    # Create framebuffers and render 6 faces
    cmd = vk_begin_single_time_commands(device, command_pool)

    for face in 1:6
        fb = unwrap(create_framebuffer(device, FramebufferCreateInfo(
            rgba16f_rp, [env_face_views[face]],
            UInt32(IBL_CUBEMAP_SIZE), UInt32(IBL_CUBEMAP_SIZE), UInt32(1))))

        push_data = IBLPushConstants(
            ntuple(i -> _IBL_CUBE_PROJ[i], 16),
            ntuple(i -> _IBL_CUBE_VIEWS[face][i], 16),
            0.0f0, 0.0f0, 0.0f0, 0.0f0)

        _ibl_render_face!(cmd, rgba16f_rp, fb, equirect_pipeline, cube_buffer,
            push_data, IBL_CUBEMAP_SIZE; descriptor_set=equirect_ds)

        finalize(fb)
    end

    _ibl_transition_cubemap_to_readable!(cmd, env_image)

    # ============================================================
    # Stage 2: Irradiance Convolution
    # ============================================================
    irr_image, irr_mem, irr_cube_view, irr_face_views, irr_sampler =
        _ibl_create_cubemap(device, physical_device, IBL_IRRADIANCE_SIZE, FORMAT_R16G16B16A16_SFLOAT)

    irradiance_pipeline = vk_compile_and_create_pipeline(device, _IBL_CUBE_VERT, _IBL_IRRADIANCE_FRAG,
        VulkanPipelineConfig(rgba16f_rp, UInt32(0), cube_bindings, cube_attributes,
            [ibl_ds_layout], [ibl_push_range], false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE, 1, IBL_IRRADIANCE_SIZE, IBL_IRRADIANCE_SIZE))

    # Descriptor set with environment cubemap
    env_cubemap_ds = vk_allocate_descriptor_set(device, ibl_pool, ibl_ds_layout)
    vk_update_image_sampler_descriptor!(device, env_cubemap_ds, 0, env_cube_view, env_sampler)

    for face in 1:6
        fb = unwrap(create_framebuffer(device, FramebufferCreateInfo(
            rgba16f_rp, [irr_face_views[face]],
            UInt32(IBL_IRRADIANCE_SIZE), UInt32(IBL_IRRADIANCE_SIZE), UInt32(1))))

        push_data = IBLPushConstants(
            ntuple(i -> _IBL_CUBE_PROJ[i], 16),
            ntuple(i -> _IBL_CUBE_VIEWS[face][i], 16),
            0.0f0, 0.0f0, 0.0f0, 0.0f0)

        _ibl_render_face!(cmd, rgba16f_rp, fb, irradiance_pipeline, cube_buffer,
            push_data, IBL_IRRADIANCE_SIZE; descriptor_set=env_cubemap_ds)

        finalize(fb)
    end

    _ibl_transition_cubemap_to_readable!(cmd, irr_image)

    # ============================================================
    # Stage 3: Prefilter Convolution (5 mip levels)
    # ============================================================
    pf_image, pf_mem, pf_cube_view, pf_face_views, pf_sampler =
        _ibl_create_cubemap(device, physical_device, IBL_PREFILTER_SIZE, FORMAT_R16G16B16A16_SFLOAT;
                             mip_levels=IBL_PREFILTER_MIP_LEVELS)

    prefilter_pipeline = vk_compile_and_create_pipeline(device, _IBL_CUBE_VERT, _IBL_PREFILTER_FRAG,
        VulkanPipelineConfig(rgba16f_rp, UInt32(0), cube_bindings, cube_attributes,
            [ibl_ds_layout], [ibl_push_range], false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE, 1, IBL_PREFILTER_SIZE, IBL_PREFILTER_SIZE))

    for mip in 0:(IBL_PREFILTER_MIP_LEVELS - 1)
        mip_size = max(1, IBL_PREFILTER_SIZE >> mip)
        roughness = Float32(mip) / Float32(IBL_PREFILTER_MIP_LEVELS - 1)

        mip_face_views = if mip == 0
            pf_face_views  # Already created for mip 0
        else
            _ibl_create_mip_face_views(device, pf_image, FORMAT_R16G16B16A16_SFLOAT, mip)
        end

        for face in 1:6
            fb = unwrap(create_framebuffer(device, FramebufferCreateInfo(
                rgba16f_rp, [mip_face_views[face]],
                UInt32(mip_size), UInt32(mip_size), UInt32(1))))

            push_data = IBLPushConstants(
                ntuple(i -> _IBL_CUBE_PROJ[i], 16),
                ntuple(i -> _IBL_CUBE_VIEWS[face][i], 16),
                roughness, 0.0f0, 0.0f0, 0.0f0)

            _ibl_render_face!(cmd, rgba16f_rp, fb, prefilter_pipeline, cube_buffer,
                push_data, mip_size; descriptor_set=env_cubemap_ds)

            finalize(fb)
        end

        # Destroy extra mip face views (mip 0 views are kept for cleanup)
        if mip > 0
            for fv in mip_face_views
                finalize(fv)
            end
        end
    end

    _ibl_transition_cubemap_to_readable!(cmd, pf_image; mip_levels=IBL_PREFILTER_MIP_LEVELS)

    # ============================================================
    # Stage 4: BRDF LUT
    # ============================================================
    brdf_image, brdf_mem = vk_create_image(
        device, physical_device, IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE,
        FORMAT_R16G16_SFLOAT, IMAGE_TILING_OPTIMAL,
        IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT,
        MEMORY_PROPERTY_DEVICE_LOCAL_BIT)

    brdf_view = unwrap(create_image_view(device, ImageViewCreateInfo(
        brdf_image, IMAGE_VIEW_TYPE_2D, FORMAT_R16G16_SFLOAT,
        ComponentMapping(COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY,
                         COMPONENT_SWIZZLE_IDENTITY, COMPONENT_SWIZZLE_IDENTITY),
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(1), UInt32(0), UInt32(1))
    )))

    brdf_sampler = unwrap(create_sampler(device, SamplerCreateInfo(
        FILTER_LINEAR, FILTER_LINEAR, SAMPLER_MIPMAP_MODE_NEAREST,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        0.0f0, false, 1.0f0, false, COMPARE_OP_ALWAYS,
        0.0f0, 0.0f0, BORDER_COLOR_FLOAT_OPAQUE_BLACK, false
    )))

    brdf_pipeline = vk_compile_and_create_pipeline(device, _IBL_BRDF_VERT, _IBL_BRDF_FRAG,
        VulkanPipelineConfig(rg16f_rp, UInt32(0),
            vk_fullscreen_vertex_bindings(), vk_fullscreen_vertex_attributes(),
            DescriptorSetLayout[], PushConstantRange[],
            false, false, false,
            CULL_MODE_NONE, FRONT_FACE_COUNTER_CLOCKWISE,
            1, IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE))

    brdf_fb = unwrap(create_framebuffer(device, FramebufferCreateInfo(
        rg16f_rp, [brdf_view],
        UInt32(IBL_BRDF_LUT_SIZE), UInt32(IBL_BRDF_LUT_SIZE), UInt32(1))))

    # Render BRDF LUT (fullscreen quad, no descriptor set)
    clear = [ClearValue(ClearColorValue((0.0f0, 0.0f0, 0.0f0, 1.0f0)))]
    rp_begin = RenderPassBeginInfo(rg16f_rp, brdf_fb,
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(IBL_BRDF_LUT_SIZE), UInt32(IBL_BRDF_LUT_SIZE))),
        clear)
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)
    cmd_set_viewport(cmd, [Viewport(0.0f0, 0.0f0, Float32(IBL_BRDF_LUT_SIZE),
        Float32(IBL_BRDF_LUT_SIZE), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd, [Rect2D(Offset2D(0, 0),
        Extent2D(UInt32(IBL_BRDF_LUT_SIZE), UInt32(IBL_BRDF_LUT_SIZE)))])
    cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, brdf_pipeline.pipeline)
    # Need the fullscreen quad buffer — create one
    quad_verts = Float32[-1,-1, 0,0,  1,-1, 1,0,  1,1, 1,1,
                         -1,-1, 0,0,  1,1, 1,1,  -1,1, 0,1]
    quad_buf_size = length(quad_verts) * sizeof(Float32)
    q_staging, q_smem = vk_create_buffer(device, physical_device, quad_buf_size,
        BUFFER_USAGE_TRANSFER_SRC_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT)
    q_ptr = unwrap(map_memory(device, q_smem, UInt64(0), UInt64(quad_buf_size)))
    GC.@preserve quad_verts unsafe_copyto!(Ptr{Float32}(q_ptr), pointer(quad_verts), length(quad_verts))
    unmap_memory(device, q_smem)
    # Note: We can't copy to device-local buffer inside the same command buffer that's recording render passes.
    # Use a host-visible buffer directly for the quad.
    cmd_bind_vertex_buffers(cmd, [q_staging], [UInt64(0)])
    cmd_draw(cmd, UInt32(6), UInt32(1), UInt32(0), UInt32(0))
    cmd_end_render_pass(cmd)

    # Transition BRDF LUT to readable
    brdf_barrier = ImageMemoryBarrier(
        C_NULL,
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT, ACCESS_SHADER_READ_BIT,
        IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        QUEUE_FAMILY_IGNORED, QUEUE_FAMILY_IGNORED,
        brdf_image,
        ImageSubresourceRange(IMAGE_ASPECT_COLOR_BIT, UInt32(0), UInt32(1), UInt32(0), UInt32(1))
    )
    cmd_pipeline_barrier(cmd, [], [], [brdf_barrier];
        src_stage_mask=PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        dst_stage_mask=PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        dependency_flags=DependencyFlag(0))

    # Submit all work
    vk_end_single_time_commands(device, command_pool, queue, cmd)

    # ============================================================
    # Cleanup temporary resources
    # ============================================================
    finalize(equirect_pipeline.pipeline); finalize(equirect_pipeline.pipeline_layout)
    equirect_pipeline.vert_module !== nothing && finalize(equirect_pipeline.vert_module)
    equirect_pipeline.frag_module !== nothing && finalize(equirect_pipeline.frag_module)

    finalize(irradiance_pipeline.pipeline); finalize(irradiance_pipeline.pipeline_layout)
    irradiance_pipeline.vert_module !== nothing && finalize(irradiance_pipeline.vert_module)
    irradiance_pipeline.frag_module !== nothing && finalize(irradiance_pipeline.frag_module)

    finalize(prefilter_pipeline.pipeline); finalize(prefilter_pipeline.pipeline_layout)
    prefilter_pipeline.vert_module !== nothing && finalize(prefilter_pipeline.vert_module)
    prefilter_pipeline.frag_module !== nothing && finalize(prefilter_pipeline.frag_module)

    finalize(brdf_pipeline.pipeline); finalize(brdf_pipeline.pipeline_layout)
    brdf_pipeline.vert_module !== nothing && finalize(brdf_pipeline.vert_module)
    brdf_pipeline.frag_module !== nothing && finalize(brdf_pipeline.frag_module)
    finalize(brdf_fb)

    for fv in env_face_views; finalize(fv); end
    for fv in irr_face_views; finalize(fv); end
    for fv in pf_face_views; finalize(fv); end

    finalize(rgba16f_rp)
    finalize(rg16f_rp)
    finalize(ibl_ds_layout)
    finalize(ibl_pool)
    finalize(cube_buffer); finalize(cube_mem)
    finalize(q_staging); finalize(q_smem)

    # Destroy equirectangular source (no longer needed after cubemap conversion)
    vk_destroy_texture!(device, equirect_tex)

    # ============================================================
    # Assemble output
    # ============================================================
    env_cubemap = VulkanGPUTexture(env_image, env_mem, env_cube_view, env_sampler,
        IBL_CUBEMAP_SIZE, IBL_CUBEMAP_SIZE, 4, FORMAT_R16G16B16A16_SFLOAT,
        IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)

    irr_cubemap = VulkanGPUTexture(irr_image, irr_mem, irr_cube_view, irr_sampler,
        IBL_IRRADIANCE_SIZE, IBL_IRRADIANCE_SIZE, 4, FORMAT_R16G16B16A16_SFLOAT,
        IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)

    pf_cubemap = VulkanGPUTexture(pf_image, pf_mem, pf_cube_view, pf_sampler,
        IBL_PREFILTER_SIZE, IBL_PREFILTER_SIZE, 4, FORMAT_R16G16B16A16_SFLOAT,
        IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)

    brdf = VulkanGPUTexture(brdf_image, brdf_mem, brdf_view, brdf_sampler,
        IBL_BRDF_LUT_SIZE, IBL_BRDF_LUT_SIZE, 2, FORMAT_R16G16_SFLOAT,
        IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)

    return VulkanIBLEnvironment(env_cubemap, irr_cubemap, pf_cubemap, brdf, intensity)
end

"""
    _load_hdr_image(path) -> (Vector{UInt8}, Int, Int)

Load an HDR image and convert to RGBA16F pixel data.
"""
function _load_hdr_image(path::String)
    img = FileIO.load(path)
    h, w = size(img)

    pixels = Vector{UInt8}(undef, w * h * 8)  # 4 channels × 2 bytes each
    idx = 1
    for row in 1:h
        for col in 1:w
            c = img[row, col]
            r = Float16(ColorTypes.red(c))
            g = Float16(ColorTypes.green(c))
            b = Float16(ColorTypes.blue(c))
            a = Float16(1.0)

            for val in (r, g, b, a)
                u = reinterpret(UInt16, val)
                pixels[idx] = u % UInt8
                pixels[idx + 1] = (u >> 8) % UInt8
                idx += 2
            end
        end
    end

    return pixels, w, h
end

"""
    vk_destroy_ibl_environment!(device, ibl)

Destroy IBL environment resources.
"""
function vk_destroy_ibl_environment!(device::Device, ibl::VulkanIBLEnvironment)
    vk_destroy_texture!(device, ibl.environment_map)
    vk_destroy_texture!(device, ibl.irradiance_map)
    vk_destroy_texture!(device, ibl.prefilter_map)
    vk_destroy_texture!(device, ibl.brdf_lut)
    return nothing
end
