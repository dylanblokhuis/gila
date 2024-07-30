pub const c = @import("c.zig");
pub const slang = @import("slang.zig");
pub const vk = @import("vk.zig");

pub const Swapchain = @import("swapchain.zig");
pub const Shader = @import("shader.zig");
pub const GraphicsPipeline = @import("graphics_pipeline.zig");
const MultiArenaUnmanaged = @import("generational-arena").MultiArenaUnmanaged;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

usingnamespace @import("pick_device.zig");

/// To construct base, instance and device wrappers for vulkan-zig, you need to pass a list of 'apis' to it.
const apis: []const vk.ApiInfo = &.{
    // You can either add invidiual functions by manually creating an 'api'
    .{
        // .base_commands = .{
        //     // .createInstance = true,
        // },
        // .instance_commands = .{
        //     .createDebugUtilsMessengerEXT = true,
        // },
    },
    // Or you can add entire feature sets or extensions
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.features.version_1_3,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    // vk.extensions.khr_synchronization_2,
    // vk.extensions.khr_dynamic_rendering,
    vk.extensions.ext_debug_utils,
};
pub const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
};
pub const required_instance_extensions = [_][*:0]const u8{
    vk.extensions.ext_debug_utils.name,
};

/// Next, pass the `apis` to the wrappers to create dispatch tables.
const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

// Also create some proxying wrappers, which also have the respective handles
pub const Instance = vk.InstanceProxy(apis);
pub const Device = vk.DeviceProxy(apis);

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    pub fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

const Self = @This();

pub const ShaderPool = MultiArenaUnmanaged(Shader, u16, u16);
pub const ShaderHandle = ShaderPool.Index;

pub const GraphicsPipelinePool = MultiArenaUnmanaged(GraphicsPipeline, u8, u8);
pub const GraphicsPipelineHandle = GraphicsPipelinePool.Index;

pub const PrependDescriptorSet = struct { layout: vk.DescriptorSetLayout, set: vk.DescriptorSet };

allocator: Allocator,
base: BaseDispatch,
device: Device,
instance: Instance,
surface: vk.SurfaceKHR,

physical_device: vk.PhysicalDevice,
physical_device_properties: vk.PhysicalDeviceProperties,
physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,

graphics_queue: Self.Queue,
present_queue: Self.Queue,

debug_messenger: vk.DebugUtilsMessengerEXT,
vma: c.VmaAllocator,
shaders: ShaderPool = .{},
graphics_pipelines: GraphicsPipelinePool = .{},

pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: *c.GLFWwindow) !Self {
    var instance_extensions = std.ArrayList([*c]const u8).init(allocator);
    defer instance_extensions.deinit();

    try instance_extensions.appendSlice(&required_instance_extensions);

    var layer_names = std.ArrayList([*:0]const u8).init(allocator);
    defer layer_names.deinit();

    if (builtin.mode == .Debug) {
        try layer_names.append("VK_LAYER_KHRONOS_validation");
    }

    const base = try BaseDispatch.load(struct {
        fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) c.GLFWglproc {
            return c.glfwGetInstanceProcAddress(@ptrFromInt(@intFromEnum(instance)), name);
        }
    }.getInstanceProcAddress);

    var glfw_exts_count: u32 = 0;
    const glfw_exts = c.glfwGetRequiredInstanceExtensions(&glfw_exts_count);
    try instance_extensions.appendSlice(glfw_exts[0..glfw_exts_count]);

    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = vk.makeApiVersion(0, 0, 0, 0),
        .p_engine_name = app_name,
        .engine_version = vk.makeApiVersion(0, 0, 0, 0),
        .api_version = vk.API_VERSION_1_3,
    };
    std.log.info("Creating Vulkan instance with \n extensions: {s}\n layers: {s}", .{
        instance_extensions.items,
        layer_names.items,
    });
    const vk_instance = try base.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(layer_names.items.len),
        .pp_enabled_layer_names = @ptrCast(layer_names.items),
        .enabled_extension_count = @intCast(instance_extensions.items.len),
        .pp_enabled_extension_names = @ptrCast(instance_extensions.items),
    }, null);

    const instance_dispatch = try allocator.create(InstanceDispatch);
    instance_dispatch.* = try InstanceDispatch.load(vk_instance, base.dispatch.vkGetInstanceProcAddr);
    const instance = Instance.init(vk_instance, instance_dispatch);

    var c_surface: c.VkSurfaceKHR = undefined;
    if (c.glfwCreateWindowSurface(@ptrFromInt(@intFromEnum(vk_instance)), window, null, &c_surface) != @intFromEnum(vk.Result.success)) {
        return error.SurfaceInitFailed;
    }
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(c_surface));

    const candidate = try Self.pickPhysicalDevice(instance, allocator, surface);
    std.log.info("Picking device {s} with support for Vulkan 1.{d}", .{ candidate.props.device_name, vk.apiVersionMinor(candidate.props.api_version) });

    const vk_device = try Self.initializeCandidate(instance, candidate);
    const device_dispatch = try allocator.create(DeviceDispatch);
    device_dispatch.* = try DeviceDispatch.load(vk_device, instance.wrapper.dispatch.vkGetDeviceProcAddr);
    const device = Device.init(vk_device, device_dispatch);

    const graphics_queue = Self.Queue.init(device, candidate.queues.graphics_family);
    const present_queue = Self.Queue.init(device, candidate.queues.present_family);

    var vma: c.VmaAllocator = undefined;
    if (c.vmaCreateAllocator(&c.VmaAllocatorCreateInfo{
        .physicalDevice = @ptrFromInt(@intFromEnum(candidate.pdev)),
        .device = @ptrFromInt(@intFromEnum(vk_device)),
        .instance = @ptrFromInt(@intFromEnum(vk_instance)),
        .pVulkanFunctions = &c.VmaVulkanFunctions{
            .vkGetInstanceProcAddr = @ptrCast(base.dispatch.vkGetInstanceProcAddr),
            .vkGetDeviceProcAddr = @ptrCast(instance.wrapper.dispatch.vkGetDeviceProcAddr),
        },
        .flags = c.VMA_ALLOCATOR_CREATE_KHR_DEDICATED_ALLOCATION_BIT | c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT | c.VMA_ALLOCATOR_CREATE_KHR_BIND_MEMORY2_BIT,
        .vulkanApiVersion = c.VK_API_VERSION_1_3,
    }, &vma) != c.VK_SUCCESS) {
        return error.VmaInitFailed;
    }

    const messenger = try instance.createDebugUtilsMessengerEXT(&vk.DebugUtilsMessengerCreateInfoEXT{
        .message_severity = vk.DebugUtilsMessageSeverityFlagsEXT{
            .verbose_bit_ext = true,
            .info_bit_ext = true,
            .error_bit_ext = true,
            .warning_bit_ext = true,
        },
        .message_type = vk.DebugUtilsMessageTypeFlagsEXT{
            .general_bit_ext = true,
            .performance_bit_ext = true,
            .validation_bit_ext = true,
        },
        .pfn_user_callback = struct {
            fn debugCallback(
                message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
                _: vk.DebugUtilsMessageTypeFlagsEXT,
                p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
                _: ?*anyopaque,
            ) callconv(vk.vulkan_call_conv) vk.Bool32 {
                if (p_callback_data) |data| {
                    const format = "{?s}";

                    if (message_severity.error_bit_ext) {
                        std.log.err(format, .{data.p_message});
                    } else if (message_severity.warning_bit_ext) {
                        std.log.warn(format, .{data.p_message});
                    } else if (message_severity.info_bit_ext) {
                        std.log.info(format, .{data.p_message});
                    } else {
                        std.log.debug(format, .{data.p_message});
                    }
                }
                return vk.FALSE;
            }
        }.debugCallback,
    }, null);

    return Self{
        .allocator = allocator,
        .base = base,
        .device = device,
        .instance = instance,
        .surface = surface,

        .physical_device = candidate.pdev,
        .physical_device_properties = candidate.props,
        .physical_device_memory_properties = instance.getPhysicalDeviceMemoryProperties(candidate.pdev),

        .graphics_queue = graphics_queue,
        .present_queue = present_queue,

        .debug_messenger = messenger,
        .vma = vma,
    };
}

pub fn createShader(self: *Self, create: Shader.CreateInfo) !ShaderPool.Index {
    const shader = try Shader.create(self, create);
    return try self.shaders.append(self.allocator, shader);
}

pub fn createGraphicsPipeline(self: *Self, create: GraphicsPipeline.CreateInfo) !GraphicsPipelinePool.Index {
    const pipeline = try GraphicsPipeline.create(self, create);
    return try self.graphics_pipelines.append(self.allocator, pipeline);
}
