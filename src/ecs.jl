# Entity Component System Core
# Implements entity ID generation, component storage, and component operations

# =============================================================================
# Entity ID System
# =============================================================================

"""
    EntityID

Unique identifier for entities in the ECS.
"""
const EntityID = UInt64

# Internal alias for backward compatibility
const EntityId = EntityID

"""
    EntityCounter

Mutable counter for generating unique entity IDs.
"""
mutable struct EntityCounter
    next_id::EntityId
end

"""
Global entity counter for unique ID generation.
"""
const ENTITY_COUNTER = EntityCounter(EntityId(1))

"""
    create_entity_id() -> EntityID

Create a new unique entity ID using the global counter.
"""
function create_entity_id()::EntityID
    id = ENTITY_COUNTER.next_id
    ENTITY_COUNTER.next_id += 1
    return id
end

"""
    reset_entity_counter!()

Reset the global entity counter. Useful for testing.
"""
function reset_entity_counter!()
    ENTITY_COUNTER.next_id = EntityId(1)
end

# =============================================================================
# World (for Scene compatibility)
# =============================================================================

"""
    World

Container for all entities and their components.
Uses its own internal counter for entity creation.
"""
mutable struct World
    next_entity_id::EntityId

    World() = new(EntityId(1))
end

"""
    create_entity!(world::World) -> EntityID

Create a new entity in the world using the world's internal counter.
"""
function create_entity!(world::World)
    id = world.next_entity_id
    world.next_entity_id += 1
    return id
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
# Component Storage
# =============================================================================

"""
    ComponentStore{T <: Component}

Type-specific storage for components. Stores components in a contiguous array
and maintains a mapping from entity IDs to array indices.
"""
mutable struct ComponentStore{T <: Component}
    components::Vector{T}
    entity_map::Dict{EntityId, Int}  # EntityId → index in components array
    index_to_entity::Dict{Int, EntityId}  # Reverse mapping for removal

    ComponentStore{T}() where T <: Component = new{T}(T[], Dict{EntityId, Int}(), Dict{Int, EntityId}())
end

"""
Global registry of component stores, keyed by component type.
"""
const COMPONENT_STORES = Dict{DataType, ComponentStore{<:Component}}()

"""
    reset_component_stores!()

Reset all component stores. Useful for testing.
"""
const _RESET_HOOKS = Function[]

function reset_component_stores!()
    empty!(COMPONENT_STORES)
    for hook in _RESET_HOOKS
        hook()
    end
end

"""
    register_component_type(::Type{T}) where T <: Component

Register a component type in the global registry.
Creates a new ComponentStore if one doesn't already exist.
"""
function register_component_type(::Type{T}) where T <: Component
    if !haskey(COMPONENT_STORES, T)
        COMPONENT_STORES[T] = ComponentStore{T}()
    end
    return nothing
end

"""
    get_component_store(::Type{T}) where T <: Component -> Union{ComponentStore{T}, Nothing}

Get the component store for a specific type, or nothing if not registered.
"""
function get_component_store(::Type{T})::Union{ComponentStore{T}, Nothing} where T <: Component
    return get(COMPONENT_STORES, T, nothing)
end

# =============================================================================
# Component Operations
# =============================================================================

"""
    add_component!(entity_id::EntityID, component::T) where T <: Component

Add a component to an entity. If the entity already has a component of this type,
it will be replaced.
"""
function add_component!(entity_id::EntityID, component::T) where T <: Component
    # Ensure component type is registered
    register_component_type(T)

    store = COMPONENT_STORES[T]

    # Check if entity already has this component type
    if haskey(store.entity_map, entity_id)
        # Replace existing component
        idx = store.entity_map[entity_id]
        store.components[idx] = component
    else
        # Add new component
        push!(store.components, component)
        idx = length(store.components)
        store.entity_map[entity_id] = idx
        store.index_to_entity[idx] = entity_id
    end

    return nothing
end

"""
    get_component(entity_id::EntityID, ::Type{T}) where T <: Component -> Union{T, Nothing}

Get a component of the specified type for an entity.
Returns nothing if the entity doesn't have this component type.
"""
function get_component(entity_id::EntityID, ::Type{T})::Union{T, Nothing} where T <: Component
    store = get_component_store(T)
    if store === nothing
        return nothing
    end

    idx = get(store.entity_map, entity_id, nothing)
    return idx === nothing ? nothing : store.components[idx]
end

"""
    has_component(entity_id::EntityID, ::Type{T}) where T <: Component -> Bool

Check if an entity has a component of the specified type.
"""
function has_component(entity_id::EntityID, ::Type{T})::Bool where T <: Component
    store = get_component_store(T)
    if store === nothing
        return false
    end
    return haskey(store.entity_map, entity_id)
end

"""
    remove_component!(entity_id::EntityID, ::Type{T}) where T <: Component -> Bool

Remove a component of the specified type from an entity.
Returns true if the component was removed, false if the entity didn't have it.

Uses swap-and-pop for O(1) removal while maintaining contiguous storage.
"""
function remove_component!(entity_id::EntityID, ::Type{T})::Bool where T <: Component
    store = get_component_store(T)
    if store === nothing
        return false
    end

    idx = get(store.entity_map, entity_id, nothing)
    if idx === nothing
        return false
    end

    # Swap-and-pop removal for O(1) complexity
    last_idx = length(store.components)

    if idx != last_idx
        # Move last element to the removed position
        last_entity = store.index_to_entity[last_idx]
        store.components[idx] = store.components[last_idx]
        store.entity_map[last_entity] = idx
        store.index_to_entity[idx] = last_entity
    end

    # Remove the last element
    pop!(store.components)
    delete!(store.entity_map, entity_id)
    delete!(store.index_to_entity, last_idx)

    return true
end

# =============================================================================
# Component Iteration
# =============================================================================

"""
    collect_components(::Type{T}) where T <: Component -> Vector{T}

Get all components of the specified type.
Returns an empty vector if no components of this type exist.
"""
function collect_components(::Type{T})::Vector{T} where T <: Component
    store = get_component_store(T)
    if store === nothing
        return T[]
    end
    return store.components
end

"""
    entities_with_component(::Type{T}) where T <: Component -> Vector{EntityID}

Get all entity IDs that have a component of the specified type.
Returns an empty vector if no entities have this component type.
Note: This allocates a new vector. For hot-path iteration, use `iterate_components` instead.
"""
function entities_with_component(::Type{T})::Vector{EntityID} where T <: Component
    store = get_component_store(T)
    if store === nothing
        return EntityID[]
    end
    return collect(keys(store.entity_map))
end

"""
    first_entity_with_component(::Type{T}) where T <: Component -> Union{EntityID, Nothing}

Get the first entity ID with a component of the specified type, or nothing.
Non-allocating alternative to `entities_with_component(...)[1]`.
"""
function first_entity_with_component(::Type{T})::Union{EntityID, Nothing} where T <: Component
    store = get_component_store(T)
    store === nothing && return nothing
    isempty(store.entity_map) && return nothing
    return first(keys(store.entity_map))
end

"""
    component_count(::Type{T}) where T <: Component -> Int

Get the number of entities with a component of the specified type.
"""
function component_count(::Type{T})::Int where T <: Component
    store = get_component_store(T)
    if store === nothing
        return 0
    end
    return length(store.components)
end

"""
    iterate_components(f::Function, ::Type{T}) where T <: Component

Iterate over all (entity_id, component) pairs for a component type.
Calls f(entity_id, component) for each pair.
"""
function iterate_components(f::Function, ::Type{T}) where T <: Component
    store = get_component_store(T)
    if store === nothing
        return nothing
    end

    for (entity_id, idx) in store.entity_map
        f(entity_id, store.components[idx])
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
    reset_entity_counter!()
    reset_physics_world!()
    reset_trigger_state!()
    reset_particle_pools!()
    reset_terrain_cache!()
    reset_lod_cache!()
    clear_world_transform_cache!()
    reset_asset_manager!()
    reset_event_bus!()
    # AnimationBlendTreeComponent: no global stores — state is per-component,
    # cleared automatically by reset_component_stores!() above.
    return nothing
end
