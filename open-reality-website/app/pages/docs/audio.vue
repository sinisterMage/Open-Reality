<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Audio System - OpenReality Docs',
  ogTitle: 'Audio System - OpenReality Docs',
  description: 'OpenAL-based 3D positional audio: AudioListenerComponent, AudioSourceComponent, spatial attenuation, WAV loading, and Doppler effect.',
  ogDescription: 'OpenAL-based 3D positional audio: AudioListenerComponent, AudioSourceComponent, spatial attenuation, WAV loading, and Doppler effect.',
})

const listenerCode = `AudioListenerComponent(
    gain = 1.0f0  # master volume (0.0 to 1.0)
)

# Only one active listener per scene.
# Position and orientation are automatically synced
# from the entity's TransformComponent each frame.
# Typically attached to the camera or player entity.`

const sourceCode = `AudioSourceComponent(
    audio_path = "sounds/explosion.wav",  # path to WAV file
    playing = true,                       # start playing immediately
    looping = false,                      # loop playback
    gain = 0.8f0,                         # volume (0.0 to 1.0)
    pitch = 1.0f0,                        # playback speed multiplier
    spatial = true,                       # 3D positional audio
    reference_distance = 1.0f0,           # distance for full volume
    max_distance = 100.0f0,               # distance where attenuation stops
    rolloff_factor = 1.0f0                # attenuation curve steepness
)

# Set spatial=false for non-positional audio (music, UI sounds)`

const spatialCode = `# Spatial audio uses inverse distance clamped attenuation:
#
#   gain = reference_distance /
#          (reference_distance + rolloff_factor *
#           (clamp(distance, reference_distance, max_distance)
#            - reference_distance))
#
# Parameters:
#   reference_distance — distance at which gain = 1.0 (no attenuation)
#   max_distance       — beyond this, attenuation is capped
#   rolloff_factor     — higher = faster falloff (1.0 is realistic)
#
# Doppler effect is handled automatically by OpenAL based on
# the relative velocity between listener and source entities.`

const wavLoadingCode = `# WAV files are loaded automatically on first use.
# The audio backend calls get_or_load_buffer! which:
#   1. Checks if the file is already cached in the buffer pool
#   2. If not, reads the WAV file (PCM 8/16-bit, mono/stereo)
#   3. Creates an OpenAL buffer and caches it for reuse
#
# No manual loading step is required — just set audio_path
# and the system handles the rest.

AudioSourceComponent(audio_path = "sounds/footstep.wav", playing = true)`

const fullExampleCode = `# Scene with a camera listener and a looping ambient source

scene_defs = [
    # Camera with audio listener
    entity([
        transform(position=Vec3d(0, 2, 5)),
        CameraComponent(fov=60.0),
        AudioListenerComponent(gain=1.0f0)
    ]),

    # Directional light
    entity([
        transform(),
        DirectionalLightComponent(
            direction=Vec3f(0, -1, -0.5),
            intensity=1.5f0
        )
    ]),

    # Campfire with crackling sound
    entity([
        transform(position=Vec3d(3, 0, -2)),
        sphere_mesh(),
        MaterialComponent(
            color=RGB{Float32}(1.0, 0.4, 0.0),
            emissive_factor=Vec3f(1.0, 0.3, 0.0)
        ),
        AudioSourceComponent(
            audio_path = "sounds/campfire.wav",
            playing = true,
            looping = true,
            gain = 0.6f0,
            spatial = true,
            reference_distance = 2.0f0,
            max_distance = 30.0f0,
            rolloff_factor = 1.5f0
        )
    ]),

    # Background music (non-spatial)
    entity([
        transform(),
        AudioSourceComponent(
            audio_path = "music/ambient.wav",
            playing = true,
            looping = true,
            gain = 0.3f0,
            spatial = false  # plays at constant volume
        )
    ]),
]`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Audio System</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        OpenAL-based 3D positional audio with automatic WAV loading, spatial attenuation,
        and Doppler effect. Attach an
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">AudioListenerComponent</code>
        to the camera and <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">AudioSourceComponent</code>
        to sound-emitting entities.
      </p>
    </div>

    <!-- AudioListenerComponent -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> AudioListenerComponent
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Represents the audio listener in the scene. Only one listener should be active at a time.
        The listener's position and orientation are synced from its entity's
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">TransformComponent</code>
        each frame by the audio system.
      </p>
      <CodeBlock :code="listenerCode" lang="julia" filename="audio_listener.jl" />
    </section>

    <!-- AudioSourceComponent -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> AudioSourceComponent
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        A mutable component that emits sound from an entity's position. Supports looping, pitch
        shifting, and configurable spatial attenuation. Set
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">spatial=false</code>
        for non-positional audio like background music or UI sounds.
      </p>
      <CodeBlock :code="sourceCode" lang="julia" filename="audio_source.jl" />
    </section>

    <!-- 3D Positional Audio -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> 3D Positional Audio
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Spatial sources use inverse distance clamped attenuation. Volume decreases as the listener
        moves away from the source, controlled by three parameters:
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">reference_distance</code>,
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">max_distance</code>, and
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">rolloff_factor</code>.
        Doppler effect is computed automatically by OpenAL from relative velocities.
      </p>
      <CodeBlock :code="spatialCode" lang="julia" filename="spatial_audio.jl" />
    </section>

    <!-- WAV Loading -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> WAV Loading
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Audio files are loaded lazily on first use. The backend maintains a buffer cache so each
        WAV file is only read from disk once, regardless of how many sources reference it.
        Supports PCM 8-bit and 16-bit, mono and stereo.
      </p>
      <CodeBlock :code="wavLoadingCode" lang="julia" filename="wav_loading.jl" />
    </section>

    <!-- Full Example -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Example: Scene with Audio
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        A complete scene with a camera listener, a spatial campfire sound source, and non-spatial
        background music.
      </p>
      <CodeBlock :code="fullExampleCode" lang="julia" filename="audio_example.jl" />
    </section>
  </div>
</template>
