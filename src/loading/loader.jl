# Unified model loading dispatcher

"""
    load_model(path::String; kwargs...) -> Vector{EntityDef}

Load a 3D model file and return a vector of EntityDefs.

Dispatches by file extension:
- `.obj` → OBJ loader (via MeshIO)
- `.gltf`, `.glb` → glTF 2.0 loader

# Keyword Arguments
- For OBJ: `default_material::MaterialComponent` — override material
- For glTF: `base_dir::String` — directory for resolving relative texture paths
"""
function load_model(path::String; kwargs...)
    ext = lowercase(splitext(path)[2])

    if ext == ".obj"
        return load_obj(path; kwargs...)
    elseif ext == ".gltf" || ext == ".glb"
        return load_gltf(path; kwargs...)
    else
        error("Unsupported model format: '$ext'. Supported formats: .obj, .gltf, .glb")
    end
end
