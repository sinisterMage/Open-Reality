# =============================================================================
# Entity ID System
# =============================================================================

"""
    EntityID

Unique identifier for entities in the ECS.
"""
const EntityID = Ark.Entity

# just for current tests TODO: remove this after adjusting tests
####
EntityID(x::Int) = Ark._new_entity(UInt32(x), UInt32(0))
EntityID(x::Int, y::Int) = Ark._new_entity(UInt32(x), UInt32(y))
Base.isless(a::EntityID, b::EntityID) = a._id < b._id
####

function initialize_world(custom_components=[])
    types = [custom_components...; COMPONENT_TYPES]
    return Ark.World(types..., allow_mutable=true)
end

"""
    World

Container for all entities and their components.
"""
World() = _WORLD

"""
    create_entity!(world::World) -> EntityID

Create a new entity in the world.
"""
function create_entity!(world)
    ark_entity = Ark.new_entity!(world, ())
    return ark_entity
end

# =============================================================================
# Component Base Type
# =============================================================================

"""
    Component

Abstract base type for all components in the ECS.

All component types must subtype this.
"""
abstract type Component end

# =============================================================================
# Component Storage (Compatibility Layer)
# =============================================================================

struct ComponentStore{T <: Component}
end


"""
    reset_component_stores!()
"""
function reset_component_stores!()
    world = World()
    Ark.reset!(world)
    empty!(_GPU_CLEANUP_QUEUE)
    for hook in _RESET_HOOKS
        hook()
    end
end

const _RESET_HOOKS = Function[]

# GPU cleanup queue — entities pending GPU resource removal.
# Filled by `remove_entity()`, drained by `flush_gpu_cleanup!()` in the render loop.
const _GPU_CLEANUP_QUEUE = EntityID[]

"""
    queue_gpu_cleanup!(entity_ids)

Enqueue entity IDs for deferred GPU resource cleanup (meshes, bounds, etc.).
Called automatically by `remove_entity()`; flushed once per frame by the render loop.
"""
function queue_gpu_cleanup!(entity_ids)
    append!(_GPU_CLEANUP_QUEUE, entity_ids)
    return nothing
end

"""
    drain_gpu_cleanup_queue!() -> Vector{EntityID}

Return all pending entity IDs and clear the queue.
"""
function drain_gpu_cleanup_queue!()::Vector{EntityID}
    if isempty(_GPU_CLEANUP_QUEUE)
        return EntityID[]
    end
    result = copy(_GPU_CLEANUP_QUEUE)
    empty!(_GPU_CLEANUP_QUEUE)
    return result
end

# =============================================================================
# Component Operations
# =============================================================================

"""
    add_component!(entity_id::EntityID, component::T) where T <: Component

Add a component to an entity. If the entity already has a component of this type,
it will be replaced.
"""
function add_component!(ark_entity::EntityID, component::T) where T <: Component
    world = World()
    if ark_entity === nothing
        ark_entity = Ark.new_entity!(world, ())
    end
    if Ark.has_components(world, ark_entity, (T,))
        Ark.set_components!(world, ark_entity, (component,))
    else
        Ark.add_components!(world, ark_entity, (component,))
    end
    return nothing
end

"""
    get_component(entity_id::EntityID, ::Type{T}) where T <: Component -> Union{T, Nothing}

Get a component of the specified type for an entity.
Returns nothing if the entity doesn't have this component type.
"""
function get_component(ark_entity::EntityID, ::Type{T})::Union{T, Nothing} where T <: Component
    world = World()
    ark_entity === nothing && return nothing
    if !Ark.has_components(world, ark_entity, (T,))
        return nothing
    end
    return Ark.get_components(world, ark_entity, (T,))[1]
end


"""
    has_component(entity_id::EntityID, ::Type{T}) where T <: Component -> Bool

Check if an entity has a component of the specified type.
"""
function has_component(ark_entity::EntityID, ::Type{T})::Bool where T <: Component
    world = World()
    ark_entity === nothing && return false
    return Ark.has_components(world, ark_entity, (T,))
end

"""
    remove_component!(entity_id::EntityID, ::Type{T}) where T <: Component -> Bool

Remove a component of the specified type from an entity.
Returns true if the component was removed, false if the entity didn't have it.

Uses swap-and-pop for O(1) removal while maintaining contiguous storage.
"""
function remove_component!(ark_entity::EntityID, ::Type{T})::Bool where T <: Component
    world = World()
    ark_entity === nothing && return false
    if !Ark.has_components(world, ark_entity, (T,))
        return false
    end
    Ark.remove_components!(world, ark_entity, (T,))
    return true
end

# =============================================================================
# Component Iteration
# =============================================================================

"""
    collect_components(::Type{T}) where T <: Component

Get all components of the specified type.
Returns an empty vector if no components of this type exist.
"""
function collect_components(::Type{T})::Vector{T} where T <: Component
    world = World()
    items = T[]
    for (entities, col) in Ark.Query(world, (T,))
        append!(items, col)
    end
    return items
end

"""
    entities_with_component(::Type{T}) where T <: Component -> Vector{EntityID}

Get all entity IDs that have a component of the specified type.
Returns an empty vector if no entities have this component type.
Note: This allocates a new vector. For hot-path iteration, use `iterate_components` instead.
"""
function entities_with_component(::Type{T})::Vector{EntityID} where T <: Component
    world = World()
    ids = Ark.Entity[]
    q = Ark.Query(world, (T,))
    for (entities, _) in q
        append!(ids, entities)
    end
    return ids
end

"""
    first_entity_with_component(::Type{T}) where T <: Component -> Union{EntityID, Nothing}

Get the first entity ID with a component of the specified type, or nothing.
Non-allocating alternative to `entities_with_component(...)[1]`.
"""
function first_entity_with_component(::Type{T})::Union{EntityID, Nothing} where T <: Component
    world = World()
    q = Ark.Query(world, (T,))
    for (entities, _) in q
        Ark.close!(q)
        return entities[1]
    end
    return nothing
end

"""
    component_count(::Type{T}) where T <: Component -> Int

Get the number of entities with a component of the specified type.
"""
function component_count(::Type{T})::Int where T <: Component
    world = World()
    q = Ark.Query(world, (T,))
    count = Ark.count_entities(q)
    Ark.close!(q)
    return count
end

"""
    iterate_components(f::Function, ::Type{T}) where T <: Component

Iterate over all (entity_id, component) pairs for a component type.
Calls f(entity_id, component) for each pair.
"""
function iterate_components(f::Function, ::Type{T}) where T <: Component
    world = World()
    for (entities, cols...) in Ark.Query(world, (T,))
        col = cols[1]
        for i in eachindex(entities)
            ark_ent = entities[i]
            f(ark_ent, col[i])
        end
    end
    return nothing
end

"""
    reset_engine_state!()

Reset all engine globals for scene switching. Clears ECS stores, entity counter,
physics world, trigger state, particle pools, terrain cache, LOD cache,
world transform cache, and asset manager cache. Audio device/context are
intentionally excluded — use `clear_audio_sources!()` separately if needed.
"""
function reset_engine_state!()
    reset_component_stores!()
    reset_physics_world!()
    reset_trigger_state!()
    reset_particle_pools!()
    reset_terrain_cache!()
    reset_lod_cache!()
    clear_world_transform_cache!()
    reset_asset_manager!()
    reset_async_loader!()
    reset_event_bus!()
    return nothing
end
