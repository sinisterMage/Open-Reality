# WebGPU backend implementation — WebGPUBackend struct + all backend_* methods.

"""
    WebGPUBackend <: AbstractBackend

WebGPU rendering backend using Rust's wgpu crate via C FFI.
"""
mutable struct WebGPUBackend <: AbstractBackend
    initialized::Bool
    window::Union{Window, Nothing}
    input::InputState
    backend_handle::UInt64

    # Julia-side resource caches
    gpu_cache::WebGPUGPUResourceCache
    texture_cache::WebGPUTextureCache
    bounds_cache::Dict{EntityID, BoundingSphere}

    # Rendering resource handles
    csm_handle::UInt64
    post_process_handle::UInt64

    # Configuration
    post_process_config::Union{PostProcessConfig, Nothing}
    use_deferred::Bool
    width::Int
    height::Int
end

function WebGPUBackend()
    WebGPUBackend(
        false,                          # initialized
        nothing,                        # window
        InputState(),                   # input
        UInt64(0),                      # backend_handle
        WebGPUGPUResourceCache(),       # gpu_cache
        WebGPUTextureCache(),           # texture_cache
        Dict{EntityID, BoundingSphere}(), # bounds_cache
        UInt64(0),                      # csm_handle
        UInt64(0),                      # post_process_handle
        nothing,                        # post_process_config
        true,                           # use_deferred
        1280,                           # width
        720,                            # height
    )
end

# ---- Core lifecycle ----

function initialize!(backend::WebGPUBackend; width::Int=1280, height::Int=720, title::String="OpenReality")
    backend.width = width
    backend.height = height

    # Create GLFW window with NO_API (WebGPU creates its own surface)
    ensure_glfw_init!()
    GLFW.WindowHint(GLFW.CLIENT_API, GLFW.NO_API)
    backend.window = Window()
    backend.window.handle = GLFW.CreateWindow(width, height, title)
    if backend.window.handle == C_NULL
        error("Failed to create GLFW window for WebGPU backend")
    end

    # Get raw window/display handles for the Rust FFI via GLFW native access
    if Sys.islinux()
        x11_window = ccall((:glfwGetX11Window, GLFW.libglfw), UInt64, (GLFW.Window,), backend.window.handle)
        x11_display = ccall((:glfwGetX11Display, GLFW.libglfw), Ptr{Nothing}, ())
        backend.backend_handle = wgpu_initialize(x11_window, x11_display, width, height)
    elseif Sys.iswindows()
        hwnd = ccall((:glfwGetWin32Window, GLFW.libglfw), Ptr{Nothing}, (GLFW.Window,), backend.window.handle)
        backend.backend_handle = wgpu_initialize(UInt64(hwnd), Ptr{Nothing}(C_NULL), width, height)
    else
        error("WebGPU backend not supported on this platform (use Metal on macOS)")
    end

    if backend.backend_handle == UInt64(0)
        error("Failed to initialize WebGPU backend: $(wgpu_last_error(UInt64(0)))")
    end

    # Setup input callbacks
    setup_input_callbacks!(backend.window, backend.input)

    # Create cascaded shadow maps (4 cascades, 1024x1024)
    backend.csm_handle = wgpu_create_csm(backend.backend_handle, 4, 1024, Float32(0.1), Float32(500.0))

    backend.initialized = true
    return nothing
end

function shutdown!(backend::WebGPUBackend)
    if backend.initialized && backend.backend_handle != UInt64(0)
        wgpu_shutdown(backend.backend_handle)
        backend.backend_handle = UInt64(0)
    end

    if backend.window !== nothing && backend.window.handle != C_NULL
        GLFW.DestroyWindow(backend.window.handle)
        backend.window = nothing
    end

    backend.initialized = false
    return nothing
end

function render_frame!(backend::WebGPUBackend, scene)
    !backend.initialized && return

    # Use frame_preparation to get backend-agnostic frame data
    frame_data = prepare_frame(scene, backend.bounds_cache)
    frame_data === nothing && return

    # For now, just clear to a dark blue color
    # Full deferred rendering will be implemented in Phase 3
    wgpu_render_clear(backend.backend_handle, 0.05, 0.05, 0.15)

    return nothing
end

# ---- Shader operations ----

function backend_create_shader(backend::WebGPUBackend, vertex_src::String, fragment_src::String)
    # WebGPU pipelines are created internally by Rust.
    # Shader creation is handled as part of the deferred pipeline setup.
    return WebGPUShaderProgram(UInt64(0))
end

function backend_destroy_shader!(backend::WebGPUBackend, shader::WebGPUShaderProgram)
    # Handled by Rust-side resource management
    nothing
end

function backend_use_shader!(backend::WebGPUBackend, shader::WebGPUShaderProgram)
    # No-op: pipeline binding is handled inside render_frame
    nothing
end

function backend_set_uniform!(backend::WebGPUBackend, shader::WebGPUShaderProgram, name::String, value)
    # No-op: uniforms are packed into buffers and sent in render_frame
    nothing
end

# ---- Mesh operations ----

function backend_upload_mesh!(backend::WebGPUBackend, entity_id, mesh)
    # Check cache first
    eid = EntityID(entity_id)
    if haskey(backend.gpu_cache.meshes, eid)
        return backend.gpu_cache.meshes[eid]
    end

    # Flatten mesh data to Float32/UInt32 arrays
    positions = Float32[]
    for v in mesh.vertices
        push!(positions, Float32(v[1]), Float32(v[2]), Float32(v[3]))
    end

    normals = Float32[]
    if !isempty(mesh.normals)
        for n in mesh.normals
            push!(normals, Float32(n[1]), Float32(n[2]), Float32(n[3]))
        end
    else
        # Generate placeholder normals
        normals = zeros(Float32, length(positions))
    end

    uvs = Float32[]
    if !isempty(mesh.uvs)
        for uv in mesh.uvs
            push!(uvs, Float32(uv[1]), Float32(uv[2]))
        end
    else
        uvs = zeros(Float32, length(mesh.vertices) * 2)
    end

    indices = UInt32.(mesh.indices)

    handle = wgpu_upload_mesh(backend.backend_handle, positions, normals, uvs, indices)
    if handle == UInt64(0)
        error("Failed to upload mesh: $(wgpu_last_error(backend.backend_handle))")
    end

    gpu_mesh = WebGPUGPUMesh(handle, Int32(length(indices)))
    backend.gpu_cache.meshes[eid] = gpu_mesh
    return gpu_mesh
end

function backend_draw_mesh!(backend::WebGPUBackend, gpu_mesh::WebGPUGPUMesh)
    # No-op: draw calls happen inside render_frame on the Rust side
    nothing
end

function backend_destroy_mesh!(backend::WebGPUBackend, gpu_mesh::WebGPUGPUMesh)
    wgpu_destroy_mesh(backend.backend_handle, gpu_mesh.handle)
    # Remove from cache
    for (eid, cached) in backend.gpu_cache.meshes
        if cached.handle == gpu_mesh.handle
            delete!(backend.gpu_cache.meshes, eid)
            break
        end
    end
end

# ---- Texture operations ----

function backend_upload_texture!(backend::WebGPUBackend, pixels::Vector{UInt8},
                                  width::Int, height::Int, channels::Int)
    handle = wgpu_upload_texture(backend.backend_handle, pixels, width, height, channels)
    if handle == UInt64(0)
        error("Failed to upload texture: $(wgpu_last_error(backend.backend_handle))")
    end
    return WebGPUGPUTexture(handle, width, height, channels)
end

function backend_bind_texture!(backend::WebGPUBackend, texture::WebGPUGPUTexture, unit::Int)
    # No-op: texture binding is handled in bind groups on the Rust side
    nothing
end

function backend_destroy_texture!(backend::WebGPUBackend, texture::WebGPUGPUTexture)
    wgpu_destroy_texture(backend.backend_handle, texture.handle)
end

# ---- Framebuffer operations ----

function backend_create_framebuffer!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUFramebuffer(UInt64(0), width, height)
end

function backend_bind_framebuffer!(backend::WebGPUBackend, fb::WebGPUFramebuffer)
    nothing
end

function backend_unbind_framebuffer!(backend::WebGPUBackend)
    nothing
end

function backend_destroy_framebuffer!(backend::WebGPUBackend, fb::WebGPUFramebuffer)
    nothing
end

# ---- G-Buffer operations ----

function backend_create_gbuffer!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUGBuffer(UInt64(0), width, height)
end

# ---- Shadow map operations ----

function backend_create_shadow_map!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUFramebuffer(UInt64(0), width, height)
end

function backend_create_csm!(backend::WebGPUBackend, num_cascades::Int, resolution::Int,
                              near::Float32, far::Float32)
    handle = wgpu_create_csm(backend.backend_handle, num_cascades, resolution, near, far)
    return WebGPUCascadedShadowMap(handle, num_cascades, resolution)
end

# ---- IBL operations ----

function backend_create_ibl_environment!(backend::WebGPUBackend, path::String, intensity::Float32)
    return WebGPUIBLEnvironment(UInt64(0))
end

# ---- Screen-space effect operations ----

function backend_create_ssr_pass!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUSSRPass(UInt64(0))
end

function backend_create_ssao_pass!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUSSAOPass(UInt64(0))
end

function backend_create_taa_pass!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUTAAPass(UInt64(0))
end

# ---- Post-processing operations ----

function backend_create_post_process!(backend::WebGPUBackend, width::Int, height::Int, config)
    return WebGPUPostProcessPipeline(UInt64(0))
end

# ---- Render state operations (no-ops — baked into pipelines) ----

backend_set_viewport!(b::WebGPUBackend, x::Int, y::Int, w::Int, h::Int) = nothing
backend_clear!(b::WebGPUBackend; color::Bool=true, depth::Bool=true) = nothing
backend_set_depth_test!(b::WebGPUBackend; enabled::Bool=true, write::Bool=true) = nothing
backend_set_blend!(b::WebGPUBackend; enabled::Bool=false) = nothing
backend_set_cull_face!(b::WebGPUBackend; enabled::Bool=true, front::Bool=false) = nothing
backend_swap_buffers!(b::WebGPUBackend) = nothing
backend_draw_fullscreen_quad!(b::WebGPUBackend, quad_handle) = nothing
function backend_blit_framebuffer!(b::WebGPUBackend, src, dst, width::Int, height::Int;
                                    color::Bool=false, depth::Bool=false)
    nothing
end

# ---- Windowing / event loop operations ----

backend_should_close(b::WebGPUBackend) = GLFW.WindowShouldClose(b.window.handle)

function backend_poll_events!(b::WebGPUBackend)
    GLFW.PollEvents()
    nothing
end

backend_get_time(b::WebGPUBackend) = get_time()
backend_capture_cursor!(b::WebGPUBackend) = GLFW.SetInputMode(b.window.handle, GLFW.CURSOR, GLFW.CURSOR_DISABLED)
backend_release_cursor!(b::WebGPUBackend) = GLFW.SetInputMode(b.window.handle, GLFW.CURSOR, GLFW.CURSOR_NORMAL)
backend_is_key_pressed(b::WebGPUBackend, key) = GLFW.GetKey(b.window.handle, key) == GLFW.PRESS
backend_get_input(b::WebGPUBackend) = b.input
