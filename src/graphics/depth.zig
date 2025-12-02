const std = @import("std");
const vk = @import("vulkan");

pub fn chooseDepthFormat(vki: anytype, physical_device: vk.PhysicalDevice) !vk.Format {
    const candidates = [_]vk.Format{
        .d32_sfloat,
        .d32_sfloat_s8_uint,
        .d24_unorm_s8_uint,
    };

    inline for (candidates) |fmt| {
        const props = vki.getPhysicalDeviceFormatProperties(physical_device, fmt);
        const opt_bits = props.optimal_tiling_features.toInt();
        const mask_bits = depthStencilAttachmentMask().toInt();
        if ((opt_bits & mask_bits) != 0) return fmt;
    }

    return error.NoSupportedDepthFormat;
}

fn depthStencilAttachmentMask() vk.FormatFeatureFlags {
    return .{ .depth_stencil_attachment_bit = true };
}

fn formatHasStencil(format: vk.Format) bool {
    return switch (format) {
        .d32_sfloat_s8_uint, .d24_unorm_s8_uint => true,
        else => false,
    };
}

pub const DepthCreateInfo = struct {
    extent: vk.Extent2D,
    memory_props: vk.PhysicalDeviceMemoryProperties,
    format: vk.Format,
    sample_count: vk.SampleCountFlags = .{ .@"1_bit" = true },
    allocator: ?*const vk.AllocationCallbacks = null,
};

pub const DepthResources = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,

    pub fn destroy(self: DepthResources, vkd: anytype, device: vk.Device, allocator: ?*const vk.AllocationCallbacks) void {
        vkd.destroyImageView(device, self.view, allocator);
        vkd.destroyImage(device, self.image, allocator);
        vkd.freeMemory(device, self.memory, allocator);
    }
};

pub fn createDepthResources(vkd: anytype, device: vk.Device, info: DepthCreateInfo) !DepthResources {
    // 1) Image
    const image_ci = vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = info.format,
        .extent = .{ .width = info.extent.width, .height = info.extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = info.sample_count,
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    };

    const image = try vkd.createImage(device, &image_ci, info.allocator);

    // 2) Allocate & bind memory
    const reqs = vkd.getImageMemoryRequirements(device, image);
    const type_index = try findMemoryTypeIndex(
        info.memory_props,
        reqs.memory_type_bits,
        .{ .device_local_bit = true },
    );

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
        .p_next = null,
    };

    const memory = try vkd.allocateMemory(device, &alloc_info, info.allocator);
    try vkd.bindImageMemory(device, image, memory, 0);

    // 3) View
    var aspect = vk.ImageAspectFlags{ .depth_bit = true };
    if (formatHasStencil(info.format)) aspect.stencil_bit = true;

    const view_ci = vk.ImageViewCreateInfo{
        .flags = .{},
        .image = image,
        .view_type = .@"2d",
        .format = info.format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const view = try vkd.createImageView(device, &view_ci, info.allocator);

    return .{
        .image = image,
        .memory = memory,
        .view = view,
    };
}

fn findMemoryTypeIndex(props: vk.PhysicalDeviceMemoryProperties, type_bits: u32, required: vk.MemoryPropertyFlags) !u32 {
    var i: u32 = 0;
    while (i < props.memory_type_count) : (i += 1) {
        const bit_set = ((type_bits >> @intCast(i)) & 1) == 1;
        if (!bit_set) continue;

        const have = props.memory_types[i].property_flags.toInt();
        const want = required.toInt();
        if ((have & want) == want) return i;
    }
    return error.NoSuitableMemoryType;
}
