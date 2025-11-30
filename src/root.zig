const std = @import("std");

// Public facade for the vrgame library.
// This lets external code (and tests) do:
//
//   const vr = @import("vrgame");
//   const Game = vr.game.Game;
//   const GraphicsContext = vr.graphics.GraphicsContext;
//
pub const graphics = struct {
    pub const GraphicsContext = @import("graphics_context").GraphicsContext;
    pub const Swapchain = @import("swapchain").Swapchain;
    pub const Vertex = @import("vertex").Vertex;
};

pub const game = struct {
    pub const Game = @import("game").Game;
    pub const InputState = @import("game").InputState;

    pub const FrameTimer = @import("frame_time").FrameTimer;
    pub const TickResult = @import("frame_time").TickResult;
};

test "refAllDecls(vrgame root)" {
    std.testing.refAllDecls(@This());
}
