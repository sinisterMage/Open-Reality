# Global EEVDF scheduler singleton + per-system weight constants.
#
# The engine owns one `EEVDFScheduler` for its lifetime. The render loop
# warms it up via `init_scheduler!()` and tears it down via
# `shutdown_scheduler!()` in its `finally` block. Code that runs outside
# the render loop (tests, scripts) gets lazy initialization on the first
# `get_scheduler()` call.

# ---------------------------------------------------------------------------
# Default per-system weights
# ---------------------------------------------------------------------------
#
# Higher weight => earlier virtual deadline => runs sooner under contention.
# The numbers are coarse defaults tuned for a typical mixed frame:
#
#   physics  >  animation == default  >  particles == culling  >  async I/O == chunk gen
#
# Per-frame critical-path work (physics narrowphase) wins over background
# work (asset loading, terrain chunk generation) when both are queued at
# the same time. Tweak by editing this file; in a future release the
# weights may become tunable per call site, but no public API for that
# exists today.

"""Weight for physics narrowphase contact tests — highest priority."""
const W_PHYSICS::Float64 = 8.0

"""Weight for skeletal animation / blend trees / IK / skinning."""
const W_ANIMATION::Float64 = 4.0

"""Default weight for ad-hoc `submit_task!` / `parallel_for` calls."""
const W_DEFAULT::Float64 = 4.0

"""Weight for particle simulation."""
const W_PARTICLES::Float64 = 2.0

"""Weight for frustum culling, LOD selection, and entity classification."""
const W_CULLING::Float64 = 2.0

"""Weight for async asset I/O — runs in the background between frame work."""
const W_ASYNC_IO::Float64 = 1.0

"""Weight for procedural terrain chunk generation — background work."""
const W_CHUNK_GEN::Float64 = 1.0

# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

const _SCHEDULER = Ref{Union{EEVDFScheduler, Nothing}}(nothing)

"""
    get_scheduler() -> EEVDFScheduler

Return the global EEVDF scheduler, initializing it lazily on first access.
"""
function get_scheduler()::EEVDFScheduler
    sched = _SCHEDULER[]
    if sched === nothing
        sched = EEVDFScheduler()
        init!(sched)
        _SCHEDULER[] = sched
    elseif !sched.running
        init!(sched)
    end
    return sched
end

"""
    init_scheduler!(; nworkers=Threads.nthreads()) -> EEVDFScheduler

Eagerly initialize the global scheduler. Safe to call multiple times — a
running scheduler is returned as-is. Called by the render loop right
after backend initialization so the first frame doesn't pay the worker
spawn cost.
"""
function init_scheduler!(; nworkers::Int=Threads.nthreads())::EEVDFScheduler
    sched = _SCHEDULER[]
    if sched === nothing
        sched = EEVDFScheduler()
        _SCHEDULER[] = sched
    end
    if !sched.running
        init!(sched; nworkers=nworkers)
    end
    return sched
end

"""
    shutdown_scheduler!()

Tear down the global scheduler. Safe to call when no scheduler exists.
Called by the render loop's `finally` block so workers do not leak across
multiple `render(...)` invocations.
"""
function shutdown_scheduler!()
    sched = _SCHEDULER[]
    if sched !== nothing
        shutdown!(sched)
    end
    return nothing
end
