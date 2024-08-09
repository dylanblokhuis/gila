const std = @import("std");
const Gc = @import("root.zig");
const vk = Gc.vk;
const Self = @This();

pipeline: vk.Pipeline,
layout: vk.PipelineLayout,
sets: []vk.DescriptorSet,
pool: ?vk.DescriptorPool = null,
first_set: u32 = 0,

pub const CreateInfo = struct {
    shader: Gc.ShaderHandle,
    prepend_descriptor_set_layouts: ?[]const vk.DescriptorSetLayout = null,
};

pub fn create(gc: *Gc, desc: Self.CreateInfo) !Self {
    const shader = gc.shaders.get(desc.shader).?;
    const reflect = try shader.doReflect(gc, if (desc.prepend_descriptor_set_layouts) |s| @intCast(s.len) else null);
    const first_set: u32 = if (desc.prepend_descriptor_set_layouts) |s| @intCast(s.len) else 0;

    const pipeline_layout = if (desc.prepend_descriptor_set_layouts) |prepend| blk: {
        const set_layouts = try gc.allocator.alloc(vk.DescriptorSetLayout, prepend.len + reflect.set_layouts.len);
        for (prepend, 0..) |layout, i| {
            set_layouts[i] = layout;
        }
        for (reflect.set_layouts, 0..) |layout, i| {
            set_layouts[prepend.len + i] = layout;
        }

        break :blk try gc.device.createPipelineLayout(&.{
            .set_layout_count = @intCast(set_layouts.len),
            .p_set_layouts = set_layouts.ptr,
            .push_constant_range_count = @intCast(reflect.push_constants.len),
            .p_push_constant_ranges = reflect.push_constants.ptr,
        }, null);
    } else blk: {
        break :blk try gc.device.createPipelineLayout(&.{
            .set_layout_count = @intCast(reflect.set_layouts.len),
            .p_set_layouts = reflect.set_layouts.ptr,
            .push_constant_range_count = @intCast(reflect.push_constants.len),
            .p_push_constant_ranges = reflect.push_constants.ptr,
        }, null);
    };

    var pipeline: vk.Pipeline = undefined;
    const create_info = vk.ComputePipelineCreateInfo{
        .layout = pipeline_layout,
        .stage = vk.PipelineShaderStageCreateInfo{
            .stage = .{ .compute_bit = true },
            .module = shader.module,
            .p_name = shader.entry_point,
        },
        .base_pipeline_index = -1,
    };
    const result = try gc.device.createComputePipelines(vk.PipelineCache.null_handle, 1, @ptrCast(&create_info), null, @ptrCast(&pipeline));

    if (result != vk.Result.success) {
        return std.debug.panic("failed to create compute pipeline: {}", .{result});
    }

    return Self{
        .pipeline = pipeline,
        .layout = pipeline_layout,
        .pool = reflect.pool,
        .sets = reflect.sets,
        .first_set = first_set,
    };
}

pub fn destroy(self: *Self, gc: *Gc) void {
    gc.device.destroyPipeline(self.pipeline, null);
}
