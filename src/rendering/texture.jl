# GPU texture loading, creation, and caching

using ModernGL
using FileIO
using ColorTypes

"""
    GPUTexture

OpenGL texture handle with metadata.
"""
mutable struct GPUTexture
    id::GLuint
    width::Int
    height::Int
    channels::Int

    GPUTexture() = new(GLuint(0), 0, 0, 0)
end

"""
    TextureCache

Caches loaded textures by file path to avoid duplicate GPU uploads.
"""
mutable struct TextureCache
    textures::Dict{String, GPUTexture}
    TextureCache() = new(Dict{String, GPUTexture}())
end

"""
    load_texture(cache::TextureCache, path::String) -> GPUTexture

Load an image from disk, upload to GPU as a 2D texture.
Returns cached texture if the same path was loaded before.
"""
function load_texture(cache::TextureCache, path::String)
    if haskey(cache.textures, path)
        return cache.textures[path]
    end

    img = FileIO.load(path)
    h, w = size(img)

    # Determine channel count
    has_alpha = eltype(img) <: ColorTypes.TransparentColor
    channels = has_alpha ? 4 : 3

    # Convert image to row-major UInt8 array, flipped vertically for OpenGL
    pixels = Vector{UInt8}(undef, w * h * channels)
    idx = 1
    for row in h:-1:1
        for col in 1:w
            pixel = img[row, col]
            pixels[idx]     = round(UInt8, clamp(Float64(red(pixel)), 0, 1) * 255)
            pixels[idx + 1] = round(UInt8, clamp(Float64(green(pixel)), 0, 1) * 255)
            pixels[idx + 2] = round(UInt8, clamp(Float64(blue(pixel)), 0, 1) * 255)
            if has_alpha
                pixels[idx + 3] = round(UInt8, clamp(Float64(alpha(pixel)), 0, 1) * 255)
            end
            idx += channels
        end
    end

    gpu = upload_texture_to_gpu(pixels, w, h, channels)
    cache.textures[path] = gpu
    return gpu
end

"""
    upload_texture_to_gpu(pixels::Vector{UInt8}, width, height, channels) -> GPUTexture

Create an OpenGL 2D texture from raw pixel data.
"""
function upload_texture_to_gpu(pixels::Vector{UInt8}, width::Int, height::Int, channels::Int)
    tex = GPUTexture()
    tex.width = width
    tex.height = height
    tex.channels = channels

    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    tex.id = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, tex.id)

    gl_format = channels == 4 ? GL_RGBA : GL_RGB

    glTexImage2D(GL_TEXTURE_2D, 0, gl_format, width, height, 0,
                 gl_format, GL_UNSIGNED_BYTE, pixels)
    glGenerateMipmap(GL_TEXTURE_2D)

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)

    glBindTexture(GL_TEXTURE_2D, GLuint(0))
    return tex
end

"""
    destroy_texture!(tex::GPUTexture)

Delete an OpenGL texture.
"""
function destroy_texture!(tex::GPUTexture)
    if tex.id != GLuint(0)
        glDeleteTextures(1, Ref(tex.id))
        tex.id = GLuint(0)
    end
end

"""
    destroy_all_textures!(cache::TextureCache)

Delete all cached textures.
"""
function destroy_all_textures!(cache::TextureCache)
    for (_, tex) in cache.textures
        destroy_texture!(tex)
    end
    empty!(cache.textures)
end
