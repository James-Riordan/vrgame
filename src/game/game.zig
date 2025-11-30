const std = @import("std");

/// Engine-agnostic input snapshot for a single frame.
/// Main maps GLFW state into this.
pub const InputState = struct {
    move_forward: bool = false,
    move_backward: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    quit: bool = false,
};

/// Minimal "game core" for the demo.
/// Right now: a single player with a 2D position and constant move speed.
/// Later: hero state, abilities, cooldowns, projectiles, etc.
pub const Game = struct {
    /// Arbitrary units; interpreted by renderer however it wants.
    player_x: f32 = 0.0,
    player_y: f32 = 0.0,

    /// Units per second.
    move_speed: f32 = 3.5,

    pub fn init() Game {
        return .{};
    }

    /// Advance game state by `dt` seconds under the given input.
    pub fn update(self: *Game, dt: f32, input: InputState) void {
        const s = self.move_speed;

        if (input.move_forward) self.player_y += s * dt;
        if (input.move_backward) self.player_y -= s * dt;
        if (input.move_left) self.player_x -= s * dt;
        if (input.move_right) self.player_x += s * dt;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Game basic movement with WASD-style input" {
    var g = Game.init();

    // No movement when no input.
    g.update(1.0, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), g.player_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), g.player_y, 0.0001);

    // Move forward for 1 second.
    g.update(1.0, .{ .move_forward = true });
    try std.testing.expect(g.player_y > 0.0);
    const y_after_forward = g.player_y;

    // Move backward for 0.5 seconds; should reduce y a bit.
    g.update(0.5, .{ .move_backward = true });
    try std.testing.expect(g.player_y < y_after_forward);

    // Move right for 2 seconds; x should increase.
    g.update(2.0, .{ .move_right = true });
    try std.testing.expect(g.player_x > 0.0);
}

test "refAllDecls(game)" {
    std.testing.refAllDecls(@This());
}
