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
/// Designed to be trivial to reuse in ZGE.
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
                self.current_fps = @as(f64, @floatFromInt(self.frames_in_window)) / window_s;
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

    // 60 frames at ~16 ms ≈ 960 ms (no FPS sample yet).
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const now_ms: i64 = @intCast((i + 1) * 16);
        const res = timer.tick(now_ms);
        try std.testing.expect(res.dt > 0.0);
        if (i < 59) {
            try std.testing.expect(!res.fps_updated);
        }
    }

    // Push over the 1s window.
    const res2 = timer.tick(2000);
    try std.testing.expect(res2.fps_updated);
    // We're somewhere in the rough 40–80 FPS range.
    try std.testing.expect(res2.fps > 40.0);
    try std.testing.expect(res2.fps < 80.0);
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

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
