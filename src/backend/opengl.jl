# OpenGL backend implementation

using ModernGL

"""
    OpenGLBackend <: AbstractBackend

OpenGL rendering backend with PBR pipeline support.
"""
mutable struct OpenGLBackend <: AbstractBackend
    initialized::Bool
    window::Union{Window, Nothing}
    input::InputState
    shader::Union{ShaderProgram, Nothing}
    gpu_cache::GPUResourceCache
    texture_cache::TextureCache

    OpenGLBackend() = new(false, nothing, InputState(), nothing, GPUResourceCache(), TextureCache())
end

function initialize!(backend::OpenGLBackend;
                     width::Int=1280, height::Int=720, title::String="OpenReality")
    backend.window = Window(width=width, height=height, title=title)
    create_window!(backend.window)

    setup_input_callbacks!(backend.window, backend.input)
    setup_resize_callback!(backend.window, (w, h) -> begin
        glViewport(0, 0, w, h)
    end)

    # OpenGL state
    glViewport(0, 0, width, height)
    glEnable(GL_DEPTH_TEST)
    glEnable(GL_CULL_FACE)
    glCullFace(GL_BACK)
    glEnable(GL_MULTISAMPLE)
    glClearColor(0.1f0, 0.1f0, 0.1f0, 1.0f0)

    # Compile PBR shader
    backend.shader = create_shader_program(PBR_VERTEX_SHADER, PBR_FRAGMENT_SHADER)

    backend.initialized = true
    @info "OpenGL backend initialized" width height
    return nothing
end

function shutdown!(backend::OpenGLBackend)
    if backend.shader !== nothing
        destroy_shader_program!(backend.shader)
        backend.shader = nothing
    end
    destroy_all!(backend.gpu_cache)
    destroy_all_textures!(backend.texture_cache)
    if backend.window !== nothing
        destroy_window!(backend.window)
        backend.window = nothing
    end
    backend.initialized = false
    return nothing
end

"""
    bind_material_textures!(sp, material, texture_cache)

Bind texture maps for a material, setting sampler uniforms and has-flags.
"""
function bind_material_textures!(sp::ShaderProgram, material::MaterialComponent, texture_cache::TextureCache)
    texture_unit = Int32(0)

    # Albedo map
    if material.albedo_map !== nothing
        gpu_tex = load_texture(texture_cache, material.albedo_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_AlbedoMap", texture_unit)
        set_uniform!(sp, "u_HasAlbedoMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasAlbedoMap", Int32(0))
    end

    # Normal map
    if material.normal_map !== nothing
        gpu_tex = load_texture(texture_cache, material.normal_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_NormalMap", texture_unit)
        set_uniform!(sp, "u_HasNormalMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasNormalMap", Int32(0))
    end

    # Metallic-roughness map
    if material.metallic_roughness_map !== nothing
        gpu_tex = load_texture(texture_cache, material.metallic_roughness_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_MetallicRoughnessMap", texture_unit)
        set_uniform!(sp, "u_HasMetallicRoughnessMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasMetallicRoughnessMap", Int32(0))
    end

    # AO map
    if material.ao_map !== nothing
        gpu_tex = load_texture(texture_cache, material.ao_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_AOMap", texture_unit)
        set_uniform!(sp, "u_HasAOMap", Int32(1))
        texture_unit += Int32(1)
    else
        set_uniform!(sp, "u_HasAOMap", Int32(0))
    end

    # Emissive map
    if material.emissive_map !== nothing
        gpu_tex = load_texture(texture_cache, material.emissive_map.path)
        glActiveTexture(GL_TEXTURE0 + UInt32(texture_unit))
        glBindTexture(GL_TEXTURE_2D, gpu_tex.id)
        set_uniform!(sp, "u_EmissiveMap", texture_unit)
        set_uniform!(sp, "u_HasEmissiveMap", Int32(1))
    else
        set_uniform!(sp, "u_HasEmissiveMap", Int32(0))
    end

    set_uniform!(sp, "u_EmissiveFactor", material.emissive_factor)

    return nothing
end

function render_frame!(backend::OpenGLBackend, scene::Scene)
    if !backend.initialized
        error("OpenGL backend not initialized")
    end

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

    # Find active camera
    camera_id = find_active_camera()
    if camera_id === nothing
        swap_buffers!(backend.window)
        return nothing
    end

    view = get_view_matrix(camera_id)
    proj = get_projection_matrix(camera_id)
    # Extract camera world position from world transform matrix (column 4)
    cam_world = get_world_transform(camera_id)
    cam_pos = Vec3f(Float32(cam_world[1, 4]), Float32(cam_world[2, 4]), Float32(cam_world[3, 4]))

    sp = backend.shader
    glUseProgram(sp.id)

    # Camera uniforms
    set_uniform!(sp, "u_View", view)
    set_uniform!(sp, "u_Projection", proj)
    set_uniform!(sp, "u_CameraPos", cam_pos)

    # Light uniforms
    upload_lights!(sp)

    # Render all entities with MeshComponent
    iterate_components(MeshComponent) do entity_id, mesh
        # Skip empty meshes
        if isempty(mesh.indices)
            return
        end

        material = get_component(entity_id, MaterialComponent)
        if material === nothing
            material = MaterialComponent()
        end

        # Model matrix (Float64 -> Float32)
        world_transform = get_world_transform(entity_id)
        model = Mat4f(world_transform)

        # Normal matrix = transpose(inverse(upper-left 3x3 of model))
        model3 = SMatrix{3, 3, Float32, 9}(
            model[1,1], model[2,1], model[3,1],
            model[1,2], model[2,2], model[3,2],
            model[1,3], model[2,3], model[3,3]
        )
        normal_matrix = SMatrix{3, 3, Float32, 9}(transpose(inv(model3)))

        # Per-object uniforms
        set_uniform!(sp, "u_Model", model)
        set_uniform!(sp, "u_NormalMatrix", normal_matrix)
        set_uniform!(sp, "u_Albedo", material.color)
        set_uniform!(sp, "u_Metallic", material.metallic)
        set_uniform!(sp, "u_Roughness", material.roughness)
        set_uniform!(sp, "u_AO", 1.0f0)

        # Bind textures
        bind_material_textures!(sp, material, backend.texture_cache)

        # Get or upload GPU mesh
        gpu_mesh = get_or_upload_mesh!(backend.gpu_cache, entity_id, mesh)

        # Draw
        glBindVertexArray(gpu_mesh.vao)
        glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
        glBindVertexArray(GLuint(0))
    end

    swap_buffers!(backend.window)
    return nothing
end
