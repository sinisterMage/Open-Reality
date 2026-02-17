# WebGPU backend concrete types.
# Each type wraps an opaque UInt64 handle returned by the Rust FFI library.

# ==================================================================
# Concrete GPU resource types
# ==================================================================

"""
    WebGPUShaderProgram <: AbstractShaderProgram

WebGPU render pipeline handle (opaque, managed by Rust FFI).
"""
struct WebGPUShaderProgram <: AbstractShaderProgram
    handle::UInt64
end

"""
    WebGPUGPUMesh <: AbstractGPUMesh

WebGPU GPU-resident mesh with vertex and index buffers.
"""
struct WebGPUGPUMesh <: AbstractGPUMesh
    handle::UInt64
    index_count::Int32
end

get_index_count(mesh::WebGPUGPUMesh) = mesh.index_count

"""
    WebGPUGPUTexture <: AbstractGPUTexture

WebGPU GPU-resident texture.
"""
struct WebGPUGPUTexture <: AbstractGPUTexture
    handle::UInt64
    width::Int
    height::Int
    channels::Int
end

"""
    WebGPUFramebuffer <: AbstractFramebuffer

WebGPU render target (framebuffer equivalent).
"""
struct WebGPUFramebuffer <: AbstractFramebuffer
    handle::UInt64
    width::Int
    height::Int
end

get_width(fb::WebGPUFramebuffer) = fb.width
get_height(fb::WebGPUFramebuffer) = fb.height

"""
    WebGPUGBuffer <: AbstractGBuffer

WebGPU G-Buffer with multiple render targets for deferred rendering.
"""
struct WebGPUGBuffer <: AbstractGBuffer
    handle::UInt64
    width::Int
    height::Int
end

"""
    WebGPUCascadedShadowMap <: AbstractCascadedShadowMap

WebGPU cascaded shadow map (4 cascades).
"""
struct WebGPUCascadedShadowMap <: AbstractCascadedShadowMap
    handle::UInt64
    num_cascades::Int
    resolution::Int
end

"""
    WebGPUPostProcessPipeline <: AbstractPostProcessPipeline

WebGPU post-processing pipeline (bloom, tone mapping, FXAA).
"""
struct WebGPUPostProcessPipeline <: AbstractPostProcessPipeline
    handle::UInt64
end

"""
    WebGPUSSAOPass <: AbstractSSAOPass

WebGPU SSAO pass.
"""
struct WebGPUSSAOPass <: AbstractSSAOPass
    handle::UInt64
end

"""
    WebGPUSSRPass <: AbstractSSRPass

WebGPU SSR pass.
"""
struct WebGPUSSRPass <: AbstractSSRPass
    handle::UInt64
end

"""
    WebGPUTAAPass <: AbstractTAAPass

WebGPU TAA pass.
"""
struct WebGPUTAAPass <: AbstractTAAPass
    handle::UInt64
end

"""
    WebGPUIBLEnvironment <: AbstractIBLEnvironment

WebGPU Image-Based Lighting environment.
"""
struct WebGPUIBLEnvironment <: AbstractIBLEnvironment
    handle::UInt64
end

"""
    WebGPUDOFPass <: AbstractDOFPass

WebGPU depth-of-field pass.
"""
struct WebGPUDOFPass <: AbstractDOFPass
    handle::UInt64
end

"""
    WebGPUMotionBlurPass <: AbstractMotionBlurPass

WebGPU motion blur pass.
"""
struct WebGPUMotionBlurPass <: AbstractMotionBlurPass
    handle::UInt64
end

# ==================================================================
# Resource caches (Julia-side, map EntityID to handle)
# ==================================================================

"""
    WebGPUGPUResourceCache

Cache of uploaded GPU meshes, keyed by EntityID.
"""
mutable struct WebGPUGPUResourceCache
    meshes::Dict{EntityID, WebGPUGPUMesh}
end

WebGPUGPUResourceCache() = WebGPUGPUResourceCache(Dict{EntityID, WebGPUGPUMesh}())

"""
    WebGPUTextureCache

Cache of uploaded GPU textures, keyed by file path.
"""
mutable struct WebGPUTextureCache
    textures::Dict{String, WebGPUGPUTexture}
end

WebGPUTextureCache() = WebGPUTextureCache(Dict{String, WebGPUGPUTexture}())
