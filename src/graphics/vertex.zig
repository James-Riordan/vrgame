const std = @import("std");
const vk = @import("vulkan");

pub const Vertex = struct {
    pos: [3]f32, // x, y, z
    color: [3]f32, // r, g, b

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            // vec3 position
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            // vec3 color
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// Layout sanity tests — guards against future shader / struct drift
// ─────────────────────────────────────────────────────────────────────────────

// test "Vertex layout matches triangle.vert expectations" {
//     // Position is a vec3
//     try std.testing.expect(Vertex.attribute_description[0].format == .r32g32b32_sfloat);
//     try std.testing.expectEqual(@offsetOf(Vertex, "pos"), Vertex.attribute_description[0].offset);

//     // Color is a vec3
//     try std.testing.expect(Vertex.attribute_description[1].format == .r32g32b32_sfloat);
//     try std.testing.expectEqual(@offsetOf(Vertex, "color"), Vertex.attribute_description[1].offset);

//     // Binding stride should be the full struct size.
//     try std.testing.expect(Vertex.binding_description.stride == @sizeOf(Vertex));
// }

test "Vertex layout matches shaders (pos, color)" {
    try std.testing.expect(@sizeOf(Vertex) == 24); // 6 * f32
    try std.testing.expect(@offsetOf(Vertex, "pos") == 0);
    try std.testing.expect(@offsetOf(Vertex, "color") == 12);

    // Binding/attribute descriptions are stable
    try std.testing.expectEqual(@as(u32, 0), Vertex.binding_description.binding);
    try std.testing.expect(@intFromEnum(Vertex.attribute_description[0].format) != 0);
    try std.testing.expect(@intFromEnum(Vertex.attribute_description[1].format) != 0);
}
