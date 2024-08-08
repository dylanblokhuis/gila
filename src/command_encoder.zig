const Gc = @import("root.zig");
const std = @import("std");
const vk = Gc.vk;

const Self = @This();

gc: *Gc,
command_pool: vk.CommandPool,
command_buffers: []vk.CommandBuffer,
fences: []vk.Fence,
delete_queues: []DeleteQueue,
current_frame_index: usize,
tracker: ResourceTracker,

pub const DeleteQueue = std.ArrayListUnmanaged(union(enum) {
    buffer: Gc.BufferHandle,
    texture: Gc.TextureHandle,
});

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

    // stage_mask: vk.PipelineStageFlags2,
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

    return Self{
        .gc = gc,
        .command_pool = pool,
        .command_buffers = command_buffers,
        .fences = fences,
        .current_frame_index = command_buffers.len - 1,
        .delete_queues = delete_queues,
        .tracker = try ResourceTracker.init(gc.allocator),
    };
}

inline fn getCommandBuffer(self: *Self) vk.CommandBuffer {
    if (self.current_frame_index >= self.command_buffers.len) {
        std.debug.panic("Must reset command encoder before using it", .{});
    }
    return self.command_buffers[self.current_frame_index];
}

// reset should be called at the beginning of each frame
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
    try self.gc.device.beginCommandBuffer(buffer, &vk.CommandBufferBeginInfo{
        .flags = .{
            .one_time_submit_bit = true,
        },
    });
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
        .src_stage_mask = .{},
        .dst_stage_mask = .{},
        .old_layout = .transfer_dst_optimal,
        .new_layout = .present_src_khr,
        .src_access_mask = .{},
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

const GraphicsPass = struct {
    encoder: *Self,
    desc: GraphicsPassDesc,
    vertex_buffer_count: u32 = 0,

    pub fn setScissor(self: *GraphicsPass, scissor: vk.Rect2D) void {
        self.auto.bind_scissor = false;
        self.encoder.gc.device.cmdSetScissor(
            self.encoder.getCommandBuffer(),
            0,
            1,
            &scissor,
        );
    }
    pub fn setScissors(self: *GraphicsPass, scissors: []const vk.Rect2D) void {
        self.auto.bind_scissor = false;
        self.encoder.gc.device.cmdSetScissor(
            self.encoder.getCommandBuffer(),
            0,
            @intCast(scissors.len),
            scissors.ptr,
        );
    }

    pub fn setViewport(self: *GraphicsPass, viewport: vk.Viewport) void {
        self.auto.bind_viewport = false;
        self.encoder.gc.device.cmdSetViewport(
            self.encoder.getCommandBuffer(),
            0,
            1,
            &viewport,
        );
    }

    pub fn setViewports(self: *GraphicsPass, viewports: []const vk.Viewport) void {
        self.auto.bind_viewport = false;
        self.encoder.gc.device.cmdSetViewport(
            self.encoder.getCommandBuffer(),
            0,
            @intCast(viewports.len),
            viewports.ptr,
        );
    }

    pub fn setDescriptorSets(self: *GraphicsPass, first_set: u32, sets: []const vk.DescriptorSet) void {
        self.auto.bind_descriptors = false;
        self.encoder.gc.device.cmdBindDescriptorSets(
            self.encoder.getCommandBuffer(),
            .graphics,
            self.pipeline.layout,
            first_set,
            @intCast(sets.len),
            sets.ptr,
            0,
            null,
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
        first_index: u32 = 0,
        vertex_offset: i32 = 0,
        first_instance: u32 = 0,
    };
    pub fn drawIndexed(self: *GraphicsPass, info: DrawIndexedInfo) void {
        self.encoder.gc.device.cmdDrawIndexed(
            self.encoder.getCommandBuffer(),
            info.index_count,
            info.instance_count,
            info.first_index,
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

    var color_rendering_attachments = self.gc.allocator.alloc(vk.RenderingAttachmentInfo, desc.color_attachments.len) catch unreachable;

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
        const sets = try pipeline.getDescriptorSetsCombined(self.gc);
        if (sets.len > 0) {
            self.gc.device.cmdBindDescriptorSets(
                self.getCommandBuffer(),
                .graphics,
                pipeline.layout,
                0,
                @intCast(sets.len),
                sets.ptr,
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

fn queueDestroyBuffer(self: *Self, index: Gc.BufferPool.Index) void {
    self.delete_queues[self.current_frame_index].append(self.gc.allocator, .{
        .buffer = index,
    }) catch unreachable;
}

pub fn writeBuffer(self: *Self, buffer: Gc.BufferHandle, data: []const u8) !void {
    var staging_buffer = try Gc.Buffer.create(self.gc, .{
        .location = .cpu_to_gpu,
        .usage = vk.BufferUsageFlags{
            .transfer_src_bit = true,
        },
        .size = data.len,
        .name = "staging buffer",
    });
    staging_buffer.setData(self.gc, data.ptr, data.len);

    // var desc = create_desc;
    // desc.usage.transfer_dst_bit = true;
    // if (desc.size == 0) {
    //     desc.size = copy_info.data_len;
    // }

    // const buffer = try Buffer.create(self, desc);
    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = data.len,
    };

    const vk_buffer = self.gc.buffers.getField(buffer, .buffer).?;
    self.gc.device.cmdCopyBuffer(self.getCommandBuffer(), staging_buffer.buffer, vk_buffer, 1, @ptrCast(&region));

    const staging = try self.gc.buffers.append(self.gc.allocator, staging_buffer);
    self.queueDestroyBuffer(staging);
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
    new_stage_mask: vk.PipelineStageFlags2 = .{},
    new_access_mask: vk.AccessFlags2 = .{},
    queue_family_index: u32 = vk.QUEUE_FAMILY_IGNORED,
};

pub fn bufferBarrier(self: *Self, buffer: Gc.BufferHandle, info: CreateBufferBarrierInfo) void {
    const current_status = self.tracker.getBuffer(buffer);
    const vk_buffer = self.gc.buffers.getField(buffer, .buffer).?;
    const barrier = vk.BufferMemoryBarrier2{
        .buffer = vk_buffer,
        .offset = 0,
        .size = vk.WHOLE_SIZE,
        .src_stage_mask = current_status.current_stage,
        .dst_stage_mask = info.new_stage_mask,
        .src_access_mask = current_status.current_access,
        .dst_access_mask = info.new_access_mask,
        .src_queue_family_index = current_status.current_queue_family,
        .dst_queue_family_index = info.queue_family_index,
    };
    self.gc.device.cmdPipelineBarrier2(self.getCommandBuffer(), &.{
        .buffer_memory_barrier_count = 1,
        .p_buffer_memory_barriers = @ptrCast(&barrier),
    });
    current_status.* = .{
        .current_access = info.new_access_mask,
        .current_stage = info.new_stage_mask,
        .current_queue_family = info.queue_family_index,
    };
}

pub fn blitToSurface(self: *Self, swapchain: *Gc.Swapchain, color_attachment: Gc.TextureHandle) void {
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

    const src = self.gc.textures.get(color_attachment).?;
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
    // self.gc.device.cmdBlitImage(self.getCommandBuffer(), @ptrCast(&vk.BlitImageInfo2{
    //     .dst_image = dst,
    //     .dst_image_layout = .transfer_dst_optimal,
    //     .src_image = src.image,
    //     .src_image_layout = .transfer_src_optimal,
    //     .filter = .linear,
    //     .region_count = 1,
    //     .p_regions = @ptrCast(&vk.ImageBlit2{
    //         .src_subresource = .{
    //             .aspect_mask = .{ .color_bit = true },
    //             .mip_level = 0,
    //             .base_array_layer = 0,
    //             .layer_count = 1,
    //         },
    //         .dst_subresource = .{
    //             .aspect_mask = .{ .color_bit = true },
    //             .mip_level = 0,
    //             .base_array_layer = 0,
    //             .layer_count = 1,
    //         },
    //         .src_offsets = .{
    //             vk.Offset3D{
    //                 .x = 0,
    //                 .y = 0,
    //                 .z = 0,
    //             },
    //             vk.Offset3D{
    //                 .x = @intCast(src.dimensions.width),
    //                 .y = @intCast(src.dimensions.height),
    //                 .z = 1,
    //             },
    //         },
    //         .dst_offsets = .{
    //             vk.Offset3D{
    //                 .x = 0,
    //                 .y = 0,
    //                 .z = 0,
    //             },
    //             vk.Offset3D{
    //                 .x = @intCast(swapchain.extent.width),
    //                 .y = @intCast(swapchain.extent.height),
    //                 .z = 1,
    //             },
    //         },
    //     }),
    // }));
}
