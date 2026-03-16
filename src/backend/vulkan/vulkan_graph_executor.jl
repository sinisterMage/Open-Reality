# Vulkan Render Graph Executor
# Handles physical Vulkan resource allocation, automatic barrier insertion,
# and pass dispatch. Replaces manual _vk_transition_all_render_targets! logic.

"""
    VkPhysicalResource

Physical Vulkan resource backing a render graph resource handle.
"""
mutable struct VkPhysicalResource
    image::Union{Image, Nothing}
    memory::Union{DeviceMemory, Nothing}
    view::Union{ImageView, Nothing}
    current_layout::ImageLayout
    format::Format              # Vulkan native format
    width::Int
    height::Int
    rg_format::RGFormat
    imported::Bool              # Don't allocate/free
end

VkPhysicalResource() = VkPhysicalResource(
    nothing, nothing, nothing,
    IMAGE_LAYOUT_UNDEFINED, FORMAT_R8G8B8A8_UNORM,
    0, 0, RG_RGBA8, false
)

"""
    VulkanGraphExecutor <: AbstractGraphExecutor

Vulkan-specific graph executor with automatic barrier pre-computation.
"""
mutable struct VulkanGraphExecutor <: AbstractGraphExecutor
    physical::Vector{VkPhysicalResource}
    # Pre-computed per-pass barrier list: (resource_idx, old_layout, new_layout)
    pre_pass_barriers::Vector{Vector{Tuple{Int, ImageLayout, ImageLayout}}}
    # Resource handles from graph construction
    handles::Union{DeferredGraphHandles, Nothing}
    # Transient per-frame state: post-processed source view for the present pass
    final_source_view::Union{ImageView, Nothing}

    VulkanGraphExecutor() = new(
        VkPhysicalResource[],
        Vector{Tuple{Int, ImageLayout, ImageLayout}}[],
        nothing,
        nothing
    )
end

# ---- Vulkan format mapping ----

function _rg_to_vk_format(fmt::RGFormat)::Format
    if fmt == RG_RGBA16F
        return FORMAT_R16G16B16A16_SFLOAT
    elseif fmt == RG_RGBA8
        return FORMAT_R8G8B8A8_UNORM
    elseif fmt == RG_RGBA8_SRGB
        return FORMAT_R8G8B8A8_SRGB
    elseif fmt == RG_RG16F
        return FORMAT_R16G16_SFLOAT
    elseif fmt == RG_R16F
        return FORMAT_R16_SFLOAT
    elseif fmt == RG_R8
        return FORMAT_R8_UNORM
    elseif fmt == RG_DEPTH32F
        return FORMAT_D32_SFLOAT
    elseif fmt == RG_DEPTH24
        return FORMAT_D24_UNORM_S8_UINT
    else
        error("Unknown RGFormat: $fmt")
    end
end

# ---- Barrier computation ----

"""
    _compute_barriers!(exec::VulkanGraphExecutor, graph::RenderGraph)

Pre-compute image layout transition barriers for each pass in the sorted order.
This replaces the manual _vk_transition_all_render_targets! function.
"""
function _compute_barriers!(exec::VulkanGraphExecutor, graph::RenderGraph)
    n_sorted = length(graph.sorted_passes)
    exec.pre_pass_barriers = [Tuple{Int, ImageLayout, ImageLayout}[] for _ in 1:n_sorted]

    # Track current layout for each resource
    layouts = Dict{Int, ImageLayout}()
    for (i, desc) in enumerate(graph.resources)
        layouts[i] = IMAGE_LAYOUT_UNDEFINED
    end

    for (order, pi) in enumerate(graph.sorted_passes)
        pass = graph.passes[pi]
        barriers = Tuple{Int, ImageLayout, ImageLayout}[]

        # Reads need SHADER_READ_ONLY_OPTIMAL
        for usage in pass.reads
            ridx = usage.handle.index
            ridx < 1 && continue
            required = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            current = get(layouts, ridx, IMAGE_LAYOUT_UNDEFINED)
            if current != required
                push!(barriers, (ridx, current, required))
                layouts[ridx] = required
            end
        end

        # Writes need ATTACHMENT_OPTIMAL layout
        for usage in pass.writes
            ridx = usage.handle.index
            ridx < 1 && continue
            desc = graph.resources[ridx]
            required = is_depth_format(desc.format) ?
                IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL :
                IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            current = get(layouts, ridx, IMAGE_LAYOUT_UNDEFINED)
            if current != required
                push!(barriers, (ridx, current, required))
                layouts[ridx] = required
            end
        end

        exec.pre_pass_barriers[order] = barriers
    end
end

# ---- AbstractGraphExecutor interface ----

function allocate_resources!(exec::VulkanGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    @assert graph.compiled "Render graph must be compiled"

    empty!(exec.physical)
    for _ in 1:length(graph.resources)
        push!(exec.physical, VkPhysicalResource())
    end

    # Note: For Vulkan, resources are allocated using the backend's device.
    # This function is called from initialize! with the backend available,
    # so the actual VkImage/VkDeviceMemory creation happens via the backend
    # methods. For now, we populate metadata; actual GPU allocation is done
    # in the backend's initialize! where we have access to the VkDevice.

    for (i, desc) in enumerate(graph.resources)
        if desc.lifetime == RG_IMPORTED
            exec.physical[i].imported = true
            continue
        end

        first_use, _ = graph.resource_lifetimes[i]
        first_use == typemax(Int) && continue  # Never used

        rw, rh = resolve_size(desc.size_policy, w, h)
        exec.physical[i].format = _rg_to_vk_format(desc.format)
        exec.physical[i].width = rw
        exec.physical[i].height = rh
        exec.physical[i].rg_format = desc.format
    end

    # Pre-compute barriers
    _compute_barriers!(exec, graph)

    return nothing
end

function set_imported_resource!(exec::VulkanGraphExecutor, handle::RGResourceHandle, image::Image)
    idx = handle.index
    if idx >= 1 && idx <= length(exec.physical)
        exec.physical[idx].image = image
        exec.physical[idx].imported = true
    end
end

function get_physical_resource(exec::VulkanGraphExecutor, handle::RGResourceHandle)
    idx = handle.index
    if idx >= 1 && idx <= length(exec.physical)
        return exec.physical[idx].image
    end
    return nothing
end

function execute_graph!(exec::VulkanGraphExecutor, graph::RenderGraph,
                         backend::VulkanBackend, ctx::RGExecuteContext)
    @assert graph.compiled "Render graph not compiled"

    for (order, pi) in enumerate(graph.sorted_passes)
        # Insert pre-computed barriers
        if order <= length(exec.pre_pass_barriers)
            for (ridx, old_layout, new_layout) in exec.pre_pass_barriers[order]
                pr = exec.physical[ridx]
                pr.image === nothing && continue
                # Use the existing transition_image_layout! function
                cmd = backend.command_buffers[backend.current_frame]
                aspect = is_depth_format(graph.resources[ridx].format) ?
                    IMAGE_ASPECT_DEPTH_BIT : IMAGE_ASPECT_COLOR_BIT
                transition_image_layout!(cmd, pr.image, old_layout, new_layout;
                    aspect_mask=aspect)
                pr.current_layout = new_layout
            end
        end

        # Execute pass
        pass = graph.passes[pi]
        @debug "RG executing pass" name=pass.name order=order
        try
            pass.execute_fn(backend, ctx)
            @debug "RG pass completed" name=pass.name
        catch e
            @error "Render graph pass failed" pass=pass.name exception=(e, catch_backtrace())
            rethrow()
        end
    end
end

function resize_resources!(exec::VulkanGraphExecutor, graph::RenderGraph, w::Int, h::Int)
    destroy_resources!(exec, graph)
    allocate_resources!(exec, graph, w, h)
end

function destroy_resources!(exec::VulkanGraphExecutor, graph::RenderGraph)
    # Vulkan resources need the device for cleanup.
    # Actual VkImage/VkDeviceMemory destruction happens via backend shutdown.
    # Here we just clear our tracking.
    empty!(exec.physical)
    empty!(exec.pre_pass_barriers)
end
