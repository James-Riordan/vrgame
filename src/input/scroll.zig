const glfw = @import("glfw");

pub const Scroll = struct {
    var dy: f64 = 0.0;

    pub fn onScroll(_: ?*glfw.Window, _: f64, yoff: f64) callconv(.c) void {
        dy += yoff;
    }

    /// Returns and resets the accumulated wheel delta.
    pub fn consume() f64 {
        const v = dy;
        dy = 0.0;
        return v;
    }
};
