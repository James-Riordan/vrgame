const std = @import("std");
const glfw = @import("glfw");

test "glfw wrapper: essential symbols present" {
    // We don’t actually open a window in integration tests — just ensure API is wired.
    try std.testing.expect(@hasDecl(glfw, "init"));
    try std.testing.expect(@hasDecl(glfw, "terminate"));
    try std.testing.expect(@hasDecl(glfw, "getVersion"));
}
