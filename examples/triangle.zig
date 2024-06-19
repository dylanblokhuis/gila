const std = @import("std");
const c = @import("gila").c;

fn errorCallback(err: c_int, desc: [*c]const u8) callconv(.C) void {
    _ = err; // autofix
    std.debug.print("glfw err: {s}", .{desc});
}

pub fn main() !void {
    _ = c.glfwSetErrorCallback(errorCallback);
    if (c.glfwInit() == 0) {
        std.debug.panic("failed to initialize GLFW", .{});
    }
    defer c.glfwTerminate();

    const window = c.glfwCreateWindow(1280, 720, "Hello, mach-glfw!", null, null);
    defer c.glfwDestroyWindow(window);

    while (c.glfwWindowShouldClose(window) == 0) {
        c.glfwSwapBuffers(window);
        c.glfwPollEvents();
    }
}
