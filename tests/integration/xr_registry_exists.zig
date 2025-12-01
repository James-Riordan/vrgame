const std = @import("std");

test "OpenXR registry (xr.xml) is present in ./registry" {
    _ = try std.fs.cwd().statFile("registry/xr.xml");
}
