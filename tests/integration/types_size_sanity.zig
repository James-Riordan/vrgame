const std = @import("std");
const math3d = @import("math3d");
const vertex = @import("vertex");

test "integration: math3d sizes and alignments" {
    try std.testing.expect(@sizeOf(math3d.Vec3) == 12);
    try std.testing.expect(@alignOf(math3d.Vec3) == 4);

    try std.testing.expect(@sizeOf(math3d.Mat4) == 64);
    try std.testing.expect(@alignOf(math3d.Mat4) == 4);
}

test "integration: vertex stride/attributes sane" {
    const bd = vertex.Vertex.binding_description;
    try std.testing.expect(bd.stride > 0);
    try std.testing.expect(bd.stride % 4 == 0);

    // Allow user-defined padding; just assert struct fits within stride.
    try std.testing.expect(bd.stride >= @sizeOf(vertex.Vertex));

    var prev_off: u32 = 0;
    for (vertex.Vertex.attribute_description, 0..) |ad, i| {
        try std.testing.expect(ad.offset < bd.stride);
        if (i != 0) try std.testing.expect(ad.offset >= prev_off);
        prev_off = ad.offset;
        _ = ad.format; // existence
        _ = ad.location;
        _ = ad.binding;
    }
}
