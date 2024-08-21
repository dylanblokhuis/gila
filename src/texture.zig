const std = @import("std");
const Gc = @import("root.zig");

const vk = Gc.vk;
const c = Gc.c;

const Self = @This();

image: vk.Image,
allocation: ?c.VmaAllocation,
format: vk.Format,
usage: vk.ImageUsageFlags,
mip_levels: u32,
array_layers: u32,
view: vk.ImageView,
dimensions: vk.Extent3D,
name: []const u8,
dedicated: bool = false,

pub const CreateInfo = struct {
    name: []const u8,
    dimensions: vk.Extent3D,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    dedicated: bool = false,
    pool: ?Gc.VmaPoolHandle = null,
};

pub fn create(gc: *Gc, desc: CreateInfo) !Self {
    const image_create_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = if (desc.dimensions.depth > 1)
            c.VK_IMAGE_TYPE_3D
        else if (desc.dimensions.height > 1)
            c.VK_IMAGE_TYPE_2D
        else
            c.VK_IMAGE_TYPE_1D,
        .format = @intCast(@intFromEnum(desc.format)),
        .extent = c.VkExtent3D{
            .width = desc.dimensions.width,
            .height = desc.dimensions.height,
            .depth = desc.dimensions.depth,
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = vk.ImageUsageFlags.toInt(desc.usage),
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };

    var image: c.VkImage = undefined;
    var allocation: c.VmaAllocation = undefined;

    const vma_pool: ?c.VmaPool = if (desc.pool != null)
        gc.vma_pools.getUnchecked(desc.pool.?)
    else
        null;

    // https://gpuopen-librariesandsdks.github.io/VulkanMemoryAllocator/html/usage_patterns.html
    const alloc_info = c.VmaAllocationCreateInfo{
        .usage = c.VMA_MEMORY_USAGE_AUTO,
        .flags = if (desc.dedicated) c.VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT else 0,
        .pool = if (vma_pool != null) vma_pool.? else std.mem.zeroes(c.VmaPool),
    };

    const result: vk.Result = @enumFromInt(c.vmaCreateImage(gc.vma, &image_create_info, &alloc_info, &image, &allocation, null));

    switch (result) {
        .success => {},
        else => {
            std.debug.panic("Failed to create buffer {}\n", .{result});
        },
    }

    var self = Self{
        .image = @enumFromInt(@intFromPtr(image)),
        .allocation = allocation,
        .usage = desc.usage,
        .format = desc.format,
        .dimensions = desc.dimensions,
        .mip_levels = 1,
        .array_layers = 1,
        .view = undefined,
        .name = desc.name,
        .dedicated = desc.dedicated,
    };

    self.view = try self.createView(gc);

    return self;
}

pub fn destroy(self: *Self, gc: *Gc) void {
    if (self.allocation) |allocation| {
        c.vmaDestroyImage(gc.vma, @ptrFromInt(@intFromEnum(self.image)), allocation);
    } else {
        gc.device.destroyImage(self.image, null);
    }
}

pub fn getResourceRange(self: *const Self) vk.ImageSubresourceRange {
    return vk.ImageSubresourceRange{
        .aspect_mask = switch (self.format) {
            .d16_unorm => vk.ImageAspectFlags{ .depth_bit = true },
            .d24_unorm_s8_uint => vk.ImageAspectFlags{ .depth_bit = true, .stencil_bit = true },
            .d32_sfloat => vk.ImageAspectFlags{ .depth_bit = true },
            .d32_sfloat_s8_uint => vk.ImageAspectFlags{ .depth_bit = true, .stencil_bit = true },
            else => vk.ImageAspectFlags{ .color_bit = true },
        },
        .base_mip_level = 0,
        .level_count = self.mip_levels,
        .base_array_layer = 0,
        .layer_count = self.array_layers,
    };
}

pub fn createView(self: *Self, gc: *Gc) !vk.ImageView {
    return try gc.device.createImageView(&.{
        .view_type = if (self.dimensions.depth > 1)
            vk.ImageViewType.@"3d"
        else if (self.dimensions.height > 1)
            vk.ImageViewType.@"2d"
        else
            vk.ImageViewType.@"1d",

        .format = self.format,
        .components = vk.ComponentMapping{
            .r = vk.ComponentSwizzle.r,
            .g = vk.ComponentSwizzle.g,
            .b = vk.ComponentSwizzle.b,
            .a = vk.ComponentSwizzle.a,
        },
        .subresource_range = self.getResourceRange(),
        .image = self.image,
    }, null);
}

pub fn resize(self: *Self, gc: *Gc, dimensions: vk.Extent3D) !void {
    self.destroy(gc);

    self.* = try Self.create(gc, .{
        .name = self.name,
        .dimensions = dimensions,
        .format = self.format,
        .usage = self.usage,
        .dedicated = self.dedicated,
    });
}
