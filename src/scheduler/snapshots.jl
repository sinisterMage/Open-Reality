# Snapshot helpers — immutable copies of component data for parallel reads.
#
# OpenReality is parallel-first: physics narrowphase, frame preparation, async
# loaders and chunk streaming all run on the EEVDF scheduler's worker pool.
# Worker tasks must not touch the global `World()` (Ark.jl is single-writer
# and component column iteration is not thread-safe), so before fanning out
# we snapshot the relevant component data into plain `Dict`s on the main
# thread. Workers then operate on those immutable copies.

"""
    TransformSnapshot

Immutable snapshot of a TransformComponent's Observable values.
Safe to read from any thread since it contains only plain values.
"""
struct TransformSnapshot
    position::Vec3d
    rotation::Quaterniond
    scale::Vec3d
end

"""
    snapshot_transforms() -> Dict{EntityID, TransformSnapshot}

Snapshot all TransformComponents into plain immutable structs.
**Must be called on the main thread** (reads Observable values).
"""
function snapshot_transforms()::Dict{EntityID, TransformSnapshot}
    world = World()
    result = Dict{EntityID, TransformSnapshot}()
    for (entities, transforms) in Ark.Query(world, (TransformComponent,))
        for i in eachindex(entities)
            tc = transforms[i]
            result[entities[i]] = TransformSnapshot(tc.position[], tc.rotation[], tc.scale[])
        end
    end
    return result
end

"""
    snapshot_components(::Type{T}) -> Dict{EntityID, T} where T <: Component

Copy all components of type T into a new Dict.
For immutable component structs this is a lightweight copy.
**Must be called on the main thread.**
"""
function snapshot_components(::Type{T})::Dict{EntityID, T} where T <: Component
    world = World()
    result = Dict{EntityID, T}()
    for (entities, components) in Ark.Query(world, (T,))
        for i in eachindex(entities)
            result[entities[i]] = components[i]
        end
    end
    return result
end
