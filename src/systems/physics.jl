# Physics system: delegates to PhysicsWorld for impulse-based simulation
# Preserves the public update_physics!(dt) API for backward compatibility

"""
    PhysicsConfig

Legacy physics configuration (kept for backward compatibility).
Use PhysicsWorldConfig for the new physics system.
"""
struct PhysicsConfig
    gravity::Vec3d

    PhysicsConfig(;
        gravity::Vec3d = Vec3d(0, -9.81, 0)
    ) = new(gravity)
end

const DEFAULT_PHYSICS_CONFIG = PhysicsConfig()

# Legacy types kept for backward compatibility with tests
struct WorldAABB
    min_pt::Vec3d
    max_pt::Vec3d
end

struct CollisionResult
    entity_a::EntityID
    entity_b::EntityID
    normal::Vec3d
    penetration::Float64
end

"""
    get_world_aabb(entity_id::EntityID) -> Union{WorldAABB, Nothing}

Compute the world-space AABB for an entity's collider.
Legacy API — wraps the new physics AABB computation.
"""
function get_world_aabb(entity_id::EntityID)
    aabb = get_entity_physics_aabb(entity_id)
    aabb === nothing && return nothing
    return WorldAABB(aabb.min_pt, aabb.max_pt)
end

"""
    aabb_overlap(a::WorldAABB, b::WorldAABB) -> Bool

Test if two world-space AABBs overlap. Legacy API.
"""
function aabb_overlap(a::WorldAABB, b::WorldAABB)::Bool
    return a.min_pt[1] <= b.max_pt[1] && a.max_pt[1] >= b.min_pt[1] &&
           a.min_pt[2] <= b.max_pt[2] && a.max_pt[2] >= b.min_pt[2] &&
           a.min_pt[3] <= b.max_pt[3] && a.max_pt[3] >= b.min_pt[3]
end

"""
    update_physics!(dt::Float64; config::PhysicsConfig = DEFAULT_PHYSICS_CONFIG)

Run one physics frame. Delegates to the PhysicsWorld impulse-based solver.
Backward compatible: existing scenes work unchanged.
"""
function update_physics!(dt::Float64; config::PhysicsConfig = DEFAULT_PHYSICS_CONFIG)
    world_config = PhysicsWorldConfig(gravity=config.gravity)
    world = get_physics_world(config=world_config)

    # Initialize inertia for any new entities that need it
    iterate_components(RigidBodyComponent) do eid, rb
        if rb.body_type == BODY_DYNAMIC && rb.inv_inertia_local == SMatrix{3,3,Float64,9}(0,0,0,0,0,0,0,0,0)
            initialize_rigidbody_inertia!(eid)
        end
    end

    step!(world, dt)
end
