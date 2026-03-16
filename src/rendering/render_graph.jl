# Render Graph System
# Declarative render pass scheduling with typed resources, automatic pass culling,
# resource lifetime analysis, aliasing, and Vulkan barrier pre-computation.

# ---- Resource Format ----

"""
    RGFormat

Pixel format for render graph resources. Maps to GL/VK/WGPU formats in executors.
"""
@enum RGFormat begin
    RG_RGBA16F        # HDR color (G-buffer, lighting, SSR, TAA, bloom)
    RG_RGBA8          # LDR color (advanced material MRT)
    RG_RGBA8_SRGB     # sRGB swapchain target
    RG_RG16F          # Motion vectors / velocity buffer
    RG_R16F           # Single channel HDR (CoC)
    RG_R8             # Single channel LDR (SSAO)
    RG_DEPTH32F       # Depth (Vulkan/WebGPU)
    RG_DEPTH24        # Depth (OpenGL)
end

"""
    is_depth_format(fmt::RGFormat) -> Bool

Check if a format is a depth format.
"""
is_depth_format(fmt::RGFormat) = fmt == RG_DEPTH32F || fmt == RG_DEPTH24

# ---- Size Policy ----

"""
    RGSizePolicy

How a resource is sized. Either relative to the backbuffer (via `scale`) or
fixed pixel dimensions (via `fixed_width`/`fixed_height`).
"""
struct RGSizePolicy
    scale::Float32     # 1.0 = full res, 0.5 = half, etc. Ignored if fixed_width > 0
    fixed_width::Int   # If > 0, use fixed dimensions instead of scale
    fixed_height::Int
end

const FULL_RES = RGSizePolicy(1.0f0, 0, 0)
const HALF_RES = RGSizePolicy(0.5f0, 0, 0)
const QUARTER_RES = RGSizePolicy(0.25f0, 0, 0)

"""
    rg_fixed_size(w::Int, h::Int) -> RGSizePolicy

Create a fixed-size policy (e.g. for shadow maps).
"""
rg_fixed_size(w::Int, h::Int) = RGSizePolicy(0.0f0, w, h)

"""
    resolve_size(policy::RGSizePolicy, backbuffer_w::Int, backbuffer_h::Int) -> (Int, Int)

Compute actual pixel dimensions from a size policy.
"""
function resolve_size(policy::RGSizePolicy, backbuffer_w::Int, backbuffer_h::Int)
    if policy.fixed_width > 0
        return (policy.fixed_width, policy.fixed_height)
    else
        return (max(1, round(Int, backbuffer_w * policy.scale)),
                max(1, round(Int, backbuffer_h * policy.scale)))
    end
end

# ---- Resource Lifetime ----

"""
    RGLifetime

Classification of how long a resource lives.
"""
@enum RGLifetime begin
    RG_TRANSIENT      # Single frame, can be aliased with non-overlapping resources
    RG_PERSISTENT     # Survives across frames, owned by graph (resize-aware)
    RG_MULTI_FRAME    # Double-buffered (TAA history, motion blur prev frame)
    RG_IMPORTED       # Externally owned (swapchain, IBL cubemap) — not allocated/freed by graph
end

# ---- Resource Descriptor ----

"""
    RGResourceDesc

Describes a render graph resource: name, format, size, lifetime, optional clear value.
"""
struct RGResourceDesc
    name::Symbol
    format::RGFormat
    size_policy::RGSizePolicy
    lifetime::RGLifetime
    clear_value::Union{NTuple{4, Float32}, Nothing}
end

# ---- Resource Handle ----

"""
    RGResourceHandle

Lightweight handle to a resource in the render graph. Carries:
- `index`: O(1) lookup into `RenderGraph.resources`
- `format`: for compile-time validation
- `version`: incremented on each write for read-after-write tracking
"""
struct RGResourceHandle
    index::Int32
    format::RGFormat
    version::Int32
end

"""
    next_version(handle::RGResourceHandle) -> RGResourceHandle

Produce a new version of a resource handle (after a write).
"""
next_version(h::RGResourceHandle) = RGResourceHandle(h.index, h.format, h.version + Int32(1))

# Sentinel for "no resource"
const RG_NO_RESOURCE = RGResourceHandle(Int32(0), RG_RGBA8, Int32(0))

# ---- Resource Access Mode ----

"""
    RGAccessMode

How a pass accesses a resource.
"""
@enum RGAccessMode begin
    RG_READ           # Sampled as texture input
    RG_WRITE          # Rendered to as attachment (creates new version)
    RG_READ_WRITE     # Read-modify-write (e.g. blending onto existing target)
end

"""
    RGResourceUsage

A declared resource usage within a pass.
"""
struct RGResourceUsage
    handle::RGResourceHandle
    access::RGAccessMode
    attachment_index::Int  # -1 for sampled inputs, 0..N for color attachments, 99 for depth
end

# ---- Render Pass ----

"""
    RGPass

A render pass in the graph. Declares resource dependencies and carries an execute callback.
The `execute_fn` is dispatched via multiple dispatch: `(backend, ctx) -> nothing`.
"""
mutable struct RGPass
    name::Symbol
    reads::Vector{RGResourceUsage}
    writes::Vector{RGResourceUsage}
    enabled::Bool
    execute_fn::Function
    queue_type::Symbol     # :graphics, :compute, :transfer
end

# ---- Execute Context ----

"""
    RGExecuteContext

Per-frame data passed to pass execute callbacks. Provides access to frame data,
configuration, and physical GPU resources backing each RGResourceHandle.
"""
struct RGExecuteContext
    frame_data::FrameData
    post_config::PostProcessConfig
    physical_resources::Vector{Any}   # Index-aligned with graph.resources
    width::Int
    height::Int
    frame_index::Int                  # 0/1 for double-buffered resources
    prev_view_proj::Mat4f
    scene::Scene
    has_shadows::Bool
    light_space::Mat4f
end

"""
    get_resource(ctx::RGExecuteContext, handle::RGResourceHandle)

Type-safe accessor for the physical GPU resource backing a handle.
"""
get_resource(ctx::RGExecuteContext, handle::RGResourceHandle) = ctx.physical_resources[handle.index]

# ---- The Render Graph ----

"""
    RenderGraph

Declarative render graph: a collection of typed resources and passes that can be
compiled into an optimized execution order with pass culling and resource aliasing.
"""
mutable struct RenderGraph
    # Declaration phase
    resources::Vector{RGResourceDesc}
    passes::Vector{RGPass}

    # Compiled state
    compiled::Bool
    sorted_passes::Vector{Int}                     # Topological order (indices into passes[])
    resource_lifetimes::Vector{Tuple{Int, Int}}    # (first_use_order, last_use_order) per resource
    resource_aliases::Dict{Int, Int}               # resource_idx -> aliased_to_idx

    # Multi-frame double-buffering: alternates 0/1 each frame
    frame_index::Int

    # Validation
    errors::Vector{String}
    warnings::Vector{String}

    RenderGraph() = new(
        RGResourceDesc[], RGPass[],
        false, Int[], Tuple{Int, Int}[], Dict{Int, Int}(),
        0,
        String[], String[]
    )
end

"""
    advance_frame!(graph::RenderGraph)

Advance the frame index for double-buffered (RG_MULTI_FRAME) resources.
Call once per frame before execute_graph!.
"""
advance_frame!(graph::RenderGraph) = (graph.frame_index = 1 - graph.frame_index)

# ---- Builder API ----

"""
    declare_resource!(graph, name, format[, size]; lifetime, clear_value) -> RGResourceHandle

Declare a new resource in the graph. Returns a handle for connecting passes.
"""
function declare_resource!(graph::RenderGraph, name::Symbol, format::RGFormat,
                            size::RGSizePolicy=FULL_RES;
                            lifetime::RGLifetime=RG_TRANSIENT,
                            clear_value::Union{NTuple{4, Float32}, Nothing}=nothing)
    desc = RGResourceDesc(name, format, size, lifetime, clear_value)
    push!(graph.resources, desc)
    idx = Int32(length(graph.resources))
    return RGResourceHandle(idx, format, Int32(0))
end

"""
    import_resource!(graph, name, format[, size]) -> RGResourceHandle

Import an externally-owned resource (swapchain, IBL cubemap, etc.).
The graph will not allocate or free this resource.
"""
function import_resource!(graph::RenderGraph, name::Symbol, format::RGFormat,
                           size::RGSizePolicy=FULL_RES)
    return declare_resource!(graph, name, format, size; lifetime=RG_IMPORTED)
end

"""
    add_pass!(graph, name, execute_fn; reads, writes, read_writes, enabled, queue_type) -> RGPass

Register a render pass. Resource handles are provided as:
- `reads`: `Vector{RGResourceHandle}` — sampled as texture inputs
- `writes`: `Vector{Tuple{RGResourceHandle, Int}}` — rendered to (handle, attachment_index)
- `read_writes`: `Vector{Tuple{RGResourceHandle, Int}}` — read-modify-write
"""
function add_pass!(graph::RenderGraph, name::Symbol, execute_fn::Function;
                    reads::Vector{RGResourceHandle}=RGResourceHandle[],
                    writes::Vector{Tuple{RGResourceHandle, Int}}=Tuple{RGResourceHandle, Int}[],
                    read_writes::Vector{Tuple{RGResourceHandle, Int}}=Tuple{RGResourceHandle, Int}[],
                    enabled::Bool=true,
                    queue_type::Symbol=:graphics)
    read_usages = [RGResourceUsage(h, RG_READ, -1) for h in reads]
    write_usages = [RGResourceUsage(h, RG_WRITE, idx) for (h, idx) in writes]
    rw_usages = [RGResourceUsage(h, RG_READ_WRITE, idx) for (h, idx) in read_writes]

    all_reads = vcat(read_usages, rw_usages)
    all_writes = vcat(write_usages, rw_usages)

    pass = RGPass(name, all_reads, all_writes, enabled, execute_fn, queue_type)
    push!(graph.passes, pass)
    return pass
end

# ---- Validation ----

"""
    validate!(graph::RenderGraph) -> Bool

Validate the graph for errors: invalid handles, read-before-write, etc.
"""
function validate!(graph::RenderGraph)::Bool
    empty!(graph.errors)
    empty!(graph.warnings)
    n_resources = length(graph.resources)

    # Check handle validity
    for pass in graph.passes
        pass.enabled || continue
        for usage in vcat(pass.reads, pass.writes)
            idx = usage.handle.index
            if idx < 1 || idx > n_resources
                push!(graph.errors, "Pass :$(pass.name) references invalid resource index $idx")
            end
        end
    end

    # Check read-before-write: every resource that is read must be written
    # by some enabled pass, or be IMPORTED/MULTI_FRAME
    written_set = Set{Int32}()
    for pass in graph.passes
        pass.enabled || continue
        for usage in pass.writes
            push!(written_set, usage.handle.index)
        end
    end

    for pass in graph.passes
        pass.enabled || continue
        for usage in pass.reads
            ridx = usage.handle.index
            ridx < 1 || ridx > n_resources && continue
            desc = graph.resources[ridx]
            if ridx ∉ written_set && desc.lifetime ∉ (RG_IMPORTED, RG_MULTI_FRAME)
                push!(graph.errors, "Pass :$(pass.name) reads :$(desc.name) which is never written by an enabled pass")
            end
        end
    end

    return isempty(graph.errors)
end

# ---- Compilation ----

"""
    compile!(graph::RenderGraph) -> Bool

Compile the render graph: validate, topologically sort, cull unused passes,
compute resource lifetimes, and determine aliasing opportunities.
Returns `true` on success, `false` if validation or compilation fails.
"""
function compile!(graph::RenderGraph)::Bool
    graph.compiled = false
    empty!(graph.sorted_passes)
    empty!(graph.resource_lifetimes)
    empty!(graph.resource_aliases)

    # Step 1: Validate
    if !validate!(graph)
        return false
    end

    n_passes = length(graph.passes)
    n_resources = length(graph.resources)

    # Step 2: Pass culling via backward flood-fill from terminal passes
    # Terminal passes = those that write to IMPORTED resources (swapchain, etc.)
    active_passes = Set{Int}()

    for (i, pass) in enumerate(graph.passes)
        pass.enabled || continue
        for usage in pass.writes
            idx = usage.handle.index
            idx < 1 || idx > n_resources && continue
            if graph.resources[idx].lifetime == RG_IMPORTED
                push!(active_passes, i)
                break
            end
        end
    end

    # Flood backwards: if an active pass reads resource R, find the pass that writes R
    changed = true
    while changed
        changed = false
        for pi in collect(active_passes)
            pass = graph.passes[pi]
            for usage in pass.reads
                ridx = usage.handle.index
                # Find writer passes for this resource
                for (j, other) in enumerate(graph.passes)
                    other.enabled || continue
                    j ∈ active_passes && continue
                    for wu in other.writes
                        if wu.handle.index == ridx
                            push!(active_passes, j)
                            changed = true
                        end
                    end
                end
            end
        end
    end

    # Also include passes that write to MULTI_FRAME resources (TAA history)
    for (i, pass) in enumerate(graph.passes)
        pass.enabled || continue
        i ∈ active_passes && continue
        for usage in pass.writes
            idx = usage.handle.index
            idx < 1 || idx > n_resources && continue
            if graph.resources[idx].lifetime == RG_MULTI_FRAME
                push!(active_passes, i)
                break
            end
        end
    end

    culled = n_passes - length(active_passes)
    if culled > 0
        disabled = [graph.passes[i].name for i in 1:n_passes if i ∉ active_passes && graph.passes[i].enabled]
        if !isempty(disabled)
            push!(graph.warnings, "Culled $(length(disabled)) pass(es) with no consumers: $(join(disabled, ", "))")
        end
    end

    # Step 3: Topological sort (Kahn's algorithm) over active passes
    active_list = sort(collect(active_passes))
    active_set = Set(active_list)

    # Build adjacency: pass i → pass j if j reads a resource that i writes
    adj = Dict{Int, Vector{Int}}()
    in_degree = Dict{Int, Int}()
    for i in active_list
        adj[i] = Int[]
        in_degree[i] = 0
    end

    for i in active_list
        for j in active_list
            i == j && continue
            # Check if j reads something i writes
            connected = false
            for wu in graph.passes[i].writes
                for ru in graph.passes[j].reads
                    if wu.handle.index == ru.handle.index
                        connected = true
                        break
                    end
                end
                connected && break
            end
            if connected
                push!(adj[i], j)
                in_degree[j] = get(in_degree, j, 0) + 1
            end
        end
    end

    # Kahn's algorithm
    queue = Int[]
    for i in active_list
        if get(in_degree, i, 0) == 0
            push!(queue, i)
        end
    end

    sorted = Int[]
    while !isempty(queue)
        # Stable sort: pick the smallest index (preserves declaration order for ties)
        sort!(queue)
        node = popfirst!(queue)
        push!(sorted, node)
        for neighbor in get(adj, node, Int[])
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0
                push!(queue, neighbor)
            end
        end
    end

    if length(sorted) != length(active_list)
        push!(graph.errors, "Cycle detected in render graph (sorted $(length(sorted)) of $(length(active_list)) active passes)")
        return false
    end

    graph.sorted_passes = sorted

    # Step 4: Resource lifetime analysis
    graph.resource_lifetimes = [(typemax(Int), 0) for _ in 1:n_resources]
    for (order, pi) in enumerate(sorted)
        pass = graph.passes[pi]
        for usage in vcat(pass.reads, pass.writes)
            ridx = usage.handle.index
            ridx < 1 || ridx > n_resources && continue
            first_use, last_use = graph.resource_lifetimes[ridx]
            graph.resource_lifetimes[ridx] = (min(first_use, order), max(last_use, order))
        end
    end

    # Step 5: Resource aliasing for transient resources
    # Greedy: for each transient resource, try to alias with an earlier one
    # that has the same format+size and whose lifetime ended before this one starts
    for i in 1:n_resources
        desc_i = graph.resources[i]
        desc_i.lifetime != RG_TRANSIENT && continue
        first_i, _ = graph.resource_lifetimes[i]
        first_i == typemax(Int) && continue  # Resource never used

        for j in 1:(i - 1)
            j ∈ values(graph.resource_aliases) || j == i && continue
            desc_j = graph.resources[j]
            desc_j.lifetime != RG_TRANSIENT && continue
            _, last_j = graph.resource_lifetimes[j]
            last_j == 0 && continue  # Resource never used

            if last_j < first_i &&
               desc_i.format == desc_j.format &&
               desc_i.size_policy == desc_j.size_policy
                # Check that j isn't already aliased to something that overlaps with i
                target = get(graph.resource_aliases, j, j)
                _, target_last = graph.resource_lifetimes[target]
                if target_last < first_i
                    graph.resource_aliases[i] = target
                    break
                end
            end
        end
    end

    graph.compiled = true
    return true
end

# ---- Query API ----

"""
    get_active_passes(graph::RenderGraph) -> Vector{Symbol}

Return the names of passes in execution order (after compilation).
"""
function get_active_passes(graph::RenderGraph)
    @assert graph.compiled "Render graph not compiled"
    return [graph.passes[i].name for i in graph.sorted_passes]
end

"""
    get_active_resources(graph::RenderGraph) -> Vector{Symbol}

Return names of resources that are actually used by active passes.
"""
function get_active_resources(graph::RenderGraph)
    @assert graph.compiled "Render graph not compiled"
    used = Set{Int}()
    for pi in graph.sorted_passes
        pass = graph.passes[pi]
        for usage in vcat(pass.reads, pass.writes)
            push!(used, usage.handle.index)
        end
    end
    return [graph.resources[i].name for i in sort(collect(used))]
end

"""
    get_alias_count(graph::RenderGraph) -> Int

Number of resources aliased (sharing physical memory).
"""
get_alias_count(graph::RenderGraph) = length(graph.resource_aliases)

# ---- Debug Visualization ----

"""
    dump_graphviz(graph::RenderGraph) -> String

Generate a DOT/Graphviz representation of the compiled render graph.
"""
function dump_graphviz(graph::RenderGraph)::String
    @assert graph.compiled "Render graph not compiled"

    io = IOBuffer()
    println(io, "digraph RenderGraph {")
    println(io, "  rankdir=LR;")
    println(io, "  node [style=filled, fontsize=10];")
    println(io, "  edge [fontsize=8];")

    # Resource nodes (ellipses)
    used_resources = Set{Int}()
    for pi in graph.sorted_passes
        pass = graph.passes[pi]
        for u in vcat(pass.reads, pass.writes)
            push!(used_resources, u.handle.index)
        end
    end

    for i in sort(collect(used_resources))
        desc = graph.resources[i]
        color = if desc.lifetime == RG_TRANSIENT
            "#E8F5E9"
        elseif desc.lifetime == RG_PERSISTENT
            "#E3F2FD"
        elseif desc.lifetime == RG_MULTI_FRAME
            "#FFF3E0"
        else  # IMPORTED
            "#F3E5F5"
        end
        aliased = haskey(graph.resource_aliases, i) ? " (alias)" : ""
        println(io, "  r$(i) [shape=ellipse, label=\"$(desc.name)\\n$(desc.format)$(aliased)\", fillcolor=\"$(color)\"];")
    end

    # Pass nodes (boxes)
    for (order, pi) in enumerate(graph.sorted_passes)
        pass = graph.passes[pi]
        println(io, "  p$(pi) [shape=box, label=\"$(order). $(pass.name)\", fillcolor=\"#BBDEFB\"];")

        for usage in pass.reads
            style = usage.access == RG_READ_WRITE ? "bold" : "dashed"
            println(io, "  r$(usage.handle.index) -> p$(pi) [style=$(style)];")
        end
        for usage in pass.writes
            if usage.access != RG_READ_WRITE  # RW already shown as bold read edge
                println(io, "  p$(pi) -> r$(usage.handle.index) [style=solid];")
            else
                println(io, "  p$(pi) -> r$(usage.handle.index) [style=bold];")
            end
        end
    end

    # Aliasing edges
    for (from, to) in graph.resource_aliases
        println(io, "  r$(from) -> r$(to) [style=dotted, color=red, label=\"alias\"];")
    end

    println(io, "}")
    return String(take!(io))
end

# ---- Custom Pass Insertion API ----

"""
    insert_pass_after!(graph, after_name, name, execute_fn; reads, writes, read_writes, enabled, queue_type) -> Union{RGPass, Nothing}

Insert a custom pass into the graph, positioned after the named pass.
The graph must be recompiled after insertion. Returns the new pass, or nothing if `after_name` not found.
"""
function insert_pass_after!(graph::RenderGraph, after_name::Symbol, name::Symbol, execute_fn::Function;
                             reads::Vector{RGResourceHandle}=RGResourceHandle[],
                             writes::Vector{Tuple{RGResourceHandle, Int}}=Tuple{RGResourceHandle, Int}[],
                             read_writes::Vector{Tuple{RGResourceHandle, Int}}=Tuple{RGResourceHandle, Int}[],
                             enabled::Bool=true,
                             queue_type::Symbol=:graphics)
    # Find the position of after_name
    insert_idx = findfirst(p -> p.name == after_name, graph.passes)
    insert_idx === nothing && return nothing

    read_usages = [RGResourceUsage(h, RG_READ, -1) for h in reads]
    write_usages = [RGResourceUsage(h, RG_WRITE, idx) for (h, idx) in writes]
    rw_usages = [RGResourceUsage(h, RG_READ_WRITE, idx) for (h, idx) in read_writes]

    all_reads = vcat(read_usages, rw_usages)
    all_writes = vcat(write_usages, rw_usages)

    pass = RGPass(name, all_reads, all_writes, enabled, execute_fn, queue_type)
    insert!(graph.passes, insert_idx + 1, pass)

    # Graph needs recompilation
    graph.compiled = false
    return pass
end

"""
    insert_pass_before!(graph, before_name, name, execute_fn; ...) -> Union{RGPass, Nothing}

Insert a custom pass before the named pass. Requires recompilation.
"""
function insert_pass_before!(graph::RenderGraph, before_name::Symbol, name::Symbol, execute_fn::Function;
                              reads::Vector{RGResourceHandle}=RGResourceHandle[],
                              writes::Vector{Tuple{RGResourceHandle, Int}}=Tuple{RGResourceHandle, Int}[],
                              read_writes::Vector{Tuple{RGResourceHandle, Int}}=Tuple{RGResourceHandle, Int}[],
                              enabled::Bool=true,
                              queue_type::Symbol=:graphics)
    insert_idx = findfirst(p -> p.name == before_name, graph.passes)
    insert_idx === nothing && return nothing

    read_usages = [RGResourceUsage(h, RG_READ, -1) for h in reads]
    write_usages = [RGResourceUsage(h, RG_WRITE, idx) for (h, idx) in writes]
    rw_usages = [RGResourceUsage(h, RG_READ_WRITE, idx) for (h, idx) in read_writes]

    all_reads = vcat(read_usages, rw_usages)
    all_writes = vcat(write_usages, rw_usages)

    pass = RGPass(name, all_reads, all_writes, enabled, execute_fn, queue_type)
    insert!(graph.passes, insert_idx, pass)

    graph.compiled = false
    return pass
end

"""
    remove_pass!(graph, name) -> Bool

Remove a pass by name. Returns true if found and removed. Requires recompilation.
"""
function remove_pass!(graph::RenderGraph, name::Symbol)::Bool
    idx = findfirst(p -> p.name == name, graph.passes)
    idx === nothing && return false
    deleteat!(graph.passes, idx)
    graph.compiled = false
    return true
end

"""
    set_pass_enabled!(graph, name, enabled) -> Bool

Enable or disable a pass by name. Returns true if found. Requires recompilation.
"""
function set_pass_enabled!(graph::RenderGraph, name::Symbol, enabled::Bool)::Bool
    idx = findfirst(p -> p.name == name, graph.passes)
    idx === nothing && return false
    graph.passes[idx].enabled = enabled
    graph.compiled = false
    return true
end

"""
    get_pass(graph, name) -> Union{RGPass, Nothing}

Look up a pass by name.
"""
function get_pass(graph::RenderGraph, name::Symbol)
    idx = findfirst(p -> p.name == name, graph.passes)
    idx === nothing && return nothing
    return graph.passes[idx]
end

"""
    get_resource_handle(graph, name) -> Union{RGResourceHandle, Nothing}

Look up a resource handle by name (for connecting custom passes to existing resources).
"""
function get_resource_handle(graph::RenderGraph, name::Symbol)
    idx = findfirst(r -> r.name == name, graph.resources)
    idx === nothing && return nothing
    desc = graph.resources[idx]
    return RGResourceHandle(Int32(idx), desc.format, Int32(0))
end

# ---- GPU Timing / Profiler Integration ----

"""
    RGPassTiming

GPU timing data for a single pass execution.
"""
struct RGPassTiming
    name::Symbol
    gpu_ms::Float64    # GPU time in milliseconds (from timestamp queries)
    cpu_ms::Float64    # CPU time in milliseconds (from time_ns)
end

"""
    RGFrameTiming

All pass timings for a single frame.
"""
struct RGFrameTiming
    pass_timings::Vector{RGPassTiming}
    total_gpu_ms::Float64
    total_cpu_ms::Float64
end

"""
    RGTimingState

Manages per-pass timing state across frames. Backends populate gpu_ms
via their timestamp query mechanisms; CPU timing is automatic.
"""
mutable struct RGTimingState
    enabled::Bool
    current_frame::Vector{RGPassTiming}
    history::Vector{RGFrameTiming}
    history_size::Int
    _write_idx::Int

    RGTimingState(; history_size::Int=120) = new(
        false, RGPassTiming[], Vector{RGFrameTiming}(undef, history_size),
        history_size, 0
    )
end

# Global timing state
const _RG_TIMING = Ref{RGTimingState}(RGTimingState())

"""
    rg_timing_enable!(enabled::Bool=true)

Enable/disable per-pass GPU+CPU timing for the render graph.
"""
rg_timing_enable!(enabled::Bool=true) = (_RG_TIMING[].enabled = enabled)

"""
    rg_timing_enabled() -> Bool

Check if render graph timing is enabled.
"""
rg_timing_enabled() = _RG_TIMING[].enabled

"""
    rg_timing_begin_frame!()

Begin timing a new frame. Called automatically by execute_graph! when timing is enabled.
"""
function rg_timing_begin_frame!()
    empty!(_RG_TIMING[].current_frame)
end

"""
    rg_timing_record!(name::Symbol, cpu_ms::Float64, gpu_ms::Float64=0.0)

Record a pass timing. Called by executors after each pass.
"""
function rg_timing_record!(name::Symbol, cpu_ms::Float64, gpu_ms::Float64=0.0)
    push!(_RG_TIMING[].current_frame, RGPassTiming(name, gpu_ms, cpu_ms))
end

"""
    rg_timing_end_frame!()

Finalize the current frame's timing and store in history ring buffer.
"""
function rg_timing_end_frame!()
    ts = _RG_TIMING[]
    timings = copy(ts.current_frame)
    total_gpu = sum(t.gpu_ms for t in timings; init=0.0)
    total_cpu = sum(t.cpu_ms for t in timings; init=0.0)

    ts._write_idx = (ts._write_idx % ts.history_size) + 1
    ts.history[ts._write_idx] = RGFrameTiming(timings, total_gpu, total_cpu)
end

"""
    rg_timing_get_latest() -> Union{RGFrameTiming, Nothing}

Get the most recent frame's timing data.
"""
function rg_timing_get_latest()
    ts = _RG_TIMING[]
    ts._write_idx == 0 && return nothing
    return ts.history[ts._write_idx]
end

"""
    rg_timing_get_average(n::Int=60) -> Union{RGFrameTiming, Nothing}

Get averaged timing data over the last n frames.
"""
function rg_timing_get_average(n::Int=60)
    ts = _RG_TIMING[]
    ts._write_idx == 0 && return nothing

    count = min(n, ts._write_idx)
    count == 0 && return nothing

    # Collect frames
    frames = RGFrameTiming[]
    for i in 1:count
        idx = ((ts._write_idx - i) % ts.history_size) + 1
        if isassigned(ts.history, idx)
            push!(frames, ts.history[idx])
        end
    end
    isempty(frames) && return nothing

    # Average pass timings (align by name)
    all_names = unique(vcat([t.name for f in frames for t in f.pass_timings]...))
    avg_timings = RGPassTiming[]
    for name in all_names
        gpu_sum = 0.0
        cpu_sum = 0.0
        cnt = 0
        for f in frames
            for t in f.pass_timings
                if t.name == name
                    gpu_sum += t.gpu_ms
                    cpu_sum += t.cpu_ms
                    cnt += 1
                end
            end
        end
        if cnt > 0
            push!(avg_timings, RGPassTiming(name, gpu_sum / cnt, cpu_sum / cnt))
        end
    end

    total_gpu = sum(t.gpu_ms for t in avg_timings; init=0.0)
    total_cpu = sum(t.cpu_ms for t in avg_timings; init=0.0)
    return RGFrameTiming(avg_timings, total_gpu, total_cpu)
end

# ---- Async Compute Helpers ----

"""
    mark_compute!(graph, name) -> Bool

Mark a pass as a compute pass (`:compute` queue). For Vulkan, compute passes
can overlap with graphics on a separate queue. For OpenGL/WebGPU, this is
informational only (no actual async execution).
"""
function mark_compute!(graph::RenderGraph, name::Symbol)::Bool
    pass = get_pass(graph, name)
    pass === nothing && return false
    pass.queue_type = :compute
    graph.compiled = false
    return true
end

"""
    get_compute_passes(graph::RenderGraph) -> Vector{Symbol}

Return names of all passes marked as `:compute`.
"""
function get_compute_passes(graph::RenderGraph)
    return [p.name for p in graph.passes if p.queue_type == :compute]
end
