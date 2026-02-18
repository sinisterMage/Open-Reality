# Physics NaN/Inf guards — prevent degenerate values from corrupting the simulation

"""
    is_valid_vec3(v::Vec3d) -> Bool

Check that all components of a Vec3d are finite (not NaN or Inf).
"""
@inline function is_valid_vec3(v::Vec3d)::Bool
    return isfinite(v[1]) && isfinite(v[2]) && isfinite(v[3])
end

"""
    clamp_velocity!(rb::RigidBodyComponent; max_linear=500.0, max_angular=100.0)

Clamp rigid body velocities to sane bounds and zero out any NaN/Inf values.
Prevents simulation explosions from extreme forces or degenerate collisions.
"""
function clamp_velocity!(rb; max_linear::Float64=500.0, max_angular::Float64=100.0)
    # Linear velocity
    if !is_valid_vec3(rb.velocity)
        rb.velocity = Vec3d(0, 0, 0)
    else
        speed = vec3d_length(rb.velocity)
        if speed > max_linear
            rb.velocity = rb.velocity * (max_linear / speed)
        end
    end

    # Angular velocity
    if !is_valid_vec3(rb.angular_velocity)
        rb.angular_velocity = Vec3d(0, 0, 0)
    else
        ang_speed = vec3d_length(rb.angular_velocity)
        if ang_speed > max_angular
            rb.angular_velocity = rb.angular_velocity * (max_angular / ang_speed)
        end
    end
end

"""
    sanitize_inertia(inv_inertia::Mat3d) -> Mat3d

Replace any NaN/Inf entries in an inverse inertia tensor with zero.
A zeroed inverse inertia makes the body behave as infinite mass on that axis.
"""
function sanitize_inertia(inv_inertia::Mat3d)::Mat3d
    clean = ntuple(9) do i
        v = inv_inertia[i]
        isfinite(v) ? v : 0.0
    end
    return Mat3d(clean...)
end
