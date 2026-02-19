<script setup lang="ts">
definePageMeta({ layout: 'docs' })
useSeoMeta({
  title: 'Terrain System - OpenReality Docs',
  ogTitle: 'Terrain System - OpenReality Docs',
  description: 'Heightmap-based terrain with LOD, splatmap multi-texturing, Perlin noise generation, and physics collision in OpenReality.',
  ogDescription: 'Heightmap-based terrain with LOD, splatmap multi-texturing, Perlin noise generation, and physics collision in OpenReality.',
})

const terrainComponentCode = `TerrainComponent(
    heightmap = HeightmapSource(...),       # height data source
    terrain_size = Vec2f(256.0f0, 256.0f0), # world X, Z dimensions
    max_height = 50.0f0,                    # maximum elevation
    chunk_size = 33,                        # vertices per chunk edge
    num_lod_levels = 3,                     # LOD levels per chunk
    splatmap_path = "terrain/splatmap.png",  # RGBA texture (4 layers)
    layers = TerrainLayer[...]              # up to 4 texture layers
)`

const heightmapSourcesCode = `# Load from a grayscale image
HeightmapSource(
    source_type = HEIGHTMAP_IMAGE,
    image_path = "terrain/heightmap.png"
)

# Generate with Perlin FBM noise
HeightmapSource(
    source_type = HEIGHTMAP_PERLIN,
    perlin_octaves = 6,         # FBM noise octaves
    perlin_frequency = 0.01f0,  # base noise frequency
    perlin_persistence = 0.5f0, # amplitude decay per octave
    perlin_seed = 42            # random seed
)

# Flat terrain (all zeros)
HeightmapSource(source_type = HEIGHTMAP_FLAT)`

const terrainLayersCode = `# Each layer has an albedo texture, optional normal map, and UV scale
TerrainLayer(
    albedo_path = "terrain/grass_albedo.png",
    normal_path = "terrain/grass_normal.png",
    uv_scale = 10.0f0   # texture repeat frequency
)

# The splatmap is an RGBA image where each channel controls
# blending weight for one layer:
#   R channel → Layer 1 (e.g. grass)
#   G channel → Layer 2 (e.g. dirt)
#   B channel → Layer 3 (e.g. rock)
#   A channel → Layer 4 (e.g. snow)

layers = [
    TerrainLayer(albedo_path="terrain/grass.png",  normal_path="terrain/grass_n.png",  uv_scale=10.0f0),
    TerrainLayer(albedo_path="terrain/dirt.png",   normal_path="terrain/dirt_n.png",   uv_scale=8.0f0),
    TerrainLayer(albedo_path="terrain/rock.png",   normal_path="terrain/rock_n.png",   uv_scale=6.0f0),
    TerrainLayer(albedo_path="terrain/snow.png",   normal_path="terrain/snow_n.png",   uv_scale=12.0f0),
]`

const heightmapShapeCode = `# HeightmapShape enables physics collision on terrain.
# The physics engine samples the height grid for contact generation.

ColliderComponent(
    shape = HeightmapShape(
        heights,  # Matrix{Float32} of height values
        width,    # grid width (number of columns)
        depth,    # grid depth (number of rows)
        scale     # Vec3f(x_scale, y_scale, z_scale)
    )
)`

const fullExampleCode = `# Complete terrain entity with physics
entity([
    transform(position=Vec3d(0, 0, 0)),
    TerrainComponent(
        heightmap = HeightmapSource(
            source_type = HEIGHTMAP_PERLIN,
            perlin_octaves = 6,
            perlin_frequency = 0.008f0,
            perlin_persistence = 0.45f0,
            perlin_seed = 123
        ),
        terrain_size = Vec2f(512.0f0, 512.0f0),
        max_height = 80.0f0,
        chunk_size = 33,
        num_lod_levels = 4,
        splatmap_path = "terrain/splatmap.png",
        layers = [
            TerrainLayer(
                albedo_path = "terrain/grass_albedo.png",
                normal_path = "terrain/grass_normal.png",
                uv_scale = 10.0f0
            ),
            TerrainLayer(
                albedo_path = "terrain/rock_albedo.png",
                normal_path = "terrain/rock_normal.png",
                uv_scale = 6.0f0
            ),
            TerrainLayer(
                albedo_path = "terrain/dirt_albedo.png",
                normal_path = "terrain/dirt_normal.png",
                uv_scale = 8.0f0
            ),
            TerrainLayer(
                albedo_path = "terrain/snow_albedo.png",
                normal_path = "terrain/snow_normal.png",
                uv_scale = 12.0f0
            ),
        ]
    ),
    # Physics collision for the terrain surface
    ColliderComponent(shape=HeightmapShape(heights, w, d, scale)),
    RigidBodyComponent(body_type=BODY_STATIC)
])`
</script>

<template>
  <div class="space-y-12">
    <div>
      <h1 class="text-3xl font-mono font-bold text-or-text">Terrain System</h1>
      <p class="text-or-text-dim mt-3 leading-relaxed">
        Heightmap-based terrain with chunked LOD, splatmap multi-texturing (up to 4 layers),
        procedural Perlin noise generation, and physics collision via
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">HeightmapShape</code>.
      </p>
    </div>

    <!-- TerrainComponent -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> TerrainComponent
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        The <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">TerrainComponent</code>
        defines all terrain parameters: heightmap source, world dimensions, LOD configuration,
        and texture layers for splatmap blending.
      </p>
      <CodeBlock :code="terrainComponentCode" lang="julia" filename="terrain_component.jl" />
    </section>

    <!-- Heightmap Sources -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Heightmap Sources
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Three heightmap source types are available:
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">HEIGHTMAP_IMAGE</code> loads
        from a grayscale image,
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">HEIGHTMAP_PERLIN</code> generates
        procedural terrain using FBM noise, and
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">HEIGHTMAP_FLAT</code> creates
        a flat plane.
      </p>
      <CodeBlock :code="heightmapSourcesCode" lang="julia" filename="heightmap_sources.jl" />
    </section>

    <!-- Terrain Layers -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Terrain Layers
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        Up to 4 texture layers can be blended using an RGBA splatmap. Each channel of the splatmap
        controls the blending weight for one <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">TerrainLayer</code>.
        Each layer specifies an albedo texture, an optional normal map, and a UV scale for tiling.
      </p>
      <CodeBlock :code="terrainLayersCode" lang="julia" filename="terrain_layers.jl" />
    </section>

    <!-- HeightmapShape -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Physics Collision
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">HeightmapShape</code>
        provides physics collision for terrain surfaces. Attach it as a
        <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">ColliderComponent</code>
        shape alongside a static <code class="text-or-text-code bg-or-panel px-1.5 py-0.5 rounded text-sm">RigidBodyComponent</code>
        so dynamic objects can walk on and collide with the terrain.
      </p>
      <CodeBlock :code="heightmapShapeCode" lang="julia" filename="heightmap_shape.jl" />
    </section>

    <!-- Full Example -->
    <section>
      <h2 class="text-xl font-mono font-bold text-or-text mb-4">
        <span class="text-or-green">#</span> Example: Complete Terrain
      </h2>
      <p class="text-or-text-dim mb-4 leading-relaxed">
        A full terrain entity with procedural Perlin heightmap, four splatmap texture layers,
        and physics collision.
      </p>
      <CodeBlock :code="fullExampleCode" lang="julia" filename="terrain_example.jl" />
    </section>
  </div>
</template>
