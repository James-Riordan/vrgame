const std = @import("std");
const AppCfg = @import("../app/config.zig");
const Inp = @import("../input/input.zig");

pub const Mode = enum { fps, orbit, xr };

pub const Params = struct {
    style: AppCfg.CameraStyle,
    fov_deg: f32,
    znear: f32,
    zfar: f32,

    // fps
    fps_mouse_sens: f32,
    fps_invert_y: bool,
    fps_base_speed: f32,
    fps_sprint_mult: f32,
    fps_require_rmb: bool,

    // orbit
    orbit_yaw_sens: f32,
    orbit_pitch_sens: f32,
    orbit_pan_sens: f32,
    orbit_dolly_wheel: f32,
    orbit_dolly_drag: f32,
    orbit_min_radius: f32,
    orbit_max_radius: f32,
    max_pitch_deg: f32,
};

pub const Rig = struct {
    mode: Mode,
    vp: [16]f32 = identity(),

    // fps
    pos: [3]f32 = .{ 0.0, 1.7, 4.0 },
    yaw: f32 = 0.0, // radians
    pitch: f32 = 0.0, // radians

    // orbit
    target: [3]f32 = .{ 0.0, 0.5, 0.0 },
    radius: f32 = 6.0,
    oyaw: f32 = 0.0,
    opitch: f32 = -0.15,

    cfg: Params,

    pub fn init(cfg: Params) Rig {
        return .{
            .mode = switch (cfg.style) {
                .fps => .fps,
                .blender_orbit => .orbit,
            },
            .cfg = cfg,
        };
    }

    pub fn setMode(self: *Rig, m: Mode) void {
        self.mode = m;
    }

    pub fn update(self: *Rig, input: Inp.InputSample) void {
        switch (self.mode) {
            .fps => self.updateFps(input),
            .orbit => self.updateOrbit(input),
            .xr => self.updateXR(input),
        }
        const fov = std.math.degreesToRadians(self.cfg.fov_deg);
        const proj = perspectiveRH_ZO(fov, input.size.aspect, self.cfg.znear, self.cfg.zfar);
        const view = self.viewMatrix();
        self.vp = mul4x4(proj, view);
    }

    pub fn viewProj(self: *const Rig) [16]f32 {
        return self.vp;
    }

    fn updateFps(self: *Rig, input: Inp.InputSample) void {
        const msens = self.cfg.fps_mouse_sens; // deg/px-like, scaled
        const use_look = if (self.cfg.fps_require_rmb) input.mouse.rmb else true;

        if (use_look) {
            const sx = input.mouse.delta[0] * (msens * 0.0174533); // to rad
            const sy = input.mouse.delta[1] * (msens * 0.0174533);
            self.yaw += sx;
            self.pitch += if (self.cfg.fps_invert_y) sy else -sy;
            const limit = std.math.degreesToRadians(self.cfg.max_pitch_deg - 0.001);
            self.pitch = std.math.clamp(self.pitch, -limit, limit);
        }

        // movement (WASD + Space/Ctrl)
        var vel: [3]f32 = .{ 0, 0, 0 };
        const speed = self.cfg.fps_base_speed * (if (input.keys.shift) self.cfg.fps_sprint_mult else 1.0);
        const dt = input.dt;

        const cy = std.math.cos(self.yaw);
        const sy = std.math.sin(self.yaw);
        const forward = normalize3(.{ sy, 0, cy });
        const right = normalize3(cross3(forward, .{ 0, 1, 0 }));

        if (input.keys.w) vel = add3(vel, forward);
        if (input.keys.s) vel = sub3(vel, forward);
        if (input.keys.d) vel = add3(vel, right);
        if (input.keys.a) vel = sub3(vel, right);
        if (input.keys.space) vel = add3(vel, .{ 0, 1, 0 });
        if (input.keys.ctrl) vel = sub3(vel, .{ 0, 1, 0 });

        if (length3(vel) > 0.0) {
            self.pos = add3(self.pos, scale3(normalize3(vel), speed * dt));
        }
    }

    fn updateOrbit(self: *Rig, input: Inp.InputSample) void {
        // wheel dolly
        if (input.mouse.wheel != 0) {
            const s = std.math.pow(f32, self.cfg.orbit_dolly_wheel, -input.mouse.wheel);
            self.radius = std.math.clamp(self.radius * s, self.cfg.orbit_min_radius, self.cfg.orbit_max_radius);
        }

        // Ctrl+RMB drag -> dolly
        if (input.mouse.rmb and input.mouse.ctrl) {
            const factor = 1.0 + (input.mouse.delta[1] * self.cfg.orbit_dolly_drag);
            self.radius = std.math.clamp(self.radius * std.math.max(0.01, factor), self.cfg.orbit_min_radius, self.cfg.orbit_max_radius);
        }
        // Shift+RMB drag -> pan
        else if (input.mouse.rmb and input.mouse.shift) {
            const per_px = (2.0 * self.radius * std.math.tan(std.math.degreesToRadians(self.cfg.fov_deg) * 0.5)) / @as(f32, @floatFromInt(input.size.h));
            const cp = std.math.cos(self.opitch);
            const sp = std.math.sin(self.opitch);
            const cy = std.math.cos(self.oyaw);
            const sy = std.math.sin(self.oyaw);
            const eye_dir = .{ cp * sy, sp, cp * cy };
            const fwd = normalize3(scale3(eye_dir, -1));
            const right = normalize3(cross3(fwd, .{ 0, 1, 0 }));
            const upv = cross3(right, fwd);
            self.target = add3(self.target, add3(scale3(right, -input.mouse.delta[0] * per_px * self.cfg.orbit_pan_sens), scale3(upv, input.mouse.delta[1] * per_px * self.cfg.orbit_pan_sens)));
        }
        // RMB drag -> orbit
        else if (input.mouse.rmb) {
            self.oyaw += input.mouse.delta[0] * self.cfg.orbit_yaw_sens;
            self.opitch += -input.mouse.delta[1] * self.cfg.orbit_pitch_sens;
            const limit = std.math.degreesToRadians(self.cfg.max_pitch_deg - 0.001);
            self.opitch = std.math.clamp(self.opitch, -limit, limit);
        }
    }

    fn updateXR(self: *Rig, _: Inp.InputSample) void {
        // Stub: later, map OpenXR head pose to view; controllers to pan/orbit
        // For now, just reuse FPS view position.
        _ = self;
    }

    fn viewMatrix(self: *const Rig) [16]f32 {
        switch (self.mode) {
            .fps, .xr => {
                // build from pos, yaw, pitch
                const cp = std.math.cos(self.pitch);
                const sp = std.math.sin(self.pitch);
                const cy = std.math.cos(self.yaw);
                const sy = std.math.sin(self.yaw);
                const fwd = normalize3(.{ cp * sy, sp, cp * cy });
                return lookAtRH(self.pos, add3(self.pos, fwd), .{ 0, 1, 0 });
            },
            .orbit => {
                const cp = std.math.cos(self.opitch);
                const sp = std.math.sin(self.opitch);
                const cy = std.math.cos(self.oyaw);
                const sy = std.math.sin(self.oyaw);
                const eye = add3(self.target, .{ self.radius * cp * sy, self.radius * sp, self.radius * cp * cy });
                return lookAtRH(eye, self.target, .{ 0, 1, 0 });
            },
        }
    }
};

// ── small math helpers
fn identity() [16]f32 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}
fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn scale3(a: [3]f32, s: f32) [3]f32 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn length3(a: [3]f32) f32 {
    return std.math.sqrt(dot3(a, a));
}
fn normalize3(a: [3]f32) [3]f32 {
    const l = length3(a);
    return if (l > 0) .{ a[0] / l, a[1] / l, a[2] / l } else .{ 0, 0, 0 };
}
fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn mul4x4(a: [16]f32, b: [16]f32) [16]f32 {
    var r: [16]f32 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            r[i + 4 * j] = a[0 + 4 * j] * b[i + 0] + a[1 + 4 * j] * b[i + 4] + a[2 + 4 * j] * b[i + 8] + a[3 + 4 * j] * b[i + 12];
        }
    }
    return r;
}
fn perspectiveRH_ZO(fov: f32, aspect: f32, zn: f32, zf: f32) [16]f32 {
    const f = 1.0 / std.math.tan(fov * 0.5);
    return .{ f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, zf / (zn - zf), -1, 0, 0, (zf * zn) / (zn - zf), 0 };
}
fn lookAtRH(eye: [3]f32, target: [3]f32, upw: [3]f32) [16]f32 {
    const fwd = normalize3(sub3(target, eye));
    const right = normalize3(cross3(fwd, upw));
    const up = cross3(right, fwd);
    return .{
        right[0],          up[0],          -fwd[0],        0,
        right[1],          up[1],          -fwd[1],        0,
        right[2],          up[2],          -fwd[2],        0,
        -dot3(right, eye), -dot3(up, eye), dot3(fwd, eye), 1,
    };
}
