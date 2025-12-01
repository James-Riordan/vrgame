const std = @import("std");

test {
    _ = @import("integration/shaders_exist.zig");
    _ = @import("integration/vertex_layout.zig");
    _ = @import("integration/math3d_sanity.zig");
    _ = @import("integration/frame_timer_window.zig");
}

test {
    std.testing.refAllDecls(@This());
}
