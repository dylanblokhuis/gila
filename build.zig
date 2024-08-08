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

    const use_lld = true;
    const use_llvm = true;

    const lib = b.addStaticLibrary(.{
        .name = "gila",
        .target = target,
        .optimize = optimize,
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });

    lib.linkLibC();
    lib.linkLibCpp();

    const vk_headers = b.dependency("Vulkan-Headers", .{});
    // add vulkan headers
    lib.installHeadersDirectory(vk_headers.path("include/vulkan"), "vulkan", .{});
    lib.installHeadersDirectory(vk_headers.path("include/vk_video"), "vk_video", .{});

    // compile VMA from git
    {
        const vma_dep = b.dependency("vma", .{});
        lib.addIncludePath(vma_dep.path("include"));
        lib.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp") });
        lib.defineCMacro("VMA_STATIC_VULKAN_FUNCTIONS", "false");
        lib.installHeader(vma_dep.path("include/vk_mem_alloc.h"), "vk_mem_alloc.h");
    }

    // compile SPIRV-reflect from git
    {
        const spirvr_dep = b.dependency("SPIRV-Reflect", .{});
        lib.addCSourceFile(.{
            .file = spirvr_dep.path("spirv_reflect.c"),
        });
        lib.installHeadersDirectory(spirvr_dep.path(""), "spirv_reflect", .{});
    }

    // add glfw
    {
        const glfw = b.dependency("glfw", .{
            .target = target,
            .optimize = optimize,
        });
        lib.linkLibrary(glfw.artifact("glfw"));
        lib.installHeadersDirectory(glfw.path("include/GLFW"), "GLFW", .{});
    }

    // add slang
    const slang_link_path: ?std.Build.LazyPath = blk: {
        var download_step = SlangDownloadBinaryStep.init(b, lib, .{});
        lib.step.dependOn(&download_step.step);
        lib.linkSystemLibrary("slang");
        const link_path = download_step.linkablePath() catch {
            break :blk null;
        };
        lib.addLibraryPath(link_path);
        break :blk link_path;
    };

    const mod = b.addModule("gila", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkLibrary(lib);
    mod.addIncludePath(lib.getEmittedIncludeTree());
    if (slang_link_path) |p| mod.addLibraryPath(p);

    const generational_arena = b.dependency("generational-arena", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("generational-arena", generational_arena.module("generational-arena"));

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
            .use_lld = use_lld,
            .use_llvm = use_llvm,
        });
        triangle.root_module.addImport("gila", mod);
        triangle.addIncludePath(lib.getEmittedIncludeTree());

        const build_step = b.step("build-example-triangle", "Build the triangle example");
        build_step.dependOn(&triangle.step);

        const run_cmd = b.addRunArtifact(triangle);
        const run_step = b.step("run-example-triangle", "Run the triangle example");
        run_step.dependOn(&run_cmd.step);

        b.installArtifact(triangle);
    }
}

pub const SlangDownloadOptions = struct {
    release_version: []const u8 = "167021889",
    download_url: ?[]const u8 = null,
};
pub const SlangDownloadBinaryStep = struct {
    target: *std.Build.Step.Compile,
    options: SlangDownloadOptions,
    step: std.Build.Step,
    b: *std.Build,

    pub fn init(b: *std.Build, target: *std.Build.Step.Compile, options: SlangDownloadOptions) *SlangDownloadBinaryStep {
        const download_step = b.allocator.create(SlangDownloadBinaryStep) catch unreachable;
        download_step.* = .{
            .target = target,
            .options = options,
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "slang-download",
                .owner = b,
                .makeFn = &make,
            }),
            .b = b,
        };
        return download_step;
    }

    pub fn linkablePath(self: *@This()) !std.Build.LazyPath {
        // return self.b.fmt("{s}/libslang.so", .{self.b.cache_root.path.?.?});
        const allocator = self.b.allocator;

        const cache_dir_path = try std.fs.path.join(allocator, &.{ self.b.cache_root.path.?, "slang-release" });
        try std.fs.cwd().makePath(cache_dir_path);
        var cache_dir = try std.fs.openDirAbsolute(cache_dir_path, .{});
        defer cache_dir.close();
        // errdefer {
        //     std.log.err("Cleaning up...", .{});
        //     std.fs.deleteTreeAbsolute(cache_dir_path) catch |err| {
        //         std.log.err("Failed to cleanup cache dir: {}", .{err});
        //     };
        // }

        const target = self.target.rootModuleTarget();
        const cache_file_name = self.b.fmt("{s}-{s}-{s}", .{
            self.options.release_version,
            @tagName(target.os.tag),
            @tagName(target.cpu.arch),
        });

        return .{
            .cwd_relative = try cache_dir.readFileAlloc(allocator, cache_file_name, std.math.maxInt(usize)),
        };
    }

    fn make(step: *std.Build.Step, prog_node: std.Progress.Node) anyerror!void {
        const download_step: *SlangDownloadBinaryStep = @fieldParentPtr("step", step);
        const allocator = download_step.b.allocator;

        const cache_dir_path = try std.fs.path.join(allocator, &.{ download_step.b.cache_root.path.?, "slang-release" });
        try std.fs.cwd().makePath(cache_dir_path);
        var cache_dir = try std.fs.openDirAbsolute(cache_dir_path, .{});
        defer cache_dir.close();
        errdefer {
            std.log.err("Cleaning up...", .{});
            std.fs.deleteTreeAbsolute(cache_dir_path) catch |err| {
                std.log.err("Failed to cleanup cache dir: {}", .{err});
            };
        }

        const target = download_step.target.rootModuleTarget();
        const cache_file_name = download_step.b.fmt("{s}-{s}-{s}", .{
            download_step.options.release_version,
            @tagName(target.os.tag),
            @tagName(target.cpu.arch),
        });

        const linkable_path = cache_dir.readFileAlloc(allocator, cache_file_name, std.math.maxInt(usize)) catch blk: {
            const path_with_binaries = try downloadFromBinary(
                download_step.b,
                download_step.target,
                download_step.options,
                prog_node.start("Downloading release and extracting", 2),
                cache_dir,
            );

            try cache_dir.writeFile(.{
                .sub_path = cache_file_name,
                .data = path_with_binaries,
            });

            break :blk path_with_binaries;
        };

        std.debug.assert(linkable_path.len > 0);

        download_step.target.addLibraryPath(.{
            .cwd_relative = linkable_path,
        });
    }
};

const GithubReleaseItem = struct {
    id: u64,
    name: []const u8,
    draft: bool,
    prerelease: bool,
    created_at: []const u8,
    published_at: []const u8,
    assets: []GithubReleaseAsset,
};

const GithubReleaseAsset = struct {
    id: u64,
    url: []const u8,
    name: []const u8,
    content_type: []const u8,
    state: []const u8,
    size: u64,
    created_at: []const u8,
    updated_at: []const u8,
    browser_download_url: []const u8,
};

var download_mutex = std.Thread.Mutex{};

pub fn downloadFromBinary(b: *std.Build, step: *std.Build.Step.Compile, options: SlangDownloadOptions, node: std.Progress.Node, cache_dir: std.fs.Dir) ![]const u8 {
    // This function could be called in parallel. We're manipulating the FS here
    // and so need to prevent that.
    download_mutex.lock();
    defer download_mutex.unlock();

    const target = step.rootModuleTarget();
    var client: std.http.Client = .{
        .allocator = b.allocator,
    };
    try std.http.Client.initDefaultProxies(&client, b.allocator);

    const archive_extension = ".zip";
    const slang_os_arch_combo: []const u8 = switch (target.os.tag) {
        .windows => switch (target.cpu.arch) {
            .x86_64 => "win64",
            .x86 => "win32",
            .aarch64 => "win-arm64",
            else => return error.UnsupportedTarget,
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "macos-x64",
            .aarch64 => "macos-aarch64",
            else => return error.UnsupportedTarget,
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-aarch64",
            else => return error.UnsupportedTarget,
        },
        else => return error.UnsupportedTarget,
    };

    const download_url, const archive_name = if (options.download_url != null) blk: {
        break :blk .{
            options.download_url.?,
            b.fmt("slang-{s}-{s}{s}", .{
                options.release_version,
                slang_os_arch_combo,
                archive_extension,
            }),
        };
    } else blk: {
        var body = std.ArrayList(u8).init(b.allocator);
        var server_header_buffer: [16 * 1024]u8 = undefined;

        const url = b.fmt("https://api.github.com/repos/shader-slang/slang/releases/{s}", .{options.release_version});
        const req = try client.fetch(.{
            .server_header_buffer = &server_header_buffer,
            .method = .GET,
            .location = .{ .url = url },
            .response_storage = .{
                .dynamic = &body,
            },
        });
        if (req.status != .ok) {
            var iter = std.http.HeaderIterator.init(&server_header_buffer);
            while (iter.next()) |header| {
                if (std.mem.eql(u8, header.name, "X-RateLimit-Remaining") and std.mem.eql(u8, header.value, "0")) {
                    std.log.err("Github API rate limit exceeded, wait 30 minutes", .{});
                    return error.GithubApiRateLimitExceeded;
                }
            }

            std.log.err("Failed to fetch slang releases: {}", .{req.status});
            return error.FailedToFetchGithubReleases;
        }

        const release = std.json.parseFromSliceLeaky(GithubReleaseItem, b.allocator, body.items, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse slang release JSON: {}", .{err});
            return error.FailedToParseGithubReleaseJson;
        };
        std.debug.assert(release.name[0] == 'v');

        const tar_name = b.fmt("slang-{s}-{s}{s}", .{
            release.name[1..],
            slang_os_arch_combo,
            archive_extension,
        });

        for (release.assets) |asset| {
            if (std.mem.endsWith(u8, asset.name, tar_name)) {
                break :blk .{ asset.browser_download_url, asset.name };
            }
        }

        std.log.err("Failed to find slang release for: {s}", .{tar_name});
        return error.FailedToFindSlangRelease;
    };

    std.debug.assert(b.cache_root.path != null);

    // download zip release file
    {
        var body = std.ArrayList(u8).init(b.allocator);
        const response = try client.fetch(.{
            .method = .GET,
            .location = .{ .url = download_url },
            .response_storage = .{
                .dynamic = &body,
            },
            .max_append_size = 50 * 1024 * 1024,
        });
        if (response.status != .ok) {
            std.log.err("Failed to download slang release: {}", .{response.status});
            return error.FailedToDownloadSlangRelease;
        }

        const target_file = try cache_dir.createFile(archive_name, .{});
        defer target_file.close();

        try target_file.writeAll(body.items);
        node.completeOne();
    }

    // unzip the just downloaded zip file to a directory
    var file = try cache_dir.openFile(archive_name, .{ .mode = .read_only });
    defer file.close();
    defer cache_dir.deleteFile(archive_name) catch unreachable;

    const extract_dir_name = try std.mem.replaceOwned(u8, b.allocator, archive_name, archive_extension, "");
    try cache_dir.makePath(extract_dir_name);

    var extract_dir = try cache_dir.openDir(extract_dir_name, .{
        .iterate = true,
    });
    defer extract_dir.close();

    try std.zip.extract(extract_dir, file.seekableStream(), .{});

    // we try and find a folder called "release" in the extracted files
    // in the slang releases this is where the binaries are stored
    // if (maybe_release_dir_path) |path| {
    node.completeOne();
    const path = try extract_dir.realpathAlloc(b.allocator, "lib");
    std.debug.print("PATH: {s}\n", .{path});
    return path;
    // }

    // return error.FailedToFindSlangReleaseDir;
}
