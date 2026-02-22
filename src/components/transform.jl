# Transform component with reactive state and hierarchy support

# Type aliases for double precision (used in transforms for precision)
const Vec3d = Vec{3, Float64}
const Quaterniond = Quaternion{Float64}

"""
    TransformComponent <: Component

Represents position, rotation, and scale of an entity with reactive Observable state.
Supports hierarchical transforms through parent reference.

Rotation is stored as a quaternion in (w, x, y, z) format where w is the scalar component.
"""
struct TransformComponent <: Component
    position::Observable{Vec3d}
    rotation::Observable{Quaterniond}
    scale::Observable{Vec3d}
    parent::Union{EntityID, Nothing}
end

"""
    TransformComponent(; position, rotation, scale, parent)

Constructor with automatic Observable wrapping for non-Observable arguments.
"""
function TransformComponent(;
    position::Union{Vec3d, Observable{Vec3d}} = Vec3d(0.0, 0.0, 0.0),
    rotation::Union{Quaterniond, Observable{Quaterniond}} = Quaterniond(1.0, 0.0, 0.0, 0.0),  # Identity: w=1
    scale::Union{Vec3d, Observable{Vec3d}} = Vec3d(1.0, 1.0, 1.0),
    parent::Union{EntityID, Nothing} = nothing
)
    TransformComponent(
        position isa Observable ? position : Observable(position),
        rotation isa Observable ? rotation : Observable(rotation),
        scale isa Observable ? scale : Observable(scale),
        parent
    )
end

"""
    transform(; position, rotation, scale)

Public API for creating transform components with sensible defaults.
Creates a TransformComponent with automatic Observable wrapping.

# Arguments
- `position`: Position in 3D space (default: origin)
- `rotation`: Rotation as quaternion in (w, x, y, z) format (default: identity rotation with w=1)
- `scale`: Scale factors (default: uniform scale of 1)

# Example
```julia
t = transform(position=Vec3d(1, 2, 3))
@show t.position[]  # Vec3d(1.0, 2.0, 3.0)
```
"""
function transform(;
    position::Union{Vec3d, Observable{Vec3d}} = Vec3d(0.0, 0.0, 0.0),
    rotation::Union{Quaterniond, Observable{Quaterniond}} = Quaterniond(1.0, 0.0, 0.0, 0.0),  # Identity: w=1
    scale::Union{Vec3d, Observable{Vec3d}} = Vec3d(1.0, 1.0, 1.0)
)
    return TransformComponent(
        position=position,
        rotation=rotation,
        scale=scale,
        parent=nothing
    )
end

"""
    with_parent(t::TransformComponent, parent::EntityID)

Create a copy of the transform with the specified parent entity.
Used internally during scene construction.
"""
function with_parent(t::TransformComponent, parent::EntityID)
    TransformComponent(
        t.position,
        t.rotation,
        t.scale,
        parent
    )
end

function Base.:(==)(a::TransformComponent, b::TransformComponent)
    return a.position[] == b.position[] &&
           a.rotation[] == b.rotation[] &&
           a.scale[] == b.scale[] &&
           a.parent == b.parent
end
