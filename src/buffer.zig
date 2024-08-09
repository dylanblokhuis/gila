const std = @import("std");
const Gc = @import("root.zig");
const c = @import("c.zig");
const vk = Gc.vk;

const Self = @This();

buffer: vk.Buffer,
// address: usize,
allocation: c.VmaAllocation,
usage: vk.BufferUsageFlags,

pub const CreateInfo = struct {
    name: []const u8,
    size: u64 = 0,
    usage: vk.BufferUsageFlags,
    location: MemoryLocation = .auto,
};

pub const MemoryLocation = enum(c_uint) {
    //unknown = 0,
    // gpu_only = 1,
    //cpu_only = 2,
    // cpu_to_gpu = 3,
    // gpu_to_cpu = 4,
    // cpu_copy = 5,
    // gpu_lazily_allocated = 6,
    auto = 7,
    prefer_device = 8,
    prefer_host = 9,
};

pub fn create(gc: *Gc, desc: CreateInfo) !Self {
    const buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = desc.size,
        .usage = desc.usage.toInt(),
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };

    var buffer: c.VkBuffer = undefined;
    var allocation: c.VmaAllocation = undefined;

    var flags: c.VmaAllocationCreateFlags = 0;

    if (desc.usage.toInt() == vk.BufferUsageFlags.toInt(.{
        .transfer_src_bit = true,
    })) {
        flags |= c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT;
    }

    const alloc_create_info = c.VmaAllocationCreateInfo{
        .flags = flags,
        .usage = @intFromEnum(desc.location),
    };
    var alloc_info: c.VmaAllocationInfo = undefined;
    const result: vk.Result = @enumFromInt(c.vmaCreateBuffer(
        gc.vma,
        &buffer_info,
        &alloc_create_info,
        &buffer,
        &allocation,
        &alloc_info,
    ));

    switch (result) {
        .success => {},
        else => {
            std.debug.panic("Failed to create buffer {}\n", .{result});
        },
    }

    // const addr = gc.device.getBufferDeviceAddress(&.{
    //     .buffer = @enumFromInt(@intFromPtr(buffer)),
    // });
    // _ = addr; // autofix

    return Self{
        .buffer = @enumFromInt(@intFromPtr(buffer)),
        .allocation = allocation,
        // .address = addr,
        .usage = desc.usage,
    };
}

pub fn destroy(self: *Self, gc: *Gc) void {
    c.vmaDestroyBuffer(gc.vma, @ptrFromInt(@intFromEnum(self.buffer)), self.allocation);
}

pub fn setData(self: *Self, gc: *Gc, data: ?*const anyopaque, len: usize) void {
    const result = c.vmaCopyMemoryToAllocation(gc.vma, data, self.allocation, 0, len);
    if (result != c.VK_SUCCESS) {
        std.debug.panic("Failed to copy memory to buffer {}\n", .{result});
    }
}
