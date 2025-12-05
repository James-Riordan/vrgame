const std = @import("std");
const glfw = @import("glfw");

pub const InputSample = struct {
    dt: f32,
    size: struct { w: u32, h: u32, aspect: f32 },
    keys: struct {
        w: bool,
        a: bool,
        s: bool,
        d: bool,
        space: bool,
        ctrl: bool,
        shift: bool,
        esc: bool,
        r: bool,
    },
    mouse: struct {
        pos: [2]f64,
        delta: [2]f32,
        wheel: f32,
        lmb: bool,
        rmb: bool,
        mmb: bool,
        alt: bool,
        ctrl: bool,
        shift: bool,
    },
};

const State = struct {
    pub var have_prev_pos: bool = false;
    pub var prev_pos: [2]f64 = .{ 0, 0 };
    pub var wheel_accum: f64 = 0.0;
};

fn onScroll(_: ?*glfw.Window, _: f64, yoff: f64) callconv(.c) void {
    State.wheel_accum += yoff;
}

pub fn attach(window: *glfw.Window) void {
    _ = glfw.setScrollCallback(window, onScroll);
}

pub fn sample(window: *glfw.Window, dt: f32) InputSample {
    const fb = glfw.getFramebufferSize(window);
    const aspect: f32 = if (fb.height > 0) @as(f32, @floatFromInt(fb.width)) / @as(f32, @floatFromInt(fb.height)) else 1.0;

    const cur = glfw.getCursorPos(window);
    if (!State.have_prev_pos) {
        State.have_prev_pos = true;
        State.prev_pos = .{ cur.x, cur.y };
    }
    const dx = @as(f32, @floatCast(cur.x - State.prev_pos[0]));
    const dy = @as(f32, @floatCast(cur.y - State.prev_pos[1]));
    State.prev_pos = .{ cur.x, cur.y };

    const shift = isDown(window, glfw.c.GLFW_KEY_LEFT_SHIFT) or isDown(window, glfw.c.GLFW_KEY_RIGHT_SHIFT);
    const ctrl = isDown(window, glfw.c.GLFW_KEY_LEFT_CONTROL) or isDown(window, glfw.c.GLFW_KEY_RIGHT_CONTROL);
    const alt = isDown(window, glfw.c.GLFW_KEY_LEFT_ALT) or isDown(window, glfw.c.GLFW_KEY_RIGHT_ALT);

    const wheel: f32 = @floatCast(State.wheel_accum);
    State.wheel_accum = 0.0;

    return .{
        .dt = dt,
        .size = .{ .w = @intCast(@max(fb.width, 1)), .h = @intCast(@max(fb.height, 1)), .aspect = aspect },
        .keys = .{
            .w = isHeld(window, glfw.c.GLFW_KEY_W),
            .a = isHeld(window, glfw.c.GLFW_KEY_A),
            .s = isHeld(window, glfw.c.GLFW_KEY_S),
            .d = isHeld(window, glfw.c.GLFW_KEY_D),
            .space = isHeld(window, glfw.c.GLFW_KEY_SPACE),
            .ctrl = ctrl,
            .shift = shift,
            .esc = isHeld(window, glfw.c.GLFW_KEY_ESCAPE),
            .r = isHeld(window, glfw.c.GLFW_KEY_R),
        },
        .mouse = .{
            .pos = .{ cur.x, cur.y },
            .delta = .{ dx, dy },
            .wheel = wheel,
            .lmb = isDown(window, glfw.c.GLFW_MOUSE_BUTTON_LEFT),
            .rmb = isDown(window, glfw.c.GLFW_MOUSE_BUTTON_RIGHT),
            .mmb = isDown(window, glfw.c.GLFW_MOUSE_BUTTON_MIDDLE),
            .alt = alt,
            .ctrl = ctrl,
            .shift = shift,
        },
    };
}

fn isDown(window: *glfw.Window, key_or_button: c_int) bool {
    const state = glfw.getKey(window, key_or_button);
    if (state == glfw.c.GLFW_PRESS) return true;
    if (state == glfw.c.GLFW_REPEAT) return true;
    return glfw.getMouseButton(window, key_or_button) == glfw.c.GLFW_PRESS;
}
fn isHeld(window: *glfw.Window, key: c_int) bool {
    const st = glfw.getKey(window, key);
    return st == glfw.c.GLFW_PRESS or st == glfw.c.GLFW_REPEAT;
}
