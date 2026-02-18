# Collision callbacks with enter/stay/exit detection

"""
    CollisionCallbackComponent <: Component

Attaches collision event callbacks to a rigid body. When the entity collides
with another entity, the corresponding callbacks are invoked.

Callbacks receive (this_entity, other_entity, manifold) where manifold is
`Union{ContactManifold, Nothing}` (nothing for exit events).
"""
mutable struct CollisionCallbackComponent <: Component
    on_collision_enter::Union{Function, Nothing}
    on_collision_stay::Union{Function, Nothing}
    on_collision_exit::Union{Function, Nothing}

    CollisionCallbackComponent(;
        on_collision_enter::Union{Function, Nothing} = nothing,
        on_collision_stay::Union{Function, Nothing} = nothing,
        on_collision_exit::Union{Function, Nothing} = nothing
    ) = new(on_collision_enter, on_collision_stay, on_collision_exit)
end

"""
    CollisionEventCache

Tracks collision pairs across frames to detect enter/stay/exit transitions.
"""
mutable struct CollisionEventCache
    prev_pairs::Set{Tuple{EntityID, EntityID}}
    current_pairs::Set{Tuple{EntityID, EntityID}}
    current_manifolds::Dict{Tuple{EntityID, EntityID}, ContactManifold}
end

CollisionEventCache() = CollisionEventCache(
    Set{Tuple{EntityID, EntityID}}(),
    Set{Tuple{EntityID, EntityID}}(),
    Dict{Tuple{EntityID, EntityID}, ContactManifold}()
)
