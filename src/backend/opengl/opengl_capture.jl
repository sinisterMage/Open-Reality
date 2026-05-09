# OpenGL framebuffer capture for visual regression testing

# Global capture hook — called just before swap_buffers! in render_frame!
# Set to a function (width, height) -> nothing to capture the current frame.
const _CAPTURE_HOOK = Ref{Union{Function, Nothing}}(nothing)

"""
    capture_framebuffer(width::Int, height::Int) -> Matrix{RGBA{Float32}}

Read the current default framebuffer (FBO 0) via glReadPixels.
Returns a (height x width) matrix of RGBA pixels in standard image orientation
(top-left origin). The OpenGL bottom-up layout is flipped automatically.

The returned matrix uses `RGBA{Float32}` from ColorTypes, with values in [0, 1],
which is directly compatible with `FileIO.save()` for PNG output.
"""
function capture_framebuffer(width::Int, height::Int)
    return _capture_default_framebuffer(width, height)
end

"""
    capture_framebuffer(backend::OpenGLBackend, width, height) -> Matrix{RGBA{Float32}}

Backend-dispatched form of [`capture_framebuffer`](@ref). Reads the current
default framebuffer; the OpenGL context held by `backend` must be current.
"""
function capture_framebuffer(backend::OpenGLBackend, width::Int, height::Int)
    return _capture_default_framebuffer(width, height)
end

function _capture_default_framebuffer(width::Int, height::Int)
    glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(0))

    pixels = Vector{UInt8}(undef, width * height * 4)
    glPixelStorei(GL_PACK_ALIGNMENT, 1)
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels)

    # Build image matrix — flip vertically (OpenGL is bottom-up, images are top-down)
    img = Matrix{RGBA{Float32}}(undef, height, width)
    for row in 1:height
        gl_row = height - row + 1  # flip
        for col in 1:width
            offset = ((gl_row - 1) * width + (col - 1)) * 4
            r = Float32(pixels[offset + 1]) / 255.0f0
            g = Float32(pixels[offset + 2]) / 255.0f0
            b = Float32(pixels[offset + 3]) / 255.0f0
            a = Float32(pixels[offset + 4]) / 255.0f0
            img[row, col] = RGBA{Float32}(r, g, b, a)
        end
    end

    return img
end

"""
    save_capture(path::String, img::Matrix{<:Colorant})

Save a captured framebuffer image to a PNG file using FileIO.
Creates parent directories if they don't exist.
"""
function save_capture(path::String, img::Matrix{<:Colorant})
    mkpath(dirname(path))
    FileIO.save(path, img)
    return nothing
end

"""
    load_reference(path::String) -> Matrix{RGBA{Float32}}

Load a reference PNG image and convert to RGBA{Float32} for comparison.
"""
function load_reference(path::String)
    raw = FileIO.load(path)
    # Convert to RGBA{Float32} regardless of source format
    return RGBA{Float32}.(raw)
end
