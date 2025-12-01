const std = @import("std");
const math3d = @import("math3d");

test "Mat4.mul respects identity on both sides" {
    const I = math3d.Mat4.identity();

    // Random but fixed values to avoid NaNs.
    var M = math3d.Mat4.identity();
    // Nudge a couple entries to make it non-trivial.
    M.m[0] = 2.0;
    M.m[5] = 3.0;
    M.m[10] = 4.0;
    M.m[12] = 1.0;
    M.m[13] = -2.0;
    M.m[14] = 0.5;

    const left = math3d.Mat4.mul(I, M);
    const right = math3d.Mat4.mul(M, I);

    inline for (0..16) |i| {
        try std.testing.expectApproxEqAbs(M.m[i], left.m[i], 1e-6);
        try std.testing.expectApproxEqAbs(M.m[i], right.m[i], 1e-6);
    }
}
