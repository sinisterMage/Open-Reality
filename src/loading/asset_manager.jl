# AssetManager: caches loaded models to avoid redundant disk I/O

"""
    AssetManager

Singleton that caches loaded models (as `Vector{EntityDef}`) keyed by file path.
Use `get_model` to load-or-retrieve from cache, and `preload!` to warm the cache.
"""
mutable struct AssetManager
    model_cache::Dict{String, Vector{EntityDef}}
end

# Global singleton (lazily initialized)
const _ASSET_MANAGER = Ref{Union{AssetManager, Nothing}}(nothing)

"""
    get_asset_manager() -> AssetManager

Get or create the global AssetManager singleton.
"""
function get_asset_manager()
    if _ASSET_MANAGER[] === nothing
        _ASSET_MANAGER[] = AssetManager(Dict{String, Vector{EntityDef}}())
    end
    return _ASSET_MANAGER[]
end

"""
    reset_asset_manager!()

Reset the asset manager (useful when resetting the scene).
"""
function reset_asset_manager!()
    _ASSET_MANAGER[] = nothing
end

"""
    get_model(path::String) -> Vector{EntityDef}

Load a model from disk or return a deep copy from the cache if already loaded.
"""
function get_model(path::String)
    am = get_asset_manager()
    if !haskey(am.model_cache, path)
        am.model_cache[path] = load_model(path)
    end
    return deepcopy(am.model_cache[path])
end

"""
    preload!(path::String)

Warm the asset cache for the given model path (loads if not already cached).
"""
function preload!(path::String)
    get_model(path)
    return nothing
end
