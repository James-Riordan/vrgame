const std = @import("std");
const ft = @import("frame_time");

test "integration: frame_time exports FrameTimer (+tick or update)" {
    try std.testing.expect(@hasDecl(ft, "FrameTimer"));

    const has_tick_module = @hasDecl(ft, "tick");
    const has_update_module = @hasDecl(ft, "update");

    const has_tick_type =
        @hasDecl(ft, "FrameTimer") and
        @hasDecl(ft.FrameTimer, "tick");

    const has_update_type =
        @hasDecl(ft, "FrameTimer") and
        @hasDecl(ft.FrameTimer, "update");

    try std.testing.expect(has_tick_module or has_update_module or has_tick_type or has_update_type);
}
