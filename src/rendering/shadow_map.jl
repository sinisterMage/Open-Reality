# Shadow mapping: depth-only FBO, light-space matrix, shadow pass

"""
    ShadowMap

Stores OpenGL resources for directional shadow mapping:
depth-only FBO, depth texture, and the depth-pass shader.
"""
mutable struct ShadowMap
    fbo::GLuint
    depth_texture::GLuint
    width::Int
    height::Int
    shader::Union{ShaderProgram, Nothing}

    ShadowMap(; width::Int=2048, height::Int=2048) =
        new(GLuint(0), GLuint(0), width, height, nothing)
end

# ---- Depth shader sources ----

const SHADOW_VERTEX_SHADER = """
#version 330 core

layout(location = 0) in vec3 a_Position;

uniform mat4 u_LightSpaceMatrix;
uniform mat4 u_Model;

void main()
{
    gl_Position = u_LightSpaceMatrix * u_Model * vec4(a_Position, 1.0);
}
"""

const SHADOW_FRAGMENT_SHADER = """
#version 330 core

void main()
{
    // Depth is written automatically
}
"""

# ---- Create / Destroy ----

"""
    create_shadow_map!(sm::ShadowMap)

Allocate the depth FBO, depth texture, and compile the depth shader.
"""
function create_shadow_map!(sm::ShadowMap)
    # Create depth texture
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    sm.depth_texture = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, sm.depth_texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24,
                 sm.width, sm.height, 0, GL_DEPTH_COMPONENT, GL_FLOAT, C_NULL)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)
    border_color = Float32[1.0, 1.0, 1.0, 1.0]
    glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, border_color)

    # Create FBO
    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    sm.fbo = fbo_ref[]
    glBindFramebuffer(GL_FRAMEBUFFER, sm.fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, sm.depth_texture, 0)
    glDrawBuffer(GL_NONE)
    glReadBuffer(GL_NONE)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    # Compile depth shader
    sm.shader = create_shader_program(SHADOW_VERTEX_SHADER, SHADOW_FRAGMENT_SHADER)

    return nothing
end

"""
    destroy_shadow_map!(sm::ShadowMap)

Clean up shadow map GPU resources.
"""
function destroy_shadow_map!(sm::ShadowMap)
    if sm.fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(sm.fbo))
        sm.fbo = GLuint(0)
    end
    if sm.depth_texture != GLuint(0)
        glDeleteTextures(1, Ref(sm.depth_texture))
        sm.depth_texture = GLuint(0)
    end
    if sm.shader !== nothing
        destroy_shader_program!(sm.shader)
        sm.shader = nothing
    end
    return nothing
end

# ---- Light-space matrix ----

"""
    compute_light_space_matrix(cam_pos::Vec3f, light_dir::Vec3f;
                               ortho_size::Float32=40.0f0,
                               near::Float32=-50.0f0,
                               far::Float32=50.0f0) -> Mat4f

Compute an orthographic light-space (view * projection) matrix for shadow mapping.
The view is centered on `cam_pos` looking along `light_dir`.
"""
function compute_light_space_matrix(cam_pos::Vec3f, light_dir::Vec3f;
                                    ortho_size::Float32=40.0f0,
                                    near::Float32=-50.0f0,
                                    far::Float32=50.0f0)
    # Normalise light direction
    d = normalize(Vec3f(light_dir[1], light_dir[2], light_dir[3]))

    # Light "eye" is at cam_pos offset opposite to light direction
    light_pos = cam_pos - d * 25.0f0

    # Light view matrix (look_at)
    up = abs(d[2]) > 0.99f0 ? Vec3f(0, 0, 1) : Vec3f(0, 1, 0)
    light_view = look_at_matrix(light_pos, light_pos + d, up)

    # Orthographic projection
    light_proj = _ortho_matrix(-ortho_size, ortho_size,
                               -ortho_size, ortho_size,
                               near, far)

    return light_proj * light_view
end

"""
Orthographic projection matrix (column-major, OpenGL convention).
"""
function _ortho_matrix(left::Float32, right::Float32,
                       bottom::Float32, top::Float32,
                       near::Float32, far::Float32)
    rl = right - left
    tb = top - bottom
    fn = far - near
    return Mat4f(
        2.0f0/rl,      0.0f0,         0.0f0,        0.0f0,
        0.0f0,         2.0f0/tb,      0.0f0,        0.0f0,
        0.0f0,         0.0f0,        -2.0f0/fn,     0.0f0,
        -(right+left)/rl, -(top+bottom)/tb, -(far+near)/fn, 1.0f0
    )
end

# ---- Shadow render pass ----

"""
    render_shadow_pass!(sm::ShadowMap, light_space::Mat4f, gpu_cache::GPUResourceCache)

Render all mesh entities into the shadow depth buffer.
"""
function render_shadow_pass!(sm::ShadowMap, light_space::Mat4f, gpu_cache::GPUResourceCache)
    sm.shader === nothing && return nothing

    # Save current viewport
    viewport = Int32[0, 0, 0, 0]
    glGetIntegerv(GL_VIEWPORT, viewport)

    glViewport(0, 0, sm.width, sm.height)
    glBindFramebuffer(GL_FRAMEBUFFER, sm.fbo)
    glClear(GL_DEPTH_BUFFER_BIT)

    # Disable face culling for shadow pass to avoid peter-panning
    glDisable(GL_CULL_FACE)

    sp = sm.shader
    glUseProgram(sp.id)
    set_uniform!(sp, "u_LightSpaceMatrix", light_space)

    iterate_components(MeshComponent) do entity_id, mesh
        isempty(mesh.indices) && return

        world_transform = get_world_transform(entity_id)
        model = Mat4f(world_transform)
        set_uniform!(sp, "u_Model", model)

        gpu_mesh = get_or_upload_mesh!(gpu_cache, entity_id, mesh)
        glBindVertexArray(gpu_mesh.vao)
        glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
        glBindVertexArray(GLuint(0))
    end

    # Restore
    glEnable(GL_CULL_FACE)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
    glViewport(viewport[1], viewport[2], viewport[3], viewport[4])

    return nothing
end

# look_at_matrix, normalize, cross, dot for Vec3f are defined in math/transforms.jl
