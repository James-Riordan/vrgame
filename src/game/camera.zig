const std = @import("std");

/// Simple 2D camera with an axis-aligned view box:
///   center = (center_x, center_y) in world units
///   view spans [center_x ± half_width], [center_y ± half_height]
/// worldToNdc() maps that box to NDC in [-1, 1]².
pub const Camera2D = struct {
    center_x: f32,
    center_y: f32,
    half_width: f32,
    half_height: f32,

    pub fn init(center_x: f32, center_y: f32, half_width: f32, half_height: f32) Camera2D {
        // Avoid degenerate cameras.
        const eps: f32 = 0.0001;
        return .{
            .center_x = center_x,
            .center_y = center_y,
            .half_width = if (half_width > eps) half_width else eps,
            .half_height = if (half_height > eps) half_height else eps,
        };
    }

    /// Re-center camera on a world position (e.g. hero).
    pub fn setCenter(self: *Camera2D, x: f32, y: f32) void {
        self.center_x = x;
        self.center_y = y;
    }

    /// Map a world-space point to normalized device coords (NDC).
    /// NDC (0,0) is at the camera center; ±1 at view edges.
    pub fn worldToNdc(self: *const Camera2D, world: [2]f32) [2]f32 {
        const nx = (world[0] - self.center_x) / self.half_width;
        const ny = (world[1] - self.center_y) / self.half_height;
        return .{ nx, ny };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Camera2D center and edges" {
    var cam = Camera2D.init(0.0, 0.0, 2.0, 1.0);

    const c = cam.worldToNdc(.{ 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c[1], 0.0001);

    const right = cam.worldToNdc(.{ 2.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), right[0], 0.0001);

    const left = cam.worldToNdc(.{ -2.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), left[0], 0.0001);

    const top = cam.worldToNdc(.{ 0.0, 1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), top[1], 0.0001);

    const bottom = cam.worldToNdc(.{ 0.0, -1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), bottom[1], 0.0001);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
