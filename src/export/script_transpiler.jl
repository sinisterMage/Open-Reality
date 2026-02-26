# Julia → Rhai AST transpiler for web export.
#
# Takes a Julia `Expr` (captured by @webscript) and emits equivalent Rhai source code.
# Supports the subset of Julia used in OpenReality game scripts:
#   - Variables, assignments, arithmetic, comparisons
#   - if/elseif/else, for, while, return
#   - Function calls (get_component, has_component, etc.)
#   - ECS host API translation
#   - Vec3d, Quaterniond, RGB constructors
#   - Ref access (ref[], ref[] = val) → game_state API
#   - UI functions (ctx argument stripped)
#   - Array/Dict operations

"""
    transpile_to_rhai(expr::Expr) -> String

Transpile a Julia function/closure Expr to Rhai source code.
"""
function transpile_to_rhai(expr::Expr)
    io = IOBuffer()
    _transpile_expr(io, expr, 0)
    return String(take!(io))
end

# ── Entry point: handle function definitions ──

function _transpile_expr(io::IOBuffer, expr::Expr, indent::Int)
    if expr.head == :function || expr.head == :(->)
        _transpile_function(io, expr, indent)
    elseif expr.head == :block
        _transpile_block(io, expr, indent)
    elseif expr.head == :(=)
        _transpile_assignment(io, expr, indent)
    elseif expr.head == :if
        _transpile_if(io, expr, indent)
    elseif expr.head == :for
        _transpile_for(io, expr, indent)
    elseif expr.head == :while
        _transpile_while(io, expr, indent)
    elseif expr.head == :return
        _write_indent(io, indent)
        print(io, "return ")
        _transpile_value(io, expr.args[1], indent)
        println(io, ";")
    elseif expr.head == :call
        _write_indent(io, indent)
        _transpile_call(io, expr, indent)
        println(io, ";")
    elseif expr.head == :let
        _transpile_let(io, expr, indent)
    elseif expr.head == :(+=) || expr.head == :(-=) || expr.head == :(*=) || expr.head == :(/=)
        _transpile_compound_assign(io, expr, indent)
    elseif expr.head == :ref
        # Array/Ref indexing as statement
        _write_indent(io, indent)
        _transpile_ref_access(io, expr, indent)
        println(io, ";")
    elseif expr.head == :macrocall
        # Skip macros in transpilation (except @webscript which wraps)
        _write_indent(io, indent)
        println(io, "// Skipped macro: $(expr.args[1])")
    elseif expr.head == :local
        # local x = val → let x = val;
        if length(expr.args) >= 1 && expr.args[1] isa Expr && expr.args[1].head == :(=)
            _transpile_assignment(io, expr.args[1], indent)
        end
    elseif expr.head == :continue
        _write_indent(io, indent)
        println(io, "continue;")
    elseif expr.head == :break
        _write_indent(io, indent)
        println(io, "break;")
    else
        # Fallback: emit as value expression
        _write_indent(io, indent)
        _transpile_value(io, expr, indent)
        println(io, ";")
    end
end

function _transpile_expr(io::IOBuffer, val, indent::Int)
    # Non-Expr values (literals, symbols) as statements
    if val isa LineNumberNode
        return  # Skip line numbers
    end
    _write_indent(io, indent)
    _transpile_value(io, val, indent)
    println(io, ";")
end

# ── Function definition ──

function _transpile_function(io::IOBuffer, expr::Expr, indent::Int)
    if expr.head == :function
        # function(args...) body end
        sig = expr.args[1]
        body = expr.args[2]
        args = if sig isa Expr && sig.head == :tuple
            sig.args
        elseif sig isa Expr && sig.head == :call
            sig.args[2:end]  # Named function: skip name
        else
            Any[sig]
        end
    else
        # (args...) -> body (lambda)
        args_expr = expr.args[1]
        body = expr.args[2]
        args = if args_expr isa Expr && args_expr.head == :tuple
            args_expr.args
        else
            Any[args_expr]
        end
    end

    # Emit as Rhai closure: |arg1, arg2, ...| { body }
    arg_names = [_arg_name(a) for a in args]
    # Filter out 'ctx' argument (implicit in Rhai host API)
    filtered = filter(a -> a != "ctx", arg_names)

    _write_indent(io, indent)
    print(io, "|$(join(filtered, ", "))| {\n")
    _transpile_block(io, body, indent + 1)
    _write_indent(io, indent)
    println(io, "}")
end

function _arg_name(a)
    if a isa Symbol
        return string(a)
    elseif a isa Expr && a.head == :(::)
        return string(a.args[1])
    else
        return string(a)
    end
end

# ── Block ──

function _transpile_block(io::IOBuffer, expr::Expr, indent::Int)
    for stmt in expr.args
        if stmt isa LineNumberNode
            continue
        end
        _transpile_expr(io, stmt, indent)
    end
end

# ── Assignment ──

function _transpile_assignment(io::IOBuffer, expr::Expr, indent::Int)
    lhs = expr.args[1]
    rhs = expr.args[2]

    # Check for Ref assignment: ref[] = val → game_state_set("name", val)
    if lhs isa Expr && lhs.head == :ref
        _write_indent(io, indent)
        ref_name = string(lhs.args[1])
        print(io, "game_state_set(\"$ref_name\", ")
        _transpile_value(io, rhs, indent)
        println(io, ");")
        return
    end

    # Check for property assignment: obj.field = val → set_ref(obj, "field", val)
    if lhs isa Expr && lhs.head == :.
        obj = lhs.args[1]
        field = lhs.args[2]
        field_name = field isa QuoteNode ? string(field.value) : string(field)
        _write_indent(io, indent)
        print(io, "set_ref(")
        _transpile_value(io, obj, indent)
        print(io, ", \"$field_name\", ")
        _transpile_value(io, rhs, indent)
        println(io, ");")
        return
    end

    _write_indent(io, indent)
    print(io, "let $(string(lhs)) = ")
    _transpile_value(io, rhs, indent)
    println(io, ";")
end

# ── Compound assignment ──

function _transpile_compound_assign(io::IOBuffer, expr::Expr, indent::Int)
    lhs = expr.args[1]
    rhs = expr.args[2]
    op = string(expr.head)
    _write_indent(io, indent)
    _transpile_value(io, lhs, indent)
    print(io, " $op ")
    _transpile_value(io, rhs, indent)
    println(io, ";")
end

# ── If/elseif/else ──

function _transpile_if(io::IOBuffer, expr::Expr, indent::Int)
    cond = expr.args[1]
    then_branch = expr.args[2]

    _write_indent(io, indent)
    print(io, "if ")
    _transpile_value(io, cond, indent)
    println(io, " {")
    _transpile_block_or_expr(io, then_branch, indent + 1)
    _write_indent(io, indent)

    if length(expr.args) >= 3
        else_branch = expr.args[3]
        if else_branch isa Expr && else_branch.head == :elseif
            print(io, "} else ")
            _transpile_if(io, else_branch.args[1], indent)  # elseif wraps another if
        elseif else_branch isa Expr && else_branch.head == :if
            print(io, "} else ")
            _transpile_if(io, else_branch, indent)
        else
            println(io, "} else {")
            _transpile_block_or_expr(io, else_branch, indent + 1)
            _write_indent(io, indent)
            println(io, "}")
        end
    else
        println(io, "}")
    end
end

# ── For loop ──

function _transpile_for(io::IOBuffer, expr::Expr, indent::Int)
    iter_expr = expr.args[1]  # :(var = range)
    body = expr.args[2]

    var = string(iter_expr.args[1])
    range = iter_expr.args[2]

    _write_indent(io, indent)
    print(io, "for $var in ")
    _transpile_value(io, range, indent)
    println(io, " {")
    _transpile_block_or_expr(io, body, indent + 1)
    _write_indent(io, indent)
    println(io, "}")
end

# ── While loop ──

function _transpile_while(io::IOBuffer, expr::Expr, indent::Int)
    cond = expr.args[1]
    body = expr.args[2]

    _write_indent(io, indent)
    print(io, "while ")
    _transpile_value(io, cond, indent)
    println(io, " {")
    _transpile_block_or_expr(io, body, indent + 1)
    _write_indent(io, indent)
    println(io, "}")
end

# ── Let block ──

function _transpile_let(io::IOBuffer, expr::Expr, indent::Int)
    # let x = val; body end → { let x = val; body }
    for arg in expr.args
        _transpile_expr(io, arg, indent)
    end
end

# ── Value expressions (recursive) ──

function _transpile_value(io::IOBuffer, val::Number, indent::Int)
    if val isa Bool
        print(io, val ? "true" : "false")
    elseif val isa Integer
        print(io, val)
    else
        print(io, val)
    end
end

function _transpile_value(io::IOBuffer, val::Symbol, indent::Int)
    s = string(val)
    # Map Julia constants
    if s == "nothing"
        print(io, "()")
    elseif s == "true" || s == "false"
        print(io, s)
    elseif s == "pi" || s == "π"
        print(io, "3.141592653589793")
    else
        print(io, s)
    end
end

function _transpile_value(io::IOBuffer, val::String, indent::Int)
    print(io, "\"", escape_string(val), "\"")
end

function _transpile_value(io::IOBuffer, val::QuoteNode, indent::Int)
    # :symbol → "symbol" (string)
    print(io, "\"", string(val.value), "\"")
end

function _transpile_value(io::IOBuffer, val::LineNumberNode, indent::Int)
    # Skip
end

function _transpile_value(io::IOBuffer, val::Nothing, indent::Int)
    print(io, "()")
end

function _transpile_value(io::IOBuffer, expr::Expr, indent::Int)
    if expr.head == :call
        _transpile_call(io, expr, indent)
    elseif expr.head == :(.)
        _transpile_dot_access(io, expr, indent)
    elseif expr.head == :ref
        _transpile_ref_access(io, expr, indent)
    elseif expr.head == :comparison
        _transpile_comparison(io, expr, indent)
    elseif expr.head == :&&
        _transpile_value(io, expr.args[1], indent)
        print(io, " && ")
        _transpile_value(io, expr.args[2], indent)
    elseif expr.head == :||
        _transpile_value(io, expr.args[1], indent)
        print(io, " || ")
        _transpile_value(io, expr.args[2], indent)
    elseif expr.head == :if  # Ternary
        print(io, "if ")
        _transpile_value(io, expr.args[1], indent)
        print(io, " { ")
        _transpile_value(io, expr.args[2], indent)
        print(io, " } else { ")
        if length(expr.args) >= 3
            _transpile_value(io, expr.args[3], indent)
        else
            print(io, "()")
        end
        print(io, " }")
    elseif expr.head == :block
        # Inline block — emit last non-LineNumberNode value
        for arg in reverse(expr.args)
            if !(arg isa LineNumberNode)
                _transpile_value(io, arg, indent)
                return
            end
        end
    elseif expr.head == :vect
        # [a, b, c] → [a, b, c]
        print(io, "[")
        for (i, v) in enumerate(expr.args)
            i > 1 && print(io, ", ")
            _transpile_value(io, v, indent)
        end
        print(io, "]")
    elseif expr.head == :tuple
        print(io, "[")
        for (i, v) in enumerate(expr.args)
            i > 1 && print(io, ", ")
            _transpile_value(io, v, indent)
        end
        print(io, "]")
    elseif expr.head == :string
        # String interpolation: "text $(var) text"
        print(io, "\"")
        for part in expr.args
            if part isa String
                print(io, escape_string(part))
            else
                print(io, "\${")
                _transpile_value(io, part, indent)
                print(io, "}")
            end
        end
        print(io, "\"")
    elseif expr.head == :(->)
        # Lambda: (args...) -> body → |args| { body }
        _transpile_function(io, expr, indent)
    elseif expr.head == :kw
        # keyword arg: name=val → just use val for now
        _transpile_value(io, expr.args[2], indent)
    else
        # Fallback
        print(io, "/* unsupported: $(expr.head) */")
    end
end

# ── Function calls ──

# Map of Julia function names to Rhai equivalents
const _CALL_MAP = Dict{Symbol, String}(
    # ECS
    :get_component => "get_component",
    :has_component => "has_component",
    :entities_with_component => "entities_with",
    :first_entity_with_component => "first_entity_with",
    # Entity lifecycle
    :add_entity => "spawn",
    :remove_entity => "despawn",
    # Math constructors
    :Vec3d => "vec3",
    :Vec3f => "vec3",
    :Point3f => "vec3",
    :Quaterniond => "quat",
    :Quaternionf => "quat",
    # Math functions
    :sqrt => "sqrt",
    :sin => "sin",
    :cos => "cos",
    :tan => "tan",
    :abs => "abs",
    :min => "min",
    :max => "max",
    :clamp => "clamp",
    :floor => "floor",
    :ceil => "ceil",
    :round => "round",
    :atan => "atan",
    :atan2 => "atan",
    :norm => "length",
    :normalize => "normalize",
    :cross => "cross",
    :dot => "dot",
    :rand => "rand",
    # Array operations
    :length => "len",
    :isempty => "is_empty",
    :empty! => "clear",
    # String
    :string => "to_string",
    :parse => "parse",
    # Type conversions (no-op in Rhai)
    :Float32 => "",
    :Float64 => "",
    :Int32 => "to_int",
    :Int64 => "to_int",
)

# Functions that take ctx as first arg (strip it in Rhai)
const _CTX_STRIPPED_FUNS = Set{Symbol}([
    :ui_text, :ui_rect, :ui_button, :ui_progress_bar, :ui_image,
])

function _transpile_call(io::IOBuffer, expr::Expr, indent::Int)
    fn = expr.args[1]
    args = expr.args[2:end]

    # Filter out keyword parameter blocks
    actual_args = filter(a -> !(a isa Expr && a.head == :parameters), args)
    kw_params = filter(a -> a isa Expr && a.head == :parameters, args)

    fn_name = if fn isa Symbol
        fn
    elseif fn isa Expr && fn.head == :(.)
        # Module-qualified: OpenReality.foo → foo
        fn.args[end] isa QuoteNode ? fn.args[end].value : fn
    else
        fn
    end

    # Handle special cases
    if fn_name == :push!
        # push!(arr, val) → arr.push(val)
        _transpile_value(io, actual_args[1], indent)
        print(io, ".push(")
        _transpile_value(io, actual_args[2], indent)
        print(io, ")")
        return
    elseif fn_name == :pop!
        _transpile_value(io, actual_args[1], indent)
        print(io, ".pop()")
        return
    elseif fn_name == :delete!
        # delete!(dict, key) → dict.remove(key)
        _transpile_value(io, actual_args[1], indent)
        print(io, ".remove(")
        _transpile_value(io, actual_args[2], indent)
        print(io, ")")
        return
    elseif fn_name == :haskey
        # haskey(dict, key) → dict.contains_key(key)
        _transpile_value(io, actual_args[1], indent)
        print(io, ".contains_key(")
        _transpile_value(io, actual_args[2], indent)
        print(io, ")")
        return
    elseif fn_name == :println || fn_name == :print
        print(io, "print(")
        for (i, a) in enumerate(actual_args)
            i > 1 && print(io, " + ")
            _transpile_value(io, a, indent)
        end
        print(io, ")")
        return
    elseif fn_name == :RGB || fn_name == :RGBA
        print(io, "rgb(")
        for (i, a) in enumerate(actual_args)
            i > 1 && print(io, ", ")
            _transpile_value(io, a, indent)
        end
        print(io, ")")
        return
    elseif fn_name == :StateTransition
        # StateTransition(:state, defs) → transition("state")
        print(io, "transition(")
        _transpile_value(io, actual_args[1], indent)
        print(io, ")")
        return
    elseif fn_name == :Ref
        # Ref(val) → val (Refs become game_state in Rhai)
        if !isempty(actual_args)
            _transpile_value(io, actual_args[1], indent)
        else
            print(io, "()")
        end
        return
    elseif fn_name in _CTX_STRIPPED_FUNS
        # Strip ctx (first positional arg if it's :ctx or typed as Context)
        stripped = actual_args
        if !isempty(actual_args) && actual_args[1] isa Symbol && actual_args[1] == :ctx
            stripped = actual_args[2:end]
        end
        print(io, string(fn_name), "(")
        _emit_args(io, stripped, kw_params, indent)
        print(io, ")")
        return
    end

    # Check if fn_name is a type constructor used as get_component 2nd arg — handle inside
    rhai_name = get(_CALL_MAP, fn_name, nothing)

    if fn_name == :get_component || fn_name == :has_component || fn_name == :entities_with_component || fn_name == :first_entity_with_component
        # Second arg is a type name — convert to string
        mapped = get(_CALL_MAP, fn_name, string(fn_name))
        print(io, mapped, "(")
        if !isempty(actual_args)
            _transpile_value(io, actual_args[1], indent)
            for a in actual_args[2:end]
                print(io, ", ")
                if a isa Symbol
                    print(io, "\"", string(a), "\"")
                else
                    _transpile_value(io, a, indent)
                end
            end
        end
        print(io, ")")
        return
    end

    # No-op conversions (Float32, Float64 — just pass through the argument)
    if rhai_name == ""
        if !isempty(actual_args)
            _transpile_value(io, actual_args[1], indent)
        end
        return
    end

    # Standard mapped or unmapped call
    out_name = rhai_name !== nothing ? rhai_name : string(fn_name)
    print(io, out_name, "(")
    _emit_args(io, actual_args, kw_params, indent)
    print(io, ")")
end

function _emit_args(io::IOBuffer, args, kw_params, indent::Int)
    first = true
    for a in args
        if a isa Expr && a.head == :kw
            # Named arg: name=val → just val
            !first && print(io, ", ")
            _transpile_value(io, a.args[2], indent)
            first = false
        else
            !first && print(io, ", ")
            _transpile_value(io, a, indent)
            first = false
        end
    end
    # Keyword parameters from :parameters block
    for p in kw_params
        for kw in p.args
            if kw isa Expr && kw.head == :kw
                !first && print(io, ", ")
                _transpile_value(io, kw.args[2], indent)
                first = false
            end
        end
    end
end

# ── Dot access ──

function _transpile_dot_access(io::IOBuffer, expr::Expr, indent::Int)
    obj = expr.args[1]
    field = expr.args[2]
    field_name = field isa QuoteNode ? string(field.value) : string(field)
    print(io, "get_ref(")
    _transpile_value(io, obj, indent)
    print(io, ", \"", field_name, "\")")
end

# ── Ref access (indexing) ──

function _transpile_ref_access(io::IOBuffer, expr::Expr, indent::Int)
    obj = expr.args[1]
    if length(expr.args) == 1
        # ref[] → game_state_get("name")
        print(io, "game_state_get(\"", string(obj), "\")")
    else
        # arr[idx] → arr[idx]
        _transpile_value(io, obj, indent)
        print(io, "[")
        _transpile_value(io, expr.args[2], indent)
        print(io, "]")
    end
end

# ── Comparison chains ──

function _transpile_comparison(io::IOBuffer, expr::Expr, indent::Int)
    # Julia comparison chains: a < b < c → (a, <, b, <, c)
    for (i, arg) in enumerate(expr.args)
        if i > 1
            print(io, " ")
        end
        if arg isa Symbol
            s = string(arg)
            # Map Julia operators to Rhai
            if s == "==="
                print(io, "==")
            elseif s == "!=="
                print(io, "!=")
            else
                print(io, s)
            end
        else
            _transpile_value(io, arg, indent)
        end
    end
end

# ── Helpers ──

function _write_indent(io::IOBuffer, indent::Int)
    for _ in 1:indent
        print(io, "    ")
    end
end

function _transpile_block_or_expr(io::IOBuffer, val, indent::Int)
    if val isa Expr && val.head == :block
        _transpile_block(io, val, indent)
    else
        _transpile_expr(io, val, indent)
    end
end

"""
    validate_webscript(expr::Expr) -> Vector{String}

Check a Julia Expr for constructs that cannot be transpiled to Rhai.
Returns a list of warning/error messages (empty = all ok).
"""
function validate_webscript(expr::Expr)
    issues = String[]
    _validate_walk(issues, expr)
    return issues
end

function _validate_walk(issues::Vector{String}, expr::Expr)
    if expr.head == :macrocall && expr.args[1] != Symbol("@webscript")
        push!(issues, "Unsupported macro: $(expr.args[1])")
    elseif expr.head == :type || expr.head == :struct || expr.head == :abstract
        push!(issues, "Type definitions not supported in @webscript")
    elseif expr.head == :module
        push!(issues, "Module definitions not supported in @webscript")
    elseif expr.head == :ccall || expr.head == :foreigncall
        push!(issues, "ccall/foreigncall not supported in @webscript")
    elseif expr.head == :try
        push!(issues, "try/catch not supported in @webscript (use if-checks instead)")
    end

    for arg in expr.args
        if arg isa Expr
            _validate_walk(issues, arg)
        end
    end
end
