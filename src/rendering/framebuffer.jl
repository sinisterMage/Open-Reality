# Framebuffer: HDR render target with color texture and depth renderbuffer

"""
    Framebuffer

Off-screen render target with an HDR (RGBA16F) color texture and a
depth renderbuffer.
"""
mutable struct Framebuffer
    fbo::GLuint
    color_texture::GLuint    # GL_RGBA16F
    depth_rbo::GLuint        # GL_DEPTH_COMPONENT24
    width::Int
    height::Int

    Framebuffer(; width::Int=1280, height::Int=720) =
        new(GLuint(0), GLuint(0), GLuint(0), width, height)
end

"""
    create_framebuffer!(fb::Framebuffer, width::Int, height::Int)

Allocate GPU resources for the framebuffer.
"""
function create_framebuffer!(fb::Framebuffer, width::Int, height::Int)
    fb.width = width
    fb.height = height

    # Color texture (HDR)
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    fb.color_texture = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, fb.color_texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, width, height, 0, GL_RGBA, GL_FLOAT, C_NULL)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

    # Depth renderbuffer
    rbo_ref = Ref(GLuint(0))
    glGenRenderbuffers(1, rbo_ref)
    fb.depth_rbo = rbo_ref[]
    glBindRenderbuffer(GL_RENDERBUFFER, fb.depth_rbo)
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height)

    # FBO
    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    fb.fbo = fbo_ref[]
    glBindFramebuffer(GL_FRAMEBUFFER, fb.fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fb.color_texture, 0)
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, fb.depth_rbo)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
    return nothing
end

"""
    destroy_framebuffer!(fb::Framebuffer)

Release GPU resources.
"""
function destroy_framebuffer!(fb::Framebuffer)
    if fb.fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(fb.fbo))
        fb.fbo = GLuint(0)
    end
    if fb.color_texture != GLuint(0)
        glDeleteTextures(1, Ref(fb.color_texture))
        fb.color_texture = GLuint(0)
    end
    if fb.depth_rbo != GLuint(0)
        glDeleteRenderbuffers(1, Ref(fb.depth_rbo))
        fb.depth_rbo = GLuint(0)
    end
    return nothing
end

"""
    resize_framebuffer!(fb::Framebuffer, width::Int, height::Int)

Destroy and recreate at new dimensions.
"""
function resize_framebuffer!(fb::Framebuffer, width::Int, height::Int)
    destroy_framebuffer!(fb)
    create_framebuffer!(fb, width, height)
end
