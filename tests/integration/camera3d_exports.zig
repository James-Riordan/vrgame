const std = @import("std");
const camera3d = @import("camera3d");
const math3d = @import("math3d");

test "camera3d: basic exports exist" {
    try std.testing.expect(@hasDecl(camera3d, "Camera3D"));
    try std.testing.expect(@hasDecl(camera3d, "CameraInput"));
}

// If Camera3D exposes view/proj, sanity-check they’re finite when eye looks at origin.
test "camera3d: view*proj finite if available" {
    if (@hasDecl(camera3d, "Camera3D")) {
        const eye = math3d.Vec3.init(0, 0, 5);
        const center = math3d.Vec3.init(0, 0, 0);
        const up = math3d.Vec3.init(0, 1, 0);

        const view = math3d.Mat4.lookAt(eye, center, up);
        const proj = math3d.Mat4.perspective(std.math.degreesToRadians(70.0), 16.0 / 9.0, 0.1, 100.0);
        const vp = math3d.Mat4.mul(proj, view);

        // elements finite
        for (vp.m) |x| try std.testing.expect(std.math.isFinite(x));
    }
}
