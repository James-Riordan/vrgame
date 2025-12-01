const std = @import("std");
const glfw = @import("glfw");
const vk = @import("vulkan");

test "integration: glfw + vulkan headers expose core types" {
    try std.testing.expect(@hasDecl(glfw, "Window"));
    try std.testing.expect(@hasDecl(glfw, "init"));
    try std.testing.expect(@hasDecl(vk, "Instance"));
    try std.testing.expect(@hasDecl(vk, "Device"));
}
