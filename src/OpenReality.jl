module OpenReality

# Dependencies
using Observables
using GeometryBasics
using ColorTypes
using StaticArrays
using Quaternions
using LinearAlgebra
using ModernGL
import GLFW
using FileIO
using Base64
import GLTF as GLTFLib

# Type aliases for common 3D types
# Point3f and Vec3f come from GeometryBasics
const Point3f = Point{3, Float32}
const Vec3f = Vec{3, Float32}
const Vec2f = Vec{2, Float32}
const Vec4f = Vec{4, Float32}
const Mat4f = SMatrix{4, 4, Float32, 16}
const Mat3f = SMatrix{3, 3, Float32, 9}

# Re-export commonly used types from dependencies
export Point3f, Vec3f, Vec2f, Vec4f, Mat4f, Mat3f
export RGB

# Re-export Quaternion from Quaternions.jl
export Quaternion

# Core modules
include("ecs.jl")
include("state.jl")
include("scene.jl")

# Math utilities
include("math/transforms.jl")

# Components
include("components/transform.jl")
include("components/mesh.jl")
include("components/material.jl")
include("components/camera.jl")
include("components/lights.jl")
include("components/primitives.jl")
include("components/player.jl")
include("components/collider.jl")

# Physics types + shapes (before rigidbody — rigidbody uses CCDMode; shapes extends ColliderShape)
include("physics/types.jl")
include("physics/shapes.jl")

include("components/rigidbody.jl")
include("components/animation.jl")
include("components/audio.jl")
include("components/skeleton.jl")
include("components/particle_system.jl")

# Physics engine (after rigidbody — solver/world use RigidBodyComponent)
include("physics/inertia.jl")
include("physics/broadphase.jl")
include("physics/narrowphase.jl")
include("physics/gjk_epa.jl")
include("physics/contact.jl")
include("physics/solver.jl")
include("physics/constraints.jl")
include("physics/triggers.jl")
include("physics/raycast.jl")
include("physics/ccd.jl")
include("physics/islands.jl")
include("physics/world.jl")

# Windowing (before backend — backend needs Window and InputState)
include("windowing/glfw.jl")
include("windowing/input.jl")

# Audio backend (after ECS — uses EntityID)
include("audio/openal_backend.jl")

# Systems (after windowing — uses GLFW key constants)
include("systems/player_controller.jl")
include("systems/physics.jl")
include("systems/animation.jl")
include("systems/skinning.jl")
include("systems/audio.jl")
include("systems/particles.jl")

# UI system (after components and ECS — uses types)
include("ui/types.jl")
include("ui/font.jl")
include("ui/widgets.jl")

# GPU Abstraction Layer (abstract types that concrete backends implement)
include("backend/gpu_types.jl")

# Rendering: backend-agnostic math, configs, and utilities
include("rendering/shader.jl")            # placeholder — concrete type in backend/opengl/
include("rendering/gpu_resources.jl")      # placeholder — concrete type in backend/opengl/
include("rendering/texture.jl")            # placeholder — concrete type in backend/opengl/
include("rendering/framebuffer.jl")        # placeholder — concrete type in backend/opengl/
include("rendering/gbuffer.jl")            # placeholder — concrete type in backend/opengl/
include("rendering/shader_variants.jl")    # ShaderLibrary{S} (parametric, backend-agnostic)
include("rendering/ibl.jl")                # placeholder — concrete type in backend/opengl/
include("rendering/ssr.jl")                # placeholder — concrete type in backend/opengl/
include("rendering/ssao.jl")               # pure math (generate_ssao_kernel, lerp)
include("rendering/taa.jl")                # pure math (HALTON_SAMPLES, jitter)
include("rendering/deferred.jl")           # placeholder — concrete type in backend/opengl/
include("rendering/post_processing.jl")    # ToneMappingMode, PostProcessConfig
include("rendering/shadow_map.jl")         # pure math (compute_light_space_matrix)
include("rendering/csm.jl")               # pure math (cascade computation)
include("rendering/camera_utils.jl")
include("rendering/frustum_culling.jl")

# Abstract backend interface
include("backend/abstract.jl")

# OpenGL backend implementation (concrete types + GL calls)
include("backend/opengl/opengl_shader.jl")       # ShaderProgram
include("backend/opengl/opengl_mesh.jl")          # GPUMesh, GPUResourceCache
include("backend/opengl/opengl_texture.jl")       # GPUTexture, TextureCache
include("backend/opengl/opengl_framebuffer.jl")   # Framebuffer, GBuffer
include("backend/opengl/opengl_shadows.jl")       # ShadowMap, CascadedShadowMap
include("backend/opengl/opengl_ibl.jl")           # IBLEnvironment
include("backend/opengl/opengl_ssao.jl")          # SSAOPass
include("backend/opengl/opengl_ssr.jl")           # SSRPass
include("backend/opengl/opengl_taa.jl")           # TAAPass
include("backend/opengl/opengl_pbr.jl")           # PBR shaders, upload_lights!
include("backend/opengl/opengl_postprocess.jl")   # PostProcessPipeline
include("backend/opengl/opengl_deferred.jl")      # DeferredPipeline
include("backend/opengl/opengl_ui.jl")            # UIRenderer, render_ui!
include("backend/opengl/opengl_particles.jl")    # Particle renderer
include("backend/opengl.jl")                      # OpenGLBackend, render_frame!

# Shared rendering orchestration (after backend — uses ECS + frustum culling)
include("rendering/frame_preparation.jl")

# Metal backend implementation (macOS only, after frame_preparation — uses FrameLightData)
if Sys.isapple()
    include("backend/metal/metal_types.jl")
    include("backend/metal/metal_ffi.jl")
    include("backend/metal/metal_uniforms.jl")
    include("backend/metal/metal_mesh.jl")
    include("backend/metal/metal_texture.jl")
    include("backend/metal/metal_shader.jl")
    include("backend/metal/metal_pbr.jl")
    include("backend/metal/metal_framebuffer.jl")
    include("backend/metal/metal_shadows.jl")
    include("backend/metal/metal_ibl.jl")
    include("backend/metal/metal_ssao.jl")
    include("backend/metal/metal_ssr.jl")
    include("backend/metal/metal_taa.jl")
    include("backend/metal/metal_postprocess.jl")
    include("backend/metal/metal_deferred.jl")
    include("backend/metal/metal_backend.jl")
end

# Vulkan backend implementation (Linux/Windows, after frame_preparation — uses FrameLightData)
if !Sys.isapple()
    include("backend/vulkan/vulkan_types.jl")
    include("backend/vulkan/vulkan_memory.jl")
    include("backend/vulkan/vulkan_device.jl")
    include("backend/vulkan/vulkan_swapchain.jl")
    include("backend/vulkan/vulkan_descriptors.jl")
    include("backend/vulkan/vulkan_uniforms.jl")
    include("backend/vulkan/vulkan_shader.jl")
    include("backend/vulkan/vulkan_mesh.jl")
    include("backend/vulkan/vulkan_texture.jl")
    include("backend/vulkan/vulkan_framebuffer.jl")
    include("backend/vulkan/vulkan_pbr.jl")
    include("backend/vulkan/vulkan_shadows.jl")
    include("backend/vulkan/vulkan_ibl.jl")
    include("backend/vulkan/vulkan_ssao.jl")
    include("backend/vulkan/vulkan_ssr.jl")
    include("backend/vulkan/vulkan_taa.jl")
    include("backend/vulkan/vulkan_postprocess.jl")
    include("backend/vulkan/vulkan_deferred.jl")
    include("backend/vulkan/vulkan_backend.jl")
end

# Rendering pipeline (after backend — uses backend types)
include("rendering/pipeline.jl")
include("rendering/systems.jl")
include("rendering/pbr_pipeline.jl")

# Model loading (after components and rendering — uses MeshComponent, MaterialComponent, TextureRef)
include("loading/obj_loader.jl")
include("loading/gltf_loader.jl")
include("loading/loader.jl")

# Export ECS
export EntityID, World, create_entity!, create_entity_id
export Component, ComponentStore
export add_component!, get_component, has_component, remove_component!
export collect_components, entities_with_component, first_entity_with_component, component_count, iterate_components
export register_component_type, reset_entity_counter!, reset_component_stores!

# Export State
export State, state

# Export Scene and Scene Graph
export Scene, scene, entity, EntityDef
export add_entity, remove_entity
export get_children, get_parent, has_entity, is_root
export traverse_scene, traverse_entity
export traverse_scene_with_depth, traverse_entity_with_depth
export get_all_descendants, get_ancestors, entity_count

# Export Components
export TransformComponent, transform, with_parent
export Vec3d, Quaterniond
export MeshComponent
export MaterialComponent, TextureRef
export CameraComponent
export PointLightComponent, DirectionalLightComponent, IBLComponent
export cube_mesh, sphere_mesh, plane_mesh
export PlayerComponent, create_player
export PlayerController, find_player_and_camera, update_player!

# Export Physics Components
export ColliderComponent, ColliderShape, AABBShape, SphereShape, CapsuleShape, CapsuleAxis
export OBBShape, ConvexHullShape, CompoundShape, CompoundChild
export CAPSULE_X, CAPSULE_Y, CAPSULE_Z
export collider_from_mesh, sphere_collider_from_mesh
export RigidBodyComponent, BodyType, BODY_STATIC, BODY_KINEMATIC, BODY_DYNAMIC
export CCDMode, CCD_NONE, CCD_SWEPT
export PhysicsConfig, update_physics!

# Export Physics Engine
export PhysicsWorldConfig, PhysicsWorld, get_physics_world, reset_physics_world!
export AABB3D, ContactManifold, ContactPoint, CollisionPair, RaycastHit
export SpatialHashGrid
export initialize_rigidbody_inertia!
export raycast, raycast_all
export sweep_test, apply_ccd!
export SimulationIsland, build_islands, update_islands!

# Export Joints/Constraints
export JointConstraint, JointComponent
export BallSocketJoint, DistanceJoint, HingeJoint, FixedJoint, SliderJoint

# Export Triggers
export TriggerComponent

# Export Animation
export InterpolationMode, INTERP_STEP, INTERP_LINEAR, INTERP_CUBICSPLINE
export AnimationChannel, AnimationClip, AnimationComponent
export update_animations!

# Export Skeletal Animation
export BoneComponent, SkinnedMeshComponent, BoneIndices4
export update_skinned_meshes!, MAX_BONES

# Export Audio
export AudioListenerComponent, AudioSourceComponent
export AudioConfig, update_audio!
export init_audio!, shutdown_audio!, reset_audio_state!
export load_wav, get_or_load_buffer!

# Export UI
export UIContext, UIDrawCommand, FontAtlas, GlyphInfo
export orthographic_matrix, clear_ui!, measure_text
export ui_rect, ui_text, ui_button, ui_progress_bar, ui_image
export init_ui_renderer!, shutdown_ui_renderer!, render_ui!, reset_ui_renderer!
export get_or_create_font_atlas!, reset_font_cache!

# Export Particles
export ParticleSystemComponent
export Particle, ParticlePool, PARTICLE_POOLS
export update_particles!, reset_particle_pools!
export init_particle_renderer!, shutdown_particle_renderer!, render_particles!, reset_particle_renderer!

# Export Shadow Mapping
export ShadowMap, create_shadow_map!, destroy_shadow_map!, compute_light_space_matrix

# Export Cascaded Shadow Mapping
export CascadedShadowMap, create_csm!, destroy_csm!, compute_cascade_splits
export compute_cascade_light_matrix, render_csm_cascade!

# Export Frustum Culling
export Frustum, FrustumPlane, BoundingSphere
export extract_frustum, bounding_sphere_from_mesh, is_sphere_in_frustum

# Export Post-Processing
export Framebuffer, PostProcessConfig, PostProcessPipeline
export ToneMappingMode, TONEMAP_REINHARD, TONEMAP_ACES, TONEMAP_UNCHARTED2

# Export Deferred Rendering
export GBuffer, create_gbuffer!, destroy_gbuffer!, resize_gbuffer!
export bind_gbuffer_for_write!, bind_gbuffer_textures_for_read!, unbind_framebuffer!
export ShaderFeature, ShaderVariantKey, ShaderLibrary
export FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_METALLIC_ROUGHNESS_MAP
export FEATURE_AO_MAP, FEATURE_EMISSIVE_MAP, FEATURE_ALPHA_CUTOFF
export FEATURE_CLEARCOAT, FEATURE_PARALLAX_MAPPING, FEATURE_SUBSURFACE
export get_or_compile_variant!, determine_shader_variant, destroy_shader_library!
export DeferredPipeline, create_deferred_pipeline!, destroy_deferred_pipeline!, resize_deferred_pipeline!

# Export SSR
export SSRPass, create_ssr_pass!, destroy_ssr_pass!, resize_ssr_pass!, render_ssr!

# Export SSAO
export SSAOPass, create_ssao_pass!, destroy_ssao_pass!, resize_ssao_pass!, render_ssao!, apply_ssao_to_lighting!

# Export TAA
export TAAPass, create_taa_pass!, destroy_taa_pass!, resize_taa_pass!, render_taa!, apply_taa_jitter!, get_halton_jitter

# Export IBL
export IBLEnvironment, create_ibl_environment!, destroy_ibl_environment!

# Export GPU Abstraction Types
export AbstractShaderProgram, AbstractGPUMesh, AbstractGPUTexture
export AbstractFramebuffer, AbstractGBuffer
export AbstractShadowMap, AbstractCascadedShadowMap
export AbstractIBLEnvironment
export AbstractSSRPass, AbstractSSAOPass, AbstractTAAPass
export AbstractPostProcessPipeline, AbstractDeferredPipeline
export AbstractGPUResourceCache, AbstractTextureCache
export get_index_count, get_width, get_height

# Export Backend
export AbstractBackend, initialize!, shutdown!, render_frame!
export OpenGLBackend
if Sys.isapple()
    export MetalBackend
end
if !Sys.isapple()
    export VulkanBackend
end

# Export Abstract Backend Methods
export backend_create_shader, backend_destroy_shader!, backend_use_shader!, backend_set_uniform!
export backend_upload_mesh!, backend_draw_mesh!, backend_destroy_mesh!
export backend_upload_texture!, backend_bind_texture!, backend_destroy_texture!
export backend_create_framebuffer!, backend_bind_framebuffer!, backend_unbind_framebuffer!, backend_destroy_framebuffer!
export backend_create_gbuffer!, backend_create_shadow_map!, backend_create_csm!
export backend_create_ibl_environment!
export backend_create_ssr_pass!, backend_create_ssao_pass!, backend_create_taa_pass!
export backend_create_post_process!
export backend_set_viewport!, backend_clear!, backend_set_depth_test!, backend_set_blend!
export backend_set_cull_face!, backend_swap_buffers!, backend_draw_fullscreen_quad!, backend_blit_framebuffer!
export backend_should_close, backend_poll_events!, backend_get_time
export backend_capture_cursor!, backend_release_cursor!, backend_is_key_pressed, backend_get_input

# Export Frame Preparation
export FrameLightData, EntityRenderData, TransparentEntityData, FrameData
export collect_lights, prepare_frame

# Export Rendering
export RenderPipeline, execute!
export RenderSystem, update!
export ShaderProgram, create_shader_program, destroy_shader_program!
export GPUMesh, GPUResourceCache, upload_mesh!, get_or_upload_mesh!, destroy_all!
export GPUTexture, TextureCache, load_texture
export run_render_loop!

# Export Windowing
export Window, create_window!, destroy_window!, should_close, poll_events!, swap_buffers!
export setup_resize_callback!, capture_cursor!, release_cursor!, get_time
export InputState, is_key_pressed, get_mouse_position, setup_input_callbacks!

# Export Math
export translation_matrix, scale_matrix, rotation_x, rotation_y, rotation_z
export rotation_matrix, compose_transform
export get_world_transform, get_local_transform, clear_world_transform_cache!
export perspective_matrix, look_at_matrix
export Mat4d

# Export Camera Utils
export find_active_camera, get_view_matrix, get_projection_matrix

# Export Model Loading
export load_model, load_obj, load_gltf

"""
    render(scene::Scene; backend=OpenGLBackend(), width=1280, height=720, title="OpenReality", post_process=nothing, ui=nothing)

Start the PBR render loop for the given scene.
Opens a window and renders until closed.

Pass `backend=MetalBackend()` on macOS to use the Metal renderer.
Pass `backend=VulkanBackend()` on Linux/Windows to use the Vulkan renderer.

Pass a `ui` callback to render immediate-mode UI each frame:
```julia
render(scene, ui = ctx -> begin
    ui_text(ctx, "Hello!", x=10, y=10, size=32)
end)
```
"""
function render(scene::Scene;
                backend::AbstractBackend = OpenGLBackend(),
                width::Int = 1280, height::Int = 720,
                title::String = "OpenReality",
                post_process::Union{PostProcessConfig, Nothing} = nothing,
                ui::Union{Function, Nothing} = nothing)
    run_render_loop!(scene, backend=backend, width=width, height=height, title=title, post_process=post_process, ui=ui)
end

export render

end  # module OpenReality
