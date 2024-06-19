pub const c = @import("c.zig");
const std = @import("std");
const vk = @import("vk.zig");
const Allocator = std.mem.Allocator;
const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
/// To construct base, instance and device wrappers for vulkan-zig, you need to pass a list of 'apis' to it.
const apis: []const vk.ApiInfo = &.{
    // You can either add invidiual functions by manually creating an 'api'
    .{
        .base_commands = .{
            .createInstance = true,
        },
        .instance_commands = .{
            .createDevice = true,
        },
    },
    // Or you can add entire feature sets or extensions
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.khr_synchronization_2,
    vk.extensions.khr_dynamic_rendering,
    vk.extensions.ext_debug_utils,
};

/// Next, pass the `apis` to the wrappers to create dispatch tables.
const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

// Also create some proxying wrappers, which also have the respective handles
const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);
const Self = @This();

gpa: Allocator,
dispatch: BaseDispatch,
device: Device,
instance: Instance,
surface: vk.SurfaceKHR,

physical_device: vk.PhysicalDevice,
physical_device_properties: vk.PhysicalDeviceProperties,
physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,

debug_messenger: vk.DebugUtilsMessengerEXT,
vma: c.VmaAllocator,

// pub fn init(
//     allocator: Allocator,
//     window: glfw.Window,
// ) !Self {
//     _ = allocator; // autofix
//     _ = window; // autofix

// }

// const Self = @This();

// pub fn init()
