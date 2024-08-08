const std = @import("std");
const c = @import("gila").c;
const slang = @import("gila").slang;
const Gc = @import("gila");
const CommandEncoder = @import("gila").CommandEncoder;

fn errorCallback(err: c_int, desc: [*c]const u8) callconv(.C) void {
    _ = err; // autofix
    std.debug.print("glfw err: {s}", .{desc});
}

pub const Vertex = packed struct {
    position: @Vector(2, f32),
    color: @Vector(3, f32),
};

const Triangle = [_]Vertex{
    Vertex{
        .position = .{ -0.5, 0.5 },
        .color = .{ 1, 0, 0 },
    },
    Vertex{
        .position = .{ 0.5, 0.5 },
        .color = .{ 0, 1, 0 },
    },
    Vertex{
        .position = .{ 0, -0.5 },
        .color = .{ 0, 0, 1 },
    },
};

pub fn main() !void {
    _ = c.glfwSetErrorCallback(errorCallback);
    if (c.glfwInit() == 0) {
        std.debug.panic("failed to initialize GLFW", .{});
    }
    defer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const extent = Gc.vk.Extent2D{
        .width = 1280,
        .height = 720,
    };
    const window = c.glfwCreateWindow(extent.width, extent.height, "gila", null, null);
    defer c.glfwDestroyWindow(window);

    if (c.glfwVulkanSupported() == 0) {
        std.debug.panic("GLFW: Vulkan not supported", .{});
    }

    var gc = try Gc.init(std.heap.c_allocator, "gila", window.?);
    var swapchain = try Gc.Swapchain.init(&gc, extent);

    const vertex_shader = try gc.createShader(.{
        .data = .{ .path = "./raster.slang" },
        .kind = .vertex,
        .entry_point = "vertexMain",
    });
    const fragment_shader = try gc.createShader(.{
        .data = .{ .path = "./raster.slang" },
        .kind = .fragment,
        .entry_point = "fragmentMain",
    });

    const pipeline = try gc.createGraphicsPipeline(.{
        .vertex = .{
            .shader = vertex_shader,
            .buffer_layout = &.{Gc.GraphicsPipeline.VertexBufferLayout{
                .stride = @sizeOf(Vertex),
                .attributes = &.{
                    Gc.GraphicsPipeline.VertexAttribute{
                        .location = 0,
                        .format = .r32g32_sfloat,
                        .offset = 0,
                    },
                    Gc.GraphicsPipeline.VertexAttribute{
                        .location = 1,
                        .format = .r32g32b32_sfloat,
                        .offset = @sizeOf(f32) * 2,
                    },
                },
            }},
        },
        .fragment = .{
            .shader = fragment_shader,
            .color_targets = &.{
                Gc.GraphicsPipeline.ColorAttachment{
                    .format = .r8g8b8a8_srgb,
                },
            },
        },
    });

    const texture = try gc.createColorAttachment(&swapchain, .r8g8b8a8_srgb);
    const vertex_buffer = try gc.createBuffer(.{
        .location = .gpu_only,
        .size = @sizeOf(Vertex) * 3,
        .usage = .{ .vertex_buffer_bit = true, .transfer_dst_bit = true },
        .name = "vertex_buffer",
    });

    var encoder = try CommandEncoder.init(&gc, .{
        .max_inflight = swapchain.swap_images.len,
    });

    {
        try encoder.reset();
        encoder.bufferBarrier(vertex_buffer, .{
            .new_access_mask = .{ .transfer_write_bit = true },
            .new_stage_mask = .{ .all_transfer_bit = true },
        });
        try encoder.writeBuffer(vertex_buffer, std.mem.sliceAsBytes(&Triangle));
        encoder.bufferBarrier(vertex_buffer, .{
            .new_access_mask = .{ .vertex_attribute_read_bit = true },
            .new_stage_mask = .{ .vertex_attribute_input_bit = true },
        });
        try encoder.submitBlocking();
    }

    while (c.glfwWindowShouldClose(window) == 0) {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);

        // Don't present or resize swapchain while the window is minimized
        if (w == 0 or h == 0) {
            c.glfwPollEvents();
            continue;
        }

        try encoder.reset();
        {
            encoder.imageBarrier(texture, .{
                .new_access_mask = .{ .color_attachment_write_bit = true },
                .new_stage_mask = .{ .color_attachment_output_bit = true },
                .new_layout = .color_attachment_optimal,
            });

            var pass = try encoder.startGraphicsPass(.{
                .pipeline = pipeline,
                .color_attachments = &.{
                    CommandEncoder.GraphicsPassDesc.ColorAttachment{
                        .handle = texture,
                        .clear_color = .{ .float_32 = .{ 0, 0, 0, 1.0 } },
                        .load_op = .clear,
                        .store_op = .store,
                    },
                },
                .depth_attachment = null,
            });
            defer encoder.endGraphicsPass(pass);

            pass.setVertexBuffer(vertex_buffer);
            pass.draw(.{
                .vertex_count = 3,
            });
        }

        encoder.imageBarrier(texture, .{
            .new_access_mask = .{ .transfer_read_bit = true },
            .new_stage_mask = .{ .all_transfer_bit = true },
            .new_layout = .transfer_src_optimal,
        });
        encoder.blitToSurface(&swapchain, texture);

        const state = try encoder.submitAndPresent(&swapchain);
        if (state == .suboptimal or swapchain.extent.width != @as(u32, @intCast(w)) or swapchain.extent.height != @as(u32, @intCast(h))) {
            try swapchain.recreate(.{
                .width = @intCast(w),
                .height = @intCast(h),
            });
        }

        c.glfwPollEvents();
    }
}
