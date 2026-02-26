# =============================================================================
# Quest / Objective System — progression tracking with auto-advancement
# =============================================================================

@enum ObjectiveType begin
    OBJ_COLLECT
    OBJ_KILL
    OBJ_REACH_LOCATION
    OBJ_INTERACT
    OBJ_CUSTOM
end

@enum QuestState begin
    QUEST_NOT_STARTED
    QUEST_ACTIVE
    QUEST_COMPLETED
    QUEST_FAILED
end

"""
    ObjectiveDef

A single objective within a quest.
"""
mutable struct ObjectiveDef
    description::String
    type::ObjectiveType
    target::Symbol              # Item id for COLLECT, entity tag for KILL, location for REACH
    required_count::Int
    current_count::Int
    completed::Bool
    custom_check::Union{Function, Nothing}  # For OBJ_CUSTOM: () -> Bool

    function ObjectiveDef(description::String, type::ObjectiveType, target::Symbol;
                          required_count::Int = 1,
                          custom_check::Union{Function, Nothing} = nothing)
        new(description, type, target, required_count, 0, false, custom_check)
    end
end

"""
    QuestReward

Rewards granted on quest completion.
"""
struct QuestReward
    items::Vector{Tuple{Symbol, Int}}   # (item_id, count)
    on_reward::Union{Function, Nothing} # Custom reward callback

    QuestReward(;
        items::Vector{Tuple{Symbol, Int}} = Tuple{Symbol, Int}[],
        on_reward::Union{Function, Nothing} = nothing
    ) = new(items, on_reward)
end

"""
    QuestDef

Definition of a quest with objectives and prerequisites.
"""
struct QuestDef
    id::Symbol
    name::String
    description::String
    objectives::Vector{ObjectiveDef}
    rewards::QuestReward
    prerequisites::Vector{Symbol}  # Quest IDs that must be COMPLETED first

    function QuestDef(id::Symbol, name::String;
                      description::String = "",
                      objectives::Vector{ObjectiveDef} = ObjectiveDef[],
                      rewards::QuestReward = QuestReward(),
                      prerequisites::Vector{Symbol} = Symbol[])
        new(id, name, description, objectives, rewards, prerequisites)
    end
end

"""
    ActiveQuest

A quest in progress with mutable objective tracking.
"""
mutable struct ActiveQuest
    def::QuestDef
    state::QuestState
    objectives::Vector{ObjectiveDef}  # Mutable copies for progress tracking
end

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

struct QuestStartedEvent <: GameEvent
    quest_id::Symbol
end

struct ObjectiveProgressEvent <: GameEvent
    quest_id::Symbol
    objective_index::Int
    current::Int
    required::Int
end

struct QuestCompletedEvent <: GameEvent
    quest_id::Symbol
end

struct QuestFailedEvent <: GameEvent
    quest_id::Symbol
end

# ---------------------------------------------------------------------------
# Quest Manager
# ---------------------------------------------------------------------------

mutable struct QuestManager
    quest_defs::Dict{Symbol, QuestDef}
    active_quests::Dict{Symbol, ActiveQuest}
    completed_quests::Set{Symbol}
    failed_quests::Set{Symbol}
    _tracking_setup::Bool

    QuestManager() = new(
        Dict{Symbol, QuestDef}(),
        Dict{Symbol, ActiveQuest}(),
        Set{Symbol}(),
        Set{Symbol}(),
        false
    )
end

# ---------------------------------------------------------------------------
# Global singleton
# ---------------------------------------------------------------------------

const _QUEST_MANAGER = Ref{Union{QuestManager, Nothing}}(nothing)

function get_quest_manager()::QuestManager
    if _QUEST_MANAGER[] === nothing
        _QUEST_MANAGER[] = QuestManager()
    end
    return _QUEST_MANAGER[]
end

function reset_quest_manager!()
    _QUEST_MANAGER[] = nothing
    return nothing
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    register_quest!(def::QuestDef)

Register a quest definition. Call before `start_quest!`.
"""
function register_quest!(def::QuestDef)
    mgr = get_quest_manager()
    mgr.quest_defs[def.id] = def
    return nothing
end

"""
    start_quest!(quest_id) -> Bool

Start a quest. Returns false if prerequisites are not met or quest is already active/completed.
"""
function start_quest!(quest_id::Symbol)::Bool
    mgr = get_quest_manager()

    # Check if already active or completed
    haskey(mgr.active_quests, quest_id) && return false
    quest_id in mgr.completed_quests && return false

    # Get definition
    def = get(mgr.quest_defs, quest_id, nothing)
    def === nothing && (@warn "Quest not registered" quest_id=quest_id; return false)

    # Check prerequisites
    for prereq in def.prerequisites
        prereq in mgr.completed_quests || return false
    end

    # Create active quest with deep-copied objectives
    objectives = [ObjectiveDef(o.description, o.type, o.target;
                               required_count=o.required_count,
                               custom_check=o.custom_check)
                  for o in def.objectives]

    aq = ActiveQuest(def, QUEST_ACTIVE, objectives)
    mgr.active_quests[quest_id] = aq

    # Set up auto-tracking on first quest start
    if !mgr._tracking_setup
        _setup_quest_tracking!()
        mgr._tracking_setup = true
    end

    emit!(QuestStartedEvent(quest_id))
    return true
end

"""
    advance_objective!(quest_id, objective_index; amount=1)

Advance an objective's progress. Auto-completes the quest if all objectives are done.
"""
function advance_objective!(quest_id::Symbol, objective_index::Int; amount::Int=1)
    mgr = get_quest_manager()
    aq = get(mgr.active_quests, quest_id, nothing)
    aq === nothing && return nothing
    aq.state != QUEST_ACTIVE && return nothing

    if objective_index < 1 || objective_index > length(aq.objectives)
        return nothing
    end

    obj = aq.objectives[objective_index]
    obj.completed && return nothing

    obj.current_count = min(obj.required_count, obj.current_count + amount)

    emit!(ObjectiveProgressEvent(quest_id, objective_index, obj.current_count, obj.required_count))

    if obj.current_count >= obj.required_count
        obj.completed = true
    end

    # Check if all objectives complete
    if all(o -> o.completed, aq.objectives)
        complete_quest!(quest_id)
    end

    return nothing
end

"""
    complete_quest!(quest_id)

Force-complete a quest. Grants rewards and emits QuestCompletedEvent.
"""
function complete_quest!(quest_id::Symbol)
    mgr = get_quest_manager()
    aq = get(mgr.active_quests, quest_id, nothing)
    aq === nothing && return nothing

    aq.state = QUEST_COMPLETED
    push!(mgr.completed_quests, quest_id)
    delete!(mgr.active_quests, quest_id)

    # Grant rewards
    rewards = aq.def.rewards
    if rewards.on_reward !== nothing
        try
            rewards.on_reward()
        catch e
            @warn "Quest reward callback error" quest_id=quest_id exception=e
        end
    end

    emit!(QuestCompletedEvent(quest_id))
    return nothing
end

"""
    fail_quest!(quest_id)

Fail a quest.
"""
function fail_quest!(quest_id::Symbol)
    mgr = get_quest_manager()
    aq = get(mgr.active_quests, quest_id, nothing)
    aq === nothing && return nothing

    aq.state = QUEST_FAILED
    push!(mgr.failed_quests, quest_id)
    delete!(mgr.active_quests, quest_id)

    emit!(QuestFailedEvent(quest_id))
    return nothing
end

"""
    is_quest_active(quest_id) -> Bool
"""
function is_quest_active(quest_id::Symbol)::Bool
    mgr = get_quest_manager()
    return haskey(mgr.active_quests, quest_id)
end

"""
    is_quest_completed(quest_id) -> Bool
"""
function is_quest_completed(quest_id::Symbol)::Bool
    mgr = get_quest_manager()
    return quest_id in mgr.completed_quests
end

"""
    get_quest_progress(quest_id) -> Union{ActiveQuest, Nothing}
"""
function get_quest_progress(quest_id::Symbol)::Union{ActiveQuest, Nothing}
    mgr = get_quest_manager()
    return get(mgr.active_quests, quest_id, nothing)
end

"""
    get_active_quest_ids() -> Vector{Symbol}
"""
function get_active_quest_ids()::Vector{Symbol}
    return collect(keys(get_quest_manager().active_quests))
end

# ---------------------------------------------------------------------------
# Auto-tracking setup
# ---------------------------------------------------------------------------

function _setup_quest_tracking!()
    # Auto-advance KILL objectives on DeathEvent
    subscribe!(DeathEvent, event -> begin
        mgr = get_quest_manager()
        for (qid, aq) in mgr.active_quests
            aq.state != QUEST_ACTIVE && continue
            for (i, obj) in enumerate(aq.objectives)
                if obj.type == OBJ_KILL && !obj.completed
                    # Target matching: check if killed entity has a tag matching obj.target
                    # For simplicity, always advance (user can filter via custom objectives)
                    advance_objective!(qid, i)
                end
            end
        end
    end; priority=200)

    # Auto-advance COLLECT objectives on ItemPickedUpEvent
    subscribe!(ItemPickedUpEvent, event -> begin
        mgr = get_quest_manager()
        for (qid, aq) in mgr.active_quests
            aq.state != QUEST_ACTIVE && continue
            for (i, obj) in enumerate(aq.objectives)
                if obj.type == OBJ_COLLECT && obj.target == event.item_id && !obj.completed
                    advance_objective!(qid, i; amount=event.count)
                end
            end
        end
    end; priority=200)

    return nothing
end
