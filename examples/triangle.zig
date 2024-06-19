const std = @import("std");
const c = @import("gila").c;

fn errorCallback(err: c_int, desc: [*c]const u8) callconv(.C) void {
    _ = err; // autofix
    std.debug.print("glfw err: {s}", .{desc});
}

pub fn main() !void {
    std.debug.print("{s}\n", .{c.slang.spGetBuildTagString()});

    const session = c.slang.spCreateSession();
    defer c.slang.spDestroySession(session);

    const request = c.slang.spCreateCompileRequest(session);
    defer c.slang.spDestroyCompileRequest(request);

    const target_index = c.slang.spAddCodeGenTarget(request, .SLANG_SPIRV);
    const profile = c.slang.spFindProfile(session, "glsl_450".ptr);
    c.slang.spSetTargetProfile(request, target_index, profile);

    // const target_index2 = c.slang.spAddCodeGenTarget(request, .SLANG_DXIL);
    // std.debug.print("{d} {d}\n", .{ target_index, target_index2 });

    // _ = c.glfwSetErrorCallback(errorCallback);
    // if (c.glfwInit() == 0) {
    //     std.debug.panic("failed to initialize GLFW", .{});
    // }
    // defer c.glfwTerminate();

    // const window = c.glfwCreateWindow(1280, 720, "Hello, mach-glfw!", null, null);
    // defer c.glfwDestroyWindow(window);

    // while (c.glfwWindowShouldClose(window) == 0) {
    //     c.glfwSwapBuffers(window);
    //     c.glfwPollEvents();
    // }
}
