const std = @import("std");
const builtin = @import("builtin");

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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const release_version = "180715385";
    const force_download_url: ?[:0]const u8 = null;

    var args = try std.process.argsWithAllocator(allocator);
    // skip executable name
    _ = args.skip();

    var maybe_output_dir: ?[:0]const u8 = null;
    while (args.next()) |arg| {
        if (maybe_output_dir == null) {
            maybe_output_dir = arg;
            continue;
        }
    }

    if (maybe_output_dir == null) {
        return error.MissingOutputDir;
    }

    // // check if libslang.so exists in the lib dir, then we can just return
    // const lib_dir = try std.fs.openDirAbsolute(maybe_lib_dir.?, .{
    //     .iterate = true,
    // });
    // {
    //     var iter = lib_dir.iterate();
    //     while (try iter.next()) |entry| {
    //         if (std.mem.eql(u8, entry.name, "libslang.so")) {
    //             return;
    //         }
    //     }
    // }

    const cache_dir = try std.fs.openDirAbsolute(maybe_output_dir.?, .{
        .iterate = true,
    });

    var client: std.http.Client = .{
        .allocator = allocator,
    };
    try std.http.Client.initDefaultProxies(&client, allocator);

    const archive_extension = ".zip";
    const slang_os_arch_combo: []const u8 = switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "win64",
            .x86 => "win32",
            .aarch64 => "win-arm64",
            else => return error.UnsupportedTarget,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "macos-x64",
            .aarch64 => "macos-aarch64",
            else => return error.UnsupportedTarget,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-aarch64",
            else => return error.UnsupportedTarget,
        },
        else => return error.UnsupportedTarget,
    };

    const download_url, const archive_name = if (force_download_url != null) blk: {
        break :blk .{
            force_download_url.?,
            try std.fmt.allocPrint(allocator, "slang-{s}-{s}{s}", .{
                release_version,
                slang_os_arch_combo,
                archive_extension,
            }),
        };
    } else blk: {
        var body = std.ArrayList(u8).init(allocator);
        var server_header_buffer: [16 * 1024]u8 = undefined;

        const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/shader-slang/slang/releases/{s}", .{release_version});
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

        const release = std.json.parseFromSliceLeaky(GithubReleaseItem, allocator, body.items, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("Failed to parse slang release JSON: {}", .{err});
            return error.FailedToParseGithubReleaseJson;
        };
        std.debug.assert(release.name[0] == 'v');

        const tar_name = try std.fmt.allocPrint(allocator, "slang-{s}-{s}{s}", .{
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

    // std.debug.assert(b.cache_root.path != null);

    // download zip release file
    {
        var body = std.ArrayList(u8).init(allocator);
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
        // node.completeOne();
    }

    // unzip the just downloaded zip file to a directory
    var file = try cache_dir.openFile(archive_name, .{ .mode = .read_only });
    defer file.close();
    defer cache_dir.deleteFile(archive_name) catch unreachable;

    // const extract_dir_name = "extracted";
    // try cache_dir.makePath(extract_dir_name);

    // var extract_dir = try cache_dir.openDir(extract_dir_name, .{
    //     .iterate = true,
    // });
    // defer extract_dir.close();

    try std.zip.extract(cache_dir, file.seekableStream(), .{});

    // we try and find a folder called "release" in the extracted files
    // in the slang releases this is where the binaries are stored
    // if (maybe_release_dir_path) |path| {
    // node.completeOne();
    // const path = try cache_dir.realpathAlloc(allocator, "lib");

    // move libslang form path to lib_dir
    // const libslang_path_src = try std.fs.path.join(allocator, &.{ path, "libslang.so" });
    // const libslang_path_dst = try std.fs.path.join(allocator, &.{ maybe_lib_dir.?, "libslang.so" });
    // try std.fs.copyFileAbsolute(libslang_path_src, libslang_path_dst, .{});
}
