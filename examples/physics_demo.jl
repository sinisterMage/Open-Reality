# Physics System Demo
# Showcases the full-featured pure Julia physics engine:
#   - Impulse-based solver with friction and restitution
#   - Multiple collider shapes (AABB, Sphere, Capsule, OBB, ConvexHull, Compound)
#   - Joint constraints (ball-socket, hinge, distance, fixed, slider)
#   - Trigger volumes with enter/stay/exit callbacks
#   - Raycasting
#   - Continuous Collision Detection (CCD)
#   - Sleeping / island-based deactivation

using OpenReality

reset_entity_counter!()
reset_component_stores!()
reset_physics_world!()

# =============================================================================
# Helper: drop a dynamic entity from a height
# =============================================================================
function dynamic_box(pos; size=Vec3f(0.5, 0.5, 0.5), color=RGB{Float32}(0.8, 0.3, 0.1),
                     mass=1.0, restitution=0.3f0, friction=0.5)
    entity([
        cube_mesh(),
        MaterialComponent(color=color, metallic=0.2f0, roughness=0.6f0),
        transform(position=pos),
        ColliderComponent(shape=AABBShape(size)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=mass,
                           restitution=restitution, friction=friction)
    ])
end

function dynamic_sphere(pos; radius=0.4f0, color=RGB{Float32}(0.2, 0.6, 0.9),
                        mass=1.0, restitution=0.6f0)
    entity([
        sphere_mesh(radius=radius),
        MaterialComponent(color=color, metallic=0.4f0, roughness=0.3f0),
        transform(position=pos),
        ColliderComponent(shape=SphereShape(radius)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=mass, restitution=restitution)
    ])
end

# =============================================================================
# Scene
# =============================================================================
s = scene([
    # --- Player ---
    create_player(position=Vec3d(0, 2, 15)),

    # --- Lights ---
    entity([
        DirectionalLightComponent(direction=Vec3f(0.4, -1.0, -0.3), intensity=2.5f0)
    ]),
    entity([
        PointLightComponent(color=RGB{Float32}(1.0, 0.95, 0.8), intensity=40.0f0, range=25.0f0),
        transform(position=Vec3d(0, 8, 0))
    ]),

    # --- Ground plane (static) ---
    entity([
        plane_mesh(width=40.0f0, depth=40.0f0),
        MaterialComponent(color=RGB{Float32}(0.45, 0.45, 0.45), metallic=0.0f0, roughness=0.95f0),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(20.0, 0.01, 20.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # =========================================================================
    # DEMO 1: Stacking boxes — tests impulse solver stability + friction
    # =========================================================================
    # A tower of boxes that should stay stacked thanks to friction
    dynamic_box(Vec3d(-6, 0.5, 0), color=RGB{Float32}(0.9, 0.2, 0.2)),
    dynamic_box(Vec3d(-6, 1.5, 0), color=RGB{Float32}(0.8, 0.4, 0.1)),
    dynamic_box(Vec3d(-6, 2.5, 0), color=RGB{Float32}(0.7, 0.6, 0.1)),
    dynamic_box(Vec3d(-6, 3.5, 0), color=RGB{Float32}(0.5, 0.8, 0.2)),
    dynamic_box(Vec3d(-6, 4.5, 0), color=RGB{Float32}(0.2, 0.9, 0.3)),

    # =========================================================================
    # DEMO 2: Bouncing spheres — tests restitution
    # =========================================================================
    # Spheres with varying bounciness dropped from height
    dynamic_sphere(Vec3d(-2, 6, 0), restitution=0.0f0,
                   color=RGB{Float32}(0.9, 0.1, 0.1)),   # no bounce (red)
    dynamic_sphere(Vec3d(-1, 6, 0), restitution=0.3f0,
                   color=RGB{Float32}(0.9, 0.5, 0.1)),   # low bounce (orange)
    dynamic_sphere(Vec3d( 0, 6, 0), restitution=0.6f0,
                   color=RGB{Float32}(0.9, 0.9, 0.1)),   # medium bounce (yellow)
    dynamic_sphere(Vec3d( 1, 6, 0), restitution=0.85f0,
                   color=RGB{Float32}(0.1, 0.9, 0.3)),   # high bounce (green)
    dynamic_sphere(Vec3d( 2, 6, 0), restitution=0.95f0,
                   color=RGB{Float32}(0.1, 0.5, 0.9)),   # super bouncy (blue)

    # =========================================================================
    # DEMO 3: Capsule colliders
    # =========================================================================
    # Capsule standing upright and one on its side
    entity([
        sphere_mesh(radius=0.5f0),  # visual stand-in
        MaterialComponent(color=RGB{Float32}(0.8, 0.2, 0.8), metallic=0.5f0, roughness=0.3f0),
        transform(position=Vec3d(5, 3, 0)),
        ColliderComponent(shape=CapsuleShape(radius=0.3f0, half_height=0.5f0, axis=CAPSULE_Y)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=2.0)
    ]),
    entity([
        sphere_mesh(radius=0.4f0),  # visual stand-in
        MaterialComponent(color=RGB{Float32}(0.2, 0.8, 0.8), metallic=0.5f0, roughness=0.3f0),
        transform(position=Vec3d(6, 4, 0)),
        ColliderComponent(shape=CapsuleShape(radius=0.25f0, half_height=0.4f0, axis=CAPSULE_X)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.5)
    ]),

    # =========================================================================
    # DEMO 4: OBB collider — a rotated box
    # =========================================================================
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(1.0, 0.8, 0.0), metallic=0.7f0, roughness=0.2f0),
        transform(position=Vec3d(4, 4, -4),
                  rotation=Quaternion(cos(π/8), 0.0, sin(π/8), 0.0)),  # rotated 45° around Y
        ColliderComponent(shape=OBBShape(Vec3f(0.5, 0.5, 0.5))),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=2.0)
    ]),

    # =========================================================================
    # DEMO 5: ConvexHull collider — a tetrahedron
    # =========================================================================
    entity([
        sphere_mesh(radius=0.5f0),  # visual approximation
        MaterialComponent(color=RGB{Float32}(0.1, 0.9, 0.9), metallic=0.3f0, roughness=0.5f0),
        transform(position=Vec3d(0, 5, -4)),
        ColliderComponent(shape=ConvexHullShape([
            Vec3f( 0.0,  0.7,  0.0),   # top
            Vec3f(-0.5, -0.3,  0.5),   # front-left
            Vec3f( 0.5, -0.3,  0.5),   # front-right
            Vec3f( 0.0, -0.3, -0.5),   # back
        ])),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0)
    ]),

    # =========================================================================
    # DEMO 6: CompoundShape — an L-shaped collider from two boxes
    # =========================================================================
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.6, 0.2, 0.9), metallic=0.4f0, roughness=0.4f0),
        transform(position=Vec3d(-3, 4, -4)),
        ColliderComponent(shape=CompoundShape([
            CompoundChild(AABBShape(Vec3f(0.5, 0.25, 0.25)),
                          position=Vec3d(0, 0.25, 0)),       # horizontal arm
            CompoundChild(AABBShape(Vec3f(0.25, 0.5, 0.25)),
                          position=Vec3d(-0.25, -0.25, 0))   # vertical arm
        ])),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=3.0)
    ]),

    # =========================================================================
    # DEMO 7: CCD — fast bullet that won't tunnel through a wall
    # =========================================================================
    # Thin wall
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.4, 0.4, 0.4), metallic=0.1f0, roughness=0.9f0),
        transform(position=Vec3d(8, 1, -6), scale=Vec3d(0.1, 2, 2)),
        ColliderComponent(shape=AABBShape(Vec3f(0.05, 1.0, 1.0))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),
    # Fast-moving sphere with CCD enabled
    entity([
        sphere_mesh(radius=0.15f0),
        MaterialComponent(color=RGB{Float32}(1.0, 0.0, 0.0), metallic=0.9f0, roughness=0.1f0),
        transform(position=Vec3d(6, 1, -6)),
        ColliderComponent(shape=SphereShape(0.15f0)),
        RigidBodyComponent(body_type=BODY_DYNAMIC, mass=0.5,
                           ccd_mode=CCD_SWEPT,
                           # Give it a high initial velocity toward the wall
                           velocity=Vec3d(50.0, 0.0, 0.0))
    ]),

    # =========================================================================
    # DEMO 8: Static ramp — angled surface for sliding
    # =========================================================================
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.5, 0.35, 0.2), metallic=0.0f0, roughness=0.85f0),
        transform(position=Vec3d(-8, 1, -4),
                  rotation=Quaternion(cos(π/12), 0.0, 0.0, sin(π/12)),  # tilted ~30°
                  scale=Vec3d(3, 0.1, 2)),
        ColliderComponent(shape=AABBShape(Vec3f(1.5, 0.05, 1.0))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),
    # Sphere that will roll down the ramp
    dynamic_sphere(Vec3d(-9, 3.5, -4), radius=0.3f0, restitution=0.2f0,
                   color=RGB{Float32}(1.0, 0.5, 0.0)),
])

# =========================================================================
# DEMO 9: Joint constraints (post-scene, using entity IDs directly)
# =========================================================================

# Ball-socket joint: pendulum bob hanging from a fixed anchor
anchor_id = create_entity_id()
add_component!(anchor_id, transform(position=Vec3d(8, 6, 4)))
add_component!(anchor_id, ColliderComponent(shape=SphereShape(0.1f0)))
add_component!(anchor_id, RigidBodyComponent(body_type=BODY_STATIC))

bob_id = create_entity_id()
add_component!(bob_id, transform(position=Vec3d(8, 4, 4)))
add_component!(bob_id, cube_mesh())
add_component!(bob_id, MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.5), metallic=0.6f0, roughness=0.3f0))
add_component!(bob_id, ColliderComponent(shape=SphereShape(0.3f0)))
add_component!(bob_id, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=2.0,
                                          velocity=Vec3d(3.0, 0.0, 0.0)))  # kick to start swinging

# Attach the pendulum joint
add_component!(bob_id, JointComponent(
    BallSocketJoint(anchor_id, bob_id,
                    local_anchor_a=Vec3d(0, 0, 0),
                    local_anchor_b=Vec3d(0, 2, 0))
))

# Distance joint: two spheres connected by a "rope"
sphere_a_id = create_entity_id()
add_component!(sphere_a_id, transform(position=Vec3d(10, 5, 0)))
add_component!(sphere_a_id, sphere_mesh(radius=0.3f0))
add_component!(sphere_a_id, MaterialComponent(color=RGB{Float32}(0.1, 0.8, 0.1), metallic=0.3f0, roughness=0.4f0))
add_component!(sphere_a_id, ColliderComponent(shape=SphereShape(0.3f0)))
add_component!(sphere_a_id, RigidBodyComponent(body_type=BODY_STATIC))

sphere_b_id = create_entity_id()
add_component!(sphere_b_id, transform(position=Vec3d(10, 3, 0)))
add_component!(sphere_b_id, sphere_mesh(radius=0.3f0))
add_component!(sphere_b_id, MaterialComponent(color=RGB{Float32}(0.8, 0.1, 0.1), metallic=0.3f0, roughness=0.4f0))
add_component!(sphere_b_id, ColliderComponent(shape=SphereShape(0.3f0)))
add_component!(sphere_b_id, RigidBodyComponent(body_type=BODY_DYNAMIC, mass=1.0,
                                               velocity=Vec3d(2.0, 0.0, 1.0)))

add_component!(sphere_b_id, JointComponent(
    DistanceJoint(sphere_a_id, sphere_b_id, target_distance=2.0)
))

# Add joint entities to the scene
add_entity(s, anchor_id)
add_entity(s, bob_id)
add_entity(s, sphere_a_id)
add_entity(s, sphere_b_id)

# =========================================================================
# DEMO 10: Trigger volume — prints when entities enter/exit
# =========================================================================
trigger_id = create_entity_id()
add_component!(trigger_id, transform(position=Vec3d(0, 1, 3)))
add_component!(trigger_id, ColliderComponent(
    shape=AABBShape(Vec3f(2.0, 2.0, 2.0)),
    is_trigger=true
))
# Visual indicator (semi-transparent green zone)
add_component!(trigger_id, cube_mesh())
add_component!(trigger_id, MaterialComponent(
    color=RGB{Float32}(0.0, 1.0, 0.3),
    metallic=0.0f0, roughness=1.0f0,
    opacity=0.2f0
))
add_component!(trigger_id, TriggerComponent(
    on_enter = (trigger_eid, other_eid) -> @info("Entity $other_eid ENTERED trigger zone!"),
    on_stay  = (trigger_eid, other_eid) -> nothing,  # silent
    on_exit  = (trigger_eid, other_eid) -> @info("Entity $other_eid EXITED trigger zone!")
))
add_entity(s, trigger_id)

# =========================================================================
# DEMO 11: Raycasting — cast a ray downward and report what's below
# =========================================================================
hit = raycast(Vec3d(0, 10, 0), Vec3d(0, -1, 0), max_distance=50.0)
if hit !== nothing
    @info "Raycast hit" entity=hit.entity point=hit.point normal=hit.normal distance=hit.distance
else
    @info "Raycast: no hit"
end

# =========================================================================
# Summary
# =========================================================================
@info "Physics Demo Scene" entities=entity_count(s) features=[
    "Impulse solver (PGS + warm-starting)",
    "Friction & restitution",
    "Spatial hash broadphase",
    "Shapes: AABB, Sphere, Capsule, OBB, ConvexHull, Compound",
    "GJK + EPA for convex-convex",
    "Joints: ball-socket, distance, hinge, fixed, slider",
    "Trigger volumes (enter/stay/exit)",
    "Raycasting (all shapes)",
    "CCD (swept sphere/capsule)",
    "Island-based sleeping",
]

# Run the render loop with physics
render(s, post_process=PostProcessConfig(
    tone_mapping=TONEMAP_ACES,
    bloom_enabled=true,
    bloom_intensity=0.3f0,
    fxaa_enabled=true
))
