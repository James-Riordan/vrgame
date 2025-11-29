const std = @import("std");

/// High-level input state for the game, independent of GLFW/OpenXR.
/// This is the layer you plug keyboard/VR input into.
pub const InputState = struct {
    move_forward: bool = false,
    move_backward: bool = false,
    move_left: bool = false,
    move_right: bool = false,
};

/// Minimal game-core state for the demo: a single player with a 2D position.
pub const Game = struct {
    player_x: f32,
    player_y: f32,
    player_speed: f32,

    pub fn init() Game {
        return Game{
            .player_x = 0.0,
            .player_y = 0.0,
            .player_speed = 3.5, // units per second
        };
    }

    /// Advance the game state by `dt` seconds, given the current input.
    pub fn update(self: *Game, dt: f32, input: InputState) void {
        var dir_x: f32 = 0.0;
        var dir_y: f32 = 0.0;

        if (input.move_forward) dir_y += 1.0;
        if (input.move_backward) dir_y -= 1.0;
        if (input.move_right) dir_x += 1.0;
        if (input.move_left) dir_x -= 1.0;

        const len_sq = dir_x * dir_x + dir_y * dir_y;
        if (len_sq == 0.0) return;

        // Zig 0.16 builtin: @sqrt(value) with inferred type.
        const len = @sqrt(len_sq);
        if (len == 0.0) return;

        dir_x /= len;
        dir_y /= len;

        self.player_x += dir_x * self.player_speed * dt;
        self.player_y += dir_y * self.player_speed * dt;
    }
};

test "Game basic movement with WASD-style input" {
    var game = Game.init();

    // No movement when no input.
    game.update(1.0, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), game.player_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), game.player_y, 0.0001);

    // Move forward for 1 second.
    game.update(1.0, .{ .move_forward = true });
    try std.testing.expect(game.player_y > 0.0);

    const y_after_forward = game.player_y;

    // Move backward for 0.5 seconds; should reduce y a bit.
    game.update(0.5, .{ .move_backward = true });
    try std.testing.expect(game.player_y < y_after_forward);

    // Move right for 2 seconds; x should increase.
    game.update(2.0, .{ .move_right = true });
    try std.testing.expect(game.player_x > 0.0);
}
