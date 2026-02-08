# GLFW window management

import GLFW

"""
    Window

Represents a GLFW window with an OpenGL context.
"""
mutable struct Window
    handle::GLFW.Window
    width::Int
    height::Int
    title::String

    Window(;
        width::Int = 1280,
        height::Int = 720,
        title::String = "OpenReality"
    ) = new(GLFW.Window(C_NULL), width, height, title)
end

"""
    create_window!(window::Window)

Create and initialize the GLFW window with an OpenGL 3.3 core profile context.
"""
function create_window!(window::Window)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 3)
    GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE)
    GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, true)
    GLFW.WindowHint(GLFW.RESIZABLE, true)
    GLFW.WindowHint(GLFW.SAMPLES, 4)

    window.handle = GLFW.CreateWindow(window.width, window.height, window.title)
    GLFW.MakeContextCurrent(window.handle)
    GLFW.SwapInterval(1)

    return nothing
end

"""
    destroy_window!(window::Window)

Destroy the GLFW window.
"""
function destroy_window!(window::Window)
    GLFW.DestroyWindow(window.handle)
    window.handle = GLFW.Window(C_NULL)
    return nothing
end

"""
    should_close(window::Window) -> Bool

Check if the window should close.
"""
function should_close(window::Window)
    return GLFW.WindowShouldClose(window.handle)
end

"""
    poll_events!()

Poll GLFW events.
"""
function poll_events!()
    GLFW.PollEvents()
    return nothing
end

"""
    swap_buffers!(window::Window)

Swap the window's front and back buffers.
"""
function swap_buffers!(window::Window)
    GLFW.SwapBuffers(window.handle)
    return nothing
end

"""
    setup_resize_callback!(window::Window, on_resize::Function)

Register a GLFW framebuffer size callback. `on_resize(width, height)` is called
when the window is resized, and the Window struct is updated automatically.
"""
function setup_resize_callback!(window::Window, on_resize::Function)
    GLFW.SetFramebufferSizeCallback(window.handle, (_, w, h) -> begin
        window.width = w
        window.height = h
        on_resize(w, h)
    end)
    return nothing
end

"""
    capture_cursor!(window::Window)

Hide and capture the mouse cursor for FPS-style mouse look.
The cursor becomes invisible and is locked to the window center.
"""
function capture_cursor!(window::Window)
    GLFW.SetInputMode(window.handle, GLFW.CURSOR, GLFW.CURSOR_DISABLED)
    return nothing
end

"""
    release_cursor!(window::Window)

Release the mouse cursor back to normal mode.
"""
function release_cursor!(window::Window)
    GLFW.SetInputMode(window.handle, GLFW.CURSOR, GLFW.CURSOR_NORMAL)
    return nothing
end

"""
    get_time() -> Float64

Get the current time in seconds (high-resolution clock).
Uses Julia's built-in `time()` since GLFW.jl does not wrap `glfwGetTime`.
"""
function get_time()
    return time()
end
