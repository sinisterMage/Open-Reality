# Frustum culling: extract frustum planes from VP matrix, test bounding spheres

"""
    FrustumPlane

A plane in Hessian normal form: ax + by + cz + d = 0.
"""
struct FrustumPlane
    a::Float32
    b::Float32
    c::Float32
    d::Float32
end

"""
    Frustum

Six clipping planes extracted from the view-projection matrix.
Order: left, right, bottom, top, near, far.
"""
struct Frustum
    planes::NTuple{6, FrustumPlane}
end

"""
    BoundingSphere

Object-space bounding sphere for quick culling tests.
"""
struct BoundingSphere
    center::Vec3f
    radius::Float32
end

# ---- Frustum extraction (Gribb-Hartmann method) ----

"""
    extract_frustum(vp::Mat4f) -> Frustum

Extract the six frustum planes from a combined view-projection matrix
using the Gribb-Hartmann method. Planes point inward; a point is inside
if distance > 0 for all planes (after normalization).
"""
function extract_frustum(vp::Mat4f)
    # Row accessors: vp is column-major, so row i = vp[i,1], vp[i,2], ...
    # Left:   row4 + row1
    left   = _make_plane(vp[4,1]+vp[1,1], vp[4,2]+vp[1,2], vp[4,3]+vp[1,3], vp[4,4]+vp[1,4])
    # Right:  row4 - row1
    right  = _make_plane(vp[4,1]-vp[1,1], vp[4,2]-vp[1,2], vp[4,3]-vp[1,3], vp[4,4]-vp[1,4])
    # Bottom: row4 + row2
    bottom = _make_plane(vp[4,1]+vp[2,1], vp[4,2]+vp[2,2], vp[4,3]+vp[2,3], vp[4,4]+vp[2,4])
    # Top:    row4 - row2
    top    = _make_plane(vp[4,1]-vp[2,1], vp[4,2]-vp[2,2], vp[4,3]-vp[2,3], vp[4,4]-vp[2,4])
    # Near:   row4 + row3
    near   = _make_plane(vp[4,1]+vp[3,1], vp[4,2]+vp[3,2], vp[4,3]+vp[3,3], vp[4,4]+vp[3,4])
    # Far:    row4 - row3
    far    = _make_plane(vp[4,1]-vp[3,1], vp[4,2]-vp[3,2], vp[4,3]-vp[3,3], vp[4,4]-vp[3,4])

    return Frustum((left, right, bottom, top, near, far))
end

function _make_plane(a::Float32, b::Float32, c::Float32, d::Float32)
    len = sqrt(a*a + b*b + c*c)
    len < 1.0f-10 && return FrustumPlane(a, b, c, d)
    return FrustumPlane(a/len, b/len, c/len, d/len)
end

# ---- Bounding sphere from mesh ----

"""
    bounding_sphere_from_mesh(mesh::MeshComponent) -> BoundingSphere

Compute a bounding sphere enclosing all vertices. Uses AABB centroid as center,
then max vertex distance as radius.
"""
function bounding_sphere_from_mesh(mesh::MeshComponent)
    if isempty(mesh.vertices)
        return BoundingSphere(Vec3f(0, 0, 0), 0.0f0)
    end

    min_pt = Vec3f(Inf32, Inf32, Inf32)
    max_pt = Vec3f(-Inf32, -Inf32, -Inf32)

    for v in mesh.vertices
        min_pt = Vec3f(min(min_pt[1], v[1]), min(min_pt[2], v[2]), min(min_pt[3], v[3]))
        max_pt = Vec3f(max(max_pt[1], v[1]), max(max_pt[2], v[2]), max(max_pt[3], v[3]))
    end

    center = (min_pt + max_pt) * 0.5f0

    max_dist_sq = 0.0f0
    for v in mesh.vertices
        d = Vec3f(v[1] - center[1], v[2] - center[2], v[3] - center[3])
        dist_sq = d[1]^2 + d[2]^2 + d[3]^2
        max_dist_sq = max(max_dist_sq, dist_sq)
    end

    return BoundingSphere(center, sqrt(max_dist_sq))
end

# ---- Sphere-in-frustum test ----

"""
    is_sphere_in_frustum(frustum::Frustum, center::Vec3f, radius::Float32) -> Bool

Test if a sphere (world-space center + radius) is at least partially inside the
frustum. Returns `false` only if the sphere is fully outside any single plane.
"""
function is_sphere_in_frustum(frustum::Frustum, center::Vec3f, radius::Float32)::Bool
    for plane in frustum.planes
        dist = plane.a * center[1] + plane.b * center[2] + plane.c * center[3] + plane.d
        if dist < -radius
            return false
        end
    end
    return true
end

# ---- Transform bounding sphere to world space ----

"""
    transform_bounding_sphere(bs::BoundingSphere, model::Mat4f) -> (Vec3f, Float32)

Transform a local-space bounding sphere to world space using the model matrix.
Returns `(world_center, world_radius)`.
"""
function transform_bounding_sphere(bs::BoundingSphere, model::Mat4f)
    # Transform center by model matrix
    c = bs.center
    world_x = model[1,1]*c[1] + model[1,2]*c[2] + model[1,3]*c[3] + model[1,4]
    world_y = model[2,1]*c[1] + model[2,2]*c[2] + model[2,3]*c[3] + model[2,4]
    world_z = model[3,1]*c[1] + model[3,2]*c[2] + model[3,3]*c[3] + model[3,4]

    # Scale radius by maximum axis scale
    sx = sqrt(model[1,1]^2 + model[2,1]^2 + model[3,1]^2)
    sy = sqrt(model[1,2]^2 + model[2,2]^2 + model[3,2]^2)
    sz = sqrt(model[1,3]^2 + model[2,3]^2 + model[3,3]^2)
    max_scale = max(sx, sy, sz)

    return (Vec3f(world_x, world_y, world_z), bs.radius * max_scale)
end
