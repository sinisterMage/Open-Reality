# Screen-Space Ambient Occlusion (SSAO)
# Alchemy SSAO with hemisphere sampling

"""
    SSAOPass

Screen-space ambient occlusion pass for deferred rendering.
Uses hemisphere sampling to compute occlusion.
"""
mutable struct SSAOPass
    ssao_fbo::GLuint                      # FBO for SSAO output
    ssao_texture::GLuint                  # R8: occlusion factor
    blur_fbo::GLuint                      # FBO for blur pass
    blur_texture::GLuint                  # Blurred occlusion
    noise_texture::GLuint                 # 4×4 random rotation noise
    ssao_shader::Union{ShaderProgram, Nothing}
    blur_shader::Union{ShaderProgram, Nothing}
    quad_vao::GLuint
    quad_vbo::GLuint
    width::Int
    height::Int

    # SSAO parameters
    kernel::Vector{Vec3f}                 # Hemisphere sample kernel
    kernel_size::Int                      # Number of samples (default: 64)
    radius::Float32                       # Sample radius in view space (default: 0.5)
    bias::Float32                         # Depth bias (default: 0.025)
    power::Float32                        # AO power/intensity (default: 1.0)

    SSAOPass(; width::Int=1280, height::Int=720,
             kernel_size::Int=64,
             radius::Float32=0.5f0,
             bias::Float32=0.025f0,
             power::Float32=1.0f0) =
        new(GLuint(0), GLuint(0), GLuint(0), GLuint(0), GLuint(0),
            nothing, nothing, GLuint(0), GLuint(0),
            width, height, Vec3f[], kernel_size, radius, bias, power)
end

# =============================================================================
# SSAO Shaders
# =============================================================================

const SSAO_VERTEX_SHADER = """
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

const SSAO_FRAGMENT_SHADER = """
#version 330 core

in vec2 v_TexCoord;
out float FragColor;

// G-Buffer inputs
uniform sampler2D gNormalRoughness;
uniform sampler2D gDepth;

// Noise texture (4×4 tiling)
uniform sampler2D u_NoiseTexture;

// Sample kernel
uniform vec3 u_Samples[64];
uniform int u_KernelSize;

// Camera matrices
uniform mat4 u_Projection;
uniform mat4 u_InvProjection;

// SSAO parameters
uniform float u_Radius;
uniform float u_Bias;
uniform vec2 u_NoiseScale;  // screen size / noise size

// Reconstruct view-space position from depth
vec3 reconstructViewPos(vec2 texCoord, float depth)
{
    vec4 clipPos = vec4(texCoord * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 viewPos = u_InvProjection * clipPos;
    return viewPos.xyz / viewPos.w;
}

void main()
{
    // Sample G-Buffer
    float depth = texture(gDepth, v_TexCoord).r;
    vec3 normal = normalize(texture(gNormalRoughness, v_TexCoord).rgb * 2.0 - 1.0);

    // Early exit: skip background
    if (depth >= 0.9999)
    {
        FragColor = 1.0;  // No occlusion for sky
        return;
    }

    // Reconstruct view-space position
    vec3 fragPos = reconstructViewPos(v_TexCoord, depth);

    // Sample random rotation from noise texture (tiled)
    vec3 randomVec = texture(u_NoiseTexture, v_TexCoord * u_NoiseScale).xyz;

    // Create TBN matrix to orient samples around normal
    vec3 tangent = normalize(randomVec - normal * dot(randomVec, normal));
    vec3 bitangent = cross(normal, tangent);
    mat3 TBN = mat3(tangent, bitangent, normal);

    // Accumulate occlusion
    float occlusion = 0.0;

    for (int i = 0; i < u_KernelSize; ++i)
    {
        // Get sample position in view space
        vec3 samplePos = TBN * u_Samples[i];  // Rotate sample to surface orientation
        samplePos = fragPos + samplePos * u_Radius;

        // Project sample to screen space
        vec4 offset = u_Projection * vec4(samplePos, 1.0);
        offset.xyz /= offset.w;
        offset.xyz = offset.xyz * 0.5 + 0.5;

        // Sample depth at offset position
        float sampleDepth = texture(gDepth, offset.xy).r;
        vec3 sampleFragPos = reconstructViewPos(offset.xy, sampleDepth);

        // Range check & accumulate
        float rangeCheck = smoothstep(0.0, 1.0, u_Radius / abs(fragPos.z - sampleFragPos.z));
        occlusion += (sampleFragPos.z >= samplePos.z + u_Bias ? 1.0 : 0.0) * rangeCheck;
    }

    // Normalize and invert (1.0 = no occlusion, 0.0 = full occlusion)
    occlusion = 1.0 - (occlusion / float(u_KernelSize));

    FragColor = occlusion;
}
"""

const SSAO_BLUR_FRAGMENT_SHADER = """
#version 330 core

in vec2 v_TexCoord;
out float FragColor;

uniform sampler2D u_SSAOTexture;

void main()
{
    vec2 texelSize = 1.0 / vec2(textureSize(u_SSAOTexture, 0));
    float result = 0.0;

    // Simple 4×4 box blur
    for (int x = -2; x < 2; ++x)
    {
        for (int y = -2; y < 2; ++y)
        {
            vec2 offset = vec2(float(x), float(y)) * texelSize;
            result += texture(u_SSAOTexture, v_TexCoord + offset).r;
        }
    }

    FragColor = result / 16.0;
}
"""

# =============================================================================
# Helper Functions
# =============================================================================

"""
    generate_ssao_kernel(kernel_size::Int) -> Vector{Vec3f}

Generate hemisphere sample kernel with non-uniform distribution.
Samples are more concentrated near the origin for better AO.
"""
function generate_ssao_kernel(kernel_size::Int)
    kernel = Vec3f[]

    for i in 1:kernel_size
        # Random sample in hemisphere
        sample = Vec3f(
            rand() * 2.0f0 - 1.0f0,
            rand() * 2.0f0 - 1.0f0,
            rand()  # Positive Z (hemisphere)
        )
        sample = normalize(sample)

        # Scale samples so more are closer to origin
        scale = Float32(i) / Float32(kernel_size)
        scale = lerp(0.1f0, 1.0f0, scale * scale)  # Quadratic falloff
        sample *= scale

        push!(kernel, sample)
    end

    return kernel
end

"""
    lerp(a, b, t)

Linear interpolation.
"""
lerp(a::Float32, b::Float32, t::Float32) = a + (b - a) * t

"""
    generate_ssao_noise_texture() -> GLuint

Generate 4×4 noise texture with random rotation vectors.
"""
function generate_ssao_noise_texture()
    noise_size = 4
    noise_data = Float32[]

    for i in 1:(noise_size * noise_size)
        # Random rotation around Z axis
        noise = Vec3f(
            rand() * 2.0f0 - 1.0f0,
            rand() * 2.0f0 - 1.0f0,
            0.0f0  # Rotate around Z only
        )
        noise = normalize(noise)

        push!(noise_data, noise[1], noise[2], noise[3])
    end

    # Create texture
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    texture = tex_ref[]

    glBindTexture(GL_TEXTURE_2D, texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB16F, noise_size, noise_size, 0, GL_RGB, GL_FLOAT, noise_data)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT)

    glBindTexture(GL_TEXTURE_2D, GLuint(0))

    return texture
end

# =============================================================================
# SSAO Pass Creation and Management
# =============================================================================

"""
    create_ssao_pass!(ssao::SSAOPass, width::Int, height::Int)

Create framebuffers, textures, and shaders for SSAO pass.
"""
function create_ssao_pass!(ssao::SSAOPass, width::Int, height::Int)
    ssao.width = width
    ssao.height = height

    # Generate sample kernel
    ssao.kernel = generate_ssao_kernel(ssao.kernel_size)

    # Generate noise texture
    ssao.noise_texture = generate_ssao_noise_texture()

    # Create SSAO FBO
    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    ssao.ssao_fbo = fbo_ref[]

    # Create SSAO texture (R8 - only occlusion factor)
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    ssao.ssao_texture = tex_ref[]

    glBindTexture(GL_TEXTURE_2D, ssao.ssao_texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, width, height, 0, GL_RED, GL_UNSIGNED_BYTE, C_NULL)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)

    glBindFramebuffer(GL_FRAMEBUFFER, ssao.ssao_fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, ssao.ssao_texture, 0)

    status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
    if status != GL_FRAMEBUFFER_COMPLETE
        error("SSAO framebuffer incomplete! Status: $status")
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    # Create blur FBO
    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    ssao.blur_fbo = fbo_ref[]

    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    ssao.blur_texture = tex_ref[]

    glBindTexture(GL_TEXTURE_2D, ssao.blur_texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, width, height, 0, GL_RED, GL_UNSIGNED_BYTE, C_NULL)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)

    glBindFramebuffer(GL_FRAMEBUFFER, ssao.blur_fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, ssao.blur_texture, 0)

    status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
    if status != GL_FRAMEBUFFER_COMPLETE
        error("SSAO blur framebuffer incomplete! Status: $status")
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
    ssao.quad_vao = vao_ref[]

    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    ssao.quad_vbo = vbo_ref[]

    glBindVertexArray(ssao.quad_vao)
    glBindBuffer(GL_ARRAY_BUFFER, ssao.quad_vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW)

    glEnableVertexAttribArray(0)
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(0))

    glEnableVertexAttribArray(1)
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(2 * sizeof(Float32)))

    glBindVertexArray(GLuint(0))

    # Compile shaders
    ssao.ssao_shader = create_shader_program(SSAO_VERTEX_SHADER, SSAO_FRAGMENT_SHADER)
    ssao.blur_shader = create_shader_program(SSAO_VERTEX_SHADER, SSAO_BLUR_FRAGMENT_SHADER)

    @info "Created SSAO pass" width=width height=height kernel_size=ssao.kernel_size

    return nothing
end

"""
    render_ssao!(ssao::SSAOPass, gbuffer::GBuffer, proj::Mat4f)

Execute SSAO pass: sample hemisphere and blur.
Returns blurred SSAO texture ID.
"""
function render_ssao!(ssao::SSAOPass, gbuffer::GBuffer, proj::Mat4f)
    # ---- SSAO sampling pass ----
    glBindFramebuffer(GL_FRAMEBUFFER, ssao.ssao_fbo)
    glViewport(0, 0, ssao.width, ssao.height)
    glClear(GL_COLOR_BUFFER_BIT)

    glDisable(GL_DEPTH_TEST)

    shader = ssao.ssao_shader
    glUseProgram(shader.id)

    # Bind G-Buffer
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, gbuffer.normal_roughness_texture)
    set_uniform!(shader, "gNormalRoughness", Int32(0))

    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, gbuffer.depth_texture)
    set_uniform!(shader, "gDepth", Int32(1))

    glActiveTexture(GL_TEXTURE2)
    glBindTexture(GL_TEXTURE_2D, ssao.noise_texture)
    set_uniform!(shader, "u_NoiseTexture", Int32(2))

    # Set uniforms
    set_uniform!(shader, "u_Projection", proj)
    inv_proj = Mat4f(inv(proj))
    set_uniform!(shader, "u_InvProjection", inv_proj)

    set_uniform!(shader, "u_Radius", ssao.radius)
    set_uniform!(shader, "u_Bias", ssao.bias)
    set_uniform!(shader, "u_KernelSize", Int32(ssao.kernel_size))
    set_uniform!(shader, "u_NoiseScale", Vec2f(Float32(ssao.width) / 4.0f0, Float32(ssao.height) / 4.0f0))

    # Upload sample kernel
    for i in 1:ssao.kernel_size
        set_uniform!(shader, "u_Samples[$(i-1)]", ssao.kernel[i])
    end

    # Draw quad
    glBindVertexArray(ssao.quad_vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(GLuint(0))

    # ---- Blur pass ----
    glBindFramebuffer(GL_FRAMEBUFFER, ssao.blur_fbo)
    glClear(GL_COLOR_BUFFER_BIT)

    blur_shader = ssao.blur_shader
    glUseProgram(blur_shader.id)

    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, ssao.ssao_texture)
    set_uniform!(blur_shader, "u_SSAOTexture", Int32(0))

    glBindVertexArray(ssao.quad_vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(GLuint(0))

    glEnable(GL_DEPTH_TEST)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    return ssao.blur_texture
end

"""
    apply_ssao_to_lighting!(target_fbo::GLuint, scene_color::GLuint, ssao_texture::GLuint,
                           width::Int, height::Int, quad_vao::GLuint)

Apply SSAO occlusion to the lighting result by multiplying.
"""
function apply_ssao_to_lighting!(target_fbo::GLuint, scene_color::GLuint, ssao_texture::GLuint,
                                width::Int, height::Int, quad_vao::GLuint)
    # Create simple multiply shader
    multiply_shader = create_shader_program(
        SSAO_VERTEX_SHADER,
        """
        #version 330 core
        in vec2 v_TexCoord;
        out vec4 FragColor;

        uniform sampler2D u_SceneColor;
        uniform sampler2D u_SSAO;

        void main()
        {
            vec3 sceneColor = texture(u_SceneColor, v_TexCoord).rgb;
            float occlusion = texture(u_SSAO, v_TexCoord).r;

            // Darken scene based on occlusion
            vec3 finalColor = sceneColor * occlusion;

            FragColor = vec4(finalColor, 1.0);
        }
        """
    )

    glBindFramebuffer(GL_FRAMEBUFFER, target_fbo)
    glViewport(0, 0, width, height)

    glDisable(GL_DEPTH_TEST)

    glUseProgram(multiply_shader.id)

    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, scene_color)
    set_uniform!(multiply_shader, "u_SceneColor", Int32(0))

    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, ssao_texture)
    set_uniform!(multiply_shader, "u_SSAO", Int32(1))

    glBindVertexArray(quad_vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(GLuint(0))

    glEnable(GL_DEPTH_TEST)

    glDeleteProgram(multiply_shader.id)

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
end

"""
    destroy_ssao_pass!(ssao::SSAOPass)

Release GPU resources for SSAO pass.
"""
function destroy_ssao_pass!(ssao::SSAOPass)
    if ssao.ssao_fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(ssao.ssao_fbo))
        ssao.ssao_fbo = GLuint(0)
    end
    if ssao.ssao_texture != GLuint(0)
        glDeleteTextures(1, Ref(ssao.ssao_texture))
        ssao.ssao_texture = GLuint(0)
    end
    if ssao.blur_fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(ssao.blur_fbo))
        ssao.blur_fbo = GLuint(0)
    end
    if ssao.blur_texture != GLuint(0)
        glDeleteTextures(1, Ref(ssao.blur_texture))
        ssao.blur_texture = GLuint(0)
    end
    if ssao.noise_texture != GLuint(0)
        glDeleteTextures(1, Ref(ssao.noise_texture))
        ssao.noise_texture = GLuint(0)
    end
    if ssao.quad_vao != GLuint(0)
        glDeleteVertexArrays(1, Ref(ssao.quad_vao))
        ssao.quad_vao = GLuint(0)
    end
    if ssao.quad_vbo != GLuint(0)
        glDeleteBuffers(1, Ref(ssao.quad_vbo))
        ssao.quad_vbo = GLuint(0)
    end
    if ssao.ssao_shader !== nothing
        glDeleteProgram(ssao.ssao_shader.id)
        ssao.ssao_shader = nothing
    end
    if ssao.blur_shader !== nothing
        glDeleteProgram(ssao.blur_shader.id)
        ssao.blur_shader = nothing
    end
    return nothing
end

"""
    resize_ssao_pass!(ssao::SSAOPass, width::Int, height::Int)

Destroy and recreate SSAO pass at new dimensions.
"""
function resize_ssao_pass!(ssao::SSAOPass, width::Int, height::Int)
    destroy_ssao_pass!(ssao)
    create_ssao_pass!(ssao, width, height)
end
