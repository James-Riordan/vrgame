const std = @import("std");
const frame_time = @import("frame_time");

test "frame_time: exports exist" {
    try std.testing.expect(@hasDecl(frame_time, "FrameTimer"));
    // Add deeper checks later once we lock the API surface.
}
