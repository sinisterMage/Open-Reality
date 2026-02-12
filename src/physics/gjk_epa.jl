# GJK (Gilbert-Johnson-Keerthi) + EPA (Expanding Polytope Algorithm)
# For convex-convex collision detection and penetration depth computation

const GJK_MAX_ITERATIONS = 64
const EPA_MAX_ITERATIONS = 64
const EPA_TOLERANCE = 1e-6

# =============================================================================
# GJK Algorithm
# =============================================================================

"""
    GJKSimplex

Simplex used during GJK iteration. Stores up to 4 support points
from the Minkowski difference.
"""
mutable struct GJKSimplex
    points::Vector{Vec3d}
    size::Int
end

GJKSimplex() = GJKSimplex(Vec3d[], 0)

function _simplex_push!(s::GJKSimplex, pt::Vec3d)
    push!(s.points, pt)
    s.size += 1
end

"""
    _minkowski_support(shape_a, pos_a, rot_a, scl_a, off_a,
                       shape_b, pos_b, rot_b, scl_b, off_b,
                       direction) -> Vec3d

Compute the Minkowski difference support point: support_A(d) - support_B(-d).
"""
function _minkowski_support(shape_a::ColliderShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                             shape_b::ColliderShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                             direction::Vec3d)
    sa = gjk_support(shape_a, pos_a, rot_a, scl_a, off_a, direction)
    sb = gjk_support(shape_b, pos_b, rot_b, scl_b, off_b, -direction)
    return sa - sb
end

"""
    gjk_intersect(shape_a, pos_a, rot_a, scl_a, off_a,
                  shape_b, pos_b, rot_b, scl_b, off_b) -> (Bool, GJKSimplex)

Test if two convex shapes intersect using the GJK algorithm.
Returns (intersects, simplex) where simplex can be used by EPA if intersecting.
"""
function gjk_intersect(shape_a::ColliderShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                        shape_b::ColliderShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f)
    # Initial direction: from center of A to center of B
    center_a = pos_a + Vec3d(Float64(off_a[1]), Float64(off_a[2]), Float64(off_a[3])) .* scl_a
    center_b = pos_b + Vec3d(Float64(off_b[1]), Float64(off_b[2]), Float64(off_b[3])) .* scl_b
    direction = center_b - center_a
    if vec3d_length(direction) < COLLISION_EPSILON
        direction = Vec3d(1, 0, 0)
    end

    simplex = GJKSimplex()

    # First support point
    a = _minkowski_support(shape_a, pos_a, rot_a, scl_a, off_a,
                            shape_b, pos_b, rot_b, scl_b, off_b, direction)
    _simplex_push!(simplex, a)
    direction = -a

    for _ in 1:GJK_MAX_ITERATIONS
        a = _minkowski_support(shape_a, pos_a, rot_a, scl_a, off_a,
                                shape_b, pos_b, rot_b, scl_b, off_b, direction)

        # If the new point didn't pass the origin, no intersection
        if vec3d_dot(a, direction) < 0
            return false, simplex
        end

        _simplex_push!(simplex, a)

        contains_origin, new_dir = _do_simplex!(simplex)
        if contains_origin
            return true, simplex
        end
        direction = new_dir
    end

    return false, simplex
end

"""
    _do_simplex!(simplex) -> (Bool, Vec3d)

Process the simplex to determine if it contains the origin.
Returns (contains_origin, new_search_direction).
"""
function _do_simplex!(simplex::GJKSimplex)
    if simplex.size == 2
        return _simplex_line!(simplex)
    elseif simplex.size == 3
        return _simplex_triangle!(simplex)
    elseif simplex.size == 4
        return _simplex_tetrahedron!(simplex)
    end
    return false, Vec3d(1, 0, 0)
end

function _simplex_line!(simplex::GJKSimplex)
    b = simplex.points[1]
    a = simplex.points[2]  # Most recently added
    ab = b - a
    ao = -a

    if vec3d_dot(ab, ao) > 0
        direction = vec3d_cross(vec3d_cross(ab, ao), ab)
        if vec3d_length(direction) < COLLISION_EPSILON
            direction = _perpendicular(ab)
        end
    else
        simplex.points = [a]
        simplex.size = 1
        direction = ao
    end

    return false, direction
end

function _simplex_triangle!(simplex::GJKSimplex)
    c = simplex.points[1]
    b = simplex.points[2]
    a = simplex.points[3]  # Most recently added
    ab = b - a
    ac = c - a
    ao = -a
    abc = vec3d_cross(ab, ac)

    # Check edge AC
    if vec3d_dot(vec3d_cross(abc, ac), ao) > 0
        if vec3d_dot(ac, ao) > 0
            simplex.points = [c, a]
            simplex.size = 2
            return false, vec3d_cross(vec3d_cross(ac, ao), ac)
        else
            simplex.points = [a]
            simplex.size = 1
            return _simplex_line_check!(simplex, a, b, ao, ab)
        end
    else
        if vec3d_dot(vec3d_cross(ab, abc), ao) > 0
            simplex.points = [a]
            simplex.size = 1
            return _simplex_line_check!(simplex, a, b, ao, ab)
        else
            # Inside triangle — check which side of the plane
            if vec3d_dot(abc, ao) > 0
                return false, abc
            else
                simplex.points = [b, c, a]
                return false, -abc
            end
        end
    end
end

function _simplex_line_check!(simplex::GJKSimplex, a::Vec3d, b::Vec3d, ao::Vec3d, ab::Vec3d)
    if vec3d_dot(ab, ao) > 0
        simplex.points = [b, a]
        simplex.size = 2
        direction = vec3d_cross(vec3d_cross(ab, ao), ab)
        if vec3d_length(direction) < COLLISION_EPSILON
            direction = _perpendicular(ab)
        end
        return false, direction
    else
        simplex.points = [a]
        simplex.size = 1
        return false, ao
    end
end

function _simplex_tetrahedron!(simplex::GJKSimplex)
    d = simplex.points[1]
    c = simplex.points[2]
    b = simplex.points[3]
    a = simplex.points[4]  # Most recently added
    ao = -a
    ab = b - a
    ac = c - a
    ad = d - a

    abc = vec3d_cross(ab, ac)
    acd = vec3d_cross(ac, ad)
    adb = vec3d_cross(ad, ab)

    # Check each face
    abc_test = vec3d_dot(abc, ao) > 0
    acd_test = vec3d_dot(acd, ao) > 0
    adb_test = vec3d_dot(adb, ao) > 0

    if abc_test
        simplex.points = [c, b, a]
        simplex.size = 3
        return _simplex_triangle!(simplex)
    end
    if acd_test
        simplex.points = [d, c, a]
        simplex.size = 3
        return _simplex_triangle!(simplex)
    end
    if adb_test
        simplex.points = [b, d, a]
        simplex.size = 3
        return _simplex_triangle!(simplex)
    end

    # Origin is inside the tetrahedron
    return true, Vec3d(0, 0, 0)
end

function _perpendicular(v::Vec3d)
    if abs(v[1]) < 0.9
        return vec3d_normalize(vec3d_cross(v, Vec3d(1, 0, 0)))
    else
        return vec3d_normalize(vec3d_cross(v, Vec3d(0, 1, 0)))
    end
end

# =============================================================================
# EPA Algorithm
# =============================================================================

struct EPAFace
    a::Int  # Index into EPA vertex list
    b::Int
    c::Int
    normal::Vec3d
    distance::Float64  # Distance from origin to face plane
end

"""
    epa_penetration(simplex::GJKSimplex,
                    shape_a, pos_a, rot_a, scl_a, off_a,
                    shape_b, pos_b, rot_b, scl_b, off_b) -> (Vec3d, Float64)

Use EPA to find the penetration normal and depth from a GJK simplex that contains the origin.
Returns (normal, depth) where normal points from A to B.
"""
function epa_penetration(simplex::GJKSimplex,
                          shape_a::ColliderShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          shape_b::ColliderShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f)
    # Build initial polytope from GJK simplex (must be a tetrahedron)
    if simplex.size < 4
        # Degenerate: expand to tetrahedron
        return Vec3d(0, 1, 0), 0.0
    end

    vertices = copy(simplex.points)
    faces = EPAFace[]

    # Create faces with outward-pointing normals
    _add_epa_face!(faces, vertices, 1, 2, 3)
    _add_epa_face!(faces, vertices, 1, 3, 4)
    _add_epa_face!(faces, vertices, 1, 4, 2)
    _add_epa_face!(faces, vertices, 2, 4, 3)

    for _ in 1:EPA_MAX_ITERATIONS
        # Find closest face to origin
        min_idx = 1
        min_dist = faces[1].distance
        for i in 2:length(faces)
            if faces[i].distance < min_dist
                min_dist = faces[i].distance
                min_idx = i
            end
        end
        closest_face = faces[min_idx]

        # Get new support point along face normal
        new_pt = _minkowski_support(shape_a, pos_a, rot_a, scl_a, off_a,
                                     shape_b, pos_b, rot_b, scl_b, off_b,
                                     closest_face.normal)
        new_dist = vec3d_dot(new_pt, closest_face.normal)

        # Convergence check
        if new_dist - min_dist < EPA_TOLERANCE
            return closest_face.normal, min_dist
        end

        # Add new vertex
        push!(vertices, new_pt)
        new_idx = length(vertices)

        # Remove faces visible from new point and collect edges
        edges = Tuple{Int, Int}[]
        remaining_faces = EPAFace[]
        for face in faces
            if vec3d_dot(face.normal, new_pt - vertices[face.a]) > 0
                # Face is visible — collect edges
                _add_edge!(edges, face.a, face.b)
                _add_edge!(edges, face.b, face.c)
                _add_edge!(edges, face.c, face.a)
            else
                push!(remaining_faces, face)
            end
        end

        # Create new faces from edge loop to new vertex
        faces = remaining_faces
        for (e1, e2) in edges
            _add_epa_face!(faces, vertices, e1, e2, new_idx)
        end

        if isempty(faces)
            return Vec3d(0, 1, 0), 0.0
        end
    end

    # Return best result so far
    if !isempty(faces)
        min_idx = argmin(f -> f.distance, faces)
        return faces[min_idx].normal, faces[min_idx].distance
    end
    return Vec3d(0, 1, 0), 0.0
end

function _add_epa_face!(faces::Vector{EPAFace}, vertices::Vector{Vec3d}, a::Int, b::Int, c::Int)
    ab = vertices[b] - vertices[a]
    ac = vertices[c] - vertices[a]
    normal = vec3d_cross(ab, ac)
    len = vec3d_length(normal)
    if len < COLLISION_EPSILON
        return
    end
    normal = normal / len

    # Ensure normal points away from origin
    if vec3d_dot(normal, vertices[a]) < 0
        normal = -normal
        # Swap winding
        push!(faces, EPAFace(a, c, b, normal, vec3d_dot(normal, vertices[a])))
    else
        push!(faces, EPAFace(a, b, c, normal, vec3d_dot(normal, vertices[a])))
    end
end

function _add_edge!(edges::Vector{Tuple{Int,Int}}, a::Int, b::Int)
    # If reverse edge exists, remove it (shared edge between visible faces)
    for i in length(edges):-1:1
        if edges[i] == (b, a)
            deleteat!(edges, i)
            return
        end
    end
    push!(edges, (a, b))
end

# =============================================================================
# Convex collision using GJK+EPA
# =============================================================================

"""
    collide_gjk_epa(shape_a, pos_a, rot_a, scl_a, off_a,
                    shape_b, pos_b, rot_b, scl_b, off_b,
                    eid_a, eid_b) -> Union{ContactManifold, Nothing}

Perform convex-convex collision detection using GJK for overlap test
and EPA for penetration depth/normal computation.
"""
function collide_gjk_epa(shape_a::ColliderShape, pos_a::Vec3d, rot_a::Quaternion{Float64}, scl_a::Vec3d, off_a::Vec3f,
                          shape_b::ColliderShape, pos_b::Vec3d, rot_b::Quaternion{Float64}, scl_b::Vec3d, off_b::Vec3f,
                          eid_a::EntityID, eid_b::EntityID)
    intersects, simplex = gjk_intersect(shape_a, pos_a, rot_a, scl_a, off_a,
                                         shape_b, pos_b, rot_b, scl_b, off_b)
    if !intersects
        return nothing
    end

    normal, depth = epa_penetration(simplex,
                                     shape_a, pos_a, rot_a, scl_a, off_a,
                                     shape_b, pos_b, rot_b, scl_b, off_b)

    if depth < COLLISION_EPSILON
        return nothing
    end

    # Contact point: midpoint of the support points
    sa = gjk_support(shape_a, pos_a, rot_a, scl_a, off_a, normal)
    sb = gjk_support(shape_b, pos_b, rot_b, scl_b, off_b, -normal)
    contact_pt = (sa + sb) * 0.5

    manifold = ContactManifold(eid_a, eid_b, normal)
    push!(manifold.points, ContactPoint(contact_pt, normal, depth))
    return manifold
end
