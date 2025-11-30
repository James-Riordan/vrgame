const std = @import("std");

/// Simple input snapshot. In future this will be expanded for full hero control.
pub const InputState = struct {
    move_forward: bool = false,
    move_backward: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    quit: bool = false,
};

/// Minimal "game core" for the demo.
/// Later this becomes hero/ability state machines, camera, etc.
pub const Game = struct {
    /// For now this is just a placeholder player position in 2D.
    player_x: f32,
    player_y: f32,

    pub fn init() Game {
        return .{
            .player_x = 0.0,
            .player_y = 0.0,
        };
    }

    pub fn update(self: *Game, dt: f32, input: InputState) void {
        const move_speed: f32 = 3.5;

        if (input.move_forward) self.player_y += move_speed * dt;
        if (input.move_backward) self.player_y -= move_speed * dt;
        if (input.move_left) self.player_x -= move_speed * dt;
        if (input.move_right) self.player_x += move_speed * dt;
    }
};

test "Game basic movement with WASD-style input" {
    var game = Game.init();

    game.update(1.0, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), game.player_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), game.player_y, 0.0001);

    game.update(1.0, .{ .move_forward = true });
    try std.testing.expect(game.player_y > 0.0);
    const y_after_forward = game.player_y;

    game.update(0.5, .{ .move_backward = true });
    try std.testing.expect(game.player_y < y_after_forward);

    game.update(2.0, .{ .move_right = true });
    try std.testing.expect(game.player_x > 0.0);
}

test "refAllDecls(game)" {
    std.testing.refAllDecls(@This());
}
