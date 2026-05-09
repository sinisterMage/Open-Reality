# Vulkan instance, physical device, and logical device creation

"""
    vk_get_required_extensions() -> Vector{String}

Get the Vulkan instance extensions required by GLFW for window surface creation.
"""
function vk_get_required_extensions()
    count_ref = Ref{UInt32}(0)
    names_ptr = ccall((:glfwGetRequiredInstanceExtensions, GLFW.libglfw),
                      Ptr{Cstring}, (Ptr{UInt32},), count_ref)
    names_ptr == C_NULL && error("GLFW: Vulkan not supported on this system")
    count = count_ref[]
    return [unsafe_string(unsafe_load(names_ptr, i)) for i in 1:count]
end

"""
    vk_create_instance(; enable_validation=false) -> Instance

Create a Vulkan instance with the required GLFW surface extensions.
"""
function vk_create_instance(; enable_validation::Bool=false)
    extensions = vk_get_required_extensions()

    layers = String[]
    if enable_validation
        push!(layers, "VK_LAYER_KHRONOS_validation")
        push!(extensions, "VK_EXT_debug_utils")
    end

    app_info = ApplicationInfo(
        v"0.1.0",
        v"0.1.0",
        v"1.2";
        application_name="OpenReality",
        engine_name="OpenReality Engine"
    )

    create_info = InstanceCreateInfo(
        layers,
        extensions;
        application_info=app_info
    )

    instance = unwrap(create_instance(create_info))

    if enable_validation
        _vk_setup_debug_messenger(instance)
    end

    return instance
end

# Persistent reference to prevent GC of the debug callback
const _VK_DEBUG_CALLBACK_REF = Ref{Any}(nothing)
# Holds the live VkDebugUtilsMessengerEXT handle so we can destroy it during
# shutdown!. Without this we leaked a child object of VkInstance and
# vkDestroyInstance would (correctly) report a validation error at exit.
const _VK_DEBUG_MESSENGER_HANDLE = Ref{UInt64}(UInt64(0))
const _VK_DEBUG_MESSENGER_INSTANCE = Ref{Ptr{Nothing}}(C_NULL)

function _vk_debug_messenger_callback(severity, type, callback_data_ptr, user_data)
    callback_data = unsafe_load(callback_data_ptr)
    msg = unsafe_string(callback_data.pMessage)

    if (severity & Vulkan.VkCore.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0
        @error "[Vulkan Validation] $msg"
    elseif (severity & Vulkan.VkCore.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0
        @warn "[Vulkan Validation] $msg"
    else
        @info "[Vulkan Validation] $msg"
    end
    return UInt32(0)  # VK_FALSE
end

function _vk_setup_debug_messenger(instance::Instance)
    severity_flags = Vulkan.VkCore.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                     Vulkan.VkCore.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
    type_flags = Vulkan.VkCore.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                 Vulkan.VkCore.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                 Vulkan.VkCore.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT

    callback_fn = @cfunction(_vk_debug_messenger_callback,
        UInt32,
        (UInt32, UInt32, Ptr{Vulkan.VkCore.VkDebugUtilsMessengerCallbackDataEXT}, Ptr{Cvoid}))

    _VK_DEBUG_CALLBACK_REF[] = callback_fn  # prevent GC

    create_info = Vulkan.VkCore.VkDebugUtilsMessengerCreateInfoEXT(
        Vulkan.VkCore.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        C_NULL, UInt32(0),
        severity_flags, type_flags,
        callback_fn, C_NULL
    )

    messenger_ref = Ref{Vulkan.VkCore.VkDebugUtilsMessengerEXT}()
    create_info_ref = Ref(create_info)

    # Load the function pointer
    func_ptr = ccall((:vkGetInstanceProcAddr, Vulkan.VkCore.libvulkan),
        Ptr{Cvoid}, (Ptr{Nothing}, Cstring),
        instance.vks, "vkCreateDebugUtilsMessengerEXT")

    if func_ptr != C_NULL
        GC.@preserve create_info_ref messenger_ref begin
            result = ccall(func_ptr, Int32,
                (Ptr{Nothing}, Ptr{Vulkan.VkCore.VkDebugUtilsMessengerCreateInfoEXT},
                 Ptr{Cvoid}, Ptr{Vulkan.VkCore.VkDebugUtilsMessengerEXT}),
                instance.vks, create_info_ref, C_NULL, messenger_ref)
            if result == 0
                _VK_DEBUG_MESSENGER_HANDLE[] = UInt64(messenger_ref[])
                _VK_DEBUG_MESSENGER_INSTANCE[] = instance.vks
                @info "Vulkan validation messenger installed"
            else
                @warn "Failed to create debug messenger: $result"
            end
        end
    else
        @warn "vkCreateDebugUtilsMessengerEXT not available"
    end
end

"""
    vk_destroy_debug_messenger!(instance)

Destroy the validation debug messenger created by `_install_debug_messenger!`.
Called from `shutdown!` BEFORE the instance is finalized so we don't leak it.
Safe to call when no messenger was installed.
"""
function vk_destroy_debug_messenger!(instance::Instance)
    handle = _VK_DEBUG_MESSENGER_HANDLE[]
    handle == 0 && return
    func_ptr = ccall((:vkGetInstanceProcAddr, Vulkan.VkCore.libvulkan),
        Ptr{Cvoid}, (Ptr{Nothing}, Cstring),
        instance.vks, "vkDestroyDebugUtilsMessengerEXT")
    if func_ptr != C_NULL
        ccall(func_ptr, Cvoid,
            (Ptr{Nothing}, UInt64, Ptr{Cvoid}),
            instance.vks, handle, C_NULL)
    end
    _VK_DEBUG_MESSENGER_HANDLE[] = UInt64(0)
    _VK_DEBUG_MESSENGER_INSTANCE[] = C_NULL
    return nothing
end

"""
    vk_create_surface(instance, window_handle) -> SurfaceKHR

Create a Vulkan surface from a GLFW window handle.
"""
function vk_create_surface(instance::Instance, window_handle::GLFW.Window)
    surface_ref = Ref{Ptr{Nothing}}()
    result = ccall((:glfwCreateWindowSurface, GLFW.libglfw),
                   Int32,
                   (Ptr{Nothing}, GLFW.Window, Ptr{Cvoid}, Ptr{Ptr{Nothing}}),
                   instance.vks, window_handle, C_NULL, surface_ref)
    result == 0 || error("Failed to create Vulkan window surface: result code $result")
    destructor = x -> Vulkan._destroy_surface_khr(instance, x)
    return SurfaceKHR(surface_ref[], destructor, instance)
end

"""
    QueueFamilyIndices

Holds the queue family indices for graphics and presentation.
"""
struct QueueFamilyIndices
    graphics::UInt32
    present::UInt32
end

"""
    vk_find_queue_families(physical_device, surface) -> Union{QueueFamilyIndices, Nothing}

Find queue families that support graphics and presentation.
"""
function vk_find_queue_families(physical_device::PhysicalDevice, surface::SurfaceKHR)
    props = get_physical_device_queue_family_properties(physical_device)
    graphics_idx = nothing
    present_idx = nothing

    for (i, prop) in enumerate(props)
        idx = UInt32(i - 1)  # 0-based
        if (prop.queue_flags & QUEUE_GRAPHICS_BIT) != QueueFlag(0)
            graphics_idx = idx
        end
        supported = unwrap(get_physical_device_surface_support_khr(physical_device, idx, surface))
        if supported
            present_idx = idx
        end
        # Prefer a family that supports both
        if graphics_idx !== nothing && present_idx !== nothing
            break
        end
    end

    if graphics_idx === nothing || present_idx === nothing
        return nothing
    end
    return QueueFamilyIndices(graphics_idx, present_idx)
end

"""
    vk_select_physical_device(instance, surface) -> (PhysicalDevice, QueueFamilyIndices)

Select the best physical device that supports graphics and presentation.
Prefers discrete GPUs over integrated.
"""
function vk_select_physical_device(instance::Instance, surface::SurfaceKHR)
    devices = unwrap(enumerate_physical_devices(instance))
    isempty(devices) && error("No Vulkan-capable GPU found")

    best_device = nothing
    best_indices = nothing
    best_score = -1

    for dev in devices
        indices = vk_find_queue_families(dev, surface)
        indices === nothing && continue

        # Check required extensions
        ext_props = unwrap(enumerate_device_extension_properties(dev))
        ext_names = Set(String(e.extension_name) for e in ext_props)
        "VK_KHR_swapchain" in ext_names || continue

        # Score device
        props = get_physical_device_properties(dev)
        score = props.device_type == PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ? 1000 : 100

        if score > best_score
            best_score = score
            best_device = dev
            best_indices = indices
        end
    end

    best_device === nothing && error("No suitable Vulkan GPU found (need graphics + present + swapchain)")
    return best_device, best_indices
end

"""
    vk_create_logical_device(physical_device, indices) -> (Device, Queue, Queue)

Create a logical device and retrieve graphics and present queues.
"""
function vk_create_logical_device(physical_device::PhysicalDevice, indices::QueueFamilyIndices)
    unique_families = unique([indices.graphics, indices.present])

    queue_create_infos = [
        DeviceQueueCreateInfo(family, [1.0f0])
        for family in unique_families
    ]

    features = PhysicalDeviceFeatures(
        :sampler_anisotropy,
        :fill_mode_non_solid,
        :independent_blend
    )

    device_info = DeviceCreateInfo(
        queue_create_infos,
        String[],  # layers (deprecated)
        ["VK_KHR_swapchain"];
        enabled_features=features
    )

    device = unwrap(create_device(physical_device, device_info))
    graphics_queue = get_device_queue(device, indices.graphics, 0)
    present_queue = get_device_queue(device, indices.present, 0)

    return device, graphics_queue, present_queue
end
