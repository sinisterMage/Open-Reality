# OpenGL UI rendering — shader, VAO/VBO, draw calls

# UI shader source
const _UI_VERTEX_SHADER = """
#version 330 core
layout(location = 0) in vec2 a_Position;
layout(location = 1) in vec2 a_TexCoord;
layout(location = 2) in vec4 a_Color;

uniform mat4 u_Projection;

out vec2 v_TexCoord;
out vec4 v_Color;

void main() {
    v_TexCoord = a_TexCoord;
    v_Color = a_Color;
    gl_Position = u_Projection * vec4(a_Position, 0.0, 1.0);
}
"""

const _UI_FRAGMENT_SHADER = """
#version 330 core
in vec2 v_TexCoord;
in vec4 v_Color;

uniform sampler2D u_Texture;
uniform int u_HasTexture;
uniform int u_IsFont;

out vec4 FragColor;

void main() {
    if (u_HasTexture == 1) {
        if (u_IsFont == 1) {
            // Font atlas: single channel (red), use as alpha
            float alpha = texture(u_Texture, v_TexCoord).r;
            FragColor = vec4(v_Color.rgb, v_Color.a * alpha);
        } else {
            // Regular texture
            vec4 texColor = texture(u_Texture, v_TexCoord);
            FragColor = texColor * v_Color;
        }
    } else {
        FragColor = v_Color;
    }
}
"""

# UI renderer state
mutable struct UIRenderer
    shader::Union{ShaderProgram, Nothing}
    vao::GLuint
    vbo::GLuint
    initialized::Bool

    UIRenderer() = new(nothing, GLuint(0), GLuint(0), false)
end

const _UI_RENDERER = Ref{UIRenderer}(UIRenderer())

function get_ui_renderer()
    return _UI_RENDERER[]
end

"""
    init_ui_renderer!()

Initialize the UI rendering resources (shader, VAO/VBO).
"""
function init_ui_renderer!()
    renderer = get_ui_renderer()
    if renderer.initialized
        return
    end

    # Compile shader
    renderer.shader = create_shader_program(_UI_VERTEX_SHADER, _UI_FRAGMENT_SHADER)

    # Create VAO/VBO
    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    renderer.vao = vao_ref[]

    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    renderer.vbo = vbo_ref[]

    glBindVertexArray(renderer.vao)
    glBindBuffer(GL_ARRAY_BUFFER, renderer.vbo)

    stride = Int32(8 * sizeof(Float32))  # pos(2) + uv(2) + color(4)

    # Position (location 0)
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, Ptr{Cvoid}(0))
    glEnableVertexAttribArray(0)

    # TexCoord (location 1)
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, Ptr{Cvoid}(2 * sizeof(Float32)))
    glEnableVertexAttribArray(1)

    # Color (location 2)
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, stride, Ptr{Cvoid}(4 * sizeof(Float32)))
    glEnableVertexAttribArray(2)

    glBindVertexArray(GLuint(0))
    glBindBuffer(GL_ARRAY_BUFFER, GLuint(0))

    renderer.initialized = true
    return nothing
end

"""
    shutdown_ui_renderer!()

Release UI rendering resources.
"""
function shutdown_ui_renderer!()
    renderer = get_ui_renderer()
    if !renderer.initialized
        return
    end

    if renderer.shader !== nothing
        destroy_shader_program!(renderer.shader)
        renderer.shader = nothing
    end

    if renderer.vao != GLuint(0)
        glDeleteVertexArrays(1, Ref(renderer.vao))
        renderer.vao = GLuint(0)
    end
    if renderer.vbo != GLuint(0)
        glDeleteBuffers(1, Ref(renderer.vbo))
        renderer.vbo = GLuint(0)
    end

    renderer.initialized = false
    return nothing
end

"""
    reset_ui_renderer!()

Reset UI renderer state (for testing).
"""
function reset_ui_renderer!()
    _UI_RENDERER[] = UIRenderer()
    return nothing
end

"""
    render_ui!(ctx::UIContext)

Flush all UI draw commands to GPU. Call after all widgets have been added.
"""
function render_ui!(ctx::UIContext)
    renderer = get_ui_renderer()
    if !renderer.initialized || renderer.shader === nothing
        return
    end

    if isempty(ctx.draw_commands) && isempty(ctx.overlay_draw_commands)
        return
    end

    sp = renderer.shader

    # Set up render state
    glDisable(GL_DEPTH_TEST)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDisable(GL_CULL_FACE)

    glUseProgram(sp.id)

    # Set orthographic projection (top-left origin)
    proj = orthographic_matrix(0.0f0, Float32(ctx.width), Float32(ctx.height), 0.0f0, -1.0f0, 1.0f0)
    set_uniform!(sp, "u_Projection", proj)

    # Upload vertex data
    glBindVertexArray(renderer.vao)
    glBindBuffer(GL_ARRAY_BUFFER, renderer.vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(ctx.vertices), ctx.vertices, GL_DYNAMIC_DRAW)

    # Execute draw commands (scissor-aware)
    prev_clip = nothing
    for cmd in ctx.draw_commands
        if cmd.clip_rect != prev_clip
            if cmd.clip_rect === nothing
                glDisable(GL_SCISSOR_TEST)
            else
                cx, cy, cw, ch = cmd.clip_rect
                gl_y = Int32(ctx.height) - cy - ch
                glEnable(GL_SCISSOR_TEST)
                glScissor(cx, gl_y, cw, ch)
            end
            prev_clip = cmd.clip_rect
        end

        if cmd.texture_id != UInt32(0)
            glActiveTexture(GL_TEXTURE0)
            glBindTexture(GL_TEXTURE_2D, cmd.texture_id)
            set_uniform!(sp, "u_HasTexture", Int32(1))
            set_uniform!(sp, "u_IsFont", cmd.is_font ? Int32(1) : Int32(0))
            set_uniform!(sp, "u_Texture", Int32(0))
        else
            set_uniform!(sp, "u_HasTexture", Int32(0))
            set_uniform!(sp, "u_IsFont", Int32(0))
        end

        vertex_start = cmd.vertex_offset ÷ 8  # 8 floats per vertex
        glDrawArrays(GL_TRIANGLES, vertex_start, cmd.vertex_count)
    end

    # Reset scissor state before overlay pass
    glDisable(GL_SCISSOR_TEST)

    # Overlay flush — render overlay geometry (tooltips, dropdowns, etc.) on top
    if !isempty(ctx.overlay_vertices)
        glBufferData(GL_ARRAY_BUFFER, sizeof(ctx.overlay_vertices), ctx.overlay_vertices, GL_DYNAMIC_DRAW)

        prev_clip = nothing
        for cmd in ctx.overlay_draw_commands
            if cmd.clip_rect != prev_clip
                if cmd.clip_rect === nothing
                    glDisable(GL_SCISSOR_TEST)
                else
                    cx, cy, cw, ch = cmd.clip_rect
                    gl_y = Int32(ctx.height) - cy - ch
                    glEnable(GL_SCISSOR_TEST)
                    glScissor(cx, gl_y, cw, ch)
                end
                prev_clip = cmd.clip_rect
            end

            if cmd.texture_id != UInt32(0)
                glActiveTexture(GL_TEXTURE0)
                glBindTexture(GL_TEXTURE_2D, cmd.texture_id)
                set_uniform!(sp, "u_HasTexture", Int32(1))
                set_uniform!(sp, "u_IsFont", cmd.is_font ? Int32(1) : Int32(0))
                set_uniform!(sp, "u_Texture", Int32(0))
            else
                set_uniform!(sp, "u_HasTexture", Int32(0))
                set_uniform!(sp, "u_IsFont", Int32(0))
            end

            vertex_start = cmd.vertex_offset ÷ 8  # 8 floats per vertex
            glDrawArrays(GL_TRIANGLES, vertex_start, cmd.vertex_count)
        end

        glDisable(GL_SCISSOR_TEST)
    end

    # Restore state
    glBindVertexArray(GLuint(0))
    glBindTexture(GL_TEXTURE_2D, GLuint(0))
    glEnable(GL_DEPTH_TEST)
    glDisable(GL_BLEND)
    glEnable(GL_CULL_FACE)

    return nothing
end
