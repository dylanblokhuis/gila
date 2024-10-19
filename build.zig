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

    const shared = b.option(bool, "shared", "Build as a shared library") orelse false;
    _ = shared; // autofix

    const lib = std.Build.Step.Compile.create(b, .{
        .name = "gila-deps",
        .kind = .lib,
        .linkage = .static,
        .root_module = .{
            .target = target,
            .optimize = optimize,
        },
    });

    lib.linkLibC();
    lib.linkLibCpp();

    const vk_headers = b.dependency("Vulkan-Headers", .{});
    // add vulkan headers
    lib.installHeadersDirectory(vk_headers.path("include/vulkan"), "vulkan", .{});
    lib.installHeadersDirectory(vk_headers.path("include/vk_video"), "vk_video", .{});
    lib.addIncludePath(vk_headers.path("include"));

    // compile VMA from git
    {
        const vma_dep = b.dependency("vma", .{});
        // lib.addIncludePath(vma_dep.path("include"));
        lib.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp") });
        lib.defineCMacro("VMA_STATIC_VULKAN_FUNCTIONS", "false");
        lib.installHeader(vma_dep.path("include/vk_mem_alloc.h"), "vk_mem_alloc.h");
        lib.addIncludePath(vma_dep.path("include"));
    }

    // compile SPIRV-reflect from git
    {
        const spirvr_dep = b.dependency("SPIRV-Reflect", .{});
        lib.addCSourceFile(.{
            .file = spirvr_dep.path("spirv_reflect.c"),
        });
        lib.installHeadersDirectory(spirvr_dep.path(""), "spirv_reflect", .{});
    }

    // add spirv-tools, we could build this as shared, so we need to link it to the module directly
    // const spvtools = b.dependency("SPIRV-Tools", .{
    //     .target = target,
    //     .optimize = optimize,
    //     .shared = shared,
    // });
    // lib.installHeadersDirectory(spvtools.path("include/spirv-tools"), "spirv-tools", .{});

    const slang_lib_dir = blk: {
        const download_slang_exe = b.addExecutable(.{
            .name = "download-slang",
            .root_source_file = b.path("build/download-slang.zig"),
            .target = target,
        });

        const dl_cmd = b.addRunArtifact(download_slang_exe);
        const extract_dir = dl_cmd.addOutputDirectoryArg("slang-release");

        const dl_step = b.step("download-slang", "Download the slang compiler");
        dl_step.dependOn(&dl_cmd.step);

        const lib_dir = extract_dir.path(b, "lib");
        lib.addLibraryPath(lib_dir);
        lib.addIncludePath(extract_dir.path(b, "include"));
        lib.linkSystemLibrary("slang");

        lib.addCSourceFile(.{ .file = b.path("./src/slang-c.cpp") });

        break :blk lib_dir;
    };

    const mod = b.addModule("gila", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkLibrary(lib);
    mod.addIncludePath(lib.getEmittedIncludeTree());
    mod.addLibraryPath(slang_lib_dir);

    const generational_arena = b.dependency("generational-arena", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("generational-arena", generational_arena.module("generational-arena"));

    const glfw = b.dependency("mach-glfw", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("mach-glfw", glfw.module("mach-glfw"));

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
            .root_source_file = b.path("src/examples/triangle.zig"),
            .target = target,
            .optimize = optimize,
        });

        triangle.root_module.addImport("gila", mod);
        // required for ZLS, imports are unused
        triangle.root_module.addImport("mach-glfw", glfw.module("mach-glfw"));
        triangle.root_module.addImport("generational-arena", generational_arena.module("generational-arena"));
        // ZLS will know where to find the headers
        triangle.addIncludePath(lib.getEmittedIncludeTree());

        const build_step = b.step("build-example-triangle", "Build the triangle example");
        build_step.dependOn(&triangle.step);

        const run_cmd = b.addRunArtifact(triangle);
        const run_step = b.step("run-example-triangle", "Run the triangle example");
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        b.installArtifact(triangle);
    }
}
