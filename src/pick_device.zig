const std = @import("std");
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const Instance = root.Instance;
const Device = root.Device;
const required_device_extensions = root.required_device_extensions;
const vk = root.vk;

pub fn initializeCandidate(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    const physical_device_features: vk.PhysicalDeviceFeatures = .{
        .fill_mode_non_solid = vk.TRUE,
        .shader_storage_image_write_without_format = vk.TRUE,
        .shader_storage_image_read_without_format = vk.TRUE,
        .shader_int_64 = vk.TRUE,
        .shader_int_16 = vk.TRUE,
        .shader_float_64 = vk.TRUE,
    };

    var ray_tracing_pipeline_ext = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR{
        .ray_tracing_pipeline = vk.TRUE,
    };

    var ray_query_ext = vk.PhysicalDeviceRayQueryFeaturesKHR{
        .ray_query = vk.TRUE,
        .p_next = &ray_tracing_pipeline_ext,
    };

    var as_ext = vk.PhysicalDeviceAccelerationStructureFeaturesKHR{
        .acceleration_structure = vk.TRUE,
        // .descriptor_binding_acceleration_structure_update_after_bind = vk.TRUE,
        .p_next = &ray_query_ext,
    };

    var vulkan_1_2_features = vk.PhysicalDeviceVulkan12Features{
        .buffer_device_address = vk.TRUE,
        // features needed for bindless
        .descriptor_indexing = vk.TRUE,
        .shader_input_attachment_array_dynamic_indexing = vk.TRUE,
        .shader_uniform_texel_buffer_array_dynamic_indexing = vk.TRUE,
        .shader_storage_texel_buffer_array_dynamic_indexing = vk.TRUE,
        .shader_uniform_buffer_array_non_uniform_indexing = vk.TRUE,
        .shader_sampled_image_array_non_uniform_indexing = vk.TRUE,
        .shader_storage_buffer_array_non_uniform_indexing = vk.TRUE,
        .shader_storage_image_array_non_uniform_indexing = vk.TRUE,
        .shader_input_attachment_array_non_uniform_indexing = vk.TRUE,
        .shader_uniform_texel_buffer_array_non_uniform_indexing = vk.TRUE,
        .shader_storage_texel_buffer_array_non_uniform_indexing = vk.TRUE,
        .descriptor_binding_uniform_buffer_update_after_bind = vk.TRUE,
        .descriptor_binding_sampled_image_update_after_bind = vk.TRUE,
        .descriptor_binding_storage_image_update_after_bind = vk.TRUE,
        .descriptor_binding_storage_buffer_update_after_bind = vk.TRUE,
        .descriptor_binding_uniform_texel_buffer_update_after_bind = vk.TRUE,
        .descriptor_binding_storage_texel_buffer_update_after_bind = vk.TRUE,
        .descriptor_binding_update_unused_while_pending = vk.TRUE,
        .descriptor_binding_partially_bound = vk.TRUE,
        .descriptor_binding_variable_descriptor_count = vk.TRUE,
        .runtime_descriptor_array = vk.TRUE,
        .shader_float_16 = vk.TRUE,
        .shader_int_8 = vk.TRUE,
        .p_next = &as_ext,
    };

    const vulkan_1_3_features = vk.PhysicalDeviceVulkan13Features{
        .dynamic_rendering = vk.TRUE,
        .synchronization_2 = vk.TRUE,
        .p_next = &vulkan_1_2_features,
    };

    return try instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .p_enabled_features = &physical_device_features,
        .p_next = &vulkan_1_3_features,
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

pub fn pickPhysicalDevice(
    instance: Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}
