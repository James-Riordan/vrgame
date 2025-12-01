const std = @import("std");
const cam = @import("camera3d");

test "integration: camera3d exports Camera3D & CameraInput" {
    try std.testing.expect(@hasDecl(cam, "Camera3D"));
    try std.testing.expect(@hasDecl(cam, "CameraInput"));
}
