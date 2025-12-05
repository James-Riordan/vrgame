const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context").GraphicsContext;

pub const Texture = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    sampler: vk.Sampler,
    format: vk.Format,
    extent: vk.Extent3D,

    pub fn destroy(self: *Texture, vkd: anytype, dev: vk.Device, alloc: ?*const vk.AllocationCallbacks) void {
        if (self.view != .null_handle) vkd.destroyImageView(dev, self.view, alloc);
        if (self.sampler != .null_handle) vkd.destroySampler(dev, self.sampler, alloc);
        if (self.image != .null_handle) vkd.destroyImage(dev, self.image, alloc);
        if (self.memory != .null_handle) vkd.freeMemory(dev, self.memory, alloc);
        self.* = .{
            .image = .null_handle,
            .memory = .null_handle,
            .view = .null_handle,
            .sampler = .null_handle,
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = 0, .height = 0, .depth = 1 },
        };
    }
};

fn beginSingleUse(vkd: anytype, dev: vk.Device, family_index: u32) !struct { pool: vk.CommandPool, buf: vk.CommandBuffer } {
    const pool = try vkd.createCommandPool(dev, &vk.CommandPoolCreateInfo{
        .flags = .{ .transient_bit = true, .reset_command_buffer_bit = true },
        .queue_family_index = family_index,
    }, null);

    var buf: vk.CommandBuffer = undefined;
    try vkd.allocateCommandBuffers(dev, &vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&buf));

    try vkd.beginCommandBuffer(buf, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    return .{ .pool = pool, .buf = buf };
}

fn endSingleUse(
    vkd: anytype,
    dev: vk.Device,
    queue: vk.Queue,
    pool: vk.CommandPool,
    buf: vk.CommandBuffer,
) !void {
    try vkd.endCommandBuffer(buf);

    const si = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&buf),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try vkd.queueSubmit(queue, 1, @ptrCast(&si), .null_handle);
    try vkd.queueWaitIdle(queue);

    vkd.freeCommandBuffers(dev, pool, 1, @ptrCast(&buf));
    vkd.destroyCommandPool(dev, pool, null);
}

fn transitionImageLayout(
    vkd: anytype,
    dev: vk.Device,
    queue: vk.Queue,
    family: u32,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) !void {
    const single = try beginSingleUse(vkd, dev, family);

    var src_stage: vk.PipelineStageFlags = .{};
    var dst_stage: vk.PipelineStageFlags = .{};
    var src_access: vk.AccessFlags = .{};
    var dst_access: vk.AccessFlags = .{};

    if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
        src_stage = .{ .top_of_pipe_bit = true };
        dst_stage = .{ .transfer_bit = true };
        src_access = .{};
        dst_access = .{ .transfer_write_bit = true };
    } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
        src_stage = .{ .transfer_bit = true };
        dst_stage = .{ .fragment_shader_bit = true };
        src_access = .{ .transfer_write_bit = true };
        dst_access = .{ .shader_read_bit = true };
    } else {
        @panic("unsupported layout transition");
    }

    const range = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    const barrier = vk.ImageMemoryBarrier{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = range,
    };

    vkd.cmdPipelineBarrier(
        single.buf,
        src_stage,
        dst_stage,
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast(&barrier),
    );

    try endSingleUse(vkd, dev, queue, single.pool, single.buf);
}

fn copyBufferToImage(
    vkd: anytype,
    dev: vk.Device,
    queue: vk.Queue,
    family: u32,
    buf: vk.Buffer,
    image: vk.Image,
    width: u32,
    height: u32,
) !void {
    const single = try beginSingleUse(vkd, dev, family);

    const sub = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };

    vkd.cmdCopyBufferToImage(single.buf, buf, image, .transfer_dst_optimal, 1, @ptrCast(&sub));
    try endSingleUse(vkd, dev, queue, single.pool, single.buf);
}

pub fn createCheckerboard(
    gc: *const GraphicsContext,
    allocator: std.mem.Allocator,
    size: u32, // e.g. 512
    cell: u32, // e.g. 32
) !Texture {
    const vkd = gc.vkd;
    const dev = gc.dev;

    const W = size;
    const H = size;

    // Generate CPU RGBA8 checkerboard
    const px_count: usize = @as(usize, @intCast(W)) * @as(usize, @intCast(H));
    var pixels = try allocator.alloc(u32, px_count);
    defer allocator.free(pixels);

    var y: u32 = 0;
    while (y < H) : (y += 1) {
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            const cx = (x / cell) & 1;
            const cy = (y / cell) & 1;
            const on = (cx ^ cy) == 1;
            const rgb: u32 = if (on) 0xff_c6d7ff else 0xff_3a4150; // ABGR8 (little endian u32)
            pixels[@as(usize, @intCast(y)) * @as(usize, @intCast(W)) + @as(usize, @intCast(x))] = rgb;
        }
    }

    // Staging buffer
    const buf_size: vk.DeviceSize = @as(vk.DeviceSize, @intCast(px_count * @sizeOf(u32)));
    const staging = try vkd.createBuffer(dev, &vk.BufferCreateInfo{
        .flags = .{},
        .size = buf_size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer vkd.destroyBuffer(dev, staging, null);

    const sreq = vkd.getBufferMemoryRequirements(dev, staging);
    const smem = try gc.allocate(sreq, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer vkd.freeMemory(dev, smem, null);
    try vkd.bindBufferMemory(dev, staging, smem, 0);

    const map = try vkd.mapMemory(dev, smem, 0, vk.WHOLE_SIZE, .{});
    defer vkd.unmapMemory(dev, smem);
    @memcpy(@as([*]u8, @ptrCast(@alignCast(map))), std.mem.sliceAsBytes(pixels));

    // Image
    const format = vk.Format.r8g8b8a8_unorm; // keep UNORM for now (sRGB pipeline later)
    const image = try vkd.createImage(dev, &vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = W, .height = H, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    }, null);
    errdefer vkd.destroyImage(dev, image, null);

    const req = vkd.getImageMemoryRequirements(dev, image);
    const mem = try gc.allocate(req, .{ .device_local_bit = true });
    errdefer vkd.freeMemory(dev, mem, null);
    try vkd.bindImageMemory(dev, image, mem, 0);

    // Upload
    try transitionImageLayout(vkd, dev, gc.graphics_queue.handle, gc.graphics_queue.family, image, .undefined, .transfer_dst_optimal);
    try copyBufferToImage(vkd, dev, gc.graphics_queue.handle, gc.graphics_queue.family, staging, image, W, H);
    try transitionImageLayout(vkd, dev, gc.graphics_queue.handle, gc.graphics_queue.family, image, .transfer_dst_optimal, .shader_read_only_optimal);

    // View
    const view = try vkd.createImageView(dev, &vk.ImageViewCreateInfo{
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
    errdefer vkd.destroyImageView(dev, view, null);

    // Sampler (cast Bool32 fields properly)
    const sampler = try vkd.createSampler(dev, &vk.SamplerCreateInfo{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .mip_lod_bias = 0,
        .anisotropy_enable = @enumFromInt(0), // vk.Bool32 false
        .max_anisotropy = 1,
        .compare_enable = @enumFromInt(0), // vk.Bool32 false
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = @enumFromInt(0), // vk.Bool32 false
    }, null);
    errdefer vkd.destroySampler(dev, sampler, null);

    return Texture{
        .image = image,
        .memory = mem,
        .view = view,
        .sampler = sampler,
        .format = format,
        .extent = .{ .width = W, .height = H, .depth = 1 },
    };
}
