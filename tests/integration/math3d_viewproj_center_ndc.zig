const std = @import("std");
const math3d = @import("math3d");

test "integration: P*V maps world origin near NDC center (x≈0,y≈0, z in [0,1])" {
    const eye = math3d.Vec3.init(0.0, 0.0, 3.0);
    const center = math3d.Vec3.init(0.0, 0.0, 0.0);
    const up = math3d.Vec3.init(0.0, 1.0, 0.0);

    const V = math3d.Mat4.lookAt(eye, center, up);
    const P = math3d.Mat4.perspective(std.math.degreesToRadians(60.0), 16.0 / 9.0, 0.1, 100.0);
    const VP = math3d.Mat4.mul(P, V);

    const clip = VP.transformPoint(center);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), clip.x, 2e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), clip.y, 2e-3);
    try std.testing.expect(clip.z >= 0.0 and clip.z <= 1.0);
}
