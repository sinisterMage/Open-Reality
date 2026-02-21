# Vulkan UI rendering — overlay pass for immediate-mode UI

const VK_UI_VERT = """
#version 450

layout(set = 0, binding = 0) uniform UIProjection {
    mat4 projection;
} ubo;

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inTexCoord;
layout(location = 2) in vec4 inColor;

layout(location = 0) out vec2 fragTexCoord;
layout(location = 1) out vec4 fragColor;

void main() {
    fragTexCoord = inTexCoord;
    fragColor = inColor;
    gl_Position = ubo.projection * vec4(inPosition, 0.0, 1.0);
}
"""

const VK_UI_FRAG = """
#version 450

layout(set = 0, binding = 1) uniform sampler2D uTexture;

layout(push_constant) uniform UIParams {
    int has_texture;
    int is_font;
} params;

layout(location = 0) in vec2 fragTexCoord;
layout(location = 1) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

void main() {
    if (params.has_texture != 0) {
        if (params.is_font != 0) {
            float alpha = texture(uTexture, fragTexCoord).r;
            outColor = vec4(fragColor.rgb, fragColor.a * alpha);
        } else {
            vec4 texColor = texture(uTexture, fragTexCoord);
            outColor = texColor * fragColor;
        }
    } else {
        outColor = fragColor;
    }
}
"""

"""
    vk_create_ui_render_pass(device, color_format) -> RenderPass

Create a render pass for UI overlay that loads (preserves) existing swapchain content.
"""
function vk_create_ui_render_pass(device::Device, color_format::Format)
    color_attachment = AttachmentDescription(
        color_format,
        SAMPLE_COUNT_1_BIT,
        ATTACHMENT_LOAD_OP_LOAD,       # preserve present pass output
        ATTACHMENT_STORE_OP_STORE,
        ATTACHMENT_LOAD_OP_DONT_CARE,
        ATTACHMENT_STORE_OP_DONT_CARE,
        IMAGE_LAYOUT_PRESENT_SRC_KHR,  # present pass left it here
        IMAGE_LAYOUT_PRESENT_SRC_KHR   # keep it presentable
    )

    depth_attachment = AttachmentDescription(
        FORMAT_D32_SFLOAT,
        SAMPLE_COUNT_1_BIT,
        ATTACHMENT_LOAD_OP_DONT_CARE,
        ATTACHMENT_STORE_OP_DONT_CARE,
        ATTACHMENT_LOAD_OP_DONT_CARE,
        ATTACHMENT_STORE_OP_DONT_CARE,
        IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    )

    color_ref = AttachmentReference(UInt32(0), IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    depth_ref = AttachmentReference(UInt32(1), IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)

    subpass = SubpassDescription(
        PIPELINE_BIND_POINT_GRAPHICS,
        [],          # input attachments
        [color_ref], # color attachments
        [];          # resolve attachments
        depth_stencil_attachment=depth_ref
    )

    dependency = SubpassDependency(
        VK_SUBPASS_EXTERNAL, UInt32(0),
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        AccessFlag(0),
        ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        DependencyFlag(0)
    )

    rp_info = RenderPassCreateInfo(
        [color_attachment, depth_attachment],
        [subpass],
        [dependency]
    )

    return unwrap(create_render_pass(device, rp_info))
end

"""
    vk_init_ui!(renderer, device, physical_device, command_pool, queue, color_format, width, height)

Initialize Vulkan UI renderer: render pass, pipeline, descriptor layout, buffers.
"""
function vk_init_ui!(renderer::VulkanUIRenderer, device::Device,
                      physical_device::PhysicalDevice, command_pool::CommandPool,
                      queue::Queue, color_format::Format, width::Int, height::Int)
    renderer.initialized && return

    # Create UI render pass (loads existing swapchain content)
    renderer.render_pass = vk_create_ui_render_pass(device, color_format)

    # Descriptor set layout: binding 0 = UBO (projection), binding 1 = sampler (texture)
    bindings = [
        DescriptorSetLayoutBinding(
            UInt32(0), DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            SHADER_STAGE_VERTEX_BIT;
            descriptor_count=1
        ),
        DescriptorSetLayoutBinding(
            UInt32(1), DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            SHADER_STAGE_FRAGMENT_BIT;
            descriptor_count=1
        ),
    ]
    renderer.descriptor_set_layout = unwrap(create_descriptor_set_layout(
        device, DescriptorSetLayoutCreateInfo(bindings)
    ))

    # Push constants: has_texture (int32) + is_font (int32) = 8 bytes
    renderer.push_constant_range = PushConstantRange(
        SHADER_STAGE_FRAGMENT_BIT, UInt32(0), UInt32(8)
    )

    # Vertex input: position (vec2) + texcoord (vec2) + color (vec4) = 32 bytes interleaved
    vertex_bindings = [
        VertexInputBindingDescription(UInt32(0), UInt32(8 * sizeof(Float32)), VERTEX_INPUT_RATE_VERTEX),
    ]
    vertex_attributes = [
        VertexInputAttributeDescription(UInt32(0), UInt32(0), FORMAT_R32G32_SFLOAT, UInt32(0)),                         # position
        VertexInputAttributeDescription(UInt32(1), UInt32(0), FORMAT_R32G32_SFLOAT, UInt32(2 * sizeof(Float32))),        # texcoord
        VertexInputAttributeDescription(UInt32(2), UInt32(0), FORMAT_R32G32B32A32_SFLOAT, UInt32(4 * sizeof(Float32))),  # color
    ]

    config = VulkanPipelineConfig(
        renderer.render_pass, UInt32(0),
        vertex_bindings, vertex_attributes,
        [renderer.descriptor_set_layout],
        [renderer.push_constant_range],
        true,   # blend enabled (alpha blending)
        false,  # no depth test
        false,  # no depth write
        CULL_MODE_NONE,
        FRONT_FACE_COUNTER_CLOCKWISE,
        1,      # 1 color attachment
        width, height
    )

    renderer.pipeline = vk_compile_and_create_pipeline(device, VK_UI_VERT, VK_UI_FRAG, config)

    # Create projection UBO (mat4 = 64 bytes)
    proj = orthographic_matrix(0.0f0, Float32(width), Float32(height), 0.0f0, -1.0f0, 1.0f0)
    renderer.projection_ubo, renderer.projection_ubo_memory = vk_create_buffer(
        device, physical_device, 64,
        BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT
    )
    vk_upload_struct_data!(device, renderer.projection_ubo_memory, proj)

    # Create 1x1 white fallback texture
    renderer.white_texture = vk_upload_texture(
        device, physical_device, command_pool, queue,
        UInt8[0xff, 0xff, 0xff, 0xff], 1, 1, 4;
        format=FORMAT_R8G8B8A8_UNORM, generate_mipmaps=false
    )

    renderer.initialized = true
    return nothing
end

"""
    vk_ensure_font_atlas!(renderer, device, physical_device, command_pool, queue, ctx)

Create font atlas as a Vulkan texture if not yet done. Re-rasterizes glyphs using
FreeTypeAbstraction and uploads as R8_UNORM.
"""
function vk_ensure_font_atlas!(renderer::VulkanUIRenderer, device::Device,
                                physical_device::PhysicalDevice, command_pool::CommandPool,
                                queue::Queue, ctx::UIContext)
    # Already created?
    renderer.font_atlas_texture !== nothing && return

    # Rasterize font atlas (same logic as font.jl but skip GL upload)
    font_path = isempty(ctx.font_path) ? _find_default_font() : ctx.font_path
    if isempty(font_path) || !isfile(font_path)
        return  # No font available
    end

    font_size = 32
    face = FreeTypeAbstraction.FTFont(font_path)
    chars = Char(32):Char(126)
    glyphs = Dict{Char, GlyphInfo}()

    glyph_bitmaps = Dict{Char, Tuple{Matrix{UInt8}, FreeTypeAbstraction.FontExtent{Float32}}}()
    for ch in chars
        extent = FreeTypeAbstraction.get_extent(face, ch)
        result = FreeTypeAbstraction.renderface(face, ch, font_size)
        if result isa Tuple
            bitmap = result[1]
            if bitmap === nothing || isempty(bitmap)
                glyph_bitmaps[ch] = (zeros(UInt8, 0, 0), extent)
            else
                glyph_bitmaps[ch] = (bitmap, extent)
            end
        else
            glyph_bitmaps[ch] = (zeros(UInt8, 0, 0), extent)
        end
    end

    # Calculate atlas layout
    x_cursor = 0
    y_cursor = 0
    row_h = 0
    atlas_width = 512
    padding = 2
    positions = Dict{Char, Tuple{Int, Int}}()

    for ch in chars
        bm, _ = glyph_bitmaps[ch]
        bw = size(bm, 1)
        bh = size(bm, 2)
        if bw == 0 && bh == 0
            bw = font_size ÷ 3
            bh = 0
        end
        if x_cursor + bw + padding > atlas_width
            x_cursor = 0
            y_cursor += row_h + padding
            row_h = 0
        end
        positions[ch] = (x_cursor, y_cursor)
        row_h = max(row_h, bh)
        x_cursor += bw + padding
    end

    atlas_height = y_cursor + row_h + padding
    atlas_height_pow2 = 1
    while atlas_height_pow2 < atlas_height
        atlas_height_pow2 <<= 1
    end
    atlas_height = max(1, atlas_height_pow2)

    atlas = zeros(UInt8, atlas_width * atlas_height)

    for ch in chars
        bm, extent = glyph_bitmaps[ch]
        px, py = positions[ch]
        bw = size(bm, 1)
        bh = size(bm, 2)

        for row in 1:bh, col in 1:bw
            atlas_x = px + col - 1
            atlas_y = py + row - 1
            if atlas_x < atlas_width && atlas_y < atlas_height
                atlas[atlas_y * atlas_width + atlas_x + 1] = bm[col, row]
            end
        end

        advance = FreeTypeAbstraction.hadvance(extent)
        bearing_x_val = FreeTypeAbstraction.inkwidth(extent) > 0 ?
            Float32(extent.horizontal_bearing[1] * font_size) : 0.0f0
        bearing_y_val = Float32(bh)

        glyphs[ch] = GlyphInfo(
            Float32(advance * font_size),
            bearing_x_val, bearing_y_val,
            Float32(bw), Float32(bh),
            Float32(px) / Float32(atlas_width),
            Float32(py) / Float32(atlas_height),
            Float32(bw) / Float32(atlas_width),
            Float32(bh) / Float32(atlas_height)
        )
    end

    # Upload as R8 Vulkan texture (expand to RGBA for simplicity — R channel only)
    rgba_data = Vector{UInt8}(undef, atlas_width * atlas_height * 4)
    for i in 1:length(atlas)
        rgba_data[(i-1)*4 + 1] = atlas[i]  # R = glyph alpha
        rgba_data[(i-1)*4 + 2] = 0x00
        rgba_data[(i-1)*4 + 3] = 0x00
        rgba_data[(i-1)*4 + 4] = 0xff
    end

    renderer.font_atlas_texture = vk_upload_texture(
        device, physical_device, command_pool, queue,
        rgba_data, atlas_width, atlas_height, 4;
        format=FORMAT_R8G8B8A8_UNORM, generate_mipmaps=false
    )

    # Assign synthetic texture ID and populate UIContext font atlas
    synthetic_id = UInt32(1)
    renderer.texture_map[synthetic_id] = renderer.font_atlas_texture

    ctx.font_atlas.texture_id = synthetic_id
    ctx.font_atlas.atlas_width = atlas_width
    ctx.font_atlas.atlas_height = atlas_height
    ctx.font_atlas.glyphs = glyphs
    ctx.font_atlas.font_size = Float32(font_size)
    ctx.font_atlas.line_height = Float32(font_size) * 1.2f0

    return nothing
end

"""
    vk_render_ui!(cmd, renderer, backend, ctx, image_index, frame_idx)

Render all UI draw commands as an overlay on the swapchain image.
"""
function vk_render_ui!(cmd::CommandBuffer, renderer::VulkanUIRenderer,
                        backend::VulkanBackend, ctx::UIContext,
                        image_index::Int, frame_idx::Int)
    !renderer.initialized && return
    isempty(ctx.draw_commands) && isempty(ctx.overlay_draw_commands) && return

    device = backend.device
    w = Int(backend.swapchain_extent.width)
    h = Int(backend.swapchain_extent.height)

    # Update projection UBO
    proj = orthographic_matrix(0.0f0, Float32(w), Float32(h), 0.0f0, -1.0f0, 1.0f0)
    vk_upload_struct_data!(device, renderer.projection_ubo_memory, proj)

    # Upload vertex data
    _vk_ui_upload_vertices!(renderer, device, backend.physical_device, ctx.vertices)

    # Begin UI render pass (preserves present pass output)
    rp_begin = RenderPassBeginInfo(
        renderer.render_pass,
        backend.swapchain_framebuffers[image_index],
        Rect2D(Offset2D(0, 0), Extent2D(UInt32(w), UInt32(h))),
        ClearValue[]
    )
    cmd_begin_render_pass(cmd, rp_begin, SUBPASS_CONTENTS_INLINE)

    cmd_set_viewport(cmd, [Viewport(0.0f0, 0.0f0, Float32(w), Float32(h), 0.0f0, 1.0f0)])
    cmd_set_scissor(cmd, [Rect2D(Offset2D(0, 0), Extent2D(UInt32(w), UInt32(h)))])

    cmd_bind_pipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, renderer.pipeline.pipeline)

    # Render main draw commands
    _vk_ui_draw_commands!(cmd, renderer, backend, ctx.draw_commands, w, h, frame_idx)

    # Render overlay draw commands (tooltips, dropdowns, etc.)
    if !isempty(ctx.overlay_draw_commands) && !isempty(ctx.overlay_vertices)
        _vk_ui_upload_vertices!(renderer, device, backend.physical_device, ctx.overlay_vertices)
        _vk_ui_draw_commands!(cmd, renderer, backend, ctx.overlay_draw_commands, w, h, frame_idx)
    end

    cmd_end_render_pass(cmd)
    return nothing
end

function _vk_ui_upload_vertices!(renderer::VulkanUIRenderer, device::Device,
                                   physical_device::PhysicalDevice, vertices::Vector{Float32})
    isempty(vertices) && return
    byte_size = sizeof(vertices)

    if byte_size > renderer.vertex_capacity
        # Destroy old buffer
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
    GC.@preserve vertices begin
        unsafe_copyto!(Ptr{UInt8}(ptr), Ptr{UInt8}(pointer(vertices)), byte_size)
    end
    unmap_memory(device, renderer.vertex_memory)
    return nothing
end

function _vk_ui_draw_commands!(cmd::CommandBuffer, renderer::VulkanUIRenderer,
                                 backend::VulkanBackend, commands::Vector{UIDrawCommand},
                                 width::Int, height::Int, frame_idx::Int)
    renderer.vertex_buffer === nothing && return

    prev_texture_id = UInt32(0xFFFFFFFF)  # sentinel: force first descriptor bind

    for draw_cmd in commands
        # Set scissor
        if draw_cmd.clip_rect !== nothing
            cx, cy, cw, ch = draw_cmd.clip_rect
            # Vulkan scissor: origin is top-left (same as UI coordinate system)
            cmd_set_scissor(cmd, [Rect2D(
                Offset2D(max(Int32(0), cx), max(Int32(0), cy)),
                Extent2D(UInt32(cw), UInt32(ch))
            )])
        else
            cmd_set_scissor(cmd, [Rect2D(Offset2D(0, 0), Extent2D(UInt32(width), UInt32(height)))])
        end

        # Push constants: has_texture + is_font
        has_tex = draw_cmd.texture_id != UInt32(0) ? Int32(1) : Int32(0)
        is_font = draw_cmd.is_font ? Int32(1) : Int32(0)
        push_data = (has_tex, is_font)
        push_ref = Ref(push_data)
        GC.@preserve push_ref cmd_push_constants(cmd, renderer.pipeline.pipeline_layout,
            SHADER_STAGE_FRAGMENT_BIT, UInt32(0), UInt32(8),
            Base.unsafe_convert(Ptr{Cvoid}, Base.cconvert(Ptr{Cvoid}, push_ref)))

        # Bind descriptor set (UBO + texture) — re-bind when texture changes
        if draw_cmd.texture_id != prev_texture_id
            tex = if draw_cmd.texture_id != UInt32(0) && haskey(renderer.texture_map, draw_cmd.texture_id)
                renderer.texture_map[draw_cmd.texture_id]
            else
                renderer.white_texture
            end

            ds = vk_allocate_descriptor_set(backend.device,
                backend.transient_pools[frame_idx], renderer.descriptor_set_layout)
            vk_update_ubo_descriptor!(backend.device, ds, 0,
                renderer.projection_ubo, UInt32(64))
            vk_update_texture_descriptor!(backend.device, ds, 1, tex)
            cmd_bind_descriptor_sets(cmd, PIPELINE_BIND_POINT_GRAPHICS,
                renderer.pipeline.pipeline_layout, UInt32(0), [ds], UInt32[])

            prev_texture_id = draw_cmd.texture_id
        end

        # Bind vertex buffer and draw
        cmd_bind_vertex_buffers(cmd, [renderer.vertex_buffer], [UInt64(0)])
        vertex_start = UInt32(draw_cmd.vertex_offset ÷ 8)  # 8 floats per vertex
        cmd_draw(cmd, UInt32(draw_cmd.vertex_count), UInt32(1), vertex_start, UInt32(0))
    end

    return nothing
end

"""
    vk_destroy_ui!(device, renderer)

Destroy Vulkan UI renderer resources.
"""
function vk_destroy_ui!(device::Device, renderer::VulkanUIRenderer)
    !renderer.initialized && return

    if renderer.pipeline !== nothing
        finalize(renderer.pipeline.pipeline)
        finalize(renderer.pipeline.pipeline_layout)
        renderer.pipeline.vert_module !== nothing && finalize(renderer.pipeline.vert_module)
        renderer.pipeline.frag_module !== nothing && finalize(renderer.pipeline.frag_module)
    end

    renderer.render_pass !== nothing && finalize(renderer.render_pass)
    renderer.descriptor_set_layout !== nothing && finalize(renderer.descriptor_set_layout)

    if renderer.vertex_buffer !== nothing
        finalize(renderer.vertex_buffer)
        finalize(renderer.vertex_memory)
    end

    if renderer.projection_ubo !== nothing
        finalize(renderer.projection_ubo)
        finalize(renderer.projection_ubo_memory)
    end

    if renderer.font_atlas_texture !== nothing
        vk_destroy_texture!(device, renderer.font_atlas_texture)
    end

    if renderer.white_texture !== nothing
        vk_destroy_texture!(device, renderer.white_texture)
    end

    renderer.initialized = false
    return nothing
end
