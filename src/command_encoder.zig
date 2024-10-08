const Gc = @import("root.zig");
const std = @import("std");
const vk = Gc.vk;

const Self = @This();

gc: *Gc,
command_pool: vk.CommandPool,
command_buffers: []vk.CommandBuffer,
fences: []vk.Fence,
delete_queues: []DeleteQueue,
arenas: []std.heap.ArenaAllocator,
bindless: Bindless,
current_frame_index: usize,
tracker: ResourceTracker,
samplers: std.AutoArrayHashMap(SamplerDesc, vk.Sampler),

pub const DeleteQueue = std.ArrayListUnmanaged(union(enum) {
    buffer: Gc.BufferHandle,
    texture: Gc.TextureHandle,
});

pub const SamplerDesc = struct {
    texel_filter: vk.Filter,
    mipmap_mode: vk.SamplerMipmapMode,
    address_mode: vk.SamplerAddressMode,
};

const ResourceTracker = struct {
    pub const TextureResource = struct {
        current_layout: vk.ImageLayout,
        current_access: vk.AccessFlags2,
        current_stage: vk.PipelineStageFlags2,
        current_queue_family: u32 = vk.QUEUE_FAMILY_IGNORED,
    };
    pub const BufferResource = struct {
        current_access: vk.AccessFlags2,
        current_stage: vk.PipelineStageFlags2,
        current_queue_family: u32 = vk.QUEUE_FAMILY_IGNORED,
    };
    pub const Resource = union(enum) {
        texture: TextureResource,
        buffer: BufferResource,
    };
    const ResourceId = union(enum) {
        texture: Gc.TextureHandle,
        buffer: Gc.BufferHandle,
    };

    resources: std.AutoArrayHashMap(ResourceId, Resource),

    pub fn init(allocator: std.mem.Allocator) !ResourceTracker {
        return ResourceTracker{
            .resources = std.AutoArrayHashMap(ResourceId, Resource).init(allocator),
        };
    }

    pub fn reset(self: *ResourceTracker) void {
        self.resources.clearRetainingCapacity();
    }

    pub fn getTexture(self: *ResourceTracker, texture: Gc.TextureHandle) *TextureResource {
        const res = self.resources.getOrPutValue(ResourceId{ .texture = texture }, .{
            .texture = TextureResource{
                .current_layout = .undefined,
                .current_access = .{},
                .current_stage = .{},
            },
        }) catch unreachable;

        return &res.value_ptr.texture;
    }

    pub fn getBuffer(self: *ResourceTracker, buffer: Gc.BufferHandle) *BufferResource {
        const res = self.resources.getOrPutValue(ResourceId{ .buffer = buffer }, .{
            .buffer = BufferResource{
                .current_access = .{},
                .current_stage = .{},
            },
        }) catch unreachable;

        return &res.value_ptr.buffer;
    }
};

const CommandEncoderOptions = struct {
    /// The maximum number of commands that will be allocated and used, will block if a new command is issued while the others are in flight.
    max_inflight: usize,
};
pub fn init(
    gc: *Gc,
    options: CommandEncoderOptions,
) !Self {
    std.log.debug("Creating command encoder with {d} frames in flight", .{options.max_inflight});

    const pool = try gc.device.createCommandPool(&vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);

    const command_buffers = try gc.allocator.alloc(vk.CommandBuffer, options.max_inflight);
    try gc.device.allocateCommandBuffers(&.{
        .command_buffer_count = @intCast(options.max_inflight),
        .command_pool = pool,
        .level = .primary,
    }, command_buffers.ptr);

    for (0..options.max_inflight) |i| {
        try gc.device.beginCommandBuffer(command_buffers[i], &vk.CommandBufferBeginInfo{
            .flags = .{
                .one_time_submit_bit = true,
            },
        });
    }

    const fences = try gc.allocator.alloc(vk.Fence, options.max_inflight);
    for (0..options.max_inflight) |i| {
        fences[i] = try gc.device.createFence(&vk.FenceCreateInfo{
            .flags = .{
                .signaled_bit = true,
            },
        }, null);
    }

    const delete_queues = try gc.allocator.alloc(DeleteQueue, options.max_inflight);
    for (0..options.max_inflight) |i| {
        delete_queues[i] = DeleteQueue{};
    }

    const arenas = try gc.allocator.alloc(std.heap.ArenaAllocator, options.max_inflight);
    for (0..options.max_inflight) |i| {
        arenas[i] = std.heap.ArenaAllocator.init(gc.allocator);
    }

    const bindless = try Bindless.init(gc, options.max_inflight);

    return Self{
        .gc = gc,
        .command_pool = pool,
        .command_buffers = command_buffers,
        .fences = fences,
        .current_frame_index = command_buffers.len - 1,
        .delete_queues = delete_queues,
        .tracker = try ResourceTracker.init(gc.allocator),
        .arenas = arenas,
        .bindless = bindless,
        .samplers = std.AutoArrayHashMap(SamplerDesc, vk.Sampler).init(gc.allocator),
    };
}

pub inline fn getCommandBuffer(self: *Self) vk.CommandBuffer {
    if (self.current_frame_index >= self.command_buffers.len) {
        std.debug.panic("Must reset command encoder before using it", .{});
    }
    return self.command_buffers[self.current_frame_index];
}

/// reset should be called at the beginning of each frame
pub fn reset(self: *Self) !void {
    self.current_frame_index = (self.current_frame_index + 1) % self.command_buffers.len;

    const fence = self.fences[self.current_frame_index];
    const buffer = self.command_buffers[self.current_frame_index];

    _ = try self.gc.device.waitForFences(1, @ptrCast(&fence), vk.TRUE, std.math.maxInt(u32));
    try self.gc.device.resetFences(1, @ptrCast(&fence));
    try self.gc.device.resetCommandBuffer(buffer, .{
        .release_resources_bit = true,
    });

    const delete_queue = &self.delete_queues[self.current_frame_index];
    while (delete_queue.popOrNull()) |item| {
        switch (item) {
            .buffer => |handle| {
                self.gc.destroyBuffer(handle);
            },
            .texture => |handle| {
                self.gc.destroyTexture(handle);
            },
        }
    }
    self.tracker.reset();
    const arena = &self.arenas[self.current_frame_index];
    _ = arena.reset(.retain_capacity);

    try self.bindless.updateDescriptorSet(self.gc, self.getBindlessDescriptorSet(), self.getArena());

    try self.gc.device.beginCommandBuffer(buffer, &vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
    });
}

/// returns the current arena for the frame, will be reset at the beginning of the next frame
pub fn getArena(self: *Self) std.mem.Allocator {
    return self.arenas[self.current_frame_index].allocator();
}

/// submits the current command buffer to the graphics queue, does not BLOCK!!
pub fn submit(self: *Self) !void {
    const buffer = self.command_buffers[self.current_frame_index];
    try self.gc.device.endCommandBuffer(buffer);

    const fence = self.fences[self.current_frame_index];
    try self.gc.device.queueSubmit(self.gc.graphics_queue.handle, 1, @ptrCast(&vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&buffer),
    }), fence);
}

/// submits the current command buffer to the graphics queue, BLOCKS until the command buffer is done executing
pub fn submitBlocking(self: *Self) !void {
    try self.submit();
    const fence = self.fences[self.current_frame_index];
    _ = try self.gc.device.waitForFences(1, @ptrCast(&fence), vk.TRUE, std.math.maxInt(usize));
}

/// transitions the swapchain image to present_src_khr and submits the command buffer and acquires then next swapchain image.
pub fn submitAndPresent(self: *Self, swapchain: *Gc.Swapchain) !Gc.Swapchain.PresentState {
    const barrier = vk.ImageMemoryBarrier2{
        .image = swapchain.currentImage(),
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_stage_mask = .{
            .all_transfer_bit = true,
        },
        .dst_stage_mask = .{
            .bottom_of_pipe_bit = true,
        },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .present_src_khr,
        .src_access_mask = .{
            .transfer_write_bit = true,
        },
        .dst_access_mask = .{},
        .src_queue_family_index = self.gc.graphics_queue.family,
        .dst_queue_family_index = self.gc.present_queue.family,
    };

    self.gc.device.cmdPipelineBarrier2(self.getCommandBuffer(), &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    });
    try self.gc.device.endCommandBuffer(self.getCommandBuffer());

    return try swapchain.present(self.getCommandBuffer(), self.fences[self.current_frame_index]);
}

/// queues a buffer for deletion after the end of the frame
pub fn queueDestroyBuffer(self: *Self, index: Gc.BufferPool.Index) void {
    self.delete_queues[self.current_frame_index].append(self.gc.allocator, .{
        .buffer = index,
    }) catch unreachable;
}

/// queues a texture for deletion after the end of the frame
pub fn queueDestroyTexture(self: *Self, index: Gc.TexturePool.Index) void {
    self.delete_queues[self.current_frame_index].append(self.gc.allocator, .{
        .texture = index,
    }) catch unreachable;
}

// creates or gets a sampler by desc
pub fn sampler(self: *Self, desc: SamplerDesc) !vk.Sampler {
    const gop = try self.samplers.getOrPut(desc);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }

    gop.value_ptr.* = try self.gc.device.createSampler(@ptrCast(&vk.SamplerCreateInfo{
        .mag_filter = desc.texel_filter,
        .min_filter = desc.texel_filter,
        .mipmap_mode = desc.mipmap_mode,
        .address_mode_u = desc.address_mode,
        .address_mode_v = desc.address_mode,
        .address_mode_w = desc.address_mode,
        .mip_lod_bias = 0.0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0.0,
        .max_lod = 0.0,
        .min_lod = 0.0,
        .border_color = vk.BorderColor.float_transparent_black,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = vk.CompareOp.never,
    }), null);

    return gop.value_ptr.*;
}

//
//
// Graphics
//
//

const GraphicsPass = struct {
    encoder: *Self,
    desc: GraphicsPassDesc,
    vertex_buffer_count: u32 = 0,

    pub fn setScissor(self: *GraphicsPass, scissor: vk.Rect2D) void {
        self.encoder.gc.device.cmdSetScissor(
            self.encoder.getCommandBuffer(),
            0,
            1,
            &scissor,
        );
    }
    pub fn setScissors(self: *GraphicsPass, scissors: []const vk.Rect2D) void {
        self.encoder.gc.device.cmdSetScissor(
            self.encoder.getCommandBuffer(),
            0,
            @intCast(scissors.len),
            scissors.ptr,
        );
    }

    pub fn setViewport(self: *GraphicsPass, viewport: vk.Viewport) void {
        self.encoder.gc.device.cmdSetViewport(
            self.encoder.getCommandBuffer(),
            0,
            1,
            &viewport,
        );
    }

    pub fn setViewports(self: *GraphicsPass, viewports: []const vk.Viewport) void {
        self.encoder.gc.device.cmdSetViewport(
            self.encoder.getCommandBuffer(),
            0,
            @intCast(viewports.len),
            viewports.ptr,
        );
    }

    pub fn bindDescriptorSets(self: *GraphicsPass, first_set: u32, sets: []const vk.DescriptorSet) void {
        const layout = self.encoder.gc.graphics_pipelines.getField(self.desc.pipeline, .layout).?;
        self.encoder.gc.device.cmdBindDescriptorSets(
            self.encoder.getCommandBuffer(),
            .graphics,
            layout,
            first_set,
            @intCast(sets.len),
            sets.ptr,
            0,
            null,
        );
    }

    pub fn setPushConstants(
        self: *GraphicsPass,
        data: []const u8,
        offset: u32,
    ) void {
        const layout = self.encoder.gc.graphics_pipelines.getField(self.desc.pipeline, .layout).?;
        self.encoder.gc.device.cmdPushConstants(
            self.encoder.getCommandBuffer(),
            layout,
            vk.ShaderStageFlags{
                .vertex_bit = true,
                .fragment_bit = true,
            },
            offset,
            @intCast(data.len),
            data.ptr,
        );
    }

    pub fn setVertexBuffer(self: *GraphicsPass, buffer: Gc.BufferHandle) void {
        const vk_handle = self.encoder.gc.buffers.getField(buffer, .buffer).?;
        self.encoder.gc.device.cmdBindVertexBuffers(
            self.encoder.getCommandBuffer(),
            self.vertex_buffer_count,
            1,
            @ptrCast(&vk_handle),
            &.{0},
        );
        self.vertex_buffer_count += 1;
    }

    pub fn setIndexBuffer(self: *GraphicsPass, buffer: Gc.BufferHandle, index_type: vk.IndexType) void {
        const vk_handle = self.encoder.gc.buffers.getField(buffer, .buffer).?;
        self.encoder.gc.device.cmdBindIndexBuffer(
            self.encoder.getCommandBuffer(),
            vk_handle,
            0,
            index_type,
        );
    }

    const DrawInfo = struct {
        vertex_count: u32,
        instance_count: u32 = 1,
        first_vertex: u32 = 0,
        first_instance: u32 = 0,
    };
    pub fn draw(self: *GraphicsPass, info: DrawInfo) void {
        self.encoder.gc.device.cmdDraw(
            self.encoder.getCommandBuffer(),
            info.vertex_count,
            info.instance_count,
            info.first_vertex,
            info.first_instance,
        );
    }

    const DrawIndexedInfo = struct {
        index_count: u32,
        instance_count: u32 = 1,
        index_offset: u32 = 0,
        vertex_offset: i32 = 0,
        first_instance: u32 = 0,
    };
    pub fn drawIndexed(self: *GraphicsPass, info: DrawIndexedInfo) void {
        self.encoder.gc.device.cmdDrawIndexed(
            self.encoder.getCommandBuffer(),
            info.index_count,
            info.instance_count,
            info.index_offset,
            info.vertex_offset,
            info.first_instance,
        );
    }
};
pub const GraphicsPassDesc = struct {
    const Auto = packed struct {
        bind_descriptors: bool = true,
        bind_scissor: bool = true,
        bind_viewport: bool = true,
    };
    pub const ColorAttachment = struct {
        handle: Gc.TextureHandle,
        load_op: vk.AttachmentLoadOp,
        store_op: vk.AttachmentStoreOp,
        clear_color: vk.ClearColorValue,
    };
    pub const DepthAttachment = struct {
        handle: Gc.TextureHandle,
        load_op: vk.AttachmentLoadOp,
        store_op: vk.AttachmentStoreOp,
        clear_value: vk.ClearDepthStencilValue,
    };
    pipeline: Gc.GraphicsPipelineHandle,
    color_attachments: []const ColorAttachment,
    depth_attachment: ?DepthAttachment,
    auto: Auto = .{},
};
pub fn startGraphicsPass(self: *Self, desc: GraphicsPassDesc) !GraphicsPass {
    const pipeline: Gc.GraphicsPipeline = self.gc.graphics_pipelines.get(desc.pipeline).?;
    self.gc.device.cmdBindPipeline(self.getCommandBuffer(), .graphics, pipeline.pipeline);

    var color_rendering_attachments = try self.getArena().alloc(vk.RenderingAttachmentInfo, desc.color_attachments.len);

    var render_area: ?vk.Rect2D = null;

    for (desc.color_attachments, 0..) |attachment, index| {
        const texture = self.gc.textures.get(attachment.handle).?;
        color_rendering_attachments[index] = vk.RenderingAttachmentInfo{
            .image_view = texture.view,
            .image_layout = vk.ImageLayout.color_attachment_optimal,
            .load_op = attachment.load_op,
            .store_op = attachment.store_op,
            .clear_value = .{
                .color = attachment.clear_color,
            },
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        };

        render_area = .{
            .extent = .{
                .width = texture.dimensions.width,
                .height = texture.dimensions.height,
            },
            .offset = .{ .x = 0, .y = 0 },
        };
    }

    var maybe_depth_attachment: ?vk.RenderingAttachmentInfo = null;
    if (desc.depth_attachment) |depth_attachment| {
        const texture = self.gc.textures.get(depth_attachment.handle).?;
        maybe_depth_attachment = vk.RenderingAttachmentInfo{
            .image_view = texture.view,
            .image_layout = vk.ImageLayout.depth_stencil_attachment_optimal,
            .load_op = depth_attachment.load_op,
            .store_op = depth_attachment.store_op,
            .clear_value = .{
                .depth_stencil = depth_attachment.clear_value,
            },
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        };
    }

    const rendering_info = vk.RenderingInfo{
        .render_area = render_area.?,
        .color_attachment_count = @intCast(color_rendering_attachments.len),
        .p_color_attachments = color_rendering_attachments.ptr,
        .p_depth_attachment = if (maybe_depth_attachment != null) &maybe_depth_attachment.? else null,
        .layer_count = 1,
        .view_mask = 0,
    };

    self.gc.device.cmdBeginRendering(self.getCommandBuffer(), &rendering_info);

    if (desc.auto.bind_descriptors) {
        if (pipeline.sets.len > 0) {
            self.gc.device.cmdBindDescriptorSets(
                self.getCommandBuffer(),
                .graphics,
                pipeline.layout,
                pipeline.first_set,
                @intCast(pipeline.sets.len),
                pipeline.sets.ptr,
                0,
                null,
            );
        }
    }

    if (desc.auto.bind_viewport) {
        self.gc.device.cmdSetViewport(self.getCommandBuffer(), 0, 1, @ptrCast(&vk.Viewport{
            .x = @floatFromInt(rendering_info.render_area.offset.x),
            .y = @floatFromInt(rendering_info.render_area.offset.y),
            .width = @floatFromInt(rendering_info.render_area.extent.width),
            .height = @floatFromInt(rendering_info.render_area.extent.height),
            .min_depth = 0.0,
            .max_depth = 1.0,
        }));
    }

    if (desc.auto.bind_scissor) {
        self.gc.device.cmdSetScissor(self.getCommandBuffer(), 0, 1, @ptrCast(&vk.Rect2D{
            .offset = rendering_info.render_area.offset,
            .extent = rendering_info.render_area.extent,
        }));
    }

    return GraphicsPass{
        .encoder = self,
        .desc = desc,
    };
}

pub fn endGraphicsPass(self: *Self, pass: GraphicsPass) void {
    _ = pass; // autofix
    self.gc.device.cmdEndRendering(self.getCommandBuffer());
}

//
//
// Compute
//
//

pub const ComputePass = struct {
    encoder: *Self,
    desc: ComputePassDesc,

    pub fn bindDescriptorSets(self: *ComputePass, first_set: u32, sets: []const vk.DescriptorSet) void {
        const layout = self.encoder.gc.compute_pipelines.getField(self.desc.pipeline, .layout).?;
        self.encoder.gc.device.cmdBindDescriptorSets(
            self.encoder.getCommandBuffer(),
            .compute,
            layout,
            first_set,
            @intCast(sets.len),
            sets.ptr,
            0,
            null,
        );
    }

    pub fn setPushConstants(
        self: *ComputePass,
        data: []const u8,
        offset: u32,
    ) void {
        const layout = self.encoder.gc.compute_pipelines.getField(self.desc.pipeline, .layout).?;
        self.encoder.gc.device.cmdPushConstants(
            self.encoder.getCommandBuffer(),
            layout,
            vk.ShaderStageFlags{
                .compute_bit = true,
            },
            offset,
            @intCast(data.len),
            data.ptr,
        );
    }

    pub fn dispatch(self: *ComputePass, x: u32, y: u32, z: u32) void {
        self.encoder.gc.device.cmdDispatch(
            self.encoder.getCommandBuffer(),
            x,
            y,
            z,
        );
    }
};

pub const ComputePassDesc = struct {
    const Auto = packed struct {
        bind_descriptors: bool = true,
    };
    pipeline: Gc.ComputePipelineHandle,
    auto: Auto = .{},
};

pub fn startComputePass(self: *Self, desc: ComputePassDesc) !ComputePass {
    const pipeline: Gc.ComputePipeline = self.gc.compute_pipelines.get(desc.pipeline).?;
    self.gc.device.cmdBindPipeline(self.getCommandBuffer(), .compute, pipeline.pipeline);

    if (desc.auto.bind_descriptors) {
        if (pipeline.sets.len > 0) {
            self.gc.device.cmdBindDescriptorSets(
                self.getCommandBuffer(),
                .compute,
                pipeline.layout,
                pipeline.first_set,
                @intCast(pipeline.sets.len),
                pipeline.sets.ptr,
                0,
                null,
            );
        }
    }

    return ComputePass{
        .encoder = self,
        .desc = desc,
    };
}

pub fn endComputePass(self: *Self, pass: ComputePass) void {
    _ = pass; // autofix
    _ = self; // autofix

}

//
//
// Bindless
//
//

const Bindless = struct {
    const DescriptorTypes = enum(u32) {
        uniform_buffer = 0,
        storage_buffer = 1,
        sampled_image = 2,
        storage_image = 3,
        acceleration_structure = 4,

        pub fn toDescriptorType(self: DescriptorTypes) vk.DescriptorType {
            switch (self) {
                .uniform_buffer => return vk.DescriptorType.uniform_buffer,
                .storage_buffer => return vk.DescriptorType.storage_buffer,
                .sampled_image => return vk.DescriptorType.combined_image_sampler,
                .storage_image => return vk.DescriptorType.storage_image,
                .acceleration_structure => return vk.DescriptorType.acceleration_structure_khr,
            }
        }
    };
    const BINDING_COUNT: comptime_int = std.meta.fields(DescriptorTypes).len;

    const CombinedImageSampler = struct {
        image: Gc.TextureHandle,
        sampler: vk.Sampler,
    };
    // const SamplerHandle = struct {
    //     index: u32,
    //     inner: vk.Sampler,
    // };
    pub const BoundDescriptor = union(DescriptorTypes) {
        uniform_buffer: Gc.BufferHandle,
        storage_buffer: Gc.BufferHandle,
        sampled_image: CombinedImageSampler,
        storage_image: Gc.TextureHandle,
        acceleration_structure: vk.AccelerationStructureKHR,
    };

    set_layout: vk.DescriptorSetLayout,
    pools: []vk.DescriptorPool,
    sets: []vk.DescriptorSet,
    bound_descriptors: std.ArrayList(BoundDescriptor),

    pub fn init(gc: *Gc, sets_amount: usize) !Bindless {
        const uniform_buffer_count = @min(std.math.maxInt(u16), gc.physical_device_properties.limits.max_descriptor_set_uniform_buffers);
        const storage_buffer_count = @min(std.math.maxInt(u16), gc.physical_device_properties.limits.max_per_stage_descriptor_storage_buffers);
        const sampled_image_count = @min(std.math.maxInt(u16), gc.physical_device_properties.limits.max_per_stage_descriptor_sampled_images);
        const storage_image_count = @min(std.math.maxInt(u16), gc.physical_device_properties.limits.max_per_stage_descriptor_storage_images);

        const pool_sizes = [BINDING_COUNT]vk.DescriptorPoolSize{
            vk.DescriptorPoolSize{
                .type = vk.DescriptorType.uniform_buffer,
                .descriptor_count = uniform_buffer_count,
            },
            vk.DescriptorPoolSize{
                .type = vk.DescriptorType.storage_buffer,
                .descriptor_count = storage_buffer_count,
            },
            vk.DescriptorPoolSize{
                .type = vk.DescriptorType.combined_image_sampler,
                .descriptor_count = sampled_image_count,
            },
            vk.DescriptorPoolSize{
                .type = vk.DescriptorType.storage_image,
                .descriptor_count = storage_image_count,
            },
            vk.DescriptorPoolSize{
                .type = vk.DescriptorType.acceleration_structure_khr,
                .descriptor_count = 1,
            },
        };

        const bindings = [BINDING_COUNT]vk.DescriptorSetLayoutBinding{
            vk.DescriptorSetLayoutBinding{
                .binding = 0,
                .descriptor_count = uniform_buffer_count,
                .descriptor_type = vk.DescriptorType.uniform_buffer,
                .stage_flags = vk.ShaderStageFlags.fromInt(2147483647),
                .p_immutable_samplers = null,
            },
            vk.DescriptorSetLayoutBinding{
                .binding = 1,
                .descriptor_count = storage_buffer_count,
                .descriptor_type = vk.DescriptorType.storage_buffer,
                .stage_flags = vk.ShaderStageFlags.fromInt(2147483647),
                .p_immutable_samplers = null,
            },
            vk.DescriptorSetLayoutBinding{
                .binding = 2,
                .descriptor_count = sampled_image_count,
                .descriptor_type = vk.DescriptorType.combined_image_sampler,
                .stage_flags = vk.ShaderStageFlags.fromInt(2147483647),
                .p_immutable_samplers = null,
            },
            vk.DescriptorSetLayoutBinding{
                .binding = 3,
                .descriptor_count = storage_image_count,
                .descriptor_type = vk.DescriptorType.storage_image,
                .stage_flags = vk.ShaderStageFlags.fromInt(2147483647),
                .p_immutable_samplers = null,
            },
            vk.DescriptorSetLayoutBinding{
                .binding = 4,
                .descriptor_count = 1,
                .descriptor_type = vk.DescriptorType.acceleration_structure_khr,
                .stage_flags = vk.ShaderStageFlags.fromInt(2147483647),
                .p_immutable_samplers = null,
            },
        };

        const binding_flags = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .p_binding_flags = &[BINDING_COUNT]vk.DescriptorBindingFlags{
                vk.DescriptorBindingFlags{ .partially_bound_bit = true, .update_after_bind_bit = true },
                vk.DescriptorBindingFlags{ .partially_bound_bit = true, .update_after_bind_bit = true },
                vk.DescriptorBindingFlags{ .partially_bound_bit = true, .update_after_bind_bit = true },
                vk.DescriptorBindingFlags{ .partially_bound_bit = true, .update_after_bind_bit = true },
                vk.DescriptorBindingFlags{ .partially_bound_bit = true, .update_after_bind_bit = true },
            },
        };

        std.debug.assert(pool_sizes.len == bindings.len);
        for (0..pool_sizes.len) |i| {
            std.debug.assert(pool_sizes[i].type == bindings[i].descriptor_type);
            std.debug.assert(pool_sizes[i].descriptor_count == bindings[i].descriptor_count);
        }

        const set_layout = try gc.device.createDescriptorSetLayout(&.{
            .binding_count = bindings.len,
            .p_bindings = &bindings,
            .flags = .{
                .update_after_bind_pool_bit = true,
            },
            .p_next = @ptrCast(&binding_flags),
        }, null);

        const pools = try gc.allocator.alloc(vk.DescriptorPool, sets_amount);
        const sets = try gc.allocator.alloc(vk.DescriptorSet, sets_amount);
        for (0..sets_amount) |i| {
            pools[i] = try gc.device.createDescriptorPool(&.{
                .pool_size_count = pool_sizes.len,
                .p_pool_sizes = &pool_sizes,
                .max_sets = 1,
                .flags = .{
                    .update_after_bind_bit = true,
                },
            }, null);

            try gc.device.allocateDescriptorSets(&.{
                .descriptor_pool = pools[i],
                .descriptor_set_count = 1,
                .p_set_layouts = @ptrCast(&set_layout),
            }, @ptrCast(&sets[i]));
        }

        // const texel_filters = [_]vk.Filter{
        //     vk.Filter.nearest,
        //     vk.Filter.linear,
        // };
        // const mipmap_modes = [_]vk.SamplerMipmapMode{
        //     vk.SamplerMipmapMode.nearest,
        //     vk.SamplerMipmapMode.linear,
        // };
        // const address_modes = [_]vk.SamplerAddressMode{
        //     vk.SamplerAddressMode.repeat,
        //     vk.SamplerAddressMode.clamp_to_edge,
        //     // vk.SamplerAddressMode.mirrored_repeat,
        //     // vk.SamplerAddressMode.clamp_to_border,
        //     // vk.SamplerAddressMode.mirror_clamp_to_edge,
        // };
        // var bound_descriptors = std.ArrayList(BoundDescriptor).init(gc.allocator);
        // // set samplers
        // for (texel_filters, 0..) |filter, x| {
        //     for (mipmap_modes, 0..) |mipmap_mode, y| {
        //         for (address_modes, 0..) |address_mode, z| {
        //             // TODO: add anisotropy
        //             const anisotropy_enable: u32 = vk.FALSE;
        //             const max_anisotropy = 16.0;
        //             const max_lod = vk.LOD_CLAMP_NONE;

        //             const sampler = try gc.device.createSampler(@ptrCast(&vk.SamplerCreateInfo{
        //                 .mag_filter = filter,
        //                 .min_filter = filter,
        //                 .mipmap_mode = mipmap_mode,
        //                 .address_mode_u = address_mode,
        //                 .address_mode_v = address_mode,
        //                 .address_mode_w = address_mode,
        //                 .mip_lod_bias = 0.0,
        //                 .anisotropy_enable = anisotropy_enable,
        //                 .max_anisotropy = max_anisotropy,
        //                 .max_lod = max_lod,
        //                 .min_lod = 0.0,
        //                 .border_color = vk.BorderColor.float_transparent_black,
        //                 .unnormalized_coordinates = vk.FALSE,
        //                 .compare_enable = vk.FALSE,
        //                 .compare_op = vk.CompareOp.never,
        //             }), null);

        //             try bound_descriptors.append(.{ .sampler = SamplerHandle{
        //                 .index = @intCast(x * mipmap_modes.len * address_modes.len + y * address_modes.len + z),
        //                 .inner = sampler,
        //             } });
        //         }
        //     }
        // }

        return Bindless{
            .set_layout = set_layout,
            .pools = pools,
            .sets = sets,
            .bound_descriptors = std.ArrayList(BoundDescriptor).init(gc.allocator),
        };
    }

    fn getWriteData(self: *Bindless, gc: *Gc, arena: std.mem.Allocator, set: vk.DescriptorSet, desc: BoundDescriptor) !?vk.WriteDescriptorSet {
        _ = self; // autofix
        const enu = std.meta.activeTag(desc);

        const index = switch (desc) {
            .uniform_buffer => |h| h.index,
            .storage_buffer => |h| h.index,
            .sampled_image => |h| h.image.index,
            .storage_image => |h| h.index,
            .acceleration_structure => 0,
        };

        var image_info = std.ArrayList(vk.DescriptorImageInfo).init(arena);
        var buffer_info = std.ArrayList(vk.DescriptorBufferInfo).init(arena);
        var accel_info: ?*vk.WriteDescriptorSetAccelerationStructureKHR = null;

        switch (desc) {
            // .sampler => |handle| {
            //     try image_info.append(vk.DescriptorImageInfo{
            //         .sampler = handle.inner,
            //         .image_view = .null_handle,
            //         .image_layout = vk.ImageLayout.undefined,
            //     });
            // },
            .sampled_image => |handle| {
                const texture = gc.textures.get(handle.image) orelse return null;
                try image_info.append(vk.DescriptorImageInfo{
                    .sampler = handle.sampler,
                    .image_view = texture.view,
                    .image_layout = vk.ImageLayout.shader_read_only_optimal,
                });
            },
            .storage_image => |handle| {
                const texture = gc.textures.get(handle) orelse return null;
                try image_info.append(vk.DescriptorImageInfo{
                    .sampler = .null_handle,
                    .image_view = texture.view,
                    .image_layout = vk.ImageLayout.general,
                });
            },
            .uniform_buffer => |handle| {
                const buffer = gc.buffers.get(handle) orelse return null;
                try buffer_info.append(vk.DescriptorBufferInfo{
                    .buffer = buffer.buffer,
                    .offset = 0,
                    .range = buffer.size,
                });
            },
            .storage_buffer => |handle| {
                const buffer = gc.buffers.get(handle) orelse return null;
                try buffer_info.append(vk.DescriptorBufferInfo{
                    .buffer = buffer.buffer,
                    .offset = 0,
                    .range = buffer.size,
                });
            },
            .acceleration_structure => |structure| {
                const ptrs = try arena.alloc(vk.AccelerationStructureKHR, 1);
                ptrs[0] = structure;

                accel_info = try arena.create(vk.WriteDescriptorSetAccelerationStructureKHR);
                accel_info.?.* = vk.WriteDescriptorSetAccelerationStructureKHR{
                    .acceleration_structure_count = @intCast(ptrs.len),
                    .p_acceleration_structures = ptrs.ptr,
                };
            },
        }

        return vk.WriteDescriptorSet{
            .dst_set = set,
            .dst_binding = @intFromEnum(desc),
            .dst_array_element = index,
            .descriptor_type = enu.toDescriptorType(),
            .descriptor_count = 1,
            .p_image_info = image_info.items.ptr,
            .p_buffer_info = buffer_info.items.ptr,
            .p_texel_buffer_view = &[0]vk.BufferView{},
            .p_next = if (accel_info != null) accel_info.? else null,
        };
    }

    pub fn updateDescriptorSet(self: *Bindless, gc: *Gc, set: vk.DescriptorSet, arena: std.mem.Allocator) !void {
        var writes = std.ArrayList(vk.WriteDescriptorSet).init(arena);

        for (self.bound_descriptors.items) |desc| {
            const maybe_write = try self.getWriteData(gc, arena, set, desc);

            if (maybe_write) |write| {
                try writes.append(write);
            }
        }

        gc.device.updateDescriptorSets(@intCast(writes.items.len), writes.items.ptr, 0, null);
    }
};

pub fn addToBindless(self: *Self, desc: Bindless.BoundDescriptor) !void {
    try self.bindless.bound_descriptors.append(desc);
}

/// Instantly writes the resource to the bindless descriptor set, with no bookkeeping.
///
/// Use this when you need to bind a resource and access it in the same frame.
pub fn writeToBindless(self: *Self, desc: Bindless.BoundDescriptor) !void {
    self.gc.device.updateDescriptorSets(
        @intCast(1),
        @ptrCast(&try self.bindless.getWriteData(self.gc, self.getArena(), self.getBindlessDescriptorSet(), desc)),
        0,
        null,
    );
}

pub fn getBindlessDescriptorSet(self: *Self) vk.DescriptorSet {
    return self.bindless.sets[self.current_frame_index];
}
pub fn getBindlessDescriptorSetLayout(self: *Self) vk.DescriptorSetLayout {
    return self.bindless.set_layout;
}

//
//
// Buffers
//
//

pub fn writeBuffer(self: *Self, buffer: Gc.BufferHandle, data: []const u8) !void {
    var staging_buffer = try Gc.Buffer.create(self.gc, .{
        .usage = vk.BufferUsageFlags{
            .transfer_src_bit = true,
        },
        .size = data.len,
        .name = "staging buffer",
    });
    staging_buffer.setData(self.gc, data.ptr, data.len);

    const vk_buffer = self.gc.buffers.getField(buffer, .buffer).?;
    self.gc.device.cmdCopyBuffer(
        self.getCommandBuffer(),
        staging_buffer.buffer,
        vk_buffer,
        1,
        @ptrCast(&vk.BufferCopy{
            .src_offset = 0,
            .dst_offset = 0,
            .size = data.len,
        }),
    );

    const staging = try self.gc.buffers.append(self.gc.allocator, staging_buffer);
    self.queueDestroyBuffer(staging);
}

pub fn writeTexture(self: *Self, handle: Gc.TextureHandle, data: []const u8) !void {
    var staging_buffer = try Gc.Buffer.create(self.gc, .{
        .usage = vk.BufferUsageFlags{
            .transfer_src_bit = true,
        },
        .size = data.len,
        .name = "staging buffer",
    });
    staging_buffer.setData(self.gc, data.ptr, data.len);

    const layout = self.tracker.getTexture(handle).current_layout;

    const texture = self.gc.textures.get(handle).?;
    self.gc.device.cmdCopyBufferToImage(
        self.getCommandBuffer(),
        staging_buffer.buffer,
        texture.image,
        layout,
        1,
        @ptrCast(&vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = texture.dimensions.width,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = texture.dimensions,
        }),
    );
}
//
//
// Barriers
//
//
const MemoryBarrierInput = struct {
    src_stage_mask: vk.PipelineStageFlags2,
    src_access_mask: vk.AccessFlags2,
    dst_stage_mask: vk.PipelineStageFlags2,
    dst_access_mask: vk.AccessFlags2,
};
pub fn memoryBarrier(self: *Self, input: MemoryBarrierInput) void {
    const memorybarrier = vk.MemoryBarrier2{
        .src_stage_mask = input.src_stage_mask,
        .src_access_mask = input.src_access_mask,
        .dst_stage_mask = input.dst_stage_mask,
        .dst_access_mask = input.dst_access_mask,
    };

    self.gc.device.cmdPipelineBarrier2(self.getCommandBuffer(), &.{
        .memory_barrier_count = 1,
        .p_memory_barriers = @ptrCast(&memorybarrier),
    });
}

pub fn fullBarrierDebug(self: *Self) void {
    const memorybarrier = vk.MemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
    };

    self.gc.device.cmdPipelineBarrier2(self.getCommandBuffer(), &.{
        .memory_barrier_count = 1,
        .p_memory_barriers = @ptrCast(&memorybarrier),
    });
}

const CreateImageBarrierInfo = struct {
    new_stage_mask: vk.PipelineStageFlags2 = .{},
    new_access_mask: vk.AccessFlags2 = .{},
    new_layout: vk.ImageLayout,
    queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
};
pub fn imageBarrier(self: *Self, image: Gc.TextureHandle, info: CreateImageBarrierInfo) void {
    const current_status = self.tracker.getTexture(image);
    const texture = self.gc.textures.get(image).?;
    const barrier = vk.ImageMemoryBarrier2{
        .image = texture.image,
        .subresource_range = texture.getResourceRange(),
        .src_stage_mask = current_status.current_stage,
        .dst_stage_mask = info.new_stage_mask,
        .src_access_mask = current_status.current_access,
        .dst_access_mask = info.new_access_mask,
        .old_layout = current_status.current_layout,
        .new_layout = info.new_layout,
        .src_queue_family_index = current_status.current_queue_family,
        .dst_queue_family_index = info.queue_family_index,
    };
    self.gc.device.cmdPipelineBarrier2(self.getCommandBuffer(), &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    });
    current_status.* = .{
        .current_layout = info.new_layout,
        .current_access = info.new_access_mask,
        .current_stage = info.new_stage_mask,
        .current_queue_family = info.queue_family_index,
    };
}

pub const CreateBufferBarrierInfo = struct {
    new_stage_mask: vk.PipelineStageFlags2 = .{
        .top_of_pipe_bit = true,
    },
    new_access_mask: vk.AccessFlags2 = .{},
    queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
};

pub fn bufferBarrier(self: *Self, buffer: Gc.BufferHandle, info: CreateBufferBarrierInfo) void {
    return self.bufferBarriers(&.{buffer}, info);
}

pub fn bufferBarriers(self: *Self, buffers: []const Gc.BufferHandle, info: CreateBufferBarrierInfo) void {
    const barriers = self.getArena().alloc(vk.BufferMemoryBarrier2, buffers.len) catch unreachable;
    for (buffers, 0..) |buffer, i| {
        const current_status = self.tracker.getBuffer(buffer);
        const vk_buffer = self.gc.buffers.getField(buffer, .buffer).?;
        const buffer_size = self.gc.buffers.getField(buffer, .size).?;
        barriers[i] = vk.BufferMemoryBarrier2{
            .buffer = vk_buffer,
            .offset = 0,
            .size = buffer_size,
            .src_stage_mask = current_status.current_stage,
            .dst_stage_mask = info.new_stage_mask,
            .src_access_mask = current_status.current_access,
            .dst_access_mask = info.new_access_mask,
            .src_queue_family_index = current_status.current_queue_family,
            .dst_queue_family_index = info.queue_family_index,
        };
        current_status.* = .{
            .current_access = info.new_access_mask,
            .current_stage = info.new_stage_mask,
            .current_queue_family = info.queue_family_index,
        };
    }

    self.gc.device.cmdPipelineBarrier2(self.getCommandBuffer(), &.{
        .buffer_memory_barrier_count = @intCast(buffers.len),
        .p_buffer_memory_barriers = barriers.ptr,
    });
}

//
//
// General transfer operations
//
//

pub fn blitToSurface(self: *Self, swapchain: *Gc.Swapchain, texture: Gc.TextureHandle) void {
    // barrier for swapchain
    const barrier = vk.ImageMemoryBarrier2{
        .image = swapchain.currentImage(),
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_stage_mask = .{},
        .dst_stage_mask = .{
            .blit_bit = true,
        },
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .src_access_mask = .{},
        .dst_access_mask = .{ .transfer_write_bit = true },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
    };

    self.gc.device.cmdPipelineBarrier2(self.getCommandBuffer(), &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    });

    const src = self.gc.textures.get(texture).?;
    const dst = swapchain.currentImage();

    self.gc.device.cmdBlitImage(
        self.getCommandBuffer(),
        src.image,
        .transfer_src_optimal,
        dst,
        .transfer_dst_optimal,
        1,
        @ptrCast(&vk.ImageBlit{
            .src_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .dst_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_offsets = .{
                vk.Offset3D{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                vk.Offset3D{
                    .x = @intCast(src.dimensions.width),
                    .y = @intCast(src.dimensions.height),
                    .z = 1,
                },
            },
            .dst_offsets = .{
                vk.Offset3D{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                vk.Offset3D{
                    .x = @intCast(swapchain.extent.width),
                    .y = @intCast(swapchain.extent.height),
                    .z = 1,
                },
            },
        }),
        .linear,
    );
}
