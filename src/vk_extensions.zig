// you can overwrite this in your program by forcing an anonymous import
const vk = @import("vk.zig");

pub const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
    vk.extensions.khr_acceleration_structure,
    vk.extensions.khr_deferred_host_operations,
    vk.extensions.khr_ray_tracing_pipeline,
    vk.extensions.khr_ray_query,
};

pub const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_deferred_host_operations.name,
    vk.extensions.khr_ray_tracing_pipeline.name,
    vk.extensions.khr_ray_query.name,
};

pub const required_instance_extensions = [_][*:0]const u8{
    vk.extensions.ext_debug_utils.name,
};
