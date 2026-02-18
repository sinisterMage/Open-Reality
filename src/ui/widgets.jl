# UI widget functions — immediate-mode API

"""
    ui_rect(ctx::UIContext; x, y, width, height, color)

Draw a solid colored rectangle.
"""
function ui_rect(ctx::UIContext;
                 x::Real = 0, y::Real = 0,
                 width::Real = 100, height::Real = 100,
                 color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                 alpha::Float32 = 1.0f0)
    _push_quad!(ctx, Float32(x), Float32(y), Float32(width), Float32(height),
                0.0f0, 0.0f0, 0.0f0, 0.0f0,  # no UVs for solid color
                Float32(red(color)), Float32(green(color)), Float32(blue(color)), alpha,
                UInt32(0), false)
    return nothing
end

"""
    ui_text(ctx::UIContext, text::String; x, y, size, color)

Draw text at the given position.
"""
function ui_text(ctx::UIContext, text::String;
                 x::Real = 0, y::Real = 0,
                 size::Int = 24,
                 color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                 alpha::Float32 = 1.0f0,
                 _skip_layout::Bool = false)
    atlas = ctx.font_atlas
    if isempty(atlas.glyphs)
        return nothing
    end

    scale = Float32(size) / atlas.font_size

    # When inside a layout (and not explicitly skipped), use layout cursor as base position
    base_x = Float32(x)
    base_y = Float32(y)
    layout_active = !_skip_layout && !isempty(ctx.layout_stack)
    if layout_active
        base_x = ctx.layout_stack[end].cursor_x
        base_y = ctx.layout_stack[end].cursor_y
    end

    cursor_x = base_x
    cursor_y = base_y
    r = Float32(red(color))
    g = Float32(green(color))
    b = Float32(blue(color))

    for ch in text
        if ch == '\n'
            cursor_x = base_x
            cursor_y += atlas.line_height * scale
            continue
        end

        glyph = get(atlas.glyphs, ch, nothing)
        glyph === nothing && continue

        if glyph.width > 0 && glyph.height > 0
            gx = cursor_x + glyph.bearing_x * scale
            gy = cursor_y + (atlas.font_size - glyph.bearing_y) * scale
            gw = glyph.width * scale
            gh = glyph.height * scale

            _push_quad!(ctx, gx, gy, gw, gh,
                        glyph.uv_x, glyph.uv_y, glyph.uv_w, glyph.uv_h,
                        r, g, b, alpha,
                        atlas.texture_id, true; skip_layout=true)
        end

        cursor_x += glyph.advance_x * scale
    end

    # Advance layout cursor once for the entire text widget
    if layout_active && !isempty(ctx.layout_stack)
        tw, th = measure_text(atlas, text, size=Float32(size))
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += tw + lc.spacing
            lc.row_height = max(lc.row_height, th)
        else
            lc.cursor_y += th + lc.spacing
            lc.col_width = max(lc.col_width, tw)
        end
    end

    return nothing
end

"""
    ui_button(ctx::UIContext, label::String; x, y, width, height, color, text_color) -> Bool

Draw a button. Returns true if clicked this frame.
"""
function ui_button(ctx::UIContext, label::String;
                   x::Real = 0, y::Real = 0,
                   width::Real = 120, height::Real = 40,
                   color::RGB{Float32} = RGB{Float32}(0.3, 0.3, 0.3),
                   hover_color::RGB{Float32} = RGB{Float32}(0.4, 0.4, 0.4),
                   text_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                   text_size::Int = 20,
                   alpha::Float32 = 1.0f0)
    fx = Float32(x)
    fy = Float32(y)
    fw = Float32(width)
    fh = Float32(height)

    # When inside a layout, use layout cursor for effective position
    layout_active = !isempty(ctx.layout_stack)
    if layout_active
        fx = ctx.layout_stack[end].cursor_x
        fy = ctx.layout_stack[end].cursor_y
    end

    # Hit test using effective position
    hovered = ctx.mouse_x >= fx && ctx.mouse_x <= fx + fw &&
              ctx.mouse_y >= fy && ctx.mouse_y <= fy + fh
    clicked = hovered && ctx.mouse_clicked

    # Draw background at effective position (skip layout cursor override)
    bg_color = hovered ? hover_color : color
    _push_quad!(ctx, fx, fy, fw, fh,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(bg_color)), Float32(green(bg_color)), Float32(blue(bg_color)), alpha,
                UInt32(0), false; skip_layout=true)

    # Center text using effective coordinates
    if !isempty(ctx.font_atlas.glyphs)
        tw, th = measure_text(ctx.font_atlas, label, size=Float32(text_size))
        tx = fx + (fw - tw) / 2.0f0
        ty = fy + (fh - Float32(text_size)) / 2.0f0
        ui_text(ctx, label, x=tx, y=ty, size=text_size, color=text_color, alpha=alpha, _skip_layout=true)
    end

    # Advance layout cursor once for the entire button
    if layout_active && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += fw + lc.spacing
            lc.row_height = max(lc.row_height, fh)
        else
            lc.cursor_y += fh + lc.spacing
            lc.col_width = max(lc.col_width, fw)
        end
    end

    return clicked
end

"""
    ui_progress_bar(ctx::UIContext, fraction; x, y, width, height, color, bg_color)

Draw a progress bar (0.0 to 1.0).
"""
function ui_progress_bar(ctx::UIContext, fraction::Real;
                         x::Real = 0, y::Real = 0,
                         width::Real = 200, height::Real = 20,
                         color::RGB{Float32} = RGB{Float32}(0.2, 0.8, 0.2),
                         bg_color::RGB{Float32} = RGB{Float32}(0.2, 0.2, 0.2),
                         alpha::Float32 = 1.0f0)
    f = clamp(Float32(fraction), 0.0f0, 1.0f0)
    fx = Float32(x)
    fy = Float32(y)
    fw = Float32(width)
    fh = Float32(height)

    layout_active = !isempty(ctx.layout_stack)
    if layout_active
        fx = ctx.layout_stack[end].cursor_x
        fy = ctx.layout_stack[end].cursor_y
    end

    # Background
    _push_quad!(ctx, fx, fy, fw, fh,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(bg_color)), Float32(green(bg_color)), Float32(blue(bg_color)), alpha,
                UInt32(0), false; skip_layout=true)

    # Fill
    if f > 0.0f0
        _push_quad!(ctx, fx, fy, fw * f, fh,
                    0.0f0, 0.0f0, 0.0f0, 0.0f0,
                    Float32(red(color)), Float32(green(color)), Float32(blue(color)), alpha,
                    UInt32(0), false; skip_layout=true)
    end

    # Advance layout cursor once
    if layout_active && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += fw + lc.spacing
            lc.row_height = max(lc.row_height, fh)
        else
            lc.cursor_y += fh + lc.spacing
            lc.col_width = max(lc.col_width, fw)
        end
    end

    return nothing
end

"""
    ui_image(ctx::UIContext, texture_id::UInt32; x, y, width, height, alpha)

Draw a textured image quad using a pre-uploaded GPU texture ID.
"""
function ui_image(ctx::UIContext, texture_id::UInt32;
                  x::Real = 0, y::Real = 0,
                  width::Real = 64, height::Real = 64,
                  alpha::Float32 = 1.0f0)
    _push_quad!(ctx, Float32(x), Float32(y), Float32(width), Float32(height),
                0.0f0, 0.0f0, 1.0f0, 1.0f0,
                1.0f0, 1.0f0, 1.0f0, alpha,
                texture_id, false)
    return nothing
end

"""
    ui_row(f, ctx; x, y, padding, spacing, width)

Layout children horizontally in a row. Widgets inside the do-block are
auto-positioned left-to-right using the container's cursor.
"""
function ui_row(f::Function, ctx::UIContext;
                x::Real = 0, y::Real = 0,
                padding::Real = 0, spacing::Real = 4,
                width::Real = 0)
    if !isempty(ctx.layout_stack)
        start_x = ctx.layout_stack[end].cursor_x + Float32(padding)
        start_y = ctx.layout_stack[end].cursor_y + Float32(padding)
    else
        start_x = Float32(x) + Float32(padding)
        start_y = Float32(y) + Float32(padding)
    end

    container = LayoutContainer(
        start_x, start_y,   # origin
        start_x, start_y,   # cursor
        :row,
        Float32(padding), Float32(spacing),
        0f0, 0f0,           # row_height, col_width
        nothing, 0f0, 0f0   # anchor, margin_x, margin_y
    )
    push!(ctx.layout_stack, container)

    try
        f()
    finally
        finished = pop!(ctx.layout_stack)
        total_w = finished.cursor_x - finished.origin_x
        total_h = finished.row_height

        # Advance parent cursor if nested
        if !isempty(ctx.layout_stack)
            parent = ctx.layout_stack[end]
            if parent.direction === :row
                parent.cursor_x += total_w + parent.spacing
                parent.row_height = max(parent.row_height, total_h)
            else
                parent.cursor_y += total_h + parent.spacing
                parent.col_width = max(parent.col_width, total_w)
            end
        end
    end

    return nothing
end

"""
    ui_column(f, ctx; x, y, padding, spacing, height)

Layout children vertically in a column. Widgets inside the do-block are
auto-positioned top-to-bottom using the container's cursor.
"""
function ui_column(f::Function, ctx::UIContext;
                   x::Real = 0, y::Real = 0,
                   padding::Real = 0, spacing::Real = 4,
                   height::Real = 0)
    if !isempty(ctx.layout_stack)
        start_x = ctx.layout_stack[end].cursor_x + Float32(padding)
        start_y = ctx.layout_stack[end].cursor_y + Float32(padding)
    else
        start_x = Float32(x) + Float32(padding)
        start_y = Float32(y) + Float32(padding)
    end

    container = LayoutContainer(
        start_x, start_y,   # origin
        start_x, start_y,   # cursor
        :column,
        Float32(padding), Float32(spacing),
        0f0, 0f0,           # row_height, col_width
        nothing, 0f0, 0f0   # anchor, margin_x, margin_y
    )
    push!(ctx.layout_stack, container)

    try
        f()
    finally
        finished = pop!(ctx.layout_stack)
        total_w = finished.col_width
        total_h = finished.cursor_y - finished.origin_y

        # Advance parent cursor if nested
        if !isempty(ctx.layout_stack)
            parent = ctx.layout_stack[end]
            if parent.direction === :row
                parent.cursor_x += total_w + parent.spacing
                parent.row_height = max(parent.row_height, total_h)
            else
                parent.cursor_y += total_h + parent.spacing
                parent.col_width = max(parent.col_width, total_w)
            end
        end
    end

    return nothing
end

"""
    ui_anchor(f, ctx; anchor, margin_x, margin_y)

Position children relative to a screen anchor point (:top_left, :top_right,
:bottom_left, :bottom_right, :center). Children are laid out in a column
starting from the computed origin.
"""
function ui_anchor(f::Function, ctx::UIContext;
                   anchor::Symbol = :top_left,
                   margin_x::Real = 10, margin_y::Real = 10)
    if anchor === :top_left
        ox = Float32(margin_x)
        oy = Float32(margin_y)
    elseif anchor === :top_right
        ox = Float32(ctx.width) - Float32(margin_x)
        oy = Float32(margin_y)
    elseif anchor === :bottom_left
        ox = Float32(margin_x)
        oy = Float32(ctx.height) - Float32(margin_y)
    elseif anchor === :bottom_right
        ox = Float32(ctx.width) - Float32(margin_x)
        oy = Float32(ctx.height) - Float32(margin_y)
    elseif anchor === :center
        ox = Float32(ctx.width) / 2f0
        oy = Float32(ctx.height) / 2f0
    else
        # Fallback to top_left
        ox = Float32(margin_x)
        oy = Float32(margin_y)
    end

    container = LayoutContainer(
        ox, oy,             # origin
        ox, oy,             # cursor
        :column,
        0f0, 4f0,           # padding, spacing
        0f0, 0f0,           # row_height, col_width
        anchor, Float32(margin_x), Float32(margin_y)
    )
    push!(ctx.layout_stack, container)

    try
        f()
    finally
        pop!(ctx.layout_stack)
    end

    return nothing
end

"""
    ui_begin_overlay(f, ctx)

Execute `f()` with overlay rendering enabled. Geometry pushed inside the block
goes to `ctx.overlay_vertices` / `ctx.overlay_draw_commands` so it renders on
top of all normal UI. Nested calls are harmless (no double-flip).
"""
function ui_begin_overlay(f::Function, ctx::UIContext)
    if ctx.in_overlay
        f()
        return nothing
    end
    ctx.in_overlay = true
    try
        f()
    finally
        ctx.in_overlay = false
    end
    return nothing
end

"""
    ui_slider(ctx, value; id, x, y, width, height, min_val, max_val, ...) -> Float32

Draw a horizontal slider and return the (possibly updated) value.
"""
function ui_slider(ctx::UIContext, value::Float32;
                   id::String = "slider",
                   x::Real = 0, y::Real = 0,
                   width::Real = 200, height::Real = 24,
                   min_val::Float32 = 0.0f0, max_val::Float32 = 1.0f0,
                   track_color::RGB{Float32} = RGB{Float32}(0.3, 0.3, 0.3),
                   fill_color::RGB{Float32} = RGB{Float32}(0.2, 0.6, 1.0),
                   thumb_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                   alpha::Float32 = 1.0f0)
    fx = Float32(x)
    fy = Float32(y)
    fw = Float32(width)
    fh = Float32(height)

    layout_active = !isempty(ctx.layout_stack)
    if layout_active
        fx = ctx.layout_stack[end].cursor_x
        fy = ctx.layout_stack[end].cursor_y
    end

    # Hit test — drag interaction (process before rendering so visuals reflect current value)
    if ctx.mouse_down && ctx.mouse_x >= fx && ctx.mouse_x <= fx + fw &&
       ctx.mouse_y >= fy && ctx.mouse_y <= fy + fh
        new_frac = clamp((Float32(ctx.mouse_x) - fx) / fw, 0f0, 1f0)
        value = min_val + new_frac * (max_val - min_val)
        ctx.drag_offsets[id] = 1f0
    else
        ctx.drag_offsets[id] = 0f0
    end

    frac = clamp((value - min_val) / (max_val - min_val), 0f0, 1f0)

    # Track rect (centered vertically, 1/3 height)
    track_y = fy + fh / 3f0
    track_h = fh / 3f0
    _push_quad!(ctx, fx, track_y, fw, track_h,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(track_color)), Float32(green(track_color)), Float32(blue(track_color)), alpha,
                UInt32(0), false; skip_layout=true)

    # Fill rect
    fill_w = fw * frac
    if fill_w > 0f0
        _push_quad!(ctx, fx, track_y, fill_w, track_h,
                    0.0f0, 0.0f0, 0.0f0, 0.0f0,
                    Float32(red(fill_color)), Float32(green(fill_color)), Float32(blue(fill_color)), alpha,
                    UInt32(0), false; skip_layout=true)
    end

    # Thumb rect
    thumb_x = fx + fw * frac - fh / 2f0
    thumb_y = fy
    thumb_size = fh
    _push_quad!(ctx, thumb_x, thumb_y, thumb_size, thumb_size,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(thumb_color)), Float32(green(thumb_color)), Float32(blue(thumb_color)), alpha,
                UInt32(0), false; skip_layout=true)

    # Layout advance
    if layout_active && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += fw + lc.spacing
            lc.row_height = max(lc.row_height, fh)
        else
            lc.cursor_y += fh + lc.spacing
            lc.col_width = max(lc.col_width, fw)
        end
    end

    return clamp(value, min_val, max_val)
end

"""
    ui_checkbox(ctx, checked; id, x, y, size, label, ...) -> Bool

Draw a checkbox with optional label. Returns the (possibly toggled) state.
"""
function ui_checkbox(ctx::UIContext, checked::Bool;
                     id::String = "checkbox",
                     x::Real = 0, y::Real = 0,
                     size::Real = 24,
                     label::String = "",
                     box_color::RGB{Float32} = RGB{Float32}(0.3, 0.3, 0.3),
                     check_color::RGB{Float32} = RGB{Float32}(0.2, 0.8, 0.2),
                     text_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                     text_size::Int = 20,
                     alpha::Float32 = 1.0f0)
    fx = Float32(x)
    fy = Float32(y)
    fs = Float32(size)

    layout_active = !isempty(ctx.layout_stack)
    if layout_active
        fx = ctx.layout_stack[end].cursor_x
        fy = ctx.layout_stack[end].cursor_y
    end

    # Box rect
    _push_quad!(ctx, fx, fy, fs, fs,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(box_color)), Float32(green(box_color)), Float32(blue(box_color)), alpha,
                UInt32(0), false; skip_layout=true)

    # Checkmark (inner rect)
    if checked
        inset = fs * 0.2f0
        _push_quad!(ctx, fx + inset, fy + inset, fs - 2f0 * inset, fs - 2f0 * inset,
                    0.0f0, 0.0f0, 0.0f0, 0.0f0,
                    Float32(red(check_color)), Float32(green(check_color)), Float32(blue(check_color)), alpha,
                    UInt32(0), false; skip_layout=true)
    end

    # Label
    label_width = 0f0
    if !isempty(label) && !isempty(ctx.font_atlas.glyphs)
        ui_text(ctx, label, x=fx + fs + 4f0, y=fy, size=text_size, color=text_color, alpha=alpha, _skip_layout=true)
        lw, _ = measure_text(ctx.font_atlas, label, size=Float32(text_size))
        label_width = lw
    end

    # Hit test
    if ctx.mouse_clicked && ctx.mouse_x >= fx && ctx.mouse_x <= fx + fs &&
       ctx.mouse_y >= fy && ctx.mouse_y <= fy + fs
        checked = !checked
    end

    # Layout advance
    total_w = fs + (isempty(label) ? 0f0 : 4f0 + label_width)
    if layout_active && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += total_w + lc.spacing
            lc.row_height = max(lc.row_height, fs)
        else
            lc.cursor_y += fs + lc.spacing
            lc.col_width = max(lc.col_width, total_w)
        end
    end

    return checked
end

"""
    ui_text_input(ctx, text; id, x, y, width, height, ...) -> String

Draw a single-line text input field. Returns the (possibly modified) text.
"""
function ui_text_input(ctx::UIContext, text::String;
                       id::String = "text_input",
                       x::Real = 0, y::Real = 0,
                       width::Real = 200, height::Real = 32,
                       bg_color::RGB{Float32} = RGB{Float32}(0.15, 0.15, 0.15),
                       border_color::RGB{Float32} = RGB{Float32}(0.4, 0.4, 0.4),
                       focus_color::RGB{Float32} = RGB{Float32}(0.2, 0.5, 1.0),
                       text_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                       text_size::Int = 20,
                       alpha::Float32 = 1.0f0)
    fx = Float32(x)
    fy = Float32(y)
    fw = Float32(width)
    fh = Float32(height)

    layout_active = !isempty(ctx.layout_stack)
    if layout_active
        fx = ctx.layout_stack[end].cursor_x
        fy = ctx.layout_stack[end].cursor_y
    end

    # Focus state
    is_focused = ctx.focused_widget_id == id

    # Click handling
    if ctx.mouse_clicked
        if ctx.mouse_x >= fx && ctx.mouse_x <= fx + fw &&
           ctx.mouse_y >= fy && ctx.mouse_y <= fy + fh
            ctx.focused_widget_id = id
            is_focused = true
        elseif is_focused
            ctx.focused_widget_id = nothing
            is_focused = false
        end
    end

    # Background rect
    current_bg = is_focused ? focus_color : bg_color
    _push_quad!(ctx, fx, fy, fw, fh,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(current_bg)), Float32(green(current_bg)), Float32(blue(current_bg)), alpha,
                UInt32(0), false; skip_layout=true)

    # Keyboard input (only when focused)
    if is_focused
        ctx.has_keyboard_focus = true
        for ch in ctx.typed_chars
            text = text * string(ch)
        end
        # Backspace rising edge (key code 259)
        if 259 in ctx.keys_pressed && !(259 in ctx.prev_keys_pressed) && !isempty(text)
            text = text[1:prevind(text, lastindex(text))]
        end
    end

    # Text rendering
    if !isempty(ctx.font_atlas.glyphs)
        ui_text(ctx, text, x=fx + 4f0, y=fy + (fh - Float32(text_size)) / 2f0,
                size=text_size, color=text_color, alpha=alpha, _skip_layout=true)
    end

    # Cursor rect (blinking indicator when focused)
    if is_focused && !isempty(ctx.font_atlas.glyphs)
        tw, _ = measure_text(ctx.font_atlas, text, size=Float32(text_size))
        _push_quad!(ctx, fx + 4f0 + tw, fy + 2f0, 1f0, fh - 4f0,
                    0.0f0, 0.0f0, 0.0f0, 0.0f0,
                    Float32(red(focus_color)), Float32(green(focus_color)), Float32(blue(focus_color)), alpha,
                    UInt32(0), false; skip_layout=true)
    end

    # Layout advance
    if layout_active && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += fw + lc.spacing
            lc.row_height = max(lc.row_height, fh)
        else
            lc.cursor_y += fh + lc.spacing
            lc.col_width = max(lc.col_width, fw)
        end
    end

    return text
end

"""
    ui_dropdown(ctx, selected, options; id, x, y, width, height, ...) -> Int

Draw a dropdown selector. Returns the (possibly changed) selected index (1-based).
"""
function ui_dropdown(ctx::UIContext, selected::Int, options::Vector{String};
                     id::String = "dropdown",
                     x::Real = 0, y::Real = 0,
                     width::Real = 160, height::Real = 32,
                     bg_color::RGB{Float32} = RGB{Float32}(0.2, 0.2, 0.2),
                     text_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                     text_size::Int = 18,
                     item_height::Int = 28,
                     alpha::Float32 = 1.0f0)
    is_open = get!(ctx.drag_offsets, id, 0f0) == 1f0

    fx = Float32(x)
    fy = Float32(y)
    fw = Float32(width)
    fh = Float32(height)

    layout_active = !isempty(ctx.layout_stack)
    if layout_active
        fx = ctx.layout_stack[end].cursor_x
        fy = ctx.layout_stack[end].cursor_y
    end

    # Header rect
    _push_quad!(ctx, fx, fy, fw, fh,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(bg_color)), Float32(green(bg_color)), Float32(blue(bg_color)), alpha,
                UInt32(0), false; skip_layout=true)

    # Selected text
    if 1 <= selected <= length(options) && !isempty(ctx.font_atlas.glyphs)
        ui_text(ctx, options[selected],
                x=fx + 4f0, y=fy + (fh - Float32(text_size)) / 2f0,
                size=text_size, color=text_color, alpha=alpha, _skip_layout=true)
    end

    # Arrow text
    if !isempty(ctx.font_atlas.glyphs)
        arrow = is_open ? "▲" : "▼"
        ui_text(ctx, arrow,
                x=fx + fw - 20f0, y=fy + (fh - Float32(text_size)) / 2f0,
                size=text_size, color=text_color, alpha=alpha, _skip_layout=true)
    end

    # Toggle open/close on header click
    if ctx.mouse_clicked && ctx.mouse_x >= fx && ctx.mouse_x <= fx + fw &&
       ctx.mouse_y >= fy && ctx.mouse_y <= fy + fh
        ctx.drag_offsets[id] = is_open ? 0f0 : 1f0
        is_open = !is_open
    end

    # Dropdown list (overlay)
    if is_open
        ui_begin_overlay(ctx) do
            for (i, opt) in enumerate(options)
                item_y = fy + fh + Float32(i - 1) * Float32(item_height)

                # Item background
                _push_quad!(ctx, fx, item_y, fw, Float32(item_height),
                            0.0f0, 0.0f0, 0.0f0, 0.0f0,
                            Float32(red(bg_color)), Float32(green(bg_color)), Float32(blue(bg_color)), alpha,
                            UInt32(0), false; skip_layout=true)

                # Item text
                if !isempty(ctx.font_atlas.glyphs)
                    ui_text(ctx, opt,
                            x=fx + 4f0, y=item_y + (Float32(item_height) - Float32(text_size)) / 2f0,
                            size=text_size, color=text_color, alpha=alpha, _skip_layout=true)
                end

                # Item click
                if ctx.mouse_clicked && ctx.mouse_x >= fx && ctx.mouse_x <= fx + fw &&
                   ctx.mouse_y >= item_y && ctx.mouse_y <= item_y + Float32(item_height)
                    selected = i
                    ctx.drag_offsets[id] = 0f0
                end
            end
        end
    end

    # Layout advance (header only)
    if layout_active && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += fw + lc.spacing
            lc.row_height = max(lc.row_height, fh)
        else
            lc.cursor_y += fh + lc.spacing
            lc.col_width = max(lc.col_width, fw)
        end
    end

    return selected
end

"""
    ui_scrollable_panel(f, ctx; id, x, y, width, height, bg_color, scroll_speed, alpha)

A scrollable panel that clips children to its bounds. Use a do-block to add
child widgets. Scroll state is persisted across frames via `ctx.scroll_offsets`.
"""
function ui_scrollable_panel(f::Function, ctx::UIContext;
                             id::String = "scroll_panel",
                             x::Real = 0, y::Real = 0,
                             width::Real = 300, height::Real = 200,
                             bg_color::RGB{Float32} = RGB{Float32}(0.1, 0.1, 0.1),
                             scroll_speed::Float32 = 20f0,
                             alpha::Float32 = 1.0f0)
    fx = Float32(x)
    fy = Float32(y)
    fw = Float32(width)
    fh = Float32(height)

    layout_active = !isempty(ctx.layout_stack)
    if layout_active
        fx = ctx.layout_stack[end].cursor_x
        fy = ctx.layout_stack[end].cursor_y
    end

    # Background rect
    _push_quad!(ctx, fx, fy, fw, fh,
                0.0f0, 0.0f0, 0.0f0, 0.0f0,
                Float32(red(bg_color)), Float32(green(bg_color)), Float32(blue(bg_color)), alpha,
                UInt32(0), false; skip_layout=true)

    # Scroll offset
    scroll = get!(ctx.scroll_offsets, id, 0f0)

    # Scroll input
    if ctx.mouse_x >= fx && ctx.mouse_x <= fx + fw &&
       ctx.mouse_y >= fy && ctx.mouse_y <= fy + fh && ctx.scroll_y != 0
        scroll = max(0f0, scroll - Float32(ctx.scroll_y) * scroll_speed)
    end

    # Push clip rect
    push!(ctx.clip_stack, (Int32(round(fx)), Int32(round(fy)), Int32(round(fw)), Int32(round(fh))))

    # Push layout container for children
    container = LayoutContainer(
        fx, fy - scroll,    # origin (scroll-adjusted)
        fx, fy - scroll,    # cursor
        :column,
        0f0, 4f0,           # padding, spacing
        0f0, 0f0,           # row_height, col_width
        nothing, 0f0, 0f0   # anchor, margin_x, margin_y
    )
    push!(ctx.layout_stack, container)

    local finished
    try
        f()
    finally
        finished = pop!(ctx.layout_stack)
        pop!(ctx.clip_stack)
    end

    # Max scroll clamp
    content_h = finished.cursor_y - finished.origin_y
    max_scroll = max(0f0, content_h - fh)
    scroll = clamp(scroll, 0f0, max_scroll)

    # Persist scroll
    ctx.scroll_offsets[id] = scroll

    # Scrollbar (visual only)
    if content_h > fh
        bar_w = 6f0
        bar_h = max(20f0, fh * (fh / content_h))
        bar_x = fx + fw - bar_w
        bar_frac = max_scroll > 0f0 ? scroll / max_scroll : 0f0
        bar_y = fy + bar_frac * (fh - bar_h)
        _push_quad!(ctx, bar_x, bar_y, bar_w, bar_h,
                    0.0f0, 0.0f0, 0.0f0, 0.0f0,
                    0.5f0, 0.5f0, 0.5f0, alpha * 0.6f0,
                    UInt32(0), false; skip_layout=true)
    end

    # Layout advance (parent)
    if layout_active && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += fw + lc.spacing
            lc.row_height = max(lc.row_height, fh)
        else
            lc.cursor_y += fh + lc.spacing
            lc.col_width = max(lc.col_width, fw)
        end
    end

    return nothing
end

"""
    ui_tooltip(ctx, text; x, y, bg_color, text_color, text_size, padding, alpha)

Draw a tooltip box. By default positions near the mouse cursor.
Does not affect layout.
"""
function ui_tooltip(ctx::UIContext, text::String;
                    x::Real = -1, y::Real = -1,
                    bg_color::RGB{Float32} = RGB{Float32}(0.1, 0.1, 0.1),
                    text_color::RGB{Float32} = RGB{Float32}(1, 1, 1),
                    text_size::Int = 16,
                    padding::Int = 6,
                    alpha::Float32 = 1.0f0)
    tx = (x == -1) ? Float32(ctx.mouse_x) + 12f0 : Float32(x)
    ty = (y == -1) ? Float32(ctx.mouse_y) + 12f0 : Float32(y)

    if isempty(ctx.font_atlas.glyphs)
        return nothing
    end

    tw, th = measure_text(ctx.font_atlas, text, size=Float32(text_size))
    bg_w = tw + 2f0 * Float32(padding)
    bg_h = th + 2f0 * Float32(padding)

    # Render in overlay mode so tooltips are not clipped by active clip rects
    ui_begin_overlay(ctx) do
        # Background
        _push_quad!(ctx, tx, ty, bg_w, bg_h,
                    0.0f0, 0.0f0, 0.0f0, 0.0f0,
                    Float32(red(bg_color)), Float32(green(bg_color)), Float32(blue(bg_color)), alpha,
                    UInt32(0), false; skip_layout=true)

        # Text
        ui_text(ctx, text,
                x=tx + Float32(padding), y=ty + Float32(padding),
                size=text_size, color=text_color, alpha=alpha, _skip_layout=true)
    end

    return nothing
end

# ---- Internal helpers ----

"""
Push a quad (2 triangles, 6 vertices) into the UI vertex buffer.
Each vertex: position.xy + uv.xy + color.rgba = 8 floats.
Uses direct indexed writes to avoid allocating a temporary array.
Routes to overlay buffers when `ctx.in_overlay` is true.
"""
function _push_quad!(ctx::UIContext,
                     x::Float32, y::Float32, w::Float32, h::Float32,
                     uv_x::Float32, uv_y::Float32, uv_w::Float32, uv_h::Float32,
                     r::Float32, g::Float32, b::Float32, a::Float32,
                     texture_id::UInt32, is_font::Bool;
                     skip_layout::Bool = false)
    # Layout cursor override — when inside a layout container, position from cursor
    if !skip_layout && !isempty(ctx.layout_stack)
        x = ctx.layout_stack[end].cursor_x
        y = ctx.layout_stack[end].cursor_y
    end

    # Select target buffers based on overlay state
    verts = ctx.in_overlay ? ctx.overlay_vertices : ctx.vertices
    cmds = ctx.in_overlay ? ctx.overlay_draw_commands : ctx.draw_commands

    offset = length(verts)

    x0, y0 = x, y
    x1, y1 = x + w, y + h
    u0, v0 = uv_x, uv_y
    u1, v1 = uv_x + uv_w, uv_y + uv_h

    # Pre-grow buffer by 48 floats (6 vertices × 8 floats)
    resize!(verts, offset + 48)

    # Vertex 1 (top-left)
    @inbounds verts[offset + 1] = x0; @inbounds verts[offset + 2] = y0
    @inbounds verts[offset + 3] = u0; @inbounds verts[offset + 4] = v0
    @inbounds verts[offset + 5] = r;  @inbounds verts[offset + 6] = g
    @inbounds verts[offset + 7] = b;  @inbounds verts[offset + 8] = a
    # Vertex 2 (top-right)
    @inbounds verts[offset + 9]  = x1; @inbounds verts[offset + 10] = y0
    @inbounds verts[offset + 11] = u1; @inbounds verts[offset + 12] = v0
    @inbounds verts[offset + 13] = r;  @inbounds verts[offset + 14] = g
    @inbounds verts[offset + 15] = b;  @inbounds verts[offset + 16] = a
    # Vertex 3 (bottom-right)
    @inbounds verts[offset + 17] = x1; @inbounds verts[offset + 18] = y1
    @inbounds verts[offset + 19] = u1; @inbounds verts[offset + 20] = v1
    @inbounds verts[offset + 21] = r;  @inbounds verts[offset + 22] = g
    @inbounds verts[offset + 23] = b;  @inbounds verts[offset + 24] = a
    # Vertex 4 (top-left)
    @inbounds verts[offset + 25] = x0; @inbounds verts[offset + 26] = y0
    @inbounds verts[offset + 27] = u0; @inbounds verts[offset + 28] = v0
    @inbounds verts[offset + 29] = r;  @inbounds verts[offset + 30] = g
    @inbounds verts[offset + 31] = b;  @inbounds verts[offset + 32] = a
    # Vertex 5 (bottom-right)
    @inbounds verts[offset + 33] = x1; @inbounds verts[offset + 34] = y1
    @inbounds verts[offset + 35] = u1; @inbounds verts[offset + 36] = v1
    @inbounds verts[offset + 37] = r;  @inbounds verts[offset + 38] = g
    @inbounds verts[offset + 39] = b;  @inbounds verts[offset + 40] = a
    # Vertex 6 (bottom-left)
    @inbounds verts[offset + 41] = x0; @inbounds verts[offset + 42] = y1
    @inbounds verts[offset + 43] = u0; @inbounds verts[offset + 44] = v1
    @inbounds verts[offset + 45] = r;  @inbounds verts[offset + 46] = g
    @inbounds verts[offset + 47] = b;  @inbounds verts[offset + 48] = a

    # Add draw command (try to merge with last command if same texture and clip)
    clip = (ctx.in_overlay || isempty(ctx.clip_stack)) ? nothing : ctx.clip_stack[end]
    if !isempty(cmds)
        last = cmds[end]
        if last.texture_id == texture_id && last.is_font == is_font && last.clip_rect == clip
            cmds[end] = UIDrawCommand(
                last.vertex_offset, last.vertex_count + 6,
                texture_id, is_font, last.clip_rect
            )
        else
            push!(cmds, UIDrawCommand(offset, 6, texture_id, is_font, clip))
        end
    else
        push!(cmds, UIDrawCommand(offset, 6, texture_id, is_font, clip))
    end

    # Advance layout cursor
    if !skip_layout && !isempty(ctx.layout_stack)
        lc = ctx.layout_stack[end]
        if lc.direction === :row
            lc.cursor_x += w + lc.spacing
            lc.row_height = max(lc.row_height, h)
        else
            lc.cursor_y += h + lc.spacing
            lc.col_width = max(lc.col_width, w)
        end
    end

    return nothing
end
