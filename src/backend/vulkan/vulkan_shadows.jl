# Vulkan cascaded shadow map rendering

"""
    vk_create_csm(device, physical_device, num_cascades, resolution, near, far) -> VulkanCascadedShadowMap

Create cascaded shadow map render targets and depth pipeline.
"""
function vk_create_csm(device::Device, physical_device::PhysicalDevice,
                        num_cascades::Int, resolution::Int,
                        near::Float32, far::Float32)
    framebuffers = VkFramebuffer[]
    render_passes = RenderPass[]
    depth_textures = VulkanGPUTexture[]

    for _ in 1:num_cascades
        fb, rp, depth_tex = vk_create_depth_only_render_target(device, physical_device, resolution, resolution)
        push!(framebuffers, fb)
        push!(render_passes, rp)
        push!(depth_textures, depth_tex)
    end

    # Compute initial cascade splits
    splits = compute_cascade_splits(num_cascades, near, far)

    return VulkanCascadedShadowMap(
        num_cascades,
        framebuffers, render_passes, depth_textures,
        fill(Mat4f(I), num_cascades),  # matrices updated per frame
        splits,
        resolution,
        nothing,  # depth pipeline created lazily
        nothing   # skinned depth pipeline created lazily
    )
end

"""
    vk_create_shadow_depth_pipeline(device, csm, push_constant_range) -> VulkanShaderProgram

Create a depth-only graphics pipeline for shadow map rendering.
"""
function vk_create_shadow_depth_pipeline(device::Device, csm::VulkanCascadedShadowMap,
                                          set_layouts::Vector{DescriptorSetLayout},
                                          push_constant_range::PushConstantRange)
    vert_src = """
    #version 450
    layout(push_constant) uniform PushConstants {
        mat4 model;
        vec4 normal_matrix_col0;
        vec4 normal_matrix_col1;
        vec4 normal_matrix_col2;
    } obj;

    layout(set = 0, binding = 0) uniform PerFrame {
        mat4 view;
        mat4 projection;
        mat4 inv_view_proj;
        vec4 camera_pos;
        float time;
        float _pad1, _pad2, _pad3;
    } frame;

    layout(location = 0) in vec3 inPosition;
    layout(location = 1) in vec3 inNormal;
    layout(location = 2) in vec2 inUV;

    void main() {
        gl_Position = frame.projection * frame.view * obj.model * vec4(inPosition, 1.0);
    }
    """

    frag_src = """
    #version 450
    void main() {
        // Depth only — no color output
    }
    """

    config = VulkanPipelineConfig(
        csm.cascade_render_passes[1],
        UInt32(0),
        vk_standard_vertex_bindings(),
        vk_standard_vertex_attributes(),
        set_layouts,
        [push_constant_range],
        false,  # no blending
        true,   # depth test
        true,   # depth write
        CULL_MODE_FRONT_BIT,  # front-face culling reduces peter-panning
        FRONT_FACE_CLOCKWISE,
        0,  # no color attachments
        csm.resolution,
        csm.resolution
    )

    vert_spirv = vk_compile_glsl_to_spirv(vert_src, :vert)
    frag_spirv = vk_compile_glsl_to_spirv(frag_src, :frag)
    return vk_create_graphics_pipeline(device, vert_spirv, frag_spirv, config)
end

"""
    vk_create_skinned_shadow_depth_pipeline(device, csm, set_layouts, push_constant_range) -> VulkanShaderProgram

Create a depth-only pipeline for shadow rendering of skinned meshes.
Uses set 0 = per-frame UBO, set 1 = bone matrix UBO.
"""
function vk_create_skinned_shadow_depth_pipeline(device::Device, csm::VulkanCascadedShadowMap,
                                                   set_layouts::Vector{DescriptorSetLayout},
                                                   push_constant_range::PushConstantRange)
    vert_src = """
    #version 450
    layout(push_constant) uniform PushConstants {
        mat4 model;
        vec4 normal_matrix_col0;
        vec4 normal_matrix_col1;
        vec4 normal_matrix_col2;
    } obj;

    layout(set = 0, binding = 0) uniform PerFrame {
        mat4 view;
        mat4 projection;
        mat4 inv_view_proj;
        vec4 camera_pos;
        float time;
        float _pad1, _pad2, _pad3;
    } frame;

    #define MAX_BONES 128
    layout(set = 1, binding = 0) uniform BoneData {
        int has_skinning;
        int _pad1, _pad2, _pad3;
        mat4 bones[MAX_BONES];
    } skinning;

    layout(location = 0) in vec3 inPosition;
    layout(location = 1) in vec3 inNormal;
    layout(location = 2) in vec2 inUV;
    layout(location = 3) in vec4 inBoneWeights;
    layout(location = 4) in uvec4 inBoneIndices;

    void main() {
        vec3 localPos = inPosition;
        if (skinning.has_skinning != 0) {
            mat4 skin = skinning.bones[inBoneIndices.x] * inBoneWeights.x
                      + skinning.bones[inBoneIndices.y] * inBoneWeights.y
                      + skinning.bones[inBoneIndices.z] * inBoneWeights.z
                      + skinning.bones[inBoneIndices.w] * inBoneWeights.w;
            localPos = (skin * vec4(inPosition, 1.0)).xyz;
        }
        gl_Position = frame.projection * frame.view * obj.model * vec4(localPos, 1.0);
    }
    """

    frag_src = """
    #version 450
    void main() {
    }
    """

    config = VulkanPipelineConfig(
        csm.cascade_render_passes[1],
        UInt32(0),
        vk_skinned_vertex_bindings(),
        vk_skinned_vertex_attributes(),
        set_layouts,
        [push_constant_range],
        false,  # no blending
        true,   # depth test
        true,   # depth write
        CULL_MODE_FRONT_BIT,
        FRONT_FACE_CLOCKWISE,
        0,  # no color attachments
        csm.resolution,
        csm.resolution
    )

    vert_spirv = vk_compile_glsl_to_spirv(vert_src, :vert)
    frag_spirv = vk_compile_glsl_to_spirv(frag_src, :frag)
    return vk_create_graphics_pipeline(device, vert_spirv, frag_spirv, config)
end

"""
    vk_render_csm_passes!(cmd, backend, csm, view, proj, light_direction)

Render shadow depth for all cascades.
"""
function vk_render_csm_passes!(cmd::CommandBuffer, backend, csm::VulkanCascadedShadowMap,
                                view::Mat4f, proj::Mat4f, light_direction::Vec3f)
    # Update cascade matrices
    for i in 1:csm.num_cascades
        near_split = csm.split_distances[i]
        far_split = csm.split_distances[i + 1]
        csm.cascade_matrices[i] = compute_cascade_light_matrix(view, proj, near_split, far_split, light_direction)
    end

    for i in 1:csm.num_cascades
        # Override per-frame UBO with light-space view/proj for this cascade
        light_view_proj = csm.cascade_matrices[i]
        # We use the cascade matrix as the combined view-projection

        clear_values = [ClearValue(ClearDepthStencilValue(1.0f0, UInt32(0)))]

        rp_begin = RenderPassBeginInfo(
            csm.cascade_render_passes[i],
            csm.cascade_framebuffers[i],
            Rect2D(Offset2D(0, 0), Extent2D(UInt32(csm.resolution), UInt32(csm.resolution))),
            clear_values
        )
        cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)

        cmd_set_viewport(cmd, [Viewport(0.0f0, 0.0f0,
            Float32(csm.resolution), Float32(csm.resolution), 0.0f0, 1.0f0)])
        cmd_set_scissor(cmd, [Rect2D(Offset2D(0, 0),
            Extent2D(UInt32(csm.resolution), UInt32(csm.resolution)))])

        if csm.depth_pipeline !== nothing
            frame_idx = backend.current_frame
            last_was_skinned = false
            cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, csm.depth_pipeline.pipeline)

            # Bind per-frame descriptor set (set 0) for shadow pass
            cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS,
                csm.depth_pipeline.pipeline_layout,
                UInt32(0), [backend.per_frame_ds[frame_idx]], UInt32[])

            # Render all mesh entities
            iterate_components(MeshComponent) do entity_id, mesh
                isempty(mesh.indices) && return

                gpu_mesh = vk_get_or_upload_mesh!(backend.gpu_cache, backend.device,
                    backend.physical_device, backend.command_pool, backend.graphics_queue,
                    entity_id, mesh)

                # Check for skinning
                is_skinned = gpu_mesh.has_skinning && csm.skinned_depth_pipeline !== nothing
                skin = is_skinned ? get_component(entity_id, SkinnedMeshComponent) : nothing
                is_skinned = is_skinned && skin !== nothing && !isempty(skin.bone_matrices)

                # Switch pipeline if needed
                if is_skinned && !last_was_skinned
                    cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS,
                        csm.skinned_depth_pipeline.pipeline)
                    last_was_skinned = true
                elseif !is_skinned && last_was_skinned
                    cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS,
                        csm.depth_pipeline.pipeline)
                    last_was_skinned = false
                end

                world_transform = get_world_transform(entity_id)
                model = Mat4f(world_transform)
                model3 = SMatrix{3, 3, Float32, 9}(
                    model[1,1], model[2,1], model[3,1],
                    model[1,2], model[2,2], model[3,2],
                    model[1,3], model[2,3], model[3,3]
                )
                normal_matrix = SMatrix{3, 3, Float32, 9}(transpose(inv(model3)))

                active_pipeline = last_was_skinned ? csm.skinned_depth_pipeline : csm.depth_pipeline
                push_data = vk_pack_per_object(model, normal_matrix)
                push_ref = Ref(push_data)
                GC.@preserve push_ref cmd_push_constants(cmd, active_pipeline.pipeline_layout,
                    SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
                    UInt32(0), UInt32(sizeof(push_data)),
                    Base.unsafe_convert(Ptr{Cvoid}, Base.cconvert(Ptr{Cvoid}, push_ref)))

                # Upload bone matrices for skinned entities
                if is_skinned
                    bone_uniforms = vk_pack_bone_uniforms(skin.bone_matrices)
                    bone_ubo, bone_mem = vk_create_uniform_buffer(
                        backend.device, backend.physical_device, bone_uniforms)
                    push!(backend.frame_temp_buffers[frame_idx], (bone_ubo, bone_mem))
                    bone_ds = vk_allocate_descriptor_set(backend.device,
                        backend.transient_pools[frame_idx], backend.per_frame_layout)
                    vk_update_ubo_descriptor!(backend.device, bone_ds, 0,
                        bone_ubo, sizeof(VulkanBoneUniforms))
                    cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS,
                        active_pipeline.pipeline_layout,
                        UInt32(1), [bone_ds], UInt32[])
                end

                vk_bind_and_draw_mesh!(cmd, gpu_mesh)
            end
        end

        cmd_end_render_pass(cmd)
    end

    return nothing
end

"""
    vk_destroy_csm!(device, csm)

Destroy cascaded shadow map resources.
"""
function vk_destroy_csm!(device::Device, csm::VulkanCascadedShadowMap)
    for i in 1:csm.num_cascades
        finalize(csm.cascade_framebuffers[i])
        finalize(csm.cascade_render_passes[i])
        vk_destroy_texture!(device, csm.cascade_depth_textures[i])
    end
    if csm.depth_pipeline !== nothing
        finalize(csm.depth_pipeline.pipeline)
        finalize(csm.depth_pipeline.pipeline_layout)
    end
    if csm.skinned_depth_pipeline !== nothing
        finalize(csm.skinned_depth_pipeline.pipeline)
        finalize(csm.skinned_depth_pipeline.pipeline_layout)
    end
    return nothing
end
