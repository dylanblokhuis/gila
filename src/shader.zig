const std = @import("std");
const Gc = @import("root.zig");
const vk = Gc.vk;
const c = Gc.c;

const Self = @This();

module: vk.ShaderModule,
kind: Kind,
entry_point: [:0]const u8,
spirv: []u8,
path: ?[]const u8 = null,

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
    spirv: []u8,
    path: [:0]const u8,
};

pub const CreateInfo = struct {
    data: Data,
    kind: Kind,
    entry_point: [:0]const u8 = "main",
};

pub fn create(gc: *Gc, desc: Self.CreateInfo) !Self {
    const spirv = switch (desc.data) {
        .spirv => desc.data.spirv,
        .path => |path| try Gc.slang.compileToSpv(gc.allocator, path, desc.entry_point, switch (desc.kind) {
            .compute => Gc.slang.SlangStage.SLANG_STAGE_COMPUTE,
            .fragment => Gc.slang.SlangStage.SLANG_STAGE_FRAGMENT,
            .vertex => Gc.slang.SlangStage.SLANG_STAGE_VERTEX,
        }),
    };

    if (desc.data == .path) {
        const filename = try std.fmt.allocPrint(gc.allocator, "{s}.spv", .{desc.data.path});
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
        .entry_point = "main",
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
    gc.device.destroyPipelineLayout(self.layout, null);
    gc.device.destroyDescriptorPool(self.pool, null);
    gc.allocator.free(self.spirv);
}

/// TODO: vertex descriptors
pub fn doReflect(self: *const Self, gc: *Gc, ignore_sets: ?usize) !SpirvReflect {
    var module: c.SpvReflectShaderModule = undefined;
    if (c.spvReflectCreateShaderModule(self.spirv.len, self.spirv.ptr, &module) != c.SPV_REFLECT_RESULT_SUCCESS) {
        // std.log.err("spvReflectCreateShaderModule failed", .{});
        return error.ShaderReflectionFailed;
    }
    defer c.spvReflectDestroyShaderModule(&module);

    var var_count: u32 = 0;
    if (c.spvReflectEnumerateDescriptorSets(&module, &var_count, null) != c.SPV_REFLECT_RESULT_SUCCESS) {
        // std.log.err("spvReflectEnumerateDescriptorSets failed", .{file_name});
        return error.ShaderReflectionFailed;
    }

    const input_vars = try gc.allocator.alloc([*c]c.SpvReflectDescriptorSet, var_count);
    defer gc.allocator.free(input_vars);

    if (c.spvReflectEnumerateDescriptorSets(&module, &var_count, input_vars.ptr) != c.SPV_REFLECT_RESULT_SUCCESS) {
        // std.log.err("spvReflectEnumerateDescriptorSets failed", .{file_name});
        return error.ShaderReflectionFailed;
    }

    var set_layouts = std.ArrayListUnmanaged(vk.DescriptorSetLayout){};
    defer set_layouts.deinit(gc.allocator);

    var pool_sizes = std.AutoArrayHashMapUnmanaged(vk.DescriptorType, vk.DescriptorPoolSize){};
    defer pool_sizes.deinit(gc.allocator);

    const stage_flags = vk.ShaderStageFlags{
        .vertex_bit = self.kind == Kind.vertex or self.kind == Kind.fragment,
        .fragment_bit = self.kind == Kind.fragment,
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
    _ = c.spvReflectEnumeratePushConstants(&module, &push_constant_count, null);

    var push_constants = try std.BoundedArray([*c]c.SpvReflectBlockVariable, 4).init(push_constant_count);
    _ = c.spvReflectEnumeratePushConstants(&module, &push_constant_count, push_constants.slice().ptr);

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
