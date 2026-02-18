# Prefab — reusable entity factory for spawning pre-configured entities

"""
    Prefab

A reusable entity template that wraps a factory function.  The factory
accepts keyword arguments (overrides) and returns an `EntityDef`.

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
end

"""
    instantiate(prefab::Prefab; kwargs...) -> EntityDef

Call the prefab's factory with the given keyword overrides and return
the resulting `EntityDef`.
"""
function instantiate(prefab::Prefab; kwargs...)::EntityDef
    return prefab.factory(; kwargs...)
end
