# Web export macros for the general-purpose Julia→Rhai transpilation pipeline.
#
# @webscript  — wraps a closure so it behaves normally in Julia but also
#               captures its source Expr for transpilation to Rhai.
# @webref     — marks a module-scope Ref for export as shared game state.
# @webstate   — marks an FSM state for web export.

"""Global registry: objectid(fn_val) => source Expr"""
const _WEBSCRIPT_REGISTRY = Dict{UInt, Expr}()

"""Global registry: variable name => (objectid, type hint)"""
const _WEBREF_REGISTRY = Dict{Symbol, Tuple{UInt, Symbol}}()

"""Global registry: state name => (state_type_expr, build_fn, ui_fn)"""
const _WEBSTATE_REGISTRY = Dict{Symbol, Tuple{Any, Symbol, Symbol}}()

"""
    @webscript expr

Wrap a function/closure so it works unchanged in native Julia, while also
storing its source `Expr` for automatic transpilation to Rhai during web export.

Usage:
```julia
enemy_ai = @webscript function(eid, dt, ctx)
    tc = get_component(eid, TransformComponent)
    # ... unchanged Julia code ...
end
```
"""
macro webscript(expr)
    quote
        let fn_val = $(esc(expr))
            OpenReality._WEBSCRIPT_REGISTRY[objectid(fn_val)] = $(QuoteNode(expr))
            fn_val
        end
    end
end

"""
    @webref name = Ref(initial_value)

Mark a module-scope Ref for export as shared game state in the web runtime.

Usage:
```julia
@webref player_hp = Ref(100.0)
@webref player_alive = Ref(true)
```
"""
macro webref(expr)
    if !(expr isa Expr && expr.head == :(=))
        error("@webref expects: @webref name = Ref(value)")
    end
    name = expr.args[1]
    rhs = expr.args[2]
    if !(name isa Symbol)
        error("@webref: LHS must be a symbol, got $(typeof(name))")
    end
    quote
        $(esc(expr))
        let ref_val = $(esc(name))
            # Determine type from the Ref's initial value
            val = ref_val[]
            type_hint = if val isa Float64 || val isa Float32
                :Float64
            elseif val isa Bool
                :Bool
            elseif val isa Integer
                :Int64
            elseif val isa AbstractString
                :String
            else
                :Any
            end
            OpenReality._WEBREF_REGISTRY[$(QuoteNode(name))] = (objectid(ref_val), type_hint)
        end
    end
end

"""
    @webstate state_name StateType(args...) build_fn ui_fn

Mark an FSM state for web export.

Usage:
```julia
@webstate :playing PlayingState(0.0) build_playing_scene get_playing_ui
```
"""
macro webstate(state_name, state_expr, build_fn, ui_fn)
    if !(state_name isa QuoteNode)
        error("@webstate: first arg must be a quoted symbol like :playing")
    end
    sname = state_name.value
    quote
        OpenReality._WEBSTATE_REGISTRY[$(QuoteNode(sname))] = (
            $(QuoteNode(state_expr)),
            $(QuoteNode(build_fn)),
            $(QuoteNode(ui_fn)),
        )
    end
end
