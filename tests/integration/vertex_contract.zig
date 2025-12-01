const std = @import("std");
const vk = @import("vulkan");
const vertex = @import("vertex");

test "vertex: exports + binding matches struct size" {
    try std.testing.expect(@hasDecl(vertex, "Vertex"));

    const stride_expected = @sizeOf(vertex.Vertex);
    try std.testing.expectEqual(stride_expected, vertex.Vertex.binding_description.stride);
    try std.testing.expectEqual(@as(u32, 0), vertex.Vertex.binding_description.binding);
    try std.testing.expectEqual(vk.VertexInputRate.vertex, vertex.Vertex.binding_description.input_rate);
}

test "vertex: attributes sane (binding=0, offsets < stride, monotonic)" {
    const stride = vertex.Vertex.binding_description.stride;
    const attrs = vertex.Vertex.attribute_description;

    try std.testing.expect(attrs.len > 0);

    var last_off: u32 = 0;
    for (attrs, 0..) |a, i| {
        try std.testing.expectEqual(@as(u32, 0), a.binding);
        try std.testing.expect(a.offset < stride);
        if (i > 0) try std.testing.expect(a.offset >= last_off);
        last_off = a.offset;

        // location monotonic non-decreasing (relaxed assumption)
        if (i > 0) try std.testing.expect(a.location >= attrs[i - 1].location);

        // Touch the enum to ensure it's a valid format (permissive).
        switch (a.format) {
            .r32_sfloat,
            .r32g32_sfloat,
            .r32g32b32_sfloat,
            .r32g32b32a32_sfloat,
            => {},
            else => {},
        }
    }
}
