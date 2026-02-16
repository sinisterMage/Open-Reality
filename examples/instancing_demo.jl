# Instanced Rendering demo
# Demonstrates automatic draw call batching for entities sharing the same mesh + material.
# 1000 cubes are rendered — entities with the same material are batched into instanced draws.

using OpenReality

reset_entity_counter!()
reset_component_stores!()

# Shared mesh (all cubes share the same MeshComponent reference for batching)
shared_cube = cube_mesh()

# Shared materials (entities with same material + mesh get instanced together)
mat_red   = MaterialComponent(color=RGB{Float32}(0.9, 0.15, 0.1), metallic=0.7f0, roughness=0.2f0)
mat_blue  = MaterialComponent(color=RGB{Float32}(0.1, 0.3, 0.9), metallic=0.5f0, roughness=0.3f0)
mat_green = MaterialComponent(color=RGB{Float32}(0.1, 0.8, 0.2), metallic=0.3f0, roughness=0.5f0)
mat_gold  = MaterialComponent(color=RGB{Float32}(1.0, 0.84, 0.0), metallic=0.95f0, roughness=0.1f0)
materials = [mat_red, mat_blue, mat_green, mat_gold]

# Generate 1000 cubes in a grid, cycling through materials
cube_entities = []
grid_size = 10  # 10x10x10 = 1000
spacing = 2.5
for ix in 1:grid_size, iy in 1:grid_size, iz in 1:grid_size
    x = Float64((ix - grid_size/2) * spacing)
    y = Float64((iy - 1) * spacing + 0.5)
    z = Float64(-(iz - 1) * spacing - 5)
    mat_idx = ((ix + iy + iz) % length(materials)) + 1

    push!(cube_entities, entity([
        shared_cube,
        materials[mat_idx],
        transform(position=Vec3d(x, y, z), scale=Vec3d(0.4, 0.4, 0.4))
    ]))
end

s = scene([
    # Player
    create_player(position=Vec3d(0, 2, 20)),

    # Floor
    entity([
        cube_mesh(),
        MaterialComponent(color=RGB{Float32}(0.3, 0.3, 0.35), metallic=0.0f0, roughness=0.8f0),
        transform(position=Vec3d(0, -0.5, 0), scale=Vec3d(50, 0.5, 50)),
        ColliderComponent(shape=AABBShape(Vec3f(50.0f0, 0.5f0, 50.0f0))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]),

    # Sun
    entity([
        DirectionalLightComponent(direction=Vec3f(0.4, -0.8, -0.4), intensity=3.0f0)
    ]),

    # Ambient fill light
    entity([
        PointLightComponent(color=RGB{Float32}(0.6, 0.7, 1.0), intensity=50.0f0, range=40.0f0),
        transform(position=Vec3d(0, 15, 0))
    ]),

    cube_entities...
])

@info "Instancing Demo: $(entity_count(s)) entities ($(length(cube_entities)) cubes)"
@info "Cubes sharing the same mesh+material are automatically batched into instanced draw calls"
render(s, post_process=PostProcessConfig(
    bloom_enabled=true,
    bloom_intensity=0.15f0,
    tone_mapping=TONEMAP_ACES,
    fxaa_enabled=true
))
