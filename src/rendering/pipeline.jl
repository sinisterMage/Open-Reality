# Rendering pipeline

"""
    RenderPipeline

Manages the rendering pipeline stages and backend lifecycle.
"""
mutable struct RenderPipeline
    backend::AbstractBackend
    active::Bool
    # Optional render graph (populated by backend during initialization if use_render_graph=true)
    render_graph::Union{RenderGraph, Nothing}
    executor::Union{AbstractGraphExecutor, Nothing}

    RenderPipeline(backend::AbstractBackend) = new(backend, false, nothing, nothing)
end

"""
    execute!(pipeline::RenderPipeline, scene::Scene)

Execute the rendering pipeline for the given scene.
Auto-initializes the backend on first call.
"""
function execute!(pipeline::RenderPipeline, scene::Scene)
    if !pipeline.active
        initialize!(pipeline.backend)
        pipeline.active = true
    end
    render_frame!(pipeline.backend, scene)
end

"""
    shutdown!(pipeline::RenderPipeline)

Shutdown the rendering pipeline and its backend.
"""
function shutdown!(pipeline::RenderPipeline)
    if pipeline.active
        shutdown!(pipeline.backend)
        pipeline.active = false
    end
end
