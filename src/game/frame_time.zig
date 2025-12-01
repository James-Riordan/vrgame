const std = @import("std");

/// Result of a single tick of the frame timer.
pub const TickResult = struct {
    /// Delta time in seconds since the previous frame.
    /// Will be 0 when the timestamp did not advance.
    dt: f64,
    /// True when an FPS sample window completed on this tick.
    fps_updated: bool,
    /// Latest FPS value. Meaningful when `fps_updated == true`,
    /// otherwise the most recent sample.
    fps: f64,
};

/// Simple, robust frame timer based on millisecond timestamps.
/// Designed to be trivial to reuse in ZGE / Zigadel demos.
pub const FrameTimer = struct {
    /// Last timestamp in milliseconds (monotonic assumption).
    last_ms: i64,
    /// Accumulated milliseconds in the current FPS window.
    accum_ms: i64 = 0,
    /// Frames counted in the current FPS window.
    frames_in_window: u32 = 0,
    /// How many milliseconds per FPS sample (usually 1000 = 1s).
    fps_sample_interval_ms: i64,
    /// Last computed FPS value.
    current_fps: f64 = 0.0,

    /// Initialize the timer with a starting millisecond timestamp and sample window.
    pub fn init(start_ms: i64, sample_interval_ms: i64) FrameTimer {
        return .{
            .last_ms = start_ms,
            .accum_ms = 0,
            .frames_in_window = 0,
            .fps_sample_interval_ms = if (sample_interval_ms > 0) sample_interval_ms else 1000,
            .current_fps = 0.0,
        };
    }

    /// Advance the timer with a new millisecond timestamp.
    /// Returns dt (seconds) and optionally a new FPS sample.
    pub fn tick(self: *FrameTimer, now_ms: i64) TickResult {
        // Non-monotonic clock or duplicate timestamp: ignore.
        if (now_ms <= self.last_ms) {
            return .{
                .dt = 0.0,
                .fps_updated = false,
                .fps = self.current_fps,
            };
        }

        const dt_ms = now_ms - self.last_ms;
        self.last_ms = now_ms;

        self.accum_ms += dt_ms;
        self.frames_in_window += 1;

        var fps_updated = false;

        if (self.accum_ms >= self.fps_sample_interval_ms and self.fps_sample_interval_ms > 0) {
            const window_s = @as(f64, @floatFromInt(self.accum_ms)) / 1000.0;
            if (window_s > 0.0) {
                self.current_fps =
                    @as(f64, @floatFromInt(self.frames_in_window)) / window_s;
            } else {
                self.current_fps = 0.0;
            }

            self.accum_ms = 0;
            self.frames_in_window = 0;
            fps_updated = true;
        }

        const dt_s = @as(f64, @floatFromInt(dt_ms)) / 1000.0;

        return .{
            .dt = dt_s,
            .fps_updated = fps_updated,
            .fps = self.current_fps,
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "FrameTimer basic progression and FPS window" {
    var timer = FrameTimer.init(0, 1000);

    // 9 frames at 100 ms → 900 ms total, no FPS sample yet.
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const now_ms: i64 = @intCast((i + 1) * 100); // 100, 200, ..., 900
        const res = timer.tick(now_ms);
        try std.testing.expect(res.dt > 0.0);
        try std.testing.expect(!res.fps_updated);
    }

    // 10th frame at 1000 ms pushes us over the 1s window:
    const res10 = timer.tick(1000);
    try std.testing.expect(res10.fps_updated);

    // 10 frames over ~1.0 seconds → ~10 FPS.
    const expected_fps: f64 = 10.0;
    try std.testing.expectApproxEqAbs(expected_fps, res10.fps, 0.0001);
}

test "FrameTimer handles non-monotonic timestamps" {
    var timer = FrameTimer.init(1000, 1000);

    const r1 = timer.tick(1010);
    try std.testing.expect(r1.dt > 0.0);

    // Time goes backwards: dt should be 0, and state unchanged.
    const r2 = timer.tick(900);
    try std.testing.expectEqual(@as(f64, 0.0), r2.dt);
    try std.testing.expect(!r2.fps_updated);
    try std.testing.expectEqual(r1.fps, r2.fps);
}

test "FrameTimer basic dt and fps windowing" {
    var ft = FrameTimer.init(0, 1000); // 1s FPS window
    var t = ft.tick(16);
    try std.testing.expect(t.dt > 0);
    // simulate ~16ms/frame over ~1s => ~60 fps
    var ms: i64 = 16;
    var last: i64 = 16;
    var fps_seen = false;
    while (ms < 1000) : (ms += 16) {
        t = ft.tick(ms);
        last = ms;
        if (t.fps_updated) {
            fps_seen = true;
            try std.testing.expect(t.fps > 40 and t.fps < 80);
        }
    }
    // one more tick should definitely finalize a window
    t = ft.tick(last + 16);
    try std.testing.expect(t.fps_updated or fps_seen);
}

// test "refAllDecls(frame_time)" {
//     std.testing.refAllDecls(@This());
// }
