const std = @import("std");
const math3d = @import("math3d");

test "math3d.perspective basic coefficients sane" {
    const fov = std.math.degreesToRadians(70.0);
    const aspect: f32 = 16.0 / 9.0;
    const near: f32 = 0.1;
    const far: f32 = 100.0;

    const P = math3d.Mat4.perspective(fov, aspect, near, far);

    // Focal terms present and finite
    try std.testing.expect(std.math.isFinite(P.m[0])); // m00
    try std.testing.expect(std.math.isFinite(P.m[5])); // m11

    // Depth row/column follow our convention
    try std.testing.expectApproxEqAbs(@as(f32, far / (near - far)), P.m[10], 1e-5); // m22
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), P.m[11], 1e-6); // m23
    try std.testing.expectApproxEqAbs(@as(f32, (far * near) / (near - far)), P.m[14], 1e-5); // m32

    // No NaNs anywhere
    for (P.m) |x| try std.testing.expect(std.math.isFinite(x));
}
