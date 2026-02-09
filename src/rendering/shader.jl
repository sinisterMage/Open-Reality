# Shader compilation and uniform management

using ModernGL

"""
    ShaderProgram

Compiled and linked OpenGL shader program with cached uniform locations.
"""
mutable struct ShaderProgram
    id::GLuint
    uniform_cache::Dict{String, GLint}

    ShaderProgram(id::GLuint) = new(id, Dict{String, GLint}())
end

"""
    compile_shader(source::String, shader_type::GLenum) -> GLuint

Compile a single GLSL shader. Throws on compilation failure.
"""
function compile_shader(source::String, shader_type::GLenum)
    shader = glCreateShader(shader_type)
    glShaderSource(shader, 1, Ptr{GLchar}[pointer(source)], C_NULL)
    glCompileShader(shader)

    status = Ref{GLint}(-1)
    glGetShaderiv(shader, GL_COMPILE_STATUS, status)
    if status[] != GL_TRUE
        max_len = Ref{GLint}(0)
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, max_len)
        log_buf = Vector{UInt8}(undef, max_len[])
        actual_len = Ref{GLsizei}(0)
        glGetShaderInfoLog(shader, max_len[], actual_len, log_buf)
        log_str = String(log_buf[1:actual_len[]])
        glDeleteShader(shader)
        error("Shader compilation failed:\n$log_str")
    end

    return shader
end

"""
    create_shader_program(vertex_src::String, fragment_src::String) -> ShaderProgram

Compile vertex and fragment shaders, link them into a program.
"""
function create_shader_program(vertex_src::String, fragment_src::String)
    vert = compile_shader(vertex_src, GL_VERTEX_SHADER)
    frag = compile_shader(fragment_src, GL_FRAGMENT_SHADER)

    program = glCreateProgram()
    glAttachShader(program, vert)
    glAttachShader(program, frag)
    glLinkProgram(program)

    status = Ref{GLint}(-1)
    glGetProgramiv(program, GL_LINK_STATUS, status)
    if status[] != GL_TRUE
        max_len = Ref{GLint}(0)
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, max_len)
        log_buf = Vector{UInt8}(undef, max_len[])
        actual_len = Ref{GLsizei}(0)
        glGetProgramInfoLog(program, max_len[], actual_len, log_buf)
        log_str = String(log_buf[1:actual_len[]])
        glDeleteProgram(program)
        error("Shader program linking failed:\n$log_str")
    end

    glDetachShader(program, vert)
    glDetachShader(program, frag)
    glDeleteShader(vert)
    glDeleteShader(frag)

    return ShaderProgram(program)
end

"""
    get_uniform_location!(sp::ShaderProgram, name::String) -> GLint

Get (and cache) a uniform location by name.
"""
function get_uniform_location!(sp::ShaderProgram, name::String)
    return get!(sp.uniform_cache, name) do
        glGetUniformLocation(sp.id, name)
    end
end

# Uniform setters

function set_uniform!(sp::ShaderProgram, name::String, val::Mat4f)
    loc = get_uniform_location!(sp, name)
    glUniformMatrix4fv(loc, 1, GL_FALSE, Ref(val))
end

function set_uniform!(sp::ShaderProgram, name::String, val::SMatrix{3, 3, Float32, 9})
    loc = get_uniform_location!(sp, name)
    glUniformMatrix3fv(loc, 1, GL_FALSE, Ref(val))
end

function set_uniform!(sp::ShaderProgram, name::String, val::Vec3f)
    loc = get_uniform_location!(sp, name)
    glUniform3f(loc, val[1], val[2], val[3])
end

function set_uniform!(sp::ShaderProgram, name::String, val::Float32)
    loc = get_uniform_location!(sp, name)
    glUniform1f(loc, val)
end

function set_uniform!(sp::ShaderProgram, name::String, val::Int32)
    loc = get_uniform_location!(sp, name)
    glUniform1i(loc, val)
end

function set_uniform!(sp::ShaderProgram, name::String, val::RGB{Float32})
    loc = get_uniform_location!(sp, name)
    glUniform3f(loc, val.r, val.g, val.b)
end

function set_uniform!(sp::ShaderProgram, name::String, val::Vec2f)
    loc = get_uniform_location!(sp, name)
    glUniform2f(loc, val[1], val[2])
end

"""
    destroy_shader_program!(sp::ShaderProgram)

Delete the OpenGL shader program.
"""
function destroy_shader_program!(sp::ShaderProgram)
    glDeleteProgram(sp.id)
    sp.id = GLuint(0)
end
