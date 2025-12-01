const std = @import("std");
const math3d = @import("math3d");
const Mat4 = math3d.Mat4;

test "integration: Mat4 identity behaves" {
    var I = Mat4.identity();
    const v = [4]f32{ 1, 2, 3, 1 };
    const out = I.mulVec4(v);
    try std.testing.expectEqualDeep(v, out);
}
