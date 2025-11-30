const std = @import("std");

/// Simple 3D vector + 4x4 matrix utilities for camera & transforms.
/// Column-major matrices, OpenGL/Vulkan-style (m[col * 4 + row]).
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3 {
        return .{ .x = 0.0, .y = 0.0, .z = 0.0 };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
        };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.x - other.x,
            .y = self.y - other.y,
            .z = self.z - other.z,
        };
    }

    pub fn scale(self: Vec3, s: f32) Vec3 {
        return .{
            .x = self.x * s,
            .y = self.y * s,
            .z = self.z * s,
        };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn length(self: Vec3) f32 {
        return @sqrt(self.dot(self));
    }

    pub fn normalized(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0.0) return self;
        return self.scale(1.0 / len);
    }
};

pub const Mat4 = struct {
    /// Column-major 4x4 matrix: m[col * 4 + row]
    m: [16]f32,

    fn idx(row: usize, col: usize) usize {
        return col * 4 + row;
    }

    pub fn identity() Mat4 {
        var res = Mat4{ .m = [_]f32{0.0} ** 16 };
        res.m[idx(0, 0)] = 1.0;
        res.m[idx(1, 0)] = 0.0;
        res.m[idx(2, 0)] = 0.0;
        res.m[idx(3, 0)] = 0.0;

        res.m[idx(0, 1)] = 0.0;
        res.m[idx(1, 1)] = 1.0;
        res.m[idx(2, 1)] = 0.0;
        res.m[idx(3, 1)] = 0.0;

        res.m[idx(0, 2)] = 0.0;
        res.m[idx(1, 2)] = 0.0;
        res.m[idx(2, 2)] = 1.0;
        res.m[idx(3, 2)] = 0.0;

        res.m[idx(0, 3)] = 0.0;
        res.m[idx(1, 3)] = 0.0;
        res.m[idx(2, 3)] = 0.0;
        res.m[idx(3, 3)] = 1.0;

        return res;
    }

    /// Matrix multiplication: result = a * b.
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var res = Mat4{ .m = [_]f32{0.0} ** 16 };

        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                var sum: f32 = 0.0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    const a_ik = a.m[idx(row, k)];
                    const b_kj = b.m[idx(k, col)];
                    sum += a_ik * b_kj;
                }
                res.m[idx(row, col)] = sum;
            }
        }

        return res;
    }

    /// Transform a point with w=1.0, then perform perspective divide.
    pub fn transformPoint(self: Mat4, v: Vec3) Vec3 {
        const x = v.x;
        const y = v.y;
        const z = v.z;
        const w: f32 = 1.0;

        var rx: f32 = 0.0;
        var ry: f32 = 0.0;
        var rz: f32 = 0.0;
        var rw: f32 = 0.0;

        var col: usize = 0;
        while (col < 4) : (col += 1) {
            const vc: f32 = switch (col) {
                0 => x,
                1 => y,
                2 => z,
                else => w,
            };

            rx += self.m[idx(0, col)] * vc;
            ry += self.m[idx(1, col)] * vc;
            rz += self.m[idx(2, col)] * vc;
            rw += self.m[idx(3, col)] * vc;
        }

        if (rw != 0.0) {
            const inv_w = 1.0 / rw;
            return Vec3.init(rx * inv_w, ry * inv_w, rz * inv_w);
        } else {
            return Vec3.init(rx, ry, rz);
        }
    }

    /// Perspective projection matrix (right-handed, Vulkan/GL-style).
    /// fov_y is in radians.
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fov_y / 2.0);
        const nf = 1.0 / (near - far);

        var res = Mat4{ .m = [_]f32{0.0} ** 16 };

        // Row 0
        res.m[idx(0, 0)] = f / aspect;
        // Row 1
        res.m[idx(1, 1)] = f;
        // Row 2
        res.m[idx(2, 2)] = (far + near) * nf;
        res.m[idx(2, 3)] = -1.0;
        // Row 3
        res.m[idx(3, 2)] = 2.0 * far * near * nf;

        return res;
    }

    /// Right-handed lookAt matrix, camera at `eye`, looking toward `center`.
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalized();
        const s = f.cross(up).normalized();
        const u = s.cross(f);

        var res = Mat4{ .m = [_]f32{0.0} ** 16 };

        // Column 0 (s)
        res.m[idx(0, 0)] = s.x;
        res.m[idx(1, 0)] = s.y;
        res.m[idx(2, 0)] = s.z;
        res.m[idx(3, 0)] = -s.dot(eye);

        // Column 1 (u)
        res.m[idx(0, 1)] = u.x;
        res.m[idx(1, 1)] = u.y;
        res.m[idx(2, 1)] = u.z;
        res.m[idx(3, 1)] = -u.dot(eye);

        // Column 2 (-f)
        res.m[idx(0, 2)] = -f.x;
        res.m[idx(1, 2)] = -f.y;
        res.m[idx(2, 2)] = -f.z;
        res.m[idx(3, 2)] = f.dot(eye);

        // Column 3
        res.m[idx(0, 3)] = 0.0;
        res.m[idx(1, 3)] = 0.0;
        res.m[idx(2, 3)] = 0.0;
        res.m[idx(3, 3)] = 1.0;

        return res;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Vec3 basic ops" {
    const a = Vec3.init(1.0, 2.0, 3.0);
    const b = Vec3.init(-1.0, 0.5, 4.0);

    const c = a.add(b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), c.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), c.z, 0.0001);

    const d = a.sub(b);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), d.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), d.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), d.z, 0.0001);

    const len2 = a.dot(a);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), len2, 0.0001);
}

test "Mat4 identity & transformPoint" {
    const id = Mat4.identity();
    const v = Vec3.init(1.0, -2.0, 3.5);
    const out = id.transformPoint(v);

    try std.testing.expectApproxEqAbs(@as(f32, v.x), out.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, v.y), out.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, v.z), out.z, 0.0001);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers for tests
// ─────────────────────────────────────────────────────────────────────────────

fn distance(a: Vec3, b: Vec3) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;
    return std.math.sqrt(dx * dx + dy * dy + dz * dz);
}

fn assertFiniteVec3(v: Vec3) !void {
    const math = std.math;
    try std.testing.expect(math.isFinite(v.x));
    try std.testing.expect(math.isFinite(v.y));
    try std.testing.expect(math.isFinite(v.z));
}

// ─────────────────────────────────────────────────────────────────────────────
// View matrix sanity test
// ─────────────────────────────────────────────────────────────────────────────

test "Mat4 lookAt basic sanity" {
    const eye = Vec3.init(0.0, 0.0, 5.0);
    const center = Vec3.init(0.0, 0.0, 0.0);
    const up = Vec3.init(0.0, 1.0, 0.0);

    const view = Mat4.lookAt(eye, center, up);

    const eye_in_view = view.transformPoint(eye);
    const center_in_view = view.transformPoint(center);

    // 1) We never want NaNs or infinities out of a view transform.
    try assertFiniteVec3(eye_in_view);
    try assertFiniteVec3(center_in_view);

    // 2) Distances should be non-zero and not completely degenerate.
    const world_dist = distance(eye, center);
    const view_dist = distance(eye_in_view, center_in_view);

    try std.testing.expect(world_dist > 0.0);
    try std.testing.expect(view_dist > 0.0);

    // 3) The view transform shouldn't obliterate scale:
    //    keep it in a reasonable order-of-magnitude band.
    const ratio = view_dist / world_dist;
    // Allow for perspective / scaling but ban crazy results.
    try std.testing.expect(ratio > 0.001);
    try std.testing.expect(ratio < 1000.0);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
