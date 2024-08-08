const std = @import("std");
const Gc = @import("root.zig");
const vk = Gc.vk;
const Allocator = std.mem.Allocator;

const Self = @This();

pub const PresentState = enum {
    optimal,
    suboptimal,
};

gc: *Gc,
surface_format: vk.SurfaceFormatKHR,
present_mode: vk.PresentModeKHR,
extent: vk.Extent2D,
handle: vk.SwapchainKHR,

swap_images: []SwapImage,
image_index: u32,
next_image_acquired: vk.Semaphore,

pub fn init(gc: *Gc, extent: vk.Extent2D) !Self {
    return try initRecycle(gc, extent, .null_handle);
}

pub fn initRecycle(gc: *Gc, extent: vk.Extent2D, old_handle: vk.SwapchainKHR) !Self {
    const caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.physical_device, gc.surface);
    const actual_extent = findActualExtent(caps, extent);
    if (actual_extent.width == 0 or actual_extent.height == 0) {
        return error.InvalidSurfaceDimensions;
    }

    const surface_format = try findSurfaceFormat(gc, gc.allocator);
    const present_mode = try findPresentMode(gc, gc.allocator);

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) {
        image_count = @min(image_count, caps.max_image_count);
    }

    const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };
    const sharing_mode: vk.SharingMode = if (gc.graphics_queue.family != gc.present_queue.family)
        .concurrent
    else
        .exclusive;

    const handle = try gc.device.createSwapchainKHR(&.{
        .surface = gc.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .queue_family_index_count = qfi.len,
        .p_queue_family_indices = &qfi,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = old_handle,
    }, null);
    errdefer gc.device.destroySwapchainKHR(handle, null);

    if (old_handle != .null_handle) {
        // Apparently, the old swapchain handle still needs to be destroyed after recreating.
        gc.device.destroySwapchainKHR(old_handle, null);
    }

    const swap_images = try initSwapchainImages(gc, handle, surface_format.format, gc.allocator);
    errdefer {
        for (swap_images) |si| si.deinit(gc);
        gc.allocator.free(swap_images);
    }
    var next_image_acquired = try gc.device.createSemaphore(&.{}, null);
    errdefer gc.device.destroySemaphore(next_image_acquired, null);

    const result = try gc.device.acquireNextImageKHR(handle, std.math.maxInt(u64), next_image_acquired, .null_handle);
    if (result.result != .success) {
        return error.ImageAcquireFailed;
    }

    std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);
    return Self{
        .gc = gc,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .extent = actual_extent,
        .handle = handle,
        .swap_images = swap_images,
        .image_index = result.image_index,
        .next_image_acquired = next_image_acquired,
    };
}

fn deinitExceptSwapchain(self: Self) void {
    for (self.swap_images) |si| si.deinit(self.gc);
    self.gc.allocator.free(self.swap_images);
    self.gc.device.destroySemaphore(self.next_image_acquired, null);
}

// pub fn waitForAllFences(self: Self) !void {
//     for (self.swap_images) |si| si.waitForFence(self.gc) catch {};
// }

pub fn deinit(self: Self) void {
    self.deinitExceptSwapchain();
    self.gc.device.destroySwapchainKHR(self.handle, null);
}

pub fn recreate(self: *Self, new_extent: vk.Extent2D) !void {
    const old_handle = self.handle;
    self.deinitExceptSwapchain();
    self.* = try initRecycle(self.gc, new_extent, old_handle);
}

pub fn currentImage(self: Self) vk.Image {
    return self.swap_images[self.image_index].image;
}

pub fn currentSwapImage(self: Self) *const SwapImage {
    return &self.swap_images[self.image_index];
}

/// assumes the command buffer is already been ended
pub fn present(self: *Self, cmdbuf: vk.CommandBuffer, fence: vk.Fence) !PresentState {
    const current = self.currentSwapImage();
    _ = try self.gc.device.waitForFences(1, @ptrCast(&current.frame_fence), vk.TRUE, std.math.maxInt(u64));
    try self.gc.device.resetFences(1, @ptrCast(&current.frame_fence));

    const acquire_complete_info = vk.SemaphoreSubmitInfo{
        .semaphore = current.image_acquired,
        .stage_mask = .{ .top_of_pipe_bit = true },
        .device_index = 0,
        .value = 1, // noop
    };
    const commend_buffer_info = vk.CommandBufferSubmitInfo{
        .command_buffer = cmdbuf,
        .device_mask = 0,
    };
    const rendering_complete_info = vk.SemaphoreSubmitInfo{
        .semaphore = current.render_finished,
        .stage_mask = .{ .bottom_of_pipe_bit = true },
        .device_index = 0,
        .value = 2, // noop
    };

    try self.gc.device.queueSubmit2(self.gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo2{vk.SubmitInfo2{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = @ptrCast(&acquire_complete_info),
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = @ptrCast(&commend_buffer_info),
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = @ptrCast(&rendering_complete_info),
    }}, fence);

    _ = try self.gc.device.queuePresentKHR(self.gc.present_queue.handle, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.render_finished),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.handle),
        .p_image_indices = @ptrCast(&self.image_index),
    });

    const result = try self.gc.device.acquireNextImageKHR(
        self.handle,
        std.math.maxInt(u64),
        self.next_image_acquired,
        current.frame_fence,
    );

    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
    self.image_index = result.image_index;

    return switch (result.result) {
        .success => .optimal,
        .suboptimal_khr => .suboptimal,
        else => unreachable,
    };
}

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(gc: *Gc, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try gc.device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer gc.device.destroyImageView(view, null);

        const image_acquired = try gc.device.createSemaphore(&.{}, null);
        errdefer gc.device.destroySemaphore(image_acquired, null);

        const render_finished = try gc.device.createSemaphore(&.{}, null);
        errdefer gc.device.destroySemaphore(render_finished, null);

        const frame_fence = try gc.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer gc.device.destroyFence(frame_fence, null);

        return SwapImage{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, gc: *Gc) void {
        gc.device.destroyImageView(self.view, null);
        gc.device.destroySemaphore(self.image_acquired, null);
        gc.device.destroySemaphore(self.render_finished, null);
        gc.device.destroyFence(self.frame_fence, null);
    }
};

fn initSwapchainImages(gc: *Gc, swapchain: vk.SwapchainKHR, format: vk.Format, allocator: Allocator) ![]SwapImage {
    const images = try gc.device.getSwapchainImagesAllocKHR(swapchain, allocator);
    defer allocator.free(images);

    const swap_images = try allocator.alloc(SwapImage, images.len);
    errdefer allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, image, format);
        i += 1;
    }

    return swap_images;
}

fn findSurfaceFormat(gc: *Gc, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try gc.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(gc.physical_device, gc.surface, allocator);
    defer allocator.free(surface_formats);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

fn findPresentMode(gc: *Gc, allocator: Allocator) !vk.PresentModeKHR {
    const present_modes = try gc.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(gc.physical_device, gc.surface, allocator);
    defer allocator.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}
