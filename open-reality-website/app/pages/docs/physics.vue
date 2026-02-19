<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Physics Guide - OpenReality Docs',
  ogTitle: 'Physics Guide - OpenReality Docs',
  description: 'OpenReality physics engine: collision shapes, GJK+EPA detection, impulse-based PGS solver, joint constraints, raycasting, and continuous collision detection.',
  ogDescription: 'OpenReality physics engine: collision shapes, GJK+EPA detection, impulse-based PGS solver, joint constraints, raycasting, and continuous collision detection.',
})

const basicCode = `# Add physics to an entity with two components:
entity([
    transform(position=Vec3d(0, 10, 0)),
    sphere_mesh(),
    MaterialComponent(color=RGB{Float32}(0.8, 0.2, 0.1)),
    ColliderComponent(shape=SphereShape(1.0f0)),
    RigidBodyComponent(body_type=BODY_DYNAMIC, mass=2.0)
])`

const shapesCode = `# Axis-Aligned Bounding Box
AABBShape()                            # unit cube
AABBShape(half_extents=Vec3f(2, 1, 3)) # custom size

# Sphere
SphereShape(1.0f0)                     # radius

# Capsule (hemispherical caps + cylinder)
CapsuleShape(0.5f0, 2.0f0, :Y)        # radius, height, axis

# Oriented Bounding Box (rotates with entity)
OBBShape(Vec3f(1, 1, 1))              # half extents

# Convex Hull (arbitrary convex shape)
ConvexHullShape(points::Vector{Vec3f})

# Compound (multiple shapes with local offsets)
CompoundShape([
    CompoundChild(AABBShape(), Vec3d(0, 0, 0), Quaterniond(1,0,0,0)),
    CompoundChild(SphereShape(0.5f0), Vec3d(0, 1, 0), Quaterniond(1,0,0,0)),
])

# Heightmap (terrain)
HeightmapShape(heights, width, depth, scale)`

const bodyTypesCode = `# Static — immovable, infinite mass (walls, ground)
RigidBodyComponent(body_type=BODY_STATIC)

# Kinematic — script-driven motion, pushes dynamics
RigidBodyComponent(body_type=BODY_KINEMATIC)

# Dynamic — fully physics-driven
RigidBodyComponent(
    body_type=BODY_DYNAMIC,
    mass=5.0,
    restitution=0.5,     # bounciness
    friction=0.6,        # surface friction
    linear_damping=0.01, # air resistance
    angular_damping=0.05
)`

const constraintsCode = `# Ball-socket joint (3 DOF removed)
BallSocketJoint(entity_a, entity_b,
    anchor_a=Vec3d(0, 1, 0),
    anchor_b=Vec3d(0, -1, 0)
)

# Distance joint (fixed distance between anchors)
DistanceJoint(entity_a, entity_b,
    anchor_a=Vec3d(0, 0, 0),
    anchor_b=Vec3d(0, 0, 0),
    distance=3.0
)

# Hinge joint (1 DOF rotation)
HingeJoint(entity_a, entity_b,
    anchor_a=Vec3d(0, 0, 0),
    anchor_b=Vec3d(0, 0, 0),
    axis=Vec3d(0, 1, 0),
    min_angle=-π/4,
    max_angle=π/4
)`

const triggerCode = `# Trigger volumes fire events without physical response
entity([
    transform(position=Vec3d(5, 0, 0)),
    ColliderComponent(
        shape=AABBShape(half_extents=Vec3f(3, 3, 3)),
        is_trigger=true
    )
])`

const raycastCode = `# Cast a ray into the physics world
hit = raycast(
    origin=Vec3d(0, 10, 0),
    direction=Vec3d(0, -1, 0),
    max_distance=100.0
)

if hit !== nothing
    entity_id = hit.entity_id
    point = hit.point       # Vec3d
    normal = hit.normal     # Vec3d
    distance = hit.distance # Float64
end`

const ccdCode = `# Enable Continuous Collision Detection for fast objects
RigidBodyComponent(
    body_type=BODY_DYNAMIC,
    mass=0.1,
    ccd_mode=CCD_SWEPT  # prevents tunneling
)`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Physics Guide</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        OpenReality includes a full rigid body physics engine with impulse-based constraint solving,
        GJK+EPA collision detection, and spatial hash broadphase.
      </p>
    </div>

    <!-- Overview -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Adding Physics
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Add physics to any entity with a <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">ColliderComponent</code>
        and a <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">RigidBodyComponent</code>.
        The physics system runs automatically each frame.
      </p>
      <CodeBlock :code="basicCode" lang="julia" filename="physics_basic.jl" />
    </section>

    <!-- Shapes -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Collision Shapes
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Seven collision shape types for different use cases. Simple shapes (AABB, Sphere) are fastest;
        ConvexHull and Compound are more accurate but more expensive.
      </p>
      <CodeBlock :code="shapesCode" lang="julia" filename="shapes.jl" />
    </section>

    <!-- Body Types -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Body Types
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Three body types control how the physics engine treats an entity.
      </p>
      <CodeBlock :code="bodyTypesCode" lang="julia" filename="body_types.jl" />
    </section>

    <!-- Solver -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Solver Pipeline
      </h2>
      <p class="text-or-text-dim leading-relaxed">
        The physics engine runs a 7-phase pipeline each step:
      </p>
      <div class="mt-4 space-y-2">
        <div v-for="(step, i) in [
          'Update world-space inertia tensors',
          'Apply gravity, reset grounded flags',
          'Broadphase — spatial hash grid finds candidate pairs',
          'Narrowphase — GJK+EPA computes contacts for each pair',
          'Solve velocity constraints — PGS impulse solver with warm starting',
          'Integrate positions',
          'Update grounded status, sleeping (islands), CCD'
        ]" :key="i" class="flex items-start gap-3 text-or-text-dim text-sm">
          <span class="font-mono text-or-green shrink-0">{{ i + 1 }}.</span>
          <span>{{ step }}</span>
        </div>
      </div>
    </section>

    <!-- Constraints -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Joint Constraints
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Connect entities with joints to create mechanical systems. Joints constrain the relative motion between two bodies.
      </p>
      <CodeBlock :code="constraintsCode" lang="julia" filename="constraints.jl" />
    </section>

    <!-- Triggers -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Trigger Volumes
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Triggers detect overlap without applying physical forces. Useful for checkpoints, damage zones, and event areas.
      </p>
      <CodeBlock :code="triggerCode" lang="julia" filename="triggers.jl" />
    </section>

    <!-- Raycasting -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Raycasting
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Cast rays into the physics world for hit detection, line-of-sight checks, and picking.
      </p>
      <CodeBlock :code="raycastCode" lang="julia" filename="raycast.jl" />
    </section>

    <!-- CCD -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Continuous Collision Detection
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Fast-moving objects can tunnel through thin geometry. CCD performs swept tests between frames to prevent this.
      </p>
      <CodeBlock :code="ccdCode" lang="julia" filename="ccd.jl" />
    </section>
  </div>
</template>
