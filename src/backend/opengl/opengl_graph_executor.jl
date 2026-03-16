# OpenGL Render Graph Executor
# Handles physical GL resource allocation, FBO management, and pass dispatch.

using ModernGL

"""
    GLPhysicalResource

Physical OpenGL resource backing a render graph resource handle.
"""
mutable struct GLPhysicalResource
    texture::GLuint       # GL texture handle (GL_TEXTURE_2D)
    fbo::GLuint           # FBO this texture is attached to (0 if not a render target)
    depth_rbo::GLuint     # Depth renderbuffer (if this resource is a depth attachment)
    width::Int
    height::Int
    format::RGFormat
    imported::Bool        # true = don't allocate/free
end

GLPhysicalResource() = GLPhysicalResource(GLuint(0), GLuint(0), GLuint(0), 0, 0, RG_RGBA8, false)

"""
    OpenGLGraphExecutor <: AbstractGraphExecutor

OpenGL-specific graph executor. Manages GL textures, FBOs, and pass dispatch.
"""
mutable struct OpenGLGraphExecutor <: AbstractGraphExecutor
    physical::Vector{GLPhysicalResource}
    # Maps sorted write-target resource indices -> shared FBO handle
    pass_fbos::Dict{Int, GLuint}  # pass_index -> FBO for that pass's write targets
    quad_vao::GLuint
    quad_vbo::GLuint
    # Resource handles from graph construction (for pass callbacks)
    handles::Union{DeferredGraphHandles, Nothing}
    # Double-buffered textures for RG_MULTI_FRAME resources: resource_idx -> [tex_0, tex_1]
    multi_frame_textures::Dict{Int, Tuple{GLuint, GLuint}}

    OpenGLGraphExecutor() = new(
        GLPhysicalResource[], Dict{Int, GLuint}(),
        GLuint(0), GLuint(0), nothing,
        Dict{Int, Tuple{GLuint, GLuint}}()
    )
end

# ---- GL format mapping ----

function _rg_to_gl_internal_format(fmt::RGFormat)
    if fmt == RG_RGBA16F
        return GL_RGBA16F
    elseif fmt == RG_RGBA8 || fmt == RG_RGBA8_SRGB
        return GL_RGBA8
    elseif fmt == RG_RG16F
        return GL_RG16F
    elseif fmt == RG_R16F
        return GL_R16F
    elseif fmt == RG_R8
        return GL_R8
    elseif fmt == RG_DEPTH32F
        return GL_DEPTH_COMPONENT32F
    elseif fmt == RG_DEPTH24
        return GL_DEPTH_COMPONENT24
    else
        error("Unknown RGFormat: $fmt")
    end
end

function _rg_to_gl_format(fmt::RGFormat)
    if fmt == RG_RGBA16F || fmt == RG_RGBA8 || fmt == RG_RGBA8_SRGB
        return GL_RGBA
    elseif fmt == RG_RG16F
        return GL_RG
    elseif fmt == RG_R16F || fmt == RG_R8
        return GL_RED
    elseif fmt == RG_DEPTH32F || fmt == RG_DEPTH24
        return GL_DEPTH_COMPONENT
    else
        error("Unknown RGFormat: $fmt")
    end
end

function _rg_to_gl_type(fmt::RGFormat)
    if fmt == RG_RGBA16F || fmt == RG_RG16F || fmt == RG_R16F || fmt == RG_DEPTH32F
        return GL_FLOAT
    elseif fmt == RG_RGBA8 || fmt == RG_RGBA8_SRGB || fmt == RG_R8
        return GL_UNSIGNED_BYTE
    elseif fmt == RG_DEPTH24
        return GL_UNSIGNED_INT
    else
        return GL_FLOAT
    end
end

# ---- Texture creation ----

function _gl_create_texture(fmt::RGFormat, w::Int, h::Int)::GLuint
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    tex = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, tex)

    internal = _rg_to_gl_internal_format(fmt)
    gl_fmt = _rg_to_gl_format(fmt)
    gl_type = _rg_to_gl_type(fmt)

    glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, gl_fmt, gl_type, C_NULL)

    # Use NEAREST for render targets (typical for deferred), LINEAR for post-process
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

    glBindTexture(GL_TEXTURE_2D, GLuint(0))
    return tex
end

function _gl_destroy_texture(tex::GLuint)
    if tex != GLuint(0)
        tex_ref = Ref(tex)
        glDeleteTextures(1, tex_ref)
    end
end

# ---- FBO creation for a set of write targets ----

function _gl_create_pass_fbo(physical::Vector{GLPhysicalResource},
                              write_indices::Vector{Int})::GLuint
    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    fbo = fbo_ref[]
    glBindFramebuffer(GL_FRAMEBUFFER, fbo)

    color_attachments = UInt32[]
    for idx in write_indices
        pr = physical[idx]
        if is_depth_format(pr.format)
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                    GL_TEXTURE_2D, pr.texture, 0)
        else
            attachment = GL_COLOR_ATTACHMENT0 + UInt32(length(color_attachments))
            glFramebufferTexture2D(GL_FRAMEBUFFER, attachment,
                                    GL_TEXTURE_2D, pr.texture, 0)
            push!(color_attachments, attachment)
        end
        pr.fbo = fbo
    end

    # If there are no depth attachments among the write targets, add a depth RBO
    has_depth = any(is_depth_format(physical[i].format) for i in write_indices)
    if !has_depth && !isempty(write_indices)
        pr = physical[write_indices[1]]
        rbo_ref = Ref(GLuint(0))
        glGenRenderbuffers(1, rbo_ref)
        rbo = rbo_ref[]
        glBindRenderbuffer(GL_RENDERBUFFER, rbo)
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, pr.width, pr.height)
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                   GL_RENDERBUFFER, rbo)
        # Store the RBO on the first physical resource for cleanup
        physical[write_indices[1]].depth_rbo = rbo
    end

    if !isempty(color_attachments)
        glDrawBuffers(length(color_attachments), color_attachments)
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
    return fbo
end

# ---- Fullscreen quad ----

function _gl_create_quad(exec::OpenGLGraphExecutor)
    quad_vertices = Float32[
        -1.0, -1.0, 0.0, 0.0,
         1.0, -1.0, 1.0, 0.0,
         1.0,  1.0, 1.0, 1.0,
        -1.0, -1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 1.0,
    ]

    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    exec.quad_vao = vao_ref[]

    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    exec.quad_vbo = vbo_ref[]

    glBindVertexArray(exec.quad_vao)
    glBindBuffer(GL_ARRAY_BUFFER, exec.quad_vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad_vertices), quad_vertices, GL_STATIC_DRAW)

    # Position (layout 0)
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(0))
    # UV (layout 1)
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(2 * sizeof(Float32)))

    glBindVertexArray(GLuint(0))
end

# ---- AbstractGraphExecutor interface ----

function allocate_resources!(exec::OpenGLGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    @assert graph.compiled "Render graph must be compiled before allocating resources"

    empty!(exec.physical)
    # Pre-fill with empty physical resources
    for _ in 1:length(graph.resources)
        push!(exec.physical, GLPhysicalResource())
    end

    # Allocate textures for non-imported resources
    for (i, desc) in enumerate(graph.resources)
        # Skip if this resource is aliased to another
        alias_target = get(graph.resource_aliases, i, i)
        if alias_target != i
            # Share the physical resource from the alias target
            exec.physical[i] = exec.physical[alias_target]
            continue
        end

        # Skip imported (physical handles set externally via set_imported_resource!)
        if desc.lifetime == RG_IMPORTED
            exec.physical[i].imported = true
            continue
        end

        # Check if resource is actually used
        first_use, last_use = graph.resource_lifetimes[i]
        if first_use == typemax(Int)
            continue  # Never used by any active pass
        end

        # Resolve dimensions
        rw, rh = resolve_size(desc.size_policy, w, h)

        # Create the GL texture
        tex = _gl_create_texture(desc.format, rw, rh)
        exec.physical[i] = GLPhysicalResource(tex, GLuint(0), GLuint(0), rw, rh, desc.format, false)

        # For multi-frame resources, allocate a second texture for double-buffering
        if desc.lifetime == RG_MULTI_FRAME
            tex_b = _gl_create_texture(desc.format, rw, rh)
            exec.multi_frame_textures[i] = (tex, tex_b)
        end
    end

    # Create FBOs for each pass's write targets
    for pi in graph.sorted_passes
        pass = graph.passes[pi]
        write_indices = Int[]
        for usage in pass.writes
            idx = usage.handle.index
            idx < 1 || idx > length(exec.physical) && continue
            pr = exec.physical[idx]
            pr.texture == GLuint(0) && continue  # Not allocated (imported or unused)
            pr.imported && continue               # Don't create FBOs for imported resources
            push!(write_indices, idx)
        end

        if !isempty(write_indices)
            fbo = _gl_create_pass_fbo(exec.physical, write_indices)
            exec.pass_fbos[pi] = fbo
        end
    end

    # Create fullscreen quad if not already created
    if exec.quad_vao == GLuint(0)
        _gl_create_quad(exec)
    end

    return nothing
end

function set_imported_resource!(exec::OpenGLGraphExecutor, handle::RGResourceHandle, gl_texture::GLuint)
    idx = handle.index
    if idx >= 1 && idx <= length(exec.physical)
        exec.physical[idx].texture = gl_texture
        exec.physical[idx].imported = true
    end
end

function get_physical_resource(exec::OpenGLGraphExecutor, handle::RGResourceHandle)
    idx = handle.index
    if idx >= 1 && idx <= length(exec.physical)
        return exec.physical[idx].texture
    end
    return GLuint(0)
end

function execute_graph!(exec::OpenGLGraphExecutor, graph::RenderGraph,
                         backend::OpenGLBackend, ctx::RGExecuteContext)
    @assert graph.compiled "Render graph not compiled"

    # Swap multi-frame textures based on current frame index
    fi = graph.frame_index
    for (ridx, (tex_a, tex_b)) in exec.multi_frame_textures
        # frame 0: physical = tex_a (current write), tex_b is the "history" (previous frame)
        # frame 1: physical = tex_b (current write), tex_a is the "history"
        exec.physical[ridx].texture = fi == 0 ? tex_a : tex_b
    end

    timing = rg_timing_enabled()
    if timing
        rg_timing_begin_frame!()
    end

    for pi in graph.sorted_passes
        pass = graph.passes[pi]

        # Bind FBO for write targets (if we created one)
        fbo = get(exec.pass_fbos, pi, GLuint(0))
        if fbo != GLuint(0)
            glBindFramebuffer(GL_FRAMEBUFFER, fbo)
            # Set viewport to the first write target's dimensions
            for usage in pass.writes
                idx = usage.handle.index
                if idx >= 1 && idx <= length(exec.physical) && exec.physical[idx].texture != GLuint(0)
                    pr = exec.physical[idx]
                    glViewport(0, 0, pr.width, pr.height)
                    break
                end
            end
        end

        # Execute the pass callback with optional CPU timing
        if timing
            t0 = time_ns()
            pass.execute_fn(backend, ctx)
            t1 = time_ns()
            cpu_ms = Float64(t1 - t0) / 1_000_000.0
            rg_timing_record!(pass.name, cpu_ms)
        else
            pass.execute_fn(backend, ctx)
        end

        # Unbind FBO
        if fbo != GLuint(0)
            glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
        end
    end

    if timing
        rg_timing_end_frame!()
    end
end

function resize_resources!(exec::OpenGLGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    destroy_resources!(exec, graph)
    allocate_resources!(exec, graph, w, h)
end

function destroy_resources!(exec::OpenGLGraphExecutor, graph::RenderGraph)
    # Destroy FBOs
    for (_, fbo) in exec.pass_fbos
        if fbo != GLuint(0)
            fbo_ref = Ref(fbo)
            glDeleteFramebuffers(1, fbo_ref)
        end
    end
    empty!(exec.pass_fbos)

    # Destroy multi-frame double-buffered textures
    destroyed = Set{GLuint}()
    for (_, (tex_a, tex_b)) in exec.multi_frame_textures
        if tex_a != GLuint(0)
            _gl_destroy_texture(tex_a)
            push!(destroyed, tex_a)
        end
        if tex_b != GLuint(0)
            _gl_destroy_texture(tex_b)
            push!(destroyed, tex_b)
        end
    end
    empty!(exec.multi_frame_textures)

    # Destroy textures (skip imported, aliased, and already destroyed multi-frame)
    for (i, pr) in enumerate(exec.physical)
        pr.imported && continue
        pr.texture == GLuint(0) && continue
        pr.texture ∈ destroyed && continue  # Already destroyed (aliased or multi-frame)
        _gl_destroy_texture(pr.texture)
        push!(destroyed, pr.texture)
        # Destroy depth RBO if present
        if pr.depth_rbo != GLuint(0)
            rbo_ref = Ref(pr.depth_rbo)
            glDeleteRenderbuffers(1, rbo_ref)
        end
    end

    empty!(exec.physical)

    # Destroy quad VAO/VBO
    if exec.quad_vao != GLuint(0)
        vao_ref = Ref(exec.quad_vao)
        glDeleteVertexArrays(1, vao_ref)
        exec.quad_vao = GLuint(0)
    end
    if exec.quad_vbo != GLuint(0)
        vbo_ref = Ref(exec.quad_vbo)
        glDeleteBuffers(1, vbo_ref)
        exec.quad_vbo = GLuint(0)
    end
end
