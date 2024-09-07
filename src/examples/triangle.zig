const std = @import("std");
const glfw = @import("gila").glfw;
const slang = @import("gila").slang;
const Gc = @import("gila");
const CommandEncoder = @import("gila").CommandEncoder;

fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.debug.print("glfw err: {} {s}\n", .{ error_code, description });
}

pub const Vertex = extern struct {
    position: [2]f32 align(1),
    color: [3]f32 align(1),
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
    _ = glfw.setErrorCallback(glfwErrorCallback);
    if (!glfw.init(.{})) {
        std.debug.panic("failed to initialize GLFW", .{});
    }
    defer glfw.terminate();

    const extent = Gc.vk.Extent2D{
        .width = 1280,
        .height = 720,
    };
    const window = glfw.Window.create(extent.width, extent.height, "gila", null, null, .{
        .client_api = .no_api,
    }).?;
    defer window.destroy();

    if (!glfw.vulkanSupported()) {
        std.debug.panic("GLFW: Vulkan not supported", .{});
    }

    var gc = try Gc.init(std.heap.c_allocator, "gila", window, .{});
    var swapchain = try Gc.Swapchain.init(&gc, extent, .{
        .present_mode = .mailbox_khr,
    });

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

    const triangle_pipeline = try gc.createGraphicsPipeline(.{
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

    // _ = compute_pipeline; // autofix

    // const texture = try gc.createSwapchainSizedColorAttachment(&swapchain, .r8g8b8a8_srgb);
    // _ = texture; // autofix
    const vertex_buffer = try gc.createBuffer(.{
        .location = .prefer_device,
        .size = @sizeOf(Vertex) * 3,
        .usage = .{ .vertex_buffer_bit = true, .transfer_dst_bit = true },
        .name = "vertex_buffer",
    });

    const storage_texture = try gc.createSwapchainSizedStorageTexture(&swapchain, .r8g8b8a8_unorm);
    var encoder = try CommandEncoder.init(&gc, .{
        .max_inflight = swapchain.swap_images.len,
    });

    const compute_pipeline = try gc.createComputePipeline(.{
        .shader = try gc.createShader(.{
            .data = .{ .path = "./compute.slang" },
            .kind = .compute,
            .entry_point = "computeMain",
        }),
        .prepend_descriptor_set_layouts = &.{
            encoder.getBindlessDescriptorSetLayout(),
        },
    });

    try encoder.addToBindless(.{ .storage_image = storage_texture });

    {
        try encoder.reset();
        try encoder.writeBuffer(vertex_buffer, Gc.toGpuBytes(&Triangle));
        encoder.bufferBarrier(vertex_buffer, .{
            .new_access_mask = .{ .vertex_attribute_read_bit = true },
            .new_stage_mask = .{ .vertex_attribute_input_bit = true },
        });
        try encoder.submit();
    }

    while (!window.shouldClose()) {
        if (window.getKey(.F1) == .press) {
            try gc.reloadGraphicsPipeline(triangle_pipeline);
            try gc.reloadComputePipeline(compute_pipeline);
        }

        const size = window.getFramebufferSize();
        // Don't present or resize swapchain while the window is minimized
        if (size.width == 0 or size.height == 0) {
            glfw.pollEvents();
            continue;
        }

        try encoder.reset();
        // make a triangle
        // {
        //     encoder.imageBarrier(texture, .{
        //         .new_access_mask = .{ .color_attachment_write_bit = true },
        //         .new_stage_mask = .{ .color_attachment_output_bit = true },
        //         .new_layout = .color_attachment_optimal,
        //     });

        //     var pass = try encoder.startGraphicsPass(.{
        //         .pipeline = triangle_pipeline,
        //         .color_attachments = &.{
        //             .{
        //                 .handle = texture,
        //                 .clear_color = .{ .float_32 = .{ 0, 0, 0, 1.0 } },
        //                 .load_op = .clear,
        //                 .store_op = .store,
        //             },
        //         },
        //         .depth_attachment = null,
        //     });
        //     defer encoder.endGraphicsPass(pass);

        //     pass.setVertexBuffer(vertex_buffer);
        //     pass.draw(.{
        //         .vertex_count = 3,
        //     });
        // }

        // make triangle a different color in compute
        {
            var pass = try encoder.startComputePass(.{
                .pipeline = compute_pipeline,
            });
            pass.bindDescriptorSets(0, &.{encoder.getBindlessDescriptorSet()});
            encoder.imageBarrier(storage_texture, .{
                .new_access_mask = .{ .shader_storage_write_bit = true },
                .new_layout = .general,
                .new_stage_mask = .{ .compute_shader_bit = true },
            });
            pass.setPushConstants(std.mem.asBytes(&extern struct {
                frame_index: u32,
                _padding: @Vector(3, u32) = undefined,
            }{
                .frame_index = 0,
            }), 0);
            pass.dispatch(swapchain.extent.width / 8, swapchain.extent.height / 8, 1);
            encoder.imageBarrier(storage_texture, .{
                .new_access_mask = .{ .transfer_read_bit = true },
                .new_layout = .transfer_src_optimal,
                .new_stage_mask = .{ .all_transfer_bit = true },
            });
        }

        // encoder.imageBarrier(texture, .{
        //     .new_access_mask = .{ .transfer_read_bit = true },
        //     .new_stage_mask = .{ .all_transfer_bit = true },
        //     .new_layout = .transfer_src_optimal,
        // });
        encoder.blitToSurface(&swapchain, storage_texture);

        const state = try encoder.submitAndPresent(&swapchain);
        if (state == .suboptimal or swapchain.extent.width != size.width or swapchain.extent.height != size.height) {
            try swapchain.recreate(.{
                .width = size.width,
                .height = size.height,
            });
        }

        glfw.pollEvents();
    }
}
