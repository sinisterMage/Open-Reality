# Vulkan uniform buffer struct packing
# Layouts match Metal uniform structs (std140 alignment) for consistency.
# Adapted from src/backend/metal/metal_uniforms.jl

# ---- Per-Frame Uniforms ----
# Descriptor set 0, binding 0

struct VulkanPerFrameUniforms
    view::NTuple{16, Float32}
    projection::NTuple{16, Float32}
    inv_view_proj::NTuple{16, Float32}
    camera_pos::NTuple{4, Float32}    # xyz + padding
    time::Float32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

function vk_pack_per_frame(view::Mat4f, proj::Mat4f, cam_pos::Vec3f, t::Float32)
    vp = proj * view
    ivp = Mat4f(inv(vp))
    VulkanPerFrameUniforms(
        ntuple(i -> view[i], 16),
        ntuple(i -> proj[i], 16),
        ntuple(i -> ivp[i], 16),
        (cam_pos[1], cam_pos[2], cam_pos[3], 0.0f0),
        t, 0.0f0, 0.0f0, 0.0f0
    )
end

# ---- Per-Object Push Constants ----
# model (4x4 = 16 floats = 64 bytes) + normal_matrix (3 columns × 4 floats = 48 bytes) = 112 bytes

struct VulkanPerObjectPushConstants
    model::NTuple{16, Float32}
    normal_matrix_col0::NTuple{4, Float32}
    normal_matrix_col1::NTuple{4, Float32}
    normal_matrix_col2::NTuple{4, Float32}
end

function vk_pack_per_object(model::Mat4f, normal_matrix::SMatrix{3,3,Float32,9})
    VulkanPerObjectPushConstants(
        ntuple(i -> model[i], 16),
        (normal_matrix[1,1], normal_matrix[2,1], normal_matrix[3,1], 0.0f0),
        (normal_matrix[1,2], normal_matrix[2,2], normal_matrix[3,2], 0.0f0),
        (normal_matrix[1,3], normal_matrix[2,3], normal_matrix[3,3], 0.0f0)
    )
end

# ---- Material Uniforms ----
# Descriptor set 1, binding 0

struct VulkanMaterialUniforms
    albedo::NTuple{4, Float32}        # rgb + opacity
    metallic::Float32
    roughness::Float32
    ao::Float32
    alpha_cutoff::Float32
    emissive_factor::NTuple{4, Float32}
    clearcoat::Float32
    clearcoat_roughness::Float32
    subsurface::Float32
    parallax_scale::Float32
    has_albedo_map::Int32
    has_normal_map::Int32
    has_metallic_roughness_map::Int32
    has_ao_map::Int32
    has_emissive_map::Int32
    has_height_map::Int32
    lod_alpha::Float32
    _pad2::Int32
end

function vk_pack_material(mat::MaterialComponent)
    VulkanMaterialUniforms(
        (mat.color.r, mat.color.g, mat.color.b, mat.opacity),
        mat.metallic,
        mat.roughness,
        1.0f0,
        mat.alpha_cutoff,
        (mat.emissive_factor[1], mat.emissive_factor[2], mat.emissive_factor[3], 0.0f0),
        mat.clearcoat,
        mat.clearcoat_roughness,
        mat.subsurface,
        mat.parallax_height_scale,
        mat.albedo_map !== nothing ? Int32(1) : Int32(0),
        mat.normal_map !== nothing ? Int32(1) : Int32(0),
        mat.metallic_roughness_map !== nothing ? Int32(1) : Int32(0),
        mat.ao_map !== nothing ? Int32(1) : Int32(0),
        mat.emissive_map !== nothing ? Int32(1) : Int32(0),
        (mat.height_map !== nothing && mat.parallax_height_scale > 0.0f0) ? Int32(1) : Int32(0),
        1.0f0, Int32(0)  # lod_alpha = 1.0 (fully opaque, no LOD crossfade)
    )
end

# ---- Light Uniforms ----
# Descriptor set 2, binding 0

const VK_MAX_POINT_LIGHTS = 16
const VK_MAX_DIR_LIGHTS = 4

struct VulkanPointLightData
    position::NTuple{4, Float32}
    color::NTuple{4, Float32}
    intensity::Float32
    range::Float32
    _pad1::Float32
    _pad2::Float32
end

struct VulkanDirLightData
    direction::NTuple{4, Float32}
    color::NTuple{4, Float32}
    intensity::Float32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

struct VulkanLightUniforms
    point_lights::NTuple{16, VulkanPointLightData}
    dir_lights::NTuple{4, VulkanDirLightData}
    num_point_lights::Int32
    num_dir_lights::Int32
    has_ibl::Int32
    ibl_intensity::Float32
end

function _vk_empty_point_light()
    VulkanPointLightData(
        (0.0f0, 0.0f0, 0.0f0, 0.0f0),
        (0.0f0, 0.0f0, 0.0f0, 0.0f0),
        0.0f0, 0.0f0, 0.0f0, 0.0f0
    )
end

function _vk_empty_dir_light()
    VulkanDirLightData(
        (0.0f0, 0.0f0, 0.0f0, 0.0f0),
        (0.0f0, 0.0f0, 0.0f0, 0.0f0),
        0.0f0, 0.0f0, 0.0f0, 0.0f0
    )
end

function vk_pack_lights(light_data::FrameLightData)
    point_lights = ntuple(VK_MAX_POINT_LIGHTS) do i
        if i <= length(light_data.point_positions)
            pos = light_data.point_positions[i]
            col = light_data.point_colors[i]
            VulkanPointLightData(
                (pos[1], pos[2], pos[3], 0.0f0),
                (col.r, col.g, col.b, 0.0f0),
                light_data.point_intensities[i],
                light_data.point_ranges[i],
                0.0f0, 0.0f0
            )
        else
            _vk_empty_point_light()
        end
    end

    dir_lights = ntuple(VK_MAX_DIR_LIGHTS) do i
        if i <= length(light_data.dir_directions)
            dir = light_data.dir_directions[i]
            col = light_data.dir_colors[i]
            VulkanDirLightData(
                (dir[1], dir[2], dir[3], 0.0f0),
                (col.r, col.g, col.b, 0.0f0),
                light_data.dir_intensities[i],
                0.0f0, 0.0f0, 0.0f0
            )
        else
            _vk_empty_dir_light()
        end
    end

    VulkanLightUniforms(
        point_lights, dir_lights,
        Int32(length(light_data.point_positions)),
        Int32(length(light_data.dir_directions)),
        light_data.has_ibl ? Int32(1) : Int32(0),
        light_data.ibl_intensity
    )
end

# ---- Shadow Uniforms ----
# Descriptor set 2, binding 1

struct VulkanShadowUniforms
    cascade_matrices::NTuple{4, NTuple{16, Float32}}
    cascade_splits::NTuple{5, Float32}
    num_cascades::Int32
    has_shadows::Int32
    _pad1::Float32
end

function vk_pack_shadow_uniforms(csm::VulkanCascadedShadowMap, has_shadows::Bool)
    mats = ntuple(VK_MAX_CSM_CASCADES) do i
        if i <= length(csm.cascade_matrices)
            m = csm.cascade_matrices[i]
            ntuple(j -> m[j], 16)
        else
            ntuple(_ -> 0.0f0, 16)
        end
    end

    splits = ntuple(5) do i
        if i <= length(csm.split_distances)
            csm.split_distances[i]
        else
            0.0f0
        end
    end

    VulkanShadowUniforms(
        mats, splits,
        Int32(csm.num_cascades),
        has_shadows ? Int32(1) : Int32(0),
        0.0f0
    )
end

# ---- SSAO Uniforms ----

struct VulkanSSAOUniforms
    samples::NTuple{64, NTuple{4, Float32}}
    projection::NTuple{16, Float32}
    kernel_size::Int32
    radius::Float32
    bias::Float32
    power::Float32
    screen_width::Float32
    screen_height::Float32
    _pad1::Float32
    _pad2::Float32
end

function vk_pack_ssao_uniforms(kernel::Vector{Vec3f}, proj::Mat4f, radius::Float32,
                                bias::Float32, power::Float32, width::Int, height::Int)
    samples = ntuple(64) do i
        if i <= length(kernel)
            k = kernel[i]
            (k[1], k[2], k[3], 0.0f0)
        else
            (0.0f0, 0.0f0, 0.0f0, 0.0f0)
        end
    end
    VulkanSSAOUniforms(
        samples,
        ntuple(i -> proj[i], 16),
        Int32(length(kernel)),
        radius, bias, power,
        Float32(width), Float32(height),
        0.0f0, 0.0f0
    )
end

# ---- SSR Uniforms ----

struct VulkanSSRUniforms
    projection::NTuple{16, Float32}
    view::NTuple{16, Float32}
    inv_projection::NTuple{16, Float32}
    camera_pos::NTuple{4, Float32}
    screen_size::NTuple{2, Float32}
    max_steps::Int32
    max_distance::Float32
    thickness::Float32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

# ---- TAA Uniforms ----

struct VulkanTAAUniforms
    prev_view_proj::NTuple{16, Float32}
    inv_view_proj::NTuple{16, Float32}
    feedback::Float32
    first_frame::Int32
    screen_width::Float32
    screen_height::Float32
end

# ---- Post-Process Uniforms ----

struct VulkanPostProcessUniforms
    bloom_threshold::Float32
    bloom_intensity::Float32
    gamma::Float32
    tone_mapping_mode::Int32
    horizontal::Int32
    vignette_intensity::Float32
    vignette_radius::Float32
    vignette_softness::Float32
    color_brightness::Float32
    color_contrast::Float32
    color_saturation::Float32
    _pad1::Float32
end

# ---- Bone Matrix Uniforms (skeletal animation) ----

const VK_MAX_BONES = 128

struct VulkanBoneUniforms
    has_skinning::Int32
    _pad1::Int32
    _pad2::Int32
    _pad3::Int32
    bone_matrices::NTuple{128, NTuple{16, Float32}}
end

function vk_pack_bone_uniforms(bone_matrices::Vector{Mat4f})
    mats = ntuple(VK_MAX_BONES) do i
        if i <= length(bone_matrices)
            m = bone_matrices[i]
            ntuple(j -> m[j], 16)
        else
            ntuple(_ -> 0.0f0, 16)
        end
    end
    VulkanBoneUniforms(Int32(1), Int32(0), Int32(0), Int32(0), mats)
end

function vk_pack_empty_bone_uniforms()
    VulkanBoneUniforms(Int32(0), Int32(0), Int32(0), Int32(0),
        ntuple(_ -> ntuple(_ -> 0.0f0, 16), VK_MAX_BONES))
end

# ---- Helper: Create and upload a uniform buffer ----

function vk_create_uniform_buffer(device::Device, physical_device::PhysicalDevice,
                                   uniform_data)
    size = sizeof(typeof(uniform_data))
    buffer, memory = vk_create_buffer(
        device, physical_device, size,
        BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
    )
    vk_upload_struct_data!(device, memory, uniform_data)
    return buffer, memory
end
