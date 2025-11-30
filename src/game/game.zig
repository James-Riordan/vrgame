const std = @import("std");

/// High-level input state, decoupled from GLFW.
/// main.zig is responsible for mapping key presses to this struct.
pub const InputState = struct {
    move_forward: bool = false,
    move_backward: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    quit: bool = false,
};

/// Core game state:
/// - A player-controlled hero (WASD)
/// - An orbiting enemy
/// - Simple collision + score + hit-flash
pub const Game = struct {
    /// Hero position in a simple 2D "world" space.
    player_x: f32 = 0.0,
    player_y: f32 = 0.0,

    /// Enemy position + internal orbit phase.
    enemy_x: f32 = 0.6,
    enemy_y: f32 = 0.0,
    enemy_angle: f32 = 0.0,

    /// Number of times the hero has "tagged" the enemy.
    score: u32 = 0,

    /// Used to detect rising edge of collisions so we don't
    /// increment score every frame while overlapping.
    _was_colliding: bool = false,

    /// Time remaining for the hit-flash effect (seconds).
    hit_flash_timer: f32 = 0.0,

    const move_speed: f32 = 3.5;
    const enemy_radius: f32 = 0.75;
    const collision_radius: f32 = 0.25;
    const tau: f32 = 6.28318530717958647692;

    /// Simple "world bounds" so the hero can't leave forever.
    const world_half_width: f32 = 2.0;
    const world_half_height: f32 = 1.5;

    /// Duration of the hit-flash in seconds.
    const hit_flash_duration: f32 = 0.25;

    pub fn init() Game {
        return .{};
    }

    /// Advance the game by dt seconds with a given input snapshot.
    pub fn update(self: *Game, dt: f32, input: InputState) void {
        // ── Hero movement (WASD) ─────────────────────────────────────────
        if (input.move_forward) self.player_y += move_speed * dt;
        if (input.move_backward) self.player_y -= move_speed * dt;
        if (input.move_left) self.player_x -= move_speed * dt;
        if (input.move_right) self.player_x += move_speed * dt;

        // Clamp hero to a simple axis-aligned world box.
        if (self.player_x > world_half_width) self.player_x = world_half_width;
        if (self.player_x < -world_half_width) self.player_x = -world_half_width;
        if (self.player_y > world_half_height) self.player_y = world_half_height;
        if (self.player_y < -world_half_height) self.player_y = -world_half_height;

        // ── Enemy orbit ──────────────────────────────────────────────────
        self.enemy_angle += 0.7 * dt;
        if (self.enemy_angle > tau) {
            self.enemy_angle -= tau;
        }

        const math = std.math;
        self.enemy_x = math.cos(self.enemy_angle) * enemy_radius;
        self.enemy_y = math.sin(self.enemy_angle) * enemy_radius;

        // ── Collision + score (edge-triggered) ───────────────────────────
        const hit_now = self.isColliding();
        if (hit_now and !self._was_colliding) {
            self.score += 1;
            self.hit_flash_timer = hit_flash_duration;
        }
        self._was_colliding = hit_now;

        // ── Hit-flash timer decay ────────────────────────────────────────
        if (self.hit_flash_timer > 0.0) {
            self.hit_flash_timer -= dt;
            if (self.hit_flash_timer < 0.0) self.hit_flash_timer = 0.0;
        }
    }

    /// Hero ↔ enemy proximity in "world" space.
    pub fn isColliding(self: *const Game) bool {
        const dx = self.player_x - self.enemy_x;
        const dy = self.player_y - self.enemy_y;
        const dist2 = dx * dx + dy * dy;
        const radius2 = collision_radius * collision_radius;
        return dist2 <= radius2;
    }

    /// Returns a 0–1 hit-flash intensity based on remaining flash time.
    pub fn hitFlashIntensity(self: *const Game) f32 {
        if (self.hit_flash_timer <= 0.0) return 0.0;
        return self.hit_flash_timer / hit_flash_duration;
    }

    pub fn heroPosition(self: *const Game) [2]f32 {
        return .{ self.player_x, self.player_y };
    }

    pub fn enemyPosition(self: *const Game) [2]f32 {
        return .{ self.enemy_x, self.enemy_y };
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

test "Game collision detection basic" {
    var game = Game.init();

    // Hero at origin.
    game.player_x = 0.0;
    game.player_y = 0.0;

    // Far away enemy → no collision.
    game.enemy_x = 1.0;
    game.enemy_y = 0.0;
    try std.testing.expect(!game.isColliding());

    // Bring enemy close enough to collide.
    game.enemy_x = 0.1;
    game.enemy_y = 0.0;
    try std.testing.expect(game.isColliding());
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
