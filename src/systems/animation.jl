# Animation system: advance time, interpolate keyframes, update transforms

"""
    update_animations!(dt::Float64)

Advance all playing AnimationComponents and apply interpolated keyframe
values to target entity transforms.
"""
function update_animations!(dt::Float64)
    iterate_components(AnimationComponent) do eid, anim
        !anim.playing && return
        anim.active_clip < 1 && return
        anim.active_clip > length(anim.clips) && return

        clip = anim.clips[anim.active_clip]

        # Advance time
        anim.current_time += dt * Float64(anim.speed)

        if anim.current_time >= Float64(clip.duration)
            if anim.looping
                anim.current_time = mod(anim.current_time, Float64(clip.duration))
            else
                anim.current_time = Float64(clip.duration)
                anim.playing = false
            end
        end

        t = Float32(anim.current_time)

        # Evaluate each channel
        for channel in clip.channels
            _apply_channel!(channel, t)
        end
    end
end

# ---- Keyframe search ----

"""
    _find_keyframe_pair(times, t) -> (idx_a, idx_b, lerp_t)

Binary-search for the pair of keyframes bounding time `t`.
Returns indices into `times` and the interpolation factor in [0,1].
"""
function _find_keyframe_pair(times::Vector{Float32}, t::Float32)
    n = length(times)
    n == 0 && return (1, 1, 0.0f0)

    if t <= times[1]
        return (1, 1, 0.0f0)
    end
    if t >= times[end]
        return (n, n, 0.0f0)
    end

    # Binary search
    lo, hi = 1, n
    while lo < hi - 1
        mid = (lo + hi) >> 1
        if times[mid] <= t
            lo = mid
        else
            hi = mid
        end
    end

    dt = times[hi] - times[lo]
    lerp_t = dt > 0.0f0 ? (t - times[lo]) / dt : 0.0f0
    return (lo, hi, lerp_t)
end

# ---- Interpolation helpers ----

function _lerp_vec3d(a::Vec3d, b::Vec3d, t::Float32)
    ft = Float64(t)
    return Vec3d(
        a[1] + (b[1] - a[1]) * ft,
        a[2] + (b[2] - a[2]) * ft,
        a[3] + (b[3] - a[3]) * ft
    )
end

"""
Spherical linear interpolation for unit quaternions.
"""
function _slerp(a::Quaterniond, b::Quaterniond, t::Float32)
    ft = Float64(t)
    # Ensure shortest path
    d = a.s * b.s + a.v1 * b.v1 + a.v2 * b.v2 + a.v3 * b.v3
    b_adj = d < 0.0 ? Quaterniond(-b.s, -b.v1, -b.v2, -b.v3) : b
    d = abs(d)

    if d > 0.9995
        # Near-linear fallback
        result = Quaterniond(
            a.s  + (b_adj.s  - a.s)  * ft,
            a.v1 + (b_adj.v1 - a.v1) * ft,
            a.v2 + (b_adj.v2 - a.v2) * ft,
            a.v3 + (b_adj.v3 - a.v3) * ft
        )
        # Normalize
        len = sqrt(result.s^2 + result.v1^2 + result.v2^2 + result.v3^2)
        return Quaterniond(result.s/len, result.v1/len, result.v2/len, result.v3/len)
    end

    theta = acos(clamp(d, -1.0, 1.0))
    sin_theta = sin(theta)
    wa = sin((1.0 - ft) * theta) / sin_theta
    wb = sin(ft * theta) / sin_theta

    return Quaterniond(
        wa * a.s  + wb * b_adj.s,
        wa * a.v1 + wb * b_adj.v1,
        wa * a.v2 + wb * b_adj.v2,
        wa * a.v3 + wb * b_adj.v3
    )
end

# ---- Channel application ----

function _apply_channel!(channel::AnimationChannel, t::Float32)
    isempty(channel.times) && return

    tc = get_component(channel.target_entity, TransformComponent)
    tc === nothing && return

    idx_a, idx_b, lerp_t = _find_keyframe_pair(channel.times, t)

    if channel.target_property == :position
        va = channel.values[idx_a]::Vec3d
        vb = channel.values[idx_b]::Vec3d
        if channel.interpolation == INTERP_STEP
            tc.position[] = va
        else
            tc.position[] = _lerp_vec3d(va, vb, lerp_t)
        end
    elseif channel.target_property == :rotation
        qa = channel.values[idx_a]::Quaterniond
        qb = channel.values[idx_b]::Quaterniond
        if channel.interpolation == INTERP_STEP
            tc.rotation[] = qa
        else
            tc.rotation[] = _slerp(qa, qb, lerp_t)
        end
    elseif channel.target_property == :scale
        va = channel.values[idx_a]::Vec3d
        vb = channel.values[idx_b]::Vec3d
        if channel.interpolation == INTERP_STEP
            tc.scale[] = va
        else
            tc.scale[] = _lerp_vec3d(va, vb, lerp_t)
        end
    end
end
