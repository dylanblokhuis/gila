const Gc = @import("root.zig");
const std = @import("std");
const vk = Gc.vk;

const Self = @This();

gc: *Gc,
swapchain: *Gc.Swapchain,
command_pool: vk.CommandPool,
command_buffers: []vk.CommandBuffer,
fences: []vk.Fence,
current_frame_index: usize,

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
        .command_buffer_count = options.max_inflight,
        .command_pool = pool,
        .level = .primary,
    }, command_buffers.len);

    const fences = try gc.allocator.alloc(vk.Fence, options.max_inflight);
    for (0..options.max_inflight) |i| {
        fences[i] = try gc.device.createFence(&vk.FenceCreateInfo{
            .flags = .{
                .signaled_bit = true,
            },
        });
    }

    return Self{
        .gc = gc,
        .command_pool = pool,
        .command_buffers = command_buffers,
        .fences = fences,
        .current_frame = command_buffers.len,
    };
}

inline fn getCommandBuffer(self: *Self) vk.CommandBuffer {
    return self.command_buffers[self.current_frame.index];
}

// reset should be called at the beginning of each frame
pub fn reset(self: *Self) !void {
    self.current_frame_index = (self.current_frame.index + 1) % self.command_buffers.len;

    const fence = self.fences[self.current_frame.index];
    try self.gc.device.waitForFences(1, &fence, true, std.math.maxInt(usize));
    try self.gc.device.resetFences(1, &fence);

    const buffer = self.command_buffers[self.current_frame.index];
    try self.gc.device.resetCommandBuffer(buffer, .{
        .release_resources_bit = true,
    });
}

const GraphicsPass = struct {
    encoder: *Self,
    desc: GraphicsPassDesc,

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

    pub fn bindDescriptorSets(self: *GraphicsPass, first_set: u32, sets: []const vk.DescriptorSet) void {
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
    auto: Auto = {},
};
pub fn startGraphicsPass(self: *Self, desc: GraphicsPassDesc) !GraphicsPass {
    const pipeline: Gc.GraphicsPipeline = self.gc.graphics_pipelines.get(desc.pipeline).?;
    self.gc.device.cmdBindPipeline(self.getCommandBuffer(), .graphics, pipeline.pipeline);

    var color_rendering_attachments = self.gc.allocator.alloc(vk.RenderingAttachmentInfoKHR, desc.color_attachments.len) catch unreachable;

    var render_area: ?vk.Rect2D = null;

    for (desc.color_attachments, 0..) |attachment, index| {
        const texture = self.gc.textures.get(attachment.handle).?;
        color_rendering_attachments[index] = vk.RenderingAttachmentInfoKHR{
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

    var maybe_depth_attachment: ?vk.RenderingAttachmentInfoKHR = null;
    if (desc.depth_attachment) |depth_attachment| {
        const texture = self.gc.textures.get(depth_attachment.handle).?;
        maybe_depth_attachment = &vk.RenderingAttachmentInfoKHR{
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

pub fn endGraphicsPass(self: *GraphicsPass) void {
    self.encoder.gc.device.cmdEndRendering(self.encoder.getCommandBuffer());
}
