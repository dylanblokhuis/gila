const std = @import("std");
const Gc = @import("root.zig");
const vk = Gc.vk;

const Self = @This();

pub fn init() !Self {
    return Self{};
}

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
