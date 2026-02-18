# Animation system: advance time, interpolate keyframes, update transforms

"""
    update_animations!(dt::Float64)

Advance all playing AnimationComponents and apply interpolated keyframe
values to target entity transforms.
"""
function update_animations!(dt::Float64)
    iterate_components(AnimationComponent) do eid, anim
        has_component(eid, AnimationBlendTreeComponent) && return
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
