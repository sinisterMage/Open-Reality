# Simulation islands: connected components of contacting bodies
# When all bodies in an island are below the sleep threshold, the island sleeps.

"""
    SimulationIsland

A group of bodies connected by contacts or joints.
All bodies in a sleeping island are skipped during simulation.
"""
struct SimulationIsland
    entities::Vector{EntityID}
end

"""
    build_islands(manifolds::Vector{ContactManifold}, constraints::Vector{JointConstraint}) -> Vector{SimulationIsland}

Build simulation islands from the contact graph.
Uses union-find (disjoint set) to group connected dynamic bodies.
"""
function build_islands(manifolds::Vector{ContactManifold}, constraints::Vector{JointConstraint})
    # Union-Find with path compression and union by rank
    parent = Dict{EntityID, EntityID}()
    rank = Dict{EntityID, Int}()

    function find_root(x::EntityID)
        if !haskey(parent, x)
            parent[x] = x
            rank[x] = 0
        end
        while parent[x] != x
            parent[x] = parent[parent[x]]  # path compression
            x = parent[x]
        end
        return x
    end

    function union!(a::EntityID, b::EntityID)
        ra = find_root(a)
        rb = find_root(b)
        ra == rb && return
        # Union by rank
        if rank[ra] < rank[rb]
            parent[ra] = rb
        elseif rank[ra] > rank[rb]
            parent[rb] = ra
        else
            parent[rb] = ra
            rank[ra] += 1
        end
    end

    # Add all dynamic bodies
    iterate_components(RigidBodyComponent) do eid, rb
        if rb.body_type == BODY_DYNAMIC
            if !haskey(parent, eid)
                parent[eid] = eid
                rank[eid] = 0
            end
        end
    end

    # Union bodies connected by contacts
    for manifold in manifolds
        rb_a = get_component(manifold.entity_a, RigidBodyComponent)
        rb_b = get_component(manifold.entity_b, RigidBodyComponent)
        # Only union dynamic bodies; static/kinematic don't join islands
        a_dynamic = rb_a !== nothing && rb_a.body_type == BODY_DYNAMIC
        b_dynamic = rb_b !== nothing && rb_b.body_type == BODY_DYNAMIC
        if a_dynamic && b_dynamic
            union!(manifold.entity_a, manifold.entity_b)
        end
    end

    # Union bodies connected by joints
    for joint in constraints
        a_dynamic = haskey(parent, joint.entity_a)
        b_dynamic = haskey(parent, joint.entity_b)
        if a_dynamic && b_dynamic
            union!(joint.entity_a, joint.entity_b)
        end
    end

    # Group by root
    island_map = Dict{EntityID, Vector{EntityID}}()
    for eid in keys(parent)
        root = find_root(eid)
        if !haskey(island_map, root)
            island_map[root] = EntityID[]
        end
        push!(island_map[root], eid)
    end

    return [SimulationIsland(entities) for entities in values(island_map)]
end

"""
    update_islands!(world, dt::Float64)

Build simulation islands and manage sleeping.
Bodies below the velocity threshold accumulate sleep time.
When all bodies in an island exceed the sleep timer, the island sleeps.
Sleeping bodies are woken when a new contact or external force is detected.
"""
function update_islands!(world::Any, dt::Float64)
    sleep_threshold_linear = world.config.sleep_linear_threshold
    sleep_threshold_angular = world.config.sleep_angular_threshold
    sleep_time_threshold = world.config.sleep_time

    iterate_components(RigidBodyComponent) do eid, rb
        rb.body_type == BODY_DYNAMIC || return

        lin_speed = vec3d_length(rb.velocity)
        ang_speed = vec3d_length(rb.angular_velocity)

        if lin_speed < sleep_threshold_linear && ang_speed < sleep_threshold_angular
            rb.sleep_timer += dt
            if rb.sleep_timer >= sleep_time_threshold
                rb.sleeping = true
                rb.velocity = Vec3d(0, 0, 0)
                rb.angular_velocity = Vec3d(0, 0, 0)
            end
        else
            rb.sleep_timer = 0.0
            rb.sleeping = false
        end
    end
end
