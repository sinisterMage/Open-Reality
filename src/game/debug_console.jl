# =============================================================================
# Debug Console — in-game command console with variable watching
# =============================================================================

"""
    DebugWatch

A named value that is displayed on-screen every frame.
"""
struct DebugWatch
    name::String
    getter::Function  # () -> String
end

"""
    DebugConsole

In-game debug console for runtime inspection and commands.
Toggle with backtick (`) key.
"""
mutable struct DebugConsole
    active::Bool
    input_buffer::String
    history::Vector{String}
    output_lines::Vector{String}
    max_output_lines::Int
    history_index::Int
    commands::Dict{String, Tuple{Function, String}}  # name => (handler, help_text)
    watches::Vector{DebugWatch}
    _cursor_pos::Int
    _fps_display::Bool
    _frame_times::Vector{Float64}

    DebugConsole() = new(
        false, "", String[], String[], 50, 0,
        Dict{String, Tuple{Function, String}}(),
        DebugWatch[], 0, false, Float64[]
    )
end

# ---------------------------------------------------------------------------
# Global singleton
# ---------------------------------------------------------------------------

const _DEBUG_CONSOLE = Ref{Union{DebugConsole, Nothing}}(nothing)

function get_debug_console()::DebugConsole
    if _DEBUG_CONSOLE[] === nothing
        _DEBUG_CONSOLE[] = DebugConsole()
        _register_builtin_commands!(_DEBUG_CONSOLE[])
    end
    return _DEBUG_CONSOLE[]
end

function reset_debug_console!()
    _DEBUG_CONSOLE[] = nothing
    return nothing
end

# ---------------------------------------------------------------------------
# Command registration
# ---------------------------------------------------------------------------

"""
    register_command!(name, handler; help="")

Register a debug command. `handler` receives `Vector{String}` args and returns output `String`.
"""
function register_command!(name::String, handler::Function; help::String="")
    console = get_debug_console()
    console.commands[name] = (handler, help)
    return nothing
end

"""
    execute_command!(input::String) -> String

Parse and execute a debug command. Returns the output string.
"""
function execute_command!(input::String)::String
    console = get_debug_console()
    parts = split(strip(input))
    isempty(parts) && return ""

    cmd_name = lowercase(string(parts[1]))
    args = length(parts) > 1 ? [string(p) for p in parts[2:end]] : String[]

    entry = get(console.commands, cmd_name, nothing)
    if entry === nothing
        return "Unknown command: $cmd_name. Type 'help' for available commands."
    end

    handler, _ = entry
    try
        return handler(args)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
end

# ---------------------------------------------------------------------------
# Watch system
# ---------------------------------------------------------------------------

"""
    watch!(name, getter)

Add a debug watch that displays on-screen every frame.
`getter` is a function `() -> String` that returns the display value.
"""
function watch!(name::String, getter::Function)
    console = get_debug_console()
    # Replace existing watch with same name
    filter!(w -> w.name != name, console.watches)
    push!(console.watches, DebugWatch(name, getter))
    return nothing
end

"""
    unwatch!(name)

Remove a debug watch by name.
"""
function unwatch!(name::String)
    console = get_debug_console()
    filter!(w -> w.name != name, console.watches)
    return nothing
end

# ---------------------------------------------------------------------------
# Built-in commands
# ---------------------------------------------------------------------------

function _register_builtin_commands!(console::DebugConsole)
    console.commands["help"] = ((args) -> begin
        lines = ["Available commands:"]
        for (name, (_, help_text)) in sort(collect(console.commands); by=first)
            push!(lines, "  $name - $help_text")
        end
        join(lines, "\n")
    end, "Show all commands")

    console.commands["inspect"] = ((args) -> begin
        if isempty(args)
            return "Usage: inspect <entity_index>"
        end
        idx = tryparse(Int, args[1])
        idx === nothing && return "Invalid entity index"
        eids = entities_with_component(TransformComponent)
        if idx < 1 || idx > length(eids)
            return "Entity index out of range (1-$(length(eids)))"
        end
        eid = eids[idx]
        lines = ["Entity #$idx:"]
        for T in [TransformComponent, MeshComponent, MaterialComponent,
                  ColliderComponent, RigidBodyComponent, HealthComponent,
                  ScriptComponent, CameraComponent, PlayerComponent]
            if has_component(eid, T)
                comp = get_component(eid, T)
                push!(lines, "  $(nameof(T)): $(sprint(show, comp))")
            end
        end
        join(lines, "\n")
    end, "Inspect entity components")

    console.commands["entities"] = ((args) -> begin
        count = component_count(TransformComponent)
        "Total entities with transforms: $count"
    end, "Count entities")

    console.commands["components"] = ((args) -> begin
        lines = ["Component counts:"]
        for T in [TransformComponent, MeshComponent, MaterialComponent,
                  ColliderComponent, RigidBodyComponent, HealthComponent,
                  ScriptComponent, CameraComponent, PlayerComponent,
                  PointLightComponent, DirectionalLightComponent,
                  ParticleSystemComponent, TerrainComponent]
            c = component_count(T)
            c > 0 && push!(lines, "  $(nameof(T)): $c")
        end
        join(lines, "\n")
    end, "List component counts")

    console.commands["fps"] = ((args) -> begin
        console._fps_display = !console._fps_display
        console._fps_display ? "FPS display enabled" : "FPS display disabled"
    end, "Toggle FPS display")

    console.commands["set"] = ((args) -> begin
        length(args) < 2 && return "Usage: set <key> <value>"
        key = args[1]
        val_str = args[2]
        # Try to parse as number
        val = tryparse(Float64, val_str)
        if val === nothing
            val = tryparse(Int, val_str)
        end
        if val === nothing
            val = val_str  # Keep as string
        end
        set_config!(key, val)
        "Set $key = $val"
    end, "Set config value")

    console.commands["get"] = ((args) -> begin
        isempty(args) && return "Usage: get <key>"
        val = get_config(args[1])
        val === nothing ? "Key '$(args[1])' not found" : "$(args[1]) = $val"
    end, "Get config value")

    console.commands["clear"] = ((args) -> begin
        empty!(console.output_lines)
        ""
    end, "Clear console output")
end

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

const KEY_GRAVE = 96  # GLFW.KEY_GRAVE_ACCENT

"""
    update_debug_console!(input::InputState, dt::Float64) -> Bool

Process debug console input. Returns `true` if the console consumed input
(meaning other systems should not process keyboard this frame).
"""
function update_debug_console!(input::InputState, dt::Float64)::Bool
    console = get_debug_console()

    # Track FPS
    if console._fps_display
        push!(console._frame_times, dt)
        if length(console._frame_times) > 120
            popfirst!(console._frame_times)
        end
    end

    # Toggle with backtick
    if is_key_just_pressed(input, KEY_GRAVE)
        console.active = !console.active
        console.input_buffer = ""
        console.history_index = 0
        return true
    end

    !console.active && return false

    # Process typed characters
    for ch in input.typed_chars
        ch == '`' && continue  # Skip the toggle key character
        console.input_buffer *= string(ch)
    end

    # Enter: execute command
    if is_key_just_pressed(input, Int(GLFW.KEY_ENTER))
        cmd = strip(console.input_buffer)
        if !isempty(cmd)
            push!(console.history, cmd)
            push!(console.output_lines, "> $cmd")
            result = execute_command!(cmd)
            if !isempty(result)
                for line in split(result, "\n")
                    push!(console.output_lines, string(line))
                end
            end
            # Trim output
            while length(console.output_lines) > console.max_output_lines
                popfirst!(console.output_lines)
            end
        end
        console.input_buffer = ""
        console.history_index = 0
    end

    # Backspace
    if is_key_just_pressed(input, Int(GLFW.KEY_BACKSPACE)) && !isempty(console.input_buffer)
        console.input_buffer = console.input_buffer[1:prevind(console.input_buffer, lastindex(console.input_buffer))]
    end

    # Up/Down: history navigation
    if is_key_just_pressed(input, Int(GLFW.KEY_UP)) && !isempty(console.history)
        if console.history_index == 0
            console.history_index = length(console.history)
        elseif console.history_index > 1
            console.history_index -= 1
        end
        console.input_buffer = console.history[console.history_index]
    end

    if is_key_just_pressed(input, Int(GLFW.KEY_DOWN))
        if console.history_index > 0 && console.history_index < length(console.history)
            console.history_index += 1
            console.input_buffer = console.history[console.history_index]
        else
            console.history_index = 0
            console.input_buffer = ""
        end
    end

    return true  # Console is active, consume input
end

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

"""
    render_debug_console!(ui_ctx)

Render the debug console overlay using the UI system.
"""
function render_debug_console!(ui_ctx)
    console = get_debug_console()

    # Always render watches (top-right corner)
    if !isempty(console.watches)
        y = 10.0f0
        for w in console.watches
            val = try w.getter() catch e "error" end
            ui_text(ui_ctx, "$(w.name): $val";
                    x=Float32(ui_ctx.width - 300), y=y, size=16,
                    color=RGB{Float32}(0.0, 1.0, 0.0))
            y += 20.0f0
        end
    end

    # FPS display
    if console._fps_display && !isempty(console._frame_times)
        avg_dt = sum(console._frame_times) / length(console._frame_times)
        fps = avg_dt > 0 ? round(Int, 1.0 / avg_dt) : 0
        ui_text(ui_ctx, "FPS: $fps";
                x=10.0f0, y=10.0f0, size=20,
                color=RGB{Float32}(1.0, 1.0, 0.0))
    end

    # Console overlay
    !console.active && return nothing

    box_height = min(400, ui_ctx.height ÷ 2)

    # Background
    ui_rect(ui_ctx; x=0, y=0, width=ui_ctx.width, height=box_height,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.9f0)

    # Output lines (scroll from bottom up)
    visible_lines = min(length(console.output_lines), (box_height - 40) ÷ 18)
    start_idx = max(1, length(console.output_lines) - visible_lines + 1)
    y = Float32(box_height - 35)
    for i in start_idx:length(console.output_lines)
        line = console.output_lines[i]
        color = startswith(line, ">") ?
            RGB{Float32}(0.7, 0.9, 1.0) :
            RGB{Float32}(0.8, 0.8, 0.8)
        ui_text(ui_ctx, line; x=10.0f0, y=y, size=14, color=color)
        y -= 18.0f0
    end

    # Input line
    input_y = Float32(box_height - 20)
    ui_rect(ui_ctx; x=0, y=input_y, width=ui_ctx.width, height=20,
            color=RGB{Float32}(0.1, 0.1, 0.2), alpha=0.95f0)
    ui_text(ui_ctx, "> $(console.input_buffer)_";
            x=10.0f0, y=input_y + 2.0f0, size=14,
            color=RGB{Float32}(1.0, 1.0, 1.0))

    return nothing
end
