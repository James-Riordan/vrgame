const std = @import("std");

/// High-level input state for the game.
/// Platform code (GLFW, etc.) should map raw events into this struct.
pub const InputState = struct {
    move_forward: bool = false,
    move_backward: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    quit: bool = false,
};

/// Core game state for the simple demo.
/// For now this is just a 2D "player" position driven by WASD-like input.
pub const Game = struct {
    /// Player position in a simple 2D world-space.
    player_x: f32,
    player_y: f32,

    /// Construct a new game with default starting state.
    pub fn init() Game {
        return .{
            .player_x = 0.0,
            .player_y = 0.0,
        };
    }

    /// Advance game simulation by `dt` seconds given the abstract input state.
    pub fn update(self: *Game, dt: f32, input: InputState) void {
        const move_speed: f32 = 3.5; // units per second (arbitrary units for now)

        if (input.move_forward) self.player_y += move_speed * dt;
        if (input.move_backward) self.player_y -= move_speed * dt;
        if (input.move_left) self.player_x -= move_speed * dt;
        if (input.move_right) self.player_x += move_speed * dt;

        // Later: camera, abilities, projectiles, hero state machine, etc.
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

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

test "refAllDecls (game module)" {
    std.testing.refAllDecls(@This());
}
