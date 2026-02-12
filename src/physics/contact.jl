# Contact manifold caching for warm-starting the solver

const MAX_CONTACT_POINTS = 4
const CONTACT_BREAKING_DISTANCE = 0.02  # Distance threshold to discard old contacts

"""
    ContactCache

Stores contact manifolds from the previous frame for warm-starting.
Key: (entity_a, entity_b) with canonical ordering (a.id < b.id).
"""
mutable struct ContactCache
    manifolds::Dict{Tuple{EntityID, EntityID}, ContactManifold}
end

ContactCache() = ContactCache(Dict{Tuple{EntityID, EntityID}, ContactManifold}())

"""
    _canonical_key(a::EntityID, b::EntityID) -> Tuple{EntityID, EntityID}
"""
@inline function _canonical_key(a::EntityID, b::EntityID)
    return a < b ? (a, b) : (b, a)
end

"""
    update_cache!(cache::ContactCache, new_manifolds::Vector{ContactManifold})

Update the contact cache with new manifolds from this frame.
Transfers accumulated impulses from old contacts to matching new contacts (warm-starting).
"""
function update_cache!(cache::ContactCache, new_manifolds::Vector{ContactManifold})
    new_dict = Dict{Tuple{EntityID, EntityID}, ContactManifold}()

    for manifold in new_manifolds
        key = _canonical_key(manifold.entity_a, manifold.entity_b)

        # Try to warm-start from cached manifold
        if haskey(cache.manifolds, key)
            old_manifold = cache.manifolds[key]
            _warm_start_manifold!(manifold, old_manifold)
        end

        # Reduce to MAX_CONTACT_POINTS
        if length(manifold.points) > MAX_CONTACT_POINTS
            _reduce_manifold!(manifold)
        end

        new_dict[key] = manifold
    end

    cache.manifolds = new_dict
end

"""
    _warm_start_manifold!(new_manifold::ContactManifold, old_manifold::ContactManifold)

Transfer accumulated impulses from old contacts to the closest new contacts.
"""
function _warm_start_manifold!(new_manifold::ContactManifold, old_manifold::ContactManifold)
    for new_pt in new_manifold.points
        best_dist_sq = CONTACT_BREAKING_DISTANCE * CONTACT_BREAKING_DISTANCE
        best_old = nothing

        for old_pt in old_manifold.points
            diff = new_pt.position - old_pt.position
            dist_sq = vec3d_dot(diff, diff)
            if dist_sq < best_dist_sq
                best_dist_sq = dist_sq
                best_old = old_pt
            end
        end

        if best_old !== nothing
            new_pt.normal_impulse = best_old.normal_impulse
            new_pt.tangent_impulse1 = best_old.tangent_impulse1
            new_pt.tangent_impulse2 = best_old.tangent_impulse2
        end
    end
end

"""
    _reduce_manifold!(manifold::ContactManifold)

Reduce a manifold to MAX_CONTACT_POINTS by keeping the points that maximize contact area.
"""
function _reduce_manifold!(manifold::ContactManifold)
    points = manifold.points
    n = length(points)
    if n <= MAX_CONTACT_POINTS
        return
    end

    # Keep the point with deepest penetration
    keep = Int[]
    max_pen_idx = 1
    max_pen = points[1].penetration
    for i in 2:n
        if points[i].penetration > max_pen
            max_pen = points[i].penetration
            max_pen_idx = i
        end
    end
    push!(keep, max_pen_idx)

    # Keep the point farthest from the first
    max_dist = 0.0
    max_dist_idx = 1
    for i in 1:n
        i == max_pen_idx && continue
        diff = points[i].position - points[max_pen_idx].position
        d = vec3d_dot(diff, diff)
        if d > max_dist
            max_dist = d
            max_dist_idx = i
        end
    end
    push!(keep, max_dist_idx)

    # Keep the point that maximizes triangle area with first two
    if n > 2
        max_area = 0.0
        max_area_idx = 1
        edge = points[keep[2]].position - points[keep[1]].position
        for i in 1:n
            i in keep && continue
            cross_vec = vec3d_cross(edge, points[i].position - points[keep[1]].position)
            area = vec3d_dot(cross_vec, cross_vec)
            if area > max_area
                max_area = area
                max_area_idx = i
            end
        end
        push!(keep, max_area_idx)
    end

    # Keep the point farthest from the triangle plane (on the opposite side)
    if n > 3
        max_dist_neg = 0.0
        max_dist_neg_idx = -1
        if length(keep) >= 3
            e1 = points[keep[2]].position - points[keep[1]].position
            e2 = points[keep[3]].position - points[keep[1]].position
            tri_normal = vec3d_cross(e1, e2)
            for i in 1:n
                i in keep && continue
                d = vec3d_dot(points[i].position - points[keep[1]].position, tri_normal)
                if abs(d) > max_dist_neg
                    max_dist_neg = abs(d)
                    max_dist_neg_idx = i
                end
            end
        end
        if max_dist_neg_idx > 0
            push!(keep, max_dist_neg_idx)
        end
    end

    manifold.points = points[keep]
end

"""
    combine_friction(f_a::Float64, f_b::Float64) -> Float64

Combine friction coefficients using geometric mean.
"""
@inline function combine_friction(f_a::Float64, f_b::Float64)
    return sqrt(f_a * f_b)
end

"""
    combine_restitution(r_a::Float64, r_b::Float64) -> Float64

Combine restitution coefficients using maximum.
"""
@inline function combine_restitution(r_a::Float64, r_b::Float64)
    return max(r_a, r_b)
end
