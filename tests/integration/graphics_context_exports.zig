const std = @import("std");
const gc = @import("graphics_context");

test "graphics_context: core exports exist" {
    try std.testing.expect(@hasDecl(gc, "GraphicsContext"));
    // Keep this flexible; add more once API surface is locked.
}
