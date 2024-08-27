const std = @import("std");
const Gc = @import("root.zig");
const vk = Gc.vk;
const c = Gc.c;

const Self = @This();

module: vk.ShaderModule,
kind: Kind,
entry_point: [:0]const u8,
spirv: []const u8,
path: ?[:0]const u8 = null,

pub const SpirvReflect = struct {
    sets: []vk.DescriptorSet,
    pool: ?vk.DescriptorPool = null,
    set_layouts: []vk.DescriptorSetLayout,
    push_constants: []vk.PushConstantRange,
};

pub const Kind = enum {
    vertex,
    fragment,
    compute,
};

pub const OptimizationLevel = enum {
    zero,
    size,
    performance,
};

pub const Data = union(enum) {
    spirv: []const u8,
    path: [:0]const u8,
};

pub const CreateInfo = struct {
    data: Data,
    kind: Kind,
    entry_point: [:0]const u8 = "main",
};

pub fn create(gc: *Gc, desc: Self.CreateInfo) !Self {
    const spirv = try optimizeSpirv(gc.allocator, switch (desc.data) {
        .spirv => desc.data.spirv,
        .path => |path| try Gc.slang.compileToSpv(gc.allocator, path, desc.entry_point, switch (desc.kind) {
            .compute => Gc.slang.SlangStage.SLANG_STAGE_COMPUTE,
            .fragment => Gc.slang.SlangStage.SLANG_STAGE_FRAGMENT,
            .vertex => Gc.slang.SlangStage.SLANG_STAGE_VERTEX,
        }),
    });

    if (desc.data == .path) {
        var split = std.mem.splitBackwards(u8, desc.data.path, "/");
        const filename = try std.fmt.allocPrint(gc.allocator, "{s}-{s}.spv", .{ desc.entry_point, split.first() });
        const path = try std.fs.path.join(gc.allocator, &.{ "./zig-out", filename });
        const file = try std.fs.cwd().createFile(path, .{});
        try file.writeAll(spirv);
        file.close();
    }

    const shader_module = try gc.device.createShaderModule(&.{
        .code_size = spirv.len,
        .p_code = @ptrCast(@alignCast(spirv.ptr)),
    }, null);

    return Self{
        .module = shader_module,
        // slang converts the entrypoint to main?
        .entry_point = desc.entry_point,
        .kind = desc.kind,
        .spirv = spirv,
        .path = switch (desc.data) {
            .spirv => null,
            .path => desc.data.path,
        },
    };
}

pub fn destroy(self: *Self, gc: *Gc) void {
    gc.device.destroyShaderModule(self.module, null);
    gc.allocator.free(self.spirv);
}

pub fn getEntryPoint(self: *const Self) [:0]const u8 {
    _ = self; // autofix
    // slang converts the entrypoint to "main"
    return "main";
}

/// TODO: vertex descriptors
pub fn doReflect(self: *const Self, gc: *Gc, ignore_sets: ?usize) !SpirvReflect {
    var module: c.SpvReflectShaderModule = undefined;
    if (c.spvReflectCreateShaderModule2(c.SPV_REFLECT_MODULE_FLAG_NONE, self.spirv.len, self.spirv.ptr, &module) != c.SPV_REFLECT_RESULT_SUCCESS) {
        return error.ShaderReflectionFailed;
    }
    defer c.spvReflectDestroyShaderModule(&module);

    var var_count: u32 = 0;
    if (c.spvReflectEnumerateDescriptorSets(&module, &var_count, null) != c.SPV_REFLECT_RESULT_SUCCESS) {
        return error.ShaderReflectionFailed;
    }

    const input_vars = try gc.allocator.alloc([*c]c.SpvReflectDescriptorSet, var_count);
    defer gc.allocator.free(input_vars);

    if (c.spvReflectEnumerateDescriptorSets(&module, &var_count, input_vars.ptr) != c.SPV_REFLECT_RESULT_SUCCESS) {
        return error.ShaderReflectionFailed;
    }

    var set_layouts = std.ArrayListUnmanaged(vk.DescriptorSetLayout){};
    defer set_layouts.deinit(gc.allocator);

    var pool_sizes = std.AutoArrayHashMapUnmanaged(vk.DescriptorType, vk.DescriptorPoolSize){};
    defer pool_sizes.deinit(gc.allocator);

    const stage_flags = vk.ShaderStageFlags{
        .vertex_bit = self.kind == Kind.vertex or self.kind == Kind.fragment,
        .fragment_bit = self.kind == Kind.vertex or self.kind == Kind.fragment,
        .compute_bit = self.kind == Kind.compute,
    };
    for (input_vars, 0..) |set, set_nr| {
        if (ignore_sets) |n| {
            if (set_nr < n) {
                continue;
            }
        }
        const bindings = try gc.allocator.alloc(vk.DescriptorSetLayoutBinding, set.*.binding_count);
        // ideally we would use the binding indices specified by the reflection instead of just incrementing
        for (0..set.*.binding_count) |i| {
            const binding = set.*.bindings[i].*;

            bindings[i] = vk.DescriptorSetLayoutBinding{
                .binding = @intCast(i),
                .descriptor_count = binding.count,
                .descriptor_type = @enumFromInt(binding.descriptor_type),
                .stage_flags = stage_flags,
            };

            if (pool_sizes.getEntry(bindings[i].descriptor_type)) |entry| {
                entry.value_ptr.descriptor_count += binding.count;
            } else {
                try pool_sizes.put(gc.allocator, bindings[i].descriptor_type, .{
                    .descriptor_count = bindings[i].descriptor_count,
                    .type = bindings[i].descriptor_type,
                });
            }
        }

        const set_layout = try gc.device.createDescriptorSetLayout(&vk.DescriptorSetLayoutCreateInfo{
            .binding_count = set.*.binding_count,
            .p_bindings = bindings.ptr,
        }, null);
        try set_layouts.append(gc.allocator, set_layout);
    }

    const sets = try gc.allocator.alloc(vk.DescriptorSet, set_layouts.items.len);

    var descriptor_pool: ?vk.DescriptorPool = null;
    if (sets.len > 0) {
        descriptor_pool = try gc.device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
            .flags = .{ .free_descriptor_set_bit = true },
            .max_sets = @intCast(set_layouts.items.len),
            .pool_size_count = @intCast(pool_sizes.count()),
            .p_pool_sizes = pool_sizes.values().ptr,
        }, null);

        try gc.device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool.?,
            .p_set_layouts = set_layouts.items.ptr,
            .descriptor_set_count = @intCast(set_layouts.items.len),
        }, sets.ptr);
    }

    var push_constant_count: u32 = 0;
    if (c.spvReflectEnumeratePushConstants(&module, &push_constant_count, null) != c.SPV_REFLECT_RESULT_SUCCESS) {
        // std.log.err("spvReflectEnumeratePushConstants failed", .{file_name});
        return error.ShaderReflectionFailed;
    }

    var push_constants = try std.BoundedArray([*c]c.SpvReflectBlockVariable, 4).init(push_constant_count);
    if (c.spvReflectEnumeratePushConstants(&module, &push_constant_count, push_constants.slice().ptr) != c.SPV_REFLECT_RESULT_SUCCESS) {
        // std.log.err("spvReflectEnumeratePushConstants failed", .{file_name});
        return error.ShaderReflectionFailed;
    }

    var ranges = try gc.allocator.alloc(vk.PushConstantRange, push_constant_count);
    for (push_constants.slice(), 0..) |pc, i| {
        ranges[i] = .{
            .offset = pc.*.offset,
            .size = pc.*.size,
            .stage_flags = stage_flags,
        };
    }

    return SpirvReflect{
        .sets = sets,
        .pool = descriptor_pool,
        .set_layouts = try set_layouts.toOwnedSlice(gc.allocator),
        .push_constants = ranges,
    };
}

fn spvMessageConsumer(
    level: c.spv_message_level_t,
    src: [*c]const u8,
    pos: [*c]const c.spv_position_t,
    msg: [*c]const u8,
) callconv(.C) void {
    switch (level) {
        c.SPV_MSG_FATAL,
        c.SPV_MSG_INTERNAL_ERROR,
        c.SPV_MSG_ERROR,
        => {
            // TODO - don't panic
            std.debug.panic("{s} at :{d}:{d}\n{s}", .{
                std.mem.span(msg),
                pos.*.line,
                pos.*.column,
                std.mem.span(src),
            });
        },
        else => {},
    }
}

fn optimizeSpirv(allocator: std.mem.Allocator, spirv: []const u8) ![]const u8 {
    const optimizer = c.spvOptimizerCreate(c.SPV_ENV_VULKAN_1_3);
    defer c.spvOptimizerDestroy(optimizer);

    c.spvOptimizerSetMessageConsumer(optimizer, spvMessageConsumer);
    c.spvOptimizerRegisterPerformancePasses(optimizer);
    c.spvOptimizerRegisterLegalizationPasses(optimizer);

    const options = c.spvOptimizerOptionsCreate();
    defer c.spvOptimizerOptionsDestroy(options);

    c.spvOptimizerOptionsSetRunValidator(options, true);

    const spirv_words_ptr = @as([*]const u32, @ptrCast(@alignCast(spirv.ptr)));
    const spirv_words = spirv_words_ptr[0 .. spirv.len / @sizeOf(u32)];

    var optimized_spirv: c.spv_binary = undefined;
    if (c.spvOptimizerRun(optimizer, spirv_words.ptr, spirv_words.len, &optimized_spirv, options) != c.SPV_SUCCESS) {
        return error.SpirvOptimizationFailed;
    }

    const code_bytes_ptr = @as([*]const u8, @ptrCast(optimized_spirv.*.code));
    const code_bytes = code_bytes_ptr[0 .. optimized_spirv.*.wordCount * @sizeOf(u32)];
    return allocator.dupe(u8, code_bytes);
}
