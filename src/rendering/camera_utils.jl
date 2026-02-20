# Camera utility functions
# Bridges CameraComponent + TransformComponent -> GPU-ready view/projection matrices

"""
    find_active_camera() -> Union{EntityID, Nothing}

Find the first entity with a CameraComponent.
"""
function find_active_camera()
    active_eid = nothing
    iterate_components(CameraComponent) do eid, cam
        if cam.active
            active_eid = eid
            return # This return is for the closure, not find_active_camera
        end
    end
    return active_eid
end

"""
    get_view_matrix(camera_entity::EntityID) -> Mat4f

Compute the view matrix from a camera entity's TransformComponent.
Converts the Float64 world transform to Float32 for GPU upload.
"""
function get_view_matrix(camera_entity::EntityID)
    world = get_world_transform(camera_entity)
    world_f32 = Mat4f(world)
    return inv(world_f32)
end

"""
    get_projection_matrix(camera_entity::EntityID) -> Mat4f

Compute the projection matrix from a camera entity's CameraComponent.
Returns identity if no CameraComponent is found.
"""
function get_projection_matrix(camera_entity::EntityID)
    cam = get_component(camera_entity, CameraComponent)
    if cam === nothing
        return Mat4f(I)
    end
    return perspective_matrix(cam.fov, cam.aspect, cam.near, cam.far)
end
