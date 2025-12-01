const std = @import("std");
const FrameTimer = @import("frame_time").FrameTimer;

test "integration: FrameTimer emits fps in ~1s window" {
    var ft = FrameTimer.init(0, 1000);
    var ms: i64 = 0;
    var saw = false;
    while (ms < 1200) : (ms += 16) {
        const t = ft.tick(ms);
        if (t.fps_updated) {
            saw = true;
            try std.testing.expect(t.fps > 40 and t.fps < 80);
        }
    }
    try std.testing.expect(saw);
}
