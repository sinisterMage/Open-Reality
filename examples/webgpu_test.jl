#!/usr/bin/env julia
# WebGPU backend test
# Run: julia --project=. examples/webgpu_test.jl
#
# Demonstrates the WebGPU backend via Rust's wgpu FFI:
# - Window creation (GLFW with NO_API)
# - wgpu surface/device initialization
# - Mesh & texture upload to GPU
# - Frame loop with clear color cycling
# - Clean shutdown
#
# Prerequisites:
#   cd openreality-wgpu && cargo build --release

using OpenReality
using OpenReality: initialize!, shutdown!, backend_should_close, backend_poll_events!,
                   backend_get_time, wgpu_render_clear, wgpu_upload_mesh,
                   wgpu_destroy_mesh, wgpu_upload_texture, wgpu_destroy_texture,
                   wgpu_resize, backend_get_input, is_key_pressed
using GLFW

println("═══════════════════════════════════════════")
println("  OpenReality — WebGPU Backend Test")
println("═══════════════════════════════════════════")
println()

# ── 1. Create and initialize the WebGPU backend ──
println("[1/5] Creating WebGPU backend...")
backend = WebGPUBackend()

println("[2/5] Initializing (creating window + wgpu device)...")
initialize!(backend; width=1280, height=720, title="OpenReality — WebGPU Test")
println("  ✓ Backend handle: $(backend.backend_handle)")
println("  ✓ Window created: $(backend.window.handle != C_NULL)")
println("  ✓ CSM handle: $(backend.csm_handle)")

# ── 2. Upload a test mesh (triangle) ──
println("[3/5] Uploading test geometry to GPU...")

# Triangle
tri_positions = Float32[
    -0.5, -0.5, 0.0,
     0.5, -0.5, 0.0,
     0.0,  0.5, 0.0,
]
tri_normals = Float32[
    0.0, 0.0, 1.0,
    0.0, 0.0, 1.0,
    0.0, 0.0, 1.0,
]
tri_uvs = Float32[
    0.0, 0.0,
    1.0, 0.0,
    0.5, 1.0,
]
tri_indices = UInt32[0, 1, 2]

tri_handle = wgpu_upload_mesh(backend.backend_handle, tri_positions, tri_normals, tri_uvs, tri_indices)
println("  ✓ Triangle mesh handle: $tri_handle")

# Cube (24 verts for proper normals)
cube_positions = Float32[
    # Front face
    -0.5, -0.5,  0.5,   0.5, -0.5,  0.5,   0.5,  0.5,  0.5,  -0.5,  0.5,  0.5,
    # Back face
    -0.5, -0.5, -0.5,  -0.5,  0.5, -0.5,   0.5,  0.5, -0.5,   0.5, -0.5, -0.5,
    # Top face
    -0.5,  0.5, -0.5,  -0.5,  0.5,  0.5,   0.5,  0.5,  0.5,   0.5,  0.5, -0.5,
    # Bottom face
    -0.5, -0.5, -0.5,   0.5, -0.5, -0.5,   0.5, -0.5,  0.5,  -0.5, -0.5,  0.5,
    # Right face
     0.5, -0.5, -0.5,   0.5,  0.5, -0.5,   0.5,  0.5,  0.5,   0.5, -0.5,  0.5,
    # Left face
    -0.5, -0.5, -0.5,  -0.5, -0.5,  0.5,  -0.5,  0.5,  0.5,  -0.5,  0.5, -0.5,
]
cube_normals = Float32[
    # Front
    0,0,1,  0,0,1,  0,0,1,  0,0,1,
    # Back
    0,0,-1, 0,0,-1, 0,0,-1, 0,0,-1,
    # Top
    0,1,0,  0,1,0,  0,1,0,  0,1,0,
    # Bottom
    0,-1,0, 0,-1,0, 0,-1,0, 0,-1,0,
    # Right
    1,0,0,  1,0,0,  1,0,0,  1,0,0,
    # Left
    -1,0,0, -1,0,0, -1,0,0, -1,0,0,
]
cube_uvs = Float32[
    0,0, 1,0, 1,1, 0,1,
    0,0, 1,0, 1,1, 0,1,
    0,0, 1,0, 1,1, 0,1,
    0,0, 1,0, 1,1, 0,1,
    0,0, 1,0, 1,1, 0,1,
    0,0, 1,0, 1,1, 0,1,
]
cube_indices = UInt32[
    0,1,2,  0,2,3,      # front
    4,5,6,  4,6,7,      # back
    8,9,10, 8,10,11,    # top
    12,13,14, 12,14,15, # bottom
    16,17,18, 16,18,19, # right
    20,21,22, 20,22,23, # left
]

cube_handle = wgpu_upload_mesh(backend.backend_handle, cube_positions, cube_normals, cube_uvs, cube_indices)
println("  ✓ Cube mesh handle: $cube_handle")

# ── 3. Upload a test texture (4x4 checkerboard) ──
println("[4/5] Uploading test texture to GPU...")

tex_width, tex_height = 4, 4
tex_pixels = UInt8[]
for y in 0:tex_height-1, x in 0:tex_width-1
    checker = ((x + y) % 2 == 0)
    push!(tex_pixels, checker ? 0xFF : 0x40)  # R
    push!(tex_pixels, checker ? 0xFF : 0x40)  # G
    push!(tex_pixels, checker ? 0xFF : 0x40)  # B
    push!(tex_pixels, 0xFF)                    # A
end

tex_handle = wgpu_upload_texture(backend.backend_handle, tex_pixels, tex_width, tex_height, 4)
println("  ✓ Texture handle: $tex_handle")

# ── 4. Run the render loop ──
println("[5/5] Entering render loop (ESC or close window to exit)...")
println()
println("  The window should display a smoothly cycling gradient.")
println("  This verifies wgpu surface presentation is working.")
println()

total_time = let
    frame_count = 0
    start_time = backend_get_time(backend)
    last_fps_time = start_time

    try
        while !backend_should_close(backend)
            backend_poll_events!(backend)

            now = backend_get_time(backend)
            t = now - start_time

            # Cycle through colors over time
            r = 0.5 * (1.0 + sin(t * 0.7))
            g = 0.5 * (1.0 + sin(t * 0.7 + 2.094))  # +120°
            b = 0.5 * (1.0 + sin(t * 0.7 + 4.189))  # +240°

            # Darken to a comfortable range
            r = r * 0.3 + 0.02
            g = g * 0.3 + 0.02
            b = b * 0.3 + 0.02

            result = wgpu_render_clear(backend.backend_handle, r, g, b)
            if result != 0
                @warn "render_clear failed" result
            end

            frame_count += 1

            # Print FPS every 2 seconds
            if now - last_fps_time >= 2.0
                fps = frame_count / (now - last_fps_time)
                print("\r  FPS: $(round(fps, digits=1))   frame: $frame_count   time: $(round(t, digits=1))s     ")
                frame_count = 0
                last_fps_time = now
            end

            # Check ESC
            input = backend_get_input(backend)
            if is_key_pressed(input, Int(GLFW.KEY_ESCAPE))
                break
            end
        end
    catch e
        if !(e isa InterruptException)
            rethrow()
        end
    end

    println()
    backend_get_time(backend) - start_time
end
println()

# ── 5. Cleanup ──
println("Cleaning up GPU resources...")
wgpu_destroy_mesh(backend.backend_handle, tri_handle)
wgpu_destroy_mesh(backend.backend_handle, cube_handle)
wgpu_destroy_texture(backend.backend_handle, tex_handle)
println("  ✓ Resources destroyed")

println("Shutting down backend...")
shutdown!(backend)
println("  ✓ Backend shut down")

println()
println("═══════════════════════════════════════════")
println("  WebGPU test completed successfully!")
println("  Ran for $(round(total_time, digits=1))s")
println("═══════════════════════════════════════════")
