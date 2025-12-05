const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context").GraphicsContext;
const Allocator = std.mem.Allocator;

pub const Swapchain = struct {
    pub const PresentState = enum { optimal, suboptimal };

    gc: *const GraphicsContext,
    allocator: Allocator,

    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,

    swap_images: []SwapImage,
    image_index: u32,
    next_image_acquired: vk.Semaphore,

    /// First-time creation.
    /// Note: extent parameter is ignored on HiDPI platforms; we pick from framebuffer size.
    pub fn init(gc: *const GraphicsContext, allocator: Allocator, extent: vk.Extent2D) !Swapchain {
        _ = extent; // we compute from framebuffer
        return try buildSwapchain(gc, allocator, .null_handle);
    }

    /// Recreate after resize/suboptimal present.
    pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
        _ = new_extent; // ignored; derived from framebuffer
        const gc = self.gc;
        const allocator = self.allocator;
        const old_handle = self.handle;

        try gc.vkd.deviceWaitIdle(gc.dev);

        const new_swapchain = try buildSwapchain(gc, allocator, old_handle);

        self.deinitExceptSwapchain();
        gc.vkd.destroySwapchainKHR(gc.dev, old_handle, null);

        self.* = new_swapchain;
    }

    fn deinitExceptSwapchain(self: Swapchain) void {
        for (self.swap_images) |si| si.deinit(self.gc);
        self.allocator.free(self.swap_images);
        self.gc.vkd.destroySemaphore(self.gc.dev, self.next_image_acquired, null);
    }

    pub fn deinit(self: Swapchain) void {
        self.deinitExceptSwapchain();
        self.gc.vkd.destroySwapchainKHR(self.gc.dev, self.handle, null);
    }

    pub fn waitForAllFences(self: Swapchain) !void {
        for (self.swap_images) |si| si.waitForFence(self.gc) catch {};
    }

    pub fn currentImage(self: Swapchain) vk.Image {
        return self.swap_images[self.image_index].image;
    }

    pub fn currentSwapImage(self: Swapchain) *const SwapImage {
        return &self.swap_images[self.image_index];
    }

    /// Submit + present current image, then acquire the next one and rotate semaphores.
    pub fn present(self: *Swapchain, cmdbuf: vk.CommandBuffer) !PresentState {
        const current = self.currentSwapImage();
        try current.waitForFence(self.gc);
        try self.gc.vkd.resetFences(self.gc.dev, 1, @ptrCast(&current.frame_fence));

        const wait_stage = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        try self.gc.vkd.queueSubmit(self.gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.image_acquired),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&current.render_finished),
        }}, current.frame_fence);

        _ = try self.gc.vkd.queuePresentKHR(self.gc.present_queue.handle, &vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&self.image_index),
            .p_results = null,
        });

        const result = try self.gc.vkd.acquireNextImageKHR(
            self.gc.dev,
            self.handle,
            std.math.maxInt(u64),
            self.next_image_acquired,
            .null_handle,
        );

        std.mem.swap(
            vk.Semaphore,
            &self.swap_images[result.image_index].image_acquired,
            &self.next_image_acquired,
        );
        self.image_index = result.image_index;

        return switch (result.result) {
            .success => .optimal,
            .suboptimal_khr => .suboptimal,
            else => unreachable,
        };
    }

    /// Convenience: dynamic viewport/scissor that handles MoltenVK vs classic Vulkan Y-flip.
    pub fn cmdSetViewportAndScissor(self: *const Swapchain, gc: *const GraphicsContext, cmd: vk.CommandBuffer) void {
        const w: f32 = @floatFromInt(self.extent.width);
        const h: f32 = @floatFromInt(self.extent.height);

        const is_macos = @import("builtin").os.tag == .macos;

        var viewport = vk.Viewport{
            .x = 0,
            .y = if (is_macos) 0 else h,
            .width = w,
            .height = if (is_macos) h else -h,
            .min_depth = 0,
            .max_depth = 1,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.extent,
        };

        gc.vkd.cmdSetViewport(cmd, 0, 1, @as([*]const vk.Viewport, @ptrCast(&viewport)));
        gc.vkd.cmdSetScissor(cmd, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&scissor)));
    }
};

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(gc: *const GraphicsContext, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try gc.vkd.createImageView(gc.dev, &.{
            .flags = .{},
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
        errdefer gc.vkd.destroyImageView(gc.dev, view, null);

        const image_acquired = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        errdefer gc.vkd.destroySemaphore(gc.dev, image_acquired, null);

        const render_finished = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
        errdefer gc.vkd.destroySemaphore(gc.dev, render_finished, null);

        const frame_fence = try gc.vkd.createFence(gc.dev, &.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer gc.vkd.destroyFence(gc.dev, frame_fence, null);

        return .{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, gc: *const GraphicsContext) void {
        self.waitForFence(gc) catch {};
        gc.vkd.destroyImageView(gc.dev, self.view, null);
        gc.vkd.destroySemaphore(gc.dev, self.image_acquired, null);
        gc.vkd.destroySemaphore(gc.dev, self.render_finished, null);
        gc.vkd.destroyFence(gc.dev, self.frame_fence, null);
    }

    /// Exposed so caller can explicitly synchronize if desired.
    pub fn waitForFence(self: SwapImage, gc: *const GraphicsContext) !void {
        _ = try gc.vkd.waitForFences(
            gc.dev,
            1,
            @ptrCast(&self.frame_fence),
            @enumFromInt(vk.TRUE),
            std.math.maxInt(u64),
        );
    }
};

fn buildSwapchain(
    gc: *const GraphicsContext,
    allocator: Allocator,
    old_handle: vk.SwapchainKHR,
) !Swapchain {
    const caps = try gc.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);

    // HiDPI-safe: pick from the framebuffer (pixel) size.
    const fb = gc.framebufferExtent();
    const actual_extent = chooseSwapExtent(caps, fb);
    if (actual_extent.width == 0 or actual_extent.height == 0)
        return error.InvalidSurfaceDimensions;

    const surface_format = try findSurfaceFormat(gc, allocator);
    const present_mode = try findPresentMode(gc, allocator); // returns fifo_khr for robustness

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);

    const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };
    const sharing_mode: vk.SharingMode = if (gc.graphics_queue.family != gc.present_queue.family) .concurrent else .exclusive;

    const handle = try gc.vkd.createSwapchainKHR(gc.dev, &.{
        .flags = .{},
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
        .clipped = @enumFromInt(vk.TRUE),
        .old_swapchain = old_handle,
    }, null);
    errdefer gc.vkd.destroySwapchainKHR(gc.dev, handle, null);

    const swap_images = try initSwapchainImages(gc, handle, surface_format.format, allocator);
    errdefer {
        for (swap_images) |si| si.deinit(gc);
        allocator.free(swap_images);
    }

    var next_image_acquired = try gc.vkd.createSemaphore(gc.dev, &.{ .flags = .{} }, null);
    errdefer gc.vkd.destroySemaphore(gc.dev, next_image_acquired, null);

    const result = try gc.vkd.acquireNextImageKHR(
        gc.dev,
        handle,
        std.math.maxInt(u64),
        next_image_acquired,
        .null_handle,
    );
    if (result.result != .success and result.result != .suboptimal_khr)
        return error.ImageAcquireFailed;

    std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);

    const sc = Swapchain{
        .gc = gc,
        .allocator = allocator,
        .surface_format = surface_format,
        .present_mode = present_mode,
        .extent = actual_extent,
        .handle = handle,
        .swap_images = swap_images,
        .image_index = result.image_index,
        .next_image_acquired = next_image_acquired,
    };

    std.log.info(
        "Swapchain: extent={d}x{d} | format={s} | present_mode={s} | images={d} | first index={d}",
        .{
            sc.extent.width,
            sc.extent.height,
            @tagName(sc.surface_format.format),
            @tagName(sc.present_mode),
            sc.swap_images.len,
            sc.image_index,
        },
    );

    return sc;
}

fn initSwapchainImages(gc: *const GraphicsContext, swapchain: vk.SwapchainKHR, format: vk.Format, allocator: Allocator) ![]SwapImage {
    var count: u32 = undefined;
    _ = try gc.vkd.getSwapchainImagesKHR(gc.dev, swapchain, &count, null);
    const images = try allocator.alloc(vk.Image, count);
    defer allocator.free(images);
    _ = try gc.vkd.getSwapchainImagesKHR(gc.dev, swapchain, &count, images.ptr);

    const swap_images = try allocator.alloc(SwapImage, count);
    errdefer allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(gc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(gc, image, format);
        i += 1;
    }
    return swap_images;
}

fn findSurfaceFormat(gc: *const GraphicsContext, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{ .format = .b8g8r8a8_srgb, .color_space = .srgb_nonlinear_khr };

    var count: u32 = undefined;
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, null);
    const surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
    defer allocator.free(surface_formats);
    _ = try gc.vki.getPhysicalDeviceSurfaceFormatsKHR(gc.pdev, gc.surface, &count, surface_formats.ptr);

    for (surface_formats) |sfmt| if (std.meta.eql(sfmt, preferred)) return preferred;
    return surface_formats[0];
}

/// Robust choice: always prefer FIFO (vsync). It's guaranteed by the spec and avoids timing quirks
/// seen with .mailbox_khr / .immediate_khr while stabilizing synchronization.
fn findPresentMode(gc: *const GraphicsContext, allocator: Allocator) !vk.PresentModeKHR {
    // Query (kept for future configurability / diagnostics)
    var count: u32 = 0;
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, null);
    const modes = try allocator.alloc(vk.PresentModeKHR, count);
    defer allocator.free(modes);
    _ = try gc.vki.getPhysicalDeviceSurfacePresentModesKHR(gc.pdev, gc.surface, &count, modes.ptr);

    // Hard, robust default:
    return .fifo_khr;
}

/// Choose the swap extent from framebuffer pixels if the surface lets us.
fn chooseSwapExtent(caps: vk.SurfaceCapabilitiesKHR, fb: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) {
        return caps.current_extent;
    }
    return .{
        .width = std.math.clamp(fb.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(fb.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}
