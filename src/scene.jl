# Scene graph management
# Implements immutable scene structure with functional transformations

# =============================================================================
# Immutable Scene Structure
# =============================================================================

"""
    Scene

Immutable scene structure containing entities and their hierarchies.
Following the functional paradigm, all operations return new scenes.

Maintains indexed lookup structures for O(1) queries:
- `entity_set` — O(1) `has_entity` checks (vs O(N) linear scan on a Vector)
- `parent_map` — O(1) `get_parent` lookups (vs O(N·M) hierarchy scan)
- `root_set`  — O(1) `is_root` checks
"""
struct Scene
    entities::Vector{EntityID}
    hierarchy::Dict{EntityID, Vector{EntityID}}  # parent → children
    root_entities::Vector{EntityID}  # Entities with no parent
    entity_set::Set{EntityID}                    # O(1) entity membership
    parent_map::Dict{EntityID, EntityID}         # child → parent, O(1) parent lookup
    root_set::Set{EntityID}                      # O(1) root membership
end

"""
    Scene(entities, hierarchy, root_entities)

Backward-compatible 3-arg constructor. Automatically derives the indexed
lookup fields (`entity_set`, `parent_map`, `root_set`) from the primary data.
"""
function Scene(entities::Vector{EntityID},
               hierarchy::Dict{EntityID, Vector{EntityID}},
               root_entities::Vector{EntityID})
    entity_set = Set{EntityID}(entities)
    parent_map = Dict{EntityID, EntityID}()
    for (parent, children) in hierarchy
        for child in children
            parent_map[child] = parent
        end
    end
    root_set = Set{EntityID}(root_entities)
    Scene(entities, hierarchy, root_entities, entity_set, parent_map, root_set)
end

"""
    Scene()

Create an empty scene.
"""
function Scene()
    Scene(
        EntityID[],
        Dict{EntityID, Vector{EntityID}}(),
        EntityID[]
    )
end

# =============================================================================
# Functional Scene Transformations
# =============================================================================

"""
    add_entity(scene::Scene, entity_id::EntityID, parent::Union{EntityID, Nothing}=nothing)::Scene

Add an entity to the scene. Returns a new Scene without modifying the original.

If parent is nothing, the entity becomes a root entity.
If parent is specified, the entity becomes a child of that parent.
"""
function add_entity(scene::Scene, entity_id::EntityID, parent::Union{EntityID, Nothing}=nothing)::Scene
    new_entities = [scene.entities; entity_id]
    new_hierarchy = copy(scene.hierarchy)
    new_roots = copy(scene.root_entities)

    if parent === nothing
        push!(new_roots, entity_id)
    else
        if !haskey(new_hierarchy, parent)
            new_hierarchy[parent] = EntityID[]
        else
            # Create a copy of the children vector to maintain immutability
            new_hierarchy[parent] = copy(new_hierarchy[parent])
        end
        push!(new_hierarchy[parent], entity_id)
    end

    Scene(new_entities, new_hierarchy, new_roots)
end

"""
    remove_entity(scene::Scene, entity_id::EntityID)::Scene

Remove an entity from the scene. Returns a new Scene without modifying the original.
Also removes all children of the entity recursively and purges their ECS components.
"""
function remove_entity(scene::Scene, entity_id::EntityID)::Scene
    # Collect all entities to remove (entity and its descendants)
    entities_to_remove = Set{EntityID}()
    collect_descendants!(entities_to_remove, scene, entity_id)

    # Queue GPU resource cleanup for removed entities
    queue_gpu_cleanup!(entities_to_remove)

    # Purge ECS components for all entities being removed
    world = World()
    for eid in entities_to_remove
        Ark.remove_entity!(world, eid)
    end

    # Filter out removed entities
    new_entities = filter(e -> !(e in entities_to_remove), scene.entities)

    # Update hierarchy - remove children mappings for removed entities
    new_hierarchy = Dict{EntityID, Vector{EntityID}}()
    for (parent, children) in scene.hierarchy
        if !(parent in entities_to_remove)
            new_children = filter(c -> !(c in entities_to_remove), children)
            if !isempty(new_children)
                new_hierarchy[parent] = new_children
            end
        end
    end

    # Update root entities
    new_roots = filter(e -> !(e in entities_to_remove), scene.root_entities)

    Scene(new_entities, new_hierarchy, new_roots)
end

"""
    destroy_entity!(scene::Scene, entity_id::EntityID; ctx=nothing)::Scene

Remove an entity and all its descendants from the scene, firing `on_destroy`
callbacks on any `ScriptComponent` before removal.

Pass `ctx` to forward a `GameContext` to `on_destroy` callbacks. When omitted
(or `nothing`), `on_destroy` receives `nothing` as its second argument.

Returns a new Scene (via `remove_entity`).
"""
function destroy_entity!(scene::Scene, entity_id::EntityID; ctx=nothing)::Scene
    descendants = Set{EntityID}()
    collect_descendants!(descendants, scene, entity_id)

    for eid in descendants
        comp = get_component(eid, ScriptComponent)
        if comp !== nothing && comp.on_destroy !== nothing
            try
                comp.on_destroy(eid, ctx)
            catch e
                @warn "ScriptComponent on_destroy error" exception=e
            end
        end
    end

    return remove_entity(scene, entity_id)
end

"""
    collect_descendants!(result::Set{EntityID}, scene::Scene, entity_id::EntityID)

Helper function to collect an entity and all its descendants into a set.
"""
function collect_descendants!(result::Set{EntityID}, scene::Scene, entity_id::EntityID)
    push!(result, entity_id)
    children = get(scene.hierarchy, entity_id, EntityID[])
    for child in children
        collect_descendants!(result, scene, child)
    end
end

# =============================================================================
# Scene Construction API
# =============================================================================

"""
    EntityDef

Entity definition type for declarative scene construction.
Contains components and child entity definitions.
"""
const EntityDef = NamedTuple{(:components, :children), Tuple{Vector{Any}, Vector{Any}}}

"""
    entity(components::Vector; children::Vector=[])::EntityDef

Create an entity definition with the given components and optional children.

# Example
```julia
entity([TransformComponent(), MeshComponent()], children=[
    entity([TransformComponent()]),
    entity([TransformComponent()])
])
```
"""
function entity(components::Vector; children::Vector=[])::EntityDef
    return (components=convert(Vector{Any}, components), children=convert(Vector{Any}, children))
end

"""
    entity(component::Component; children::Vector=[])::EntityDef

Convenience method to create an entity with a single component.
"""
function entity(component::Component; children::Vector=[])::EntityDef
    return entity([component]; children=children)
end

"""
    scene(entity_defs::Vector)::Scene

Create a Scene from a vector of entity definitions.

# Example
```julia
s = scene([
    entity([TransformComponent(position=Point3f(0, 0, 0))], children=[
        entity([TransformComponent(position=Point3f(1, 0, 0))]),
        entity([TransformComponent(position=Point3f(-1, 0, 0))])
    ]),
    entity([CameraComponent()])
])
```
"""
function scene(entity_defs::Vector)::Scene
    s = Scene()

    for entity_def in entity_defs
        s = add_entity_from_def(s, entity_def, nothing)
    end

    # Replace placeholder DFS-order indices in AnimationChannels with real EntityIDs.
    # Loaders (e.g. load_gltf) store 1-based DFS positions as placeholder EntityIDs;
    # s.entities is in DFS creation order, so the mapping is direct.
    _remap_animation_targets!(s.entities)

    # Apply deferred skin components from glTF loading.
    # These need entity ID remapping just like animations.
    _apply_deferred_skin_components!(entity_defs, s.entities)

    return s
end

"""
    scene()

Create an empty scene.
"""
scene() = Scene()

"""
    scene(f::Function)

Create a scene using a builder function. The builder receives an empty scene
and must return the constructed `Scene`.

# Example
```julia
s = scene() do s
    s = add_entity(s, create_entity_id())
    return s
end
```
"""
function scene(f::Function)
    s = f(Scene())
    return s
end

"""
    add_entity_from_def(scene::Scene, entity_def::EntityDef, parent::Union{EntityID, Nothing})::Scene

Process an entity definition recursively, adding entities to the scene
and their components to the ECS storage.

When a parent is specified, TransformComponent is updated to include the parent
reference for hierarchical transform calculation.
"""
function add_entity_from_def(scene::Scene, entity_def::EntityDef, parent::Union{EntityID, Nothing})::Scene
    # Create entity ID
    entity_id = create_entity!(World())

    # Add components to ECS storage
    for component in entity_def.components
        if component isa Component
            # If this is a TransformComponent and we have a parent,
            # create a new transform with the parent reference set
            if component isa TransformComponent && parent !== nothing
                component = with_parent(component, parent)
            end
            add_component!(entity_id, component)
        end
        # Deferred components from glTF skin loading are collected for post-processing
        # (handled by _apply_deferred_skin_components! after scene creation)
    end

    # Add entity to scene
    scene = add_entity(scene, entity_id, parent)

    # Process children recursively
    for child_def in entity_def.children
        if child_def isa EntityDef
            scene = add_entity_from_def(scene, child_def, entity_id)
        end
    end

    return scene
end

# =============================================================================
# Animation Target Remapping
# =============================================================================

"""
    _remap_animation_targets!(entity_ids::Vector{EntityID})

Replace placeholder entity-def indices stored in AnimationChannel.target_entity
with the real EntityIDs that were assigned during scene creation.

Placeholder IDs use the convention `EntityID(def_index)` where `def_index` is
the 1-based position in the original `entity_defs` vector.
"""
function _remap_animation_targets!(entity_ids::Vector{EntityID})
    isempty(entity_ids) && return nothing

    for eid in entity_ids
        anim = get_component(eid, AnimationComponent)
        anim === nothing && continue

        new_clips = AnimationClip[]
        changed = false

        for clip in anim.clips
            new_channels = AnimationChannel[]
            for ch in clip.channels
                placeholder_idx = Int(ch.target_entity)
                if placeholder_idx >= 1 && placeholder_idx <= length(entity_ids)
                    real_id = entity_ids[placeholder_idx]
                    if real_id != ch.target_entity
                        push!(new_channels, AnimationChannel(
                            real_id, ch.target_property, ch.times, ch.values, ch.interpolation
                        ))
                        changed = true
                        continue
                    end
                end
                push!(new_channels, ch)
            end
            push!(new_clips, AnimationClip(clip.name, new_channels, clip.duration))
        end

        if changed
            anim.clips = new_clips
        end
    end

    return nothing
end

# =============================================================================
# Deferred Skin Component Application
# =============================================================================

"""
    _apply_deferred_skin_components!(entity_defs, real_entity_ids)

Process _DeferredComponent items in entity definition components.
These are created by the glTF loader for SkinnedMeshComponent instances that
need entity ID remapping (bone_entities use placeholder DFS indices).
"""
function _apply_deferred_skin_components!(entity_defs::Vector, real_entity_ids::Vector{EntityID})
    isempty(real_entity_ids) && return nothing

    for entity_def in entity_defs
        !(entity_def isa NamedTuple) && continue
        !hasproperty(entity_def, :components) && continue

        for comp in entity_def.components
            # Check for _DeferredComponent type (from gltf_loader.jl)
            if hasproperty(comp, :target_entity) && hasproperty(comp, :component) && !(comp isa Component)
                placeholder_idx = Int(comp.target_entity)
                if placeholder_idx >= 1 && placeholder_idx <= length(real_entity_ids)
                    real_target = real_entity_ids[placeholder_idx]
                    skin_comp = comp.component

                    # Remap bone_entities from placeholder indices to real IDs
                    if hasproperty(skin_comp, :bone_entities)
                        remapped_bones = EntityID[]
                        for bone_placeholder in skin_comp.bone_entities
                            bone_idx = Int(bone_placeholder)
                            if bone_idx >= 1 && bone_idx <= length(real_entity_ids)
                                push!(remapped_bones, real_entity_ids[bone_idx])
                            end
                        end
                        skin_comp.bone_entities = remapped_bones
                        if length(skin_comp.bone_matrices) != length(remapped_bones)
                            skin_comp.bone_matrices = fill(Mat4f(I), length(remapped_bones))
                        end
                    end

                    add_component!(real_target, skin_comp)
                end
            end
        end
    end

    return nothing
end

# =============================================================================
# Scene Traversal
# =============================================================================

"""
    get_children(scene::Scene, entity_id::EntityID)::Vector{EntityID}

Get the direct children of an entity in the scene.
Returns an empty vector if the entity has no children.
"""
function get_children(scene::Scene, entity_id::EntityID)::Vector{EntityID}
    return get(scene.hierarchy, entity_id, EntityID[])
end

"""
    get_parent(scene::Scene, entity_id::EntityID)::Union{EntityID, Nothing}

Get the parent of an entity in the scene.
Returns nothing if the entity is a root entity.
"""
function get_parent(scene::Scene, entity_id::EntityID)::Union{EntityID, Nothing}
    return get(scene.parent_map, entity_id, nothing)
end

"""
    has_entity(scene::Scene, entity_id::EntityID)::Bool

Check if an entity exists in the scene.
"""
function has_entity(scene::Scene, entity_id::EntityID)::Bool
    return entity_id in scene.entity_set
end

"""
    is_root(scene::Scene, entity_id::EntityID)::Bool

Check if an entity is a root entity (has no parent).
"""
function is_root(scene::Scene, entity_id::EntityID)::Bool
    return entity_id in scene.root_set
end

"""
    traverse_scene(scene::Scene, visitor::Function)

Traverse the entire scene depth-first, calling visitor(entity_id) for each entity.
"""
function traverse_scene(scene::Scene, visitor::Function)
    for root in scene.root_entities
        traverse_entity(scene, root, visitor)
    end
end

"""
    traverse_entity(scene::Scene, entity_id::EntityID, visitor::Function)

Traverse an entity and its descendants depth-first, calling visitor(entity_id) for each.
"""
function traverse_entity(scene::Scene, entity_id::EntityID, visitor::Function)
    visitor(entity_id)

    for child in get_children(scene, entity_id)
        traverse_entity(scene, child, visitor)
    end
end

"""
    traverse_scene_with_depth(scene::Scene, visitor::Function)

Traverse the scene depth-first, calling visitor(entity_id, depth) for each entity.
The depth starts at 0 for root entities.
"""
function traverse_scene_with_depth(scene::Scene, visitor::Function)
    for root in scene.root_entities
        traverse_entity_with_depth(scene, root, 0, visitor)
    end
end

"""
    traverse_entity_with_depth(scene::Scene, entity_id::EntityID, depth::Int, visitor::Function)

Traverse an entity and its descendants depth-first with depth tracking.
"""
function traverse_entity_with_depth(scene::Scene, entity_id::EntityID, depth::Int, visitor::Function)
    visitor(entity_id, depth)

    for child in get_children(scene, entity_id)
        traverse_entity_with_depth(scene, child, depth + 1, visitor)
    end
end

"""
    get_all_descendants(scene::Scene, entity_id::EntityID)::Vector{EntityID}

Get all descendants of an entity (children, grandchildren, etc.).
"""
function get_all_descendants(scene::Scene, entity_id::EntityID)::Vector{EntityID}
    descendants = EntityID[]
    for child in get_children(scene, entity_id)
        push!(descendants, child)
        append!(descendants, get_all_descendants(scene, child))
    end
    return descendants
end

"""
    get_ancestors(scene::Scene, entity_id::EntityID)::Vector{EntityID}

Get all ancestors of an entity (parent, grandparent, etc.), ordered from immediate parent to root.
"""
function get_ancestors(scene::Scene, entity_id::EntityID)::Vector{EntityID}
    ancestors = EntityID[]
    current = get_parent(scene, entity_id)
    while current !== nothing
        push!(ancestors, current)
        current = get_parent(scene, current)
    end
    return ancestors
end

"""
    entity_count(scene::Scene)::Int

Get the total number of entities in the scene.
"""
function entity_count(scene::Scene)::Int
    return length(scene.entities)
end

# =============================================================================
# Backward Compatibility - Entity creation on mutable scene reference
# =============================================================================

"""
    entity(scene::Scene)

Create an empty entity as a root in the given scene.
This version is for backward compatibility with the do-block syntax.
Note: This returns the entity ID but doesn't update the scene (use scene(defs) instead).
"""
function entity(scene_ref::Scene)
    @warn "Using entity(scene::Scene) is deprecated. Use scene([entity(...)]) syntax instead."
    id = create_entity!(World())
    return id
end

"""
    entity(scene::Scene, f::Function)

Create an entity in the scene with a setup function.
Deprecated: Use the new scene([entity(...)]) syntax instead.
"""
function entity(scene_ref::Scene, f::Function)
    @warn "Using entity(scene::Scene, f::Function) is deprecated. Use scene([entity(...)]) syntax instead."
    id = create_entity!(World())
    f(id)
    return id
end
