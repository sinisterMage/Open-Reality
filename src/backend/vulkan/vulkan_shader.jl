# Vulkan shader compilation (GLSL → SPIR-V via glslang) and pipeline creation

using glslang_jll

# ==================================================================
# SPIR-V Compilation
# ==================================================================

"""
    vk_compile_glsl_to_spirv(source::String, stage::Symbol) -> Vector{UInt32}

Compile GLSL source to SPIR-V bytecode using glslangValidator.
`stage` should be :vert, :frag, :comp, :geom, :tesc, or :tese.
"""
function vk_compile_glsl_to_spirv(source::String, stage::Symbol)
    stage_str = String(stage)

    # Write source to temp file
    tmp_src = tempname() * ".glsl"
    tmp_spv = tempname() * ".spv"

    try
        write(tmp_src, source)

        # Compile using glslangValidator
        glslang_path = glslang_jll.glslangValidator_path
        cmd = `$glslang_path -V -S $stage_str -o $tmp_spv $tmp_src`
        output = IOBuffer()
        err_output = IOBuffer()
        proc = run(pipeline(cmd; stderr=err_output, stdout=output); wait=true)

        if proc.exitcode != 0
            error_msg = String(take!(err_output))
            error("GLSL compilation failed for $stage shader:\n$error_msg")
        end

        # Read compiled SPIR-V
        spv_bytes = read(tmp_spv)
        spv_words = reinterpret(UInt32, spv_bytes)
        return Vector{UInt32}(spv_words)
    finally
        isfile(tmp_src) && rm(tmp_src)
        isfile(tmp_spv) && rm(tmp_spv)
    end
end

"""
    vk_create_shader_module(device, spirv_code) -> ShaderModule
"""
function vk_create_shader_module(device::Device, spirv_code::Vector{UInt32})
    info = ShaderModuleCreateInfo(length(spirv_code) * sizeof(UInt32), spirv_code)
    return unwrap(create_shader_module(device, info))
end

# ==================================================================
# Graphics Pipeline Creation
# ==================================================================

"""
    VulkanPipelineConfig

Configuration for creating a Vulkan graphics pipeline.
"""
struct VulkanPipelineConfig
    render_pass::RenderPass
    subpass::UInt32
    vertex_bindings::Vector{VertexInputBindingDescription}
    vertex_attributes::Vector{VertexInputAttributeDescription}
    descriptor_set_layouts::Vector{DescriptorSetLayout}
    push_constant_ranges::Vector{PushConstantRange}
    blend_enable::Bool
    depth_test::Bool
    depth_write::Bool
    cull_mode::CullModeFlag
    front_face::FrontFace
    color_attachment_count::Int
    width::Int
    height::Int
    topology::PrimitiveTopology
end

# Backward-compatible constructor: topology defaults to TRIANGLE_LIST
function VulkanPipelineConfig(render_pass, subpass, vertex_bindings, vertex_attributes,
                               descriptor_set_layouts, push_constant_ranges,
                               blend_enable, depth_test, depth_write,
                               cull_mode, front_face, color_attachment_count, width, height;
                               topology=PRIMITIVE_TOPOLOGY_TRIANGLE_LIST)
    VulkanPipelineConfig(render_pass, subpass, vertex_bindings, vertex_attributes,
                          descriptor_set_layouts, push_constant_ranges,
                          blend_enable, depth_test, depth_write,
                          cull_mode, front_face, color_attachment_count, width, height,
                          topology)
end

"""
    vk_standard_vertex_bindings() -> Vector{VertexInputBindingDescription}

Standard vertex input bindings: positions (0), normals (1), UVs (2).
"""
function vk_standard_vertex_bindings()
    return [
        VertexInputBindingDescription(UInt32(0), UInt32(sizeof(Point3f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(1), UInt32(sizeof(Vec3f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(2), UInt32(sizeof(Vec2f)), VERTEX_INPUT_RATE_VERTEX),
    ]
end

"""
    vk_standard_vertex_attributes() -> Vector{VertexInputAttributeDescription}

Standard vertex input attributes matching layout locations 0=position, 1=normal, 2=UV.
"""
function vk_standard_vertex_attributes()
    return [
        VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32B32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(1), UInt32(1), FORMAT_R32G32B32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(2), UInt32(2), FORMAT_R32G32_SFLOAT, UInt32(0)),
    ]
end

"""
    vk_skinned_vertex_bindings() -> Vector{VertexInputBindingDescription}

Vertex input bindings for skinned meshes: positions (0), normals (1), UVs (2),
bone weights (3), bone indices (4).
"""
function vk_skinned_vertex_bindings()
    return [
        VertexInputBindingDescription(UInt32(0), UInt32(sizeof(Point3f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(1), UInt32(sizeof(Vec3f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(2), UInt32(sizeof(Vec2f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(3), UInt32(4 * sizeof(Float32)), VERTEX_INPUT_RATE_VERTEX),  # vec4 bone weights
        VertexInputBindingDescription(UInt32(4), UInt32(4 * sizeof(UInt16)), VERTEX_INPUT_RATE_VERTEX),   # uvec4 bone indices
    ]
end

"""
    vk_skinned_vertex_attributes() -> Vector{VertexInputAttributeDescription}

Vertex attributes for skinned meshes: position (0), normal (1), UV (2),
bone weights (3, vec4 float), bone indices (4, uvec4 uint16).
"""
function vk_skinned_vertex_attributes()
    return [
        VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32B32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(1), UInt32(1), FORMAT_R32G32B32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(2), UInt32(2), FORMAT_R32G32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(3), UInt32(3), FORMAT_R32G32B32A32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(4), UInt32(4), FORMAT_R16G16B16A16_UINT, UInt32(0)),
    ]
end

"""
    vk_instanced_vertex_bindings() -> Vector{VertexInputBindingDescription}

Vertex input bindings for instanced rendering: positions (0), normals (1), UVs (2),
instance data (3, per-instance rate: model mat4 + normal mat3 = 100 bytes stride).
"""
function vk_instanced_vertex_bindings()
    return [
        VertexInputBindingDescription(UInt32(0), UInt32(sizeof(Point3f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(1), UInt32(sizeof(Vec3f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(2), UInt32(sizeof(Vec2f)), VERTEX_INPUT_RATE_VERTEX),
        VertexInputBindingDescription(UInt32(3), UInt32(VK_INSTANCE_STRIDE), VERTEX_INPUT_RATE_INSTANCE),
    ]
end

"""
    vk_instanced_vertex_attributes() -> Vector{VertexInputAttributeDescription}

Vertex attributes for instanced rendering: position (0), normal (1), UV (2),
model matrix columns (5-8, per-instance), normal matrix columns (9-11, per-instance).
"""
function vk_instanced_vertex_attributes()
    return [
        # Per-vertex
        VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32B32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(1), UInt32(1), FORMAT_R32G32B32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(2), UInt32(2), FORMAT_R32G32_SFLOAT, UInt32(0)),
        # Per-instance: model matrix columns (binding 3, locations 5-8)
        VertexInputAttributeDescription(UInt32(5), UInt32(3), FORMAT_R32G32B32A32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(6), UInt32(3), FORMAT_R32G32B32A32_SFLOAT, UInt32(16)),
        VertexInputAttributeDescription(UInt32(7), UInt32(3), FORMAT_R32G32B32A32_SFLOAT, UInt32(32)),
        VertexInputAttributeDescription(UInt32(8), UInt32(3), FORMAT_R32G32B32A32_SFLOAT, UInt32(48)),
        # Per-instance: normal matrix columns (binding 3, locations 9-11)
        VertexInputAttributeDescription(UInt32(9), UInt32(3), FORMAT_R32G32B32_SFLOAT, UInt32(64)),
        VertexInputAttributeDescription(UInt32(10), UInt32(3), FORMAT_R32G32B32_SFLOAT, UInt32(76)),
        VertexInputAttributeDescription(UInt32(11), UInt32(3), FORMAT_R32G32B32_SFLOAT, UInt32(88)),
    ]
end

"""
    vk_fullscreen_vertex_bindings() -> Vector{VertexInputBindingDescription}

Vertex binding for fullscreen quad (position + UV interleaved).
"""
function vk_fullscreen_vertex_bindings()
    return [
        VertexInputBindingDescription(UInt32(0), UInt32(4 * sizeof(Float32)), VERTEX_INPUT_RATE_VERTEX),
    ]
end

"""
    vk_fullscreen_vertex_attributes() -> Vector{VertexInputAttributeDescription}

Vertex attributes for fullscreen quad: position (location 0, vec2), UV (location 1, vec2).
"""
function vk_fullscreen_vertex_attributes()
    return [
        VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32_SFLOAT, UInt32(0)),
        VertexInputAttributeDescription(UInt32(1), UInt32(0), FORMAT_R32G32_SFLOAT, UInt32(2 * sizeof(Float32))),
    ]
end

"""
    vk_create_graphics_pipeline(device, vert_spirv, frag_spirv, config) -> VulkanShaderProgram

Create a complete graphics pipeline from SPIR-V vertex and fragment shaders.
"""
function vk_create_graphics_pipeline(device::Device, vert_spirv::Vector{UInt32},
                                      frag_spirv::Vector{UInt32}, config::VulkanPipelineConfig)
    vert_module = vk_create_shader_module(device, vert_spirv)
    frag_module = vk_create_shader_module(device, frag_spirv)

    vert_stage = PipelineShaderStageCreateInfo(
        SHADER_STAGE_VERTEX_BIT, vert_module, "main"
    )
    frag_stage = PipelineShaderStageCreateInfo(
        SHADER_STAGE_FRAGMENT_BIT, frag_module, "main"
    )

    vertex_input = PipelineVertexInputStateCreateInfo(
        config.vertex_bindings, config.vertex_attributes
    )

    input_assembly = PipelineInputAssemblyStateCreateInfo(
        config.topology, false
    )

    viewport = Viewport(0.0f0, 0.0f0, Float32(config.width), Float32(config.height), 0.0f0, 1.0f0)
    scissor = Rect2D(Offset2D(0, 0), Extent2D(UInt32(config.width), UInt32(config.height)))
    viewport_state = PipelineViewportStateCreateInfo(;
        viewports=[viewport], scissors=[scissor]
    )

    rasterizer = PipelineRasterizationStateCreateInfo(
        false,  # depth_clamp_enable
        false,  # rasterizer_discard_enable
        POLYGON_MODE_FILL,
        config.front_face,
        false,  # depth_bias_enable
        0.0f0, 0.0f0, 0.0f0,  # depth bias constant/clamp/slope
        1.0f0;  # line_width
        cull_mode=config.cull_mode
    )

    multisample = PipelineMultisampleStateCreateInfo(
        SAMPLE_COUNT_1_BIT, false, 1.0f0, false, false
    )

    depth_stencil = PipelineDepthStencilStateCreateInfo(
        config.depth_test,
        config.depth_write,
        COMPARE_OP_LESS,
        false,  # depth bounds test
        false,  # stencil test
        StencilOpState(STENCIL_OP_KEEP, STENCIL_OP_KEEP, STENCIL_OP_KEEP, COMPARE_OP_ALWAYS, 0, 0, 0),
        StencilOpState(STENCIL_OP_KEEP, STENCIL_OP_KEEP, STENCIL_OP_KEEP, COMPARE_OP_ALWAYS, 0, 0, 0),
        0.0f0, 1.0f0
    )

    blend_attachments = [
        PipelineColorBlendAttachmentState(
            config.blend_enable,
            BLEND_FACTOR_SRC_ALPHA,
            BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            BLEND_OP_ADD,
            BLEND_FACTOR_ONE,
            BLEND_FACTOR_ZERO,
            BLEND_OP_ADD,
            COLOR_COMPONENT_R_BIT | COLOR_COMPONENT_G_BIT | COLOR_COMPONENT_B_BIT | COLOR_COMPONENT_A_BIT
        )
        for _ in 1:config.color_attachment_count
    ]

    color_blend = PipelineColorBlendStateCreateInfo(
        false,  # logic_op_enable
        LOGIC_OP_COPY,
        blend_attachments,
        (0.0f0, 0.0f0, 0.0f0, 0.0f0)
    )

    # Dynamic state for viewport and scissor
    dynamic_states = [DYNAMIC_STATE_VIEWPORT, DYNAMIC_STATE_SCISSOR]
    dynamic_state = PipelineDynamicStateCreateInfo(dynamic_states)

    layout_info = PipelineLayoutCreateInfo(
        config.descriptor_set_layouts,
        config.push_constant_ranges
    )
    pipeline_layout = unwrap(create_pipeline_layout(device, layout_info))

    pipeline_info = GraphicsPipelineCreateInfo(
        [vert_stage, frag_stage],
        rasterizer,
        pipeline_layout,
        config.subpass,
        Int32(-1);  # base_pipeline_index
        render_pass=config.render_pass,
        vertex_input_state=vertex_input,
        input_assembly_state=input_assembly,
        viewport_state=viewport_state,
        multisample_state=multisample,
        depth_stencil_state=depth_stencil,
        color_blend_state=color_blend,
        dynamic_state=dynamic_state
    )

    pipelines, _ = unwrap(create_graphics_pipelines(device, [pipeline_info]))
    pipeline = pipelines[1]

    return VulkanShaderProgram(pipeline, pipeline_layout, config.descriptor_set_layouts;
                               vert=vert_module, frag=frag_module)
end

"""
    vk_compile_and_create_pipeline(device, vert_src, frag_src, config) -> VulkanShaderProgram

Convenience: compile GLSL sources to SPIR-V and create a graphics pipeline.
"""
function vk_compile_and_create_pipeline(device::Device, vert_src::String, frag_src::String,
                                         config::VulkanPipelineConfig)
    vert_spirv = vk_compile_glsl_to_spirv(vert_src, :vert)
    frag_spirv = vk_compile_glsl_to_spirv(frag_src, :frag)
    return vk_create_graphics_pipeline(device, vert_spirv, frag_spirv, config)
end

# ==================================================================
# Pipeline Cache
# ==================================================================

"""
Global pipeline cache keyed by (vertex_hash, fragment_hash, render_pass) for reuse.
"""
const _VK_PIPELINE_CACHE = Dict{UInt64, VulkanShaderProgram}()

function vk_pipeline_cache_key(vert_src::String, frag_src::String, render_pass_handle::UInt64)
    h = hash(vert_src)
    h = hash(frag_src, h)
    h = hash(render_pass_handle, h)
    return h
end

function vk_destroy_all_cached_pipelines!(device::Device)
    for (_, prog) in _VK_PIPELINE_CACHE
        finalize(prog.pipeline)
        finalize(prog.pipeline_layout)
        prog.vert_module !== nothing && finalize(prog.vert_module)
        prog.frag_module !== nothing && finalize(prog.frag_module)
    end
    empty!(_VK_PIPELINE_CACHE)
    return nothing
end
