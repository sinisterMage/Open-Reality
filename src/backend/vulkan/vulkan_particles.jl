# Vulkan particle rendering — CPU billboard particles with alpha/additive blending

const VK_PARTICLE_VERT = """
#version 450

layout(push_constant) uniform ParticlePC {
    mat4 view;
    mat4 projection;
} pc;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inTexCoord;
layout(location = 2) in vec4 inColor;

layout(location = 0) out vec2 fragTexCoord;
layout(location = 1) out vec4 fragColor;

void main() {
    fragTexCoord = inTexCoord;
    fragColor = inColor;
    gl_Position = pc.projection * pc.view * vec4(inPosition, 1.0);
}
"""

const VK_PARTICLE_FRAG = """
#version 450

layout(location = 0) in vec2 fragTexCoord;
layout(location = 1) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

void main() {
    // Soft circular falloff (procedural, no texture needed)
    vec2 center = fragTexCoord - vec2(0.5);
    float dist = dot(center, center) * 4.0;
    float alpha = 1.0 - smoothstep(0.5, 1.0, dist);

    outColor = vec4(fragColor.rgb, fragColor.a * alpha);
    if (outColor.a < 0.01) discard;
}
"""

"""
    vk_init_particles!(renderer, device, physical_device, render_pass, width, height)

Create particle rendering pipelines (alpha blend + additive blend).
Uses the UI overlay render pass (LOAD_OP_LOAD) so particles are rendered on top of the present output.
"""
function vk_init_particles!(renderer::VulkanParticleRenderer, device::Device,
                             physical_device::PhysicalDevice, render_pass::RenderPass,
                             width::Int, height::Int)
    renderer.initialized && return

    renderer.push_constant_range = PushConstantRange(
        SHADER_STAGE_VERTEX_BIT, UInt32(0), UInt32(128)
    )

    # Vertex input: position (vec3) + texcoord (vec2) + color (vec4) = 36 bytes interleaved
    vertex_bindings = [
        VertexInputBindingDescription(UInt32(0), UInt32(9 * sizeof(Float32)), VERTEX_INPUT_RATE_VERTEX),
    ]
    vertex_attributes = [
        VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32B32_SFLOAT, UInt32(0)),                      # position
        VertexInputAttributeDescription(UInt32(1), UInt32(0), FORMAT_R32G32_SFLOAT, UInt32(3 * sizeof(Float32))),        # texcoord
        VertexInputAttributeDescription(UInt32(2), UInt32(0), FORMAT_R32G32B32A32_SFLOAT, UInt32(5 * sizeof(Float32))),  # color
    ]

    # Alpha blend pipeline (src_alpha, one_minus_src_alpha)
    alpha_config = VulkanPipelineConfig(
        render_pass, UInt32(0),
        vertex_bindings, vertex_attributes,
        DescriptorSetLayout[],  # No descriptor sets — everything via push constants
        [renderer.push_constant_range],
        true,   # blend enabled
        false,  # no depth test (swapchain depth is irrelevant after present)
        false,  # no depth write
        CULL_MODE_NONE,
        FRONT_FACE_COUNTER_CLOCKWISE,
        1,      # 1 color attachment
        width, height
    )
    renderer.alpha_pipeline = vk_compile_and_create_pipeline(
        device, VK_PARTICLE_VERT, VK_PARTICLE_FRAG, alpha_config)

    # Additive blend pipeline — need custom blend (src_alpha, one)
    # We create a separate pipeline with additive blend factors
    renderer.additive_pipeline = _vk_create_additive_particle_pipeline(
        device, render_pass, vertex_bindings, vertex_attributes,
        renderer.push_constant_range, width, height)

    renderer.initialized = true
    return nothing
end

function _vk_create_additive_particle_pipeline(device::Device, render_pass::RenderPass,
                                                 vertex_bindings, vertex_attributes,
                                                 push_constant_range::PushConstantRange,
                                                 width::Int, height::Int)
    vert_spirv = vk_compile_glsl_to_spirv(VK_PARTICLE_VERT, :vert)
    frag_spirv = vk_compile_glsl_to_spirv(VK_PARTICLE_FRAG, :frag)

    vert_module = vk_create_shader_module(device, vert_spirv)
    frag_module = vk_create_shader_module(device, frag_spirv)

    vert_stage = PipelineShaderStageCreateInfo(SHADER_STAGE_VERTEX_BIT, vert_module, "main")
    frag_stage = PipelineShaderStageCreateInfo(SHADER_STAGE_FRAGMENT_BIT, frag_module, "main")

    vertex_input = PipelineVertexInputStateCreateInfo(vertex_bindings, vertex_attributes)
    input_assembly = PipelineInputAssemblyStateCreateInfo(PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, false)

    viewport = Viewport(0.0f0, 0.0f0, Float32(width), Float32(height), 0.0f0, 1.0f0)
    scissor = Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height)))
    viewport_state = PipelineViewportStateCreateInfo(; viewports=[viewport], scissors=[scissor])

    rasterizer = PipelineRasterizationStateCreateInfo(
        false, false, POLYGON_MODE_FILL, FRONT_FACE_COUNTER_CLOCKWISE,
        false, 0.0f0, 0.0f0, 0.0f0, 1.0f0;
        cull_mode=CULL_MODE_NONE
    )

    multisample = PipelineMultisampleStateCreateInfo(SAMPLE_COUNT_1_BIT, false, 1.0f0, false, false)

    depth_stencil = PipelineDepthStencilStateCreateInfo(
        false, false, COMPARE_OP_LESS, false, false,
        StencilOpState(STENCIL_OP_KEEP, STENCIL_OP_KEEP, STENCIL_OP_KEEP, COMPARE_OP_ALWAYS, 0, 0, 0),
        StencilOpState(STENCIL_OP_KEEP, STENCIL_OP_KEEP, STENCIL_OP_KEEP, COMPARE_OP_ALWAYS, 0, 0, 0),
        0.0f0, 1.0f0
    )

    # Additive blend: src_alpha + ONE
    blend_attachment = PipelineColorBlendAttachmentState(
        true,  # blend enable
        BLEND_FACTOR_SRC_ALPHA,       # src color
        BLEND_FACTOR_ONE,             # dst color (additive!)
        BLEND_OP_ADD,
        BLEND_FACTOR_SRC_ALPHA,
        BLEND_FACTOR_ONE,
        BLEND_OP_ADD,
        COLOR_COMPONENT_R_BIT | COLOR_COMPONENT_G_BIT | COLOR_COMPONENT_B_BIT | COLOR_COMPONENT_A_BIT
    )

    color_blend = PipelineColorBlendStateCreateInfo(
        false, LOGIC_OP_COPY, [blend_attachment], (0.0f0, 0.0f0, 0.0f0, 0.0f0)
    )

    dynamic_states = [DYNAMIC_STATE_VIEWPORT, DYNAMIC_STATE_SCISSOR]
    dynamic_state = PipelineDynamicStateCreateInfo(dynamic_states)

    layout_info = PipelineLayoutCreateInfo(DescriptorSetLayout[], [push_constant_range])
    pipeline_layout = unwrap(create_pipeline_layout(device, layout_info))

    pipeline_info = GraphicsPipelineCreateInfo(
        [vert_stage, frag_stage],
        rasterizer,
        pipeline_layout,
        UInt32(0), Int32(-1);
        render_pass=render_pass,
        vertex_input_state=vertex_input,
        input_assembly_state=input_assembly,
        viewport_state=viewport_state,
        multisample_state=multisample,
        depth_stencil_state=depth_stencil,
        color_blend_state=color_blend,
        dynamic_state=dynamic_state
    )

    pipelines, _ = unwrap(create_graphics_pipelines(device, [pipeline_info]))
    return VulkanShaderProgram(pipelines[1], pipeline_layout, DescriptorSetLayout[];
                                vert=vert_module, frag=frag_module)
end

"""
    vk_render_particles!(cmd, renderer, backend, view, proj, image_index)

Render all particle emitters as an overlay on the swapchain image.
Uses the UI overlay render pass (shared).
"""
function vk_render_particles!(cmd::CommandBuffer, renderer::VulkanParticleRenderer,
                               backend::VulkanBackend, view::Mat4f, proj::Mat4f,
                               image_index::Int)
    !renderer.initialized && return
    isempty(PARTICLE_POOLS) && return

    device = backend.device
    w = Int(backend.swapchain_extent.width)
    h = Int(backend.swapchain_extent.height)

    # Flip Y for Vulkan
    vk_proj = Mat4f(
        proj[1], proj[2], proj[3], proj[4],
        proj[5], -proj[6], proj[7], proj[8],
        proj[9], proj[10], proj[11], proj[12],
        proj[13], proj[14], proj[15], proj[16]
    )

    # Begin overlay render pass (shared with UI — preserves present output)
    rp_begin = RenderPassBeginInfo(
        backend.ui_renderer.render_pass,
        backend.swapchain_framebuffers[image_index],
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(w), UInt32(h))),
        ClearValue[]
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)

    cmd_set_viewport(cmd, [Viewport(0.0f0, 0.0f0, Float32(w), Float32(h), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd, [Rect2D(Offset2D(0, 0), Extent2D(UInt32(w), UInt32(h)))])

    # Push view + projection matrices
    push_data = (view, vk_proj)
    push_ref = Ref(push_data)
    GC.@preserve push_ref begin
        push_ptr = Base.unsafe_convert(Ptr{Cvoid}, Base.cconvert(Ptr{Cvoid}, push_ref))

        for (eid, pool) in PARTICLE_POOLS
            pool.vertex_count <= 0 && continue

            # Determine blend mode
            comp = get_component(eid, ParticleSystemComponent)
            is_additive = comp !== nothing && comp.additive
            pipeline = is_additive ? renderer.additive_pipeline : renderer.alpha_pipeline
            pipeline === nothing && continue

            cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline)

            cmd_push_constants(cmd, pipeline.pipeline_layout,
                SHADER_STAGE_VERTEX_BIT, UInt32(0), UInt32(128), push_ptr)

            # Upload vertex data
            byte_size = pool.vertex_count * 9 * sizeof(Float32)
            _vk_particle_upload_vertices!(renderer, device, backend.physical_device,
                pool.vertex_data, byte_size)

            renderer.vertex_buffer === nothing && continue

            cmd_bind_vertex_buffers(cmd, [renderer.vertex_buffer], [UInt64(0)])
            cmd_draw(cmd, UInt32(pool.vertex_count), UInt32(1), UInt32(0), UInt32(0))
        end
    end

    cmd_end_render_pass(cmd)
    return nothing
end

function _vk_particle_upload_vertices!(renderer::VulkanParticleRenderer, device::Device,
                                        physical_device::PhysicalDevice,
                                        vertex_data::Vector{Float32}, byte_size::Int)
    byte_size <= 0 && return

    if byte_size > renderer.vertex_capacity
        if renderer.vertex_buffer !== nothing
            finalize(renderer.vertex_buffer)
            finalize(renderer.vertex_memory)
        end
        new_capacity = max(byte_size, renderer.vertex_capacity * 2, 4096)
        renderer.vertex_buffer, renderer.vertex_memory = vk_create_buffer(
            device, physical_device, new_capacity,
            BUFFER_USAGE_VERTEX_BUFFER_BIT,
            MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
        )
        renderer.vertex_capacity = new_capacity
    end

    ptr = unwrap(map_memory(device, renderer.vertex_memory, UInt64(0), UInt64(byte_size)))
    GC.@preserve vertex_data begin
        unsafe_copyto!(Ptr{UInt8}(ptr), Ptr{UInt8}(pointer(vertex_data)), byte_size)
    end
    unmap_memory(device, renderer.vertex_memory)
    return nothing
end

"""
    vk_destroy_particles!(device, renderer)

Destroy Vulkan particle renderer resources.
"""
function vk_destroy_particles!(device::Device, renderer::VulkanParticleRenderer)
    !renderer.initialized && return

    for pipeline in (renderer.alpha_pipeline, renderer.additive_pipeline)
        if pipeline !== nothing
            finalize(pipeline.pipeline)
            finalize(pipeline.pipeline_layout)
            pipeline.vert_module !== nothing && finalize(pipeline.vert_module)
            pipeline.frag_module !== nothing && finalize(pipeline.frag_module)
        end
    end

    if renderer.vertex_buffer !== nothing
        finalize(renderer.vertex_buffer)
        finalize(renderer.vertex_memory)
    end

    renderer.initialized = false
    return nothing
end
