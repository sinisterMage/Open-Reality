# Material component

using ColorTypes

"""
    TextureRef

Reference to a texture by file path. The rendering system resolves
these to GPU textures at render time via the TextureCache.
"""
struct TextureRef
    path::String
end

"""
    MaterialComponent <: Component

PBR material with optional texture maps.
When a texture is set, it overrides the corresponding uniform value.
"""
struct MaterialComponent <: Component
    color::RGB{Float32}
    metallic::Float32
    roughness::Float32
    albedo_map::Union{TextureRef, Nothing}
    normal_map::Union{TextureRef, Nothing}
    metallic_roughness_map::Union{TextureRef, Nothing}
    ao_map::Union{TextureRef, Nothing}
    emissive_map::Union{TextureRef, Nothing}
    emissive_factor::Vec3f

    MaterialComponent(;
        color::RGB{Float32} = RGB{Float32}(1.0, 1.0, 1.0),
        metallic::Float32 = 0.0f0,
        roughness::Float32 = 0.5f0,
        albedo_map::Union{TextureRef, Nothing} = nothing,
        normal_map::Union{TextureRef, Nothing} = nothing,
        metallic_roughness_map::Union{TextureRef, Nothing} = nothing,
        ao_map::Union{TextureRef, Nothing} = nothing,
        emissive_map::Union{TextureRef, Nothing} = nothing,
        emissive_factor::Vec3f = Vec3f(0, 0, 0)
    ) = new(color, metallic, roughness, albedo_map, normal_map,
            metallic_roughness_map, ao_map, emissive_map, emissive_factor)
end
