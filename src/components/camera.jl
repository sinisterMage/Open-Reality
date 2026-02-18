# Camera component

"""
    CameraComponent <: Component

Represents a camera for viewing the scene.
"""
struct CameraComponent <: Component
    fov::Float32          # Field of view in degrees
    near::Float32         # Near clipping plane
    far::Float32          # Far clipping plane
    aspect::Float32       # Aspect ratio
    active::Bool          # Whether this camera is the active one

    CameraComponent(;
        fov::Float32 = 60.0f0,
        near::Float32 = 0.1f0,
        far::Float32 = 1000.0f0,
        aspect::Float32 = 16.0f0 / 9.0f0,
        active::Bool = true
    ) = new(fov, near, far, aspect, active)
end
