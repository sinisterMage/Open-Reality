# Asset pipeline for export/build: texture compression, mesh optimization,
# and shader precompilation.

# ─── Texture Compression ──────────────────────────────────────────────

"""
    TextureFormat

Target format for compressed textures.
"""
@enum TextureFormat begin
    TEX_PNG         # Lossless PNG (default, no extra deps)
    TEX_JPEG        # Lossy JPEG (smaller, ok for diffuse)
    TEX_KTX2_BC7    # KTX2 + BCn (desktop)
    TEX_KTX2_ASTC   # KTX2 + ASTC (mobile)
end

"""
    AssetPipelineConfig

Configuration for asset processing during export.
"""
struct AssetPipelineConfig
    texture_format::TextureFormat
    texture_max_size::Int           # Max texture dimension (0 = no limit)
    texture_quality::Float32        # 0.0-1.0 for lossy formats
    optimize_meshes::Bool           # Re-index and de-duplicate vertices
    generate_lod_meshes::Bool       # Auto-generate LOD meshes
    lod_levels::Int                 # Number of LOD levels to generate
    lod_reduction::Float32          # Vertex reduction per level (0.0-1.0)
    validate_shaders::Bool          # Validate WGSL/GLSL shaders

    function AssetPipelineConfig(;
        texture_format::TextureFormat = TEX_PNG,
        texture_max_size::Int = 0,
        texture_quality::Float32 = 0.85f0,
        optimize_meshes::Bool = true,
        generate_lod_meshes::Bool = false,
        lod_levels::Int = 3,
        lod_reduction::Float32 = 0.5f0,
        validate_shaders::Bool = false
    )
        new(texture_format, texture_max_size, texture_quality,
            optimize_meshes, generate_lod_meshes, lod_levels, lod_reduction,
            validate_shaders)
    end
end

"""
    process_texture(path::String, config::AssetPipelineConfig) -> Vector{UInt8}

Read and optionally compress a texture file according to the pipeline config.
Returns the processed texture data as bytes.
"""
function process_texture(path::String, config::AssetPipelineConfig)
    if !isfile(path)
        @warn "Texture not found: $path"
        return UInt8[]
    end

    data = read(path)

    # For PNG format, just return raw data (optionally resize)
    if config.texture_format == TEX_PNG
        if config.texture_max_size > 0
            data = _resize_texture_if_needed(data, config.texture_max_size)
        end
        return data
    end

    # For JPEG, convert via FileIO if available
    if config.texture_format == TEX_JPEG
        return _compress_jpeg(data, config.texture_quality, config.texture_max_size)
    end

    # KTX2 formats require external tools
    if config.texture_format in (TEX_KTX2_BC7, TEX_KTX2_ASTC)
        return _compress_ktx2(path, config)
    end

    return data
end

function _resize_texture_if_needed(data::Vector{UInt8}, max_size::Int)
    # PNG dimension check from header (bytes 16-23 contain width and height as big-endian u32)
    if length(data) > 24 && data[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]
        w = UInt32(data[17]) << 24 | UInt32(data[18]) << 16 | UInt32(data[19]) << 8 | UInt32(data[20])
        h = UInt32(data[21]) << 24 | UInt32(data[22]) << 16 | UInt32(data[23]) << 8 | UInt32(data[24])
        if w <= max_size && h <= max_size
            return data  # Already within limits
        end
        @info "Texture exceeds max size ($w x $h > $max_size), resize not implemented — returning original"
    end
    return data
end

function _compress_jpeg(data::Vector{UInt8}, quality::Float32, max_size::Int)
    # Try to use FileIO + ImageMagick for JPEG compression
    try
        @eval begin
            using FileIO
            using ImageIO
        end
        tmp_in = tempname() * ".png"
        tmp_out = tempname() * ".jpg"
        write(tmp_in, data)
        img = Base.invokelatest(FileIO.load, tmp_in)
        Base.invokelatest(FileIO.save, tmp_out, img)
        result = read(tmp_out)
        rm(tmp_in; force=true)
        rm(tmp_out; force=true)
        return result
    catch e
        @warn "JPEG compression not available, returning PNG data" exception=e
        return data
    end
end

function _compress_ktx2(path::String, config::AssetPipelineConfig)
    # KTX2 compression requires toktx from KTX-Software
    toktx = Sys.which("toktx")
    if toktx === nothing
        @warn "toktx not found — KTX2 compression unavailable. Install KTX-Software."
        return read(path)
    end

    tmp_out = tempname() * ".ktx2"
    codec = config.texture_format == TEX_KTX2_BC7 ? "BasisLZ" : "ASTC"

    try
        run(`$toktx --t2 --encode $codec $tmp_out $path`)
        result = read(tmp_out)
        rm(tmp_out; force=true)
        @info "Compressed $(basename(path)) to KTX2 ($codec): $(length(result)) bytes"
        return result
    catch e
        @warn "KTX2 compression failed for $path" exception=e
        return read(path)
    end
end

# ─── Mesh Optimization ────────────────────────────────────────────────

"""
    optimize_mesh(mesh::MeshComponent) -> MeshComponent

Optimize a mesh by removing duplicate vertices and rebuilding the index buffer.
"""
function optimize_mesh(mesh::MeshComponent)
    nv = length(mesh.vertices)
    if nv == 0
        return mesh
    end

    # Build a map of unique vertices
    VertexKey = Tuple{Float32, Float32, Float32, Float32, Float32, Float32, Float32, Float32}
    vertex_map = Dict{VertexKey, UInt32}()
    new_vertices = eltype(mesh.vertices)[]
    new_normals = eltype(mesh.normals)[]
    new_uvs = eltype(mesh.uvs)[]
    new_bone_weights = eltype(mesh.bone_weights)[]
    new_bone_indices = eltype(mesh.bone_indices)[]
    remap = zeros(UInt32, nv)

    for i in 1:nv
        v = mesh.vertices[i]
        n = i <= length(mesh.normals) ? mesh.normals[i] : Vec3f(0, 1, 0)
        uv = i <= length(mesh.uvs) ? mesh.uvs[i] : Vec2f(0, 0)

        key = (v[1], v[2], v[3], n[1], n[2], n[3], uv[1], uv[2])
        if haskey(vertex_map, key)
            remap[i] = vertex_map[key]
        else
            idx = UInt32(length(new_vertices))
            vertex_map[key] = idx
            remap[i] = idx
            push!(new_vertices, v)
            push!(new_normals, n)
            push!(new_uvs, uv)
            if !isempty(mesh.bone_weights) && i <= length(mesh.bone_weights)
                push!(new_bone_weights, mesh.bone_weights[i])
                push!(new_bone_indices, mesh.bone_indices[i])
            end
        end
    end

    # Remap indices
    new_indices = UInt32[remap[idx + 1] for idx in mesh.indices]

    removed = nv - length(new_vertices)
    if removed > 0
        @info "Mesh optimization: removed $removed duplicate vertices ($nv → $(length(new_vertices)))"
    end

    MeshComponent(
        vertices = new_vertices,
        normals = new_normals,
        uvs = new_uvs,
        indices = new_indices,
        bone_weights = new_bone_weights,
        bone_indices = new_bone_indices,
    )
end

"""
    generate_lod_mesh(mesh::MeshComponent, reduction::Float32) -> MeshComponent

Generate a simplified LOD mesh by reducing vertex count.
Uses a simple edge-collapse approximation.
"""
function generate_lod_mesh(mesh::MeshComponent, reduction::Float32)
    target_tris = max(1, round(Int, length(mesh.indices) / 3 * (1.0f0 - reduction)))
    current_tris = length(mesh.indices) ÷ 3

    if current_tris <= target_tris
        return mesh
    end

    # Simple uniform vertex decimation: merge nearby vertices using a spatial grid
    nv = length(mesh.vertices)
    if nv == 0
        return mesh
    end

    # Compute bounding box
    min_pos = Vec3f(Inf32, Inf32, Inf32)
    max_pos = Vec3f(-Inf32, -Inf32, -Inf32)
    for v in mesh.vertices
        min_pos = Vec3f(min(min_pos[1], v[1]), min(min_pos[2], v[2]), min(min_pos[3], v[3]))
        max_pos = Vec3f(max(max_pos[1], v[1]), max(max_pos[2], v[2]), max(max_pos[3], v[3]))
    end

    extent = max_pos - min_pos
    max_extent = max(extent[1], extent[2], extent[3])
    if max_extent < 1e-6
        return mesh
    end

    # Grid cell size based on desired reduction
    grid_size = max_extent * reduction * 0.5f0
    if grid_size < 1e-6
        return mesh
    end

    # Quantize vertices to grid cells and merge
    CellKey = Tuple{Int32, Int32, Int32}
    cell_map = Dict{CellKey, UInt32}()
    new_vertices = eltype(mesh.vertices)[]
    new_normals = eltype(mesh.normals)[]
    new_uvs = eltype(mesh.uvs)[]
    remap = zeros(UInt32, nv)

    for i in 1:nv
        v = mesh.vertices[i]
        cell = (Int32(floor((v[1] - min_pos[1]) / grid_size)),
                Int32(floor((v[2] - min_pos[2]) / grid_size)),
                Int32(floor((v[3] - min_pos[3]) / grid_size)))

        if haskey(cell_map, cell)
            remap[i] = cell_map[cell]
        else
            idx = UInt32(length(new_vertices))
            cell_map[cell] = idx
            remap[i] = idx
            push!(new_vertices, v)
            push!(new_normals, i <= length(mesh.normals) ? mesh.normals[i] : Vec3f(0, 1, 0))
            push!(new_uvs, i <= length(mesh.uvs) ? mesh.uvs[i] : Vec2f(0, 0))
        end
    end

    # Remap and filter degenerate triangles
    new_indices = UInt32[]
    ni = length(mesh.indices)
    for t in 1:3:(ni - 2)
        a = remap[mesh.indices[t] + 1]
        b = remap[mesh.indices[t + 1] + 1]
        c = remap[mesh.indices[t + 2] + 1]
        if a != b && b != c && a != c
            push!(new_indices, a, b, c)
        end
    end

    @info "LOD generation: $(current_tris) → $(length(new_indices) ÷ 3) triangles, $(nv) → $(length(new_vertices)) vertices"

    MeshComponent(
        vertices = new_vertices,
        normals = new_normals,
        uvs = new_uvs,
        indices = new_indices,
    )
end

# ─── Shader Validation ────────────────────────────────────────────────

"""
    validate_wgsl_shader(path::String) -> Bool

Validate a WGSL shader file using naga (if available).
"""
function validate_wgsl_shader(path::String)
    naga = Sys.which("naga")
    if naga === nothing
        @warn "naga not found — WGSL validation unavailable. Install naga-cli."
        return true
    end

    try
        run(`$naga $path`)
        return true
    catch e
        @error "WGSL validation failed: $path" exception=e
        return false
    end
end

"""
    validate_glsl_shader(path::String, stage::String) -> Bool

Validate a GLSL shader file using glslangValidator (if available).
"""
function validate_glsl_shader(path::String, stage::String = "frag")
    validator = Sys.which("glslangValidator")
    if validator === nothing
        @warn "glslangValidator not found — GLSL validation unavailable."
        return true
    end

    try
        run(`$validator -S $stage $path`)
        return true
    catch e
        @error "GLSL validation failed: $path" exception=e
        return false
    end
end

# ─── Pipeline Orchestration ──────────────────────────────────────────

"""
    process_assets(scene::Scene, config::AssetPipelineConfig) -> ProcessedAssets

Run the full asset pipeline on a scene: optimize meshes, compress textures,
and validate shaders. Returns processed data ready for export.
"""
struct ProcessedAssets
    meshes::Vector{MeshComponent}
    mesh_index_map::Dict{UInt64, UInt32}
    textures::Dict{String, Vector{UInt8}}
    lod_meshes::Dict{UInt64, Vector{MeshComponent}}  # original hash → LOD levels
end

function process_assets(scene::Scene, config::AssetPipelineConfig)
    entities = scene.entities

    # Collect and optimize meshes
    unique_meshes = MeshComponent[]
    mesh_index_map = Dict{UInt64, UInt32}()
    lod_meshes = Dict{UInt64, Vector{MeshComponent}}()

    for eid in entities
        if has_component(eid, MeshComponent)
            mesh = get_component(eid, MeshComponent)
            h = objectid(mesh)
            if !haskey(mesh_index_map, h)
                processed = config.optimize_meshes ? optimize_mesh(mesh) : mesh
                mesh_index_map[h] = UInt32(length(unique_meshes))
                push!(unique_meshes, processed)

                # Generate LOD meshes if requested
                if config.generate_lod_meshes
                    lods = MeshComponent[]
                    current = processed
                    for level in 1:config.lod_levels
                        lod = generate_lod_mesh(current, config.lod_reduction)
                        push!(lods, lod)
                        current = lod
                    end
                    lod_meshes[h] = lods
                end
            end
        end
    end

    # Collect and process textures
    texture_paths = Set{String}()
    for eid in entities
        if has_component(eid, MaterialComponent)
            mat = get_component(eid, MaterialComponent)
            for field in [:albedo_map, :normal_map, :metallic_roughness_map, :ao_map,
                          :emissive_map, :height_map, :clearcoat_map]
                if hasproperty(mat, field)
                    tex_ref = getproperty(mat, field)
                    if tex_ref !== nothing && tex_ref isa TextureRef && tex_ref.path != ""
                        push!(texture_paths, tex_ref.path)
                    end
                end
            end
        end
    end

    processed_textures = Dict{String, Vector{UInt8}}()
    for path in texture_paths
        processed_textures[path] = process_texture(path, config)
    end

    @info "Asset pipeline complete" meshes=length(unique_meshes) textures=length(processed_textures) lod_meshes=length(lod_meshes)

    ProcessedAssets(unique_meshes, mesh_index_map, processed_textures, lod_meshes)
end
