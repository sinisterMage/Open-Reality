# Render Graph Executor — Abstract interface
# Each backend provides a concrete executor that handles physical resource
# allocation, barrier insertion, and pass dispatch.

"""
    AbstractGraphExecutor

Abstract executor for the render graph. Backend-specific subtypes handle:
- Physical GPU resource allocation (textures, FBOs, images)
- Barrier/transition insertion (Vulkan) or no-op (OpenGL, WebGPU)
- Per-frame pass dispatch
"""
abstract type AbstractGraphExecutor end

"""
    allocate_resources!(executor, graph, width, height)

Allocate physical GPU resources for all declared resources in the compiled graph.
Called once after `compile!`, and again after `resize_resources!`.
"""
function allocate_resources!(executor::AbstractGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    error("allocate_resources! not implemented for $(typeof(executor))")
end

"""
    execute_graph!(executor, graph, backend, ctx)

Execute all compiled passes in order. Per-backend executors handle FBO binding,
barrier insertion, etc. before each pass callback.
"""
function execute_graph!(executor::AbstractGraphExecutor, graph::RenderGraph,
                         backend::AbstractBackend, ctx::RGExecuteContext)
    error("execute_graph! not implemented for $(typeof(executor))")
end

"""
    resize_resources!(executor, graph, width, height)

Recreate all size-dependent resources after a window resize.
Destroys existing transient/persistent resources and re-allocates.
"""
function resize_resources!(executor::AbstractGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    error("resize_resources! not implemented for $(typeof(executor))")
end

"""
    destroy_resources!(executor, graph)

Free all physical GPU resources owned by the executor.
Imported resources are NOT freed (they belong to their respective subsystems).
"""
function destroy_resources!(executor::AbstractGraphExecutor, graph::RenderGraph)
    error("destroy_resources! not implemented for $(typeof(executor))")
end

"""
    set_imported_resource!(executor, handle, physical_handle)

Wire an externally-owned resource (swapchain image, existing GBuffer texture, etc.)
to a graph resource handle. Must be called before execute_graph! for all IMPORTED resources.
"""
function set_imported_resource!(executor::AbstractGraphExecutor, handle::RGResourceHandle, physical_handle)
    error("set_imported_resource! not implemented for $(typeof(executor))")
end

"""
    get_physical_resource(executor, handle) -> Any

Get the physical GPU resource backing a handle (for external use).
"""
function get_physical_resource(executor::AbstractGraphExecutor, handle::RGResourceHandle)
    error("get_physical_resource not implemented for $(typeof(executor))")
end
