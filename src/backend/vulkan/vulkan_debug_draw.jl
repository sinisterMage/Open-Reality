# Vulkan debug line renderer — colored lines with no depth test

const VK_DEBUG_LINE_VERT = """
#version 450

layout(push_constant) uniform DebugPC {
    mat4 view_proj;
} pc;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inColor;

layout(location = 0) out vec3 fragColor;

void main() {
    fragColor = inColor;
    gl_Position = pc.view_proj * vec4(inPosition, 1.0);
}
"""

const VK_DEBUG_LINE_FRAG = """
#version 450

layout(location = 0) in vec3 fragColor;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(fragColor, 1.0);
}
"""

"""
    vk_init_debug_draw!(renderer, device, physical_device, render_pass, width, height)

Create the debug line rendering pipeline. Uses the UI overlay render pass (LOAD_OP_LOAD)
so debug lines are rendered on top of the scene.
"""
function vk_init_debug_draw!(renderer::VulkanDebugDrawRenderer, device::Device,
                              physical_device::PhysicalDevice, render_pass::RenderPass,
                              width::Int, height::Int)
    renderer.initialized && return

    push_range = PushConstantRange(SHADER_STAGE_VERTEX_BIT, UInt32(0), UInt32(64))

    # Vertex input: position (vec3) + color (vec3) = 24 bytes interleaved
    vertex_bindings = [
        VertexInputBindingDescription(UInt32(0), UInt32(6 * sizeof(Float32)), VERTEX_INPUT_RATE_VERTEX),
    ]
    vertex_attributes = [
        VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32B32_SFLOAT, UInt32(0)),                      # position
        VertexInputAttributeDescription(UInt32(1), UInt32(0), FORMAT_R32G32B32_SFLOAT, UInt32(3 * sizeof(Float32))),     # color
    ]

    config = VulkanPipelineConfig(
        render_pass, UInt32(0),
        vertex_bindings, vertex_attributes,
        DescriptorSetLayout[],
        [push_range],
        false,  # no blend
        false,  # no depth test
        false,  # no depth write
        CULL_MODE_NONE,
        FRONT_FACE_COUNTER_CLOCKWISE,
        1,      # 1 color attachment
        width, height;
        topology=PRIMITIVE_TOPOLOGY_LINE_LIST
    )
    renderer.pipeline = vk_compile_and_create_pipeline(
        device, VK_DEBUG_LINE_VERT, VK_DEBUG_LINE_FRAG, config)

    renderer.initialized = true
    return nothing
end

"""
    vk_render_debug_draw!(cmd, renderer, backend, view, proj, image_index)

Render all accumulated debug lines for this frame. Reads from `_DEBUG_LINES`.
"""
function vk_render_debug_draw!(cmd::CommandBuffer, renderer::VulkanDebugDrawRenderer,
                                backend::VulkanBackend, view::Mat4f, proj::Mat4f,
                                image_index::Int)
    !renderer.initialized && return
    !OPENREALITY_DEBUG && return

    n = length(_DEBUG_LINES)
    n == 0 && return

    device = backend.device
    physical_device = backend.physical_device

    # Pack vertex data: 2 vertices per line, 6 floats per vertex (pos3 + color3)
    floats_per_vertex = 6
    vertex_count = 2 * n
    data = Vector{Float32}(undef, vertex_count * floats_per_vertex)

    for i in 1:n
        line = _DEBUG_LINES[i]
        base = (i - 1) * 2 * floats_per_vertex

        # Start vertex
        data[base + 1] = line.start_pos[1]
        data[base + 2] = line.start_pos[2]
        data[base + 3] = line.start_pos[3]
        data[base + 4] = line.color.r
        data[base + 5] = line.color.g
        data[base + 6] = line.color.b

        # End vertex
        data[base + 7] = line.end_pos[1]
        data[base + 8] = line.end_pos[2]
        data[base + 9] = line.end_pos[3]
        data[base + 10] = line.color.r
        data[base + 11] = line.color.g
        data[base + 12] = line.color.b
    end

    byte_size = vertex_count * floats_per_vertex * sizeof(Float32)

    # Grow VBO if needed
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

    # Upload vertex data
    ptr = unwrap(map_memory(device, renderer.vertex_memory, UInt64(0), UInt64(byte_size)))
    GC.@preserve data begin
        unsafe_copyto!(Ptr{UInt8}(ptr), Ptr{UInt8}(pointer(data)), byte_size)
    end
    unmap_memory(device, renderer.vertex_memory)

    # Begin render pass (overlay on swapchain, LOAD_OP_LOAD)
    fb = backend.swapchain_framebuffers[image_index + 1]
    extent = backend.swapchain_extent
    w = Int(extent.width)
    h = Int(extent.height)

    rp_begin = RenderPassBeginInfo(
        backend.ui_renderer.render_pass, fb,
        Rect2D(Offset2D(0, 0), extent),
        ClearValue[]
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)

    cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, renderer.pipeline.pipeline)

    # Viewport + scissor
    cmd_set_viewport(cmd, [Viewport(0.0f0, 0.0f0, Float32(w), Float32(h), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd, [Rect2D(Offset2D(0, 0), extent)])

    # Push view_proj matrix
    vp = proj * view
    vp_data = Float32[vp[i] for i in 1:16]
    GC.@preserve vp_data begin
        cmd_push_constants(cmd, renderer.pipeline.pipeline_layout,
            SHADER_STAGE_VERTEX_BIT, UInt32(0), UInt32(64), Ptr{Cvoid}(pointer(vp_data)))
    end

    # Bind VBO and draw
    cmd_bind_vertex_buffers(cmd, [renderer.vertex_buffer], [UInt64(0)])
    cmd_draw(cmd, UInt32(vertex_count), UInt32(1), UInt32(0), UInt32(0))

    cmd_end_render_pass(cmd)
    return nothing
end

"""
    vk_destroy_debug_draw!(device, renderer)

Destroy the debug draw renderer and free its resources.
"""
function vk_destroy_debug_draw!(device::Device, renderer::VulkanDebugDrawRenderer)
    if renderer.pipeline !== nothing
        finalize(renderer.pipeline.pipeline)
        finalize(renderer.pipeline.pipeline_layout)
        renderer.pipeline.vert_module !== nothing && finalize(renderer.pipeline.vert_module)
        renderer.pipeline.frag_module !== nothing && finalize(renderer.pipeline.frag_module)
    end
    if renderer.vertex_buffer !== nothing
        finalize(renderer.vertex_buffer)
        finalize(renderer.vertex_memory)
    end
    renderer.initialized = false
    return nothing
end
