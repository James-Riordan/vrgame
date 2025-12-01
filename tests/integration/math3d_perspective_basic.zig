const std = @import("std");
const math3d = @import("math3d");

test "integration: perspective matrix core entries" {
    const fov: f32 = std.math.degreesToRadians(60.0);
    const aspect: f32 = 16.0 / 9.0;
    const near: f32 = 0.1;
    const far: f32 = 100.0;

    const P = math3d.Mat4.perspective(fov, aspect, near, far);
    const m = P.m;

    const f = 1.0 / @tan(fov / 2.0);
    const tol: f32 = 1e-5;

    // [0,0] and [1,1]
    try std.testing.expectApproxEqAbs(@as(f32, f / aspect), m[0], tol);
    try std.testing.expectApproxEqAbs(@as(f32, f), m[5], tol);

    // Z mapping (Vulkan/D3D-style: [0,1])
    try std.testing.expectApproxEqAbs(@as(f32, far / (near - far)), m[10], tol);
    try std.testing.expectApproxEqAbs(@as(f32, (far * near) / (near - far)), m[14], tol);

    // -1 in [2,3] (row 2, col 3) → index col=3,row=2 → 3*4+2 = 14? (we already used 14 above)
    // The -1 lives at [2,3] = m[11] (col=3,row=2 → 3*4+2 = 14; careful: here it's [*row* 2, col 3] = m[11])
    // Our implementation sets m[idx(2,3)] = -1 → that is m[11].
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m[11], tol);
}
