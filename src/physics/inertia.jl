# Inertia tensor computation for physics shapes

const Mat3d = SMatrix{3, 3, Float64, 9}
const ZERO_MAT3D = Mat3d(0,0,0, 0,0,0, 0,0,0)

"""
    compute_inverse_inertia(shape::ColliderShape, mass::Float64, scale::Vec3d) -> Mat3d

Compute the inverse inertia tensor in local space for a given shape and mass.
Returns the zero matrix for static/kinematic bodies (infinite mass).
"""
function compute_inverse_inertia(shape::AABBShape, mass::Float64, scale::Vec3d)
    if mass <= 0.0
        return ZERO_MAT3D
    end

    # Box inertia: I_xx = 1/12 * m * (h² + d²), etc.
    w = 2.0 * Float64(shape.half_extents[1]) * scale[1]
    h = 2.0 * Float64(shape.half_extents[2]) * scale[2]
    d = 2.0 * Float64(shape.half_extents[3]) * scale[3]
    m12 = mass / 12.0

    ix = m12 * (h*h + d*d)
    iy = m12 * (w*w + d*d)
    iz = m12 * (w*w + h*h)

    return Mat3d(
        1.0/ix, 0, 0,
        0, 1.0/iy, 0,
        0, 0, 1.0/iz
    )
end

function compute_inverse_inertia(shape::SphereShape, mass::Float64, scale::Vec3d)
    if mass <= 0.0
        return ZERO_MAT3D
    end

    # Solid sphere: I = 2/5 * m * r²
    r = Float64(shape.radius) * max(scale[1], scale[2], scale[3])
    inertia = 0.4 * mass * r * r
    inv_i = 1.0 / inertia

    return Mat3d(
        inv_i, 0, 0,
        0, inv_i, 0,
        0, 0, inv_i
    )
end

function compute_inverse_inertia(shape::CapsuleShape, mass::Float64, scale::Vec3d)
    if mass <= 0.0
        return ZERO_MAT3D
    end

    max_scale = max(scale[1], scale[2], scale[3])
    r = Float64(shape.radius) * max_scale
    hh = Float64(shape.half_height) * max_scale
    h = 2.0 * hh  # cylinder height

    # Capsule = cylinder + 2 hemispheres (= 1 sphere)
    # Volume ratios for mass distribution
    v_cyl = pi * r * r * h
    v_sphere = (4.0 / 3.0) * pi * r * r * r
    v_total = v_cyl + v_sphere
    m_cyl = mass * v_cyl / v_total
    m_sph = mass * v_sphere / v_total

    # Cylinder inertia (aligned along Y by default)
    # I_xx = I_zz = 1/12 * m * (3r² + h²)
    # I_yy = 1/2 * m * r²
    cyl_ixx = m_cyl * (3.0 * r * r + h * h) / 12.0
    cyl_iyy = m_cyl * r * r / 2.0

    # Sphere inertia (2/5 * m * r²) + parallel axis theorem for offset along Y
    sph_i_center = 0.4 * m_sph * r * r
    # Each hemisphere center is at ±(hh + 3r/8) from capsule center
    sph_offset = hh + 3.0 * r / 8.0
    sph_ixx = sph_i_center + m_sph * sph_offset * sph_offset  # parallel axis
    sph_iyy = sph_i_center  # no offset along Y axis

    # Total
    ixx = cyl_ixx + sph_ixx
    iyy = cyl_iyy + sph_iyy
    izz = ixx  # symmetric about Y

    # Rotate inertia to match capsule axis
    if shape.axis == CAPSULE_Y
        return Mat3d(1.0/ixx, 0, 0, 0, 1.0/iyy, 0, 0, 0, 1.0/izz)
    elseif shape.axis == CAPSULE_X
        # Swap X and Y
        return Mat3d(1.0/iyy, 0, 0, 0, 1.0/ixx, 0, 0, 0, 1.0/izz)
    else  # CAPSULE_Z
        # Swap Z and Y
        return Mat3d(1.0/ixx, 0, 0, 0, 1.0/izz, 0, 0, 0, 1.0/iyy)
    end
end

function compute_inverse_inertia(shape::OBBShape, mass::Float64, scale::Vec3d)
    # OBB = box, same inertia formula as AABB
    if mass <= 0.0
        return ZERO_MAT3D
    end
    w = 2.0 * Float64(shape.half_extents[1]) * scale[1]
    h = 2.0 * Float64(shape.half_extents[2]) * scale[2]
    d = 2.0 * Float64(shape.half_extents[3]) * scale[3]
    m12 = mass / 12.0
    ix = m12 * (h*h + d*d)
    iy = m12 * (w*w + d*d)
    iz = m12 * (w*w + h*h)
    return Mat3d(1.0/ix, 0, 0, 0, 1.0/iy, 0, 0, 0, 1.0/iz)
end

function compute_inverse_inertia(shape::ConvexHullShape, mass::Float64, scale::Vec3d)
    # Approximate: use bounding box inertia
    if mass <= 0.0 || isempty(shape.vertices)
        return ZERO_MAT3D
    end
    min_v = Vec3d(Inf, Inf, Inf)
    max_v = Vec3d(-Inf, -Inf, -Inf)
    for v in shape.vertices
        sv = Vec3d(Float64(v[1]) * scale[1], Float64(v[2]) * scale[2], Float64(v[3]) * scale[3])
        min_v = Vec3d(min(min_v[1], sv[1]), min(min_v[2], sv[2]), min(min_v[3], sv[3]))
        max_v = Vec3d(max(max_v[1], sv[1]), max(max_v[2], sv[2]), max(max_v[3], sv[3]))
    end
    w = max_v[1] - min_v[1]
    h = max_v[2] - min_v[2]
    d = max_v[3] - min_v[3]
    m12 = mass / 12.0
    ix = m12 * (h*h + d*d)
    iy = m12 * (w*w + d*d)
    iz = m12 * (w*w + h*h)
    ix = max(ix, 1e-10)
    iy = max(iy, 1e-10)
    iz = max(iz, 1e-10)
    return Mat3d(1.0/ix, 0, 0, 0, 1.0/iy, 0, 0, 0, 1.0/iz)
end

function compute_inverse_inertia(shape::CompoundShape, mass::Float64, scale::Vec3d)
    if mass <= 0.0 || isempty(shape.children)
        return ZERO_MAT3D
    end

    # Parallel axis theorem: I_total = Σ (I_child + m_child * d²)
    # Distribute mass proportionally by volume estimate (using AABB volumes)
    volumes = Float64[]
    identity_rot = Quaternion(1.0, 0.0, 0.0, 0.0)
    for child in shape.children
        aabb = compute_world_aabb(child.shape, Vec3d(0,0,0), identity_rot, scale, Vec3f(0,0,0))
        sz = aabb.max_pt - aabb.min_pt
        vol = max(abs(sz[1]) * abs(sz[2]) * abs(sz[3]), 1e-10)
        push!(volumes, vol)
    end
    total_vol = sum(volumes)

    ixx = 0.0; iyy = 0.0; izz = 0.0
    ixy = 0.0; ixz = 0.0; iyz = 0.0

    for (i, child) in enumerate(shape.children)
        m_child = mass * volumes[i] / total_vol
        # Child local inertia (inverse → invert back to get inertia)
        inv_I_child = compute_inverse_inertia(child.shape, m_child, scale)
        # Get diagonal inertia values
        I_child_xx = inv_I_child[1,1] > 0 ? 1.0 / inv_I_child[1,1] : 1e10
        I_child_yy = inv_I_child[2,2] > 0 ? 1.0 / inv_I_child[2,2] : 1e10
        I_child_zz = inv_I_child[3,3] > 0 ? 1.0 / inv_I_child[3,3] : 1e10

        # Parallel axis theorem: add m * (d²·I₃ - d⊗d)
        d = child.local_position .* scale
        d_sq = d[1]*d[1] + d[2]*d[2] + d[3]*d[3]

        ixx += I_child_xx + m_child * (d_sq - d[1]*d[1])
        iyy += I_child_yy + m_child * (d_sq - d[2]*d[2])
        izz += I_child_zz + m_child * (d_sq - d[3]*d[3])
        ixy += -m_child * d[1] * d[2]
        ixz += -m_child * d[1] * d[3]
        iyz += -m_child * d[2] * d[3]
    end

    # Build full inertia tensor and invert
    I_total = Mat3d(
        ixx, ixy, ixz,
        ixy, iyy, iyz,
        ixz, iyz, izz
    )
    # Use diagonal approximation for invertibility
    inv_ixx = ixx > 1e-10 ? 1.0 / ixx : 0.0
    inv_iyy = iyy > 1e-10 ? 1.0 / iyy : 0.0
    inv_izz = izz > 1e-10 ? 1.0 / izz : 0.0
    return Mat3d(inv_ixx, 0, 0, 0, inv_iyy, 0, 0, 0, inv_izz)
end

"""
    rotate_inverse_inertia(inv_inertia_local::Mat3d, rotation::Quaternion{Float64}) -> Mat3d

Transform the inverse inertia tensor from local to world space using the rotation.
I_world⁻¹ = R * I_local⁻¹ * Rᵀ
"""
function rotate_inverse_inertia(inv_inertia_local::Mat3d, rotation::Quaternion{Float64})
    R_full = rotation_matrix(rotation)
    # Extract 3x3 rotation
    R = Mat3d(
        R_full[1,1], R_full[2,1], R_full[3,1],
        R_full[1,2], R_full[2,2], R_full[3,2],
        R_full[1,3], R_full[2,3], R_full[3,3]
    )
    return R * inv_inertia_local * R'
end
