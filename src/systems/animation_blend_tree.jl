# Animation blend tree system: evaluate blend nodes, update blend tree components

# =============================================================================
# Blend output helpers
# =============================================================================

function _blend_outputs(a::Dict{EntityID, Dict{Symbol, Any}}, b::Dict{EntityID, Dict{Symbol, Any}}, t::Float32)
    result = Dict{EntityID, Dict{Symbol, Any}}()

    all_keys = union(keys(a), keys(b))
    for eid in all_keys
        props_a = get(a, eid, Dict{Symbol, Any}())
        props_b = get(b, eid, Dict{Symbol, Any}())
        blended = Dict{Symbol, Any}()

        all_props = union(keys(props_a), keys(props_b))
        for prop in all_props
            va = get(props_a, prop, nothing)
            vb = get(props_b, prop, nothing)

            if va === nothing
                blended[prop] = vb
            elseif vb === nothing
                blended[prop] = va
            elseif va isa Vec3d && vb isa Vec3d
                blended[prop] = _lerp_vec3d(va, vb, t)
            elseif va isa Quaterniond && vb isa Quaterniond
                blended[prop] = _slerp(va, vb, t)
            else
                blended[prop] = vb
            end
        end

        result[eid] = blended
    end

    return result
end

function _weighted_blend_outputs(outputs::Vector{Dict{EntityID, Dict{Symbol, Any}}}, weights::Vector{Float32})
    isempty(outputs) && return Dict{EntityID, Dict{Symbol, Any}}()
    length(outputs) == 1 && return outputs[1]

    result = Dict{EntityID, Dict{Symbol, Any}}()

    all_eids = Set{EntityID}()
    for out in outputs
        union!(all_eids, keys(out))
    end

    for eid in all_eids
        blended = Dict{Symbol, Any}()

        all_props = Set{Symbol}()
        for out in outputs
            if haskey(out, eid)
                union!(all_props, keys(out[eid]))
            end
        end

        for prop in all_props
            # Collect values and their weights
            vals = []
            ws = Float32[]
            for (i, out) in enumerate(outputs)
                if haskey(out, eid) && haskey(out[eid], prop)
                    push!(vals, out[eid][prop])
                    push!(ws, weights[i])
                end
            end

            isempty(vals) && continue

            if length(vals) == 1
                blended[prop] = vals[1]
            elseif vals[1] isa Vec3d
                acc = Vec3d(0.0, 0.0, 0.0)
                w_total = sum(ws)
                for (v, w) in zip(vals, ws)
                    nw = w / w_total
                    acc = Vec3d(acc[1] + v[1] * nw, acc[2] + v[2] * nw, acc[3] + v[3] * nw)
                end
                blended[prop] = acc
            elseif vals[1] isa Quaterniond
                # Successive slerp blending
                acc = vals[1]::Quaterniond
                w_acc = ws[1]
                for i in 2:length(vals)
                    w_acc += ws[i]
                    t_blend = w_acc > 0.0f0 ? ws[i] / w_acc : 0.0f0
                    acc = _slerp(acc, vals[i]::Quaterniond, t_blend)
                end
                blended[prop] = acc
            else
                blended[prop] = vals[1]
            end
        end

        result[eid] = blended
    end

    return result
end

# =============================================================================
# evaluate_blend_node — dispatch on node type
# =============================================================================

function evaluate_blend_node(node::ClipNode, params::Dict{String, Float32}, bool_params::Dict{String, Bool}, triggers::Set{String}, time::Float64)
    result = Dict{EntityID, Dict{Symbol, Any}}()

    for channel in node.clip.channels
        isempty(channel.times) && continue

        idx_a, idx_b, lerp_t = _find_keyframe_pair(channel.times, Float32(time))

        val = if channel.interpolation == INTERP_STEP
            channel.values[idx_a]
        elseif channel.target_property == :position || channel.target_property == :scale
            _lerp_vec3d(channel.values[idx_a]::Vec3d, channel.values[idx_b]::Vec3d, lerp_t)
        elseif channel.target_property == :rotation
            _slerp(channel.values[idx_a]::Quaterniond, channel.values[idx_b]::Quaterniond, lerp_t)
        else
            channel.values[idx_a]
        end

        if !haskey(result, channel.target_entity)
            result[channel.target_entity] = Dict{Symbol, Any}()
        end
        result[channel.target_entity][channel.target_property] = val
    end

    return result
end

function evaluate_blend_node(node::Blend1DNode, params::Dict{String, Float32}, bool_params::Dict{String, Bool}, triggers::Set{String}, time::Float64)
    v = get(params, node.parameter, 0.0f0)

    if v <= node.thresholds[1]
        return evaluate_blend_node(node.children[1], params, bool_params, triggers, time)
    end

    if v >= node.thresholds[end]
        return evaluate_blend_node(node.children[end], params, bool_params, triggers, time)
    end

    # Find adjacent thresholds
    idx = 1
    for i in 1:(length(node.thresholds) - 1)
        if node.thresholds[i] <= v < node.thresholds[i + 1]
            idx = i
            break
        end
    end

    t = (v - node.thresholds[idx]) / (node.thresholds[idx + 1] - node.thresholds[idx])
    out_a = evaluate_blend_node(node.children[idx], params, bool_params, triggers, time)
    out_b = evaluate_blend_node(node.children[idx + 1], params, bool_params, triggers, time)

    return _blend_outputs(out_a, out_b, t)
end

function evaluate_blend_node(node::Blend2DNode, params::Dict{String, Float32}, bool_params::Dict{String, Bool}, triggers::Set{String}, time::Float64)
    px = get(params, node.param_x, 0.0f0)
    py = get(params, node.param_y, 0.0f0)

    n = length(node.children)
    weights = Vector{Float32}(undef, n)
    total_weight = 0.0f0

    for i in 1:n
        dx = px - node.positions[i][1]
        dy = py - node.positions[i][2]
        dist = sqrt(dx * dx + dy * dy)
        w = 1.0f0 / (dist + 1e-6f0)
        weights[i] = w
        total_weight += w
    end

    # Normalize weights
    if total_weight > 0.0f0
        for i in 1:n
            weights[i] /= total_weight
        end
    end

    outputs = Vector{Dict{EntityID, Dict{Symbol, Any}}}(undef, n)
    for i in 1:n
        outputs[i] = evaluate_blend_node(node.children[i], params, bool_params, triggers, time)
    end

    return _weighted_blend_outputs(outputs, weights)
end

# =============================================================================
# update_blend_tree! — main system tick
# =============================================================================

function update_blend_tree!(dt::Float64)
    iterate_components(AnimationBlendTreeComponent) do eid, comp
        comp.current_time += dt

        if comp.transitioning
            if comp.transition_duration <= 0f0
                comp.transitioning = false
                comp.previous_root = nothing
                output = evaluate_blend_node(comp.root, comp.parameters, comp.bool_parameters, comp.trigger_parameters, comp.current_time)
            else
                comp.transition_elapsed += Float32(dt)
                t = clamp(comp.transition_elapsed / comp.transition_duration, 0f0, 1f0)
                out_prev = evaluate_blend_node(comp.previous_root, comp.parameters, comp.bool_parameters, comp.trigger_parameters, comp.current_time)
                out_curr = evaluate_blend_node(comp.root, comp.parameters, comp.bool_parameters, comp.trigger_parameters, comp.current_time)
                output = _blend_outputs(out_prev, out_curr, t)
                if t >= 1.0f0
                    comp.transitioning = false
                    comp.previous_root = nothing
                end
            end
        else
            output = evaluate_blend_node(comp.root, comp.parameters, comp.bool_parameters, comp.trigger_parameters, comp.current_time)
        end

        # Apply output to TransformComponent Observables
        for (target_eid, props) in output
            tc = get_component(target_eid, TransformComponent)
            tc === nothing && continue
            haskey(props, :position) && (tc.position[] = props[:position])
            haskey(props, :rotation) && (tc.rotation[] = props[:rotation])
            haskey(props, :scale)    && (tc.scale[]    = props[:scale])
        end

        # Consume triggers
        empty!(comp.trigger_parameters)
    end
end

# =============================================================================
# Public API
# =============================================================================

function transition_to_tree!(comp::AnimationBlendTreeComponent, new_root::BlendNode, duration::Float32)
    comp.previous_root = comp.root
    comp.root = new_root
    comp.transitioning = true
    comp.transition_duration = duration
    comp.transition_elapsed = 0f0
end

function set_parameter!(comp::AnimationBlendTreeComponent, name::String, value::Float32)
    comp.parameters[name] = value
end

function set_bool_parameter!(comp::AnimationBlendTreeComponent, name::String, value::Bool)
    comp.bool_parameters[name] = value
end

function fire_trigger!(comp::AnimationBlendTreeComponent, name::String)
    push!(comp.trigger_parameters, name)
end
