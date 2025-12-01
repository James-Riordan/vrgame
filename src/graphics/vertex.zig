const std = @import("std");
const vk = @import("vulkan");

pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    color: [3]f32,

    // Binding layout (binding 0)
    pub const binding_description: vk.VertexInputBindingDescription = .{
        .binding = 0,
        .stride = @as(u32, @intCast(@sizeOf(Vertex))),
        .input_rate = .vertex,
    };

    // Attribute layouts (locations 0..2)
    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @as(u32, @intCast(@offsetOf(Vertex, "pos"))) },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @as(u32, @intCast(@offsetOf(Vertex, "normal"))) },
        .{ .location = 2, .binding = 0, .format = .r32g32b32_sfloat, .offset = @as(u32, @intCast(@offsetOf(Vertex, "color"))) },
    };
};

test "Vertex layout sanity" {
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Vertex, "pos"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Vertex, "normal"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Vertex, "color"));
}
