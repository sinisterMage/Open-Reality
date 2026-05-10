# EEVDF task types — units of work managed by `EEVDFScheduler`.
#
# A `ScheduledTask` is the internal record the scheduler keeps per submission.
# A `TaskHandle` is the public completion handle returned by `submit_task!`.
# A `TaskGroup` is a multi-task barrier used by `parallel_for` to fan out
# work and join on the calling thread.

"""
    ScheduledTask

Internal scheduler record for one unit of work.

Fields:
- `fn`            : the function to run (zero-argument).
- `weight`        : EEVDF weight (higher = larger fair-share). See the
                    `W_*` constants in `src/scheduler/global.jl`.
- `slice`         : estimated runtime in seconds. Affects only the virtual
                    deadline `vd = vruntime + slice/weight`; the task is not
                    pre-empted if it overshoots.
- `vruntime`      : accumulated virtual runtime. Advanced by `Δt/weight`
                    each time the task runs.
- `deadline`      : virtual deadline used to order the run-queue.
- `enqueue_time`  : wallclock submission time (FIFO tiebreaker).
- `done`          : signaled exactly once when the task finishes (success
                    or failure).
- `exception`     : captured exception if the task threw, otherwise
                    `nothing`.
- `group`         : optional `TaskGroup` to notify on completion (used by
                    `parallel_for`). May be `nothing`.
"""
mutable struct ScheduledTask
    fn::Function
    weight::Float64
    slice::Float64
    vruntime::Float64
    deadline::Float64
    enqueue_time::Float64
    done::Threads.Event
    exception::Union{Nothing, Any}
    group::Any  # ::Union{Nothing, TaskGroup} — forward-declared
end

function ScheduledTask(fn::Function;
                       weight::Float64,
                       slice::Float64,
                       group=nothing)
    weight > 0.0 || throw(ArgumentError("ScheduledTask weight must be > 0, got $weight"))
    slice >= 0.0 || throw(ArgumentError("ScheduledTask slice must be >= 0, got $slice"))
    return ScheduledTask(fn, weight, slice, 0.0, 0.0, time(),
                         Threads.Event(), nothing, group)
end

"""
    TaskHandle

Public completion handle for a submitted task. Use [`wait!`](@ref) to block
until the task finishes; if the task threw, `wait!` rethrows on the caller.
"""
struct TaskHandle
    task::ScheduledTask
end

"""
    wait!(handle::TaskHandle)

Block until the task completes. Rethrows any exception that occurred inside
the scheduled function.
"""
function wait!(handle::TaskHandle)
    wait(handle.task.done)
    if handle.task.exception !== nothing
        throw(handle.task.exception)
    end
    return nothing
end

"""
    TaskGroup

Barrier used by `parallel_for` to fan out work and join on the caller. A
group tracks `pending` outstanding child tasks; when the last child
completes, `done` is signaled. Exceptions thrown by any child are collected
and rethrown by `wait!(group)`.
"""
mutable struct TaskGroup
    pending::Threads.Atomic{Int}
    done::Threads.Event
    exceptions::Vector{Any}
    exc_lock::ReentrantLock
end

function TaskGroup(n::Int)
    n >= 0 || throw(ArgumentError("TaskGroup size must be >= 0, got $n"))
    g = TaskGroup(Threads.Atomic{Int}(n), Threads.Event(), Any[], ReentrantLock())
    n == 0 && notify(g.done)
    return g
end

"""
    group_done!(group::TaskGroup, exc=nothing)

Mark one outstanding task as finished. If `exc` is non-`nothing` it is
recorded for later re-throwing by `wait!(group)`. When the last pending
task completes, the group's `done` event is signaled.
"""
function group_done!(group::TaskGroup, exc=nothing)
    if exc !== nothing
        lock(group.exc_lock)
        try
            push!(group.exceptions, exc)
        finally
            unlock(group.exc_lock)
        end
    end
    if Threads.atomic_sub!(group.pending, 1) == 1
        notify(group.done)
    end
    return nothing
end

"""
    wait!(group::TaskGroup)

Block until every task in the group has completed. Rethrows the first
exception captured (subsequent exceptions are accessible via
`group.exceptions`).
"""
function wait!(group::TaskGroup)
    wait(group.done)
    if !isempty(group.exceptions)
        throw(group.exceptions[1])
    end
    return nothing
end
