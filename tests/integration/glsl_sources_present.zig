const std = @import("std");

test "glsl sources present" {
    // just assert they can be stat'd; discard the Stat value
    _ = try std.fs.cwd().statFile("shaders/triangle.vert");
    _ = try std.fs.cwd().statFile("shaders/triangle.frag");
}
