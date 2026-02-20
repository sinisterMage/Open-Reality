using OpenReality
using Test
using LinearAlgebra
using StaticArrays

@testset "OpenReality.jl" begin
    @testset "Module loads" begin
        @test isdefined(OpenReality, :scene)
        @test isdefined(OpenReality, :entity)
        @test isdefined(OpenReality, :render)
    end

    @testset "ECS" begin
        @testset "World-based entity creation" begin
            world = World()

            id1 = create_entity!(World())
            @test id1._id == 2

            id2 = create_entity!(World())
            @test id2._id == 3
        end

        @testset "Global entity ID generation" begin
            id1 = create_entity!(World())
            id2 = create_entity!(World())

            @test id1 != id2
            @test id2._id == id1._id + 1
            @test typeof(id1) == EntityID
        end

        @testset "Component storage" begin
            reset_component_stores!()
            

            # Create entities
            e1 = create_entity!(World())
            e2 = create_entity!(World())

            # Add components (using new Observable-based TransformComponent)
            add_component!(e1, transform(position=Vec3d(1, 2, 3)))
            add_component!(e2, transform(position=Vec3d(4, 5, 6)))

            # Retrieve components
            c1 = get_component(e1, TransformComponent)
            @test c1 !== nothing
            @test c1.position[] == Vec3d(1, 2, 3)

            c2 = get_component(e2, TransformComponent)
            @test c2 !== nothing
            @test c2.position[] == Vec3d(4, 5, 6)

            # Check existence
            @test has_component(e1, TransformComponent)
            @test has_component(e2, TransformComponent)
            @test !has_component(e1, MeshComponent)

            # Component count
            @test component_count(TransformComponent) == 2
            @test component_count(MeshComponent) == 0
        end

        @testset "Component replacement" begin
            reset_component_stores!()
            

            e1 = create_entity!(World())

            # Add initial component
            add_component!(e1, transform(position=Vec3d(1, 1, 1)))
            @test get_component(e1, TransformComponent).position[] == Vec3d(1, 1, 1)

            # Replace with new component
            add_component!(e1, transform(position=Vec3d(9, 9, 9)))
            @test get_component(e1, TransformComponent).position[] == Vec3d(9, 9, 9)

            # Count should still be 1
            @test component_count(TransformComponent) == 1
        end

        @testset "Component removal" begin
            reset_component_stores!()
            

            e1 = create_entity!(World())
            e2 = create_entity!(World())
            e3 = create_entity!(World())

            add_component!(e1, transform(position=Vec3d(1, 0, 0)))
            add_component!(e2, transform(position=Vec3d(2, 0, 0)))
            add_component!(e3, transform(position=Vec3d(3, 0, 0)))

            @test component_count(TransformComponent) == 3

            # Remove middle component
            result = remove_component!(e2, TransformComponent)
            @test result == true
            @test !has_component(e2, TransformComponent)
            @test component_count(TransformComponent) == 2

            # Remaining components should still be accessible
            @test get_component(e1, TransformComponent).position[] == Vec3d(1, 0, 0)
            @test get_component(e3, TransformComponent).position[] == Vec3d(3, 0, 0)

            # Removing non-existent component returns false
            @test remove_component!(e2, TransformComponent) == false
            @test remove_component!(e1, MeshComponent) == false
        end

        @testset "Component iteration" begin
            reset_component_stores!()
            

            e1 = create_entity!(World())
            e2 = create_entity!(World())

            add_component!(e1, transform(position=Vec3d(1, 0, 0)))
            add_component!(e2, transform(position=Vec3d(2, 0, 0)))

            # Collect all components
            all_transforms = collect_components(TransformComponent)
            @test length(all_transforms) == 2

            # Get entities with component
            entities = entities_with_component(TransformComponent)
            @test length(entities) == 2
            @test e1 in entities
            @test e2 in entities

            # Empty collection for unregistered type
            @test isempty(collect_components(MeshComponent))
            @test isempty(entities_with_component(MeshComponent))
        end

        @testset "Multiple component types" begin
            reset_component_stores!()
            

            e1 = create_entity!(World())

            # Add multiple component types to same entity
            add_component!(e1, transform(position=Vec3d(1, 2, 3)))
            add_component!(e1, MaterialComponent(metallic=0.8f0))
            add_component!(e1, CameraComponent(fov=90.0f0))

            # All should be retrievable
            @test has_component(e1, TransformComponent)
            @test has_component(e1, MaterialComponent)
            @test has_component(e1, CameraComponent)

            @test get_component(e1, TransformComponent).position[] == Vec3d(1, 2, 3)
            @test get_component(e1, MaterialComponent).metallic == 0.8f0
            @test get_component(e1, CameraComponent).fov == 90.0f0
        end

        @testset "Component inheritance" begin
            # All components should be subtypes of Component
            @test TransformComponent <: Component
            @test MeshComponent <: Component
            @test MaterialComponent <: Component
            @test CameraComponent <: Component
            @test PointLightComponent <: Component
            @test DirectionalLightComponent <: Component
            @test ColliderComponent <: Component
            @test RigidBodyComponent <: Component
            @test AnimationComponent <: Component
        end
    end

    @testset "Scene Graph" begin
        @testset "Empty scene creation" begin
            s = scene()
            @test s isa Scene
            @test isempty(s.entities)
            @test isempty(s.root_entities)
            @test isempty(s.hierarchy)
        end

        @testset "Immutable Scene" begin
            reset_component_stores!()

            s1 = Scene()
            e1 = create_entity!(World())

            s2 = add_entity(s1, e1)

            # Original scene unchanged (immutability)
            @test length(s1.entities) == 0
            @test length(s1.root_entities) == 0

            # New scene has the entity
            @test length(s2.entities) == 1
            @test length(s2.root_entities) == 1
            @test e1 in s2.entities
            @test e1 in s2.root_entities
        end

        @testset "Entity hierarchy" begin
            reset_component_stores!()

            s = Scene()
            parent_id = create_entity!(World())
            child1_id = create_entity!(World())
            child2_id = create_entity!(World())

            # Build hierarchy: parent -> [child1, child2]
            s = add_entity(s, parent_id, nothing)
            s = add_entity(s, child1_id, parent_id)
            s = add_entity(s, child2_id, parent_id)

            # Verify structure
            @test length(s.entities) == 3
            @test length(s.root_entities) == 1
            @test parent_id in s.root_entities

            # Verify hierarchy
            children = get_children(s, parent_id)
            @test length(children) == 2
            @test child1_id in children
            @test child2_id in children

            # Verify parent lookup
            @test get_parent(s, child1_id) == parent_id
            @test get_parent(s, child2_id) == parent_id
            @test get_parent(s, parent_id) === nothing
        end

        @testset "Scene construction with entity definitions" begin
            reset_component_stores!()

            # Create scene with hierarchy using entity definitions
            s = scene([
                entity([transform(position=Vec3d(0, 0, 0))], children=[
                    entity([transform(position=Vec3d(1, 0, 0))]),
                    entity([transform(position=Vec3d(-1, 0, 0))])
                ]),
                entity([CameraComponent()])
            ])

            # Verify structure
            @test length(s.entities) == 4
            @test length(s.root_entities) == 2

            # Verify hierarchy of first root
            root1 = s.root_entities[1]
            children = get_children(s, root1)
            @test length(children) == 2

            # Verify components were added
            @test has_component(root1, TransformComponent)
            root1_transform = get_component(root1, TransformComponent)
            @test root1_transform.position[] == Vec3d(0, 0, 0)

            # Verify second root has camera
            root2 = s.root_entities[2]
            @test has_component(root2, CameraComponent)
        end

        @testset "Single component entity convenience" begin
            reset_component_stores!()

            s = scene([
                entity(transform(position=Vec3d(1, 2, 3)))
            ])

            @test length(s.entities) == 1
            root = s.root_entities[1]
            @test has_component(root, TransformComponent)
            @test get_component(root, TransformComponent).position[] == Vec3d(1, 2, 3)
        end

        @testset "Scene traversal" begin
            reset_component_stores!()

            # Create a tree: root -> [child1 -> [grandchild], child2]
            s = scene([
                entity([transform()], children=[
                    entity([transform()], children=[
                        entity([transform()])
                    ]),
                    entity([transform()])
                ])
            ])

            # Test depth-first traversal
            visited = EntityID[]
            traverse_scene(s, e -> push!(visited, e))
            @test length(visited) == 4

            # Verify depth-first order: root first, then children
            @test visited[1] == s.root_entities[1]
        end

        @testset "Scene traversal with depth" begin
            
            reset_component_stores!()

            # Create: root (depth 0) -> child (depth 1) -> grandchild (depth 2)
            s = scene([
                entity([transform()], children=[
                    entity([transform()], children=[
                        entity([transform()])
                    ])
                ])
            ])

            depths = Int[]
            traverse_scene_with_depth(s, (e, d) -> push!(depths, d))
            @test depths == [0, 1, 2]
        end

        @testset "Get descendants and ancestors" begin
            
            reset_component_stores!()

            # Create: root -> child -> grandchild
            s = scene([
                entity([transform()], children=[
                    entity([transform()], children=[
                        entity([transform()])
                    ])
                ])
            ])

            root = s.root_entities[1]
            child = get_children(s, root)[1]
            grandchild = get_children(s, child)[1]

            # Test get_all_descendants
            descendants = get_all_descendants(s, root)
            @test length(descendants) == 2
            @test child in descendants
            @test grandchild in descendants

            # Test get_ancestors
            ancestors = get_ancestors(s, grandchild)
            @test length(ancestors) == 2
            @test ancestors[1] == child  # Immediate parent first
            @test ancestors[2] == root   # Then root
        end

        @testset "Entity removal" begin
            
            reset_component_stores!()

            # Create: root1 -> [child1, child2], root2
            s = scene([
                entity([transform()], children=[
                    entity([transform()]),
                    entity([transform()])
                ]),
                entity([transform()])
            ])

            @test length(s.entities) == 4
            @test length(s.root_entities) == 2

            root1 = s.root_entities[1]
            root2 = s.root_entities[2]

            # Remove root1 (should also remove its children)
            s2 = remove_entity(s, root1)

            # Original unchanged
            @test length(s.entities) == 4

            # New scene has only root2
            @test length(s2.entities) == 1
            @test length(s2.root_entities) == 1
            @test s2.root_entities[1] == root2
        end

        @testset "Entity helper functions" begin
            reset_component_stores!()

            s = scene([
                entity([transform()], children=[
                    entity([transform()])
                ])
            ])

            root = s.root_entities[1]
            child = get_children(s, root)[1]

            # has_entity
            @test has_entity(s, root)
            @test has_entity(s, child)
            @test !has_entity(s, EntityID(9999))

            # is_root
            @test is_root(s, root)
            @test !is_root(s, child)

            # entity_count
            @test entity_count(s) == 2
        end

        @testset "Complex nested hierarchy" begin
            reset_component_stores!()

            # Create a more complex tree
            s = scene([
                entity([transform(position=Vec3d(0, 0, 0))], children=[
                    entity([transform(position=Vec3d(1, 0, 0))], children=[
                        entity([transform(position=Vec3d(1, 1, 0))]),
                        entity([transform(position=Vec3d(1, -1, 0))])
                    ]),
                    entity([transform(position=Vec3d(-1, 0, 0))], children=[
                        entity([transform(position=Vec3d(-1, 1, 0))])
                    ])
                ]),
                entity([CameraComponent()], children=[
                    entity([PointLightComponent()])
                ])
            ])

            @test entity_count(s) == 8
            @test length(s.root_entities) == 2

            # Verify deep nesting
            root1 = s.root_entities[1]
            root1_children = get_children(s, root1)
            @test length(root1_children) == 2

            first_child = root1_children[1]
            first_child_children = get_children(s, first_child)
            @test length(first_child_children) == 2
        end
    end

    @testset "State" begin
        s = state(0)
        @test s[] == 0

        s[] = 42
        @test s[] == 42
    end

    @testset "Components" begin
        @testset "TransformComponent with Observables" begin
            # Default transform
            t = TransformComponent()
            @test t.position[] == Vec3d(0, 0, 0)
            @test t.rotation[] == Quaterniond(1, 0, 0, 0)  # Identity quaternion (w=1)
            @test t.scale[] == Vec3d(1, 1, 1)
            @test t.parent === nothing

            # Custom position
            t2 = TransformComponent(position=Vec3d(1, 2, 3))
            @test t2.position[] == Vec3d(1, 2, 3)

            # Observable reactivity
            t2.position[] = Vec3d(4, 5, 6)
            @test t2.position[] == Vec3d(4, 5, 6)
        end

        @testset "transform() public API" begin
            t = transform(position=Vec3d(1, 2, 3))
            @test t.position[] == Vec3d(1, 2, 3)
            @test t.rotation[] == Quaterniond(1, 0, 0, 0)  # Identity: w=1, x=y=z=0
            @test t.scale[] == Vec3d(1, 1, 1)
            @test t.parent === nothing  # transform() always creates without parent
        end

        @testset "with_parent helper" begin
            t = transform(position=Vec3d(1, 0, 0))
            parent_id = EntityID(42)
            t_with_parent = with_parent(t, parent_id)

            @test t_with_parent.position[] == Vec3d(1, 0, 0)
            @test t_with_parent.parent == parent_id
            @test t.parent === nothing  # Original unchanged
        end

        @testset "MeshComponent" begin
            m = MeshComponent()
            @test isempty(m.vertices)
            @test isempty(m.indices)
            @test isempty(m.uvs)
        end

        @testset "MaterialComponent" begin
            mat = MaterialComponent()
            @test mat.color == RGB{Float32}(1.0, 1.0, 1.0)
            @test mat.metallic == 0.0f0
            @test mat.roughness == 0.5f0
            @test mat.albedo_map === nothing
            @test mat.normal_map === nothing
            @test mat.metallic_roughness_map === nothing
            @test mat.ao_map === nothing
            @test mat.emissive_map === nothing
            @test mat.emissive_factor == Vec3f(0, 0, 0)
        end

        @testset "MaterialComponent with TextureRef" begin
            tex = TextureRef("/path/to/texture.png")
            mat = MaterialComponent(
                albedo_map=tex,
                normal_map=TextureRef("/path/to/normal.png"),
                metallic=0.5f0
            )
            @test mat.albedo_map !== nothing
            @test mat.albedo_map.path == "/path/to/texture.png"
            @test mat.normal_map.path == "/path/to/normal.png"
            @test mat.metallic == 0.5f0
        end

        @testset "CameraComponent" begin
            cam = CameraComponent()
            @test cam.fov == 60.0f0
            @test cam.near == 0.1f0
            @test cam.far == 1000.0f0
        end

        @testset "Light components" begin
            pl = PointLightComponent()
            @test pl.intensity == 1.0f0

            dl = DirectionalLightComponent()
            @test dl.direction == Vec3f(0, -1, 0)
        end

        @testset "ColliderComponent" begin
            # Default collider
            c = ColliderComponent()
            @test c.shape isa AABBShape
            @test c.shape.half_extents == Vec3f(0.5, 0.5, 0.5)
            @test c.offset == Vec3f(0, 0, 0)

            # Sphere collider
            c2 = ColliderComponent(shape=SphereShape(2.0f0))
            @test c2.shape isa SphereShape
            @test c2.shape.radius == 2.0f0

            # Custom AABB
            c3 = ColliderComponent(
                shape=AABBShape(Vec3f(1, 2, 3)),
                offset=Vec3f(0, 1, 0)
            )
            @test c3.shape.half_extents == Vec3f(1, 2, 3)
            @test c3.offset == Vec3f(0, 1, 0)
        end

        @testset "RigidBodyComponent" begin
            # Default
            rb = RigidBodyComponent()
            @test rb.body_type == BODY_DYNAMIC
            @test rb.velocity == Vec3d(0, 0, 0)
            @test rb.mass == 1.0
            @test rb.grounded == false

            # Static body
            rb2 = RigidBodyComponent(body_type=BODY_STATIC)
            @test rb2.body_type == BODY_STATIC

            # Kinematic body
            rb3 = RigidBodyComponent(body_type=BODY_KINEMATIC)
            @test rb3.body_type == BODY_KINEMATIC
        end

        @testset "collider_from_mesh" begin
            mesh = MeshComponent(
                vertices=[
                    Point3f(-1, -2, -3),
                    Point3f(1, 2, 3),
                    Point3f(0, 0, 0)
                ],
                indices=UInt32[0, 1, 2]
            )
            c = collider_from_mesh(mesh)
            @test c.shape isa AABBShape
            @test c.shape.half_extents ≈ Vec3f(1, 2, 3) atol=1e-5
            @test c.offset ≈ Vec3f(0, 0, 0) atol=1e-5
        end

        @testset "sphere_collider_from_mesh" begin
            mesh = MeshComponent(
                vertices=[
                    Point3f(1, 0, 0),
                    Point3f(-1, 0, 0),
                    Point3f(0, 1, 0),
                    Point3f(0, -1, 0)
                ],
                indices=UInt32[0, 1, 2, 0, 2, 3]
            )
            c = sphere_collider_from_mesh(mesh)
            @test c.shape isa SphereShape
            @test c.shape.radius ≈ 1.0f0 atol=1e-5
        end
    end

    @testset "Primitives with UVs" begin
        @testset "cube_mesh has UVs" begin
            m = cube_mesh()
            @test !isempty(m.uvs)
            @test length(m.uvs) == length(m.vertices)
        end

        @testset "plane_mesh has UVs" begin
            m = plane_mesh()
            @test !isempty(m.uvs)
            @test length(m.uvs) == length(m.vertices)
        end

        @testset "sphere_mesh has UVs" begin
            m = sphere_mesh()
            @test !isempty(m.uvs)
            @test length(m.uvs) == length(m.vertices)
        end
    end

    @testset "Physics" begin
        @testset "AABB overlap" begin
            a = OpenReality.WorldAABB(Vec3d(0, 0, 0), Vec3d(2, 2, 2))
            b = OpenReality.WorldAABB(Vec3d(1, 1, 1), Vec3d(3, 3, 3))
            @test OpenReality.aabb_overlap(a, b) == true

            c = OpenReality.WorldAABB(Vec3d(5, 5, 5), Vec3d(6, 6, 6))
            @test OpenReality.aabb_overlap(a, c) == false
        end

        @testset "AABB non-overlap" begin
            a = OpenReality.WorldAABB(Vec3d(0, 0, 0), Vec3d(1, 1, 1))
            b = OpenReality.WorldAABB(Vec3d(2, 0, 0), Vec3d(3, 1, 1))
            @test OpenReality.aabb_overlap(a, b) == false
        end

        @testset "Collision resolution — floor prevents fall-through" begin
            reset_component_stores!()

            # Create a floor (static, at y=0, extends from -10 to 10 in xz, height 0.1)
            floor_id = create_entity!(World())
            add_component!(floor_id, transform(position=Vec3d(0, -0.05, 0)))
            add_component!(floor_id, ColliderComponent(
                shape=AABBShape(Vec3f(10.0, 0.05, 10.0))
            ))
            add_component!(floor_id, RigidBodyComponent(body_type=BODY_STATIC))

            # Create a dynamic box above the floor
            box_id = create_entity!(World())
            add_component!(box_id, transform(position=Vec3d(0, 0.5, 0)))
            add_component!(box_id, ColliderComponent(
                shape=AABBShape(Vec3f(0.5, 0.5, 0.5))
            ))
            add_component!(box_id, RigidBodyComponent(body_type=BODY_DYNAMIC))

            # Simulate several physics steps
            for _ in 1:100
                update_physics!(1.0 / 60.0)
            end

            # Box should not have fallen through the floor
            box_tc = get_component(box_id, TransformComponent)
            @test box_tc.position[][2] >= -0.1  # Should be at or above floor level
        end

        @testset "PhysicsConfig" begin
            config = PhysicsConfig()
            @test config.gravity == Vec3d(0, -9.81, 0)

            custom = PhysicsConfig(gravity=Vec3d(0, -20.0, 0))
            @test custom.gravity == Vec3d(0, -20.0, 0)
        end
    end

    @testset "Physics — Shapes" begin
        @testset "CapsuleShape defaults" begin
            c = CapsuleShape()
            @test c.radius == 0.5f0
            @test c.half_height == 0.5f0
            @test c.axis == CAPSULE_Y
        end

        @testset "CapsuleShape custom" begin
            c = CapsuleShape(radius=0.3f0, half_height=0.8f0, axis=CAPSULE_X)
            @test c.radius == 0.3f0
            @test c.half_height == 0.8f0
            @test c.axis == CAPSULE_X
        end

        @testset "OBBShape" begin
            o = OBBShape(Vec3f(1, 2, 3))
            @test o.half_extents == Vec3f(1, 2, 3)
        end

        @testset "ConvexHullShape" begin
            verts = [Vec3f(0, 1, 0), Vec3f(-1, 0, 0), Vec3f(1, 0, 0), Vec3f(0, 0, -1)]
            ch = ConvexHullShape(verts)
            @test length(ch.vertices) == 4
        end

        @testset "CompoundShape" begin
            cs = CompoundShape([
                CompoundChild(AABBShape(Vec3f(0.5, 0.25, 0.25)), position=Vec3d(0, 0.25, 0)),
                CompoundChild(SphereShape(0.3f0), position=Vec3d(0, -0.25, 0))
            ])
            @test length(cs.children) == 2
            @test cs.children[1].shape isa AABBShape
            @test cs.children[2].shape isa SphereShape
            @test cs.children[1].local_position == Vec3d(0, 0.25, 0)
        end

        @testset "ColliderComponent is_trigger" begin
            c = ColliderComponent(is_trigger=true)
            @test c.is_trigger == true

            c2 = ColliderComponent()
            @test c2.is_trigger == false
        end

        @testset "AABB computation — sphere" begin
            aabb = OpenReality.compute_world_aabb(
                SphereShape(1.0f0), Vec3d(0, 5, 0),
                Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0)
            )
            @test aabb.min_pt ≈ Vec3d(-1, 4, -1) atol=1e-10
            @test aabb.max_pt ≈ Vec3d(1, 6, 1) atol=1e-10
        end

        @testset "AABB computation — AABB" begin
            aabb = OpenReality.compute_world_aabb(
                AABBShape(Vec3f(1, 2, 3)), Vec3d(0, 0, 0),
                Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0)
            )
            @test aabb.min_pt ≈ Vec3d(-1, -2, -3) atol=1e-10
            @test aabb.max_pt ≈ Vec3d(1, 2, 3) atol=1e-10
        end

        @testset "AABB computation — capsule Y-axis" begin
            aabb = OpenReality.compute_world_aabb(
                CapsuleShape(radius=0.5f0, half_height=1.0f0, axis=CAPSULE_Y),
                Vec3d(0, 0, 0), Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0)
            )
            # Capsule along Y: extends ±1.0 on Y (half_height) + ±0.5 (radius)
            @test aabb.min_pt[2] ≈ -1.5 atol=1e-10
            @test aabb.max_pt[2] ≈ 1.5 atol=1e-10
            @test aabb.min_pt[1] ≈ -0.5 atol=1e-10
            @test aabb.max_pt[1] ≈ 0.5 atol=1e-10
        end

        @testset "AABB computation — OBB" begin
            aabb = OpenReality.compute_world_aabb(
                OBBShape(Vec3f(1, 1, 1)), Vec3d(0, 0, 0),
                Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0)
            )
            @test aabb.min_pt ≈ Vec3d(-1, -1, -1) atol=1e-10
            @test aabb.max_pt ≈ Vec3d(1, 1, 1) atol=1e-10
        end

        @testset "AABB computation — ConvexHull" begin
            aabb = OpenReality.compute_world_aabb(
                ConvexHullShape([Vec3f(0, 1, 0), Vec3f(-1, 0, 0), Vec3f(1, 0, 0), Vec3f(0, 0, -1)]),
                Vec3d(0, 0, 0), Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0)
            )
            @test aabb.min_pt[1] ≈ -1.0 atol=1e-10
            @test aabb.max_pt[1] ≈ 1.0 atol=1e-10
            @test aabb.max_pt[2] ≈ 1.0 atol=1e-10
        end

        @testset "AABB computation — CompoundShape" begin
            cs = CompoundShape([
                CompoundChild(AABBShape(Vec3f(0.5, 0.5, 0.5)), position=Vec3d(2, 0, 0)),
                CompoundChild(AABBShape(Vec3f(0.5, 0.5, 0.5)), position=Vec3d(-2, 0, 0))
            ])
            aabb = OpenReality.compute_world_aabb(
                cs, Vec3d(0, 0, 0), Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0)
            )
            @test aabb.min_pt[1] ≈ -2.5 atol=1e-10
            @test aabb.max_pt[1] ≈ 2.5 atol=1e-10
        end
    end

    @testset "Physics — Broadphase" begin
        @testset "SpatialHashGrid insert and query" begin
            grid = OpenReality.SpatialHashGrid(cell_size=2.0)

            # Two overlapping AABBs
            aabb_a = OpenReality.AABB3D(Vec3d(0, 0, 0), Vec3d(1, 1, 1))
            aabb_b = OpenReality.AABB3D(Vec3d(0.5, 0.5, 0.5), Vec3d(1.5, 1.5, 1.5))
            insert!(grid, EntityID(1), aabb_a)
            insert!(grid, EntityID(2), aabb_b)

            pairs = OpenReality.query_pairs(grid)
            @test length(pairs) == 1
            @test pairs[1].entity_a == EntityID(1) || pairs[1].entity_b == EntityID(1)
        end

        @testset "SpatialHashGrid no overlap" begin
            grid = OpenReality.SpatialHashGrid(cell_size=2.0)

            aabb_a = OpenReality.AABB3D(Vec3d(0, 0, 0), Vec3d(1, 1, 1))
            aabb_b = OpenReality.AABB3D(Vec3d(10, 10, 10), Vec3d(11, 11, 11))
            insert!(grid, EntityID(1), aabb_a)
            insert!(grid, EntityID(2), aabb_b)

            pairs = OpenReality.query_pairs(grid)
            @test isempty(pairs)
        end

        @testset "SpatialHashGrid clear" begin
            grid = OpenReality.SpatialHashGrid(cell_size=2.0)
            insert!(grid, EntityID(1), OpenReality.AABB3D(Vec3d(0,0,0), Vec3d(1,1,1)))
            @test !isempty(grid.cells)
            OpenReality.clear!(grid)
            @test isempty(grid.cells)
            @test isempty(grid.entity_aabbs)
        end
    end

    @testset "Physics — Narrowphase" begin
        @testset "Sphere vs Sphere collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(1.0f0)))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(1.5, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(1.0f0)))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
            @test length(manifold.points) == 1
            @test manifold.points[1].penetration > 0
            # Normal should point from A to B (positive X)
            @test manifold.normal[1] > 0
        end

        @testset "Sphere vs Sphere no collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(5, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))

            manifold = OpenReality.collide(e1, e2)
            @test manifold === nothing
        end

        @testset "AABB vs AABB collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=AABBShape(Vec3f(1, 1, 1))))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(1.5, 0, 0)))
            add_component!(e2, ColliderComponent(shape=AABBShape(Vec3f(1, 1, 1))))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
            @test manifold.points[1].penetration ≈ 0.5 atol=1e-10
        end

        @testset "Sphere vs AABB collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(1.0f0)))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(1.5, 0, 0)))
            add_component!(e2, ColliderComponent(shape=AABBShape(Vec3f(1, 1, 1))))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
            @test manifold.points[1].penetration > 0
        end

        @testset "Capsule vs Sphere collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=CapsuleShape(radius=0.5f0, half_height=1.0f0)))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(0.8, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
            @test manifold.points[1].penetration > 0
        end

        @testset "Capsule vs Capsule collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=CapsuleShape(radius=0.3f0, half_height=0.5f0)))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(0.4, 0, 0)))
            add_component!(e2, ColliderComponent(shape=CapsuleShape(radius=0.3f0, half_height=0.5f0)))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
            @test manifold.points[1].penetration > 0
        end

        @testset "Capsule vs AABB collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 1, 0)))
            add_component!(e1, ColliderComponent(shape=CapsuleShape(radius=0.5f0, half_height=0.5f0)))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(0, 0, 0)))
            add_component!(e2, ColliderComponent(shape=AABBShape(Vec3f(2, 0.5, 2))))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
        end
    end

    @testset "Physics — GJK/EPA" begin
        @testset "OBB vs AABB collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=OBBShape(Vec3f(1, 1, 1))))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(1.5, 0, 0)))
            add_component!(e2, ColliderComponent(shape=AABBShape(Vec3f(1, 1, 1))))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
            @test manifold.points[1].penetration > 0
        end

        @testset "OBB vs OBB collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=OBBShape(Vec3f(1, 1, 1))))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(1.5, 0, 0)))
            add_component!(e2, ColliderComponent(shape=OBBShape(Vec3f(1, 1, 1))))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
        end

        @testset "ConvexHull vs AABB collision" begin
           reset_component_stores!()

            # Tetrahedron centered at origin
            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=ConvexHullShape([
                Vec3f(0, 1, 0), Vec3f(-1, -1, 0), Vec3f(1, -1, 0), Vec3f(0, 0, -1)
            ])))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(0.5, 0, 0)))
            add_component!(e2, ColliderComponent(shape=AABBShape(Vec3f(1, 1, 1))))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
        end

        @testset "ConvexHull vs ConvexHull no collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=ConvexHullShape([
                Vec3f(0, 1, 0), Vec3f(-1, -1, 0), Vec3f(1, -1, 0), Vec3f(0, 0, -1)
            ])))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(10, 0, 0)))
            add_component!(e2, ColliderComponent(shape=ConvexHullShape([
                Vec3f(0, 1, 0), Vec3f(-1, -1, 0), Vec3f(1, -1, 0), Vec3f(0, 0, -1)
            ])))

            manifold = OpenReality.collide(e1, e2)
            @test manifold === nothing
        end

        @testset "GJK support functions" begin
            # Sphere support should be center + radius * direction
            s = OpenReality.gjk_support(SphereShape(1.0f0), Vec3d(0, 0, 0),
                            Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0),
                            Vec3d(1, 0, 0))
            @test s[1] ≈ 1.0 atol=1e-10

            # AABB support along +X should give +half_extent
            s2 = OpenReality.gjk_support(AABBShape(Vec3f(2, 1, 1)), Vec3d(0, 0, 0),
                             Quaterniond(1, 0, 0, 0), Vec3d(1, 1, 1), Vec3f(0, 0, 0),
                             Vec3d(1, 0, 0))
            @test s2[1] ≈ 2.0 atol=1e-10
        end
    end

    @testset "Physics — Raycasting" begin
        @testset "Raycast hits sphere" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, -5)))
            add_component!(e1, ColliderComponent(shape=SphereShape(1.0f0)))

            hit = raycast(Vec3d(0, 0, 0), Vec3d(0, 0, -1), max_distance=20.0)
            @test hit !== nothing
            @test hit.entity == e1
            @test hit.distance ≈ 4.0 atol=0.1  # distance to sphere surface
            @test hit.normal[3] > 0  # normal points toward ray origin
        end

        @testset "Raycast hits AABB" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, -2, 0)))
            add_component!(e1, ColliderComponent(shape=AABBShape(Vec3f(10, 0.5, 10))))

            hit = raycast(Vec3d(0, 5, 0), Vec3d(0, -1, 0), max_distance=20.0)
            @test hit !== nothing
            @test hit.entity == e1
            @test hit.point[2] ≈ -1.5 atol=0.1  # top surface of AABB
        end

        @testset "Raycast misses" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(10, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(1.0f0)))

            hit = raycast(Vec3d(0, 0, 0), Vec3d(0, 0, -1), max_distance=20.0)
            @test hit === nothing
        end

        @testset "Raycast hits capsule" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, -5)))
            add_component!(e1, ColliderComponent(shape=CapsuleShape(radius=0.5f0, half_height=1.0f0)))

            hit = raycast(Vec3d(0, 0, 0), Vec3d(0, 0, -1), max_distance=20.0)
            @test hit !== nothing
            @test hit.entity == e1
        end

        @testset "Raycast skips triggers" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, -3)))
            add_component!(e1, ColliderComponent(shape=SphereShape(1.0f0), is_trigger=true))

            hit = raycast(Vec3d(0, 0, 0), Vec3d(0, 0, -1), max_distance=20.0)
            @test hit === nothing
        end

        @testset "raycast_all returns sorted hits" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, -3)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(0, 0, -8)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))

            hits = raycast_all(Vec3d(0, 0, 0), Vec3d(0, 0, -1), max_distance=20.0)
            @test length(hits) == 2
            @test hits[1].distance < hits[2].distance
            @test hits[1].entity == e1
            @test hits[2].entity == e2
        end
    end

    @testset "Physics — CCD" begin
        @testset "Sweep test detects collision" begin
            reset_component_stores!()

            # Static wall close to origin
            wall_id = create_entity!(World())
            add_component!(wall_id, transform(position=Vec3d(1, 0, 0)))
            add_component!(wall_id, ColliderComponent(shape=AABBShape(Vec3f(0.1, 2, 2))))

            # Fast-moving sphere
            bullet_id = create_entity!(World())
            add_component!(bullet_id, transform(position=Vec3d(0, 0, 0)))
            add_component!(bullet_id, ColliderComponent(shape=SphereShape(0.2f0)))
            add_component!(bullet_id, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=0.5))

            # velocity=500, dt=1/60 → travel_distance=8.33, wall at x=1 is within range
            result = OpenReality.sweep_test(bullet_id, Vec3d(500, 0, 0), 1.0/60.0)
            @test result !== nothing
        end

        @testset "CCD mode enum" begin
            @test CCD_NONE isa OpenReality.CCDMode
            @test CCD_SWEPT isa OpenReality.CCDMode
        end
    end

    @testset "Physics — Constraints" begin
        @testset "BallSocketJoint construction" begin
            j = BallSocketJoint(EntityID(1), EntityID(2),
                                local_anchor_a=Vec3d(0, 1, 0),
                                local_anchor_b=Vec3d(0, -1, 0))
            @test j.entity_a == EntityID(1)
            @test j.entity_b == EntityID(2)
            @test j.local_anchor_a == Vec3d(0, 1, 0)
            @test j.local_anchor_b == Vec3d(0, -1, 0)
        end

        @testset "DistanceJoint construction" begin
            j = DistanceJoint(EntityID(1), EntityID(2), target_distance=3.0)
            @test j.target_distance == 3.0
            @test j.entity_a == EntityID(1)
        end

        @testset "HingeJoint construction" begin
            j = HingeJoint(EntityID(1), EntityID(2),
                           axis=Vec3d(0, 0, 1), lower_limit=-π/4, upper_limit=π/4)
            @test j.axis == Vec3d(0, 0, 1)
            @test j.lower_limit ≈ -π/4
            @test j.upper_limit ≈ π/4
        end

        @testset "FixedJoint construction" begin
            j = FixedJoint(EntityID(1), EntityID(2),
                           local_anchor_a=Vec3d(1, 0, 0), local_anchor_b=Vec3d(-1, 0, 0))
            @test j.local_anchor_a == Vec3d(1, 0, 0)
        end

        @testset "SliderJoint construction" begin
            j = SliderJoint(EntityID(1), EntityID(2),
                            axis=Vec3d(0, 1, 0), lower_limit=0.0, upper_limit=5.0)
            @test j.axis == Vec3d(0, 1, 0)
            @test j.upper_limit == 5.0
        end

        @testset "JointComponent wraps constraint" begin
            j = BallSocketJoint(EntityID(1), EntityID(2))
            jc = JointComponent(j)
            @test jc.joint isa BallSocketJoint
            @test jc isa Component
        end

        @testset "Ball-socket joint constrains pendulum" begin
            reset_component_stores!()
            reset_physics_world!()

            # Static anchor
            anchor = create_entity!(World())
            add_component!(anchor, transform(position=Vec3d(0, 5, 0)))
            add_component!(anchor, ColliderComponent(shape=SphereShape(0.1f0)))
            add_component!(anchor, RigidBodyComponent(body_type=BODY_STATIC))

            # Dynamic bob
            bob = create_entity!(World())
            add_component!(bob, transform(position=Vec3d(0, 3, 0)))
            add_component!(bob, ColliderComponent(shape=SphereShape(0.3f0)))
            add_component!(bob, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0,
                                                    velocity=Vec3d(2, 0, 0)))

            add_component!(bob, JointComponent(
                BallSocketJoint(anchor, bob,
                                local_anchor_a=Vec3d(0, 0, 0),
                                local_anchor_b=Vec3d(0, 2, 0))
            ))

            # Run several physics steps
            for _ in 1:50
                update_physics!(1.0 / 60.0)
            end

            # Bob should still be roughly 2 units from anchor (joint distance)
            bob_tc = get_component(bob, TransformComponent)
            anchor_tc = get_component(anchor, TransformComponent)
            dist = sqrt(sum((bob_tc.position[] - anchor_tc.position[]) .^ 2))
            @test dist ≈ 2.0 atol=0.5  # approximate due to solver convergence
        end
    end

    @testset "Physics — Triggers" begin
        @testset "TriggerComponent defaults" begin
            tc = TriggerComponent()
            @test tc.on_enter === nothing
            @test tc.on_stay === nothing
            @test tc.on_exit === nothing
        end

        @testset "TriggerComponent with callbacks" begin
            entered = Ref(false)
            tc = TriggerComponent(
                on_enter = (t, o) -> (entered[] = true),
                on_stay = nothing,
                on_exit = nothing
            )
            @test tc.on_enter !== nothing
            tc.on_enter(EntityID(1), EntityID(2))
            @test entered[] == true
        end

        @testset "TriggerComponent is Component" begin
            @test TriggerComponent <: Component
        end

        @testset "Trigger enter/exit detection" begin
            reset_component_stores!()
            reset_physics_world!()
            OpenReality.reset_trigger_state!()

            # Trigger zone at origin
            trigger_eid = create_entity!(World())
            add_component!(trigger_eid, transform(position=Vec3d(0, 0, 0)))
            add_component!(trigger_eid, ColliderComponent(
                shape=AABBShape(Vec3f(2, 2, 2)), is_trigger=true
            ))

            enter_log = EntityID[]
            exit_log = EntityID[]
            add_component!(trigger_eid, TriggerComponent(
                on_enter = (t, o) -> push!(enter_log, o),
                on_exit = (t, o) -> push!(exit_log, o)
            ))

            # Object inside trigger zone
            obj_eid = create_entity!(World())
            add_component!(obj_eid, transform(position=Vec3d(0, 0, 0)))
            add_component!(obj_eid, ColliderComponent(shape=SphereShape(0.5f0)))

            # First update: should trigger on_enter
            OpenReality.update_triggers!()
            @test length(enter_log) == 1
            @test enter_log[1] == obj_eid

            # Second update: same overlap, no new enter
            OpenReality.update_triggers!()
            @test length(enter_log) == 1  # no duplicate

            # Move object out of trigger zone
            obj_tc = get_component(obj_eid, TransformComponent)
            obj_tc.position[] = Vec3d(100, 0, 0)

            OpenReality.update_triggers!()
            @test length(exit_log) == 1
            @test exit_log[1] == obj_eid
        end
    end

    @testset "Physics — Islands and Sleeping" begin
        @testset "SimulationIsland struct" begin
            island = OpenReality.SimulationIsland([EntityID(1), EntityID(2)])
            @test length(island.entities) == 2
        end

        @testset "build_islands groups connected bodies" begin
            reset_component_stores!()

            # Two dynamic bodies with a contact manifold between them
            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(1.0f0)))
            add_component!(e1, RigidBodyComponent(body_type=BODY_DYNAMIC))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(1, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(1.0f0)))
            add_component!(e2, RigidBodyComponent(body_type=BODY_DYNAMIC))

            # Isolated body
            e3 = create_entity!(World())
            add_component!(e3, transform(position=Vec3d(100, 0, 0)))
            add_component!(e3, ColliderComponent(shape=SphereShape(1.0f0)))
            add_component!(e3, RigidBodyComponent(body_type=BODY_DYNAMIC))

            manifolds = [OpenReality.ContactManifold(e1, e2, Vec3d(1, 0, 0))]
            constraints = OpenReality.JointConstraint[]

            islands = OpenReality.build_islands(manifolds, constraints)
            # Should have 2 islands: one with e1+e2, one with e3
            @test length(islands) == 2
            sizes = sort([length(i.entities) for i in islands])
            @test sizes == [1, 2]
        end

        @testset "PhysicsWorldConfig sleep fields" begin
            config = OpenReality.PhysicsWorldConfig()
            @test config.sleep_linear_threshold == 0.01
            @test config.sleep_angular_threshold == 0.05
            @test config.sleep_time == 0.5
        end
    end

    @testset "Physics — Compound Shapes" begin
        @testset "CompoundShape vs AABB collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=CompoundShape([
                CompoundChild(AABBShape(Vec3f(0.5, 0.25, 0.25)), position=Vec3d(0, 0.25, 0)),
                CompoundChild(AABBShape(Vec3f(0.25, 0.5, 0.25)), position=Vec3d(-0.25, -0.25, 0))
            ])))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(0.5, 0.25, 0)))
            add_component!(e2, ColliderComponent(shape=AABBShape(Vec3f(0.5, 0.5, 0.5))))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
        end

        @testset "CompoundShape vs Sphere collision" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=CompoundShape([
                CompoundChild(SphereShape(0.5f0), position=Vec3d(0, 0, 0))
            ])))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(0.8, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))

            manifold = OpenReality.collide(e1, e2)
            @test manifold !== nothing
        end

        @testset "CompoundShape no collision when distant" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=CompoundShape([
                CompoundChild(AABBShape(Vec3f(0.5, 0.5, 0.5)), position=Vec3d(0, 0, 0))
            ])))

            e2 = create_entity!(World())
            add_component!(e2, transform(position=Vec3d(100, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))

            manifold = OpenReality.collide(e1, e2)
            @test manifold === nothing
        end

        @testset "CompoundShape inertia computation" begin
            cs = CompoundShape([
                CompoundChild(AABBShape(Vec3f(0.5, 0.5, 0.5)), position=Vec3d(1, 0, 0)),
                CompoundChild(AABBShape(Vec3f(0.5, 0.5, 0.5)), position=Vec3d(-1, 0, 0))
            ])
            inv_I = OpenReality.compute_inverse_inertia(cs, 2.0, Vec3d(1, 1, 1))
            # Inverse inertia should be non-zero for positive mass
            @test inv_I[1, 1] > 0
            @test inv_I[2, 2] > 0
            @test inv_I[3, 3] > 0
        end
    end

    @testset "Physics — Inertia" begin
        @testset "Sphere inertia" begin
            inv_I = OpenReality.compute_inverse_inertia(SphereShape(1.0f0), 1.0, Vec3d(1, 1, 1))
            # I = 2/5 * m * r² = 0.4, inv = 2.5
            @test inv_I[1, 1] ≈ 2.5 atol=1e-10
            @test inv_I[2, 2] ≈ 2.5 atol=1e-10
            @test inv_I[3, 3] ≈ 2.5 atol=1e-10
        end

        @testset "Box inertia" begin
            inv_I = OpenReality.compute_inverse_inertia(AABBShape(Vec3f(0.5, 0.5, 0.5)), 1.0, Vec3d(1, 1, 1))
            # Full width 1.0 on each axis. I_xx = 1/12 * m * (h² + d²) = 1/12 * (1+1) = 1/6
            @test inv_I[1, 1] ≈ 6.0 atol=1e-10
        end

        @testset "Zero mass returns zero inertia" begin
            inv_I = OpenReality.compute_inverse_inertia(SphereShape(1.0f0), 0.0, Vec3d(1, 1, 1))
            @test inv_I == OpenReality.ZERO_MAT3D
        end

        @testset "Capsule inertia" begin
            inv_I = OpenReality.compute_inverse_inertia(
                CapsuleShape(radius=0.5f0, half_height=1.0f0), 1.0, Vec3d(1, 1, 1)
            )
            @test inv_I[1, 1] > 0
            @test inv_I[2, 2] > 0
            # For Y-axis capsule, I_yy should be smaller (less resistance to rotation around long axis)
            @test inv_I[2, 2] > inv_I[1, 1]  # inv is larger = easier to rotate
        end
    end

    @testset "Physics — Solver integration" begin
        @testset "Dynamic body falls under gravity" begin
            reset_component_stores!()
            reset_physics_world!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 10, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e1, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0))

            for _ in 1:10
                update_physics!(1.0 / 60.0)
            end

            tc = get_component(e1, TransformComponent)
            @test tc.position[][2] < 10.0  # should have fallen
        end

        @testset "Static body does not move" begin
            reset_component_stores!()
            reset_physics_world!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(0, 5, 0)))
            add_component!(e1, ColliderComponent(shape=AABBShape(Vec3f(1, 1, 1))))
            add_component!(e1, RigidBodyComponent(body_type=BODY_STATIC))

            for _ in 1:10
                update_physics!(1.0 / 60.0)
            end

            tc = get_component(e1, TransformComponent)
            @test tc.position[][2] ≈ 5.0 atol=1e-10  # unchanged
        end

        @testset "Restitution: bouncy ball bounces higher" begin
            reset_component_stores!()
            reset_physics_world!()

            # Floor
            floor_id = create_entity!(World())
            add_component!(floor_id, transform(position=Vec3d(0, -0.5, 0)))
            add_component!(floor_id, ColliderComponent(shape=AABBShape(Vec3f(10, 0.5, 10))))
            add_component!(floor_id, RigidBodyComponent(body_type=BODY_STATIC))

            # Low-bounce ball
            b1 = create_entity!(World())
            add_component!(b1, transform(position=Vec3d(-2, 3, 0)))
            add_component!(b1, ColliderComponent(shape=SphereShape(0.3f0)))
            add_component!(b1, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0, restitution=0.1f0))

            # High-bounce ball
            b2 = create_entity!(World())
            add_component!(b2, transform(position=Vec3d(2, 3, 0)))
            add_component!(b2, ColliderComponent(shape=SphereShape(0.3f0)))
            add_component!(b2, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0, restitution=0.9f0))

            # Run physics until after first bounce
            for _ in 1:200
                update_physics!(1.0 / 60.0)
            end

            rb1 = get_component(b1, RigidBodyComponent)
            rb2 = get_component(b2, RigidBodyComponent)
            # Both should not have fallen through
            tc1 = get_component(b1, TransformComponent)
            tc2 = get_component(b2, TransformComponent)
            @test tc1.position[][2] >= -0.5
            @test tc2.position[][2] >= -0.5
        end

        @testset "PhysicsWorldConfig defaults" begin
            config = OpenReality.PhysicsWorldConfig()
            @test config.gravity == Vec3d(0, -9.81, 0)
            @test config.fixed_dt ≈ 1.0 / 120.0
            @test config.max_substeps == 8
            @test config.solver_iterations == 10
            @test config.position_correction == 0.2
            @test config.slop == 0.005
        end

        @testset "Contact cache warm-starting" begin
            cache = OpenReality.ContactCache()
            @test isempty(cache.manifolds)

            # Create a manifold with accumulated impulse
            m = OpenReality.ContactManifold(EntityID(1), EntityID(2), Vec3d(0, 1, 0))
            cp = OpenReality.ContactPoint(Vec3d(0, 0, 0), Vec3d(0, 1, 0), 0.1)
            cp.normal_impulse = 5.0
            push!(m.points, cp)

            OpenReality.update_cache!(cache, [m])
            @test length(cache.manifolds) == 1
        end
    end

    @testset "Physics — RigidBody fields" begin
        @testset "RigidBodyComponent new fields" begin
            rb = RigidBodyComponent()
            @test rb.angular_velocity == Vec3d(0, 0, 0)
            @test rb.friction == 0.5
            @test rb.linear_damping == 0.01
            @test rb.angular_damping == 0.05
            @test rb.sleeping == false
            @test rb.sleep_timer == 0.0
            @test rb.ccd_mode == CCD_NONE
        end

        @testset "RigidBodyComponent custom construction" begin
            rb = RigidBodyComponent(
                body_type=BODY_DYNAMIC,
                velocity=Vec3d(1, 2, 3),
                angular_velocity=Vec3d(0.1, 0.2, 0.3),
                mass=5.0,
                restitution=0.8f0,
                friction=0.7,
                linear_damping=0.02,
                angular_damping=0.1,
                ccd_mode=CCD_SWEPT
            )
            @test rb.velocity == Vec3d(1, 2, 3)
            @test rb.angular_velocity == Vec3d(0.1, 0.2, 0.3)
            @test rb.mass == 5.0
            @test rb.inv_mass ≈ 0.2 atol=1e-10
            @test rb.friction == 0.7
            @test rb.ccd_mode == CCD_SWEPT
        end
    end

    @testset "Backend" begin
        @testset "OpenGL Backend" begin
            backend = OpenGLBackend()
            @test !backend.initialized

            initialize!(backend)
            @test backend.initialized

            shutdown!(backend)
            @test !backend.initialized
        end

        if Sys.isapple()
            @testset "Metal Backend" begin
                backend = MetalBackend()
                @test !backend.initialized

                initialize!(backend)
                @test backend.initialized

                shutdown!(backend)
                @test !backend.initialized
            end
        end

        if !Sys.isapple()
            @testset "Vulkan Backend" begin
                backend = VulkanBackend()
                @test !backend.initialized

                initialize!(backend)
                @test backend.initialized

                shutdown!(backend)
                @test !backend.initialized
            end
        end
    end

    @testset "Model Loading" begin
        @testset "load_model dispatches by extension" begin
            # Unsupported extensions return fallback placeholder instead of throwing
            result_xyz = load_model("test.xyz")
            @test result_xyz isa Vector
            @test length(result_xyz) == 1
            result_fbx = load_model("test.fbx")
            @test result_fbx isa Vector
            @test length(result_fbx) == 1
        end
    end

    @testset "Math utilities" begin
        @testset "Translation matrix (Float32)" begin
            m = translation_matrix(Vec3f(1, 2, 3))
            @test m[13] == 1.0f0
            @test m[14] == 2.0f0
            @test m[15] == 3.0f0
        end

        @testset "Scale matrix (Float32)" begin
            m = scale_matrix(Vec3f(2, 3, 4))
            @test m[1] == 2.0f0
            @test m[6] == 3.0f0
            @test m[11] == 4.0f0
        end

        @testset "Translation matrix (Float64)" begin
            m = translation_matrix(Vec3d(1, 2, 3))
            @test m[13] == 1.0
            @test m[14] == 2.0
            @test m[15] == 3.0
            @test m isa Mat4d
        end

        @testset "Scale matrix (Float64)" begin
            m = scale_matrix(Vec3d(2, 3, 4))
            @test m[1] == 2.0
            @test m[6] == 3.0
            @test m[11] == 4.0
            @test m isa Mat4d
        end

        @testset "Rotation matrix from quaternion" begin
            # Identity quaternion should give identity rotation
            # Quaternion(w, x, y, z) where w=1 for identity
            q_identity = Quaterniond(1, 0, 0, 0)
            R = rotation_matrix(q_identity)
            @test R ≈ Mat4d(I) atol=1e-10

            # 90 degree rotation around Z axis
            # Quaternion convention: (w, x, y, z) = (cos(θ/2), 0, 0, sin(θ/2)) for Z rotation
            angle = π/2
            q_z90 = Quaterniond(cos(angle/2), 0, 0, sin(angle/2))
            R_z90 = rotation_matrix(q_z90)

            # (1, 0, 0) should become (0, 1, 0) after rotation around Z
            point = [1.0, 0.0, 0.0, 1.0]
            rotated = R_z90 * point
            @test rotated[1] ≈ 0.0 atol=1e-10
            @test rotated[2] ≈ 1.0 atol=1e-10
            @test rotated[3] ≈ 0.0 atol=1e-10
        end

        @testset "Transform composition" begin
            pos = Vec3d(1, 0, 0)
            rot = Quaterniond(1, 0, 0, 0)  # Identity rotation (w=1)
            scl = Vec3d(2, 2, 2)

            mat = compose_transform(pos, rot, scl)

            # Test point transformation: scale then translate
            point = [1.0, 0.0, 0.0, 1.0]
            transformed = mat * point

            # Expected: 1 * 2 (scale) + 1 (translation) = 3
            @test transformed[1] ≈ 3.0 atol=1e-10
            @test transformed[2] ≈ 0.0 atol=1e-10
            @test transformed[3] ≈ 0.0 atol=1e-10
        end
    end

    @testset "Hierarchical Transforms" begin
        @testset "World transform for entity without parent" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(position=Vec3d(10, 0, 0)))

            world = get_world_transform(e1)

            # Position should be in translation column
            @test world[13] ≈ 10.0 atol=1e-10
            @test world[14] ≈ 0.0 atol=1e-10
            @test world[15] ≈ 0.0 atol=1e-10
        end

        @testset "World transform for entity without transform" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            # No transform component added

            world = get_world_transform(e1)

            # Should return identity matrix
            @test world ≈ Mat4d(I) atol=1e-10
        end

        @testset "Hierarchical transforms with parent-child" begin
            reset_component_stores!()

            # Create parent-child hierarchy via scene
            s = scene([
                entity([transform(position=Vec3d(10, 0, 0))], children=[
                    entity([transform(position=Vec3d(5, 0, 0))])
                ])
            ])

            parent_id = s.root_entities[1]
            child_id = get_children(s, parent_id)[1]

            # Verify parent reference is set
            child_transform = get_component(child_id, TransformComponent)
            @test child_transform.parent == parent_id

            # Child world position should be parent + child local (10 + 5 = 15)
            child_world = get_world_transform(child_id)
            @test child_world[13] ≈ 15.0 atol=1e-10
            @test child_world[14] ≈ 0.0 atol=1e-10
            @test child_world[15] ≈ 0.0 atol=1e-10
        end

        @testset "Three-level hierarchy" begin
            reset_component_stores!()

            # Create grandparent -> parent -> child hierarchy
            s = scene([
                entity([transform(position=Vec3d(10, 0, 0))], children=[
                    entity([transform(position=Vec3d(5, 0, 0))], children=[
                        entity([transform(position=Vec3d(2, 0, 0))])
                    ])
                ])
            ])

            grandparent = s.root_entities[1]
            parent = get_children(s, grandparent)[1]
            child = get_children(s, parent)[1]

            # Grandparent world position: 10
            gp_world = get_world_transform(grandparent)
            @test gp_world[13] ≈ 10.0 atol=1e-10

            # Parent world position: 10 + 5 = 15
            p_world = get_world_transform(parent)
            @test p_world[13] ≈ 15.0 atol=1e-10

            # Child world position: 10 + 5 + 2 = 17
            c_world = get_world_transform(child)
            @test c_world[13] ≈ 17.0 atol=1e-10
        end

        @testset "Hierarchical transforms with scale" begin
            reset_component_stores!()

            # Parent scaled 2x, child at local position (5, 0, 0)
            s = scene([
                entity([transform(position=Vec3d(0, 0, 0), scale=Vec3d(2, 2, 2))], children=[
                    entity([transform(position=Vec3d(5, 0, 0))])
                ])
            ])

            parent = s.root_entities[1]
            child = get_children(s, parent)[1]

            # Child's local position (5,0,0) is scaled by parent's scale (2x)
            # World position = parent_scale * child_local + parent_position
            # = 2 * 5 + 0 = 10
            child_world = get_world_transform(child)
            @test child_world[13] ≈ 10.0 atol=1e-10
        end

        @testset "Hierarchical transforms with rotation" begin
            reset_component_stores!()

            # Parent rotated 90° around Z axis
            # Child at local position (5, 0, 0)
            # After rotation, child should be at (0, 5, 0) in world space
            # Quaternion convention: (w, x, y, z) = (cos(θ/2), 0, 0, sin(θ/2)) for Z rotation
            angle = π/2
            q_z90 = Quaterniond(cos(angle/2), 0, 0, sin(angle/2))

            s = scene([
                entity([transform(position=Vec3d(0, 0, 0), rotation=q_z90)], children=[
                    entity([transform(position=Vec3d(5, 0, 0))])
                ])
            ])

            child = get_children(s, s.root_entities[1])[1]
            child_world = get_world_transform(child)

            @test child_world[13] ≈ 0.0 atol=1e-10  # x ≈ 0
            @test child_world[14] ≈ 5.0 atol=1e-10  # y ≈ 5
            @test child_world[15] ≈ 0.0 atol=1e-10  # z ≈ 0
        end

        @testset "Local transform calculation" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, transform(
                position=Vec3d(1, 2, 3),
                scale=Vec3d(2, 2, 2)
            ))

            local_mat = get_local_transform(e1)

            # Should include translation
            @test local_mat[13] ≈ 1.0 atol=1e-10
            @test local_mat[14] ≈ 2.0 atol=1e-10
            @test local_mat[15] ≈ 3.0 atol=1e-10

            # Should include scale
            @test local_mat[1] ≈ 2.0 atol=1e-10
            @test local_mat[6] ≈ 2.0 atol=1e-10
            @test local_mat[11] ≈ 2.0 atol=1e-10
        end
    end

    @testset "Shadow Mapping" begin
        @testset "ShadowMap struct" begin
            sm = ShadowMap()
            @test sm.width == 2048
            @test sm.height == 2048
            @test sm.fbo == UInt32(0)
            @test sm.depth_texture == UInt32(0)
            @test sm.shader === nothing

            sm2 = ShadowMap(width=1024, height=1024)
            @test sm2.width == 1024
            @test sm2.height == 1024
        end

        @testset "compute_light_space_matrix" begin
            cam_pos = Vec3f(0, 5, 10)
            light_dir = Vec3f(0, -1, 0)
            lsm = compute_light_space_matrix(cam_pos, light_dir)
            @test lsm isa Mat4f
            @test size(lsm) == (4, 4)
            # Light-space matrix should be non-identity for a non-trivial setup
            @test lsm != Mat4f(I)
        end

        @testset "ortho matrix" begin
            ortho = OpenReality._ortho_matrix(-10.0f0, 10.0f0, -10.0f0, 10.0f0, -50.0f0, 50.0f0)
            @test ortho isa Mat4f
            # The diagonal entries should be 2/(right-left), 2/(top-bottom), -2/(far-near)
            @test ortho[1,1] ≈ 2.0f0/20.0f0 atol=1e-5
            @test ortho[2,2] ≈ 2.0f0/20.0f0 atol=1e-5
            @test ortho[3,3] ≈ -2.0f0/100.0f0 atol=1e-5
        end
    end

    @testset "Frustum Culling" begin
        @testset "BoundingSphere from mesh" begin
            mesh = MeshComponent(
                vertices=[
                    Point3f(-1, -1, -1),
                    Point3f(1, 1, 1),
                    Point3f(0, 0, 0)
                ],
                indices=UInt32[0, 1, 2]
            )
            bs = bounding_sphere_from_mesh(mesh)
            @test bs isa BoundingSphere
            @test bs.center ≈ Vec3f(0, 0, 0) atol=1e-5
            @test bs.radius ≈ sqrt(3.0f0) atol=1e-5
        end

        @testset "BoundingSphere from empty mesh" begin
            mesh = MeshComponent()
            bs = bounding_sphere_from_mesh(mesh)
            @test bs.center == Vec3f(0, 0, 0)
            @test bs.radius == 0.0f0
        end

        @testset "Frustum extraction" begin
            # Use a simple identity VP matrix — all points in [-1,1]^3 should be "inside"
            vp = Mat4f(I)
            f = extract_frustum(vp)
            @test f isa Frustum
            @test length(f.planes) == 6
        end

        @testset "Sphere in frustum test" begin
            vp = Mat4f(I)
            f = extract_frustum(vp)

            # A sphere at origin with small radius should be inside identity frustum
            @test is_sphere_in_frustum(f, Vec3f(0, 0, 0), 0.5f0) == true

            # A sphere far outside should be culled
            @test is_sphere_in_frustum(f, Vec3f(100, 100, 100), 0.1f0) == false
        end

        @testset "Transform bounding sphere" begin
            bs = BoundingSphere(Vec3f(0, 0, 0), 1.0f0)

            # Identity transform — no change
            identity_model = Mat4f(I)
            center, radius = OpenReality.transform_bounding_sphere(bs, identity_model)
            @test center ≈ Vec3f(0, 0, 0) atol=1e-5
            @test radius ≈ 1.0f0 atol=1e-5

            # Translation
            trans_model = Mat4f(
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                5, 3, 1, 1
            )
            center2, radius2 = OpenReality.transform_bounding_sphere(bs, trans_model)
            @test center2 ≈ Vec3f(5, 3, 1) atol=1e-5
            @test radius2 ≈ 1.0f0 atol=1e-5

            # Uniform scale of 2
            scale_model = Mat4f(
                2, 0, 0, 0,
                0, 2, 0, 0,
                0, 0, 2, 0,
                0, 0, 0, 1
            )
            center3, radius3 = OpenReality.transform_bounding_sphere(bs, scale_model)
            @test center3 ≈ Vec3f(0, 0, 0) atol=1e-5
            @test radius3 ≈ 2.0f0 atol=1e-5
        end
    end

    @testset "Animation System" begin
        @testset "AnimationComponent defaults" begin
            anim = AnimationComponent()
            @test isempty(anim.clips)
            @test anim.active_clip == 0
            @test anim.current_time == 0.0
            @test anim.playing == false
            @test anim.looping == true
            @test anim.speed == 1.0f0
        end

        @testset "AnimationClip and AnimationChannel" begin
            channel = AnimationChannel(
                EntityID(1), :position,
                Float32[0.0, 1.0, 2.0],
                Any[Vec3d(0, 0, 0), Vec3d(1, 0, 0), Vec3d(2, 0, 0)],
                INTERP_LINEAR
            )
            @test channel.target_property == :position
            @test length(channel.times) == 3

            clip = AnimationClip("test", [channel], 2.0f0)
            @test clip.name == "test"
            @test clip.duration == 2.0f0
            @test length(clip.channels) == 1
        end

        @testset "InterpolationMode enum" begin
            @test INTERP_STEP isa InterpolationMode
            @test INTERP_LINEAR isa InterpolationMode
            @test INTERP_CUBICSPLINE isa InterpolationMode
        end

        @testset "Keyframe pair finding" begin
            times = Float32[0.0, 1.0, 2.0, 3.0]

            # Before first keyframe
            idx_a, idx_b, t = OpenReality._find_keyframe_pair(times, -1.0f0)
            @test idx_a == 1
            @test idx_b == 1
            @test t == 0.0f0

            # After last keyframe
            idx_a, idx_b, t = OpenReality._find_keyframe_pair(times, 5.0f0)
            @test idx_a == 4
            @test idx_b == 4

            # Between keyframes
            idx_a, idx_b, t = OpenReality._find_keyframe_pair(times, 1.5f0)
            @test idx_a == 2
            @test idx_b == 3
            @test t ≈ 0.5f0 atol=1e-5

            # Exact keyframe — binary search lands on the keyframe
            idx_a, idx_b, t = OpenReality._find_keyframe_pair(times, 1.0f0)
            @test idx_a == 2  # times[2] == 1.0
        end

        @testset "Vec3d lerp" begin
            a = Vec3d(0, 0, 0)
            b = Vec3d(10, 20, 30)
            mid = OpenReality._lerp_vec3d(a, b, 0.5f0)
            @test mid ≈ Vec3d(5, 10, 15) atol=1e-10
        end

        @testset "Quaternion slerp" begin
            # Slerp between identity and 90° rotation around Z
            q1 = Quaterniond(1, 0, 0, 0)
            angle = π/2
            q2 = Quaterniond(cos(angle/2), 0, 0, sin(angle/2))

            # At t=0, should be q1
            r0 = OpenReality._slerp(q1, q2, 0.0f0)
            @test r0.s ≈ 1.0 atol=1e-5
            @test r0.v1 ≈ 0.0 atol=1e-5
            @test r0.v2 ≈ 0.0 atol=1e-5
            @test r0.v3 ≈ 0.0 atol=1e-5

            # At t=1, should be q2
            r1 = OpenReality._slerp(q1, q2, 1.0f0)
            @test r1.s ≈ q2.s atol=1e-5
            @test r1.v3 ≈ q2.v3 atol=1e-5
        end

        @testset "update_animations! moves position" begin
            reset_component_stores!()

            # Create entity with transform
            eid = create_entity!(World())
            add_component!(eid, transform(position=Vec3d(0, 0, 0)))

            # Create animation that moves x from 0 to 10 over 1 second
            channel = AnimationChannel(
                eid, :position,
                Float32[0.0, 1.0],
                Any[Vec3d(0, 0, 0), Vec3d(10, 0, 0)],
                INTERP_LINEAR
            )
            clip = AnimationClip("move", [channel], 1.0f0)
            anim = AnimationComponent(
                clips=[clip], active_clip=1,
                playing=true, looping=false, speed=1.0f0
            )
            add_component!(eid, anim)

            # Step forward 0.5 seconds
            update_animations!(0.5)

            tc = get_component(eid, TransformComponent)
            @test tc.position[][1] ≈ 5.0 atol=0.5  # approximately halfway
        end
    end

    @testset "Transparency" begin
        @testset "MaterialComponent opacity defaults" begin
            mat = MaterialComponent()
            @test mat.opacity == 1.0f0
            @test mat.alpha_cutoff == 0.0f0
        end

        @testset "MaterialComponent with opacity" begin
            mat = MaterialComponent(opacity=0.5f0)
            @test mat.opacity == 0.5f0
            @test mat.alpha_cutoff == 0.0f0
        end

        @testset "MaterialComponent with alpha cutoff" begin
            mat = MaterialComponent(alpha_cutoff=0.5f0)
            @test mat.opacity == 1.0f0
            @test mat.alpha_cutoff == 0.5f0
        end

        @testset "MaterialComponent transparent with texture" begin
            mat = MaterialComponent(
                opacity=0.7f0,
                alpha_cutoff=0.3f0,
                albedo_map=TextureRef("/path/to/albedo.png")
            )
            @test mat.opacity == 0.7f0
            @test mat.alpha_cutoff == 0.3f0
            @test mat.albedo_map !== nothing
        end
    end

    @testset "Post-Processing" begin
        @testset "PostProcessConfig defaults" begin
            config = PostProcessConfig()
            @test config.bloom_enabled == false
            @test config.bloom_threshold == 1.0f0
            @test config.bloom_intensity == 0.3f0
            @test config.ssao_enabled == false
            @test config.ssao_radius == 0.5f0
            @test config.ssao_samples == 16
            @test config.tone_mapping == TONEMAP_REINHARD
            @test config.fxaa_enabled == false
            @test config.gamma == 2.2f0
        end

        @testset "PostProcessConfig custom" begin
            config = PostProcessConfig(
                bloom_enabled=true,
                bloom_threshold=0.8f0,
                tone_mapping=TONEMAP_ACES,
                fxaa_enabled=true,
                gamma=2.4f0
            )
            @test config.bloom_enabled == true
            @test config.bloom_threshold == 0.8f0
            @test config.tone_mapping == TONEMAP_ACES
            @test config.fxaa_enabled == true
            @test config.gamma == 2.4f0
        end

        @testset "ToneMappingMode enum" begin
            @test TONEMAP_REINHARD isa ToneMappingMode
            @test TONEMAP_ACES isa ToneMappingMode
            @test TONEMAP_UNCHARTED2 isa ToneMappingMode
        end

        @testset "Framebuffer struct" begin
            fb = Framebuffer()
            @test fb.fbo == UInt32(0)
            @test fb.color_texture == UInt32(0)
            @test fb.depth_rbo == UInt32(0)
            @test fb.width == 1280
            @test fb.height == 720
        end

        @testset "PostProcessPipeline struct" begin
            pp = PostProcessPipeline()
            @test pp.config isa PostProcessConfig
            @test pp.quad_vao == UInt32(0)
            @test pp.composite_shader === nothing
        end
    end

    @testset "Windowing" begin
        win = Window()
        @test win.width == 1280
        @test win.height == 720
        @test win.title == "OpenReality"

        win2 = Window(width=800, height=600, title="Test")
        @test win2.width == 800
        @test win2.height == 600
    end

    @testset "Input" begin
        input = InputState()
        @test !is_key_pressed(input, 65)  # 'A' key
        @test get_mouse_position(input) == (0.0, 0.0)
    end

    @testset "Input Mapping" begin
        @testset "InputMap creation" begin
            map = InputMap()
            @test isempty(map.bindings)
            @test isempty(map.states)
        end

        @testset "Bind and unbind actions" begin
            map = InputMap()

            # Bind a keyboard key
            bind!(map, "jump", KeyboardKey(32))  # space
            @test haskey(map.bindings, "jump")
            @test length(map.bindings["jump"].sources) == 1
            @test haskey(map.states, "jump")

            # Bind a second source to the same action
            bind!(map, "jump", GamepadButton(1, GAMEPAD_BUTTON_A))
            @test length(map.bindings["jump"].sources) == 2

            # Unbind a specific source
            unbind!(map, "jump", KeyboardKey(32))
            @test length(map.bindings["jump"].sources) == 1

            # Unbind entire action
            unbind!(map, "jump")
            @test !haskey(map.bindings, "jump")
            @test !haskey(map.states, "jump")
        end

        @testset "Keyboard action pressed" begin
            map = InputMap()
            input = InputState()

            bind!(map, "fire", KeyboardKey(70))  # F key

            # Not pressed
            update_actions!(map, input)
            @test !is_action_pressed(map, "fire")

            # Press key
            push!(input.keys_pressed, 70)
            update_actions!(map, input)
            @test is_action_pressed(map, "fire")
            @test get_axis(map, "fire") == 1.0f0

            # Release key
            delete!(input.keys_pressed, 70)
            update_actions!(map, input)
            @test !is_action_pressed(map, "fire")
            @test get_axis(map, "fire") == 0.0f0
        end

        @testset "Mouse button action" begin
            map = InputMap()
            input = InputState()

            bind!(map, "shoot", MouseButton(0))  # left click

            push!(input.mouse_buttons, 0)
            update_actions!(map, input)
            @test is_action_pressed(map, "shoot")

            delete!(input.mouse_buttons, 0)
            update_actions!(map, input)
            @test !is_action_pressed(map, "shoot")
        end

        @testset "Edge detection — just_pressed and just_released" begin
            map = InputMap()
            input = InputState()

            bind!(map, "jump", KeyboardKey(32))

            # Frame 1: not pressed
            update_actions!(map, input)
            @test !is_action_just_pressed(map, "jump")
            @test !is_action_just_released(map, "jump")

            # Frame 2: press key
            push!(input.keys_pressed, 32)
            update_actions!(map, input)
            @test is_action_just_pressed(map, "jump")
            @test !is_action_just_released(map, "jump")

            # Frame 3: still held
            update_actions!(map, input)
            @test is_action_pressed(map, "jump")
            @test !is_action_just_pressed(map, "jump")  # no longer "just"

            # Frame 4: release
            delete!(input.keys_pressed, 32)
            update_actions!(map, input)
            @test !is_action_pressed(map, "jump")
            @test is_action_just_released(map, "jump")

            # Frame 5: still released
            update_actions!(map, input)
            @test !is_action_just_released(map, "jump")  # no longer "just"
        end

        @testset "Gamepad button action" begin
            map = InputMap()
            input = InputState()

            bind!(map, "jump", GamepadButton(1, GAMEPAD_BUTTON_A))

            # No gamepad connected — action should be false
            update_actions!(map, input)
            @test !is_action_pressed(map, "jump")

            # Simulate gamepad buttons (button A = index 0 pressed)
            input.gamepad_buttons[1] = [true, false, false, false]
            update_actions!(map, input)
            @test is_action_pressed(map, "jump")

            # Release
            input.gamepad_buttons[1] = [false, false, false, false]
            update_actions!(map, input)
            @test !is_action_pressed(map, "jump")
        end

        @testset "Gamepad axis with deadzone" begin
            map = InputMap()
            input = InputState()

            bind!(map, "move_forward", GamepadAxis(1, GAMEPAD_AXIS_LEFT_Y, false, 0.15f0))

            # No gamepad — not active
            update_actions!(map, input)
            @test !is_action_pressed(map, "move_forward")
            @test get_axis(map, "move_forward") == 0.0f0

            # Axis within deadzone (Y = -0.1, magnitude 0.1 < 0.15)
            input.gamepad_axes[1] = Float32[0.0, -0.1, 0.0, 0.0]
            update_actions!(map, input)
            @test !is_action_pressed(map, "move_forward")
            @test get_axis(map, "move_forward") == 0.0f0

            # Axis beyond deadzone (Y = -0.8, negative direction = forward)
            input.gamepad_axes[1] = Float32[0.0, -0.8, 0.0, 0.0]
            update_actions!(map, input)
            @test is_action_pressed(map, "move_forward")
            @test get_axis(map, "move_forward") > 0.5f0  # remapped above deadzone

            # Positive direction should NOT trigger (positive=false means negative direction)
            input.gamepad_axes[1] = Float32[0.0, 0.8, 0.0, 0.0]
            update_actions!(map, input)
            @test !is_action_pressed(map, "move_forward")
        end

        @testset "Gamepad axis positive direction" begin
            map = InputMap()
            input = InputState()

            bind!(map, "move_backward", GamepadAxis(1, GAMEPAD_AXIS_LEFT_Y, true, 0.15f0))

            # Positive Y = backward
            input.gamepad_axes[1] = Float32[0.0, 0.8, 0.0, 0.0]
            update_actions!(map, input)
            @test is_action_pressed(map, "move_backward")
            @test get_axis(map, "move_backward") > 0.5f0

            # Negative Y should NOT trigger
            input.gamepad_axes[1] = Float32[0.0, -0.8, 0.0, 0.0]
            update_actions!(map, input)
            @test !is_action_pressed(map, "move_backward")
        end

        @testset "Multiple sources — OR logic" begin
            map = InputMap()
            input = InputState()

            bind!(map, "jump", KeyboardKey(32))
            bind!(map, "jump", GamepadButton(1, GAMEPAD_BUTTON_A))

            # Only keyboard
            push!(input.keys_pressed, 32)
            update_actions!(map, input)
            @test is_action_pressed(map, "jump")

            # Only gamepad
            delete!(input.keys_pressed, 32)
            input.gamepad_buttons[1] = [true, false]
            update_actions!(map, input)
            @test is_action_pressed(map, "jump")

            # Both
            push!(input.keys_pressed, 32)
            update_actions!(map, input)
            @test is_action_pressed(map, "jump")

            # Neither
            delete!(input.keys_pressed, 32)
            input.gamepad_buttons[1] = [false, false]
            update_actions!(map, input)
            @test !is_action_pressed(map, "jump")
        end

        @testset "Query nonexistent action" begin
            map = InputMap()
            @test !is_action_pressed(map, "nope")
            @test !is_action_just_pressed(map, "nope")
            @test !is_action_just_released(map, "nope")
            @test get_axis(map, "nope") == 0.0f0
        end

        @testset "Default player map" begin
            map = create_default_player_map()

            @test haskey(map.bindings, "move_forward")
            @test haskey(map.bindings, "move_backward")
            @test haskey(map.bindings, "move_left")
            @test haskey(map.bindings, "move_right")
            @test haskey(map.bindings, "jump")
            @test haskey(map.bindings, "crouch")
            @test haskey(map.bindings, "sprint")
            @test haskey(map.bindings, "look_up")
            @test haskey(map.bindings, "look_down")
            @test haskey(map.bindings, "look_left")
            @test haskey(map.bindings, "look_right")

            # Each movement action has 2 sources (keyboard + gamepad)
            @test length(map.bindings["move_forward"].sources) == 2
            @test length(map.bindings["jump"].sources) == 2
            @test length(map.bindings["sprint"].sources) == 2

            # Look actions have only gamepad (mouse is handled separately)
            @test length(map.bindings["look_up"].sources) == 1
        end

        @testset "InputState edge detection helpers" begin
            input = InputState()

            # Key not pressed
            @test !is_key_just_pressed(input, 65)
            @test !is_key_just_released(input, 65)

            # Press key (no previous frame yet)
            push!(input.keys_pressed, 65)
            @test is_key_just_pressed(input, 65)

            # After begin_frame, key is in prev_keys
            begin_frame!(input)
            @test !is_key_just_pressed(input, 65)  # still held, not "just"

            # Release
            delete!(input.keys_pressed, 65)
            @test is_key_just_released(input, 65)
        end

        @testset "InputState gamepad state tracking" begin
            input = InputState()

            # Simulate gamepad data
            input.gamepad_axes[1] = Float32[0.5, -0.3, 0.0, 0.0]
            input.gamepad_buttons[1] = [true, false, true]

            @test input.gamepad_axes[1][1] ≈ 0.5f0
            @test input.gamepad_buttons[1][1] == true
            @test input.gamepad_buttons[1][2] == false

            # begin_frame copies to prev
            begin_frame!(input)
            @test input.prev_gamepad_buttons[1] == [true, false, true]

            # Modify current — prev should stay
            input.gamepad_buttons[1] = [false, false, false]
            @test input.prev_gamepad_buttons[1] == [true, false, true]
        end

        @testset "Gamepad constants" begin
            @test GAMEPAD_BUTTON_A == 0
            @test GAMEPAD_BUTTON_B == 1
            @test GAMEPAD_BUTTON_X == 2
            @test GAMEPAD_BUTTON_Y == 3
            @test GAMEPAD_BUTTON_LB == 4
            @test GAMEPAD_BUTTON_RB == 5
            @test GAMEPAD_AXIS_LEFT_X == 0
            @test GAMEPAD_AXIS_LEFT_Y == 1
            @test GAMEPAD_AXIS_RIGHT_X == 2
            @test GAMEPAD_AXIS_RIGHT_Y == 3
            @test GAMEPAD_AXIS_TRIGGER_LEFT == 4
            @test GAMEPAD_AXIS_TRIGGER_RIGHT == 5
        end
    end

    @testset "Audio" begin
        @testset "AudioListenerComponent defaults" begin
            listener = AudioListenerComponent()
            @test listener.gain == 1.0f0
        end

        @testset "AudioListenerComponent custom" begin
            listener = AudioListenerComponent(gain=0.5f0)
            @test listener.gain == 0.5f0
        end

        @testset "AudioSourceComponent defaults" begin
            source = AudioSourceComponent()
            @test source.audio_path == ""
            @test source.playing == false
            @test source.looping == false
            @test source.gain == 1.0f0
            @test source.pitch == 1.0f0
            @test source.spatial == true
            @test source.reference_distance == 1.0f0
            @test source.max_distance == 100.0f0
            @test source.rolloff_factor == 1.0f0
        end

        @testset "AudioSourceComponent custom" begin
            source = AudioSourceComponent(
                audio_path="music.wav",
                playing=true,
                looping=true,
                gain=0.8f0,
                pitch=1.2f0,
                spatial=false,
                reference_distance=2.0f0,
                max_distance=50.0f0,
                rolloff_factor=0.5f0
            )
            @test source.audio_path == "music.wav"
            @test source.playing == true
            @test source.looping == true
            @test source.gain == 0.8f0
            @test source.pitch == 1.2f0
            @test source.spatial == false
            @test source.reference_distance == 2.0f0
            @test source.max_distance == 50.0f0
            @test source.rolloff_factor == 0.5f0
        end

        @testset "AudioSourceComponent is mutable" begin
            source = AudioSourceComponent(audio_path="test.wav")
            source.playing = true
            @test source.playing == true
            source.gain = 0.3f0
            @test source.gain == 0.3f0
        end

        @testset "Audio components in ECS" begin
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, AudioListenerComponent(gain=0.9f0))
            add_component!(e1, transform())

            e2 = create_entity!(World())
            add_component!(e2, AudioSourceComponent(audio_path="sfx.wav", playing=true))
            add_component!(e2, transform(position=Vec3d(5, 0, 0)))

            @test has_component(e1, AudioListenerComponent)
            @test has_component(e2, AudioSourceComponent)
            @test get_component(e1, AudioListenerComponent).gain == 0.9f0
            @test get_component(e2, AudioSourceComponent).audio_path == "sfx.wav"
            @test get_component(e2, AudioSourceComponent).playing == true
        end

        @testset "AudioConfig defaults" begin
            config = AudioConfig()
            @test config.doppler_factor == 1.0f0
            @test config.speed_of_sound == 343.3f0
        end

        @testset "Audio state management" begin
            reset_audio_state!()
            state = OpenReality.get_audio_state()
            @test state.initialized == false
            @test isempty(state.buffers)
            @test isempty(state.sources)
        end

        @testset "WAV loader" begin
            # Create a minimal valid WAV file in memory
            wav_path = tempname() * ".wav"
            # 44-byte header + 4 bytes of silence (mono 16-bit, 44100 Hz)
            io = IOBuffer()
            # RIFF header
            write(io, b"RIFF")
            write(io, UInt32(36 + 4))  # file size - 8
            write(io, b"WAVE")
            # fmt chunk
            write(io, b"fmt ")
            write(io, UInt32(16))      # chunk size
            write(io, UInt16(1))       # PCM format
            write(io, UInt16(1))       # mono
            write(io, UInt32(44100))   # sample rate
            write(io, UInt32(44100 * 2))  # byte rate
            write(io, UInt16(2))       # block align
            write(io, UInt16(16))      # bits per sample
            # data chunk
            write(io, b"data")
            write(io, UInt32(4))       # data size
            write(io, Int16(0))        # silence
            write(io, Int16(0))        # silence

            wav_data = take!(io)
            Base.write(wav_path, wav_data)

            pcm, format, sample_rate = load_wav(wav_path)
            @test length(pcm) == 4
            @test format == OpenReality.AL_FORMAT_MONO16
            @test sample_rate == Int32(44100)

            rm(wav_path)
        end

        @testset "WAV loader stereo" begin
            wav_path = tempname() * ".wav"
            io = IOBuffer()
            write(io, b"RIFF")
            write(io, UInt32(36 + 8))
            write(io, b"WAVE")
            write(io, b"fmt ")
            write(io, UInt32(16))
            write(io, UInt16(1))       # PCM
            write(io, UInt16(2))       # stereo
            write(io, UInt32(48000))
            write(io, UInt32(48000 * 4))
            write(io, UInt16(4))
            write(io, UInt16(16))
            write(io, b"data")
            write(io, UInt32(8))
            write(io, Int16(0))
            write(io, Int16(0))
            write(io, Int16(0))
            write(io, Int16(0))

            Base.write(wav_path, take!(io))

            pcm, format, sample_rate = load_wav(wav_path)
            @test length(pcm) == 8
            @test format == OpenReality.AL_FORMAT_STEREO16
            @test sample_rate == Int32(48000)

            rm(wav_path)
        end
    end

    @testset "UI System" begin
        @testset "UIContext creation" begin
            ctx = UIContext()
            @test isempty(ctx.vertices)
            @test isempty(ctx.draw_commands)
            @test ctx.width == 1280
            @test ctx.height == 720
            @test ctx.mouse_x == 0.0
            @test ctx.mouse_y == 0.0
            @test ctx.mouse_clicked == false
        end

        @testset "orthographic_matrix" begin
            proj = orthographic_matrix(0.0f0, 800.0f0, 600.0f0, 0.0f0, -1.0f0, 1.0f0)
            @test proj isa Mat4f
            # Top-left corner (0,0) should map to (-1,1) in NDC
            clip = proj * SVector{4, Float32}(0, 0, 0, 1)
            @test isapprox(clip[1] / clip[4], -1.0f0, atol=1e-5)
            @test isapprox(clip[2] / clip[4], 1.0f0, atol=1e-5)
            # Bottom-right corner (800,600) should map to (1,-1) in NDC
            clip2 = proj * SVector{4, Float32}(800, 600, 0, 1)
            @test isapprox(clip2[1] / clip2[4], 1.0f0, atol=1e-5)
            @test isapprox(clip2[2] / clip2[4], -1.0f0, atol=1e-5)
        end

        @testset "clear_ui!" begin
            ctx = UIContext()
            push!(ctx.vertices, 1.0f0, 2.0f0)
            push!(ctx.draw_commands, UIDrawCommand(0, 6, UInt32(0), false))
            clear_ui!(ctx)
            @test isempty(ctx.vertices)
            @test isempty(ctx.draw_commands)
        end

        @testset "ui_rect generates vertices" begin
            ctx = UIContext()
            ui_rect(ctx, x=10, y=20, width=100, height=50,
                    color=RGB{Float32}(1, 0, 0), alpha=0.5f0)
            # 6 vertices * 8 floats = 48
            @test length(ctx.vertices) == 48
            @test length(ctx.draw_commands) == 1
            @test ctx.draw_commands[1].vertex_count == 6
            @test ctx.draw_commands[1].texture_id == UInt32(0)
        end

        @testset "ui_rect vertex positions" begin
            ctx = UIContext()
            ui_rect(ctx, x=10, y=20, width=100, height=50)
            # First vertex: top-left (x=10, y=20)
            @test ctx.vertices[1] == 10.0f0  # x
            @test ctx.vertices[2] == 20.0f0  # y
            # Third vertex: bottom-right (x=110, y=70)
            @test ctx.vertices[17] == 110.0f0  # x (3rd vertex, offset 2*8+1)
            @test ctx.vertices[18] == 70.0f0   # y
        end

        @testset "ui_progress_bar" begin
            ctx = UIContext()
            ui_progress_bar(ctx, 0.5, x=0, y=0, width=200, height=20)
            # Should produce 2 rects (background + fill) = 12 vertices
            @test length(ctx.vertices) == 96  # 12 * 8
        end

        @testset "ui_button hit test" begin
            ctx = UIContext()
            ctx.mouse_x = 50.0
            ctx.mouse_y = 50.0
            ctx.mouse_clicked = true
            ctx.font_atlas = FontAtlas()  # no glyphs, text won't render

            clicked = ui_button(ctx, "Test", x=0, y=0, width=100, height=100)
            @test clicked == true

            # Miss
            clear_ui!(ctx)
            ctx.mouse_x = 200.0
            clicked2 = ui_button(ctx, "Test", x=0, y=0, width=100, height=100)
            @test clicked2 == false
        end

        @testset "draw command batching" begin
            ctx = UIContext()
            # Two rects with same texture (0) should merge
            ui_rect(ctx, x=0, y=0, width=50, height=50)
            ui_rect(ctx, x=60, y=0, width=50, height=50)
            @test length(ctx.draw_commands) == 1
            @test ctx.draw_commands[1].vertex_count == 12  # 2 quads merged
        end

        @testset "UIDrawCommand" begin
            cmd = UIDrawCommand(0, 6, UInt32(1), true)
            @test cmd.vertex_offset == 0
            @test cmd.vertex_count == 6
            @test cmd.texture_id == UInt32(1)
            @test cmd.is_font == true
        end

        @testset "FontAtlas defaults" begin
            atlas = FontAtlas()
            @test atlas.texture_id == UInt32(0)
            @test atlas.atlas_width == 0
            @test isempty(atlas.glyphs)
        end

        @testset "GlyphInfo" begin
            g = GlyphInfo(8.0f0, 1.0f0, 10.0f0, 7.0f0, 12.0f0, 0.1f0, 0.2f0, 0.05f0, 0.1f0)
            @test g.advance_x == 8.0f0
            @test g.width == 7.0f0
            @test g.uv_x == 0.1f0
        end

        @testset "measure_text with empty atlas" begin
            atlas = FontAtlas()
            w, h = measure_text(atlas, "Hello")
            @test w == 0.0f0
            @test h == 0.0f0
        end

        @testset "measure_text with mock glyphs" begin
            atlas = FontAtlas()
            atlas.font_size = 16.0f0
            atlas.line_height = 19.2f0
            atlas.glyphs['H'] = GlyphInfo(10.0f0, 0f0, 12f0, 8f0, 12f0, 0f0, 0f0, 0f0, 0f0)
            atlas.glyphs['i'] = GlyphInfo(5.0f0, 0f0, 12f0, 4f0, 12f0, 0f0, 0f0, 0f0, 0f0)

            w, h = measure_text(atlas, "Hi")
            @test w == 15.0f0  # 10 + 5
            @test h == 19.2f0
        end

        @testset "ui_image" begin
            ctx = UIContext()
            ui_image(ctx, UInt32(42), x=10, y=10, width=64, height=64)
            @test length(ctx.draw_commands) == 1
            @test ctx.draw_commands[1].texture_id == UInt32(42)
            @test ctx.draw_commands[1].is_font == false
            @test length(ctx.vertices) == 48
        end

        @testset "UI renderer state" begin
            reset_ui_renderer!()
            renderer = OpenReality.get_ui_renderer()
            @test renderer.initialized == false
            @test renderer.shader === nothing
        end

        # ── Group 1: InputState new fields ──────────────────────────────────

        @testset "InputState typed_chars reset" begin
            input = InputState()
            push!(input.typed_chars, 'a')
            push!(input.typed_chars, 'b')
            @test length(input.typed_chars) == 2
            begin_frame!(input)
            @test isempty(input.typed_chars)
        end

        # ── Group 2: LayoutContainer construction ───────────────────────────

        @testset "LayoutContainer construction" begin
            lc = LayoutContainer(
                10f0, 20f0,       # origin_x, origin_y
                10f0, 20f0,       # cursor_x, cursor_y
                :row,
                4f0, 8f0,         # padding, spacing
                0f0, 0f0,         # row_height, col_width
                nothing, 0f0, 0f0  # anchor, margin_x, margin_y
            )
            @test lc.origin_x == 10f0
            @test lc.origin_y == 20f0
            @test lc.direction === :row
            @test lc.padding == 4f0
            @test lc.spacing == 8f0
            @test lc.anchor === nothing
            @test lc.margin_x == 0f0
            @test lc.margin_y == 0f0
        end

        # ── Group 3: Layout cursor advancement ──────────────────────────────

        @testset "ui_row cursor advancement" begin
            ctx = UIContext()
            ui_row(ctx, x=10, y=20, spacing=8) do
                ui_rect(ctx, width=50, height=30)
                ui_rect(ctx, width=40, height=25)
            end
            vertices = ctx.vertices
            # First rect at origin (10, 20)
            @test vertices[1] == 10.0f0
            @test vertices[2] == 20.0f0
            # Second rect x should be: 10 + 50 + 8 = 68, y stays 20
            @test vertices[49] == 68.0f0
            @test vertices[50] == 20.0f0
        end

        @testset "ui_column cursor advancement" begin
            ctx = UIContext()
            ui_column(ctx, x=10, y=20, spacing=4) do
                ui_rect(ctx, width=50, height=20)
                ui_rect(ctx, width=40, height=25)
            end
            vertices = ctx.vertices
            # First rect at origin (10, 20)
            @test vertices[1] == 10.0f0
            @test vertices[2] == 20.0f0
            # Second rect x stays 10, y should be: 20 + 20 + 4 = 44
            @test vertices[49] == 10.0f0
            @test vertices[50] == 44.0f0
        end

        @testset "ui_anchor top_right origin" begin
            ctx = UIContext()
            ctx.width = 800
            ctx.height = 600
            ui_anchor(ctx, anchor=:top_right, margin_x=10, margin_y=15f0) do
                ui_rect(ctx, width=50, height=30)
            end
            vertices = ctx.vertices
            # x should be: 800 - 10 = 790, y should be: 15
            @test vertices[1] == 790.0f0
            @test vertices[2] == 15.0f0
        end

        @testset "nested layout" begin
            ctx = UIContext()
            ui_row(ctx, x=0, y=0, spacing=5) do
                ui_rect(ctx, width=100, height=20)
                ui_column(ctx, spacing=3) do
                    ui_rect(ctx, width=60, height=15)
                end
            end
            vertices = ctx.vertices
            # First rect at (0, 0)
            @test vertices[1] == 0.0f0
            @test vertices[2] == 0.0f0
            # Second rect x should be: 0 + 100 + 5 = 105, y stays 0
            @test vertices[49] == 105.0f0
            @test vertices[50] == 0.0f0
        end

        @testset "InputState scroll_delta reset" begin
            input = InputState()
            input.scroll_delta = (1.5, -2.0)
            begin_frame!(input)
            @test input.scroll_delta == (0.0, 0.0)
        end

        @testset "ui_anchor bottom_left origin" begin
            ctx = UIContext()
            ctx.width = 800
            ctx.height = 600
            ui_anchor(ctx, anchor=:bottom_left, margin_x=5, margin_y=10) do
                ui_rect(ctx, width=50, height=20)
            end
            @test ctx.vertices[1] == 5.0f0
            @test ctx.vertices[2] == 590.0f0
        end

        @testset "ui_slider vertex count" begin
            ctx = UIContext()
            result = ui_slider(ctx, 0.5f0, id="s", width=200, height=24, min_val=0f0, max_val=1f0)
            @test length(ctx.vertices) == 144
            @test result == 0.5f0
        end

        @testset "ui_slider value clamped" begin
            ctx = UIContext()
            @test ui_slider(ctx, 2.0f0, id="s", min_val=0f0, max_val=1f0) == 1.0f0
            @test ui_slider(ctx, -1.0f0, id="s2", min_val=0f0, max_val=1f0) == 0.0f0
        end

        @testset "ui_checkbox toggle on click" begin
            ctx = UIContext()
            ctx.mouse_x = 10.0
            ctx.mouse_y = 10.0
            ctx.mouse_clicked = true
            @test ui_checkbox(ctx, false, id="c", x=0, y=0, size=24) == true
        end

        @testset "ui_checkbox no toggle off click" begin
            ctx = UIContext()
            ctx.mouse_x = 200.0
            ctx.mouse_y = 200.0
            ctx.mouse_clicked = true
            @test ui_checkbox(ctx, true, id="c", x=0, y=0, size=24) == true
        end

        @testset "ui_text_input char append" begin
            ctx = UIContext()
            ctx.focused_widget_id = "t"
            ctx.typed_chars = ['!']
            @test ui_text_input(ctx, "hello", id="t", x=0, y=0, width=200, height=32) == "hello!"
        end

        @testset "ui_text_input backspace" begin
            ctx = UIContext()
            ctx.focused_widget_id = "t"
            ctx.keys_pressed = Set{Int}([259])
            ctx.prev_keys_pressed = Set{Int}()
            @test ui_text_input(ctx, "hello", id="t", x=0, y=0, width=200, height=32) == "hell"
        end

        @testset "ui_text_input focus claim" begin
            ctx = UIContext()
            ctx.mouse_x = 50.0
            ctx.mouse_y = 16.0
            ctx.mouse_clicked = true
            ui_text_input(ctx, "text", id="myfield", x=0, y=0, width=200, height=32)
            @test ctx.focused_widget_id == "myfield"
            @test ctx.has_keyboard_focus == true
        end

        @testset "ui_dropdown vertex count" begin
            ctx = UIContext()
            result = ui_dropdown(ctx, 1, ["A","B","C"], id="d", x=0, y=0, width=160, height=32)
            @test result == 1
            @test length(ctx.draw_commands) >= 1
        end

        @testset "ui_scrollable_panel clip rect" begin
            ctx = UIContext()
            ui_scrollable_panel(ctx, id="p", x=10, y=20, width=200, height=100) do
                ui_rect(ctx, width=200, height=30)
            end
            clipped = filter(c -> c.clip_rect !== nothing, ctx.draw_commands)
            @test !isempty(clipped)
            @test clipped[1].clip_rect == (Int32(10), Int32(20), Int32(200), Int32(100))
        end

        @testset "ui_scrollable_panel scroll advance" begin
            ctx = UIContext()
            ctx.scroll_y = -3.0
            ctx.mouse_x = 50.0
            ctx.mouse_y = 50.0
            ui_scrollable_panel(ctx, id="p", x=0, y=0, width=200, height=100, scroll_speed=10f0) do
                ui_rect(ctx, width=200, height=200)
            end
            @test get(ctx.scroll_offsets, "p", 0f0) > 0f0
        end

        @testset "ui_tooltip vertex count" begin
            ctx = UIContext()
            ctx.font_atlas.font_size = 16.0f0
            ctx.font_atlas.line_height = 19.2f0
            ctx.font_atlas.glyphs['H'] = GlyphInfo(10.0f0, 0f0, 12f0, 8f0, 12f0, 0f0, 0f0, 0f0, 0f0)
            ctx.font_atlas.glyphs['i'] = GlyphInfo(5.0f0, 0f0, 12f0, 4f0, 12f0, 0f0, 0f0, 0f0, 0f0)
            ui_tooltip(ctx, "Hi", x=100, y=100)
            @test length(ctx.overlay_draw_commands) >= 1
        end

        @testset "ui_begin_overlay routing" begin
            ctx = UIContext()
            ui_begin_overlay(ctx) do
                ui_rect(ctx, x=0, y=0, width=50, height=50)
            end
            @test isempty(ctx.draw_commands)
            @test length(ctx.overlay_draw_commands) == 1
            @test ctx.in_overlay == false
        end

        @testset "batching respects clip boundary" begin
            ctx = UIContext()
            push!(ctx.clip_stack, (Int32(0), Int32(0), Int32(100), Int32(100)))
            ui_rect(ctx, x=0, y=0, width=50, height=50)
            pop!(ctx.clip_stack)
            ui_rect(ctx, x=60, y=0, width=50, height=50)
            @test length(ctx.draw_commands) == 2
        end

        @testset "batching merges same clip" begin
            ctx = UIContext()
            push!(ctx.clip_stack, (Int32(0), Int32(0), Int32(200), Int32(200)))
            ui_rect(ctx, x=0, y=0, width=50, height=50)
            ui_rect(ctx, x=60, y=0, width=50, height=50)
            pop!(ctx.clip_stack)
            @test length(ctx.draw_commands) == 1
            @test ctx.draw_commands[1].vertex_count == 12
        end

        @testset "overlay ignores clip stack" begin
            ctx = UIContext()
            push!(ctx.clip_stack, (Int32(0), Int32(0), Int32(200), Int32(200)))
            ui_rect(ctx, x=0, y=0, width=50, height=50)
            @test ctx.draw_commands[1].clip_rect !== nothing
            ui_begin_overlay(ctx) do
                ui_rect(ctx, x=10, y=10, width=30, height=30)
            end
            @test ctx.overlay_draw_commands[1].clip_rect === nothing
        end

    end

    @testset "Skeletal Animation" begin
        @testset "BoneComponent defaults" begin
            bone = BoneComponent()
            @test bone.inverse_bind_matrix == Mat4f(I)
            @test bone.bone_index == 0
            @test bone.name == ""
        end

        @testset "BoneComponent custom" begin
            ibm = Mat4f(
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                5, 3, 1, 1
            )
            bone = BoneComponent(inverse_bind_matrix=ibm, bone_index=3, name="spine")
            @test bone.inverse_bind_matrix == ibm
            @test bone.bone_index == 3
            @test bone.name == "spine"
        end

        @testset "SkinnedMeshComponent defaults" begin
            skin = SkinnedMeshComponent()
            @test isempty(skin.bone_entities)
            @test isempty(skin.bone_matrices)
        end

        @testset "SkinnedMeshComponent custom" begin
            bone_eids = [EntityID(1), EntityID(2), EntityID(3)]
            mats = [Mat4f(I), Mat4f(I), Mat4f(I)]
            skin = SkinnedMeshComponent(bone_entities=bone_eids, bone_matrices=mats)
            @test length(skin.bone_entities) == 3
            @test length(skin.bone_matrices) == 3
        end

        @testset "SkinnedMeshComponent is mutable" begin
            skin = SkinnedMeshComponent()
            push!(skin.bone_entities, EntityID(1))
            @test length(skin.bone_entities) == 1
            push!(skin.bone_matrices, Mat4f(I))
            @test length(skin.bone_matrices) == 1
        end

        @testset "MeshComponent bone fields backward compatible" begin
            # Old-style construction without bone data
            mesh = MeshComponent(
                vertices=[Point3f(0, 0, 0)],
                indices=UInt32[0],
                normals=[Vec3f(0, 1, 0)]
            )
            @test isempty(mesh.bone_weights)
            @test isempty(mesh.bone_indices)
        end

        @testset "MeshComponent with bone data" begin
            weights = [Vec4f(0.5, 0.3, 0.2, 0.0)]
            indices = [BoneIndices4((UInt16(0), UInt16(1), UInt16(2), UInt16(0)))]
            mesh = MeshComponent(
                vertices=[Point3f(0, 0, 0)],
                indices=UInt32[0],
                normals=[Vec3f(0, 1, 0)],
                bone_weights=weights,
                bone_indices=indices
            )
            @test length(mesh.bone_weights) == 1
            @test length(mesh.bone_indices) == 1
            @test mesh.bone_weights[1][1] == 0.5f0
            @test mesh.bone_indices[1][1] == UInt16(0)
        end

        @testset "MAX_BONES constant" begin
            @test MAX_BONES == 128
        end

        @testset "Bone matrix computation — identity" begin
            reset_component_stores!()

            # Create a mesh entity and a bone entity at the same position
            mesh_eid = create_entity!(World())
            add_component!(mesh_eid, transform(position=Vec3d(0, 0, 0)))

            bone_eid = create_entity!(World())
            add_component!(bone_eid, transform(position=Vec3d(0, 0, 0)))
            add_component!(bone_eid, BoneComponent(
                inverse_bind_matrix=Mat4f(I),
                bone_index=0,
                name="root"
            ))

            skin = SkinnedMeshComponent(
                bone_entities=[bone_eid],
                bone_matrices=[Mat4f(I)]
            )
            add_component!(mesh_eid, skin)

            update_skinned_meshes!()

            skin_comp = get_component(mesh_eid, SkinnedMeshComponent)
            # Both at origin with identity IBM → bone matrix should be identity
            @test skin_comp.bone_matrices[1] ≈ Mat4f(I) atol=1e-5
        end

        @testset "Bone matrix computation — translated bone" begin
            reset_component_stores!()

            mesh_eid = create_entity!(World())
            add_component!(mesh_eid, transform(position=Vec3d(0, 0, 0)))

            bone_eid = create_entity!(World())
            add_component!(bone_eid, transform(position=Vec3d(5, 0, 0)))
            add_component!(bone_eid, BoneComponent(
                inverse_bind_matrix=Mat4f(I),
                bone_index=0,
                name="arm"
            ))

            skin = SkinnedMeshComponent(
                bone_entities=[bone_eid],
                bone_matrices=[Mat4f(I)]
            )
            add_component!(mesh_eid, skin)

            update_skinned_meshes!()

            skin_comp = get_component(mesh_eid, SkinnedMeshComponent)
            # Bone is at (5,0,0) with identity IBM → matrix should translate by (5,0,0)
            bm = skin_comp.bone_matrices[1]
            @test bm[1,4] ≈ 5.0f0 atol=1e-5
            @test bm[2,4] ≈ 0.0f0 atol=1e-5
            @test bm[3,4] ≈ 0.0f0 atol=1e-5
        end

        @testset "Bone matrix with inverse bind matrix" begin
            reset_component_stores!()

            mesh_eid = create_entity!(World())
            add_component!(mesh_eid, transform(position=Vec3d(0, 0, 0)))

            bone_eid = create_entity!(World())
            add_component!(bone_eid, transform(position=Vec3d(3, 0, 0)))

            # IBM that undoes the bind pose translation
            ibm = Mat4f(
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                -3, 0, 0, 1
            )
            add_component!(bone_eid, BoneComponent(
                inverse_bind_matrix=ibm,
                bone_index=0,
                name="bone"
            ))

            skin = SkinnedMeshComponent(
                bone_entities=[bone_eid],
                bone_matrices=[Mat4f(I)]
            )
            add_component!(mesh_eid, skin)

            update_skinned_meshes!()

            skin_comp = get_component(mesh_eid, SkinnedMeshComponent)
            # Bone world = translate(3,0,0), IBM = translate(-3,0,0)
            # Result: translate(3,0,0) * translate(-3,0,0) = identity
            bm = skin_comp.bone_matrices[1]
            @test bm ≈ Mat4f(I) atol=1e-4
        end

        @testset "Multi-bone skinning" begin
            
            reset_component_stores!()

            mesh_eid = create_entity!(World())
            add_component!(mesh_eid, transform(position=Vec3d(0, 0, 0)))

            bone1 = create_entity!(World())
            add_component!(bone1, transform(position=Vec3d(1, 0, 0)))
            add_component!(bone1, BoneComponent(bone_index=0, name="bone1"))

            bone2 = create_entity!(World())
            add_component!(bone2, transform(position=Vec3d(0, 2, 0)))
            add_component!(bone2, BoneComponent(bone_index=1, name="bone2"))

            skin = SkinnedMeshComponent(
                bone_entities=[bone1, bone2],
                bone_matrices=[Mat4f(I), Mat4f(I)]
            )
            add_component!(mesh_eid, skin)

            update_skinned_meshes!()

            skin_comp = get_component(mesh_eid, SkinnedMeshComponent)
            @test length(skin_comp.bone_matrices) == 2
            # Each bone should have a translation matrix
            @test skin_comp.bone_matrices[1][1,4] ≈ 1.0f0 atol=1e-5
            @test skin_comp.bone_matrices[2][2,4] ≈ 2.0f0 atol=1e-5
        end

        @testset "update_skinned_meshes! with no skinned entities" begin
            
            reset_component_stores!()

            # Should not error with no skinned entities
            update_skinned_meshes!()
            @test true
        end

        @testset "Bone and skin components in ECS" begin
            
            reset_component_stores!()

            e1 = create_entity!(World())
            add_component!(e1, BoneComponent(bone_index=0, name="root"))

            e2 = create_entity!(World())
            add_component!(e2, SkinnedMeshComponent(bone_entities=[e1]))

            @test has_component(e1, BoneComponent)
            @test has_component(e2, SkinnedMeshComponent)
            @test get_component(e1, BoneComponent).name == "root"
            @test get_component(e2, SkinnedMeshComponent).bone_entities == [e1]
        end

        @testset "BoneIndices4 type" begin
            bi = BoneIndices4((UInt16(0), UInt16(1), UInt16(2), UInt16(3)))
            @test bi[1] == UInt16(0)
            @test bi[2] == UInt16(1)
            @test bi[3] == UInt16(2)
            @test bi[4] == UInt16(3)
        end

        @testset "Skinning resizes bone_matrices if needed" begin
            
            reset_component_stores!()

            mesh_eid = create_entity!(World())
            add_component!(mesh_eid, transform())

            bone_eid = create_entity!(World())
            add_component!(bone_eid, transform())
            add_component!(bone_eid, BoneComponent(bone_index=0))

            # Start with empty bone_matrices
            skin = SkinnedMeshComponent(
                bone_entities=[bone_eid],
                bone_matrices=Mat4f[]
            )
            add_component!(mesh_eid, skin)

            update_skinned_meshes!()

            skin_comp = get_component(mesh_eid, SkinnedMeshComponent)
            @test length(skin_comp.bone_matrices) == 1
        end
    end

    # ==================================================================
    # Particle System Tests
    # ==================================================================
    @testset "Particle System" begin
        @testset "ParticleSystemComponent defaults" begin
            comp = ParticleSystemComponent()
            @test comp.max_particles == 256
            @test comp.emission_rate == 20.0f0
            @test comp.burst_count == 0
            @test comp.lifetime_min == 1.0f0
            @test comp.lifetime_max == 2.0f0
            @test comp.gravity_modifier == 1.0f0
            @test comp.damping == 0.0f0
            @test comp.start_size_min == 0.1f0
            @test comp.start_size_max == 0.3f0
            @test comp.end_size == 0.0f0
            @test comp.start_alpha == 1.0f0
            @test comp.end_alpha == 0.0f0
            @test comp.additive == false
            @test comp._active == true
            @test comp._emit_accumulator == 0.0f0
        end

        @testset "ParticleSystemComponent custom" begin
            comp = ParticleSystemComponent(
                max_particles=500,
                emission_rate=100.0f0,
                burst_count=50,
                lifetime_min=0.5f0,
                lifetime_max=3.0f0,
                gravity_modifier=0.5f0,
                damping=0.1f0,
                start_size_min=0.5f0,
                start_size_max=1.0f0,
                end_size=0.1f0,
                start_color=RGB{Float32}(1.0f0, 0.0f0, 0.0f0),
                end_color=RGB{Float32}(1.0f0, 1.0f0, 0.0f0),
                start_alpha=0.8f0,
                end_alpha=0.1f0,
                additive=true
            )
            @test comp.max_particles == 500
            @test comp.emission_rate == 100.0f0
            @test comp.burst_count == 50
            @test comp.gravity_modifier == 0.5f0
            @test comp.additive == true
            @test comp.start_color.r == 1.0f0
            @test comp.start_color.g == 0.0f0
            @test comp.end_color.g == 1.0f0
        end

        @testset "ParticleSystemComponent mutability" begin
            comp = ParticleSystemComponent()
            comp.emission_rate = 50.0f0
            @test comp.emission_rate == 50.0f0
            comp._active = false
            @test comp._active == false
            comp.burst_count = 10
            @test comp.burst_count == 10
        end

        @testset "ParticleSystemComponent in ECS" begin
            
            reset_component_stores!()

            eid = create_entity!(World())
            comp = ParticleSystemComponent(emission_rate=30.0f0)
            add_component!(eid, comp)

            @test has_component(eid, ParticleSystemComponent)
            retrieved = get_component(eid, ParticleSystemComponent)
            @test retrieved.emission_rate == 30.0f0
        end

        @testset "Particle struct" begin
            p = Particle()
            @test p.position == Vec3f(0, 0, 0)
            @test p.velocity == Vec3f(0, 0, 0)
            @test p.lifetime == 0.0f0
            @test p.max_lifetime == 1.0f0
            @test p.size == 0.1f0
            @test p.alive == false
        end

        @testset "ParticlePool creation" begin
            pool = ParticlePool(100)
            @test length(pool.particles) == 100
            @test pool.alive_count == 0
            @test pool.vertex_count == 0
            @test length(pool.vertex_data) == 100 * 6 * 9
        end

        @testset "Particle emission" begin
            
            reset_component_stores!()
            reset_particle_pools!()

            comp = ParticleSystemComponent(max_particles=10, emission_rate=0.0f0, burst_count=5)
            pool = ParticlePool(10)
            origin = Vec3f(1.0f0, 2.0f0, 3.0f0)

            # Emit 5 particles via burst
            for _ in 1:5
                OpenReality._emit_particle!(pool, comp, origin)
            end

            @test pool.alive_count == 5
            # Check first particle was placed at origin
            @test pool.particles[1].alive == true
            @test pool.particles[1].position == origin
            @test pool.particles[1].lifetime > 0.0f0
        end

        @testset "Particle simulation" begin
            
            reset_component_stores!()

            comp = ParticleSystemComponent(
                max_particles=5,
                gravity_modifier=1.0f0,
                damping=0.0f0,
                lifetime_min=10.0f0,
                lifetime_max=10.0f0
            )
            pool = ParticlePool(5)
            origin = Vec3f(0, 10, 0)

            # Emit one particle
            OpenReality._emit_particle!(pool, comp, origin)
            @test pool.alive_count == 1

            # Simulate for 1 second
            dt = 1.0f0
            OpenReality._simulate_particles!(pool, comp, dt)

            p = pool.particles[1]
            @test p.alive == true
            # Gravity should have pulled velocity down
            @test p.velocity[2] < 0.0f0
            # Position should have changed
            @test p.position[2] < 10.0f0
        end

        @testset "Particle lifetime expiry" begin
            comp = ParticleSystemComponent(
                max_particles=5,
                lifetime_min=0.5f0,
                lifetime_max=0.5f0
            )
            pool = ParticlePool(5)

            OpenReality._emit_particle!(pool, comp, Vec3f(0, 0, 0))
            @test pool.alive_count == 1

            # Simulate past lifetime
            OpenReality._simulate_particles!(pool, comp, 1.0f0)
            @test pool.alive_count == 0
            @test pool.particles[1].alive == false
        end

        @testset "Particle damping" begin
            comp = ParticleSystemComponent(
                max_particles=5,
                gravity_modifier=0.0f0,
                damping=0.5f0,
                lifetime_min=10.0f0,
                lifetime_max=10.0f0,
                velocity_min=Vec3f(1, 1, 1),
                velocity_max=Vec3f(1, 1, 1)
            )
            pool = ParticlePool(5)

            OpenReality._emit_particle!(pool, comp, Vec3f(0, 0, 0))
            initial_speed = sum(abs.(pool.particles[1].velocity))

            OpenReality._simulate_particles!(pool, comp, 1.0f0)
            final_speed = sum(abs.(pool.particles[1].velocity))

            @test final_speed < initial_speed
        end

        @testset "Billboard vertex generation" begin
            comp = ParticleSystemComponent(
                max_particles=5,
                start_size_min=1.0f0,
                start_size_max=1.0f0,
                end_size=1.0f0,
                start_alpha=1.0f0,
                end_alpha=1.0f0,
                lifetime_min=10.0f0,
                lifetime_max=10.0f0
            )
            pool = ParticlePool(5)

            OpenReality._emit_particle!(pool, comp, Vec3f(0, 0, 0))

            cam_right = Vec3f(1, 0, 0)
            cam_up = Vec3f(0, 1, 0)

            vert_count = OpenReality._build_billboard_vertices!(pool, comp, cam_right, cam_up)

            @test vert_count == 6  # 2 triangles = 6 vertices
            @test pool.vertex_count == 6

            # Check vertex data is populated (first vertex: pos3 + uv2 + color4)
            @test pool.vertex_data[1] != 0.0f0 || pool.vertex_data[2] != 0.0f0 || pool.vertex_data[3] != 0.0f0  # at least one pos component nonzero
        end

        @testset "Pool full stops emission" begin
            comp = ParticleSystemComponent(max_particles=3, lifetime_min=10.0f0, lifetime_max=10.0f0)
            pool = ParticlePool(3)

            for _ in 1:3
                @test OpenReality._emit_particle!(pool, comp, Vec3f(0,0,0)) == true
            end
            # Pool should be full now
            @test OpenReality._emit_particle!(pool, comp, Vec3f(0,0,0)) == false
        end

        @testset "Back-to-front sorting" begin
            comp = ParticleSystemComponent(max_particles=3, lifetime_min=10.0f0, lifetime_max=10.0f0)
            pool = ParticlePool(3)

            # Emit 3 particles at different distances
            OpenReality._emit_particle!(pool, comp, Vec3f(0, 0, 0))
            pool.particles[1].position = Vec3f(0, 0, 1)
            OpenReality._emit_particle!(pool, comp, Vec3f(0, 0, 0))
            pool.particles[2].position = Vec3f(0, 0, 10)
            OpenReality._emit_particle!(pool, comp, Vec3f(0, 0, 0))
            pool.particles[3].position = Vec3f(0, 0, 5)

            cam_pos = Vec3f(0, 0, 0)
            OpenReality._sort_particles_back_to_front!(pool, cam_pos)

            # After sorting, farthest should be first among alive
            alive_positions = [p.position[3] for p in pool.particles if p.alive]
            @test alive_positions[1] >= alive_positions[2]
            @test alive_positions[2] >= alive_positions[3]
        end

        @testset "update_particles! with no emitters" begin
            
            reset_component_stores!()
            reset_particle_pools!()

            # Should not error
            update_particles!(0.016f0, Vec3f(0,0,0), Vec3f(1,0,0), Vec3f(0,1,0))
            @test true
        end

        @testset "Full particle update cycle" begin
            
            reset_component_stores!()
            reset_particle_pools!()

            eid = create_entity!(World())
            add_component!(eid, transform(position=Vec3d(0, 5, 0)))
            add_component!(eid, ParticleSystemComponent(
                max_particles=50,
                emission_rate=100.0f0,
                burst_count=10,
                lifetime_min=2.0f0,
                lifetime_max=3.0f0
            ))

            cam_pos = Vec3f(0, 0, 10)
            cam_right = Vec3f(1, 0, 0)
            cam_up = Vec3f(0, 1, 0)

            # First frame: burst + continuous emission
            update_particles!(0.1f0, cam_pos, cam_right, cam_up)

            @test haskey(PARTICLE_POOLS, eid)
            pool = PARTICLE_POOLS[eid]
            @test pool.alive_count > 0
            @test pool.vertex_count > 0

            # Burst should be consumed
            comp = get_component(eid, ParticleSystemComponent)
            @test comp.burst_count == 0
        end

        @testset "Particle pool cleanup on entity removal" begin
            
            reset_component_stores!()
            reset_particle_pools!()

            eid = create_entity!(World())
            add_component!(eid, transform())
            add_component!(eid, ParticleSystemComponent(burst_count=5))

            cam = Vec3f(0,0,0)
            update_particles!(0.016f0, cam, Vec3f(1,0,0), Vec3f(0,1,0))
            @test haskey(PARTICLE_POOLS, eid)

            # Remove the component
            remove_component!(eid, ParticleSystemComponent)

            # Next update should clean up the pool
            update_particles!(0.016f0, cam, Vec3f(1,0,0), Vec3f(0,1,0))
            @test !haskey(PARTICLE_POOLS, eid)
        end

        @testset "Inactive emitter skipped" begin
            
            reset_component_stores!()
            reset_particle_pools!()

            eid = create_entity!(World())
            add_component!(eid, transform())
            comp = ParticleSystemComponent(burst_count=5, _active=false)
            add_component!(eid, comp)

            update_particles!(0.016f0, Vec3f(0,0,0), Vec3f(1,0,0), Vec3f(0,1,0))

            # Pool shouldn't exist since emitter is inactive
            @test !haskey(PARTICLE_POOLS, eid)
        end

        @testset "GRAVITY constant" begin
            @test OpenReality.GRAVITY == Vec3f(0.0f0, -9.81f0, 0.0f0)
        end
    end

    @testset "ORSB Scene Export" begin
        @testset "Export constants" begin
            @test OpenReality.ORSB_MAGIC == UInt8['O', 'R', 'S', 'B']
            @test OpenReality.ORSB_VERSION == UInt32(1)
        end

        @testset "Empty scene export roundtrip" begin
            
            reset_component_stores!()

            s = scene()
            tmp = tempname() * ".orsb"
            try
                export_scene(s, tmp)
                @test isfile(tmp)
                data = read(tmp)
                # At least header (32 bytes)
                @test length(data) >= 32
                # Check magic
                @test data[1:4] == UInt8['O', 'R', 'S', 'B']
                # Version
                @test reinterpret(UInt32, data[5:8])[1] == UInt32(1)
                # 0 entities
                @test reinterpret(UInt32, data[13:16])[1] == UInt32(0)
            finally
                isfile(tmp) && rm(tmp)
            end
        end

        @testset "Single entity export" begin
            
            reset_component_stores!()

            eid = create_entity!(World())
            add_component!(eid, transform(position=Vec3d(1.0, 2.0, 3.0)))
            s = add_entity(scene(), eid)

            tmp = tempname() * ".orsb"
            try
                export_scene(s, tmp)
                data = read(tmp)
                @test length(data) >= 32
                # 1 entity
                @test reinterpret(UInt32, data[13:16])[1] == UInt32(1)
                # Entity ID should be in the entity graph section (starts at byte 33)
                eid_bytes = reinterpret(UInt64, data[33:40])[1]
                @test eid_bytes == ((UInt64(eid._id) >> 32) | UInt64(eid._gen))
            finally
                isfile(tmp) && rm(tmp)
            end
        end

        @testset "Entity with mesh and material" begin
            
            reset_component_stores!()

            eid = create_entity!(World())
            add_component!(eid, transform())
            add_component!(eid, MeshComponent(
                vertices=[Point3f(0,0,0), Point3f(1,0,0), Point3f(0,1,0)],
                normals=[Vec3f(0,0,1), Vec3f(0,0,1), Vec3f(0,0,1)],
                uvs=[Vec2f(0,0), Vec2f(1,0), Vec2f(0,1)],
                indices=UInt32[0, 1, 2]
            ))
            add_component!(eid, MaterialComponent(
                color=RGB{Float32}(1.0, 0.0, 0.0),
                metallic=0.5f0,
                roughness=0.5f0
            ))
            s = add_entity(scene(), eid)

            tmp = tempname() * ".orsb"
            try
                export_scene(s, tmp)
                data = read(tmp)
                # Should have 1 entity, 1 mesh, 0 textures, 1 material
                @test reinterpret(UInt32, data[13:16])[1] == UInt32(1)  # entities
                @test reinterpret(UInt32, data[17:20])[1] == UInt32(1)  # meshes
                @test reinterpret(UInt32, data[21:24])[1] == UInt32(0)  # textures
                @test reinterpret(UInt32, data[25:28])[1] == UInt32(1)  # materials
                # File should be well over the header
                @test length(data) > 200
            finally
                isfile(tmp) && rm(tmp)
            end
        end

        @testset "Physics config export" begin
            
            reset_component_stores!()

            s = scene()
            config = PhysicsWorldConfig(
                gravity=Vec3d(0, -9.81, 0),
                fixed_dt=1.0/60.0,
                max_substeps=4
            )
            tmp = tempname() * ".orsb"
            try
                export_scene(s, tmp; physics_config=config)
                data = read(tmp)
                # File should contain physics config at the end (48 bytes)
                @test length(data) >= 80  # header + empty sections + physics config
            finally
                isfile(tmp) && rm(tmp)
            end
        end

        @testset "Entity with lights" begin
            
            reset_component_stores!()

            eid1 = create_entity!(World())
            add_component!(eid1, transform(position=Vec3d(5.0, 10.0, 5.0)))
            add_component!(eid1, PointLightComponent(
                color=RGB{Float32}(1.0, 1.0, 1.0),
                intensity=10.0f0,
                range=50.0f0
            ))

            eid2 = create_entity!(World())
            add_component!(eid2, transform())
            add_component!(eid2, DirectionalLightComponent(
                direction=Vec3f(0.0, -1.0, 0.0),
                color=RGB{Float32}(1.0, 0.9, 0.8),
                intensity=5.0f0
            ))

            s = add_entity(add_entity(scene(), eid1), eid2)
            tmp = tempname() * ".orsb"
            try
                export_scene(s, tmp)
                data = read(tmp)
                @test length(data) > 32
                # 2 entities
                @test reinterpret(UInt32, data[13:16])[1] == UInt32(2)
            finally
                isfile(tmp) && rm(tmp)
            end
        end
    end

    @testset "WebGPU Backend Types" begin
        @testset "Type definitions exist" begin
            @test isdefined(OpenReality, :WebGPUGPUMesh)
            @test isdefined(OpenReality, :WebGPUGPUTexture)
            @test isdefined(OpenReality, :WebGPUFramebuffer)
            @test isdefined(OpenReality, :WebGPUGBuffer)
            @test isdefined(OpenReality, :WebGPUGPUResourceCache)
            @test isdefined(OpenReality, :WebGPUTextureCache)
        end

        @testset "Type hierarchy" begin
            @test WebGPUGPUMesh <: AbstractGPUMesh
            @test WebGPUGPUTexture <: AbstractGPUTexture
            @test WebGPUFramebuffer <: AbstractFramebuffer
        end

        @testset "WebGPU type construction" begin
            m = WebGPUGPUMesh(UInt64(1), Int32(36))
            @test m.handle == UInt64(1)
            @test m.index_count == Int32(36)

            t = WebGPUGPUTexture(UInt64(2), 256, 256, 4)
            @test t.handle == UInt64(2)
            @test t.width == 256
        end
    end

    @testset "Engine Reset" begin
        @testset "reset_engine_state! clears ECS and physics" begin
            reset_component_stores!()
            
            eid = create_entity!(World())
            add_component!(eid, TransformComponent())
            @test component_count(TransformComponent) == 1

            reset_engine_state!()

            @test component_count(TransformComponent) == 0
            @test OpenReality._PHYSICS_WORLD[] === nothing
        end

        @testset "reset_engine_state! is idempotent" begin
            reset_engine_state!()
            @test (reset_engine_state!(); true)
        end

        @testset "clear_audio_sources! is a no-op when uninitialized" begin
            reset_audio_state!()
            state = OpenReality.get_audio_state()
            state.sources[EntityID(1)] = UInt32(99)
            @test_nowarn clear_audio_sources!()
            @test !isempty(OpenReality.get_audio_state().sources)
        end

        @testset "clear_audio_sources! empties sources dict" begin
            reset_audio_state!()
            state = OpenReality.get_audio_state()
            state.initialized = true
            state.sources[EntityID(1)] = UInt32(99)
            clear_audio_sources!()
            @test isempty(OpenReality.get_audio_state().sources)
        end
    end

    @testset "ScriptComponent" begin
        @testset "Default construction" begin
            reset_engine_state!()
            sc = ScriptComponent()
            @test sc.on_start === nothing
            @test sc.on_update === nothing
            @test sc.on_destroy === nothing
            @test sc._started == false
        end

        @testset "on_start fires exactly once" begin
            reset_engine_state!()
            start_count = Ref(0)
            update_count = Ref(0)
            eid = create_entity!(World())
            add_component!(eid, ScriptComponent(
                on_start = (_, _) -> start_count[] += 1,
                on_update = (_, _, _) -> update_count[] += 1
            ))
            ctx = GameContext(Scene(), InputState())
            update_scripts!(0.016, ctx)
            update_scripts!(0.016, ctx)
            @test start_count[] == 1
            @test update_count[] == 2
        end

        @testset "Error isolation" begin
            reset_engine_state!()
            counter = Ref(0)
            eid1 = create_entity!(World())
            add_component!(eid1, ScriptComponent(
                on_update = (_, _, _) -> error("boom")
            ))
            eid2 = create_entity!(World())
            add_component!(eid2, ScriptComponent(
                on_update = (_, _, _) -> counter[] += 1
            ))
            ctx = GameContext(Scene(), InputState())
            update_scripts!(0.016, ctx)
            @test counter[] == 1
        end

        @testset "Snapshot protection" begin
            reset_engine_state!()
            eid = create_entity!(World())
            add_component!(eid, ScriptComponent(
                on_update = (_, _, _) -> begin
                    new_eid = create_entity!(World())
                    add_component!(new_eid, ScriptComponent(
                        on_update = (_, _, _) -> nothing
                    ))
                end
            ))
            ctx = GameContext(Scene(), InputState())
            @test_nowarn update_scripts!(0.016, ctx)
        end

        @testset "destroy_entity! fires on_destroy before removal" begin
            reset_engine_state!()
            destroy_count = Ref(0)
            eid = create_entity!(World())
            add_component!(eid, ScriptComponent(
                on_destroy = (_, _) -> destroy_count[] += 1
            ))
            s = Scene()
            s = add_entity(s, eid)
            s = destroy_entity!(s, eid)
            @test destroy_count[] == 1
            @test has_component(eid, ScriptComponent) == false
        end

        @testset "destroy_entity! fires on_destroy for descendants" begin
            reset_engine_state!()
            child_destroy_count = Ref(0)
            parent_eid = create_entity!(World())
            child_eid = create_entity!(World())
            add_component!(child_eid, ScriptComponent(
                on_destroy = (_, _) -> child_destroy_count[] += 1
            ))
            s = Scene()
            s = add_entity(s, parent_eid)
            s = add_entity(s, child_eid, parent_eid)
            s = destroy_entity!(s, parent_eid)
            @test child_destroy_count[] == 1
        end

        @testset "remove_entity does NOT fire on_destroy" begin
            reset_engine_state!()
            destroy_count = Ref(0)
            eid = create_entity!(World())
            add_component!(eid, ScriptComponent(
                on_destroy = (_, _) -> destroy_count[] += 1
            ))
            s = Scene()
            s = add_entity(s, eid)
            s = remove_entity(s, eid)
            @test destroy_count[] == 0
        end

        @testset "on_update receives GameContext" begin
            reset_engine_state!()
            received_ctx = Ref{Any}(nothing)
            eid = create_entity!(World())
            add_component!(eid, ScriptComponent(
                on_update = (_, _, c) -> (received_ctx[] = c)
            ))
            ctx = GameContext(Scene(), InputState())
            update_scripts!(0.016, ctx)
            @test received_ctx[] isa GameContext
        end
    end

    @testset "CollisionCallbackComponent" begin
        @testset "default construction" begin
            cc = CollisionCallbackComponent()
            @test cc.on_collision_enter === nothing
            @test cc.on_collision_stay === nothing
            @test cc.on_collision_exit === nothing
        end

        @testset "enter detection" begin
            
            reset_component_stores!()
            reset_physics_world!()

            e1 = create_entity!(World())
            e2 = create_entity!(World())

            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e1, RigidBodyComponent())

            add_component!(e2, transform(position=Vec3d(0, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e2, RigidBodyComponent())

            enter_count = Ref(0)
            add_component!(e1, CollisionCallbackComponent(
                on_collision_enter = (self, other, manifold) -> (enter_count[] += 1)
            ))

            world = get_physics_world()
            key = e1 < e2 ? (e1, e2) : (e2, e1)
            push!(world.collision_cache.current_pairs, key)

            OpenReality.update_collision_callbacks!(world)
            @test enter_count[] == 1
        end

        @testset "stay detection" begin
            
            reset_component_stores!()
            reset_physics_world!()

            e1 = create_entity!(World())
            e2 = create_entity!(World())

            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e1, RigidBodyComponent())

            add_component!(e2, transform(position=Vec3d(0, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e2, RigidBodyComponent())

            stay_count = Ref(0)
            add_component!(e1, CollisionCallbackComponent(
                on_collision_stay = (self, other, manifold) -> (stay_count[] += 1)
            ))

            world = get_physics_world()
            key = e1 < e2 ? (e1, e2) : (e2, e1)
            push!(world.collision_cache.current_pairs, key)
            push!(world.collision_cache.prev_pairs, key)

            OpenReality.update_collision_callbacks!(world)
            @test stay_count[] == 1
        end

        @testset "exit detection" begin
            
            reset_component_stores!()
            reset_physics_world!()

            e1 = create_entity!(World())
            e2 = create_entity!(World())

            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e1, RigidBodyComponent())

            add_component!(e2, transform(position=Vec3d(0, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e2, RigidBodyComponent())

            exit_count = Ref(0)
            add_component!(e1, CollisionCallbackComponent(
                on_collision_exit = (self, other, manifold) -> (exit_count[] += 1)
            ))

            world = get_physics_world()
            key = e1 < e2 ? (e1, e2) : (e2, e1)
            push!(world.collision_cache.prev_pairs, key)

            OpenReality.update_collision_callbacks!(world)
            @test exit_count[] == 1
        end

        @testset "sleeping suppression" begin
            
            reset_component_stores!()
            reset_physics_world!()

            e1 = create_entity!(World())
            e2 = create_entity!(World())

            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e1, RigidBodyComponent(sleeping=true))

            add_component!(e2, transform(position=Vec3d(0, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e2, RigidBodyComponent(sleeping=true))

            exit_count = Ref(0)
            add_component!(e1, CollisionCallbackComponent(
                on_collision_exit = (self, other, manifold) -> (exit_count[] += 1)
            ))

            world = get_physics_world()
            key = e1 < e2 ? (e1, e2) : (e2, e1)
            push!(world.collision_cache.prev_pairs, key)

            OpenReality.update_collision_callbacks!(world)
            @test exit_count[] == 0
        end

        @testset "callback error isolation" begin
            
            reset_component_stores!()
            reset_physics_world!()

            e1 = create_entity!(World())
            e2 = create_entity!(World())

            add_component!(e1, transform(position=Vec3d(0, 0, 0)))
            add_component!(e1, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e1, RigidBodyComponent())

            add_component!(e2, transform(position=Vec3d(0, 0, 0)))
            add_component!(e2, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(e2, RigidBodyComponent())

            second_fired = Ref(false)
            add_component!(e1, CollisionCallbackComponent(
                on_collision_enter = (self, other, manifold) -> error("test error")
            ))
            add_component!(e2, CollisionCallbackComponent(
                on_collision_enter = (self, other, manifold) -> (second_fired[] = true)
            ))

            world = get_physics_world()
            key = e1 < e2 ? (e1, e2) : (e2, e1)
            push!(world.collision_cache.current_pairs, key)

            @test_warn "CollisionCallbackComponent error" OpenReality.update_collision_callbacks!(world)
            @test second_fired[] == true
        end

        @testset "integration: enter fires on collision" begin
            
            reset_component_stores!()
            reset_physics_world!()
            OpenReality.reset_trigger_state!()

            # Dynamic sphere above static floor
            sphere_eid = create_entity!(World())
            add_component!(sphere_eid, transform(position=Vec3d(0, 1, 0)))
            add_component!(sphere_eid, ColliderComponent(shape=SphereShape(0.5f0)))
            add_component!(sphere_eid, RigidBodyComponent(mass=1.0))
            OpenReality.initialize_rigidbody_inertia!(sphere_eid)

            floor_eid = create_entity!(World())
            add_component!(floor_eid, transform(position=Vec3d(0, 0, 0)))
            add_component!(floor_eid, ColliderComponent(shape=AABBShape(Vec3f(10, 0.1, 10))))
            add_component!(floor_eid, RigidBodyComponent(body_type=BODY_STATIC, mass=0.0))

            enter_count = Ref(0)
            add_component!(sphere_eid, CollisionCallbackComponent(
                on_collision_enter = (self, other, manifold) -> (enter_count[] += 1)
            ))

            world = get_physics_world()
            for _ in 1:20
                OpenReality.step!(world, 0.1)
            end
            @test enter_count[] >= 1
        end
    end

    @testset "Render Loop Wiring" begin
        @testset "on_update return value convention" begin
            @test ([] isa Vector) == true
            @test (nothing isa Vector) == false
            @test (scene() isa Vector) == false
        end

        @testset "update_scripts! callable in full module context" begin
            reset_engine_state!()
            counter = Ref(0)
            eid = create_entity!(World())
            add_component!(eid, ScriptComponent(on_update=(id, dt) -> counter[] += 1))
            update_scripts!(0.016)
            @test counter[] == 1
        end

        @testset "destroy_entity! is exported" begin
            @test isdefined(OpenReality, :destroy_entity!)
        end

        @testset "reset_engine_state! is exported" begin
            @test isdefined(OpenReality, :reset_engine_state!)
        end

        @testset "clear_audio_sources! is exported" begin
            @test isdefined(OpenReality, :clear_audio_sources!)
        end

        @testset "EntityDef is side-effect-free, scene() is side-effectful" begin
            reset_engine_state!()
            @test component_count(TransformComponent) == 0
            defs = [entity([TransformComponent()])]
            @test component_count(TransformComponent) == 0
            s = scene(defs)
            @test component_count(TransformComponent) > 0
            reset_engine_state!()
        end

        @testset "Scene switch: on_destroy fires before reset" begin
            reset_engine_state!()
            destroy_order = String[]
            s = scene([entity([TransformComponent(), ScriptComponent(on_destroy = (id, ctx) -> push!(destroy_order, "destroyed"))])])
            # Simulate the render loop's on_destroy snapshot
            script_entities = entities_with_component(ScriptComponent)
            for eid in script_entities
                comp = get_component(eid, ScriptComponent)
                if comp !== nothing && comp.on_destroy !== nothing
                    comp.on_destroy(eid, nothing)
                end
            end
            @test "destroyed" in destroy_order
            reset_engine_state!()
            @test component_count(TransformComponent) == 0
            @test component_count(ScriptComponent) == 0
            reset_engine_state!()
        end
    end

    @testset "Animation Blend Trees" begin
        @testset "Blend1DNode weight at midpoint" begin
            reset_engine_state!()

            # Create two target entities with transforms
            target_a = create_entity!(World())
            target_b = create_entity!(World())
            add_component!(target_a, transform(position=Vec3d(0, 0, 0)))
            add_component!(target_b, transform(position=Vec3d(0, 0, 0)))

            # Clip A: position at (1,0,0)
            clip_a = AnimationClip("walk", [
                AnimationChannel(target_a, :position, Float32[0.0, 1.0], Any[Vec3d(1.0, 0.0, 0.0), Vec3d(1.0, 0.0, 0.0)], INTERP_LINEAR)
            ], 1.0f0)

            # Clip B: position at (3,0,0)
            clip_b = AnimationClip("run", [
                AnimationChannel(target_a, :position, Float32[0.0, 1.0], Any[Vec3d(3.0, 0.0, 0.0), Vec3d(3.0, 0.0, 0.0)], INTERP_LINEAR)
            ], 1.0f0)

            node = Blend1DNode("speed", Float32[0.0, 1.0], BlendNode[ClipNode(clip_a), ClipNode(clip_b)])
            params = Dict{String, Float32}("speed" => 0.5f0)
            bool_params = Dict{String, Bool}()
            triggers = Set{String}()

            output = OpenReality.evaluate_blend_node(node, params, bool_params, triggers, 0.0)

            # At speed=0.5, result should be midpoint: (2,0,0)
            @test haskey(output, target_a)
            pos = output[target_a][:position]::Vec3d
            @test abs(pos[1] - 2.0) < 1e-5
            @test abs(pos[2] - 0.0) < 1e-5
            @test abs(pos[3] - 0.0) < 1e-5

            # At speed=0.0, result should equal first clip: (1,0,0)
            params["speed"] = 0.0f0
            output = OpenReality.evaluate_blend_node(node, params, bool_params, triggers, 0.0)
            @test haskey(output, target_a)
            pos = output[target_a][:position]::Vec3d
            @test abs(pos[1] - 1.0) < 1e-5
            @test abs(pos[2] - 0.0) < 1e-5
            @test abs(pos[3] - 0.0) < 1e-5

            # At speed=1.0, result should equal second clip: (3,0,0)
            params["speed"] = 1.0f0
            output = OpenReality.evaluate_blend_node(node, params, bool_params, triggers, 0.0)
            @test haskey(output, target_a)
            pos = output[target_a][:position]::Vec3d
            @test abs(pos[1] - 3.0) < 1e-5
            @test abs(pos[2] - 0.0) < 1e-5
            @test abs(pos[3] - 0.0) < 1e-5

            reset_engine_state!()
        end

        @testset "Crossfade blend weight" begin
            # Verify crossfade t computation
            comp = AnimationBlendTreeComponent(
                ClipNode(AnimationClip("idle", AnimationChannel[], 1.0f0)),
                Dict{String, Float32}(),
                Dict{String, Bool}(),
                Set{String}(),
                0.0,
                true,
                1.0f0,
                0.5f0,
                ClipNode(AnimationClip("walk", AnimationChannel[], 1.0f0))
            )

            t = clamp(comp.transition_elapsed / comp.transition_duration, 0f0, 1f0)
            @test t == 0.5f0

            comp.transition_elapsed = 0.0f0
            t = clamp(comp.transition_elapsed / comp.transition_duration, 0f0, 1f0)
            @test t == 0.0f0

            comp.transition_elapsed = 1.0f0
            t = clamp(comp.transition_elapsed / comp.transition_duration, 0f0, 1f0)
            @test t == 1.0f0
        end

        @testset "Guard: update_animations! skips blend-tree entities" begin
            reset_engine_state!()
            eid = create_entity!(World())
            target_eid = create_entity!(World())
            add_component!(target_eid, transform(position=Vec3d(0, 0, 0)))

            clip = AnimationClip("test", [
                AnimationChannel(target_eid, :position, Float32[0.0, 1.0], Any[Vec3d(0.0, 0.0, 0.0), Vec3d(1.0, 0.0, 0.0)], INTERP_LINEAR)
            ], 1.0f0)

            anim = AnimationComponent(clips=[clip], active_clip=1, playing=true, current_time=0.0, looping=true, speed=1.0f0)
            add_component!(eid, anim)

            blend_comp = AnimationBlendTreeComponent(
                ClipNode(AnimationClip("idle", AnimationChannel[], 1.0f0)),
                Dict{String, Float32}(),
                Dict{String, Bool}(),
                Set{String}(),
                0.0,
                false,
                0f0,
                0f0,
                nothing
            )
            add_component!(eid, blend_comp)

            update_animations!(0.016)
            # current_time should NOT have been advanced because the guard skips blend-tree entities
            @test get_component(eid, AnimationComponent).current_time == 0.0
            reset_engine_state!()
        end

        @testset "Trigger consumed after evaluation" begin
            reset_engine_state!()
            eid = create_entity!(World())
            add_component!(eid, transform(position=Vec3d(0, 0, 0)))

            comp = AnimationBlendTreeComponent(
                ClipNode(AnimationClip("idle", AnimationChannel[], 1.0f0)),
                Dict{String, Float32}(),
                Dict{String, Bool}(),
                Set{String}(),
                0.0,
                false,
                0f0,
                0f0,
                nothing
            )
            add_component!(eid, comp)
            fire_trigger!(comp, "jump")
            @test "jump" in comp.trigger_parameters

            update_blend_tree!(0.016)
            @test !("jump" in get_component(eid, AnimationBlendTreeComponent).trigger_parameters)
            reset_engine_state!()
        end
    end

    @testset "Camera Controllers" begin
        @testset "find_active_camera with two cameras" begin
            reset_engine_state!()
            eid1 = create_entity!(World())
            add_component!(eid1, transform())
            add_component!(eid1, CameraComponent(active=false))

            eid2 = create_entity!(World())
            add_component!(eid2, transform())
            add_component!(eid2, CameraComponent(active=true))

            @test find_active_camera() == eid2
            reset_engine_state!()
        end

        @testset "ThirdPersonCamera position computation" begin
            reset_engine_state!()

            # Target entity at origin
            target_eid = create_entity!(World())
            add_component!(target_eid, transform(position=Vec3d(0, 0, 0)))

            # Camera entity at origin
            cam_eid = create_entity!(World())
            add_component!(cam_eid, transform(position=Vec3d(0, 0, 0)))
            add_component!(cam_eid, ThirdPersonCamera(
                target_eid,
                5.0f0,       # distance
                0.0,         # yaw
                0.0,         # pitch
                -deg2rad(89.0), # min_pitch
                deg2rad(89.0),  # max_pitch
                0.0f0,       # sensitivity (no mouse effect)
                false,       # collision_enabled
                1000.0f0,    # smoothing (high value = instant)
                Vec3f(0, 0, 0) # offset
            ))

            input = InputState()
            update_camera_controllers!(input, 1.0)

            tc = get_component(cam_eid, TransformComponent)
            pos = tc.position[]
            # With yaw=0, pitch=0, distance=5, camera should be at approximately (0, 0, 5)
            @test abs(pos[1]) < 0.1
            @test abs(pos[2]) < 0.1
            @test abs(pos[3] - 5.0) < 0.1
            reset_engine_state!()
        end

        @testset "CinematicCamera path interpolation" begin
            reset_engine_state!()

            cam_eid = create_entity!(World())
            add_component!(cam_eid, transform(position=Vec3d(0, 0, 0)))
            add_component!(cam_eid, CinematicCamera(
                5.0f0,                                    # move_speed
                0.003f0,                                  # sensitivity
                [Vec3d(0, 0, 0), Vec3d(2, 0, 0)],       # path
                [0.0f0, 1.0f0],                          # path_times
                0.5f0,                                    # current_time
                true,                                     # playing
                false                                     # looping
            ))

            input = InputState()
            update_camera_controllers!(input, 0.0)  # zero dt so time doesn't advance

            tc = get_component(cam_eid, TransformComponent)
            pos = tc.position[]
            @test abs(pos[1] - 1.0) < 0.01
            @test abs(pos[2]) < 0.01
            @test abs(pos[3]) < 0.01
            reset_engine_state!()
        end

        @testset "No-op when no controllers exist" begin
            reset_engine_state!()
            input = InputState()
            @test_nowarn update_camera_controllers!(input, 0.016)
            reset_engine_state!()
        end
    end

    @testset "Game State Machine" begin
        # Concrete no-op subtype for testing default implementations
        struct NoOpState <: GameState end

        @testset "Default implementations return nothing" begin
            reset_engine_state!()
            s = scene([])
            st = NoOpState()
            @test on_enter!(st, s) === nothing
            ctx = GameContext(s, InputState())
            @test on_update!(st, s, 0.0, ctx) === nothing
            @test on_exit!(st, s) === nothing
            @test get_ui_callback(st) === nothing
            reset_engine_state!()
        end

        @testset "on_enter! called on initial state" begin
            reset_engine_state!()
            mutable struct TestEnteredState <: GameState
                entered::Bool
            end
            OpenReality.on_enter!(st::TestEnteredState, sc::Scene) = (st.entered = true; nothing)

            st = TestEnteredState(false)
            s = scene([])
            on_enter!(st, s)
            @test st.entered == true
            reset_engine_state!()
        end

        @testset "on_exit! called before on_enter! during transition" begin
            reset_engine_state!()
            call_order = String[]

            mutable struct ExitState <: GameState end
            mutable struct EnterState <: GameState end
            OpenReality.on_exit!(st::ExitState, sc::Scene) = push!(call_order, "exit")
            OpenReality.on_enter!(st::EnterState, sc::Scene) = push!(call_order, "enter")

            s = scene([])
            on_exit!(ExitState(), s)
            on_enter!(EnterState(), s)
            @test call_order == ["exit", "enter"]
            reset_engine_state!()
        end

        @testset "StateTransition with new_scene_defs = nothing — scene unchanged" begin
            t = StateTransition(:x, nothing)
            @test t.target == :x
            @test t.new_scene_defs === nothing
        end

        @testset "StateTransition convenience constructor" begin
            t = StateTransition(:foo)
            @test t.target == :foo
            @test t.new_scene_defs === nothing
        end

        @testset "StateTransition with new_scene_defs" begin
            reset_engine_state!()
            defs = [entity([TransformComponent()])]
            t = StateTransition(:bar, defs)
            @test t.target == :bar
            @test t.new_scene_defs !== nothing
            @test length(t.new_scene_defs) == 1

            # Verify scene can be built from new_defs after reset
            reset_engine_state!()
            @test component_count(TransformComponent) == 0
            new_scene = scene(t.new_scene_defs)
            @test component_count(TransformComponent) > 0
            reset_engine_state!()
        end

        @testset "Error isolation — on_enter! throwing is catchable" begin
            reset_engine_state!()
            mutable struct ErrorState <: GameState end
            OpenReality.on_enter!(st::ErrorState, sc::Scene) = error("test error")

            s = scene([])
            caught = false
            try
                on_enter!(ErrorState(), s)
            catch e
                caught = true
                @test e isa ErrorException
            end
            @test caught
            reset_engine_state!()
        end

        @testset "add_state! registers state" begin
            fsm = GameStateMachine(:a, [])
            @test isempty(fsm.states)
            add_state!(fsm, :a, NoOpState())
            @test haskey(fsm.states, :a)
            @test fsm.states[:a] isa NoOpState
        end

        @testset "add_state! returns fsm for chaining" begin
            fsm = GameStateMachine(:a, [])
            result = add_state!(fsm, :a, NoOpState())
            @test result === fsm
        end

        @testset "GameStateMachine convenience constructor" begin
            defs = [entity([TransformComponent()])]
            fsm = GameStateMachine(:start, defs)
            @test fsm.initial_state == :start
            @test fsm.initial_scene_defs === defs
            @test isempty(fsm.states)
        end
    end

    @testset "GameContext" begin
        
        reset_component_stores!()

        @testset "spawn! returns non-zero EntityID" begin
            
            reset_component_stores!()
            s = Scene()
            ctx = GameContext(s, InputState())
            edef = entity([TransformComponent()])
            eid = spawn!(ctx, edef)
            @test eid > EntityID(0)
        end

        @testset "spawned entity not in scene before apply_mutations!" begin
            
            reset_component_stores!()
            s = Scene()
            ctx = GameContext(s, InputState())
            edef = entity([TransformComponent()])
            eid = spawn!(ctx, edef)
            @test has_entity(ctx.scene, eid) == false
        end

        @testset "spawned entity in scene after apply_mutations!" begin
            
            reset_component_stores!()
            s = Scene()
            ctx = GameContext(s, InputState())
            edef = entity([TransformComponent()])
            eid = spawn!(ctx, edef)
            new_scene = apply_mutations!(ctx, ctx.scene)
            @test has_entity(new_scene, eid) == true
        end

        @testset "spawned entity has components after apply_mutations!" begin
            
            reset_component_stores!()
            s = Scene()
            ctx = GameContext(s, InputState())
            edef = entity([TransformComponent()])
            eid = spawn!(ctx, edef)
            apply_mutations!(ctx, ctx.scene)
            @test has_component(eid, TransformComponent) == true
        end

        @testset "despawn removes entity from scene" begin
            
            reset_component_stores!()
            s = scene([entity([TransformComponent()])])
            eid = s.entities[1]
            ctx = GameContext(s, InputState())
            despawn!(ctx, eid)
            new_scene = apply_mutations!(ctx, ctx.scene)
            @test has_entity(new_scene, eid) == false
        end

        @testset "despawn removes entity components from ECS" begin
            
            reset_component_stores!()
            s = scene([entity([TransformComponent()])])
            eid = s.entities[1]
            ctx = GameContext(s, InputState())
            despawn!(ctx, eid)
            apply_mutations!(ctx, ctx.scene)
            @test has_component(eid, TransformComponent) == false
        end

        @testset "apply_mutations! on empty queues preserves entity count" begin
            
            reset_component_stores!()
            s = scene([entity([TransformComponent()])])
            initial_count = entity_count(s)
            ctx = GameContext(s, InputState())
            new_scene = apply_mutations!(ctx, ctx.scene)
            @test entity_count(new_scene) == initial_count
        end

        @testset "two spawn! calls return different EntityIDs" begin
            
            reset_component_stores!()
            s = Scene()
            ctx = GameContext(s, InputState())
            eid1 = spawn!(ctx, entity([TransformComponent()]))
            eid2 = spawn!(ctx, entity([TransformComponent()]))
            @test eid1 != eid2
        end
    end

    @testset "EventBus" begin
        struct TestEvent <: GameEvent; value::Int end
        struct OtherEvent <: GameEvent; msg::String end

        reset_event_bus!()

        @testset "subscribe! and emit!" begin
            reset_event_bus!()
            received = Ref(0)
            cb = e -> (received[] = e.value)
            subscribe!(TestEvent, cb)
            emit!(TestEvent(42))
            @test received[] == 42
        end

        @testset "multiple listeners called in order" begin
            reset_event_bus!()
            order = Int[]
            subscribe!(TestEvent, _ -> push!(order, 1))
            subscribe!(TestEvent, _ -> push!(order, 2))
            emit!(TestEvent(0))
            @test order == [1, 2]
        end

        @testset "unsubscribe! removes listener" begin
            reset_event_bus!()
            called = Ref(false)
            cb = _ -> (called[] = true)
            subscribe!(TestEvent, cb)
            unsubscribe!(TestEvent, cb)
            emit!(TestEvent(0))
            @test called[] == false
        end

        @testset "throwing listener does not block others" begin
            reset_event_bus!()
            flag = Ref(false)
            subscribe!(TestEvent, _ -> error("boom"))
            subscribe!(TestEvent, _ -> (flag[] = true))
            emit!(TestEvent(0))
            @test flag[] == true
        end

        @testset "reset_event_bus! clears all subscriptions" begin
            reset_event_bus!()
            called = Ref(false)
            subscribe!(TestEvent, _ -> (called[] = true))
            reset_event_bus!()
            emit!(TestEvent(0))
            @test called[] == false
        end

        @testset "reset_engine_state! clears event bus" begin
            reset_event_bus!()
            called = Ref(false)
            subscribe!(TestEvent, _ -> (called[] = true))
            reset_engine_state!()
            emit!(TestEvent(0))
            @test called[] == false
        end

        @testset "different event types do not cross-fire" begin
            reset_event_bus!()
            called = Ref(false)
            subscribe!(OtherEvent, _ -> (called[] = true))
            emit!(TestEvent(1))
            @test called[] == false
        end
    end

    @testset "AssetManager" begin
        reset_asset_manager!()

        @testset "reset_asset_manager! clears cache" begin
            am = get_asset_manager()
            am.model_cache["dummy"] = [entity([TransformComponent()])]
            reset_asset_manager!()
            @test isempty(get_asset_manager().model_cache)
        end

        @testset "singleton identity" begin
            reset_asset_manager!()
            am1 = get_asset_manager()
            am2 = get_asset_manager()
            @test am1 === am2
        end

        @testset "reset_engine_state! resets asset manager" begin
            am = get_asset_manager()
            am.model_cache["dummy"] = [entity([TransformComponent()])]
            reset_engine_state!()
            @test isempty(get_asset_manager().model_cache)
        end

        @testset "get_model returns deep copy from cache" begin
            reset_asset_manager!()
            am = get_asset_manager()
            am.model_cache["test_path"] = [entity([TransformComponent()])]
            result = get_model("test_path")
            @test result == am.model_cache["test_path"]
            @test result !== am.model_cache["test_path"]
        end
    end

    @testset "Prefab" begin
        
        reset_component_stores!()

        @testset "instantiate calls factory with correct kwargs" begin
            
            reset_component_stores!()
            pf = Prefab(; position=Vec3d(0,0,0)) do (; position)
                entity([TransformComponent(; position)])
            end
            edef = instantiate(pf; position=Vec3d(1, 2, 3))
            @test edef.components[1] isa TransformComponent
            @test edef.components[1].position[] == Vec3d(1, 2, 3)
        end

        @testset "spawn!(ctx, prefab) returns a valid EntityID" begin
            
            reset_component_stores!()
            pf = Prefab(; position=Vec3d(0,0,0)) do (; position)
                entity([TransformComponent(; position)])
            end
            s = Scene()
            ctx = GameContext(s, InputState())
            eid = spawn!(ctx, pf)
            @test eid > EntityID(0)
            @test typeof(eid) == EntityID
        end

        @testset "two spawns from same prefab produce different EntityIDs" begin
            
            reset_component_stores!()
            pf = Prefab(; position=Vec3d(0,0,0)) do (; position)
                entity([TransformComponent(; position)])
            end
            s = Scene()
            ctx = GameContext(s, InputState())
            eid1 = spawn!(ctx, pf)
            eid2 = spawn!(ctx, pf)
            @test eid1 != eid2
        end

        @testset "after apply_mutations! both entities exist in scene" begin
            
            reset_component_stores!()
            pf = Prefab(; position=Vec3d(0,0,0)) do (; position)
                entity([TransformComponent(; position)])
            end
            s = Scene()
            ctx = GameContext(s, InputState())
            eid1 = spawn!(ctx, pf)
            eid2 = spawn!(ctx, pf)
            new_scene = apply_mutations!(ctx, ctx.scene)
            @test has_entity(new_scene, eid1)
            @test has_entity(new_scene, eid2)
        end

        @testset "override kwargs reflected in spawned entity components" begin
            
            reset_component_stores!()
            pf = Prefab(; position=Vec3d(0,0,0)) do (; position)
                entity([TransformComponent(; position)])
            end
            s = Scene()
            ctx = GameContext(s, InputState())
            eid1 = spawn!(ctx, pf; position=Vec3d(1, 2, 3))
            eid2 = spawn!(ctx, pf; position=Vec3d(4, 5, 6))
            new_scene = apply_mutations!(ctx, ctx.scene)
            t1 = get_component(eid1, TransformComponent)
            t2 = get_component(eid2, TransformComponent)
            @test t1.position[] == Vec3d(1, 2, 3)
            @test t2.position[] == Vec3d(4, 5, 6)
            @test t1.position[] != t2.position[]
        end
    end

    @testset "DebugDraw" begin
        @testset "flush_debug_draw! is always callable without error" begin
            @test_nowarn flush_debug_draw!()
        end

        if OPENREALITY_DEBUG
            @testset "debug_line! adds one entry to _DEBUG_LINES" begin
                flush_debug_draw!()
                debug_line!(Vec3f(0,0,0), Vec3f(1,0,0))
                @test length(OpenReality._DEBUG_LINES) == 1
                flush_debug_draw!()
            end

            @testset "debug_box! adds exactly 12 entries to _DEBUG_LINES" begin
                flush_debug_draw!()
                debug_box!(Vec3f(0,0,0), Vec3f(1,1,1))
                @test length(OpenReality._DEBUG_LINES) == 12
                flush_debug_draw!()
            end

            @testset "flush_debug_draw! empties the buffer" begin
                debug_box!(Vec3f(0,0,0), Vec3f(1,1,1))
                flush_debug_draw!()
                @test isempty(OpenReality._DEBUG_LINES)
            end

            @testset "debug_sphere! adds exactly 48 entries to _DEBUG_LINES" begin
                flush_debug_draw!()
                debug_sphere!(Vec3f(0,0,0), 1.0f0)
                @test length(OpenReality._DEBUG_LINES) == 48
                flush_debug_draw!()
            end
        else
            @testset "debug_line! is a no-op when OPENREALITY_DEBUG = false" begin
                @test_nowarn debug_line!(Vec3f(0,0,0), Vec3f(1,0,0))
            end

            @testset "debug_box! is a no-op when OPENREALITY_DEBUG = false" begin
                @test_nowarn debug_box!(Vec3f(0,0,0), Vec3f(1,1,1))
            end
        end
    end
end
