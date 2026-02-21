# WebGPU backend implementation — WebGPUBackend struct + all backend_* methods.

"""
    WebGPUBackend <: AbstractBackend

WebGPU rendering backend using Rust's wgpu crate via C FFI.
"""
mutable struct WebGPUBackend <: AbstractBackend
    initialized::Bool
    deferred_initialized::Bool
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

    # TAA state tracking
    prev_view_proj::Mat4f
    taa_frame_index::Int
end

function WebGPUBackend()
    WebGPUBackend(
        false,                          # initialized
        false,                          # deferred_initialized
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
        Mat4f(I),                       # prev_view_proj
        0,                              # taa_frame_index
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

    # Deferred pipeline is created lazily on the first frame (window must be visible first)
    backend.deferred_initialized = false

    backend.initialized = true
    return nothing
end

function shutdown!(backend::WebGPUBackend)
    if backend.initialized && backend.backend_handle != UInt64(0)
        # Destroy cached textures
        for (_, tex) in backend.texture_cache.textures
            wgpu_destroy_texture(backend.backend_handle, tex.handle)
        end
        empty!(backend.texture_cache.textures)

        # Destroy cached meshes
        for (_, mesh) in backend.gpu_cache.meshes
            wgpu_destroy_mesh(backend.backend_handle, mesh.handle)
        end
        empty!(backend.gpu_cache.meshes)

        # Shutdown the Rust backend (destroys deferred pipeline, CSM, etc.)
        wgpu_shutdown(backend.backend_handle)
        backend.backend_handle = UInt64(0)
    end

    if backend.window !== nothing && backend.window.handle != C_NULL
        GLFW.DestroyWindow(backend.window.handle)
        backend.window = nothing
    end

    backend.deferred_initialized = false
    backend.initialized = false
    return nothing
end

# ---- Deferred pipeline lazy initialization ----

"""
    _ensure_deferred_pipeline!(backend::WebGPUBackend)

Lazily create the deferred rendering pipeline on the first frame.
This is deferred because the window must be visible and the surface
must be configured before pipeline creation can succeed.
"""
function _ensure_deferred_pipeline!(backend::WebGPUBackend)
    backend.deferred_initialized && return true

    result = wgpu_create_deferred_pipeline(backend.backend_handle, backend.width, backend.height)
    if result != 0
        err = wgpu_last_error(backend.backend_handle)
        @warn "Failed to create WebGPU deferred pipeline" error=err
        return false
    end

    backend.deferred_initialized = true
    @info "WebGPU deferred pipeline created" width=backend.width height=backend.height
    return true
end

# ---- Render frame ----

function render_frame!(backend::WebGPUBackend, scene)
    !backend.initialized && return

    # Lazily create the deferred pipeline on first frame
    if !_ensure_deferred_pipeline!(backend)
        # Fallback to clear if pipeline creation failed
        wgpu_render_clear(backend.backend_handle, 0.05, 0.05, 0.15)
        return nothing
    end

    # Use frame_preparation to get backend-agnostic frame data (parallel when threading enabled)
    frame_data = threading_enabled() ?
        prepare_frame_parallel(scene, backend.bounds_cache) :
        prepare_frame(scene, backend.bounds_cache)
    frame_data === nothing && return

    view = frame_data.view
    proj = frame_data.proj
    cam_pos = frame_data.cam_pos

    # Compute inverse VP
    vp = proj * view
    inv_vp = inv(vp)
    time_val = Float32(backend_get_time(backend))

    # 1. Begin frame: upload per-frame uniforms
    per_frame_data = _pack_per_frame(view, proj, Mat4f(inv_vp), cam_pos, time_val)
    wgpu_begin_frame(backend.backend_handle, per_frame_data)

    # 2. Upload lights
    light_data = _pack_lights(frame_data.lights)
    wgpu_upload_lights(backend.backend_handle, light_data)

    # 3. Shadow pass (if directional light exists)
    if frame_data.primary_light_dir !== nothing
        mesh_handles = UInt64[]
        model_floats = Float32[]
        cascade_matrices = Float32[]

        # Collect all opaque entities for shadow depth
        for erd in frame_data.opaque_entities
            gpu_mesh = _ensure_mesh_uploaded(backend, erd.entity_id, erd.mesh)
            gpu_mesh === nothing && continue
            push!(mesh_handles, gpu_mesh.handle)
            # Flatten model matrix (column-major: iterate columns then rows for contiguous storage)
            m = erd.model
            for col in 1:4, row in 1:4
                push!(model_floats, Float32(m[row, col]))
            end
        end

        # Compute 4 cascade matrices
        num_cascades = 4
        split_distances = compute_cascade_splits(0.1f0, 500.0f0, num_cascades)
        for c in 1:num_cascades
            light_matrix = compute_cascade_light_matrix(view, proj,
                split_distances[c], split_distances[c + 1], frame_data.primary_light_dir)
            lm = light_matrix
            for col in 1:4, row in 1:4
                push!(cascade_matrices, Float32(lm[row, col]))
            end
        end

        if !isempty(mesh_handles)
            wgpu_shadow_pass(backend.backend_handle, mesh_handles, model_floats,
                UInt32(length(mesh_handles)), cascade_matrices, Int32(num_cascades))
        end

        # Re-upload camera per-frame data (shadow pass overwrites the buffer with cascade VPs)
        wgpu_begin_frame(backend.backend_handle, per_frame_data)
    end

    # 4. G-Buffer pass: batch into instanced + singles, then render
    if !isempty(frame_data.opaque_entities)
        # Ensure all meshes are uploaded first
        for erd in frame_data.opaque_entities
            _ensure_mesh_uploaded(backend, erd.entity_id, erd.mesh)
        end

        # Group entities into instanced batches and singles
        batches, singles = group_into_batches(frame_data.opaque_entities)

        # 4a. Render singles (non-instanced) via regular gbuffer pass
        if !isempty(singles)
            entity_stride = UInt32(264)
            entities_buf = UInt8[]
            for erd in singles
                gpu_mesh = _ensure_mesh_uploaded(backend, erd.entity_id, erd.mesh)
                gpu_mesh === nothing && continue
                material = get_component(erd.entity_id, MaterialComponent)
                tex_handles = _ensure_textures_uploaded(backend, material)
                entity_bytes = _pack_entity_raw(gpu_mesh.handle, erd.model, erd.normal_matrix, material, tex_handles)
                append!(entities_buf, entity_bytes)
            end
            if !isempty(entities_buf)
                entity_count = UInt32(length(entities_buf) ÷ Int(entity_stride))
                wgpu_gbuffer_pass(backend.backend_handle, entities_buf, entity_count, entity_stride)
            end
        end

        # 4b. Render instanced batches
        _render_wgpu_instanced_batches(backend, batches)
    end

    # 4c. Skinned G-Buffer pass: render entities with skeletal animation
    _render_wgpu_skinned_gbuffer(backend, frame_data.opaque_entities)

    # 5. Lighting pass
    wgpu_lighting_pass(backend.backend_handle)

    # 6. SSAO pass
    ssao_params = _pack_ssao_params(proj, backend.width, backend.height)
    wgpu_ssao_pass(backend.backend_handle, ssao_params)

    # 7. SSR pass
    ssr_params = _pack_ssr_params(proj, view, cam_pos, backend.width, backend.height)
    wgpu_ssr_pass(backend.backend_handle, ssr_params)

    # 8. TAA pass
    taa_params = _pack_taa_params(backend, vp)
    wgpu_taa_pass(backend.backend_handle, taa_params)
    backend.prev_view_proj = Mat4f(vp)
    backend.taa_frame_index += 1

    # 8.5. DOF pass (if enabled)
    config = backend.post_process_config
    if config !== nothing && config.dof_enabled
        dof_params = _pack_dof_params(config, proj)
        wgpu_dof_pass(backend.backend_handle, dof_params)
    end

    # 8.6. Motion blur pass (if enabled)
    if config !== nothing && config.motion_blur_enabled
        mblur_params = _pack_motion_blur_params(config, inv_vp, backend.prev_view_proj)
        wgpu_motion_blur_pass(backend.backend_handle, mblur_params)
    end

    # 9. Post-process pass
    pp_params = _pack_postprocess_params(backend)
    wgpu_postprocess_pass(backend.backend_handle, pp_params)

    # 10. Forward pass for transparent entities
    if !isempty(frame_data.transparent_entities)
        sorted_trans = sort(frame_data.transparent_entities, by=x -> -x.dist_sq)
        entity_stride = UInt32(264)
        trans_buf = UInt8[]
        for ted in sorted_trans
            gpu_mesh = _ensure_mesh_uploaded(backend, ted.entity_id, ted.mesh)
            gpu_mesh === nothing && continue
            material = get_component(ted.entity_id, MaterialComponent)
            tex_handles = _ensure_textures_uploaded(backend, material)
            entity_bytes = _pack_entity_raw(gpu_mesh.handle, ted.model, ted.normal_matrix, material, tex_handles)
            append!(trans_buf, entity_bytes)
        end
        if !isempty(trans_buf)
            entity_count = UInt32(length(trans_buf) ÷ Int(entity_stride))
            wgpu_forward_pass(backend.backend_handle, trans_buf, entity_count, entity_stride)
        end
    end

    # 11. Particle pass
    _render_wgpu_particles(backend, view, proj)

    # 12. UI pass
    _render_wgpu_ui(backend)

    # 12.5. Debug lines pass (if ENV gated debug is enabled)
    _render_wgpu_debug_lines(backend, vp)

    # 13. Present
    wgpu_present(backend.backend_handle)

    return nothing
end

# ---- Helper: Ensure mesh is uploaded ----

"""
    _ensure_mesh_uploaded(backend, entity_id, mesh) -> Union{WebGPUGPUMesh, Nothing}

Check the GPU cache for the mesh. If not cached, upload it via wgpu_upload_mesh.
Returns the WebGPUGPUMesh or nothing on failure.
"""
function _ensure_mesh_uploaded(backend::WebGPUBackend, entity_id::EntityID, mesh::MeshComponent)
    eid = entity_id
    if haskey(backend.gpu_cache.meshes, eid)
        return backend.gpu_cache.meshes[eid]
    end

    # Upload the mesh (reuses the same logic as backend_upload_mesh!)
    return backend_upload_mesh!(backend, entity_id, mesh)
end

# ---- Helper: Ensure textures are uploaded ----

"""
    _ensure_textures_uploaded(backend, material) -> NTuple{6, UInt64}

For each texture ref in the material, load from disk if not cached,
upload via wgpu_upload_texture. Returns 6 texture handles in order:
  [albedo, normal, metallic_roughness, ao, emissive, height]
A handle of 0 means no texture is bound for that slot.
"""
function _ensure_textures_uploaded(backend::WebGPUBackend, material)::NTuple{6, UInt64}
    if material === nothing
        return (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    end

    tex_refs = (
        material.albedo_map,
        material.normal_map,
        material.metallic_roughness_map,
        material.ao_map,
        material.emissive_map,
        material.height_map,
    )

    handles = ntuple(6) do i
        ref = tex_refs[i]
        ref === nothing && return UInt64(0)
        _load_and_upload_texture(backend, ref.path)
    end

    return handles
end

"""
    _load_and_upload_texture(backend, path) -> UInt64

Load texture from disk (if not cached), upload to GPU, return handle.
Returns 0 on failure.
"""
function _load_and_upload_texture(backend::WebGPUBackend, path::String)::UInt64
    # Check cache first
    if haskey(backend.texture_cache.textures, path)
        return backend.texture_cache.textures[path].handle
    end

    # Load from disk
    if !isfile(path)
        @warn "Texture file not found" path=path
        return UInt64(0)
    end

    try
        img = FileIO.load(path)
        h, w = size(img)

        # Determine channel count
        has_alpha = eltype(img) <: ColorTypes.TransparentColor
        channels = has_alpha ? 4 : 3

        # Convert to row-major UInt8 array (flipped vertically for GPU)
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

        handle = wgpu_upload_texture(backend.backend_handle, pixels, w, h, channels)
        if handle == UInt64(0)
            @warn "Failed to upload texture" path=path error=wgpu_last_error(backend.backend_handle)
            return UInt64(0)
        end

        gpu_tex = WebGPUGPUTexture(handle, w, h, channels)
        backend.texture_cache.textures[path] = gpu_tex
        return handle
    catch e
        @warn "Failed to load texture" path=path exception=e
        return UInt64(0)
    end
end

# ---- Helper: Pack entity to 264 bytes (matching Rust parser layout) ----

"""
    _pack_entity_raw(mesh_handle, model, normal_matrix, material, tex_handles) -> Vector{UInt8}

Pack a single entity to exactly 264 bytes matching the Rust EntityDrawData layout:
  [0..8)   mesh_handle (u64)
  [8..72)  model matrix (mat4, 64 bytes)
  [72..88) normal_col0 (vec4, 16 bytes)
  [88..104) normal_col1 (vec4, 16 bytes)
  [104..120) normal_col2 (vec4, 16 bytes)
  [120..216) material (MaterialUniforms, 96 bytes)
  [216..264) texture_handles ([6]u64, 48 bytes)
"""
function _pack_entity_raw(mesh_handle::UInt64, model, normal_matrix,
                           material, tex_handles::NTuple{6, UInt64})::Vector{UInt8}
    buf = Vector{UInt8}(undef, 264)

    # Mesh handle (8 bytes, little-endian)
    buf[1:8] .= reinterpret(UInt8, [mesh_handle])

    # Model matrix (64 bytes, column-major — SMatrix stores column-major natively)
    model_floats = Float32[Float32(model[i]) for i in 1:16]
    buf[9:72] .= reinterpret(UInt8, model_floats)

    # Normal matrix columns as vec4 (3 * 16 = 48 bytes)
    nc0 = Float32[Float32(normal_matrix[1,1]), Float32(normal_matrix[2,1]), Float32(normal_matrix[3,1]), 0.0f0]
    nc1 = Float32[Float32(normal_matrix[1,2]), Float32(normal_matrix[2,2]), Float32(normal_matrix[3,2]), 0.0f0]
    nc2 = Float32[Float32(normal_matrix[1,3]), Float32(normal_matrix[2,3]), Float32(normal_matrix[3,3]), 0.0f0]
    buf[73:88]  .= reinterpret(UInt8, nc0)
    buf[89:104] .= reinterpret(UInt8, nc1)
    buf[105:120] .= reinterpret(UInt8, nc2)

    # Material (96 bytes — full MaterialUniforms matching Rust layout)
    mat_buf = _pack_material_96(material)
    buf[121:216] .= mat_buf

    # Texture handles (48 bytes = 6 * u64)
    tex_data = UInt64[tex_handles[i] for i in 1:6]
    buf[217:264] .= reinterpret(UInt8, tex_data)

    return buf
end

"""
    _pack_material_96(material) -> Vector{UInt8}

Pack MaterialComponent fields into exactly 96 bytes matching the Rust MaterialUniforms layout:
  albedo [f32;4] (16), metallic f32 (4), roughness f32 (4), ao f32 (4), alpha_cutoff f32 (4),
  emissive_factor [f32;4] (16), clearcoat f32 (4), clearcoat_roughness f32 (4),
  subsurface f32 (4), parallax_scale f32 (4),
  has_albedo_map i32 (4), has_normal_map i32 (4), has_metallic_roughness_map i32 (4), has_ao_map i32 (4),
  has_emissive_map i32 (4), has_height_map i32 (4), _pad1 i32 (4), _pad2 i32 (4)
= 96 bytes total
"""
function _pack_material_96(material)::Vector{UInt8}
    buf = Vector{UInt8}(undef, 96)

    if material === nothing
        # Default white material
        data = Float32[1.0f0, 1.0f0, 1.0f0, 1.0f0,  # albedo rgba
                       0.0f0, 0.5f0, 1.0f0, 0.0f0,   # metallic, roughness, ao, alpha_cutoff
                       0.0f0, 0.0f0, 0.0f0, 0.0f0,   # emissive_factor + pad
                       0.0f0, 0.0f0, 0.0f0, 0.0f0]   # clearcoat, clearcoat_rough, subsurface, parallax
        buf[1:64] .= reinterpret(UInt8, data)
        # has_*_map flags + lod_alpha + padding (8 Int32 = 32 bytes)
        buf[65:96] .= reinterpret(UInt8, Int32[0, 0, 0, 0, 0, 0, reinterpret(Int32, 1.0f0), 0])
        return buf
    end

    # Pack floats (16 floats = 64 bytes)
    data = Float32[
        Float32(material.color.r), Float32(material.color.g), Float32(material.color.b), Float32(material.opacity),
        Float32(material.metallic), Float32(material.roughness), 1.0f0, Float32(material.alpha_cutoff),
        Float32(material.emissive_factor[1]), Float32(material.emissive_factor[2]), Float32(material.emissive_factor[3]), 0.0f0,
        Float32(material.clearcoat), Float32(material.clearcoat_roughness), Float32(material.subsurface), Float32(material.parallax_height_scale),
    ]
    buf[1:64] .= reinterpret(UInt8, data)

    # Pack has_*_map flags + lod_alpha + padding (8 Int32 = 32 bytes)
    lod_alpha_bits = reinterpret(Int32, 1.0f0)  # 0x3f800000 = fully visible
    flags = Int32[
        material.albedo_map !== nothing ? Int32(1) : Int32(0),
        material.normal_map !== nothing ? Int32(1) : Int32(0),
        material.metallic_roughness_map !== nothing ? Int32(1) : Int32(0),
        material.ao_map !== nothing ? Int32(1) : Int32(0),
        material.emissive_map !== nothing ? Int32(1) : Int32(0),
        material.height_map !== nothing ? Int32(1) : Int32(0),
        lod_alpha_bits,  # lod_alpha as f32 bits (1.0 = fully visible)
        Int32(0),  # _pad2
    ]
    buf[65:96] .= reinterpret(UInt8, flags)

    return buf
end

# ---- Helper: Pack SSAO params ----

"""
    _pack_ssao_params(proj, width, height) -> Vector{UInt8}

Pack SSAO parameters matching WGPUSSAOParams layout.
Generates a hemisphere sample kernel and packs it with the projection matrix.
"""
function _pack_ssao_params(proj, width::Int, height::Int)::Vector{UInt8}
    # Generate 64 hemisphere sample directions
    samples = Float32[]
    for i in 1:64
        # Uniform hemisphere sample
        xi1 = Float32(rand())
        xi2 = Float32(rand())
        x = Float32(cos(2.0f0 * Float32(pi) * xi1) * sqrt(1.0f0 - xi2 * xi2))
        y = Float32(sin(2.0f0 * Float32(pi) * xi1) * sqrt(1.0f0 - xi2 * xi2))
        z = Float32(xi2)
        # Scale by distance distribution (more samples closer to origin)
        scale_val = Float32(i) / 64.0f0
        scale_val = 0.1f0 + scale_val * scale_val * 0.9f0
        push!(samples, x * scale_val, y * scale_val, z * scale_val, 0.0f0)
    end

    ssao = WGPUSSAOParams(
        NTuple{256, Float32}(Tuple(samples)),
        _mat4_to_ntuple(proj),
        Int32(32),              # kernel_size
        0.5f0,                  # radius
        0.025f0,                # bias
        2.0f0,                  # power
        Float32(width),         # screen_width
        Float32(height),        # screen_height
        0.0f0,                  # _pad1
        0.0f0,                  # _pad2
    )
    return _struct_to_bytes(ssao)
end

# ---- Helper: Pack SSR params ----

"""
    _pack_ssr_params(proj, view, cam_pos, width, height) -> Vector{UInt8}

Pack SSR parameters matching WGPUSSRParams layout.
"""
function _pack_ssr_params(proj, view, cam_pos, width::Int, height::Int)::Vector{UInt8}
    inv_proj = inv(proj)
    ssr = WGPUSSRParams(
        _mat4_to_ntuple(proj),
        _mat4_to_ntuple(view),
        _mat4_to_ntuple(Mat4f(inv_proj)),
        _vec3_to_ntuple4(cam_pos, 0.0f0),
        (Float32(width), Float32(height)),
        Int32(64),              # max_steps
        50.0f0,                 # max_distance
        0.1f0,                  # thickness
        0.0f0,                  # _pad1
        0.0f0,                  # _pad2
        0.0f0,                  # _pad3
    )
    return _struct_to_bytes(ssr)
end

# ---- Helper: Pack TAA params ----

"""
    _pack_taa_params(backend, current_vp) -> Vector{UInt8}

Pack TAA parameters matching WGPUTAAParams layout.
"""
function _pack_taa_params(backend::WebGPUBackend, current_vp)::Vector{UInt8}
    taa = WGPUTAAParams(
        _mat4_to_ntuple(backend.prev_view_proj),
        0.9f0,                  # feedback factor
        Int32(backend.taa_frame_index == 0 ? 1 : 0),  # first_frame
        Float32(backend.width),
        Float32(backend.height),
    )
    return _struct_to_bytes(taa)
end

# ---- Helper: Pack post-process params ----

"""
    _pack_postprocess_params(backend) -> Vector{UInt8}

Pack post-processing parameters matching WGPUPostProcessParams layout.
Uses the backend's PostProcessConfig if available, otherwise defaults.
"""
function _pack_postprocess_params(backend::WebGPUBackend)::Vector{UInt8}
    config = backend.post_process_config

    bloom_threshold = 1.0f0
    bloom_intensity = 0.3f0
    gamma = 2.2f0
    tone_mapping_mode = Int32(0)  # Reinhard
    vignette_intensity = 0.0f0
    vignette_radius = 0.8f0
    vignette_softness = 0.5f0
    color_brightness = 0.0f0
    color_contrast = 1.0f0
    color_saturation = 1.0f0

    if config !== nothing
        bloom_threshold = config.bloom_threshold
        bloom_intensity = config.bloom_intensity
        gamma = config.gamma
        tone_mapping_mode = Int32(config.tone_mapping)
        vignette_intensity = config.vignette_enabled ? config.vignette_intensity : 0.0f0
        vignette_radius = config.vignette_radius
        vignette_softness = config.vignette_softness
        color_brightness = config.color_grading_enabled ? config.color_grading_brightness : 0.0f0
        color_contrast = config.color_grading_enabled ? config.color_grading_contrast : 1.0f0
        color_saturation = config.color_grading_enabled ? config.color_grading_saturation : 1.0f0
    end

    pp = WGPUPostProcessParams(
        bloom_threshold,
        bloom_intensity,
        gamma,
        tone_mapping_mode,
        Int32(0),               # horizontal (not used for composite)
        vignette_intensity,
        vignette_radius,
        vignette_softness,
        color_brightness,
        color_contrast,
        color_saturation,
        0.0f0,                  # _pad1
    )
    return _struct_to_bytes(pp)
end

# ---- Helper: Pack DOF params ----

"""
    _pack_dof_params(config, proj) -> Vector{Float32}

Pack DOF parameters as 8 Float32 values for the Rust FFI.
"""
function _pack_dof_params(config::PostProcessConfig, proj)::Vector{Float32}
    # Extract near/far planes from projection matrix (perspective: p[3,3] and p[3,4])
    near = Float32(proj[4,3] / (proj[3,3] - 1.0))
    far  = Float32(proj[4,3] / (proj[3,3] + 1.0))
    return Float32[
        config.dof_focus_distance,
        config.dof_focus_range,
        abs(near),
        abs(far),
        config.dof_bokeh_radius,
        0.0f0,  # pad
        0.0f0,  # pad
        0.0f0,  # pad
    ]
end

# ---- Helper: Pack motion blur params ----

"""
    _pack_motion_blur_params(config, inv_vp, prev_vp) -> Vector{UInt8}

Pack motion blur parameters matching WGPUMotionBlurParams layout (160 bytes).
"""
function _pack_motion_blur_params(config::PostProcessConfig, inv_vp, prev_vp)::Vector{UInt8}
    mblur = WGPUMotionBlurParams(
        _mat4_to_ntuple(inv_vp),
        _mat4_to_ntuple(prev_vp),
        config.motion_blur_max_velocity,
        0.0f0,  # _vel_pad1
        0.0f0,  # _vel_pad2
        0.0f0,  # _vel_pad3
        Int32(config.motion_blur_samples),
        config.motion_blur_intensity,
        0.0f0,  # _blur_pad1
        0.0f0,  # _blur_pad2
    )
    return _struct_to_bytes(mblur)
end

# ---- Helper: Render particles ----

"""
    _render_wgpu_particles(backend, view, proj)

Collect particle vertex data from all active particle pools and submit to the
wgpu_particle_pass FFI call.
"""
function _render_wgpu_particles(backend::WebGPUBackend, view::Mat4f, proj::Mat4f)
    isempty(PARTICLE_POOLS) && return

    # Collect all particle vertex data into a single buffer
    all_vertices = Float32[]
    total_vertex_count = 0

    for (eid, pool) in PARTICLE_POOLS
        pool.vertex_count <= 0 && continue
        # Pool vertex data is interleaved: pos3 + uv2 + color4 = 9 floats per vertex
        num_floats = pool.vertex_count * 9
        if num_floats <= length(pool.vertex_data)
            append!(all_vertices, @view pool.vertex_data[1:num_floats])
            total_vertex_count += pool.vertex_count
        end
    end

    total_vertex_count <= 0 && return

    # Flatten view and projection matrices to Float32 arrays (column-major)
    view_mat = Float32[Float32(view[i]) for i in 1:16]
    proj_mat = Float32[Float32(proj[i]) for i in 1:16]

    wgpu_particle_pass(backend.backend_handle, all_vertices,
        UInt32(total_vertex_count), view_mat, proj_mat)
end

# ---- Helper: Render UI ----

"""
    _render_wgpu_ui(backend)

Execute the UI callback (if registered) and submit UI vertex data to
the wgpu_ui_pass FFI call.
"""
function _render_wgpu_ui(backend::WebGPUBackend)
    _UI_CALLBACK[] === nothing && return
    _UI_CONTEXT[] === nothing && return

    ctx = _UI_CONTEXT[]
    clear_ui!(ctx)
    _UI_CALLBACK[](ctx)

    isempty(ctx.vertices) && return

    # UI vertex data: pos2 + uv2 + color4 = 8 floats per vertex
    vertex_count = length(ctx.vertices) ÷ 8
    vertex_count <= 0 && return

    wgpu_ui_pass(backend.backend_handle, ctx.vertices,
        UInt32(vertex_count), Float32(ctx.width), Float32(ctx.height))
end

# ---- Helper: Render debug lines ----

"""
    _render_wgpu_debug_lines(backend, view_proj)

Render debug lines if OPENREALITY_DEBUG is enabled. Packs DebugLine data into
pos3+color3 vertex format and calls wgpu_debug_lines_pass.
"""
function _render_wgpu_debug_lines(backend::WebGPUBackend, view_proj)
    !OPENREALITY_DEBUG && return
    isempty(_DEBUG_LINES) && return

    # Pack: 2 vertices per line, 6 floats per vertex (pos3 + color3)
    nlines = length(_DEBUG_LINES)
    vertices = Float32[]
    sizehint!(vertices, nlines * 12)
    for line in _DEBUG_LINES
        push!(vertices, Float32(line.start_pos[1]), Float32(line.start_pos[2]), Float32(line.start_pos[3]))
        push!(vertices, Float32(line.color.r), Float32(line.color.g), Float32(line.color.b))
        push!(vertices, Float32(line.end_pos[1]), Float32(line.end_pos[2]), Float32(line.end_pos[3]))
        push!(vertices, Float32(line.color.r), Float32(line.color.g), Float32(line.color.b))
    end

    vertex_count = UInt32(nlines * 2)
    vp_floats = Float32[Float32(view_proj[i]) for i in 1:16]
    wgpu_debug_lines_pass(backend.backend_handle, vertices, vertex_count, vp_floats)

    flush_debug_draw!()
end

# ---- Helper: Render instanced batches ----

"""
    _render_wgpu_instanced_batches(backend, batches)

Render instanced batches via the instanced G-Buffer pipeline.
Each batch shares one mesh + material; per-instance transforms are packed into a flat buffer.
Instance data layout: 28 floats per instance (model mat4 column-major + 3 normal vec4 columns).
"""
function _render_wgpu_instanced_batches(backend::WebGPUBackend, batches)
    isempty(batches) && return

    for batch in batches
        rep = batch.representative
        gpu_mesh = _ensure_mesh_uploaded(backend, rep.entity_id, rep.mesh)
        gpu_mesh === nothing && continue

        # Pack material for the representative entity
        material = get_component(rep.entity_id, MaterialComponent)
        material === nothing && (material = MaterialComponent())
        mat_data = _pack_material_96(material)
        tex_handles = UInt64[_ensure_textures_uploaded(backend, material)...]

        # Pack instance data: 28 floats per instance (model mat4 + 3 normal vec4)
        instance_count = length(batch.model_matrices)
        instance_data = Float32[]
        sizehint!(instance_data, instance_count * 28)
        for i in 1:instance_count
            m = batch.model_matrices[i]
            # Model matrix (column-major, 16 floats)
            for j in 1:16
                push!(instance_data, Float32(m[j]))
            end
            # Normal matrix columns as vec4 (3 * 4 = 12 floats)
            nm = batch.normal_matrices[i]
            push!(instance_data, Float32(nm[1,1]), Float32(nm[2,1]), Float32(nm[3,1]), 0.0f0)
            push!(instance_data, Float32(nm[1,2]), Float32(nm[2,2]), Float32(nm[3,2]), 0.0f0)
            push!(instance_data, Float32(nm[1,3]), Float32(nm[2,3]), Float32(nm[3,3]), 0.0f0)
        end

        wgpu_gbuffer_instanced_pass(backend.backend_handle,
            gpu_mesh.handle, mat_data, tex_handles, instance_data, instance_count)
    end
end

# ---- Helper: Render skinned entities ----

"""
    _render_wgpu_skinned_gbuffer(backend, opaque_entities)

Find entities with SkinnedMeshComponent, upload their bone matrices, and render
them via the skinned G-Buffer pipeline (LoadOp::Load preserves existing G-Buffer data).

Each skinned entity is rendered in its own pass invocation because the Rust side
has a single shared bone_uniform_buffer — uploading + drawing per entity ensures
each entity uses its own bone matrices.
"""
function _render_wgpu_skinned_gbuffer(backend::WebGPUBackend, opaque_entities)
    isempty(opaque_entities) && return

    entity_stride = UInt32(264)

    for erd in opaque_entities
        skin = get_component(erd.entity_id, SkinnedMeshComponent)
        skin === nothing && continue
        isempty(skin.bone_matrices) && continue

        gpu_mesh = _ensure_mesh_uploaded(backend, erd.entity_id, erd.mesh)
        gpu_mesh === nothing && continue

        # Upload bone matrices for this entity
        num_bones = min(length(skin.bone_matrices), 128)
        bone_floats = Float32[]
        sizehint!(bone_floats, num_bones * 16)
        for i in 1:num_bones
            m = skin.bone_matrices[i]
            for j in 1:16
                push!(bone_floats, Float32(m[j]))
            end
        end
        wgpu_upload_bone_matrices(backend.backend_handle, bone_floats, num_bones)

        # Pack and draw this single entity
        material = get_component(erd.entity_id, MaterialComponent)
        tex_handles = _ensure_textures_uploaded(backend, material)
        entity_bytes = _pack_entity_raw(gpu_mesh.handle, erd.model, erd.normal_matrix, material, tex_handles)
        wgpu_gbuffer_skinned_pass(backend.backend_handle, entity_bytes, UInt32(1), entity_stride)
    end
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
    eid = entity_id
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

    # Upload bone data for skeletal animation if available
    if !isempty(mesh.bone_weights) && !isempty(mesh.bone_indices)
        num_verts = length(mesh.bone_weights)
        bone_weights = Float32[]
        for bw in mesh.bone_weights
            push!(bone_weights, Float32(bw[1]), Float32(bw[2]), Float32(bw[3]), Float32(bw[4]))
        end
        bone_indices = UInt16[]
        for bi in mesh.bone_indices
            push!(bone_indices, UInt16(bi[1]), UInt16(bi[2]), UInt16(bi[3]), UInt16(bi[4]))
        end
        wgpu_upload_bone_data(backend.backend_handle, handle, bone_weights, bone_indices, num_verts)
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

# ---- Depth of Field ----

function backend_create_dof_pass!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUDOFPass(UInt64(0))
end

# ---- Motion Blur ----

function backend_create_motion_blur_pass!(backend::WebGPUBackend, width::Int, height::Int)
    return WebGPUMotionBlurPass(UInt64(0))
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
