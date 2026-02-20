# Threading infrastructure: opt-in parallelism with snapshot-based data access
#
# Strategy: copy component data from globals on the main thread into flat
# collections, then dispatch parallel work on those copies. This avoids
# locking globals, avoids Dict concurrent-access bugs, and keeps OpenGL
# calls on the main thread.

"""
    _USE_THREADING

Global toggle for multithreaded engine paths. Off by default — enable with
`use_threading(true)`. When off, all parallel code paths fall back to the
existing serial implementations.
"""
const _USE_THREADING = Ref(false)

"""
    use_threading(val::Bool=true)

Enable or disable engine multithreading. Must be called before `render()`.
Requires Julia to be started with multiple threads (`julia -t auto` or
`julia -t N`).
"""
function use_threading(val::Bool=true)
    _USE_THREADING[] = val
    if val && Threads.nthreads() <= 1
        @warn "use_threading(true) called but Julia has only 1 thread. Start with `julia -t auto` for parallelism."
    end
end

"""
    threading_enabled() -> Bool

Check whether multithreading is enabled and multiple threads are available.
"""
@inline function threading_enabled()::Bool
    return _USE_THREADING[] && Threads.nthreads() > 1
end

# =============================================================================
# Snapshot types — immutable copies of component data for parallel reads
# =============================================================================

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
