using OpenReality
using Test
using LinearAlgebra

@testset "OpenReality.jl" begin
    @testset "Module loads" begin
        @test isdefined(OpenReality, :scene)
        @test isdefined(OpenReality, :entity)
        @test isdefined(OpenReality, :render)
    end

    @testset "ECS" begin
        @testset "World-based entity creation" begin
            world = World()
            @test world.next_entity_id == 1

            id1 = create_entity!(world)
            @test id1 == 1
            @test world.next_entity_id == 2

            id2 = create_entity!(world)
            @test id2 == 2
        end

        @testset "Global entity ID generation" begin
            reset_entity_counter!()

            id1 = create_entity_id()
            id2 = create_entity_id()

            @test id1 != id2
            @test id2 == id1 + 1
            @test typeof(id1) == EntityID
        end

        @testset "Component storage" begin
            reset_component_stores!()
            reset_entity_counter!()

            # Create entities
            e1 = create_entity_id()
            e2 = create_entity_id()

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
            reset_entity_counter!()

            e1 = create_entity_id()

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
            reset_entity_counter!()

            e1 = create_entity_id()
            e2 = create_entity_id()
            e3 = create_entity_id()

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
            reset_entity_counter!()

            e1 = create_entity_id()
            e2 = create_entity_id()

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
            reset_entity_counter!()

            e1 = create_entity_id()

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
            reset_entity_counter!()
            reset_component_stores!()

            s1 = Scene()
            e1 = create_entity_id()

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
            reset_entity_counter!()
            reset_component_stores!()

            s = Scene()
            parent_id = create_entity_id()
            child1_id = create_entity_id()
            child2_id = create_entity_id()

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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
            reset_component_stores!()

            # Create a floor (static, at y=0, extends from -10 to 10 in xz, height 0.1)
            floor_id = create_entity_id()
            add_component!(floor_id, transform(position=Vec3d(0, -0.05, 0)))
            add_component!(floor_id, ColliderComponent(
                shape=AABBShape(Vec3f(10.0, 0.05, 10.0))
            ))
            add_component!(floor_id, RigidBodyComponent(body_type=BODY_STATIC))

            # Create a dynamic box above the floor
            box_id = create_entity_id()
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

    @testset "Model Loading" begin
        @testset "load_model dispatches by extension" begin
            # Test that unsupported extensions throw
            @test_throws ErrorException load_model("test.xyz")
            @test_throws ErrorException load_model("test.fbx")
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
            reset_entity_counter!()
            reset_component_stores!()

            e1 = create_entity_id()
            add_component!(e1, transform(position=Vec3d(10, 0, 0)))

            world = get_world_transform(e1)

            # Position should be in translation column
            @test world[13] ≈ 10.0 atol=1e-10
            @test world[14] ≈ 0.0 atol=1e-10
            @test world[15] ≈ 0.0 atol=1e-10
        end

        @testset "World transform for entity without transform" begin
            reset_entity_counter!()
            reset_component_stores!()

            e1 = create_entity_id()
            # No transform component added

            world = get_world_transform(e1)

            # Should return identity matrix
            @test world ≈ Mat4d(I) atol=1e-10
        end

        @testset "Hierarchical transforms with parent-child" begin
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
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
            reset_entity_counter!()
            reset_component_stores!()

            e1 = create_entity_id()
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
            reset_entity_counter!()
            reset_component_stores!()

            # Create entity with transform
            eid = create_entity_id()
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

    @testset "Backend" begin
        backend = OpenGLBackend()
        @test !backend.initialized

        initialize!(backend)
        @test backend.initialized

        shutdown!(backend)
        @test !backend.initialized
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
end
