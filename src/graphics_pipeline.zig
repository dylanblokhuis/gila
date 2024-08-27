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
    vertex: VertexState,
    primitive: PrimitiveState = PrimitiveState{},
    depth_stencil: ?DepthStencilState = null,
    multisample: MultiSampleState = MultiSampleState{},
    /// when null, the pipeline will not have a fragment stage but depth will still be written by the vertex shader.
    fragment: ?FragmentState = null,
    prepend_descriptor_set_layouts: ?[]const vk.DescriptorSetLayout = null,
    flags: Flags = Flags{},
};

pub const Flags = packed struct {
    /// Vertex is used by default when fragment is null, otherwise fragment is used unless this flag is set to false
    use_fragment_for_reflection: bool = true,
};

pub const VertexState = struct {
    shader: Gc.ShaderHandle,
    buffer_layout: []const VertexBufferLayout,
};

pub const VertexBufferLayout = struct {
    /// The stride, in bytes, between elements of this buffer.
    stride: u32,
    attributes: []const VertexAttribute,
    step_mode: vk.VertexInputRate = .vertex,
};

pub const VertexAttribute = struct {
    /// The location of this attribute in the shader.
    location: u32,
    /// The format of this attribute.
    format: vk.Format,
    /// The offset, in bytes, from the start of the buffer to the first element of this attribute.
    offset: u32,
};

pub const PrimitiveState = struct {
    topology: vk.PrimitiveTopology = .triangle_list,
    front_face: vk.FrontFace = .counter_clockwise,
    cull_mode: vk.CullModeFlags = .{},
    polygon_mode: vk.PolygonMode = .fill,

    strip_index_format: ?vk.IndexType = null,
    unclipped_depth: bool = false,
    conservative_rasterization: bool = false,
};

pub const DepthStencilState = struct {
    format: vk.Format,
    depth_write_enabled: bool = true,
    depth_compare_op: vk.CompareOp,
    stencil: StencilState = StencilState{},
    bias: DepthBiasState = DepthBiasState{},

    pub fn is_depth_enabled(self: DepthStencilState) bool {
        return self.depth_compare_op != .always or self.depth_write_enabled;
    }

    pub fn is_depth_read_only(self: DepthStencilState) bool {
        return !self.depth_write_enabled;
    }

    pub fn is_stencil_read_only(self: DepthStencilState, cull_mode: ?vk.CullModeFlags) bool {
        return self.stencil.is_read_only(cull_mode);
    }

    pub fn is_read_only(self: DepthStencilState, cull_mode: ?vk.CullModeFlags) bool {
        return self.is_depth_read_only() and self.is_stencil_read_only(cull_mode);
    }
};

pub const DepthBiasState = struct {
    constant_factor: f32 = 0.0,
    clamp: f32 = 0.0,
    slope_factor: f32 = 0.0,
};

pub const StencilState = struct {
    front: StencilFaceState = StencilFaceState.Ignore,
    back: StencilFaceState = StencilFaceState.Ignore,
    read_mask: u32 = 0xFF,
    write_mask: u32 = 0xFF,

    pub fn is_enabled(self: StencilState) bool {
        const is_front_enabled = std.meta.eql(self.front, StencilFaceState.Ignore);
        const is_back_enabled = std.meta.eql(self.back, StencilFaceState.Ignore);

        return (!is_front_enabled or !is_back_enabled) and (self.read_mask != 0 or self.write_mask != 0);
    }

    pub fn is_read_only(self: StencilState, cull_mode: ?vk.CullModeFlags) bool {
        if (self.write_mask == 0) {
            return true;
        }

        const front_ro = (cull_mode != null and cull_mode.?.front_bit) or self.front.is_read_only();
        const back_ro = (cull_mode != null and cull_mode.?.back_bit) or self.back.is_read_only();

        return front_ro and back_ro;
    }
};

pub const StencilFaceState = struct {
    compare_op: vk.CompareOp,
    fail_op: vk.StencilOp,
    pass_op: vk.StencilOp,
    depth_fail_op: vk.StencilOp,

    pub const Ignore = StencilFaceState{
        .compare_op = .always,
        .fail_op = .keep,
        .pass_op = .keep,
        .depth_fail_op = .keep,
    };

    pub fn is_read_only(self: StencilFaceState) bool {
        return self.pass_op == .keep and self.fail_op == .keep and self.depth_fail_op == .keep;
    }
};
pub const MultiSampleState = struct {
    count: vk.SampleCountFlags = .{
        .@"1_bit" = true,
    },
    mask: u64 = 0xFFFFFFFFFFFFFFFF,
    alpha_to_coverage: bool = false,
};

pub const FragmentState = struct {
    shader: Gc.ShaderHandle,
    color_targets: []const ColorAttachment,
};

pub const ColorAttachment = struct {
    format: vk.Format,
    blend: ?BlendState = null,
    write_to_channels: vk.ColorComponentFlags = .{
        .r_bit = true,
        .g_bit = true,
        .b_bit = true,
        .a_bit = true,
    },
};

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,

    pub const Replace = BlendState{
        .color = BlendComponent.Replace,
        .alpha = BlendComponent.Replace,
    };

    pub const AlphaBlending = BlendState{
        .color = .{
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
            .op = .add,
        },
        .alpha = BlendComponent.Over,
    };

    pub const PremultipliedAlphaBlending = BlendState{
        .color = BlendComponent.Over,
        .alpha = BlendComponent.Over,
    };
};

pub const BlendComponent = struct {
    src_factor: vk.BlendFactor,
    dst_factor: vk.BlendFactor,
    op: vk.BlendOp,

    pub const Replace = BlendComponent{
        .src_factor = .one,
        .dst_factor = .zero,
        .op = .add,
    };

    pub const Over = BlendComponent{
        .src_factor = .one,
        .dst_factor = .one_minus_src_alpha,
        .op = .add,
    };
};

pub fn create(gc: *Gc, desc: Self.CreateInfo) !Self {
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor, .blend_constants, .stencil_reference };

    // var stages = try std.BoundedArray(vk.PipelineShaderStageCreateInfo, 2).init(if (desc.fragment != null) 2 else 1);
    var vertex_buffers = try std.BoundedArray(vk.VertexInputBindingDescription, 16).init(desc.vertex.buffer_layout.len);
    var max_vertex_attributes: usize = 0;
    for (desc.vertex.buffer_layout) |layout| {
        max_vertex_attributes += layout.attributes.len;
    }

    var vertex_attributes = try std.BoundedArray(vk.VertexInputAttributeDescription, 16 * 4).init(max_vertex_attributes);

    for (desc.vertex.buffer_layout, 0..) |layout, i| {
        // vertex_buffers.buffer[o]
        vertex_buffers.buffer[i] = .{
            .binding = @intCast(i),
            .stride = layout.stride,
            .input_rate = layout.step_mode,
        };

        for (layout.attributes, 0..) |attribute, j| {
            vertex_attributes.buffer[i + j] = .{
                .location = attribute.location,
                .format = attribute.format,
                .offset = attribute.offset,
                .binding = @intCast(i),
            };
        }
    }

    const vertex_input = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(desc.vertex.buffer_layout.len),
        .p_vertex_binding_descriptions = vertex_buffers.slice().ptr,

        .vertex_attribute_description_count = @intCast(vertex_attributes.len),
        .p_vertex_attribute_descriptions = vertex_attributes.slice().ptr,
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = desc.primitive.topology,
        .primitive_restart_enable = if (desc.primitive.strip_index_format != null) 1 else 0,
    };

    var rasterization = vk.PipelineRasterizationStateCreateInfo{
        .polygon_mode = desc.primitive.polygon_mode,
        .front_face = desc.primitive.front_face,
        .line_width = 1.0,
        .depth_clamp_enable = if (desc.primitive.unclipped_depth) 1 else 0,
        .rasterizer_discard_enable = 0,
        .cull_mode = desc.primitive.cull_mode,

        // these will be set later
        .depth_bias_enable = 0,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_slope_factor = 0.0,
    };

    const conservative_rasterization = vk.PipelineRasterizationConservativeStateCreateInfoEXT{
        .conservative_rasterization_mode = .overestimate_ext,
        .extra_primitive_overestimation_size = 0.0,
    };

    if (desc.primitive.conservative_rasterization) {
        rasterization.p_next = &conservative_rasterization;
    }

    var vk_depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .back = vk.StencilOpState{
            .compare_op = .always,
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .front = vk.StencilOpState{
            .compare_op = .always,
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .depth_test_enable = 0,
        .depth_write_enable = 0,
        .depth_compare_op = .always,
        .depth_bounds_test_enable = 0,
        .stencil_test_enable = 0,
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };
    if (desc.depth_stencil) |depth_stencil| {

        // todo: adjust this based on the options
        // const layout = if (depth_stencil.is_read_only(desc.primitive.cull_mode)) vk.ImageLayout.depth_stencil_read_only_optimal else vk.ImageLayout.depth_stencil_attachment_optimal;
        // _ = layout; // autofix

        // is depth_enabled?
        if (depth_stencil.is_depth_enabled()) {
            vk_depth_stencil.depth_test_enable = 1;
            vk_depth_stencil.depth_write_enable = if (depth_stencil.depth_write_enabled) 1 else 0;
            vk_depth_stencil.depth_compare_op = depth_stencil.depth_compare_op;
        }
        if (depth_stencil.stencil.is_enabled()) {
            vk_depth_stencil.stencil_test_enable = 1;
            vk_depth_stencil.front = vk.StencilOpState{
                .compare_op = depth_stencil.stencil.front.compare_op,
                .fail_op = depth_stencil.stencil.front.fail_op,
                .pass_op = depth_stencil.stencil.front.pass_op,
                .depth_fail_op = depth_stencil.stencil.front.depth_fail_op,
                .compare_mask = depth_stencil.stencil.read_mask,
                .write_mask = depth_stencil.stencil.write_mask,
                .reference = 0,
            };
            vk_depth_stencil.back = vk.StencilOpState{
                .compare_op = depth_stencil.stencil.back.compare_op,
                .fail_op = depth_stencil.stencil.back.fail_op,
                .pass_op = depth_stencil.stencil.back.pass_op,
                .depth_fail_op = depth_stencil.stencil.back.depth_fail_op,
                .compare_mask = depth_stencil.stencil.read_mask,
                .write_mask = depth_stencil.stencil.write_mask,
                .reference = 0,
            };
        }
        if (depth_stencil.bias.constant_factor != 0.0 or depth_stencil.bias.slope_factor != 0.0) {
            rasterization.depth_bias_enable = 1;
            rasterization.depth_bias_constant_factor = depth_stencil.bias.constant_factor;
            rasterization.depth_bias_clamp = depth_stencil.bias.clamp;
            rasterization.depth_bias_slope_factor = depth_stencil.bias.slope_factor;
        }
    }

    const viewport = vk.PipelineViewportStateCreateInfo{
        .scissor_count = 1,
        .viewport_count = 1,
    };

    const vk_sample_mask = [_]u32{
        @intCast(desc.multisample.mask & 0xFFFFFFFF),
        @intCast(desc.multisample.mask >> 32),
    };

    const multisample = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = desc.multisample.count,
        .alpha_to_coverage_enable = @intFromBool(desc.multisample.alpha_to_coverage),
        .p_sample_mask = &vk_sample_mask,

        // currently not supported
        .sample_shading_enable = 0,
        .min_sample_shading = 0.0,
        .alpha_to_one_enable = 0,
    };

    const targets = if (desc.fragment != null) desc.fragment.?.color_targets else &.{};
    var color_formats = try std.BoundedArray(vk.Format, 8).init(targets.len);
    var attachments = try std.BoundedArray(vk.PipelineColorBlendAttachmentState, 8).init(targets.len);
    for (targets, 0..) |color_target, i| {
        var attachment: vk.PipelineColorBlendAttachmentState = .{
            .blend_enable = vk.FALSE,
            .color_write_mask = color_target.write_to_channels,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
        };

        if (color_target.blend) |blend| {
            attachment.blend_enable = vk.TRUE;
            attachment.color_blend_op = blend.color.op;
            attachment.src_color_blend_factor = blend.color.src_factor;
            attachment.dst_color_blend_factor = blend.color.dst_factor;
            attachment.alpha_blend_op = blend.alpha.op;
            attachment.src_alpha_blend_factor = blend.alpha.src_factor;
            attachment.dst_alpha_blend_factor = blend.alpha.dst_factor;
        }

        attachments.buffer[i] = attachment;
        color_formats.buffer[i] = color_target.format;
    }

    std.debug.assert(targets.len == attachments.len);

    const color_blend = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .clear,
        .attachment_count = @intCast(attachments.len),
        .p_attachments = attachments.slice().ptr,
        .blend_constants = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
    };

    const dynamic_state = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = @intCast(dynamic_states.len),
        .p_dynamic_states = &dynamic_states,
    };

    var stages = try std.BoundedArray(vk.PipelineShaderStageCreateInfo, 2).init(if (desc.fragment != null) 2 else 1);
    var vertex_shader = gc.shaders.get(desc.vertex.shader).?;
    var shader_used_for_reflection = &vertex_shader;

    stages.buffer[0] = .{
        .p_name = vertex_shader.getEntryPoint(),
        .module = vertex_shader.module,
        .stage = vk.ShaderStageFlags{
            .vertex_bit = true,
        },
    };
    if (desc.fragment != null) {
        var fragment_shader = gc.shaders.get(desc.fragment.?.shader).?;
        stages.buffer[1] = .{
            .p_name = fragment_shader.getEntryPoint(),
            .module = fragment_shader.module,
            .stage = vk.ShaderStageFlags{
                .fragment_bit = true,
            },
        };
        if (desc.flags.use_fragment_for_reflection) {
            shader_used_for_reflection = &fragment_shader;
        }
    }

    const reflect = try shader_used_for_reflection.doReflect(gc, if (desc.prepend_descriptor_set_layouts) |s| @intCast(s.len) else null);
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

    const rendering_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = @intCast(targets.len),
        .p_color_attachment_formats = color_formats.slice().ptr,
        .depth_attachment_format = if (desc.depth_stencil != null) desc.depth_stencil.?.format else vk.Format.undefined,
        .stencil_attachment_format = vk.Format.undefined,
        .view_mask = 0,
    };

    const vk_info = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = @intCast(stages.len),
        .p_stages = stages.slice().ptr,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_tessellation_state = null,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &rasterization,
        .p_multisample_state = &multisample,
        .p_depth_stencil_state = &vk_depth_stencil,
        .p_dynamic_state = &dynamic_state,
        .layout = pipeline_layout,
        .p_color_blend_state = &color_blend,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
        .p_next = &rendering_info,
    };

    var pipeline: vk.Pipeline = undefined;
    const result = try gc.device.createGraphicsPipelines(vk.PipelineCache.null_handle, 1, @ptrCast(&vk_info), null, @ptrCast(&pipeline));
    if (result != vk.Result.success) {
        return std.debug.panic("failed to create graphics pipeline: {}", .{result});
    }

    return Self{
        .pipeline = pipeline,
        .layout = pipeline_layout,
        .sets = reflect.sets,
        .pool = reflect.pool,
        .first_set = first_set,
    };
}

pub fn destroy(self: *Self, gc: *Gc) void {
    gc.device.destroyPipeline(self.pipeline, null);
    gc.device.destroyPipelineLayout(self.layout, null);
    if (self.pool) |pool| {
        gc.device.destroyDescriptorPool(pool, null);
        gc.allocator.free(self.sets);
    }
}

// const UpdateDescriptor = union(enum) {
//     buffer: Gc.BufferHandle,
//     texture: Gc.TextureHandle,
// };
// const DescriptorLocation = struct {
//     set: u32,
//     binding: u32,
//     array_element: u32 = 0,
// };

// /// runs updateDescriptorSets with the given data_handle
// pub fn updateDescriptor(self: *const Self, gc: *Gc, location: DescriptorLocation, data_handle: UpdateDescriptor, sampler_desc: ?Gc.SamplerDesc) void {
//     const sets = self.getDescriptorSetsCombined(gc) catch unreachable;
//     const set = sets[location.set];

//     switch (data_handle) {
//         .buffer => |handle| {
//             const buffer = gc.buffers.get(handle).?;

//             var ty = vk.DescriptorType.uniform_buffer;

//             if (buffer.usage.contains(.{ .storage_buffer_bit = true })) {
//                 ty = vk.DescriptorType.storage_buffer;
//             }

//             if (buffer.usage.contains(.{ .uniform_buffer_bit = true })) {
//                 ty = vk.DescriptorType.uniform_buffer;
//             }

//             const texel_buffer_view = [0]vk.BufferView{};
//             const image_info = [0]vk.DescriptorImageInfo{};
//             var buffer_info = vk.DescriptorBufferInfo{
//                 .buffer = buffer.buffer,
//                 .offset = 0,
//                 .range = vk.WHOLE_SIZE,
//             };

//             const write = vk.WriteDescriptorSet{
//                 .dst_set = set,
//                 .dst_binding = location.binding,
//                 .dst_array_element = location.array_element,
//                 .descriptor_count = 1,
//                 .descriptor_type = ty,
//                 .p_image_info = &image_info,
//                 .p_buffer_info = @ptrCast(&buffer_info),
//                 .p_texel_buffer_view = &texel_buffer_view,
//             };

//             gc.device.updateDescriptorSets(1, @ptrCast(&write), 0, null);
//         },
//         .texture => |handle| {
//             const texture = gc.textures.get(handle).?;

//             const buffer_info = [0]vk.DescriptorBufferInfo{};
//             const texel_buffer_view = [0]vk.BufferView{};

//             var image_info = vk.DescriptorImageInfo{
//                 .sampler = vk.Sampler.null_handle,
//                 .image_view = texture.view,
//                 .image_layout = vk.ImageLayout.general,
//             };

//             var ty = vk.DescriptorType.combined_image_sampler;

//             if (texture.usage.contains(.{ .color_attachment_bit = true })) {
//                 image_info = vk.DescriptorImageInfo{
//                     .sampler = vk.Sampler.null_handle,
//                     .image_view = texture.view,
//                     .image_layout = vk.ImageLayout.color_attachment_optimal,
//                 };
//                 ty = vk.DescriptorType.input_attachment;
//             }

//             if (texture.usage.contains(.{ .depth_stencil_attachment_bit = true })) {
//                 image_info = vk.DescriptorImageInfo{
//                     .sampler = vk.Sampler.null_handle,
//                     .image_view = texture.view,
//                     .image_layout = vk.ImageLayout.depth_attachment_optimal,
//                 };
//                 ty = vk.DescriptorType.input_attachment;
//             }

//             if (texture.usage.contains(.{ .storage_bit = true })) {
//                 image_info = vk.DescriptorImageInfo{
//                     .sampler = vk.Sampler.null_handle,
//                     .image_view = texture.view,
//                     .image_layout = vk.ImageLayout.general,
//                 };
//                 ty = vk.DescriptorType.storage_image;
//             }

//             if (texture.usage.contains(.{ .sampled_bit = true })) {
//                 if (sampler_desc == null) {
//                     return std.debug.panic("a sampler_desc is required for sampled textures", .{});
//                 }

//                 image_info = vk.DescriptorImageInfo{
//                     .sampler = gc.samplers.get(sampler_desc.?).?,
//                     .image_view = texture.view,
//                     .image_layout = vk.ImageLayout.shader_read_only_optimal,
//                 };
//                 ty = vk.DescriptorType.combined_image_sampler;
//             }

//             const write = vk.WriteDescriptorSet{
//                 .dst_set = set,
//                 .dst_binding = location.binding,
//                 .dst_array_element = location.array_element,
//                 .descriptor_count = 1,
//                 .descriptor_type = ty,
//                 .p_image_info = @ptrCast(&image_info),
//                 .p_buffer_info = @ptrCast(&buffer_info),
//                 .p_texel_buffer_view = @ptrCast(&texel_buffer_view),
//             };
//             gc.device.updateDescriptorSets(1, @ptrCast(&write), 0, null);
//         },
//     }
// }
