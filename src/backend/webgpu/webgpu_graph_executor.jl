# WebGPU Render Graph Executor
# Simplest executor: wgpu handles barriers automatically.
# Dispatches FFI calls in the graph's sorted order.

"""
    WebGPUGraphExecutor <: AbstractGraphExecutor

WebGPU-specific graph executor. Since wgpu handles resource barriers
automatically, this executor only tracks opaque u64 handles and
dispatches FFI calls in the compiled pass order.
"""
mutable struct WebGPUGraphExecutor <: AbstractGraphExecutor
    resource_handles::Vector{UInt64}
    handles::Union{DeferredGraphHandles, Nothing}

    WebGPUGraphExecutor() = new(UInt64[], nothing)
end

function allocate_resources!(exec::WebGPUGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    @assert graph.compiled "Render graph must be compiled"

    # WebGPU resources are managed on the Rust side.
    # Julia only tracks opaque handles. Pre-fill with zeros.
    exec.resource_handles = zeros(UInt64, length(graph.resources))
    return nothing
end

function set_imported_resource!(exec::WebGPUGraphExecutor, handle::RGResourceHandle, wgpu_handle::UInt64)
    idx = handle.index
    if idx >= 1 && idx <= length(exec.resource_handles)
        exec.resource_handles[idx] = wgpu_handle
    end
end

function get_physical_resource(exec::WebGPUGraphExecutor, handle::RGResourceHandle)
    idx = handle.index
    if idx >= 1 && idx <= length(exec.resource_handles)
        return exec.resource_handles[idx]
    end
    return UInt64(0)
end

function execute_graph!(exec::WebGPUGraphExecutor, graph::RenderGraph,
                         backend::WebGPUBackend, ctx::RGExecuteContext)
    @assert graph.compiled "Render graph not compiled"

    # WebGPU: no explicit barriers needed (wgpu tracks resource state)
    for pi in graph.sorted_passes
        pass = graph.passes[pi]
        pass.execute_fn(backend, ctx)
    end
end

function resize_resources!(exec::WebGPUGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    # WebGPU resources are recreated on the Rust side during resize.
    # Just re-initialize our handle tracking.
    exec.resource_handles = zeros(UInt64, length(graph.resources))
end

function destroy_resources!(exec::WebGPUGraphExecutor, graph::RenderGraph)
    empty!(exec.resource_handles)
end
