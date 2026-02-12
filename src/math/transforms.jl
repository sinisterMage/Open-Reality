# Transform utilities
# Matrix composition and transformation functions

# Type aliases for double precision matrices
const Mat4d = SMatrix{4, 4, Float64, 16}

# =============================================================================
# Float32 Transform Functions (Original API)
# =============================================================================

"""
    translation_matrix(v::Vec3f) -> Mat4f

Create a translation matrix from a vector (Float32 version).
"""
function translation_matrix(v::Vec3f)
    return Mat4f(
        1,    0,    0,    0,
        0,    1,    0,    0,
        0,    0,    1,    0,
        v[1], v[2], v[3], 1
    )
end

"""
    scale_matrix(s::Vec3f) -> Mat4f

Create a scale matrix from a vector (Float32 version).
"""
function scale_matrix(s::Vec3f)
    return Mat4f(
        s[1], 0, 0, 0,
        0, s[2], 0, 0,
        0, 0, s[3], 0,
        0, 0, 0, 1
    )
end

"""
    rotation_x(angle::Float32) -> Mat4f

Create a rotation matrix around the X axis.
"""
function rotation_x(angle::Float32)
    c = cos(angle)
    s = sin(angle)
    return Mat4f(
        1, 0, 0, 0,
        0, c, s, 0,
        0, -s, c, 0,
        0, 0, 0, 1
    )
end

"""
    rotation_y(angle::Float32) -> Mat4f

Create a rotation matrix around the Y axis.
"""
function rotation_y(angle::Float32)
    c = cos(angle)
    s = sin(angle)
    return Mat4f(
        c, 0, -s, 0,
        0, 1, 0, 0,
        s, 0, c, 0,
        0, 0, 0, 1
    )
end

"""
    rotation_z(angle::Float32) -> Mat4f

Create a rotation matrix around the Z axis.
"""
function rotation_z(angle::Float32)
    c = cos(angle)
    s = sin(angle)
    return Mat4f(
        c, s, 0, 0,
        -s, c, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    )
end

# =============================================================================
# Float64 Transform Functions (For hierarchical transforms)
# =============================================================================

"""
    translation_matrix(v::Vec{3, Float64}) -> Mat4d

Create a translation matrix from a vector (Float64 version).
"""
function translation_matrix(v::Vec{3, Float64})
    return Mat4d(
        1,    0,    0,    0,
        0,    1,    0,    0,
        0,    0,    1,    0,
        v[1], v[2], v[3], 1
    )
end

"""
    scale_matrix(s::Vec{3, Float64}) -> Mat4d

Create a scale matrix from a vector (Float64 version).
"""
function scale_matrix(s::Vec{3, Float64})
    return Mat4d(
        s[1], 0, 0, 0,
        0, s[2], 0, 0,
        0, 0, s[3], 0,
        0, 0, 0, 1
    )
end

"""
    rotation_matrix(q::Quaternion{Float64}) -> Mat4d

Create a rotation matrix from a quaternion.
Uses the standard quaternion to rotation matrix conversion.

The quaternion is expected in (w, x, y, z) format where w is the scalar component.
Uses the Quaternions.jl convention with q.s = w and q.v1, q.v2, q.v3 = x, y, z.
"""
function rotation_matrix(q::Quaternion{Float64})
    # Extract quaternion components using Quaternions.jl accessors
    # q.s = w (scalar/real part)
    # q.v1, q.v2, q.v3 = x, y, z (imaginary/vector part)
    w, x, y, z = q.s, q.v1, q.v2, q.v3

    # Normalize quaternion (for safety)
    n = sqrt(x*x + y*y + z*z + w*w)
    if n > 0
        x, y, z, w = x/n, y/n, z/n, w/n
    end

    # Precompute common terms
    xx = x * x
    yy = y * y
    zz = z * z
    xy = x * y
    xz = x * z
    yz = y * z
    wx = w * x
    wy = w * y
    wz = w * z

    # Construct rotation matrix (column-major for OpenGL/StaticArrays)
    return Mat4d(
        1 - 2*(yy + zz),     2*(xy + wz),     2*(xz - wy), 0,
            2*(xy - wz), 1 - 2*(xx + zz),     2*(yz + wx), 0,
            2*(xz + wy),     2*(yz - wx), 1 - 2*(xx + yy), 0,
                      0,               0,               0, 1
    )
end

"""
    compose_transform(position::Vec{3, Float64}, rotation::Quaternion{Float64}, scale::Vec{3, Float64}) -> Mat4d

Compose a 4x4 transformation matrix from position, rotation (quaternion), and scale.
The composition order is: Translation * Rotation * Scale (T * R * S).

This means points are first scaled, then rotated, then translated.
Fused into a single matrix construction to avoid 3 temporary matrices + 2 multiplications.
"""
function compose_transform(position::Vec{3, Float64}, rotation::Quaternion{Float64}, scale::Vec{3, Float64})
    # Extract and normalize quaternion
    w, x, y, z = rotation.s, rotation.v1, rotation.v2, rotation.v3
    n = sqrt(x*x + y*y + z*z + w*w)
    if n > 0
        inv_n = 1.0 / n
        x *= inv_n; y *= inv_n; z *= inv_n; w *= inv_n
    end

    # Precompute rotation terms
    xx = 2.0 * x * x; yy = 2.0 * y * y; zz = 2.0 * z * z
    xy = 2.0 * x * y; xz = 2.0 * x * z; yz = 2.0 * y * z
    wx = 2.0 * w * x; wy = 2.0 * w * y; wz = 2.0 * w * z

    sx, sy, sz = scale[1], scale[2], scale[3]
    tx, ty, tz = position[1], position[2], position[3]

    # Fused T * R * S — each column of R is scaled by the corresponding scale factor
    return Mat4d(
        (1.0 - yy - zz) * sx, (xy + wz) * sx,       (xz - wy) * sx,       0.0,
        (xy - wz) * sy,       (1.0 - xx - zz) * sy,  (yz + wx) * sy,       0.0,
        (xz + wy) * sz,       (yz - wx) * sz,        (1.0 - xx - yy) * sz, 0.0,
        tx,                   ty,                    tz,                   1.0
    )
end

# =============================================================================
# World Transform Cache (per-frame)
# =============================================================================

"""
Per-frame cache for world transform matrices. Call `clear_world_transform_cache!()`
at the start of each frame. Avoids recomputing the same transform when
`get_world_transform` is called multiple times for the same entity (shadow passes,
entity classification, light upload, particles, etc.).
"""
const _WORLD_TRANSFORM_CACHE = Dict{EntityID, Mat4d}()

"""
    clear_world_transform_cache!()

Clear the per-frame world transform cache. Call once at the start of each frame.
"""
function clear_world_transform_cache!()
    empty!(_WORLD_TRANSFORM_CACHE)
end

# Register cache clearing with ECS reset so tests don't see stale transforms
push!(_RESET_HOOKS, clear_world_transform_cache!)

# =============================================================================
# World Transform Calculation
# =============================================================================

"""
    get_world_transform(entity_id::EntityID) -> Mat4d

Calculate the world transformation matrix for an entity, taking into account
the full parent hierarchy. Results are cached per frame.

Returns identity matrix if the entity has no TransformComponent.
Child transforms are multiplied by parent transforms, so children move with their parents.
"""
function get_world_transform(entity_id::EntityID)
    cached = get(_WORLD_TRANSFORM_CACHE, entity_id, nothing)
    cached !== nothing && return cached

    transform_comp = get_component(entity_id, TransformComponent)

    if transform_comp === nothing
        result = Mat4d(I)
        _WORLD_TRANSFORM_CACHE[entity_id] = result
        return result
    end

    # Calculate local transform matrix from Observable values
    local_matrix = compose_transform(
        transform_comp.position[],
        transform_comp.rotation[],
        transform_comp.scale[]
    )

    # If entity has a parent, multiply by parent's world transform
    result = if transform_comp.parent !== nothing
        parent_world = get_world_transform(transform_comp.parent)
        parent_world * local_matrix
    else
        local_matrix
    end

    _WORLD_TRANSFORM_CACHE[entity_id] = result
    return result
end

"""
    get_local_transform(entity_id::EntityID) -> Mat4d

Calculate the local transformation matrix for an entity (without parent transforms).

Returns identity matrix if the entity has no TransformComponent.
"""
function get_local_transform(entity_id::EntityID)
    transform_comp = get_component(entity_id, TransformComponent)

    if transform_comp === nothing
        return Mat4d(I)
    end

    return compose_transform(
        transform_comp.position[],
        transform_comp.rotation[],
        transform_comp.scale[]
    )
end

# =============================================================================
# Projection and View Matrices
# =============================================================================

"""
    perspective_matrix(fov_deg::Float32, aspect::Float32, near::Float32, far::Float32) -> Mat4f

Create an OpenGL perspective projection matrix.
`fov_deg` is the vertical field-of-view in degrees.
"""
function perspective_matrix(fov_deg::Float32, aspect::Float32, near::Float32, far::Float32)
    fov_rad = fov_deg * Float32(pi) / 180.0f0
    t = tan(fov_rad / 2.0f0)
    Mat4f(
        1/(aspect*t), 0,     0,                        0,
        0,            1/t,   0,                        0,
        0,            0,     -(far+near)/(far-near),  -1,
        0,            0,     -2*far*near/(far-near),   0
    )
end

"""
    look_at_matrix(eye::Vec3f, target::Vec3f, up::Vec3f) -> Mat4f

Create a view matrix looking from `eye` toward `target` with the given `up` direction.
"""
function look_at_matrix(eye::Vec3f, target::Vec3f, up::Vec3f)
    f = normalize(target - eye)
    s = normalize(cross(f, up))
    u = cross(s, f)
    Mat4f(
         s[1],          u[1],         -f[1],         0,
         s[2],          u[2],         -f[2],         0,
         s[3],          u[3],         -f[3],         0,
        -dot(s, eye),  -dot(u, eye),   dot(f, eye),  1
    )
end
