const std = @import("std");
const Vertex = @import("vertex").Vertex;

test "integration: vertex binding/attributes match struct layout" {
    try std.testing.expectEqual(@sizeOf(Vertex), Vertex.binding_description.stride);
    try std.testing.expectEqual(@as(u32, 0), Vertex.attribute_description[0].location);
    try std.testing.expectEqual(@as(u32, 1), Vertex.attribute_description[1].location);
    try std.testing.expect(@offsetOf(Vertex, "pos") == 0);
    try std.testing.expect(@offsetOf(Vertex, "color") == 12);
}
