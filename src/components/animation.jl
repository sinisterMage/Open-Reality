# Animation component: clips, channels, keyframes

"""
    InterpolationMode

Keyframe interpolation strategy.
"""
@enum InterpolationMode INTERP_STEP INTERP_LINEAR INTERP_CUBICSPLINE

"""
    AnimationChannel

A single animated property targeting one entity's transform.
"""
struct AnimationChannel
    target_entity::EntityID
    target_property::Symbol    # :position, :rotation, or :scale
    times::Vector{Float32}     # keyframe timestamps (sorted ascending)
    values::Vector{Any}        # Vec3d for position/scale, Quaterniond for rotation
    interpolation::InterpolationMode
end

"""
    AnimationClip

A named collection of channels that play together.
"""
struct AnimationClip
    name::String
    channels::Vector{AnimationChannel}
    duration::Float32
end

"""
    AnimationComponent <: Component

Holds animation clips and playback state. Attach to any entity to
make it (or entities referenced by channels) animate.
"""
mutable struct AnimationComponent <: Component
    clips::Vector{AnimationClip}
    active_clip::Int         # 0 = none
    current_time::Float64
    playing::Bool
    looping::Bool
    speed::Float32

    AnimationComponent(;
        clips::Vector{AnimationClip} = AnimationClip[],
        active_clip::Int = 0,
        current_time::Float64 = 0.0,
        playing::Bool = false,
        looping::Bool = true,
        speed::Float32 = 1.0f0
    ) = new(clips, active_clip, current_time, playing, looping, speed)
end
