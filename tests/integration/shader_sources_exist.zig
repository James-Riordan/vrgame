const std = @import("std");

fn exists(path: []const u8) bool {
    _ = std.fs.cwd().statFile(path) catch return false;
    return true;
}

test "shader sources exist" {
    try std.testing.expect(exists("shaders/triangle.vert"));
    try std.testing.expect(exists("shaders/triangle.frag"));
}
