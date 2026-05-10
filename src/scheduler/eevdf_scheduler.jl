# Engine-wide EEVDF task scheduler.
#
# OpenReality is parallel-first: every multi-threaded job in the engine
# (frame preparation, physics narrowphase, async asset loads, chunk
# streaming, future per-system parallelism) is submitted to a single
# `EEVDFScheduler` backed by a persistent worker-thread pool.
#
# EEVDF (Earliest Eligible Virtual Deadline First) is the fair-share
# scheduling discipline used by recent Linux kernels. Each task has a
# weight `w` and a service request (slice) `r`; its virtual deadline is
# `vd = vruntime + r/w`. Among eligible tasks (those with vruntime <=
# global virtual time `V`), the one with the smallest `vd` runs next.
# Higher-weight tasks therefore get shorter normalized deadlines and run
# sooner, which is exactly what we want for tight per-frame work like
# physics narrowphase versus background work like chunk streaming.
#
# Implementation notes:
# - The run-queue is a binary min-heap of `ScheduledTask` ordered by
#   `(deadline, enqueue_time)`. We hand-roll the heap to avoid pulling
#   in a new dependency.
# - Workers wait on a `Threads.Condition` for new tasks and pop the
#   current head of the heap when woken.
# - Each task records its actual runtime and updates its `vruntime`
#   (`+= Δt / weight`); the scheduler advances the global virtual time
#   to `max(V, task.vruntime)`. Newly enqueued tasks have their
#   `vruntime` clamped up to `V` so a long-idle requester cannot
#   burst-claim CPU at the expense of currently-running work.

# ---------------------------------------------------------------------------
# Min-heap helpers (ordering: smaller deadline first; FIFO on ties)
# ---------------------------------------------------------------------------

@inline function _task_lt(a::ScheduledTask, b::ScheduledTask)
    if a.deadline != b.deadline
        return a.deadline < b.deadline
    end
    return a.enqueue_time < b.enqueue_time
end

function _heap_push!(heap::Vector{ScheduledTask}, task::ScheduledTask)
    push!(heap, task)
    i = length(heap)
    while i > 1
        parent = i >> 1
        if _task_lt(heap[i], heap[parent])
            heap[i], heap[parent] = heap[parent], heap[i]
            i = parent
        else
            break
        end
    end
    return nothing
end

function _heap_pop!(heap::Vector{ScheduledTask})
    top = heap[1]
    last = pop!(heap)
    if !isempty(heap)
        heap[1] = last
        n = length(heap)
        i = 1
        while true
            l = 2i
            r = 2i + 1
            smallest = i
            if l <= n && _task_lt(heap[l], heap[smallest])
                smallest = l
            end
            if r <= n && _task_lt(heap[r], heap[smallest])
                smallest = r
            end
            smallest == i && break
            heap[i], heap[smallest] = heap[smallest], heap[i]
            i = smallest
        end
    end
    return top
end

# ---------------------------------------------------------------------------
# EEVDFScheduler
# ---------------------------------------------------------------------------

"""
    EEVDFScheduler

Engine-wide task scheduler implementing an EEVDF-style ordering on top of
a persistent worker-thread pool. Construct via [`init!`](@ref) and tear
down via [`shutdown!`](@ref). Submit work with [`submit_task!`](@ref) or
the data-parallel [`parallel_for`](@ref).
"""
mutable struct EEVDFScheduler
    queue::Vector{ScheduledTask}
    cond::Threads.Condition           # also acts as the queue lock
    virtual_time::Float64
    num_workers::Int
    workers::Vector{Task}
    running::Bool
end

function EEVDFScheduler()
    return EEVDFScheduler(ScheduledTask[], Threads.Condition(), 0.0, 0, Task[], false)
end

"""
    init!(sched::EEVDFScheduler; nworkers=Threads.nthreads()) -> EEVDFScheduler

Spawn the worker pool and start accepting work. Idempotent: calling on an
already-running scheduler is a no-op.
"""
function init!(sched::EEVDFScheduler; nworkers::Int=Threads.nthreads())
    sched.running && return sched
    nworkers = max(1, nworkers)
    sched.num_workers = nworkers
    sched.running = true
    sched.virtual_time = 0.0
    empty!(sched.queue)
    empty!(sched.workers)
    for wid in 1:nworkers
        worker = Threads.@spawn _worker_loop(sched, wid)
        push!(sched.workers, worker)
    end
    return sched
end

"""
    shutdown!(sched::EEVDFScheduler)

Stop the scheduler, wake all workers, and wait for them to exit. Any
remaining queued tasks are signaled with no-op completion (they never
run); callers waiting on those handles will return immediately. Idempotent.
"""
function shutdown!(sched::EEVDFScheduler)
    sched.running || return nothing
    lock(sched.cond)
    try
        sched.running = false
        notify(sched.cond, all=true)
    finally
        unlock(sched.cond)
    end
    for w in sched.workers
        try
            wait(w)
        catch e
            @warn "EEVDFScheduler worker exited with error" exception=e
        end
    end
    # Drain any leftover tasks: signal completion so blocked callers unblock.
    lock(sched.cond)
    try
        while !isempty(sched.queue)
            t = _heap_pop!(sched.queue)
            t.exception = ErrorException("EEVDFScheduler shut down before task ran")
            notify(t.done)
            if t.group !== nothing
                group_done!(t.group, t.exception)
            end
        end
    finally
        unlock(sched.cond)
    end
    empty!(sched.workers)
    sched.num_workers = 0
    return nothing
end

# ---------------------------------------------------------------------------
# Worker loop
# ---------------------------------------------------------------------------

function _worker_loop(sched::EEVDFScheduler, worker_id::Int)
    while true
        task = nothing
        lock(sched.cond)
        try
            while sched.running && isempty(sched.queue)
                wait(sched.cond)
            end
            if !sched.running && isempty(sched.queue)
                return
            end
            task = _heap_pop!(sched.queue)
        finally
            unlock(sched.cond)
        end

        task === nothing && continue

        t0 = time()
        try
            # Workers are long-lived `Threads.@spawn` tasks created in
            # `init!`, but most submissions come from closures defined
            # after that point in newer world ages. `invokelatest` lifts
            # the world-age constraint so a worker spawned at world N can
            # still execute callbacks compiled at world N+k.
            Base.invokelatest(task.fn)
        catch e
            task.exception = e
        end
        dt = time() - t0

        lock(sched.cond)
        try
            task.vruntime += dt / task.weight
            if task.vruntime > sched.virtual_time
                sched.virtual_time = task.vruntime
            end
        finally
            unlock(sched.cond)
        end

        notify(task.done)
        if task.group !== nothing
            group_done!(task.group, task.exception)
        end
    end
end

# ---------------------------------------------------------------------------
# Submission API
# ---------------------------------------------------------------------------

"""
    submit_task!(sched::EEVDFScheduler, fn; weight, slice=1e-3) -> TaskHandle
    submit_task!(fn, sched::EEVDFScheduler; weight, slice=1e-3) -> TaskHandle

Enqueue `fn` (zero-argument) on the scheduler. `weight` controls the EEVDF
fair-share priority (use the `W_*` constants); `slice` is the estimated
runtime in seconds and shapes the virtual deadline `vd = vruntime + slice/weight`.

Returns a [`TaskHandle`](@ref); call [`wait!`](@ref) to block until the
task finishes.
"""
function submit_task!(sched::EEVDFScheduler, fn::Function;
                      weight::Float64,
                      slice::Float64=1e-3,
                      group=nothing)
    sched.running || throw(ErrorException("EEVDFScheduler is not running; call init_scheduler!() first"))
    task = ScheduledTask(fn; weight=weight, slice=slice, group=group)
    lock(sched.cond)
    try
        if task.vruntime < sched.virtual_time
            task.vruntime = sched.virtual_time
        end
        task.deadline = task.vruntime + task.slice / task.weight
        task.enqueue_time = time()
        _heap_push!(sched.queue, task)
        notify(sched.cond)
    finally
        unlock(sched.cond)
    end
    return TaskHandle(task)
end

submit_task!(fn::Function, sched::EEVDFScheduler; kwargs...) =
    submit_task!(sched, fn; kwargs...)

# Internal helper used by `parallel_for` — same as `submit_task!` but does
# not require the caller to construct the public handle (the group handles
# join semantics).
function _submit_for_group!(sched::EEVDFScheduler, fn::Function;
                            weight::Float64,
                            slice::Float64,
                            group::TaskGroup)
    return submit_task!(sched, fn; weight=weight, slice=slice, group=group)
end

# ---------------------------------------------------------------------------
# parallel_for — data-parallel fan-out / join
# ---------------------------------------------------------------------------

"""
    parallel_for(f, sched::EEVDFScheduler, range; weight, slice=1e-3, chunks=nothing)

Run `f(i)` for each element `i` of `range` in parallel on the scheduler's
worker pool. Returns when every iteration has finished; rethrows the first
exception thrown by any iteration.

`weight` and `slice` parameterise every chunk task identically. `chunks`
defaults to the worker count (or the range length, whichever is smaller).

Falls back to a direct serial loop when:
- the scheduler is not running,
- `Threads.nthreads() == 1`, or
- `range` has 0 or 1 element,
to avoid task-spawn overhead. The body is invoked on the calling task in
that case.
"""
function parallel_for(f::Function, sched::EEVDFScheduler, range;
                      weight::Float64,
                      slice::Float64=1e-3,
                      chunks::Union{Nothing, Int}=nothing)
    n = length(range)
    n == 0 && return nothing

    if !sched.running || Threads.nthreads() == 1 || n == 1
        @inbounds for i in eachindex(range)
            f(range[i])
        end
        return nothing
    end

    nchunks = something(chunks, sched.num_workers)
    nchunks = max(1, min(nchunks, n))
    chunk_size = cld(n, nchunks)
    actual_chunks = cld(n, chunk_size)

    if actual_chunks <= 1
        @inbounds for i in eachindex(range)
            f(range[i])
        end
        return nothing
    end

    group = TaskGroup(actual_chunks)
    per_chunk_slice = slice / actual_chunks
    idx_pairs = collect(eachindex(range))
    for c in 1:actual_chunks
        lo = (c - 1) * chunk_size + 1
        hi = min(c * chunk_size, n)
        let lo=lo, hi=hi, idx_pairs=idx_pairs, range=range, f=f
            _submit_for_group!(sched,
                () -> begin
                    @inbounds for k in lo:hi
                        f(range[idx_pairs[k]])
                    end
                end;
                weight=weight, slice=per_chunk_slice, group=group)
        end
    end
    wait!(group)
    return nothing
end

"""
    parallel_for_chunks(f, sched::EEVDFScheduler, range; weight, slice=1e-3, chunks=nothing)

Chunked variant of [`parallel_for`](@ref). Splits `range` into `chunks`
contiguous slices and invokes `f(chunk_id::Int, slice_range)` once per
chunk on a worker. `chunk_id` is stable in `1:nchunks` and is intended for
indexing per-chunk accumulators that are merged on the calling thread
after the call returns.

Returns the actual number of chunks used (so callers can size accumulator
arrays exactly). Falls back to a single in-line invocation
(`f(1, eachindex(range))`) when the scheduler is unavailable or the input
is too small to benefit from fan-out.
"""
function parallel_for_chunks(f::Function, sched::EEVDFScheduler, range;
                             weight::Float64,
                             slice::Float64=1e-3,
                             chunks::Union{Nothing, Int}=nothing)
    n = length(range)
    n == 0 && return 0

    if !sched.running || Threads.nthreads() == 1 || n == 1
        f(1, eachindex(range))
        return 1
    end

    nchunks = something(chunks, sched.num_workers)
    nchunks = max(1, min(nchunks, n))
    chunk_size = cld(n, nchunks)
    actual_chunks = cld(n, chunk_size)

    if actual_chunks <= 1
        f(1, eachindex(range))
        return 1
    end

    group = TaskGroup(actual_chunks)
    per_chunk_slice = slice / actual_chunks
    idx = collect(eachindex(range))
    for c in 1:actual_chunks
        lo = (c - 1) * chunk_size + 1
        hi = min(c * chunk_size, n)
        cid = c
        let cid=cid, lo=lo, hi=hi, idx=idx, f=f
            _submit_for_group!(sched,
                () -> f(cid, view(idx, lo:hi));
                weight=weight, slice=per_chunk_slice, group=group)
        end
    end
    wait!(group)
    return actual_chunks
end
