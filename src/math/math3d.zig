const std = @import("std");

/// Simple 3D/4D vectors + 4x4 matrices (column-major, Vulkan/GL style).
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3 {
        return .{ .x = 0, .y = 0, .z = 0 };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn scale(self: Vec3, s: f32) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
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
        return if (len == 0.0) self else self.scale(1.0 / len);
    }
};

pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn fromVec3(v: Vec3, w: f32) Vec4 {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = w };
    }

    pub fn toVec3(self: Vec4) Vec3 {
        const inv_w: f32 = if (self.w != 0.0) 1.0 / self.w else 1.0;
        return Vec3.init(self.x * inv_w, self.y * inv_w, self.z * inv_w);
    }

    pub fn toArray(self: Vec4) [4]f32 {
        return .{ self.x, self.y, self.z, self.w };
    }

    /// Accepts Vec4, [4]f32, or *[4]f32 (and *Vec4). Used by Mat4.mulVec4.
    pub fn fromAny(v_any: anytype) Vec4 {
        const T = @TypeOf(v_any);
        const ti = @typeInfo(T);
        return switch (ti) {
            .@"struct" => {
                if (T == Vec4) return v_any;
                @compileError("Vec4.fromAny: unsupported struct type");
            },
            .array => |a| blk: {
                if (a.len != 4) @compileError("Vec4.fromAny: array length must be 4");
                if (a.child != f32) @compileError("Vec4.fromAny: array element type must be f32");
                break :blk Vec4.init(v_any[0], v_any[1], v_any[2], v_any[3]);
            },
            .pointer => blk: {
                break :blk Vec4.fromAny(v_any.*);
            },
            else => @compileError("Vec4.fromAny: unsupported type"),
        };
    }
};

pub const Mat4 = struct {
    /// Column-major 4x4 matrix: m[col*4 + row]
    m: [16]f32,

    inline fn idx(row: usize, col: usize) usize {
        return col * 4 + row;
    }

    pub fn identity() Mat4 {
        var res = Mat4{ .m = [_]f32{0} ** 16 };
        res.m[idx(0, 0)] = 1;
        res.m[idx(1, 1)] = 1;
        res.m[idx(2, 2)] = 1;
        res.m[idx(3, 3)] = 1;
        return res;
    }

    /// Matrix multiply: a * b (column-major).
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r = Mat4{ .m = [_]f32{0} ** 16 };
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var col: usize = 0;
            while (col < 4) : (col += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.m[idx(row, k)] * b.m[idx(k, col)];
                }
                r.m[idx(row, col)] = sum;
            }
        }
        return r;
    }

    /// Multiply by a 4D vector. Returns the **same shape** as the input:
    ///  - Vec4 -> Vec4
    ///  - [4]f32 -> [4]f32
    pub fn mulVec4(self: Mat4, v_any: anytype) @TypeOf(v_any) {
        const v = Vec4.fromAny(v_any);
        const m = self.m;

        const rx = m[idx(0, 0)] * v.x + m[idx(0, 1)] * v.y + m[idx(0, 2)] * v.z + m[idx(0, 3)] * v.w;
        const ry = m[idx(1, 0)] * v.x + m[idx(1, 1)] * v.y + m[idx(1, 2)] * v.z + m[idx(1, 3)] * v.w;
        const rz = m[idx(2, 0)] * v.x + m[idx(2, 1)] * v.y + m[idx(2, 2)] * v.z + m[idx(2, 3)] * v.w;
        const rw = m[idx(3, 0)] * v.x + m[idx(3, 1)] * v.y + m[idx(3, 2)] * v.z + m[idx(3, 3)] * v.w;

        const RetT = @TypeOf(v_any);
        const ti = @typeInfo(RetT);
        return switch (ti) {
            .@"struct" => {
                if (RetT == Vec4) return Vec4.init(rx, ry, rz, rw);
                @compileError("Mat4.mulVec4: unsupported struct return type");
            },
            .array => |a| blk: {
                if (a.len != 4 or a.child != f32)
                    @compileError("Mat4.mulVec4: only [4]f32 arrays supported");
                break :blk [_]f32{ rx, ry, rz, rw };
            },
            .pointer => @compileError("Mat4.mulVec4: pointer inputs not supported; pass by value"),
            else => @compileError("Mat4.mulVec4: unsupported input/return type"),
        };
    }

    /// Transform a point (w=1) with perspective divide.
    pub fn transformPoint(self: Mat4, v: Vec3) Vec3 {
        const v4 = self.mulVec4(Vec4.fromVec3(v, 1.0)); // returns Vec4
        return v4.toVec3();
    }

    /// Right-handed perspective (Vulkan/D3D Z in [0,1]).
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fov_y / 2.0);
        var m = Mat4{ .m = [_]f32{0} ** 16 };

        // diag
        m.m[idx(0, 0)] = f / aspect;
        m.m[idx(1, 1)] = f;

        // Depth (RH, Vulkan/D3D clip: z in [0,1])
        m.m[idx(2, 2)] = far / (near - far); // m22
        m.m[idx(3, 2)] = -1.0; // m32  <-- moved here
        m.m[idx(2, 3)] = (far * near) / (near - far); // m23  <-- moved here
        m.m[idx(3, 3)] = 0.0;

        return m;
    }

    /// Right-handed lookAt, camera at `eye`, looking to `center`, `up` up-vector.
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalized();
        const s = f.cross(up).normalized();
        const u = s.cross(f);

        var r = Mat4{ .m = [_]f32{0} ** 16 };

        // column 0 (s)
        r.m[idx(0, 0)] = s.x;
        r.m[idx(1, 0)] = s.y;
        r.m[idx(2, 0)] = s.z;
        // column 1 (u)
        r.m[idx(0, 1)] = u.x;
        r.m[idx(1, 1)] = u.y;
        r.m[idx(2, 1)] = u.z;
        // column 2 (-f)
        r.m[idx(0, 2)] = -f.x;
        r.m[idx(1, 2)] = -f.y;
        r.m[idx(2, 2)] = -f.z;
        // column 3 (translation)
        r.m[idx(0, 3)] = -s.dot(eye);
        r.m[idx(1, 3)] = -u.dot(eye);
        r.m[idx(2, 3)] = f.dot(eye);
        r.m[idx(3, 3)] = 1.0;

        return r;
    }

    /// Alias (kept for convenience).
    pub fn mulPoint(self: Mat4, v: Vec3) Vec3 {
        return self.transformPoint(v);
    }
    pub fn mulPoint3(self: Mat4, v: Vec3) Vec3 {
        return self.transformPoint(v);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Vec3 basics" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(-1, 0.5, 4);
    const c = a.add(b);
    try std.testing.expectApproxEqAbs(@as(f32, 0), c.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), c.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 7), c.z, 0.0001);
}

test "Mat4.identity mulVec4 returns same shape as input" {
    const I = Mat4.identity();
    const v_arr: [4]f32 = .{ 1, 2, 3, 1 };
    const out_arr = I.mulVec4(v_arr);
    try std.testing.expectEqualDeep(v_arr, out_arr);

    const v4 = Vec4.init(1, 2, 3, 1);
    const out_v4 = I.mulVec4(v4);
    try std.testing.expectEqual(@as(f32, v4.x), out_v4.x);
    try std.testing.expectEqual(@as(f32, v4.y), out_v4.y);
    try std.testing.expectEqual(@as(f32, v4.z), out_v4.z);
    try std.testing.expectEqual(@as(f32, v4.w), out_v4.w);
}

test "Mat4.transformPoint identity" {
    const I = Mat4.identity();
    const v = Vec3.init(1.0, -2.0, 3.5);
    const out = I.transformPoint(v);
    try std.testing.expectApproxEqAbs(v.x, out.x, 0.0001);
    try std.testing.expectApproxEqAbs(v.y, out.y, 0.0001);
    try std.testing.expectApproxEqAbs(v.z, out.z, 0.0001);
}

test "Vec3 normalization → unit length (128 samples)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    var rng = prng.random();

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var v = Vec3.init(
            rng.float(f32) * 2.0 - 1.0,
            rng.float(f32) * 2.0 - 1.0,
            rng.float(f32) * 2.0 - 1.0,
        );
        if (v.length() < 1e-6) continue; // skip near-zero
        v = v.normalized();
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), v.length(), 1e-3);
    }
}

test "Mat4 identity invariants (I*M==M && M*I==M)" {
    const I = Mat4.identity();
    const proj = Mat4.perspective(std.math.degreesToRadians(60.0), 16.0 / 9.0, 0.1, 100.0);
    const view = Mat4.lookAt(Vec3.init(1, 2, 3), Vec3.init(0, 0, 0), Vec3.init(0, 1, 0));
    const M = Mat4.mul(proj, view);

    const IM = Mat4.mul(I, M);
    const MI = Mat4.mul(M, I);

    var k: usize = 0;
    while (k < 16) : (k += 1) {
        try std.testing.expectApproxEqAbs(M.m[k], IM.m[k], 1e-5);
        try std.testing.expectApproxEqAbs(M.m[k], MI.m[k], 1e-5);
    }
}

// test "refAllDecls(math3d)" {
//     std.testing.refAllDecls(@This());
// }
