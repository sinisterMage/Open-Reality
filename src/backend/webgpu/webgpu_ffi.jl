# WebGPU FFI wrappers — ccall bindings to the Rust openreality-wgpu cdylib.

# Library path discovery
const _WEBGPU_LIB_REF = Ref{String}("")

function _find_webgpu_lib()
    # Check environment variable first (set by Bazel julia_run rules)
    env_path = get(ENV, "OPENREALITY_WGPU_LIB", "")
    if !isempty(env_path) && isfile(env_path)
        return env_path
    end

    # Check several locations in order of priority
    # Workspace root target (cargo workspace) comes first, then crate-local
    _lib_name = Sys.iswindows() ? "openreality_wgpu.dll" :
        Sys.isapple() ? "libopenreality_wgpu.dylib" : "libopenreality_wgpu.so"
    _root = joinpath(@__DIR__, "..", "..", "..")
    candidates = [
        joinpath(_root, "target", "release", _lib_name),
        joinpath(_root, "openreality-wgpu", "target", "release", _lib_name),
        joinpath(_root, "target", "debug", _lib_name),
        joinpath(_root, "openreality-wgpu", "target", "debug", _lib_name),
    ]
    for path in candidates
        if isfile(path)
            return path
        end
    end
    error("Could not find openreality_wgpu library. Build it with: cd openreality-wgpu && cargo build --release")
end

function _webgpu_lib()
    if isempty(_WEBGPU_LIB_REF[])
        _WEBGPU_LIB_REF[] = _find_webgpu_lib()
    end
    return _WEBGPU_LIB_REF[]
end

# ---- Lifecycle ----

function wgpu_initialize(window_handle::UInt64, display_handle::Ptr{Nothing}, width::Int, height::Int)
    ccall((:or_wgpu_initialize, _webgpu_lib()), UInt64,
          (UInt64, Ptr{Nothing}, Int32, Int32),
          window_handle, display_handle, Int32(width), Int32(height))
end

function wgpu_shutdown(backend::UInt64)
    ccall((:or_wgpu_shutdown, _webgpu_lib()), Cvoid, (UInt64,), backend)
end

function wgpu_resize(backend::UInt64, width::Int, height::Int)
    ccall((:or_wgpu_resize, _webgpu_lib()), Cvoid,
          (UInt64, Int32, Int32),
          backend, Int32(width), Int32(height))
end

# ---- Simple rendering ----

function wgpu_render_clear(backend::UInt64, r::Float64, g::Float64, b::Float64)
    ccall((:or_wgpu_render_clear, _webgpu_lib()), Int32,
          (UInt64, Float64, Float64, Float64),
          backend, r, g, b)
end

# ---- Mesh operations ----

function wgpu_upload_mesh(backend::UInt64,
                           positions::Vector{Float32}, normals::Vector{Float32},
                           uvs::Vector{Float32}, indices::Vector{UInt32})
    num_vertices = UInt32(length(positions) ÷ 3)
    num_indices = UInt32(length(indices))
    ccall((:or_wgpu_upload_mesh, _webgpu_lib()), UInt64,
          (UInt64, Ptr{Float32}, UInt32, Ptr{Float32}, Ptr{Float32}, Ptr{UInt32}, UInt32),
          backend, positions, num_vertices, normals, uvs, indices, num_indices)
end

function wgpu_destroy_mesh(backend::UInt64, mesh::UInt64)
    ccall((:or_wgpu_destroy_mesh, _webgpu_lib()), Cvoid,
          (UInt64, UInt64), backend, mesh)
end

# ---- Texture operations ----

function wgpu_upload_texture(backend::UInt64, pixels::Vector{UInt8},
                              width::Int, height::Int, channels::Int)
    ccall((:or_wgpu_upload_texture, _webgpu_lib()), UInt64,
          (UInt64, Ptr{UInt8}, Int32, Int32, Int32),
          backend, pixels, Int32(width), Int32(height), Int32(channels))
end

function wgpu_destroy_texture(backend::UInt64, texture::UInt64)
    ccall((:or_wgpu_destroy_texture, _webgpu_lib()), Cvoid,
          (UInt64, UInt64), backend, texture)
end

# ---- Shadow maps ----

function wgpu_create_csm(backend::UInt64, num_cascades::Int, resolution::Int,
                          near::Float32, far::Float32)
    ccall((:or_wgpu_create_csm, _webgpu_lib()), UInt64,
          (UInt64, Int32, Int32, Float32, Float32),
          backend, Int32(num_cascades), Int32(resolution), near, far)
end

# ---- Post-processing ----

function wgpu_create_post_process(backend::UInt64, width::Int, height::Int,
                                    bloom_threshold::Float32, bloom_intensity::Float32,
                                    gamma::Float32, tone_mapping_mode::Int,
                                    fxaa_enabled::Bool)
    ccall((:or_wgpu_create_post_process, _webgpu_lib()), UInt64,
          (UInt64, Int32, Int32, Float32, Float32, Float32, Int32, Int32),
          backend, Int32(width), Int32(height),
          bloom_threshold, bloom_intensity, gamma,
          Int32(tone_mapping_mode), Int32(fxaa_enabled ? 1 : 0))
end

# ---- Error handling ----

function wgpu_last_error(backend::UInt64)
    ptr = ccall((:or_wgpu_last_error, _webgpu_lib()), Ptr{UInt8}, (UInt64,), backend)
    if ptr == C_NULL
        return nothing
    end
    return unsafe_string(ptr)
end

# ==================================================================
# Packed data structs for FFI boundary
# ==================================================================
# These structs are defined with exact field layout to match the Rust
# repr(C) structs in openreality-gpu-shared/src/uniforms.rs.
# All structs are isbits so they can be reinterpret-ed to raw bytes.

"""
    WGPUPerFrameUniforms

Matches Rust `PerFrameUniforms` (256 bytes with padding).
Fields: view, projection, inv_view_proj (each mat4), camera_pos (vec4),
time + 3 padding floats. Padded to 256 bytes for WebGPU uniform alignment.
"""
struct WGPUPerFrameUniforms
    view::NTuple{16, Float32}
    projection::NTuple{16, Float32}
    inv_view_proj::NTuple{16, Float32}
    camera_pos::NTuple{4, Float32}
    time::Float32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
    # 224 bytes from fields; pad to 256 for WebGPU minUniformBufferOffsetAlignment
    _alignment_pad::NTuple{8, Float32}
end

# Byte size including alignment padding
const WGPU_PER_FRAME_SIZE = 256

"""
    WGPUPointLightData

Matches Rust `PointLightData` (48 bytes).
"""
struct WGPUPointLightData
    position::NTuple{4, Float32}   # xyz + w padding
    color::NTuple{4, Float32}      # rgb + w padding
    intensity::Float32
    range::Float32
    _pad1::Float32
    _pad2::Float32
end

"""
    WGPUDirLightData

Matches Rust `DirLightData` (48 bytes).
"""
struct WGPUDirLightData
    direction::NTuple{4, Float32}  # xyz + w padding
    color::NTuple{4, Float32}      # rgb + w padding
    intensity::Float32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

"""
    WGPULightUniforms

Matches Rust `LightUniforms`.
16 point lights (48 bytes each) + 4 dir lights (48 bytes each) + 4 control ints/floats.
Total: 16*48 + 4*48 + 16 = 768 + 192 + 16 = 976 bytes.
"""
struct WGPULightUniforms
    point_lights::NTuple{16, WGPUPointLightData}
    dir_lights::NTuple{4, WGPUDirLightData}
    num_point_lights::Int32
    num_dir_lights::Int32
    has_ibl::Int32
    ibl_intensity::Float32
end

"""
    WGPUMaterialUniforms

Matches Rust `MaterialUniforms` (96 bytes).
PBR material parameters packed for GPU uniform buffer.
"""
struct WGPUMaterialUniforms
    albedo::NTuple{4, Float32}                # 16 bytes (rgba)
    metallic::Float32                          # 4
    roughness::Float32                         # 4
    ao::Float32                                # 4
    alpha_cutoff::Float32                      # 4   = 32
    emissive_factor::NTuple{4, Float32}        # 16  = 48
    clearcoat::Float32                         # 4
    clearcoat_roughness::Float32               # 4
    subsurface::Float32                        # 4
    parallax_scale::Float32                    # 4   = 64
    has_albedo_map::Int32                      # 4
    has_normal_map::Int32                      # 4
    has_metallic_roughness_map::Int32          # 4
    has_ao_map::Int32                          # 4   = 80
    has_emissive_map::Int32                    # 4
    has_height_map::Int32                      # 4
    _pad1::Int32                               # 4
    _pad2::Int32                               # 4   = 96
end

const WGPU_MATERIAL_SIZE = 96  # sizeof(WGPUMaterialUniforms)

"""
    WGPUEntityDrawData

Packed entity data for G-Buffer and forward passes.
Matches the layout parsed in lib.rs:
  offset 0:   mesh_handle (u64, 8 bytes)
  offset 8:   model matrix (mat4, 64 bytes)
  offset 72:  normal_col0 (vec4, 16 bytes)
  offset 88:  normal_col1 (vec4, 16 bytes)
  offset 104: normal_col2 (vec4, 16 bytes)
  offset 120: material (WGPUMaterialUniforms, 96 bytes)
  offset 216: texture_handles (6 x u64, 48 bytes)
  Total: 264 bytes
"""
struct WGPUEntityDrawData
    mesh_handle::UInt64                        # 8 bytes
    model::NTuple{16, Float32}                 # 64 bytes (column-major mat4)
    normal_col0::NTuple{4, Float32}            # 16 bytes
    normal_col1::NTuple{4, Float32}            # 16 bytes
    normal_col2::NTuple{4, Float32}            # 16 bytes
    material::WGPUMaterialUniforms             # 96 bytes
    texture_handles::NTuple{6, UInt64}         # 48 bytes
end

const WGPU_ENTITY_DRAW_DATA_SIZE = Int(sizeof(WGPUEntityDrawData))

"""
    WGPUSSAOParams

Matches Rust `SSAOParams`.
64 hemisphere sample directions (vec4 each) + projection matrix + control params.
Total: 64*16 + 64 + 32 = 1024 + 64 + 32 = 1120 bytes.
"""
struct WGPUSSAOParams
    samples::NTuple{256, Float32}              # 64 vec4 samples = 256 floats = 1024 bytes
    projection::NTuple{16, Float32}            # mat4 = 64 bytes
    kernel_size::Int32                         # 4
    radius::Float32                            # 4
    bias::Float32                              # 4
    power::Float32                             # 4
    screen_width::Float32                      # 4
    screen_height::Float32                     # 4
    _pad1::Float32                             # 4
    _pad2::Float32                             # 4
end

"""
    WGPUSSRParams

Matches Rust `SSRParams`.
3 matrices (projection, view, inv_projection) + camera_pos + control params.
Total: 3*64 + 16 + 32 = 240 bytes.
"""
struct WGPUSSRParams
    projection::NTuple{16, Float32}            # mat4 = 64 bytes
    view::NTuple{16, Float32}                  # mat4 = 64 bytes
    inv_projection::NTuple{16, Float32}        # mat4 = 64 bytes
    camera_pos::NTuple{4, Float32}             # vec4 = 16 bytes
    screen_size::NTuple{2, Float32}            # 8 bytes
    max_steps::Int32                           # 4
    max_distance::Float32                      # 4
    thickness::Float32                         # 4
    _pad1::Float32                             # 4
    _pad2::Float32                             # 4
    _pad3::Float32                             # 4
end

"""
    WGPUTAAParams

Matches Rust `TAAParams`.
Previous frame view-projection matrix + control params.
Total: 64 + 16 = 80 bytes.
"""
struct WGPUTAAParams
    prev_view_proj::NTuple{16, Float32}        # mat4 = 64 bytes
    feedback::Float32                          # 4
    first_frame::Int32                         # 4
    screen_width::Float32                      # 4
    screen_height::Float32                     # 4
end

"""
    WGPUPostProcessParams

Matches Rust `PostProcessParams`.
Bloom and tone mapping control params.
Total: 32 bytes.
"""
struct WGPUPostProcessParams
    bloom_threshold::Float32                   # 4
    bloom_intensity::Float32                   # 4
    gamma::Float32                             # 4
    tone_mapping_mode::Int32                   # 4
    horizontal::Int32                          # 4
    _pad1::Float32                             # 4
    _pad2::Float32                             # 4
    _pad3::Float32                             # 4
end

"""
    WGPUCascadeData

Matches Rust `CascadeData` (80 bytes).
Single shadow cascade: light-space VP matrix + split depth.
"""
struct WGPUCascadeData
    light_view_proj::NTuple{16, Float32}       # mat4 = 64 bytes
    split_depth::Float32                       # 4
    _pad1::Float32                             # 4
    _pad2::Float32                             # 4
    _pad3::Float32                             # 4
end

"""
    WGPUShadowUniforms

Matches Rust `ShadowUniforms`.
4 cascade data entries + control params.
Total: 4*80 + 16 = 336 bytes.
"""
struct WGPUShadowUniforms
    cascades::NTuple{4, WGPUCascadeData}       # 4 * 80 = 320 bytes
    num_cascades::Int32                        # 4
    shadow_bias::Float32                       # 4
    _pad1::Float32                             # 4
    _pad2::Float32                             # 4
end

# ==================================================================
# FFI: Deferred Pipeline Setup
# ==================================================================

"""
    wgpu_create_deferred_pipeline(backend, width, height) -> Int32

Create the full deferred rendering pipeline (all pipelines and render targets).
Call once after initialize. Returns 0 on success, -1 on failure.
"""
function wgpu_create_deferred_pipeline(backend::UInt64, width::Int, height::Int)
    ccall((:or_wgpu_create_deferred_pipeline, _webgpu_lib()), Int32,
          (UInt64, Int32, Int32),
          backend, Int32(width), Int32(height))
end

"""
    wgpu_resize_pipeline(backend, width, height)

Resize the deferred pipeline render targets.
"""
function wgpu_resize_pipeline(backend::UInt64, width::Int, height::Int)
    ccall((:or_wgpu_resize_pipeline, _webgpu_lib()), Cvoid,
          (UInt64, Int32, Int32),
          backend, Int32(width), Int32(height))
end

# ==================================================================
# FFI: Per-Frame Rendering Calls
# ==================================================================

"""
    wgpu_begin_frame(backend, per_frame_data) -> Int32

Upload per-frame uniforms (view, projection, inv_view_proj, camera_pos, time).
`per_frame_data` is a Vector{UInt8} containing a packed WGPUPerFrameUniforms.
Returns 0 on success, -1 on failure.
"""
function wgpu_begin_frame(backend::UInt64, per_frame_data::Vector{UInt8})
    ccall((:or_wgpu_begin_frame, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}, UInt32),
          backend, per_frame_data, UInt32(length(per_frame_data)))
end

"""
    wgpu_upload_lights(backend, light_data) -> Int32

Upload light uniform data (LightUniforms struct).
`light_data` is a Vector{UInt8} containing a packed WGPULightUniforms.
Returns 0 on success, -1 on failure.
"""
function wgpu_upload_lights(backend::UInt64, light_data::Vector{UInt8})
    ccall((:or_wgpu_upload_lights, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}, UInt32),
          backend, light_data, UInt32(length(light_data)))
end

"""
    wgpu_shadow_pass(backend, mesh_handles, models, entity_count, cascade_matrices, num_cascades) -> Int32

Render depth for all shadow cascades.
- `mesh_handles`: Vector{UInt64} of mesh handles (one per entity)
- `models`: Vector{Float32} of flattened model matrices (16 floats per entity)
- `entity_count`: number of entities
- `cascade_matrices`: Vector{Float32} of flattened cascade light-space VP matrices (16 floats per cascade)
- `num_cascades`: number of cascades (typically 4)
Returns 0 on success, -1 on failure.
"""
function wgpu_shadow_pass(backend::UInt64,
                           mesh_handles::Vector{UInt64},
                           models::Vector{Float32},
                           entity_count::Integer,
                           cascade_matrices::Vector{Float32},
                           num_cascades::Integer)
    ccall((:or_wgpu_shadow_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt64}, Ptr{Float32}, UInt32, Ptr{Float32}, Int32),
          backend, mesh_handles, models, UInt32(entity_count),
          cascade_matrices, Int32(num_cascades))
end

"""
    wgpu_gbuffer_pass(backend, entities_data, entity_count, entity_stride) -> Int32

Render all opaque entities into the G-Buffer.
- `entities_data`: Vector{UInt8} of packed WGPUEntityDrawData structs
- `entity_count`: number of entities
- `entity_stride`: byte size of each entity (sizeof(WGPUEntityDrawData))
Returns 0 on success, -1 on failure.
"""
function wgpu_gbuffer_pass(backend::UInt64,
                            entities_data::Vector{UInt8},
                            entity_count::Integer,
                            entity_stride::Integer)
    ccall((:or_wgpu_gbuffer_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}, UInt32, UInt32),
          backend, entities_data, UInt32(entity_count), UInt32(entity_stride))
end

"""
    wgpu_lighting_pass(backend) -> Int32

Fullscreen deferred PBR lighting pass. Uses G-Buffer and light data already uploaded.
Returns 0 on success, -1 on failure.
"""
function wgpu_lighting_pass(backend::UInt64)
    ccall((:or_wgpu_lighting_pass, _webgpu_lib()), Int32,
          (UInt64,),
          backend)
end

"""
    wgpu_ssao_pass(backend, params) -> Int32

Compute screen-space ambient occlusion from G-Buffer.
`params` is a Vector{UInt8} containing a packed WGPUSSAOParams.
Returns 0 on success, -1 on failure.
"""
function wgpu_ssao_pass(backend::UInt64, params::Vector{UInt8})
    ccall((:or_wgpu_ssao_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}),
          backend, params)
end

"""
    wgpu_ssr_pass(backend, params) -> Int32

Screen-space reflections pass.
`params` is a Vector{UInt8} containing a packed WGPUSSRParams.
Returns 0 on success, -1 on failure.
"""
function wgpu_ssr_pass(backend::UInt64, params::Vector{UInt8})
    ccall((:or_wgpu_ssr_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}),
          backend, params)
end

"""
    wgpu_taa_pass(backend, params) -> Int32

Temporal anti-aliasing pass.
`params` is a Vector{UInt8} containing a packed WGPUTAAParams.
Returns 0 on success, -1 on failure.
"""
function wgpu_taa_pass(backend::UInt64, params::Vector{UInt8})
    ccall((:or_wgpu_taa_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}),
          backend, params)
end

"""
    wgpu_postprocess_pass(backend, params) -> Int32

Post-processing pass: bloom extraction, blur, composite, FXAA.
`params` is a Vector{UInt8} containing a packed WGPUPostProcessParams.
Returns 0 on success, -1 on failure.
"""
function wgpu_postprocess_pass(backend::UInt64, params::Vector{UInt8})
    ccall((:or_wgpu_postprocess_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}),
          backend, params)
end

"""
    wgpu_forward_pass(backend, entities_data, entity_count, entity_stride) -> Int32

Render transparent objects (forward pass with blending).
Same packed entity format as gbuffer_pass.
Returns 0 on success, -1 on failure.
"""
function wgpu_forward_pass(backend::UInt64,
                            entities_data::Vector{UInt8},
                            entity_count::Integer,
                            entity_stride::Integer)
    ccall((:or_wgpu_forward_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{UInt8}, UInt32, UInt32),
          backend, entities_data, UInt32(entity_count), UInt32(entity_stride))
end

"""
    wgpu_particle_pass(backend, vertices, vertex_count, view_mat, proj_mat) -> Int32

Render particle billboard quads.
- `vertices`: Vector{Float32} of interleaved vertex data (pos3 + uv2 + color4 = 9 floats/vertex)
- `vertex_count`: number of vertices
- `view_mat`: Vector{Float32} of 16 floats (column-major mat4 view matrix)
- `proj_mat`: Vector{Float32} of 16 floats (column-major mat4 projection matrix)
Returns 0 on success, -1 on failure.
"""
function wgpu_particle_pass(backend::UInt64,
                             vertices::Vector{Float32},
                             vertex_count::Integer,
                             view_mat::Vector{Float32},
                             proj_mat::Vector{Float32})
    ccall((:or_wgpu_particle_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{Float32}, UInt32, Ptr{Float32}, Ptr{Float32}),
          backend, vertices, UInt32(vertex_count), view_mat, proj_mat)
end

"""
    wgpu_ui_pass(backend, vertices, vertex_count, screen_width, screen_height) -> Int32

Render 2D UI overlay.
- `vertices`: Vector{Float32} of interleaved vertex data (pos2 + uv2 + color4 = 8 floats/vertex)
- `vertex_count`: number of vertices
- `screen_width`, `screen_height`: viewport dimensions for orthographic projection
Returns 0 on success, -1 on failure.
"""
function wgpu_ui_pass(backend::UInt64,
                       vertices::Vector{Float32},
                       vertex_count::Integer,
                       screen_width::Real,
                       screen_height::Real)
    ccall((:or_wgpu_ui_pass, _webgpu_lib()), Int32,
          (UInt64, Ptr{Float32}, UInt32, Float32, Float32),
          backend, vertices, UInt32(vertex_count),
          Float32(screen_width), Float32(screen_height))
end

"""
    wgpu_present(backend) -> Int32

Present: blit the final post-processed result to the swapchain.
Returns 0 on success, -1 on failure.
"""
function wgpu_present(backend::UInt64)
    ccall((:or_wgpu_present, _webgpu_lib()), Int32,
          (UInt64,),
          backend)
end

# ==================================================================
# Helper: reinterpret an isbits struct to a UInt8 vector
# ==================================================================

"""
    _struct_to_bytes(s) -> Vector{UInt8}

Reinterpret any isbits struct as a byte vector. The struct must have a fixed
memory layout (no pointers, no heap-allocated fields).
"""
function _struct_to_bytes(s::T) where T
    buf = Vector{UInt8}(undef, sizeof(T))
    GC.@preserve buf begin
        unsafe_store!(Ptr{T}(pointer(buf)), s)
    end
    return buf
end

"""
    _mat4_to_ntuple(m) -> NTuple{16, Float32}

Convert a 4x4 matrix (column-major SMatrix or Matrix) to an NTuple{16, Float32}.
Assumes column-major storage order.
"""
function _mat4_to_ntuple(m)::NTuple{16, Float32}
    return ntuple(i -> Float32(m[i]), 16)
end

"""
    _vec3_to_ntuple4(v, w=0.0f0) -> NTuple{4, Float32}

Convert a 3-element vector to a padded NTuple{4, Float32} (xyz + w).
"""
function _vec3_to_ntuple4(v, w::Float32=0.0f0)::NTuple{4, Float32}
    return (Float32(v[1]), Float32(v[2]), Float32(v[3]), w)
end

# ==================================================================
# Helper: _pack_per_frame
# ==================================================================

"""
    _pack_per_frame(view, proj, inv_vp, cam_pos, time) -> Vector{UInt8}

Pack per-frame uniforms into a byte buffer matching WGPUPerFrameUniforms (256 bytes).

Arguments:
- `view`: 4x4 view matrix (column-major)
- `proj`: 4x4 projection matrix (column-major)
- `inv_vp`: 4x4 inverse view-projection matrix (column-major)
- `cam_pos`: 3-element camera position vector
- `time`: elapsed time in seconds
"""
function _pack_per_frame(view, proj, inv_vp, cam_pos, time::Real)::Vector{UInt8}
    pf = WGPUPerFrameUniforms(
        _mat4_to_ntuple(view),
        _mat4_to_ntuple(proj),
        _mat4_to_ntuple(inv_vp),
        _vec3_to_ntuple4(cam_pos, 1.0f0),
        Float32(time),
        0.0f0,  # _pad1
        0.0f0,  # _pad2
        0.0f0,  # _pad3
        ntuple(_ -> 0.0f0, 8),  # alignment padding to 256 bytes
    )
    return _struct_to_bytes(pf)
end

# ==================================================================
# Helper: _pack_lights
# ==================================================================

"""
    _pack_lights(frame_light_data) -> Vector{UInt8}

Pack a FrameLightData into a byte buffer matching WGPULightUniforms.

Converts up to 16 point lights and 4 directional lights from the engine's
FrameLightData struct into the packed GPU format.
"""
function _pack_lights(fld)::Vector{UInt8}
    # Pack point lights (up to 16)
    num_point = min(length(fld.point_positions), 16)
    point_lights = ntuple(16) do i
        if i <= num_point
            pos = fld.point_positions[i]
            col = fld.point_colors[i]
            WGPUPointLightData(
                (Float32(pos[1]), Float32(pos[2]), Float32(pos[3]), 0.0f0),
                (Float32(col.r), Float32(col.g), Float32(col.b), 1.0f0),
                Float32(fld.point_intensities[i]),
                Float32(fld.point_ranges[i]),
                0.0f0,
                0.0f0,
            )
        else
            WGPUPointLightData(
                (0.0f0, 0.0f0, 0.0f0, 0.0f0),
                (0.0f0, 0.0f0, 0.0f0, 0.0f0),
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
            )
        end
    end

    # Pack directional lights (up to 4)
    num_dir = min(length(fld.dir_directions), 4)
    dir_lights = ntuple(4) do i
        if i <= num_dir
            dir = fld.dir_directions[i]
            col = fld.dir_colors[i]
            WGPUDirLightData(
                (Float32(dir[1]), Float32(dir[2]), Float32(dir[3]), 0.0f0),
                (Float32(col.r), Float32(col.g), Float32(col.b), 1.0f0),
                Float32(fld.dir_intensities[i]),
                0.0f0, 0.0f0, 0.0f0,
            )
        else
            WGPUDirLightData(
                (0.0f0, 0.0f0, 0.0f0, 0.0f0),
                (0.0f0, 0.0f0, 0.0f0, 0.0f0),
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
            )
        end
    end

    lu = WGPULightUniforms(
        point_lights,
        dir_lights,
        Int32(num_point),
        Int32(num_dir),
        Int32(fld.has_ibl ? 1 : 0),
        Float32(fld.ibl_intensity),
    )
    return _struct_to_bytes(lu)
end

# ==================================================================
# Helper: _pack_material
# ==================================================================

"""
    _pack_material(mat, has_albedo, has_normal, has_mr, has_ao, has_emissive, has_height) -> WGPUMaterialUniforms

Convert a MaterialComponent and boolean texture-presence flags into a packed
WGPUMaterialUniforms struct.
"""
function _pack_material(mat,
                         has_albedo::Bool, has_normal::Bool,
                         has_mr::Bool, has_ao::Bool,
                         has_emissive::Bool, has_height::Bool)::WGPUMaterialUniforms
    WGPUMaterialUniforms(
        (Float32(mat.color.r), Float32(mat.color.g), Float32(mat.color.b), Float32(mat.opacity)),
        Float32(mat.metallic),
        Float32(mat.roughness),
        1.0f0,                        # ao (default full)
        Float32(mat.alpha_cutoff),
        (Float32(mat.emissive_factor[1]), Float32(mat.emissive_factor[2]),
         Float32(mat.emissive_factor[3]), 0.0f0),
        Float32(mat.clearcoat),
        Float32(mat.clearcoat_roughness),
        Float32(mat.subsurface),
        Float32(mat.parallax_height_scale),
        Int32(has_albedo ? 1 : 0),
        Int32(has_normal ? 1 : 0),
        Int32(has_mr ? 1 : 0),
        Int32(has_ao ? 1 : 0),
        Int32(has_emissive ? 1 : 0),
        Int32(has_height ? 1 : 0),
        Int32(0),  # _pad1
        Int32(0),  # _pad2
    )
end

# ==================================================================
# Helper: _pack_entity
# ==================================================================

"""
    _pack_entity(mesh_handle, model, normal_matrix, material, texture_handles) -> Vector{UInt8}

Pack a single entity's draw data into a byte buffer matching WGPUEntityDrawData.

Arguments:
- `mesh_handle`: UInt64 GPU mesh handle
- `model`: 4x4 model matrix (column-major)
- `normal_matrix`: 3x3 normal matrix (column-major; stored as 3 vec4 columns)
- `material`: WGPUMaterialUniforms (already packed)
- `texture_handles`: NTuple{6, UInt64} or Vector of 6 texture handles (0 = no texture)
"""
function _pack_entity(mesh_handle::UInt64,
                       model,
                       normal_matrix,
                       material::WGPUMaterialUniforms,
                       texture_handles)::Vector{UInt8}
    # Extract normal matrix columns as vec4 (pad w=0)
    nc0 = (Float32(normal_matrix[1,1]), Float32(normal_matrix[2,1]),
           Float32(normal_matrix[3,1]), 0.0f0)
    nc1 = (Float32(normal_matrix[1,2]), Float32(normal_matrix[2,2]),
           Float32(normal_matrix[3,2]), 0.0f0)
    nc2 = (Float32(normal_matrix[1,3]), Float32(normal_matrix[2,3]),
           Float32(normal_matrix[3,3]), 0.0f0)

    # Build texture handles NTuple
    tex = if texture_handles isa NTuple{6, UInt64}
        texture_handles
    else
        ntuple(i -> i <= length(texture_handles) ? UInt64(texture_handles[i]) : UInt64(0), 6)
    end

    entity = WGPUEntityDrawData(
        mesh_handle,
        _mat4_to_ntuple(model),
        nc0,
        nc1,
        nc2,
        material,
        tex,
    )
    return _struct_to_bytes(entity)
end
