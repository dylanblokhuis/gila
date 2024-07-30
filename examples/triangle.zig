const std = @import("std");
const c = @import("gila").c;
const slang = @import("gila").slang;
const Gc = @import("gila");

fn errorCallback(err: c_int, desc: [*c]const u8) callconv(.C) void {
    _ = err; // autofix
    std.debug.print("glfw err: {s}", .{desc});
}

pub const Vertex = packed struct {
    position: @Vector(2, f32),
    color: @Vector(3, f32),
};

pub fn main() !void {
    // const bytes = try slang.compileToSpv("hello-world.slang", "computeMain", .SLANG_STAGE_COMPUTE);
    // std.debug.print("{any}", .{bytes});

    // std.debug.print("{s}\n", .{c.slang.spGetBuildTagString()});

    // const session = c.slang.spCreateSession();
    // defer c.slang.spDestroySession(session);

    // const request = c.slang.spCreateCompileRequest(session);
    // defer c.slang.spDestroyCompileRequest(request);

    // const target_index = c.slang.spAddCodeGenTarget(request, .SLANG_SPIRV);
    // const profile = c.slang.spFindProfile(session, "glsl_450".ptr);
    // c.slang.spSetTargetProfile(request, target_index, profile);

    // const target_index2 = c.slang.spAddCodeGenTarget(request, .SLANG_DXIL);
    // std.debug.print("{d} {d}\n", .{ target_index, target_index2 });

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
    const window = c.glfwCreateWindow(extent.width, extent.height, "Hello, mach-glfw!", null, null);
    defer c.glfwDestroyWindow(window);

    if (c.glfwVulkanSupported() == 0) {
        std.debug.panic("GLFW: Vulkan not supported", .{});
    }

    var gc = try Gc.init(std.heap.c_allocator, "gila", window.?);
    const swapchain = try Gc.Swapchain.init(&gc, extent);
    _ = swapchain; // autofix

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
                // Gc.GraphicsPipeline.ColorAttachment{
                //     .format = .
                // },
            },
        },
    });
    _ = pipeline; // autofix

    while (c.glfwWindowShouldClose(window) == 0) {
        var w: c_int = undefined;
        var h: c_int = undefined;
        c.glfwGetFramebufferSize(window, &w, &h);

        // Don't present or resize swapchain while the window is minimized
        if (w == 0 or h == 0) {
            c.glfwPollEvents();
            continue;
        }

        c.glfwPollEvents();
    }
}
