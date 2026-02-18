# UI System Showcase
# Demonstrates all interactive UI widgets: slider, checkbox, text input,
# dropdown, scrollable panel, tooltip, layout system (row/column/anchor),
# overlay, button, progress bar.
#
# Run with:
#   julia --project=. examples/ui_showcase.jl

using OpenReality

reset_entity_counter!()
reset_component_stores!()

# ============================================================================
# Scene Setup — minimal 3D scene as backdrop
# ============================================================================

s = scene([
    # FPS Player
    create_player(position=Vec3d(0, 1.7, 6)),

    # Sun
    entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.5),
            intensity=2.5f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )
    ]),

    # Fill light
    entity([
        PointLightComponent(
            color=RGB{Float32}(0.4, 0.6, 1.0),
            intensity=20.0f0,
            range=25.0f0
        ),
        transform(position=Vec3d(-4, 5, 3))
    ]),

    # Objects to look at
    entity([
        sphere_mesh(radius=0.8f0),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.2, 0.2),
            metallic=0.7f0,
            roughness=0.3f0
        ),
        transform(position=Vec3d(-2, 0.8, 0))
    ]),

    entity([
        cube_mesh(size=1.2f0),
        MaterialComponent(
            color=RGB{Float32}(0.2, 0.5, 0.9),
            metallic=0.3f0,
            roughness=0.6f0
        ),
        transform(position=Vec3d(2, 0.6, 0))
    ]),

    entity([
        sphere_mesh(radius=0.5f0),
        MaterialComponent(
            color=RGB{Float32}(0.9, 0.8, 0.2),
            metallic=1.0f0,
            roughness=0.1f0
        ),
        transform(position=Vec3d(0, 0.5, -2))
    ]),

    # Floor
    entity([
        plane_mesh(width=20.0f0, depth=20.0f0),
        MaterialComponent(
            color=RGB{Float32}(0.4, 0.4, 0.4),
            metallic=0.0f0,
            roughness=0.9f0
        ),
        transform(),
        ColliderComponent(shape=AABBShape(Vec3f(10.0, 0.01, 10.0)), offset=Vec3f(0, -0.01, 0)),
        RigidBodyComponent(body_type=BODY_STATIC)
    ])
])

# ============================================================================
# UI State — Refs persist across frames
# ============================================================================

slider_val    = Ref(0.5f0)
show_stats    = Ref(true)
user_text     = Ref("Hello!")
dropdown_sel  = Ref(1)
frame_count   = Ref(0)
click_count   = Ref(0)

theme_names   = ["Red", "Green", "Blue", "Gold"]
theme_colors  = [
    RGB{Float32}(0.8, 0.2, 0.2),
    RGB{Float32}(0.2, 0.8, 0.3),
    RGB{Float32}(0.2, 0.4, 0.9),
    RGB{Float32}(0.9, 0.7, 0.1),
]

# ============================================================================
# UI Callback
# ============================================================================

ui_callback = function(ctx::UIContext)
    frame_count[] += 1

    # ── Title bar (top) ──────────────────────────────────────────────────
    ui_rect(ctx, x=0, y=0, width=ctx.width, height=44,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.8f0)
    ui_text(ctx, "OpenReality — UI Showcase", x=12, y=10, size=26,
            color=RGB{Float32}(1.0, 1.0, 1.0))

    # ── Controls panel (top-left) ────────────────────────────────────────
    ui_anchor(ctx, anchor=:top_left, margin_x=12, margin_y=56) do
        # Panel background
        ui_rect(ctx, width=280, height=310,
                color=RGB{Float32}(0.08, 0.08, 0.12), alpha=0.85f0)

        ui_column(ctx, x=22, y=66, spacing=10) do
            ui_text(ctx, "Controls", size=22,
                    color=RGB{Float32}(0.9, 0.8, 0.3))

            # Slider
            ui_text(ctx, "Intensity: $(round(slider_val[], digits=2))", size=16,
                    color=RGB{Float32}(0.8, 0.8, 0.8))
            slider_val[] = ui_slider(ctx, slider_val[],
                                     id="intensity", width=240, height=22,
                                     min_val=0.0f0, max_val=1.0f0)

            # Progress bar driven by slider
            ui_text(ctx, "Progress:", size=16,
                    color=RGB{Float32}(0.8, 0.8, 0.8))
            ui_progress_bar(ctx, slider_val[], width=240, height=18,
                            color=theme_colors[dropdown_sel[]])

            # Checkbox
            show_stats[] = ui_checkbox(ctx, show_stats[],
                                       id="show_stats", size=20,
                                       label="Show Stats Panel",
                                       check_color=RGB{Float32}(0.3, 0.9, 0.3))

            # Dropdown — theme selector
            ui_text(ctx, "Theme:", size=16,
                    color=RGB{Float32}(0.8, 0.8, 0.8))
            dropdown_sel[] = ui_dropdown(ctx, dropdown_sel[], theme_names,
                                         id="theme", width=240, height=28)

            # Text input
            ui_text(ctx, "Label:", size=16,
                    color=RGB{Float32}(0.8, 0.8, 0.8))
            user_text[] = ui_text_input(ctx, user_text[],
                                        id="label_input", width=240, height=28)
        end
    end

    # ── User text echo (bottom-left) ─────────────────────────────────────
    ui_anchor(ctx, anchor=:bottom_left, margin_x=12, margin_y=50) do
        ui_rect(ctx, width=280, height=36,
                color=theme_colors[dropdown_sel[]], alpha=0.7f0)
        ui_text(ctx, user_text[], x=24, y=ctx.height - 44, size=20,
                color=RGB{Float32}(1, 1, 1), _skip_layout=true)
    end

    # ── Stats panel (top-right, toggled by checkbox) ─────────────────────
    if show_stats[]
        ui_anchor(ctx, anchor=:top_right, margin_x=260, margin_y=56) do
            ui_rect(ctx, width=248, height=150,
                    color=RGB{Float32}(0.06, 0.06, 0.1), alpha=0.85f0)

            ui_column(ctx, x=ctx.width - 250, y=66, spacing=6) do
                ui_text(ctx, "Stats", size=22,
                        color=RGB{Float32}(0.3, 0.8, 1.0))
                ui_text(ctx, "Frame: $(frame_count[])", size=16,
                        color=RGB{Float32}(0.8, 0.8, 0.8))
                ui_text(ctx, "Clicks: $(click_count[])", size=16,
                        color=RGB{Float32}(0.8, 0.8, 0.8))
                ui_text(ctx, "Theme: $(theme_names[dropdown_sel[]])", size=16,
                        color=theme_colors[dropdown_sel[]])
                ui_text(ctx, "Slider: $(round(slider_val[], digits=3))", size=16,
                        color=RGB{Float32}(0.8, 0.8, 0.8))
            end
        end
    end

    # ── Scrollable log panel (bottom-right) ──────────────────────────────
    ui_anchor(ctx, anchor=:bottom_right, margin_x=260, margin_y=230) do
        ui_text(ctx, "Event Log", size=18,
                color=RGB{Float32}(0.7, 0.7, 0.7), _skip_layout=true)
    end

    scroll_x = Float32(ctx.width - 260)
    scroll_y = Float32(ctx.height - 210)
    ui_scrollable_panel(ctx, id="log_panel",
                        x=scroll_x, y=scroll_y,
                        width=248, height=170) do
        for i in 1:20
            ui_text(ctx, "Log entry #$i — $(theme_names[clamp(mod1(i, 4), 1, 4)])",
                    size=14, color=RGB{Float32}(0.7, 0.7, 0.7))
        end
    end

    # ── Row of buttons (bottom-center) ───────────────────────────────────
    btn_y = ctx.height - 50
    btn_start = (ctx.width - 300) / 2

    ui_row(ctx, x=btn_start, y=btn_y, spacing=8) do
        if ui_button(ctx, "Click Me", width=100, height=36,
                     color=theme_colors[dropdown_sel[]],
                     hover_color=RGB{Float32}(0.6, 0.6, 0.6),
                     text_size=16)
            click_count[] += 1
        end

        if ui_button(ctx, "Reset", width=90, height=36,
                     color=RGB{Float32}(0.5, 0.2, 0.2),
                     hover_color=RGB{Float32}(0.7, 0.3, 0.3),
                     text_size=16)
            slider_val[]   = 0.5f0
            show_stats[]   = true
            user_text[]    = "Hello!"
            dropdown_sel[] = 1
            click_count[]  = 0
        end

        # Animated bar
        anim = Float32((sin(frame_count[] * 0.03) + 1.0) / 2.0)
        ui_progress_bar(ctx, anim, width=90, height=36,
                        color=RGB{Float32}(0.3, 0.7, 1.0))
    end

    # ── Tooltip (show when hovering over top-right area) ─────────────────
    if show_stats[] &&
       ctx.mouse_x >= ctx.width - 260 && ctx.mouse_x <= ctx.width - 12 &&
       ctx.mouse_y >= 56 && ctx.mouse_y <= 206
        ui_tooltip(ctx, "Stats panel — toggle with checkbox",
                   text_size=14, padding=6)
    end

    # ── Controls hint ────────────────────────────────────────────────────
    ui_text(ctx, "WASD: Move | Mouse: Look | Shift: Sprint | Esc: Release cursor",
            x=ctx.width - 520, y=ctx.height - 14, size=12,
            color=RGB{Float32}(0.5, 0.5, 0.5))
end

# ============================================================================
# Run
# ============================================================================

println("Starting OpenReality UI Showcase...")
println("Controls: WASD to move, mouse to look, Shift to sprint, Escape to release cursor")
println()
println("UI Widgets demonstrated:")
println("  - Slider (intensity control)")
println("  - Checkbox (toggle stats panel)")
println("  - Dropdown (theme color selector)")
println("  - Text Input (editable label)")
println("  - Progress Bar (slider-driven + animated)")
println("  - Buttons (click counter + reset)")
println("  - Scrollable Panel (event log)")
println("  - Tooltip (hover over stats panel)")
println("  - Layout: row, column, anchor")

render(s, ui=ui_callback, title="OpenReality — UI Showcase")
