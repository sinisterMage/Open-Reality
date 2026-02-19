<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Systems Reference - OpenReality Docs',
  ogTitle: 'Systems Reference - OpenReality Docs',
  description: 'Guide to OpenReality systems: player controller, physics simulation, animation, skeletal skinning, 3D audio, particle simulation, and UI rendering.',
  ogDescription: 'Guide to OpenReality systems: player controller, physics simulation, animation, skeletal skinning, 3D audio, particle simulation, and UI rendering.',
})

const pipelineCode = `# Executed automatically each frame by render():
clear_world_transform_cache!()        # invalidate cached matrices
update_player!(controller, input, dt) # FPS controls
update_camera_controllers!(scene, dt) # orbit/third-person/cinematic
update_animations!(dt)                # keyframe interpolation
update_blend_trees!(dt)               # animation blend trees
update_skinned_meshes!()              # bone matrix computation
update_physics!(dt)                   # physics simulation step
update_collision_callbacks!()         # collision event dispatch
update_scripts!(scene, dt, ctx)       # ScriptComponent lifecycle
update_audio!(dt)                     # 3D audio sync
update_particles!(dt)                 # particle emission & simulation
render_frame!(backend, scene)         # GPU rendering`

const playerCode = `# Auto-detected when PlayerComponent exists in scene
# Provides FPS-style controls:
#   WASD       — movement
#   Mouse      — look around
#   Shift      — sprint
#   Space/Ctrl — up/down
#   Escape     — release cursor

# Controller is created automatically:
controller = PlayerController(player_entity_id, camera_entity_id)`

const physicsCode = `# Physics runs as a fixed-timestep sub-stepping loop:
# 1. Update world-space inertia tensors
# 2. Apply gravity, reset grounded flags
# 3. Broadphase — spatial hash grid
# 4. Narrowphase — GJK+EPA collision detection
# 5. Solve constraints — PGS impulse solver
# 6. Integrate positions
# 7. Update sleeping, CCD

# The PhysicsWorld is a global singleton:
physics_step!(world, dt)`

const animationCode = `# Interpolates keyframes each frame:
#   STEP         — discrete jumps
#   LINEAR       — lerp for position/scale, slerp for rotation
#   CUBICSPLINE  — cubic Hermite spline

# Channels target entity properties:
#   :position → Vec3d
#   :rotation → Quaterniond
#   :scale    → Vec3d

update_animations!(dt)  # called automatically`

const skinningCode = `# Computes final bone matrices for skeletal animation:
#   final_matrix = world_transform × inverse_bind_matrix
#
# Updates SkinnedMeshComponent.bone_matrices[]
# which are uploaded to GPU uniforms for vertex skinning.

update_skinned_meshes!()  # called automatically`

const audioCode = `# Syncs 3D audio positions from transforms:
#   - Listener position/orientation from camera entity
#   - Source positions from entity transforms
#   - Handles play/stop/loop state changes

update_audio!(dt)  # called automatically`

const particlesCode = `# CPU-side particle simulation:
#   - Accumulator-based emission (frame-rate independent)
#   - Velocity integration with gravity and damping
#   - Lifetime tracking and recycling
#   - Color and size interpolation over lifetime
#   - Billboard vertex generation for rendering
#   - Back-to-front sorting for transparency

update_particles!(dt)  # called automatically`

const uiCode = `# Immediate-mode UI rendered as an overlay:
render(s, ui=function(ctx::UIContext)
    ui_text(ctx, 10, 10, "FPS: \$(round(1/dt))")
    ui_rect(ctx, 10, 40, 200, 20, (0.2, 0.2, 0.2, 0.8))
    ui_progress_bar(ctx, 10, 40, 200, 20, health/100)

    if ui_button(ctx, 10, 80, 120, 30, "Restart")
        reset_game!()
    end

    ui_image(ctx, 10, 120, 64, 64, "icon.png")
end)`

const systems = [
  { id: 'pipeline', title: 'Systems Pipeline', code: pipelineCode, desc: 'The render loop executes systems in a fixed order each frame. Delta time is computed automatically.' },
  { id: 'player', title: 'Player Controller', code: playerCode, desc: 'FPS-style input handling. Automatically activated when a PlayerComponent is detected in the scene. Captures the cursor and provides WASD movement with mouse look.' },
  { id: 'physics', title: 'Physics System', code: physicsCode, desc: 'Fixed-timestep physics simulation with sub-stepping. The PhysicsWorld singleton manages broadphase, narrowphase, constraint solving, and sleeping.' },
  { id: 'animation', title: 'Animation System', code: animationCode, desc: 'Keyframe interpolation supporting three modes. Animations from glTF files are automatically loaded with correct interpolation types and target remapping.' },
  { id: 'skinning', title: 'Skinning System', code: skinningCode, desc: 'Computes the final bone transform matrices for skeletal animation. These matrices are uploaded as shader uniforms for vertex skinning on the GPU.' },
  { id: 'audio', title: 'Audio System', code: audioCode, desc: 'Synchronizes 3D audio state with entity transforms. The OpenAL backend handles spatial attenuation, distance rolloff, and stereo panning.' },
  { id: 'particles', title: 'Particle System', code: particlesCode, desc: 'CPU-simulated particles with billboard rendering. The accumulator pattern ensures consistent emission rates regardless of frame rate.' },
  { id: 'ui', title: 'UI System', code: uiCode, desc: 'Immediate-mode UI overlay rendered on top of the 3D scene. Supports text, rectangles, progress bars, buttons, and images. Uses FreeType for font atlas generation.' },
]
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Systems Reference</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        Systems run each frame to update game state. They operate on components
        in the ECS store and are executed in a fixed order by the render loop.
      </p>
    </div>

    <nav class="flex flex-wrap gap-2">
      <a
        v-for="s in systems"
        :key="s.id"
        :href="`#${s.id}`"
        class="px-2 py-1 text-xs font-mono rounded border border-or-border text-or-text-dim hover:text-or-green hover:border-or-green/50 transition-colors"
      >
        {{ s.title }}
      </a>
    </nav>

    <section v-for="s in systems" :key="s.id" :id="s.id" class="scroll-mt-20">
      <h2 class="text-xl font-mono font-bold text-or-text mb-3">
        <span class="text-or-green">#</span> {{ s.title }}
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">{{ s.desc }}</p>
      <CodeBlock :code="s.code" lang="julia" :filename="s.id + '.jl'" />
    </section>
  </div>
</template>
