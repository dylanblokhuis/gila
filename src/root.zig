pub const c = @import("c.zig");
pub const slang = @import("slang.zig");
pub const vk = @import("vk.zig");
pub const glfw = @import("mach-glfw");

pub const Swapchain = @import("swapchain.zig");
pub const Shader = @import("shader.zig");
pub const Texture = @import("texture.zig");
pub const Buffer = @import("buffer.zig");
pub const GraphicsPipeline = @import("graphics_pipeline.zig");
pub const ComputePipeline = @import("compute_pipeline.zig");
pub const CommandEncoder = @import("command_encoder.zig");
const MultiArenaUnmanaged = @import("generational-arena").MultiArenaUnmanaged;
const ArenaUnmanaged = @import("generational-arena").ArenaUnmanaged;

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

pub const GraphicsPipelinePool = MultiArenaUnmanaged(GraphicsPipeline, u4, u4);
pub const GraphicsPipelineHandle = GraphicsPipelinePool.Index;

pub const ComputePipelinePool = MultiArenaUnmanaged(ComputePipeline, u4, u4);
pub const ComputePipelineHandle = ComputePipelinePool.Index;

pub const TexturePool = MultiArenaUnmanaged(Texture, u16, u16);
pub const TextureHandle = TexturePool.Index;

pub const BufferPool = MultiArenaUnmanaged(Buffer, u16, u16);
pub const BufferHandle = BufferPool.Index;

pub const VmaPools = ArenaUnmanaged(c.VmaPool, u8, u8);
pub const VmaPoolHandle = VmaPools.Index;

// pub const PrependDescriptorSet = struct { layout: vk.DescriptorSetLayout };

const GraphicsPipelineCreationTracker = std.AutoHashMapUnmanaged(GraphicsPipelineHandle, GraphicsPipeline.CreateInfo);
const ComputePipelineCreationTracker = std.AutoHashMapUnmanaged(ComputePipelineHandle, ComputePipeline.CreateInfo);

const Options = struct {
    validation_layers: bool = true,
};

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
compute_pipelines: ComputePipelinePool = .{},
textures: TexturePool = .{},
buffers: BufferPool = .{},
vma_pools: VmaPools = .{},
graphics_pipeline_creation_tracker: GraphicsPipelineCreationTracker = .{},
compute_pipeline_creation_tracker: ComputePipelineCreationTracker = .{},

pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: glfw.Window, options: Options) !Self {
    var instance_extensions = std.ArrayList([*c]const u8).init(allocator);
    defer instance_extensions.deinit();

    try instance_extensions.appendSlice(&required_instance_extensions);

    var layer_names = std.ArrayList([*:0]const u8).init(allocator);
    defer layer_names.deinit();

    if (options.validation_layers) {
        try layer_names.append("VK_LAYER_KHRONOS_validation");
    }

    const base = try BaseDispatch.load(struct {
        fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) ?glfw.VKProc {
            return glfw.getInstanceProcAddress(@ptrFromInt(@intFromEnum(instance)), name);
        }
    }.getInstanceProcAddress);

    const glfw_exts = glfw.getRequiredInstanceExtensions();
    try instance_extensions.appendSlice(glfw_exts.?);

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
    if (glfw.createWindowSurface(vk_instance, window, null, &c_surface) != @intFromEnum(vk.Result.success)) {
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
        .flags = c.VMA_ALLOCATOR_CREATE_KHR_DEDICATED_ALLOCATION_BIT | c.VMA_ALLOCATOR_CREATE_KHR_BIND_MEMORY2_BIT | c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT,
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
    const handle = try self.graphics_pipelines.append(self.allocator, pipeline);

    var create_ref = create;
    create_ref.vertex.buffer_layout = try self.allocator.dupe(GraphicsPipeline.VertexBufferLayout, create.vertex.buffer_layout);
    if (create_ref.prepend_descriptor_set_layouts) |slice| {
        create_ref.prepend_descriptor_set_layouts = try self.allocator.dupe(vk.DescriptorSetLayout, slice);
    }
    if (create_ref.fragment) |*fragment| {
        fragment.color_targets = try self.allocator.dupe(GraphicsPipeline.ColorAttachment, fragment.color_targets);
    }

    try self.graphics_pipeline_creation_tracker.put(self.allocator, handle, create_ref);
    return handle;
}

pub fn destroyGraphicsPipeline(self: *Self, handle: GraphicsPipelineHandle) void {
    var inner = self.graphics_pipelines.remove(handle).?;
    inner.destroy(self);
    self.graphics_pipeline_creation_tracker.remove(handle);
}

pub fn createComputePipeline(self: *Self, create: ComputePipeline.CreateInfo) !ComputePipelinePool.Index {
    const pipeline = try ComputePipeline.create(self, create);
    const handle = try self.compute_pipelines.append(self.allocator, pipeline);

    var create_ref = create;
    if (create_ref.prepend_descriptor_set_layouts) |slice| {
        create_ref.prepend_descriptor_set_layouts = try self.allocator.dupe(vk.DescriptorSetLayout, slice);
    }

    try self.compute_pipeline_creation_tracker.put(self.allocator, handle, create_ref);
    return handle;
}

pub fn destroyComputePipeline(self: *Self, handle: ComputePipelineHandle) void {
    var inner = self.compute_pipelines.remove(handle).?;
    inner.destroy(self);
    self.compute_pipeline_creation_tracker.remove(handle);
}

pub fn createTexture(self: *Self, create: Texture.CreateInfo) !TexturePool.Index {
    const tex = try Texture.create(self, create);
    return try self.textures.append(self.allocator, tex);
}

pub fn destroyTexture(self: *Self, texture: TexturePool.Index) void {
    var inner = self.textures.remove(texture).?;
    inner.destroy(self);
}

pub fn createSwapchainSizedColorAttachment(self: *Self, swapchain: *const Swapchain, format: ?vk.Format) !TexturePool.Index {
    const tex = try Texture.create(self, .{
        .dedicated = true,
        .dimensions = .{
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .depth = 1,
        },
        .format = format orelse swapchain.surface_format.format,
        .name = "swapchain_sized_color_attachment",
        .usage = vk.ImageUsageFlags{
            .color_attachment_bit = true,
            .transfer_src_bit = true,
            .sampled_bit = true,
            .storage_bit = true,
        },
    });
    return try self.textures.append(self.allocator, tex);
}

pub fn createSwapchainSizedDepthAttachment(self: *Self, swapchain: *const Swapchain, format: ?vk.Format) !TexturePool.Index {
    const tex = try Texture.create(self, .{
        .dedicated = true,
        .dimensions = .{
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .depth = 1,
        },
        .format = format orelse vk.Format.d32_sfloat,
        .name = "swapchain_sized_depth_attachment",
        .usage = vk.ImageUsageFlags{
            .depth_stencil_attachment_bit = true,
            .transfer_src_bit = true,
            .sampled_bit = true,
        },
    });
    return try self.textures.append(self.allocator, tex);
}

pub fn createSwapchainSizedStorageTexture(self: *Self, swapchain: *const Swapchain, format: vk.Format) !TexturePool.Index {
    const tex = try Texture.create(self, .{
        .dedicated = true,
        .dimensions = .{
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .depth = 1,
        },
        .format = format,
        .name = "swapchain_sized_storage_texture",
        .usage = vk.ImageUsageFlags{
            .storage_bit = true,
            .transfer_src_bit = true,
            .sampled_bit = true,
        },
    });
    return try self.textures.append(self.allocator, tex);
}

pub fn createBuffer(self: *Self, create: Buffer.CreateInfo) !BufferPool.Index {
    const buf = try Buffer.create(self, create);
    return try self.buffers.append(self.allocator, buf);
}

pub fn destroyBuffer(self: *Self, buffer: BufferPool.Index) void {
    var inner = self.buffers.remove(buffer).?;
    inner.destroy(self);
}

pub const BufferCopyInfo = struct {
    data: ?*const anyopaque,
    data_len: usize,
    dst_offset: usize = 0,
    command_buffer: ?vk.CommandBuffer = null,
};

pub fn createBufferWithCopy(self: *Self, create_desc: Buffer.CreateInfo, copy_info: BufferCopyInfo) !BufferPool.Index {
    var staging_buffer = try Buffer.create(self, .{
        .location = .auto,
        .usage = vk.BufferUsageFlags{
            .transfer_src_bit = true,
        },
        .size = copy_info.data_len,
        .name = "staging buffer",
    });
    staging_buffer.setData(self, copy_info.data, copy_info.data_len);

    var desc = create_desc;
    desc.usage.transfer_dst_bit = true;
    if (desc.size == 0) {
        desc.size = copy_info.data_len;
    }

    const buffer = try Buffer.create(self, desc);
    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = copy_info.dst_offset,
        .size = copy_info.data_len,
    };

    var command_buffer: vk.CommandBuffer = self.transfer_command_buffer;
    if (copy_info.command_buffer) |cmdbuf| {
        command_buffer = cmdbuf;
        self.device.cmdCopyBuffer(command_buffer, staging_buffer.buffer, buffer.buffer, 1, @ptrCast(&region));

        const staging = try self.buffers.append(self.allocator, staging_buffer);
        self.queueDestroyBuffer(staging);
    } else {
        try self.startTransfer();
        self.device.cmdCopyBuffer(command_buffer, staging_buffer.buffer, buffer.buffer, 1, @ptrCast(&region));
        try self.submitTransfer();

        staging_buffer.destroy(self);
    }

    return try self.buffers.append(self.allocator, buffer);
}

const VmaPoolOptions = struct {
    block_size: usize = 0,
    max_block_count: u32 = 0,
    min_block_count: u32 = 0,
    min_allocation_alignment: usize = 0,
    priority: f32 = 0,
    is_linear: bool = false,
};

pub fn createVmaPool(self: *Self, options: VmaPoolOptions, sample_buffer_usage: vk.BufferUsageFlags) !VmaPoolHandle {
    const sample_info = c.VmaAllocationCreateInfo{
        .usage = c.VMA_MEMORY_USAGE_AUTO,
    };

    const sample_buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = 1024,
        .usage = sample_buffer_usage.toInt(),
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    var mem_type_index: u32 = undefined;
    if (c.vmaFindMemoryTypeIndexForBufferInfo(self.vma, &sample_buffer_info, &sample_info, &mem_type_index) != c.VK_SUCCESS) {
        return error.VmaMemoryTypeIndexNotFound;
    }

    // Create a pool that can have at most 2 blocks, 128 MiB each.
    const pool_create_info = c.VmaPoolCreateInfo{
        .memoryTypeIndex = mem_type_index,
        .blockSize = options.block_size,
        .maxBlockCount = options.max_block_count,
        .minBlockCount = options.min_block_count,
        .minAllocationAlignment = options.min_allocation_alignment,
        .priority = options.priority,
        .flags = if (options.is_linear) c.VMA_POOL_CREATE_LINEAR_ALGORITHM_BIT else 0,
    };

    var pool: c.VmaPool = undefined;
    if (c.vmaCreatePool(self.vma, &pool_create_info, &pool) != c.VK_SUCCESS) {
        return error.VmaPoolCreationFailed;
    }

    return try self.vma_pools.append(self.allocator, pool);
}

/// This function will make sure that the input type is properly aligned to prevent any misalignment issues
pub fn toGpuBytes(input: anytype) []const u8 {
    const T: std.builtin.Type = @typeInfo(@TypeOf(input));

    if (T != .Pointer) {
        @compileError("toGpuBytes only supports pointers");
    }

    const ChildT: std.builtin.Type = @typeInfo(std.meta.Child(@TypeOf(input)));
    const StructT = switch (ChildT) {
        .Array => @typeInfo(ChildT.Array.child),
        else => ChildT,
    };
    if (StructT != .Struct) {
        @compileError("toGpuBytes only supports structs");
    }
    if (StructT.Struct.layout != .@"extern") {
        @compileError("toGpuBytes only supports extern structs");
    }

    // check if all fields are align(1)
    inline for (StructT.Struct.fields) |field| {
        if (field.alignment != 1) {
            @compileError("toGpuBytes only supports structs with align(1) fields");
        }
        if (@typeInfo(field.type) == .Vector) {
            @compileError("toGpuBytes does not support vectors, the compiler will not align them properly");
        }
    }

    return if (T.Pointer.size == .Slice) std.mem.sliceAsBytes(input) else std.mem.asBytes(input);
}

/// compiles the shaders and recreates the pipeline, but the handle remains the same
pub fn reloadGraphicsPipeline(self: *Self, handle: GraphicsPipelineHandle) !void {
    const create_info = self.graphics_pipeline_creation_tracker.get(handle).?;

    var vertex_shader = self.shaders.get(create_info.vertex.shader).?;
    if (vertex_shader.path) |path| {
        const new_shader = try Shader.create(self, .{
            .data = .{ .path = path },
            .entry_point = vertex_shader.entry_point,
            .kind = vertex_shader.kind,
        });
        vertex_shader.destroy(self);
        try self.shaders.set(create_info.vertex.shader, new_shader);
    }

    if (create_info.fragment) |fragment| {
        var fragment_shader = self.shaders.get(fragment.shader).?;
        if (fragment_shader.path) |path| {
            const new_shader = try Shader.create(self, .{
                .data = .{ .path = path },
                .entry_point = fragment_shader.entry_point,
                .kind = fragment_shader.kind,
            });
            fragment_shader.destroy(self);
            try self.shaders.set(fragment.shader, new_shader);
        }
    }

    var old_pipeline = self.graphics_pipelines.get(handle).?;
    old_pipeline.destroy(self);

    try self.graphics_pipelines.set(handle, try GraphicsPipeline.create(self, create_info));
}

/// compiles the shader and recreates the pipeline, but the handle remains the same
pub fn reloadComputePipeline(self: *Self, handle: ComputePipelineHandle) !void {
    const create_info = self.compute_pipeline_creation_tracker.get(handle).?;

    var shader = self.shaders.get(create_info.shader).?;
    if (shader.path) |path| {
        const new_shader = try Shader.create(self, .{
            .data = .{ .path = path },
            .entry_point = shader.entry_point,
            .kind = shader.kind,
        });
        shader.destroy(self);
        try self.shaders.set(create_info.shader, new_shader);
    }

    var old_pipeline = self.compute_pipelines.get(handle).?;
    old_pipeline.destroy(self);

    try self.compute_pipelines.set(handle, try ComputePipeline.create(self, create_info));
}
