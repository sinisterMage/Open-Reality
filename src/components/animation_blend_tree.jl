# Animation blend tree component: blend nodes and blend tree state

abstract type BlendNode end

struct ClipNode <: BlendNode
    clip::AnimationClip
end

mutable struct Blend1DNode <: BlendNode
    parameter::String
    thresholds::Vector{Float32}
    children::Vector{BlendNode}
end

mutable struct Blend2DNode <: BlendNode
    param_x::String
    param_y::String
    positions::Vector{Vec2f}
    children::Vector{BlendNode}
end

mutable struct AnimationBlendTreeComponent <: Component
    root::BlendNode
    parameters::Dict{String, Float32}
    bool_parameters::Dict{String, Bool}
    trigger_parameters::Set{String}
    current_time::Float64
    transitioning::Bool
    transition_duration::Float32
    transition_elapsed::Float32
    previous_root::Union{BlendNode, Nothing}
end
