"""
    OpenRealityVulkanExt

Package extension that provides the concrete Vulkan rendering backend
(`VulkanBackendImpl <: OpenReality.VulkanBackend`) and all of its supporting
GPU resource types and methods.

This extension is loaded automatically by Julia when both `OpenReality` and
`Vulkan` are in scope. On macOS we never load it — Vulkan.jl's precompilation
is broken on Apple Silicon and the Metal backend is the supported path. On
Linux/Windows, `OpenReality.__init__` installs and `using`s `Vulkan`, which
triggers Julia to load this extension.

The included source files still live under `src/backend/vulkan/`; the only
reason we keep them there (instead of moving under `ext/`) is to minimise the
diff and keep the OpenGL/Metal/Vulkan backends side-by-side in one tree.
"""
module OpenRealityVulkanExt

using OpenReality
using Vulkan
using glslang_jll
import GLFW

# Pull in the GeometryBasics / StaticArrays / LinearAlgebra / ColorTypes
# symbols that the Vulkan backend source files reference without a module
# qualifier. They are reachable through `OpenReality.*` because OpenReality
# does `using` them at module load, but they aren't re-exported.
using OpenReality:
    SMatrix, SVector, MMatrix, MVector, StaticArrays,
    Vec, Point, Mat4f, Mat3f, Vec2f, Vec3f, Vec4f, Point3f,
    RGB, RGBA,
    inv, transpose, I, dot, cross, norm, normalize, det

# Non-exported OpenReality symbols accessed by the included Vulkan source
# files. Keep this list in sync if the Vulkan backend grows new references.
using OpenReality: ensure_glfw_init!, _COMPUTE_SUPPORTED

# Generic functions defined in OpenReality that the included files extend with
# methods specialised on `VulkanBackendImpl`. Listing them with `import` is
# what makes `function foo(backend::VulkanBackendImpl, ...)` add a method to
# `OpenReality.foo` rather than shadow it inside this extension module.
import OpenReality:
    # Core lifecycle
    initialize!, shutdown!, render_frame!,
    # Shader / mesh / texture
    backend_create_shader, backend_destroy_shader!,
    backend_use_shader!, backend_set_uniform!,
    backend_upload_mesh!, backend_draw_mesh!, backend_destroy_mesh!,
    backend_draw_mesh_instanced!,
    backend_upload_texture!, backend_bind_texture!, backend_destroy_texture!,
    # Framebuffer / G-buffer / shadow map
    backend_create_framebuffer!, backend_bind_framebuffer!,
    backend_unbind_framebuffer!, backend_destroy_framebuffer!,
    backend_create_gbuffer!, backend_create_shadow_map!, backend_create_csm!,
    # IBL / screen-space passes
    backend_create_ibl_environment!,
    backend_create_ssr_pass!, backend_create_ssao_pass!, backend_create_taa_pass!,
    backend_create_post_process!,
    backend_create_dof_pass!, backend_create_motion_blur_pass!,
    # Render state / windowing
    backend_set_viewport!, backend_clear!, backend_set_depth_test!,
    backend_set_blend!, backend_set_cull_face!,
    backend_swap_buffers!, backend_draw_fullscreen_quad!,
    backend_blit_framebuffer!,
    backend_should_close, backend_poll_events!, backend_get_time,
    backend_capture_cursor!, backend_release_cursor!,
    backend_is_key_pressed, backend_get_input,
    # Terrain
    backend_render_terrain!, render_streaming_terrain_gbuffer!,
    # Render graph executor interface
    allocate_resources!, execute_graph!,
    resize_resources!, destroy_resources!,
    set_imported_resource!, get_physical_resource,
    # Render graph pass stubs (defined in src/rendering/deferred_graph.jl)
    execute_rg_shadow_csm!, execute_rg_gbuffer!, execute_rg_terrain_gbuffer!,
    execute_rg_deferred_lighting!, execute_rg_ssao!, execute_rg_ssao_blur!,
    execute_rg_ssr!, execute_rg_composite_lighting!, execute_rg_taa!,
    execute_rg_dof_coc!, execute_rg_dof_blur!, execute_rg_dof_composite!,
    execute_rg_mblur_velocity!, execute_rg_mblur_blur!,
    execute_rg_bloom_extract!, execute_rg_bloom_blur!,
    execute_rg_post_composite!, execute_rg_fxaa!,
    execute_rg_depth_copy!, execute_rg_forward_transparent!,
    execute_rg_particles!, execute_rg_ui!, execute_rg_debug_draw!,
    execute_rg_present!,
    # Framebuffer capture (for visual regression tests)
    capture_framebuffer

# Resolve the source directory at module-init time. `pkgdir(OpenReality)`
# returns the package root regardless of whether OpenReality is being used
# from a dev checkout or an installed depot.
const _VULKAN_SRC = joinpath(pkgdir(OpenReality), "src", "backend", "vulkan")

# Order matches the previous in-tree includes in `src/OpenReality.jl` so
# inter-file references resolve identically.
include(joinpath(_VULKAN_SRC, "vulkan_types.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_memory.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_device.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_swapchain.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_descriptors.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_uniforms.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_shader.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_mesh.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_instancing.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_texture.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_framebuffer.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_pbr.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_shadows.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_ibl.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_ssao.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_ssr.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_taa.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_postprocess.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_deferred.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_backend.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_ui.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_particles.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_terrain.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_dof.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_motion_blur.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_debug_draw.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_graph_executor.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_graph_passes.jl"))
include(joinpath(_VULKAN_SRC, "vulkan_capture.jl"))

# Constructor shim: overload the abstract `OpenReality.VulkanBackend` stub
# (which would otherwise raise) so user code calling `VulkanBackend()`
# constructs the concrete `VulkanBackendImpl` when this extension is loaded.
OpenReality.VulkanBackend() = VulkanBackendImpl()

end # module OpenRealityVulkanExt
