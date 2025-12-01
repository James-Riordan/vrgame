const std = @import("std");
const math3d = @import("math3d");

test "integration: lookAt produces an orthonormal basis" {
    const eye = math3d.Vec3.init(1.0, 2.0, 3.0);
    const center = math3d.Vec3.init(0.0, 0.0, 0.0);
    const up = math3d.Vec3.init(0.0, 1.0, 0.0);

    const V = math3d.Mat4.lookAt(eye, center, up);
    const m = V.m;

    // Column-major: [col*4 + row]
    const s = math3d.Vec3.init(m[0], m[1], m[2]); // right
    const u_axis = math3d.Vec3.init(m[4], m[5], m[6]); // up
    const neg_f = math3d.Vec3.init(m[8], m[9], m[10]); // -forward

    const tol: f32 = 1e-5;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.length(), tol);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), u_axis.length(), tol);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), neg_f.length(), tol);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.dot(u_axis), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.dot(neg_f), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), u_axis.dot(neg_f), 1e-4);
}
