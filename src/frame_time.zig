const std = @import("std");

/// FrameTimer – simple monotonic frame delta tracker.
///
/// - Uses std.time.nanoTimestamp() (monotonic, not wall clock).
/// - Returns dt in seconds as f32.
/// - Clamps dt to `max_dt` to avoid huge physics steps after long pauses.
///
/// This is intentionally engine-agnostic (no GLFW / Vulkan deps) so it can
/// be reused across PC & VR runtimes.
pub const FrameTimer = struct {
    last_ns: i128,
    max_dt: f32,

    /// Initialize with a maximum delta in seconds.
    /// Example: 0.25 = clamp dt to 250ms per frame.
    pub fn init(max_dt: f32) FrameTimer {
        return .{
            .last_ns = std.time.nanoTimestamp(),
            .max_dt = max_dt,
        };
    }

    /// Compute the time since the previous tick, in seconds.
    /// - Never returns negative.
    /// - Clamped to `max_dt`.
    pub fn tick(self: *FrameTimer) f32 {
        const now = std.time.nanoTimestamp();
        const dt_ns: i128 = now - self.last_ns;
        self.last_ns = now;

        if (dt_ns <= 0) return 0.0;

        const dt_s_f64 = @as(f64, @floatFromInt(dt_ns)) /
            @as(f64, std.time.ns_per_s);

        var dt_f32 = @as(f32, @floatCast(dt_s_f64));
        if (dt_f32 > self.max_dt) dt_f32 = self.max_dt;

        return dt_f32;
    }
};

test "FrameTimer: non-negative dt and clamp" {
    var timer = FrameTimer.init(0.5);

    const dt1 = timer.tick();
    try std.testing.expect(dt1 >= 0.0);
    try std.testing.expect(dt1 <= 0.5);

    const dt2 = timer.tick();
    try std.testing.expect(dt2 >= 0.0);
    try std.testing.expect(dt2 <= 0.5);
}

test "FrameTimer: refAllDecls" {
    std.testing.refAllDecls(@This());
}
