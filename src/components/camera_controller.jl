# Camera controller components

"""
    ThirdPersonCamera <: Component

Third-person camera that follows a target entity with collision avoidance.
"""
mutable struct ThirdPersonCamera <: Component
    target_entity::EntityID
    distance::Float32
    yaw::Float64
    pitch::Float64
    min_pitch::Float64
    max_pitch::Float64
    sensitivity::Float32
    collision_enabled::Bool
    smoothing::Float32
    offset::Vec3f
end

"""
    OrbitCamera <: Component

Orbit camera that revolves around a fixed target position.
Right mouse button rotates, scroll wheel zooms.
"""
mutable struct OrbitCamera <: Component
    target_position::Vec3d
    distance::Float32
    yaw::Float64
    pitch::Float64
    zoom_speed::Float32
    pan_speed::Float32
    smoothing::Float32
end

"""
    CinematicCamera <: Component

Cinematic camera with spline path playback and free-fly mode.
When `playing` is true, follows the path; otherwise uses WASD + mouse free-fly.
"""
mutable struct CinematicCamera <: Component
    move_speed::Float32
    sensitivity::Float32
    path::Vector{Vec3d}
    path_times::Vector{Float32}
    current_time::Float32
    playing::Bool
    looping::Bool
end
