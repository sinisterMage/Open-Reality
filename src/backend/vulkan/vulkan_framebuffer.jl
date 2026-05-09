# Vulkan framebuffer and render pass creation for off-screen render targets

"""
    vk_create_render_target(device, physical_device, width, height;
                            color_format=FORMAT_R16G16B16A16_SFLOAT,
                            has_depth=true) -> VulkanFramebuffer

Create an off-screen render target with one HDR color attachment and optional depth.
"""
function vk_create_render_target(device::Device, physical_device::PhysicalDevice,
                                  width::Integer, height::Integer;
                                  color_format::Format=FORMAT_R16G16B16A16_SFLOAT,
                                  has_depth::Bool=true)
    # Create color texture
    color_tex = vk_create_render_target_texture(device, physical_device, width, height, color_format)

    # Create depth texture if needed
    depth_tex = nothing
    if has_depth
        depth_tex = vk_create_render_target_texture(
            device, physical_device, width, height, FORMAT_D32_SFLOAT;
            aspect=IMAGE_ASPECT_DEPTH_BIT
        )
    end

    # Create render pass
    attachments = AttachmentDescription[]
    push!(attachments, AttachmentDescription(
        color_format, SAMPLE_COUNT_1_BIT,
        ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
        ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
        IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    ))

    color_ref = AttachmentReference(UInt32(0), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)

    depth_ref = nothing
    if has_depth
        push!(attachments, AttachmentDescription(
            FORMAT_D32_SFLOAT, SAMPLE_COUNT_1_BIT,
            ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_DONT_CARE,
            ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
            IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        ))
        depth_ref = AttachmentReference(UInt32(1), IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
    end

    subpass = if depth_ref !== nothing
        SubpassDescription(
            PIPELINE_BIND_POINT_GRAPHICS, [], [color_ref], [];
            depth_stencil_attachment=depth_ref
        )
    else
        SubpassDescription(PIPELINE_BIND_POINT_GRAPHICS, [], [color_ref], [])
    end

    # EXTERNAL → subpass 0: wait for prior color/depth output AND for any prior
    # fragment-shader reads (write-after-read hazard) before we begin writing.
    # Without FRAGMENT_SHADER + SHADER_READ in src, a pass like SSR that samples
    # this target earlier in the same command buffer can race with the next
    # write to it (e.g. SSR samples lighting_target, then lighting writes it
    # again next frame inside the same submission).
    dep_in = SubpassDependency(
        VK_SUBPASS_EXTERNAL, UInt32(0),
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
            PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        ACCESS_SHADER_READ_BIT,
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT | (has_depth ? ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT : AccessFlag(0)),
        DependencyFlag(0)
    )

    # subpass 0 → EXTERNAL: make color writes visible for subsequent fragment shader reads
    dep_out = SubpassDependency(
        UInt32(0), VK_SUBPASS_EXTERNAL,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        ACCESS_SHADER_READ_BIT,
        DependencyFlag(0)
    )

    rp = unwrap(create_render_pass(device, RenderPassCreateInfo(attachments, [subpass], [dep_in, dep_out])))

    # Create framebuffer
    views = ImageView[color_tex.view]
    if depth_tex !== nothing
        push!(views, depth_tex.view)
    end

    fb = unwrap(create_framebuffer(device, FramebufferCreateInfo(
        rp, views, UInt32(width), UInt32(height), UInt32(1)
    )))

    return VulkanFramebuffer(
        fb, rp,
        color_tex.image, color_tex.memory, color_tex.view,
        depth_tex !== nothing ? depth_tex.image : nothing,
        depth_tex !== nothing ? depth_tex.memory : nothing,
        depth_tex !== nothing ? depth_tex.view : nothing,
        color_format,
        Int(width), Int(height)
    )
end

"""
    vk_create_gbuffer(device, physical_device, width, height) -> VulkanGBuffer

Create a G-Buffer with 4 color MRTs and depth for deferred rendering.
"""
function vk_create_gbuffer(device::Device, physical_device::PhysicalDevice,
                            width::Integer, height::Integer)
    # Create textures
    albedo_metallic = vk_create_render_target_texture(device, physical_device, width, height,
                                                       FORMAT_R16G16B16A16_SFLOAT)
    normal_roughness = vk_create_render_target_texture(device, physical_device, width, height,
                                                        FORMAT_R16G16B16A16_SFLOAT)
    emissive_ao = vk_create_render_target_texture(device, physical_device, width, height,
                                                   FORMAT_R16G16B16A16_SFLOAT)
    advanced_material = vk_create_render_target_texture(device, physical_device, width, height,
                                                         FORMAT_R8G8B8A8_UNORM)
    depth = vk_create_render_target_texture(device, physical_device, width, height,
                                             FORMAT_D32_SFLOAT; aspect=IMAGE_ASPECT_DEPTH_BIT)

    # Create render pass with 4 color attachments + depth
    attachments = [
        AttachmentDescription(FORMAT_R16G16B16A16_SFLOAT, SAMPLE_COUNT_1_BIT,
            ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
            ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
            IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
        AttachmentDescription(FORMAT_R16G16B16A16_SFLOAT, SAMPLE_COUNT_1_BIT,
            ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
            ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
            IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
        AttachmentDescription(FORMAT_R16G16B16A16_SFLOAT, SAMPLE_COUNT_1_BIT,
            ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
            ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
            IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
        AttachmentDescription(FORMAT_R8G8B8A8_UNORM, SAMPLE_COUNT_1_BIT,
            ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
            ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
            IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
        AttachmentDescription(FORMAT_D32_SFLOAT, SAMPLE_COUNT_1_BIT,
            ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
            ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
            IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
    ]

    color_refs = [
        AttachmentReference(UInt32(0), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
        AttachmentReference(UInt32(1), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
        AttachmentReference(UInt32(2), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
        AttachmentReference(UInt32(3), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
    ]
    depth_ref = AttachmentReference(UInt32(4), IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)

    subpass = SubpassDescription(
        PIPELINE_BIND_POINT_GRAPHICS, [], color_refs, [];
        depth_stencil_attachment=depth_ref
    )

    # EXTERNAL → subpass 0: wait for prior operations
    dep_in = SubpassDependency(
        VK_SUBPASS_EXTERNAL, UInt32(0),
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        AccessFlag(0),
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT | ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        DependencyFlag(0)
    )

    # subpass 0 → EXTERNAL: make color+depth writes visible for subsequent shader reads
    dep_out = SubpassDependency(
        UInt32(0), VK_SUBPASS_EXTERNAL,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT | ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        ACCESS_SHADER_READ_BIT,
        DependencyFlag(0)
    )

    rp = unwrap(create_render_pass(device, RenderPassCreateInfo(attachments, [subpass], [dep_in, dep_out])))

    views = [albedo_metallic.view, normal_roughness.view, emissive_ao.view,
             advanced_material.view, depth.view]
    fb = unwrap(create_framebuffer(device, FramebufferCreateInfo(
        rp, views, UInt32(width), UInt32(height), UInt32(1)
    )))

    return VulkanGBuffer(fb, rp, albedo_metallic, normal_roughness, emissive_ao,
                          advanced_material, depth, Int(width), Int(height))
end

"""
    vk_destroy_render_target!(device, target)

Destroy a VulkanFramebuffer and its resources.
"""
function vk_destroy_render_target!(device::Device, target::VulkanFramebuffer)
    finalize(target.framebuffer)
    finalize(target.render_pass)
    finalize(target.color_view)
    finalize(target.color_image)
    finalize(target.color_memory)
    if target.depth_view !== nothing
        finalize(target.depth_view)
    end
    if target.depth_image !== nothing
        finalize(target.depth_image)
    end
    if target.depth_memory !== nothing
        finalize(target.depth_memory)
    end
    return nothing
end

"""
    vk_destroy_gbuffer!(device, gbuffer)

Destroy a VulkanGBuffer and its resources.
"""
function vk_destroy_gbuffer!(device::Device, gbuffer::VulkanGBuffer)
    finalize(gbuffer.framebuffer)
    finalize(gbuffer.render_pass)
    vk_destroy_texture!(device, gbuffer.albedo_metallic)
    vk_destroy_texture!(device, gbuffer.normal_roughness)
    vk_destroy_texture!(device, gbuffer.emissive_ao)
    vk_destroy_texture!(device, gbuffer.advanced_material)
    vk_destroy_texture!(device, gbuffer.depth)
    return nothing
end

"""
    vk_create_depth_only_render_target(device, physical_device, width, height) -> (Framebuffer, RenderPass, VulkanGPUTexture)

Create a depth-only render target for shadow mapping.
"""
function vk_create_depth_only_render_target(device::Device, physical_device::PhysicalDevice,
                                             width::Integer, height::Integer)
    depth_tex = vk_create_render_target_texture(device, physical_device, width, height,
                                                 FORMAT_D32_SFLOAT; aspect=IMAGE_ASPECT_DEPTH_BIT)

    attachment = AttachmentDescription(
        FORMAT_D32_SFLOAT, SAMPLE_COUNT_1_BIT,
        ATTACHMENT_LOAD_OP_CLEAR, ATTACHMENT_STORE_OP_STORE,
        ATTACHMENT_LOAD_OP_DONT_CARE, ATTACHMENT_STORE_OP_DONT_CARE,
        IMAGE_LAYOUT_UNDEFINED, IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    )

    depth_ref = AttachmentReference(UInt32(0), IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
    subpass = SubpassDescription(
        PIPELINE_BIND_POINT_GRAPHICS, [], [], [];
        depth_stencil_attachment=depth_ref
    )

    dep_in = SubpassDependency(
        VK_SUBPASS_EXTERNAL, UInt32(0),
        PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        AccessFlag(0),
        ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        DependencyFlag(0)
    )

    # subpass 0 → EXTERNAL: make depth writes visible for subsequent shader reads
    dep_out = SubpassDependency(
        UInt32(0), VK_SUBPASS_EXTERNAL,
        PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        ACCESS_SHADER_READ_BIT,
        DependencyFlag(0)
    )

    rp = unwrap(create_render_pass(device, RenderPassCreateInfo([attachment], [subpass], [dep_in, dep_out])))
    fb = unwrap(create_framebuffer(device, FramebufferCreateInfo(
        rp, [depth_tex.view], UInt32(width), UInt32(height), UInt32(1)
    )))

    return fb, rp, depth_tex
end
