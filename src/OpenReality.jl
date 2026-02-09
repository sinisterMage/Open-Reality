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
const Mat4f = SMatrix{4, 4, Float32, 16}
const Mat3f = SMatrix{3, 3, Float32, 9}

# Re-export commonly used types from dependencies
export Point3f, Vec3f, Vec2f, Mat4f, Mat3f
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
include("components/rigidbody.jl")

# Windowing (before backend — backend needs Window and InputState)
include("windowing/glfw.jl")
include("windowing/input.jl")

# Systems (after windowing — uses GLFW key constants)
include("systems/player_controller.jl")
include("systems/physics.jl")

# Rendering utilities (before backend — backend needs these)
include("rendering/shader.jl")
include("rendering/gpu_resources.jl")
include("rendering/texture.jl")
include("rendering/camera_utils.jl")

# Backend
include("backend/abstract.jl")
include("backend/opengl.jl")

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
export collect_components, entities_with_component, component_count, iterate_components
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
export PointLightComponent, DirectionalLightComponent
export cube_mesh, sphere_mesh, plane_mesh
export PlayerComponent, create_player
export PlayerController, find_player_and_camera, update_player!

# Export Physics Components
export ColliderComponent, ColliderShape, AABBShape, SphereShape
export collider_from_mesh, sphere_collider_from_mesh
export RigidBodyComponent, BodyType, BODY_STATIC, BODY_KINEMATIC, BODY_DYNAMIC
export PhysicsConfig, update_physics!

# Export Backend
export AbstractBackend, initialize!, shutdown!, render_frame!
export OpenGLBackend

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
export get_world_transform, get_local_transform
export perspective_matrix, look_at_matrix
export Mat4d

# Export Camera Utils
export find_active_camera, get_view_matrix, get_projection_matrix

# Export Model Loading
export load_model, load_obj, load_gltf

"""
    render(scene::Scene; width=1280, height=720, title="OpenReality")

Start the PBR render loop for the given scene.
Opens a window and renders until closed.
"""
function render(scene::Scene;
                width::Int = 1280, height::Int = 720,
                title::String = "OpenReality")
    run_render_loop!(scene, width=width, height=height, title=title)
end

export render

end  # module OpenReality
