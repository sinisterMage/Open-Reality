# Shader Permutation System
# Compiles shader variants based on material features to avoid massive uber-shaders

"""
    ShaderFeature

Enum of shader features that can be enabled/disabled per material.
Each feature adds a #define to the shader compilation.
"""
@enum ShaderFeature begin
    FEATURE_ALBEDO_MAP
    FEATURE_NORMAL_MAP
    FEATURE_METALLIC_ROUGHNESS_MAP
    FEATURE_AO_MAP
    FEATURE_EMISSIVE_MAP
    FEATURE_ALPHA_CUTOFF
    FEATURE_CLEARCOAT
    FEATURE_PARALLAX_MAPPING
    FEATURE_SUBSURFACE
    FEATURE_LOD_DITHER
    FEATURE_INSTANCED
    FEATURE_TERRAIN_SPLATMAP
    FEATURE_SKINNING
end

"""
    ShaderVariantKey

Key for caching shader variants based on enabled features.
"""
struct ShaderVariantKey
    features::Set{ShaderFeature}
end

# Implement hash and equality for dictionary lookups
Base.hash(key::ShaderVariantKey, h::UInt) = hash(key.features, h)
Base.:(==)(a::ShaderVariantKey, b::ShaderVariantKey) = a.features == b.features

"""
    ShaderLibrary{S <: AbstractShaderProgram}

Manages shader variants with lazy compilation.
Stores template shaders and compiles variants on-demand based on feature sets.
Parametric on the shader program type to support multiple backends.
"""
mutable struct ShaderLibrary{S <: AbstractShaderProgram}
    variants::Dict{ShaderVariantKey, S}
    template_vertex::String
    template_fragment::String
    shader_name::String  # For debugging
    compile_fn::Function  # (vertex_src::String, fragment_src::String) -> S

    ShaderLibrary{S}(name::String, vertex_template::String, fragment_template::String,
                     compile_fn::Function) where S =
        new{S}(Dict{ShaderVariantKey, S}(), vertex_template, fragment_template, name, compile_fn)
end

"""
    _insert_defines_after_version(source::String, define_block::String) -> String

Insert `#define` directives after the `#version` line in GLSL source,
or prepend them for MSL sources (which have no `#version` line).
GLSL requires `#version` to be the very first line, so defines must come after it.
MSL has no such restriction — defines are prepended at the top.
"""
function _insert_defines_after_version(source::String, define_block::String)::String
    if isempty(define_block)
        return source
    end

    # Detect MSL vs GLSL: MSL sources typically start with #include <metal_stdlib>
    # or lack a #version directive. Check if the first non-empty line is #version.
    first_line_end = findfirst('\n', source)
    first_line = first_line_end === nothing ? source : source[1:first_line_end-1]

    if startswith(strip(first_line), "#version")
        # GLSL: insert defines after the #version line
        version_line = source[1:first_line_end]  # includes the '\n'
        rest = source[first_line_end+1:end]
        return version_line * define_block * "\n" * rest
    else
        # MSL (or other): prepend defines at the top
        return define_block * "\n" * source
    end
end

"""
    get_or_compile_variant!(lib::ShaderLibrary{S}, key::ShaderVariantKey) -> S

Get a cached shader variant or compile a new one if it doesn't exist.
"""
function get_or_compile_variant!(lib::ShaderLibrary{S}, key::ShaderVariantKey)::S where S
    # Check cache
    if haskey(lib.variants, key)
        return lib.variants[key]
    end

    # Generate #defines from features
    defines = String[]
    for feature in key.features
        push!(defines, "#define $(uppercase(string(feature)))")
    end

    # Insert defines after #version line (GLSL requires #version on the first line)
    define_block = join(defines, "\n")
    vertex_src = _insert_defines_after_version(lib.template_vertex, define_block)
    fragment_src = _insert_defines_after_version(lib.template_fragment, define_block)

    # Compile shader using the backend-specific compile function
    try
        program = lib.compile_fn(vertex_src, fragment_src)
        lib.variants[key] = program

        # Debug info
        feature_names = join([string(f) for f in key.features], ", ")
        @info "Compiled shader variant: $(lib.shader_name) [$(feature_names)]"

        return program
    catch e
        @error "Failed to compile shader variant: $(lib.shader_name)" exception=e
        rethrow()
    end
end

"""
    determine_shader_variant(material::MaterialComponent) -> ShaderVariantKey

Determine which shader variant to use based on material properties.
"""
function determine_shader_variant(material::MaterialComponent)::ShaderVariantKey
    features = Set{ShaderFeature}()

    # Check texture presence
    if material.albedo_map !== nothing
        push!(features, FEATURE_ALBEDO_MAP)
    end
    if material.normal_map !== nothing
        push!(features, FEATURE_NORMAL_MAP)
    end
    if material.metallic_roughness_map !== nothing
        push!(features, FEATURE_METALLIC_ROUGHNESS_MAP)
    end
    if material.ao_map !== nothing
        push!(features, FEATURE_AO_MAP)
    end
    if material.emissive_map !== nothing
        push!(features, FEATURE_EMISSIVE_MAP)
    end

    # Check alpha cutoff
    if material.alpha_cutoff > 0.0f0
        push!(features, FEATURE_ALPHA_CUTOFF)
    end

    # Advanced material features
    if material.clearcoat > 0.0f0 || material.clearcoat_map !== nothing
        push!(features, FEATURE_CLEARCOAT)
    end
    if material.height_map !== nothing && material.parallax_height_scale > 0.0f0
        push!(features, FEATURE_PARALLAX_MAPPING)
    end
    if material.subsurface > 0.0f0
        push!(features, FEATURE_SUBSURFACE)
    end

    return ShaderVariantKey(features)
end

"""
    destroy_shader_library!(lib::ShaderLibrary)

Destroy all compiled shader variants in the library.
"""
function destroy_shader_library!(lib::ShaderLibrary)
    for (key, program) in lib.variants
        destroy_shader_program!(program)
    end
    empty!(lib.variants)
    return nothing
end

"""
    get_variant_count(lib::ShaderLibrary) -> Int

Get the number of compiled variants in the library.
"""
function get_variant_count(lib::ShaderLibrary)::Int
    return length(lib.variants)
end
