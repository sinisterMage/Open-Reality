# Async asset loading via the engine-wide EEVDFScheduler.
#
# Every `load_model_async` call submits one low-weight task (W_ASYNC_IO) to
# the global EEVDFScheduler. The task runs `load_model` on a worker thread
# and pushes its result onto a results channel that the main thread drains
# once per frame via `poll_async_loads!`.
#
# This replaces the previous "single dedicated background worker thread"
# design so that asset loading shares the same pool — and the same
# fair-share policy — as physics narrowphase, frame prep, and chunk
# streaming.

"""
    AsyncLoadResult

The result of an async model load — either the loaded entities or an
error string.
"""
struct AsyncLoadResult
    path::String
    entities::Union{Vector{EntityDef}, Nothing}
    error::Union{String, Nothing}
end

"""
    AsyncAssetLoader

Channel-collected async loader. Submit a request via
[`load_model_async`](@ref); the load runs on the engine's task scheduler.
Drain completed results via [`poll_async_loads!`](@ref) once per frame on
the main thread.
"""
mutable struct AsyncAssetLoader
    result_channel::Channel{AsyncLoadResult}
    inflight::Vector{TaskHandle}
end

"""
    AsyncAssetLoader(; buffer_size=64) -> AsyncAssetLoader

Create an async asset loader. No background thread is spawned eagerly —
work is dispatched per request to the [`EEVDFScheduler`](@ref).
"""
function AsyncAssetLoader(; buffer_size::Int=64)
    return AsyncAssetLoader(Channel{AsyncLoadResult}(buffer_size), TaskHandle[])
end

"""
    load_model_async(loader::AsyncAssetLoader, path::String; kwargs...)

Queue a model for background loading on the engine task scheduler.
Non-blocking — returns immediately.
"""
function load_model_async(loader::AsyncAssetLoader, path::String; kwargs...)
    res_ch = loader.result_channel
    handle = submit_task!(get_scheduler(), () -> begin
        try
            entities = load_model(path; kwargs...)
            put!(res_ch, AsyncLoadResult(path, entities, nothing))
        catch e
            put!(res_ch, AsyncLoadResult(path, nothing, sprint(showerror, e)))
        end
    end; weight=W_ASYNC_IO, slice=0.05)
    push!(loader.inflight, handle)
    return nothing
end

"""
    poll_async_loads!(loader::AsyncAssetLoader) -> Vector{AsyncLoadResult}

Drain all completed load results from the result channel (non-blocking).
Call once per frame on the main thread.
"""
function poll_async_loads!(loader::AsyncAssetLoader)::Vector{AsyncLoadResult}
    results = AsyncLoadResult[]
    while isready(loader.result_channel)
        push!(results, take!(loader.result_channel))
    end
    return results
end

"""
    shutdown_async_loader!(loader::AsyncAssetLoader)

Wait for any outstanding submissions to complete and close the result
channel. Outstanding results that complete during shutdown are still
deliverable via the channel until it is closed.
"""
function shutdown_async_loader!(loader::AsyncAssetLoader)
    for handle in loader.inflight
        try
            wait(handle.task.done)
        catch e
            @warn "Async loader task error during shutdown" exception=e
        end
    end
    empty!(loader.inflight)
    close(loader.result_channel)
    return nothing
end

# Global singleton (opt-in, created lazily)
const _ASYNC_LOADER = Ref{Union{AsyncAssetLoader, Nothing}}(nothing)

"""
    get_async_loader() -> AsyncAssetLoader

Get or create the global async asset loader.
"""
function get_async_loader()
    if _ASYNC_LOADER[] === nothing
        _ASYNC_LOADER[] = AsyncAssetLoader()
    end
    return _ASYNC_LOADER[]
end

"""
    reset_async_loader!()

Shutdown and reset the global async loader.
"""
function reset_async_loader!()
    if _ASYNC_LOADER[] !== nothing
        shutdown_async_loader!(_ASYNC_LOADER[])
        _ASYNC_LOADER[] = nothing
    end
end
