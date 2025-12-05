const std = @import("std");

// Small local math helpers (kept private to the module)
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
fn len3(v: [3]f32) f32 {
    return @sqrt(dot3(v, v));
}
fn norm3(v: [3]f32) [3]f32 {
    const L = len3(v);
    return if (L > 0) .{ v[0] / L, v[1] / L, v[2] / L } else .{ 0, 0, 0 };
}

fn mul4x4(a: [16]f32, b: [16]f32) [16]f32 {
    var r: [16]f32 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            r[i + 4 * j] =
                a[0 + 4 * j] * b[i + 0] +
                a[1 + 4 * j] * b[i + 4] +
                a[2 + 4 * j] * b[i + 8] +
                a[3 + 4 * j] * b[i + 12];
        }
    }
    return r;
}

fn mulPoint4x4(m: [16]f32, p: [4]f32) [4]f32 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12] * p[3],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13] * p[3],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14] * p[3],
        m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15] * p[3],
    };
}

fn invert4x4(m: [16]f32) ?[16]f32 {
    var inv: [16]f32 = undefined;

    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    var det: f32 = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (@abs(det) < 1e-8) return null;
    det = 1.0 / det;
    var i: usize = 0;
    while (i < 16) : (i += 1) inv[i] *= det;
    return inv;
}

fn unprojectCenter(vp: [16]f32, z_clip_zo: f32) ?[3]f32 {
    const inv = invert4x4(vp) orelse return null;
    const p = mulPoint4x4(inv, .{ 0.0, 0.0, z_clip_zo, 1.0 });
    if (@abs(p[3]) < 1e-8) return null;
    return .{ p[0] / p[3], p[1] / p[3], p[2] / p[3] };
}
fn centerRayFromVP(vp: [16]f32) ?struct { origin: [3]f32, dir: [3]f32 } {
    const p0 = unprojectCenter(vp, 0.0) orelse return null;
    const p1 = unprojectCenter(vp, 1.0) orelse return null;
    return .{ .origin = p0, .dir = norm3(sub3(p1, p0)) };
}
fn hitRayY(origin: [3]f32, dir: [3]f32, y: f32) ?[3]f32 {
    if (@abs(dir[1]) < 1e-6) return null;
    const t = (y - origin[1]) / dir[1];
    if (t <= 0.0) return null;
    return add3(origin, scale3(dir, t));
}

fn lookAtRH(eye: [3]f32, target: [3]f32, up: [3]f32) [16]f32 {
    const fwd = norm3(sub3(target, eye));
    const right = norm3(.{ fwd[1] * up[2] - fwd[2] * up[1], fwd[2] * up[0] - fwd[0] * up[2], fwd[0] * up[1] - fwd[1] * up[0] });
    const up2 = .{ right[1] * fwd[2] - right[2] * fwd[1], right[2] * fwd[0] - right[0] * fwd[2], right[0] * fwd[1] - right[1] * fwd[0] };
    return .{
        right[0],          up2[0],          -fwd[0],        0,
        right[1],          up2[1],          -fwd[1],        0,
        right[2],          up2[2],          -fwd[2],        0,
        -dot3(right, eye), -dot3(up2, eye), dot3(fwd, eye), 1,
    };
}

fn perspectiveRH_ZO(fov: f32, aspect: f32, zn: f32, zf: f32) [16]f32 {
    const f = 1.0 / @tan(fov * 0.5);
    return .{
        f / aspect, 0, 0,                     0,
        0,          f, 0,                     0,
        0,          0, zf / (zn - zf),        -1,
        0,          0, (zf * zn) / (zn - zf), 0,
    };
}

pub const OrbitConfig = struct {
    yaw_sens: f32,
    pitch_sens: f32,
    dolly_wheel: f32,
    min_radius: f32,
    max_radius: f32,
    max_pitch_deg: f32,
};

pub const OrbitState = struct {
    target: [3]f32 = .{ 0.0, 0.5, 0.0 },
    radius: f32 = 6.0,
    yaw: f32 = 0.0,
    pitch: f32 = -0.15,

    /// Pick a target from the current VP by ray-casting to y=0 (ground).
    pub fn pickTargetFromVP(self: *OrbitState, vp: [16]f32, cfg: OrbitConfig) void {
        if (centerRayFromVP(vp)) |ray| {
            const hit = hitRayY(ray.origin, ray.dir, 0.0) orelse add3(ray.origin, scale3(ray.dir, 4.0));
            self.target = hit;
            const seed_r = @max(0.25, len3(sub3(hit, ray.origin)));
            self.radius = std.math.clamp(seed_r, cfg.min_radius, cfg.max_radius);
            self.yaw = std.math.atan2(ray.dir[0], ray.dir[2]);
            self.pitch = std.math.asin(std.math.clamp(ray.dir[1], -1.0, 1.0));
        }
    }

    /// Apply input deltas for one frame (RMB drag + wheel).
    pub fn update(self: *OrbitState, look_dx: f32, look_dy: f32, rmb_down: bool, wheel_delta: f64, cfg: OrbitConfig) void {
        if (rmb_down) {
            self.yaw += look_dx * cfg.yaw_sens;
            self.pitch -= look_dy * cfg.pitch_sens; // mouse up → look up
            const maxp = @as(f32, @floatCast(std.math.degreesToRadians(cfg.max_pitch_deg)));
            self.pitch = std.math.clamp(self.pitch, -maxp, maxp);
        }
        if (wheel_delta != 0.0) {
            const f = std.math.pow(f32, cfg.dolly_wheel, @floatCast(-wheel_delta));
            self.radius = std.math.clamp(self.radius * f, cfg.min_radius, cfg.max_radius);
        }
    }

    /// Produce view, proj, vp and eye position
    pub fn matrices(self: *const OrbitState, aspect: f32, fov_deg: f32, zn: f32, zf: f32, y_flip_proj: bool) struct { view: [16]f32, proj: [16]f32, vp: [16]f32, eye: [3]f32 } {
        const cp = @cos(self.pitch);
        const sp = @sin(self.pitch);
        const cy = @cos(self.yaw);
        const sy = @sin(self.yaw);

        const dir = .{ cp * sy, sp, cp * cy };
        const eye = add3(self.target, scale3(dir, -self.radius));

        const view = lookAtRH(eye, self.target, .{ 0, 1, 0 });
        var proj = perspectiveRH_ZO(@floatCast(std.math.degreesToRadians(fov_deg)), aspect, zn, zf);
        if (y_flip_proj) proj[5] = -proj[5];

        return .{ .view = view, .proj = proj, .vp = mul4x4(proj, view), .eye = eye };
    }
};
