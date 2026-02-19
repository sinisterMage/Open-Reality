<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Rendering Guide - OpenReality Docs',
  ogTitle: 'Rendering Guide - OpenReality Docs',
  description: 'OpenReality rendering: 4 GPU backends, deferred PBR pipeline, cascaded shadow maps, IBL, post-processing, transparency, and shader variants.',
  ogDescription: 'OpenReality rendering: 4 GPU backends, deferred PBR pipeline, cascaded shadow maps, IBL, post-processing, transparency, and shader variants.',
})

const backendsCode = `# OpenGL 3.3 (default, all platforms)
render(s, backend=OpenGLBackend())

# Vulkan (Linux/Windows, full deferred pipeline)
render(s, backend=VulkanBackend())

# Metal (macOS)
render(s, backend=MetalBackend())

# WebGPU (via Rust FFI, WASM-exportable)
render(s, backend=WebGPUBackend())`

const pbrCode = `# Full PBR material
MaterialComponent(
    color=RGB{Float32}(0.9, 0.1, 0.1),
    metallic=0.8f0,
    roughness=0.2f0,
    albedo_map=TextureRef("metal_albedo.png"),
    normal_map=TextureRef("metal_normal.png"),
    metallic_roughness_map=TextureRef("metal_mr.png"),
    ao_map=TextureRef("metal_ao.png"),
    emissive_map=TextureRef("metal_emissive.png"),
    emissive_factor=Vec3f(1, 0.5, 0)
)`

const advancedCode = `# Clear coat (lacquered/coated surfaces)
MaterialComponent(
    clearcoat=1.0f0,
    clearcoat_roughness=0.1f0,
    clearcoat_map=TextureRef("clearcoat.png")
)

# Parallax occlusion mapping (depth illusion)
MaterialComponent(
    height_map=TextureRef("height.png"),
    parallax_height_scale=0.05f0
)

# Subsurface scattering (skin, wax, leaves)
MaterialComponent(
    subsurface=0.5f0,
    subsurface_color=Vec3f(1.0, 0.2, 0.1)
)`

const postprocessCode = `render(s,
    post_process=PostProcessConfig(
        # Bloom
        bloom_enabled=true,
        bloom_threshold=1.0f0,
        bloom_intensity=0.5f0,

        # Tone mapping
        tone_mapping=TONEMAP_ACES,  # or TONEMAP_REINHARD, TONEMAP_UNCHARTED2

        # Anti-aliasing
        fxaa_enabled=true,

        # Depth of field
        dof_enabled=true,
        dof_focus_distance=10.0f0,
        dof_focus_range=5.0f0,

        # Motion blur
        motion_blur_enabled=true,
        motion_blur_intensity=1.0f0
    )
)`

const shadowsCode = `# Cascaded Shadow Maps are automatic when
# DirectionalLightComponent is present.
#
# Configuration:
#   4 cascades
#   PCF filtering
#   Slope-scaled bias
#   Shadow map uses texture unit 6
#
# CSM works with all backends that support
# the deferred rendering pipeline.

entity([
    DirectionalLightComponent(
        direction=Vec3f(-0.5, -1, -0.3),
        color=RGB{Float32}(1, 1, 1),
        intensity=2.0f0
    )
])`

const iblCode = `# Image-based lighting for environment reflections
entity([
    IBLComponent(
        environment_path="skybox.hdr",
        intensity=1.0f0
    )
])

# IBL generates:
#   - Irradiance cubemap (diffuse)
#   - Pre-filtered environment map (specular)
#   - BRDF lookup texture`

const deferredCode = `# Deferred rendering pipeline (all backends):
#
# Geometry Pass (G-Buffer):
#   - Albedo + metallic
#   - Normal + roughness
#   - Position + AO
#   - Emissive
#
# Lighting Pass:
#   - PBR shading from G-Buffer
#   - Point lights, directional lights
#   - IBL (image-based lighting)
#
# Post-processing:
#   - SSAO (screen-space ambient occlusion)
#   - SSR (screen-space reflections)
#   - TAA (temporal anti-aliasing)
#   - Bloom + tone mapping
#   - DOF + motion blur
#   - FXAA`

const transparencyCode = `# Two-pass rendering for transparency:
# 1. Opaque entities rendered first (front-to-back)
# 2. Transparent entities rendered second (back-to-front)

# Set opacity < 1.0 for transparency
MaterialComponent(
    color=RGB{Float32}(0.2, 0.5, 1.0),
    opacity=0.5f0
)

# Alpha cutoff for masked rendering (foliage, fences)
MaterialComponent(
    albedo_map=TextureRef("leaves.png"),
    alpha_cutoff=0.5f0
)`

const shaderVariantsCode = `# Shader features are compiled on-demand:
#   FEATURE_ALBEDO_MAP
#   FEATURE_NORMAL_MAP
#   FEATURE_METALLIC_ROUGHNESS_MAP
#   FEATURE_AO_MAP
#   FEATURE_EMISSIVE_MAP
#   FEATURE_ALPHA_CUTOFF
#   FEATURE_CLEARCOAT
#   FEATURE_PARALLAX_MAPPING
#   FEATURE_SUBSURFACE
#   FEATURE_LOD_DITHER
#   FEATURE_INSTANCED
#
# The ShaderLibrary caches variants by feature set.
# Only the defines you need are compiled.`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Rendering Guide</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        OpenReality features a physically-based rendering pipeline with deferred shading,
        cascaded shadow maps, image-based lighting, and configurable post-processing.
      </p>
    </div>

    <!-- Backends -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Rendering Backends
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Four backends target different platforms. Switch between them with a single parameter.
      </p>
      <CodeBlock :code="backendsCode" lang="julia" filename="backends.jl" />
    </section>

    <!-- Deferred Pipeline -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Deferred Rendering Pipeline
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        All backends use a full deferred pipeline with G-Buffer rendering,
        decoupling geometry from lighting for efficient multi-light scenes.
      </p>
      <CodeBlock :code="deferredCode" lang="julia" filename="deferred.jl" />
    </section>

    <!-- PBR -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> PBR Materials
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Materials use the metallic-roughness PBR model with full texture support.
        All texture references are resolved lazily and cached by the TextureCache.
      </p>
      <CodeBlock :code="pbrCode" lang="julia" filename="pbr.jl" />
    </section>

    <!-- Advanced materials -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Advanced Material Features
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Three advanced material features for realistic surface rendering.
      </p>
      <CodeBlock :code="advancedCode" lang="julia" filename="advanced_materials.jl" />
    </section>

    <!-- Shadows -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Cascaded Shadow Maps
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Directional lights automatically produce cascaded shadow maps with four cascades,
        PCF filtering, and slope-scaled bias for clean shadow boundaries at all distances.
      </p>
      <CodeBlock :code="shadowsCode" lang="julia" filename="shadows.jl" />
    </section>

    <!-- IBL -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Image-Based Lighting
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Add an HDR environment map for physically accurate reflections and ambient lighting.
        The engine generates irradiance, prefiltered environment, and BRDF lookup textures automatically.
      </p>
      <CodeBlock :code="iblCode" lang="julia" filename="ibl.jl" />
    </section>

    <!-- Post-processing -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Post-Processing
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Configure the HDR post-processing pipeline with bloom, tone mapping, and anti-aliasing.
        Additional screen-space effects (SSAO, SSR, TAA, DOF, motion blur, vignette, color grading) are available on all backends.
      </p>
      <CodeBlock :code="postprocessCode" lang="julia" filename="postprocess.jl" />
    </section>

    <!-- Transparency -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Transparency
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        The renderer uses a two-pass approach: opaque entities first, then transparent entities sorted back-to-front.
        Alpha cutoff provides efficient masked rendering for foliage and fences.
      </p>
      <CodeBlock :code="transparencyCode" lang="julia" filename="transparency.jl" />
    </section>

    <!-- Shader Variants -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Shader Variants
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Instead of a single uber-shader, the engine compiles shader variants on-demand based on the features each material uses.
        Variants are cached in the ShaderLibrary for reuse.
      </p>
      <CodeBlock :code="shaderVariantsCode" lang="julia" filename="shader_variants.jl" />
    </section>
  </div>
</template>
