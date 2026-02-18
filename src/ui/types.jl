# UI system types

"""
    UIDrawCommand

A batched draw command for the UI renderer.
Each command corresponds to a group of vertices sharing the same texture.
"""
struct UIDrawCommand
    vertex_offset::Int    # Start index in vertex array (in floats)
    vertex_count::Int     # Number of vertices (each vertex = 8 floats)
    texture_id::UInt32    # 0 = solid color, >0 = texture/font atlas
    is_font::Bool         # True if texture is a font atlas (single-channel)
    clip_rect::Union{Nothing, NTuple{4, Int32}}  # Scissor rect (x, y, w, h) or nothing
end

UIDrawCommand(vertex_offset, vertex_count, texture_id, is_font) =
    UIDrawCommand(vertex_offset, vertex_count, texture_id, is_font, nothing)

"""
    GlyphInfo

Metrics for a single glyph in a font atlas.
"""
struct GlyphInfo
    advance_x::Float32    # Horizontal advance in pixels
    bearing_x::Float32    # Left bearing
    bearing_y::Float32    # Top bearing (above baseline)
    width::Float32        # Glyph bitmap width
    height::Float32       # Glyph bitmap height
    uv_x::Float32         # Atlas UV left
    uv_y::Float32         # Atlas UV top
    uv_w::Float32         # Atlas UV width
    uv_h::Float32         # Atlas UV height
end

"""
    FontAtlas

A cached font atlas containing rasterized glyphs and their metrics.
"""
mutable struct FontAtlas
    texture_id::UInt32
    atlas_width::Int
    atlas_height::Int
    glyphs::Dict{Char, GlyphInfo}
    font_size::Float32
    line_height::Float32

    FontAtlas() = new(UInt32(0), 0, 0, Dict{Char, GlyphInfo}(), 0.0f0, 0.0f0)
end

"""
    LayoutContainer

Describes a layout region that auto-positions child widgets in a row or column.
Pushed/popped via layout functions; children advance the cursor automatically.
"""
mutable struct LayoutContainer
    origin_x::Float32
    origin_y::Float32
    cursor_x::Float32
    cursor_y::Float32
    direction::Symbol           # :row or :column
    padding::Float32
    spacing::Float32
    row_height::Float32         # max child height seen (:row mode)
    col_width::Float32          # max child width seen (:column mode)
    anchor::Union{Symbol, Nothing}  # :top_left, :top_right, :bottom_left, :bottom_right, :center, or nothing
    margin_x::Float32
    margin_y::Float32
end

"""
    UIContext

Frame-scoped state for immediate-mode UI rendering.
Rebuilt each frame — users call widget functions to add geometry.
"""
mutable struct UIContext
    # Batched geometry (position.xy + uv.xy + color.rgba = 8 floats per vertex)
    vertices::Vector{Float32}
    draw_commands::Vector{UIDrawCommand}

    # Font atlas
    font_atlas::FontAtlas
    font_path::String

    # Input state (synced from backend each frame)
    mouse_x::Float64
    mouse_y::Float64
    mouse_clicked::Bool   # True on the frame the button was pressed
    mouse_down::Bool      # True while button is held

    # Screen dimensions
    width::Int
    height::Int

    # Image texture cache
    image_textures::Dict{String, UInt32}

    # Layout system
    layout_stack::Vector{LayoutContainer}
    clip_stack::Vector{NTuple{4, Int32}}

    # Keyboard / focus state
    focused_widget_id::Union{String, Nothing}
    has_keyboard_focus::Bool
    typed_chars::Vector{Char}
    keys_pressed::Set{Int}
    prev_keys_pressed::Set{Int}

    # Scroll input
    scroll_x::Float64
    scroll_y::Float64

    # Overlay layer
    in_overlay::Bool
    overlay_vertices::Vector{Float32}
    overlay_draw_commands::Vector{UIDrawCommand}

    # Persistent per-widget state
    scroll_offsets::Dict{String, Float32}
    drag_offsets::Dict{String, Float32}

    UIContext() = new(
        Float32[], UIDrawCommand[],
        FontAtlas(), "",
        0.0, 0.0, false, false,
        1280, 720,
        Dict{String, UInt32}(),
        LayoutContainer[],
        NTuple{4,Int32}[],
        nothing,
        false,
        Char[],
        Set{Int}(),
        Set{Int}(),
        0.0,
        0.0,
        false,
        Float32[],
        UIDrawCommand[],
        Dict{String, Float32}(),
        Dict{String, Float32}()
    )
end

"""
    orthographic_matrix(left, right, bottom, top, near, far) -> Mat4f

Orthographic projection matrix (column-major, OpenGL convention).
For UI: `orthographic_matrix(0, width, height, 0, -1, 1)` gives top-left origin.
"""
function orthographic_matrix(left::Float32, right::Float32,
                             bottom::Float32, top::Float32,
                             near::Float32, far::Float32)
    rl = right - left
    tb = top - bottom
    fn = far - near
    return Mat4f(
        2.0f0/rl,      0.0f0,         0.0f0,        0.0f0,
        0.0f0,         2.0f0/tb,      0.0f0,        0.0f0,
        0.0f0,         0.0f0,        -2.0f0/fn,     0.0f0,
        -(right+left)/rl, -(top+bottom)/tb, -(far+near)/fn, 1.0f0
    )
end

"""
    clear_ui!(ctx::UIContext)

Reset UI context for a new frame.
"""
function clear_ui!(ctx::UIContext)
    empty!(ctx.vertices)
    empty!(ctx.draw_commands)
    empty!(ctx.overlay_vertices)
    empty!(ctx.overlay_draw_commands)
    empty!(ctx.layout_stack)
    empty!(ctx.clip_stack)
    ctx.in_overlay = false
    ctx.has_keyboard_focus = false
    return nothing
end
