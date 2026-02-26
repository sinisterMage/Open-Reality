# =============================================================================
# Dialogue System — branching dialogue trees with conditional choices
# =============================================================================

"""
    DialogueChoice

A player choice within a dialogue node.
"""
struct DialogueChoice
    text::String
    next_node_id::Symbol                  # :end to terminate dialogue
    condition::Union{Function, Nothing}   # () -> Bool; nothing = always available
    on_select::Union{Function, Nothing}   # Side effect callback
end

DialogueChoice(text::String, next::Symbol;
               condition=nothing, on_select=nothing) =
    DialogueChoice(text, next, condition, on_select)

"""
    DialogueNode

A single node in a dialogue tree — one "screen" of dialogue.
"""
mutable struct DialogueNode
    id::Symbol
    speaker::String
    text::String
    choices::Vector{DialogueChoice}
    on_enter::Union{Function, Nothing}
    auto_advance::Union{Symbol, Nothing}  # If set, auto-advance to this node (narration)
end

function DialogueNode(id::Symbol, speaker::String, text::String;
                      choices::Vector{DialogueChoice} = DialogueChoice[],
                      on_enter::Union{Function, Nothing} = nothing,
                      auto_advance::Union{Symbol, Nothing} = nothing)
    DialogueNode(id, speaker, text, choices, on_enter, auto_advance)
end

"""
    DialogueTree

A complete dialogue sequence.
"""
struct DialogueTree
    nodes::Dict{Symbol, DialogueNode}
    start_node::Symbol
end

function DialogueTree(nodes::Vector{DialogueNode})
    dict = Dict{Symbol, DialogueNode}()
    for node in nodes
        dict[node.id] = node
    end
    isempty(nodes) && error("DialogueTree must have at least one node")
    DialogueTree(dict, nodes[1].id)
end

function DialogueTree(start::Symbol, nodes::Vector{DialogueNode})
    dict = Dict{Symbol, DialogueNode}()
    for node in nodes
        dict[node.id] = node
    end
    DialogueTree(dict, start)
end

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

struct DialogueStartedEvent <: GameEvent
    tree_id::Symbol
end

struct DialogueChoiceEvent <: GameEvent
    node_id::Symbol
    choice_index::Int
    choice_text::String
end

struct DialogueEndedEvent <: GameEvent
    tree_id::Symbol
end

# ---------------------------------------------------------------------------
# Dialogue Manager
# ---------------------------------------------------------------------------

mutable struct DialogueManager
    current_tree::Union{DialogueTree, Nothing}
    current_node::Union{DialogueNode, Nothing}
    active::Bool
    tree_id::Symbol
    _available_choices::Vector{DialogueChoice}

    DialogueManager() = new(nothing, nothing, false, :none, DialogueChoice[])
end

# ---------------------------------------------------------------------------
# Global singleton
# ---------------------------------------------------------------------------

const _DIALOGUE_MANAGER = Ref{Union{DialogueManager, Nothing}}(nothing)

function get_dialogue_manager()::DialogueManager
    if _DIALOGUE_MANAGER[] === nothing
        _DIALOGUE_MANAGER[] = DialogueManager()
    end
    return _DIALOGUE_MANAGER[]
end

function reset_dialogue_manager!()
    _DIALOGUE_MANAGER[] = nothing
    return nothing
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    start_dialogue!(tree; id=:dialogue)

Start a dialogue sequence. Emits DialogueStartedEvent.
"""
function start_dialogue!(tree::DialogueTree; id::Symbol=:dialogue)
    dm = get_dialogue_manager()
    dm.current_tree = tree
    dm.tree_id = id
    dm.active = true
    _advance_to_node!(dm, tree.start_node)
    emit!(DialogueStartedEvent(id))
    return nothing
end

"""
    select_choice!(index::Int)

Select a dialogue choice by index (1-based). Advances to the next node.
"""
function select_choice!(index::Int)
    dm = get_dialogue_manager()
    !dm.active && return nothing
    (index < 1 || index > length(dm._available_choices)) && return nothing

    choice = dm._available_choices[index]

    emit!(DialogueChoiceEvent(
        dm.current_node !== nothing ? dm.current_node.id : :unknown,
        index, choice.text))

    if choice.on_select !== nothing
        try
            choice.on_select()
        catch e
            @warn "Dialogue on_select error" exception=e
        end
    end

    _advance_to_node!(dm, choice.next_node_id)
    return nothing
end

"""
    advance!()

Advance narration nodes (those with `auto_advance` set and no choices).
"""
function advance!()
    dm = get_dialogue_manager()
    !dm.active && return nothing
    dm.current_node === nothing && return nothing
    if dm.current_node.auto_advance !== nothing
        _advance_to_node!(dm, dm.current_node.auto_advance)
    elseif isempty(dm._available_choices) && isempty(dm.current_node.choices)
        # No choices and no auto_advance: end dialogue
        end_dialogue!()
    end
    return nothing
end

"""
    end_dialogue!()

End the current dialogue. Emits DialogueEndedEvent.
"""
function end_dialogue!()
    dm = get_dialogue_manager()
    tree_id = dm.tree_id
    dm.active = false
    dm.current_tree = nothing
    dm.current_node = nothing
    empty!(dm._available_choices)
    emit!(DialogueEndedEvent(tree_id))
    return nothing
end

"""
    is_dialogue_active() -> Bool
"""
function is_dialogue_active()::Bool
    return get_dialogue_manager().active
end

"""
    get_current_dialogue_node() -> Union{DialogueNode, Nothing}
"""
function get_current_dialogue_node()
    return get_dialogue_manager().current_node
end

"""
    get_available_choices() -> Vector{DialogueChoice}
"""
function get_available_choices()
    return get_dialogue_manager()._available_choices
end

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

function _advance_to_node!(dm::DialogueManager, node_id::Symbol)
    if node_id == :end || dm.current_tree === nothing ||
       !haskey(dm.current_tree.nodes, node_id)
        end_dialogue!()
        return nothing
    end

    node = dm.current_tree.nodes[node_id]
    dm.current_node = node

    # Filter choices by conditions
    dm._available_choices = filter(node.choices) do c
        c.condition === nothing || (try c.condition()::Bool catch; false end)
    end

    if node.on_enter !== nothing
        try
            node.on_enter()
        catch e
            @warn "Dialogue on_enter error" exception=e
        end
    end

    return nothing
end

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

"""
    update_dialogue_input!(input::InputState) -> Bool

Process dialogue input. Returns `true` if dialogue consumed input.
"""
function update_dialogue_input!(input::InputState)::Bool
    dm = get_dialogue_manager()
    !dm.active && return false

    # Number keys 1-9 select choices
    for i in 1:min(9, length(dm._available_choices))
        key = 48 + i  # GLFW.KEY_1 = 49, KEY_2 = 50, etc.
        if is_key_just_pressed(input, key)
            select_choice!(i)
            return true
        end
    end

    # Space/Enter advances narration nodes
    if is_key_just_pressed(input, 32) || is_key_just_pressed(input, 257)  # SPACE=32, ENTER=257
        if isempty(dm._available_choices)
            advance!()
        end
        return true
    end

    return true  # Consume all input while dialogue active
end

# ---------------------------------------------------------------------------
# Rendering helper
# ---------------------------------------------------------------------------

"""
    render_dialogue!(ui_ctx)

Render the dialogue box using the UI system.
"""
function render_dialogue!(ui_ctx)
    dm = get_dialogue_manager()
    !dm.active && return nothing
    dm.current_node === nothing && return nothing

    box_height = 200
    box_y = Float32(ui_ctx.height - box_height)
    box_width = Float32(ui_ctx.width - 40)

    # Background
    ui_rect(ui_ctx; x=20.0f0, y=box_y, width=box_width, height=Float32(box_height - 20),
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.85f0)

    # Speaker name
    ui_text(ui_ctx, dm.current_node.speaker;
            x=40.0f0, y=box_y + 10.0f0, size=26,
            color=RGB{Float32}(1.0, 0.85, 0.2))

    # Dialogue text
    ui_text(ui_ctx, dm.current_node.text;
            x=40.0f0, y=box_y + 42.0f0, size=20,
            color=RGB{Float32}(1.0, 1.0, 1.0))

    # Choices
    for (i, choice) in enumerate(dm._available_choices)
        choice_y = box_y + 80.0f0 + Float32((i - 1) * 28)
        label = "[$i] $(choice.text)"
        ui_text(ui_ctx, label;
                x=60.0f0, y=choice_y, size=18,
                color=RGB{Float32}(0.7, 0.9, 1.0))
    end

    # Show "Press Space to continue" for narration nodes
    if isempty(dm._available_choices) && dm.current_node.auto_advance !== nothing
        ui_text(ui_ctx, "Press Space to continue...";
                x=40.0f0, y=box_y + Float32(box_height - 45), size=14,
                color=RGB{Float32}(0.5, 0.5, 0.6))
    end

    return nothing
end
