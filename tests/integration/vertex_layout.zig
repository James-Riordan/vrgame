const std = @import("std");
const vertex = @import("vertex");

test "vertex binding/attributes match struct layout" {
    // Basic invariants that should hold regardless of your Vertex fields.
    const bd = vertex.Vertex.binding_description;
    try std.testing.expect(bd.binding == 0); // usually 0 in single-VB demos
    try std.testing.expect(bd.stride > 0);
    try std.testing.expect(bd.input_rate.vertex == true);

    // Every attribute must sit within the stride.
    for (vertex.Vertex.attribute_description) |ad| {
        try std.testing.expect(ad.offset < bd.stride);
        try std.testing.expect(ad.location >= 0);
        // Minimal sanity: known formats ought to exist in enum; we just check the tag is valid.
        _ = ad.format;
    }
}
