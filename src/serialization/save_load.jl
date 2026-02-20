# Game state serialization — save/load ECS + scene graph
#
# Uses Julia's Serialization stdlib for binary format. Components with
# non-serializable fields (closures) are skipped automatically; game code
# must re-attach ScriptComponents after loading.

using Serialization

# =============================================================================
# Configuration
# =============================================================================

"""
    _NON_SERIALIZABLE_TYPES

Component types that contain non-serializable data (closures, GPU handles, etc.)
and should be excluded from save files. ScriptComponent is registered by default.
"""
const _NON_SERIALIZABLE_TYPES = Set{DataType}()

"""
    register_non_serializable!(T::DataType)

Mark a component type as non-serializable so it is skipped during `save_game`.
"""
function register_non_serializable!(T::DataType)
    push!(_NON_SERIALIZABLE_TYPES, T)
    return nothing
end

# Register built-in non-serializable types (ScriptComponent has closure fields)
push!(_NON_SERIALIZABLE_TYPES, ScriptComponent)

# =============================================================================
# Save
# =============================================================================

"""
    save_game(scene::Scene, path::String)

Serialize the current ECS state and scene graph to a binary file.

Components whose types are registered in `_NON_SERIALIZABLE_TYPES` (e.g.
`ScriptComponent`) are excluded automatically. Individual components that
fail to serialize are silently skipped.

# Example
```julia
save_game(current_scene, "saves/slot1.orsav")
```
"""
function save_game(scene::Scene, path::String)
    # Snapshot component data, skipping non-serializable types
    comp_data = Dict{String, Vector{Tuple{EntityID, Vector{UInt8}}}}()

    world = World()
    for T in COMPONENT_TYPES
        T in _NON_SERIALIZABLE_TYPES && continue

        entries = Tuple{EntityID, Vector{UInt8}}[]
        for (entities, col) in Ark.Query(world, (T,))
            for i in eachindex(entities)
                eid = entities[i]
                comp = col[i]
                try
                    buf = IOBuffer()
                    Serialization.serialize(buf, comp)
                    push!(entries, (eid, take!(buf)))
                catch
                    # Component has non-serializable fields — skip silently
                end
            end
        end

        if !isempty(entries)
            comp_data[string(T)] = entries
        end
    end

    save_data = Dict{String, Any}(
        "version"        => 1,
        "entity_counter" => ENTITY_COUNTER.next_id,
        "entities"       => scene.entities,
        "hierarchy"      => scene.hierarchy,
        "root_entities"  => scene.root_entities,
        "components"     => comp_data,
    )

    open(path, "w") do io
        Serialization.serialize(io, save_data)
    end

    return nothing
end

# =============================================================================
# Load
# =============================================================================

"""
    load_game(path::String)::Scene

Deserialize a save file and restore the ECS state and scene graph.

**Important:** This calls `reset_component_stores!()` before restoring.
Components that were not saved (e.g. `ScriptComponent`) will NOT be present
after loading — game code must re-attach them.

# Example
```julia
current_scene = load_game("saves/slot1.orsav")
```
"""
function load_game(path::String)::Scene
    save_data = open(path) do io
        Serialization.deserialize(io)
    end

    version = get(save_data, "version", 0)
    version < 1 && error("Unsupported save format version: $version")

    # Clear existing ECS state
    reset_component_stores!()

    # Restore entity counter so new entities don't collide with saved IDs
    ENTITY_COUNTER.next_id = save_data["entity_counter"]

    # Restore components
    for (type_name, entries) in save_data["components"]
        for (eid, blob) in entries
            try
                comp = Serialization.deserialize(IOBuffer(blob))
                add_component!(eid, comp)
            catch e
                @warn "Failed to deserialize component" type=type_name entity=eid exception=e
            end
        end
    end

    # Rebuild scene (the 3-arg constructor auto-derives indexed lookups)
    return Scene(
        save_data["entities"],
        save_data["hierarchy"],
        save_data["root_entities"]
    )
end
