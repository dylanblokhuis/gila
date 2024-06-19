const std = @import("std");
const builtin = @import("builtin");
// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "gila",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.linkLibCpp();

    const vk_headers = b.dependency("Vulkan-Headers", .{});
    // add vulkan headers
    lib.addIncludePath(vk_headers.path("include"));
    lib.installHeadersDirectory(vk_headers.path("include/vulkan"), "vulkan", .{});
    lib.installHeadersDirectory(vk_headers.path("include/vk_video"), "vk_video", .{});

    // compile VMA from git
    {
        const vma_dep = b.dependency("vma", .{});
        lib.addIncludePath(vma_dep.path("include"));
        lib.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp") });
        lib.defineCMacro("VMA_STATIC_VULKAN_FUNCTIONS", "false");
        lib.installHeadersDirectory(vma_dep.path("include"), "", .{});
        lib.installHeader(vma_dep.path("include/vk_mem_alloc.h"), "vk_mem_alloc.h");
    }

    // compile SPIRV-reflect from git
    {
        const spirvr_dep = b.dependency("SPIRV-Reflect", .{});
        lib.addCSourceFile(.{
            .file = spirvr_dep.path("spirv_reflect.c"),
        });
        lib.addIncludePath(spirvr_dep.path(""));
        lib.installHeadersDirectory(spirvr_dep.path(""), "spirv_reflect", .{});
    }

    // add glfw
    {
        const glfw = b.dependency("glfw", .{
            .target = target,
            .optimize = optimize,
        });
        lib.linkLibrary(glfw.artifact("glfw"));
        lib.addIncludePath(glfw.path("include"));
        lib.installHeadersDirectory(glfw.path("include/GLFW"), "GLFW", .{});
    }

    const mod = b.addModule("gila", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkLibrary(lib);

    mod.addImport("generational-arena", b.dependency("generational-arena", .{
        .target = target,
        .optimize = optimize,
    }).module("generational-arena"));

    // zig build generate-vk
    {
        const registry = vk_headers.path("registry/vk.xml").getPath(b);
        const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
        const vk_generate_cmd = b.addRunArtifact(vk_gen);
        vk_generate_cmd.addArg(registry);
        vk_generate_cmd.addFileArg(b.path("src/vk.zig"));

        const run_step = b.step("generate-vk", "Generate Vulkan bindings");
        run_step.dependOn(&vk_generate_cmd.step);
    }

    // build examples
    {
        const triangle = b.addExecutable(.{
            .name = "triangle",
            .root_source_file = b.path("examples/triangle.zig"),
            .target = target,
            .optimize = optimize,
        });
        triangle.root_module.addImport("gila", mod);

        const build_step = b.step("build-example-triangle", "Build the triangle example");
        build_step.dependOn(&triangle.step);

        const run_cmd = b.addRunArtifact(triangle);
        const run_step = b.step("run-example-triangle", "Run the triangle example");
        run_step.dependOn(&run_cmd.step);

        b.installArtifact(triangle);
    }
}
