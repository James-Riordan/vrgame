const std = @import("std");

test "conformance: shader files have stable names/locations" {
    const A = std.testing.allocator;
    const exe_dir = try std.fs.selfExeDirPathAlloc(A);
    defer A.free(exe_dir);
    for (&[_][]const u8{ "shaders/triangle_vert", "shaders/triangle_frag" }) |rel| {
        const full = try std.fs.path.join(A, &.{ exe_dir, rel });
        defer A.free(full);
        _ = try std.fs.cwd().statFile(full);
    }
}
