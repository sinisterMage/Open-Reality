# Async asset loading via Channel-based worker thread
#
# Allows models to be loaded on a background thread without blocking the
# render loop. Results are polled once per frame on the main thread.

"""
    AsyncLoadRequest

A request to load a model asynchronously.
"""
struct AsyncLoadRequest
    path::String
    kwargs::Dict{Symbol, Any}
end

"""
    AsyncLoadResult

The result of an async model load — either the loaded entities or an error string.
"""
struct AsyncLoadResult
    path::String
    entities::Union{Vector{EntityDef}, Nothing}
    error::Union{String, Nothing}
end

"""
    AsyncAssetLoader

Channel-based async loader. Send requests via `load_model_async`,
poll completed results via `poll_async_loads!`.
"""
mutable struct AsyncAssetLoader
    request_channel::Channel{AsyncLoadRequest}
    result_channel::Channel{AsyncLoadResult}
    worker_task::Union{Task, Nothing}
end

"""
    AsyncAssetLoader(; buffer_size=64) -> AsyncAssetLoader

Create and start an async asset loader with a background worker thread.
"""
function AsyncAssetLoader(; buffer_size::Int=64)
    req_ch = Channel{AsyncLoadRequest}(buffer_size)
    res_ch = Channel{AsyncLoadResult}(buffer_size)
    loader = AsyncAssetLoader(req_ch, res_ch, nothing)
    loader.worker_task = Threads.@spawn _async_load_worker(req_ch, res_ch)
    return loader
end

function _async_load_worker(req_ch::Channel{AsyncLoadRequest}, res_ch::Channel{AsyncLoadResult})
    for req in req_ch
        try
            entities = load_model(req.path; req.kwargs...)
            put!(res_ch, AsyncLoadResult(req.path, entities, nothing))
        catch e
            put!(res_ch, AsyncLoadResult(req.path, nothing, sprint(showerror, e)))
        end
    end
end

"""
    load_model_async(loader::AsyncAssetLoader, path::String; kwargs...)

Queue a model for background loading. Non-blocking — returns immediately.
"""
function load_model_async(loader::AsyncAssetLoader, path::String; kwargs...)
    put!(loader.request_channel, AsyncLoadRequest(path, Dict{Symbol, Any}(kwargs)))
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

Close channels and wait for the worker to finish.
"""
function shutdown_async_loader!(loader::AsyncAssetLoader)
    close(loader.request_channel)
    if loader.worker_task !== nothing
        wait(loader.worker_task)
    end
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
