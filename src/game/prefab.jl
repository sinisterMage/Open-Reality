# Prefab — reusable entity factory for spawning pre-configured entities

"""
    Prefab

A reusable entity template that wraps a factory function with default
keyword arguments.  The factory accepts keyword arguments (overrides)
and returns an `EntityDef`.

# Example
```julia
pf = Prefab(; position=Vec3d(0,0,0)) do (; position)
    entity([TransformComponent(; position)])
end
spawn!(ctx, pf; position=Vec3d(1, 2, 3))
```
"""
struct Prefab
    factory::Function
    defaults::Dict{Symbol, Any}
end

function Prefab(factory::Function; kwargs...)
    Prefab(factory, Dict{Symbol, Any}(kwargs...))
end

"""
    instantiate(prefab::Prefab; kwargs...) -> EntityDef

Call the prefab's factory with the given keyword overrides merged over
the prefab's defaults and return the resulting `EntityDef`.
"""
function instantiate(prefab::Prefab; kwargs...)::EntityDef
    merged = merge(prefab.defaults, Dict{Symbol, Any}(kwargs...))
    return prefab.factory((; merged...))
end
