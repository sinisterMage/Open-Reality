# Screen-Space Reflections (SSR)
# Ray-march through G-buffer depth to find reflection hits

"""
    SSRPass

Screen-space reflections pass for deferred rendering.
Ray-marches through depth buffer to find reflection hits.
"""
mutable struct SSRPass
    ssr_fbo::GLuint                    # FBO for SSR output
    ssr_texture::GLuint                # RGBA: RGB=reflection color, A=confidence
    ssr_shader::Union{ShaderProgram, Nothing}
    quad_vao::GLuint
    quad_vbo::GLuint
    width::Int
    height::Int

    # SSR parameters
    max_steps::Int                     # Ray-march steps (default: 64)
    max_distance::Float32              # Max ray distance in view space (default: 50m)
    thickness::Float32                 # Depth threshold for hit detection (default: 0.5)
    stride::Float32                    # Step size multiplier (default: 1.0)
    max_roughness::Float32             # Skip SSR for roughness > this (default: 0.5)

    SSRPass(; width::Int=1280, height::Int=720,
            max_steps::Int=64,
            max_distance::Float32=50.0f0,
            thickness::Float32=0.5f0,
            stride::Float32=1.0f0,
            max_roughness::Float32=0.5f0) =
        new(GLuint(0), GLuint(0), nothing, GLuint(0), GLuint(0),
            width, height, max_steps, max_distance, thickness, stride, max_roughness)
end

# =============================================================================
# SSR Shaders
# =============================================================================

const SSR_VERTEX_SHADER = """
#version 330 core
layout (location = 0) in vec2 a_Position;
layout (location = 1) in vec2 a_TexCoord;

out vec2 v_TexCoord;

void main()
{
    v_TexCoord = a_TexCoord;
    gl_Position = vec4(a_Position, 0.0, 1.0);
}
"""

const SSR_FRAGMENT_SHADER = """
#version 330 core

in vec2 v_TexCoord;
out vec4 FragColor;

// G-Buffer inputs
uniform sampler2D gAlbedoMetallic;
uniform sampler2D gNormalRoughness;
uniform sampler2D gDepth;

// Scene color (deferred lighting result)
uniform sampler2D u_SceneColor;

// Camera matrices
uniform mat4 u_View;
uniform mat4 u_Projection;
uniform mat4 u_InvView;
uniform mat4 u_InvProjection;
uniform vec3 u_CameraPos;

// SSR parameters
uniform int u_MaxSteps;
uniform float u_MaxDistance;
uniform float u_Thickness;
uniform float u_Stride;
uniform float u_MaxRoughness;

// Reconstruct view-space position from depth
vec3 reconstructViewPos(vec2 texCoord, float depth)
{
    vec4 clipPos = vec4(texCoord * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 viewPos = u_InvProjection * clipPos;
    return viewPos.xyz / viewPos.w;
}

// Project view-space position to screen space
vec3 projectViewPos(vec3 viewPos)
{
    vec4 clipPos = u_Projection * vec4(viewPos, 1.0);
    clipPos.xyz /= clipPos.w;
    clipPos.xyz = clipPos.xyz * 0.5 + 0.5;
    return clipPos.xyz;
}

// Ray-march in screen space
bool rayMarch(vec3 rayOrigin, vec3 rayDir, out vec2 hitUV, out float hitConfidence)
{
    vec3 rayPos = rayOrigin;
    vec3 rayStep = rayDir * u_Stride;

    hitConfidence = 0.0;

    for (int i = 0; i < u_MaxSteps; ++i)
    {
        // Advance ray
        rayPos += rayStep;

        // Check if ray left screen
        vec3 screenPos = projectViewPos(rayPos);
        if (screenPos.x < 0.0 || screenPos.x > 1.0 ||
            screenPos.y < 0.0 || screenPos.y > 1.0 ||
            screenPos.z < 0.0 || screenPos.z > 1.0)
        {
            return false;
        }

        // Sample depth at current position
        float sampledDepth = texture(gDepth, screenPos.xy).r;
        vec3 sampledViewPos = reconstructViewPos(screenPos.xy, sampledDepth);

        // Check if ray intersects geometry
        float depth = rayPos.z;
        float sampledZ = sampledViewPos.z;

        if (depth < sampledZ && depth > sampledZ - u_Thickness)
        {
            // Hit found!
            hitUV = screenPos.xy;

            // Calculate confidence based on distance from edge
            vec2 edgeDist = vec2(
                min(screenPos.x, 1.0 - screenPos.x),
                min(screenPos.y, 1.0 - screenPos.y)
            );
            float edgeFade = min(edgeDist.x, edgeDist.y);
            edgeFade = smoothstep(0.0, 0.2, edgeFade);

            // Fade based on distance traveled
            float distanceFade = 1.0 - (float(i) / float(u_MaxSteps));

            hitConfidence = edgeFade * distanceFade;
            return true;
        }
    }

    return false;
}

void main()
{
    // Sample G-Buffer
    float depth = texture(gDepth, v_TexCoord).r;
    vec4 normalRoughness = texture(gNormalRoughness, v_TexCoord);
    vec3 normal = normalize(normalRoughness.rgb * 2.0 - 1.0);
    float roughness = normalRoughness.a;

    vec4 albedoMetallic = texture(gAlbedoMetallic, v_TexCoord);
    float metallic = albedoMetallic.a;

    // Early exit: skip SSR for high roughness or non-metallic surfaces
    if (roughness > u_MaxRoughness || metallic < 0.1)
    {
        FragColor = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    // Early exit: skip background (depth = 1.0)
    if (depth >= 0.9999)
    {
        FragColor = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    // Reconstruct view-space position
    vec3 viewPos = reconstructViewPos(v_TexCoord, depth);

    // Compute reflection direction in view space
    vec3 viewDir = normalize(viewPos);
    vec3 viewNormal = normalize((u_View * vec4(normal, 0.0)).xyz);
    vec3 reflectDir = reflect(viewDir, viewNormal);

    // Ray-march to find reflection hit
    vec2 hitUV;
    float confidence;
    if (rayMarch(viewPos, reflectDir, hitUV, confidence))
    {
        // Sample scene color at hit point
        vec3 reflectionColor = texture(u_SceneColor, hitUV).rgb;

        // Fade based on roughness (smoother = stronger reflection)
        float roughnessFade = 1.0 - (roughness / u_MaxRoughness);
        confidence *= roughnessFade;

        // Output reflection with confidence
        FragColor = vec4(reflectionColor, confidence);
    }
    else
    {
        // No hit
        FragColor = vec4(0.0, 0.0, 0.0, 0.0);
    }
}
"""

# =============================================================================
# SSR Pass Creation and Management
# =============================================================================

"""
    create_ssr_pass!(ssr::SSRPass, width::Int, height::Int)

Create framebuffer and shader for SSR pass.
"""
function create_ssr_pass!(ssr::SSRPass, width::Int, height::Int)
    ssr.width = width
    ssr.height = height

    # Create FBO
    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    ssr.ssr_fbo = fbo_ref[]

    # Create SSR texture (RGBA16F)
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    ssr.ssr_texture = tex_ref[]

    glBindTexture(GL_TEXTURE_2D, ssr.ssr_texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, width, height, 0, GL_RGBA, GL_FLOAT, C_NULL)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

    # Attach to FBO
    glBindFramebuffer(GL_FRAMEBUFFER, ssr.ssr_fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, ssr.ssr_texture, 0)

    # Verify completeness
    status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
    if status != GL_FRAMEBUFFER_COMPLETE
        error("SSR framebuffer incomplete! Status: $status")
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    # Create fullscreen quad
    vertices = Float32[
        # positions   # texcoords
        -1.0,  1.0,   0.0, 1.0,
        -1.0, -1.0,   0.0, 0.0,
         1.0, -1.0,   1.0, 0.0,
        -1.0,  1.0,   0.0, 1.0,
         1.0, -1.0,   1.0, 0.0,
         1.0,  1.0,   1.0, 1.0
    ]

    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    ssr.quad_vao = vao_ref[]

    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    ssr.quad_vbo = vbo_ref[]

    glBindVertexArray(ssr.quad_vao)
    glBindBuffer(GL_ARRAY_BUFFER, ssr.quad_vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW)

    # Position attribute
    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(0))

    # Texcoord attribute
    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(2 * sizeof(Float32)))

    glBindVertexArray(GLuint(0))

    # Compile shader
    ssr.ssr_shader = create_shader_program(SSR_VERTEX_SHADER, SSR_FRAGMENT_SHADER)

    @info "Created SSR pass" width=width height=height max_steps=ssr.max_steps

    return nothing
end

"""
    render_ssr!(ssr::SSRPass, gbuffer::GBuffer, scene_color_texture::GLuint,
                view::Mat4f, proj::Mat4f, cam_pos::Vec3f)

Execute SSR ray-marching pass.
"""
function render_ssr!(ssr::SSRPass, gbuffer::GBuffer, scene_color_texture::GLuint,
                     view::Mat4f, proj::Mat4f, cam_pos::Vec3f)
    # Bind SSR framebuffer
    glBindFramebuffer(GL_FRAMEBUFFER, ssr.ssr_fbo)
    glViewport(0, 0, ssr.width, ssr.height)
    glClear(GL_COLOR_BUFFER_BIT)

    # Disable depth test for fullscreen quad
    glDisable(GL_DEPTH_TEST)

    # Use SSR shader
    shader = ssr.ssr_shader
    glUseProgram(shader.id)

    # Bind G-Buffer textures
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, gbuffer.albedo_metallic_texture)
    set_uniform!(shader, "gAlbedoMetallic", Int32(0))

    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, gbuffer.normal_roughness_texture)
    set_uniform!(shader, "gNormalRoughness", Int32(1))

    glActiveTexture(GL_TEXTURE2)
    glBindTexture(GL_TEXTURE_2D, gbuffer.depth_texture)
    set_uniform!(shader, "gDepth", Int32(2))

    # Bind scene color
    glActiveTexture(GL_TEXTURE3)
    glBindTexture(GL_TEXTURE_2D, scene_color_texture)
    set_uniform!(shader, "u_SceneColor", Int32(3))

    # Set camera uniforms
    set_uniform!(shader, "u_View", view)
    set_uniform!(shader, "u_Projection", proj)

    inv_view = Mat4f(inv(view))
    inv_proj = Mat4f(inv(proj))
    set_uniform!(shader, "u_InvView", inv_view)
    set_uniform!(shader, "u_InvProjection", inv_proj)
    set_uniform!(shader, "u_CameraPos", cam_pos)

    # Set SSR parameters
    set_uniform!(shader, "u_MaxSteps", Int32(ssr.max_steps))
    set_uniform!(shader, "u_MaxDistance", ssr.max_distance)
    set_uniform!(shader, "u_Thickness", ssr.thickness)
    set_uniform!(shader, "u_Stride", ssr.stride)
    set_uniform!(shader, "u_MaxRoughness", ssr.max_roughness)

    # Draw fullscreen quad
    glBindVertexArray(ssr.quad_vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(GLuint(0))

    # Re-enable depth test
    glEnable(GL_DEPTH_TEST)

    # Unbind framebuffer
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    return nothing
end

"""
    composite_ssr!(target_fbo::GLuint, scene_color::GLuint, ssr_texture::GLuint,
                   width::Int, height::Int, quad_vao::GLuint)

Composite SSR over scene color using additive blending.
"""
function composite_ssr!(target_fbo::GLuint, scene_color::GLuint, ssr_texture::GLuint,
                        width::Int, height::Int, quad_vao::GLuint)
    # Simple composite shader
    composite_shader = create_shader_program(
        SSR_VERTEX_SHADER,
        """
        #version 330 core
        in vec2 v_TexCoord;
        out vec4 FragColor;

        uniform sampler2D u_SceneColor;
        uniform sampler2D u_SSR;

        void main()
        {
            vec3 sceneColor = texture(u_SceneColor, v_TexCoord).rgb;
            vec4 ssr = texture(u_SSR, v_TexCoord);

            // Blend reflection based on confidence
            vec3 finalColor = mix(sceneColor, ssr.rgb, ssr.a);

            FragColor = vec4(finalColor, 1.0);
        }
        """
    )

    glBindFramebuffer(GL_FRAMEBUFFER, target_fbo)
    glViewport(0, 0, width, height)

    glDisable(GL_DEPTH_TEST)

    glUseProgram(composite_shader.id)

    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, scene_color)
    set_uniform!(composite_shader, "u_SceneColor", Int32(0))

    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, ssr_texture)
    set_uniform!(composite_shader, "u_SSR", Int32(1))

    glBindVertexArray(quad_vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(GLuint(0))

    glEnable(GL_DEPTH_TEST)

    glDeleteProgram(composite_shader.id)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

"""
    destroy_ssr_pass!(ssr::SSRPass)

Release GPU resources for SSR pass.
"""
function destroy_ssr_pass!(ssr::SSRPass)
    if ssr.ssr_fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(ssr.ssr_fbo))
        ssr.ssr_fbo = GLuint(0)
    end
    if ssr.ssr_texture != GLuint(0)
        glDeleteTextures(1, Ref(ssr.ssr_texture))
        ssr.ssr_texture = GLuint(0)
    end
    if ssr.quad_vao != GLuint(0)
        glDeleteVertexArrays(1, Ref(ssr.quad_vao))
        ssr.quad_vao = GLuint(0)
    end
    if ssr.quad_vbo != GLuint(0)
        glDeleteBuffers(1, Ref(ssr.quad_vbo))
        ssr.quad_vbo = GLuint(0)
    end
    if ssr.ssr_shader !== nothing
        glDeleteProgram(ssr.ssr_shader.id)
        ssr.ssr_shader = nothing
    end
    return nothing
end

"""
    resize_ssr_pass!(ssr::SSRPass, width::Int, height::Int)

Destroy and recreate SSR pass at new dimensions.
"""
function resize_ssr_pass!(ssr::SSRPass, width::Int, height::Int)
    destroy_ssr_pass!(ssr)
    create_ssr_pass!(ssr, width, height)
end
