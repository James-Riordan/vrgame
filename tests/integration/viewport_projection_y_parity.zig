const std = @import("std");

fn windowY_macos(ndc_y: f32, H: f32) f32 {
    // macOS path: negative viewport height.
    // Vulkan window transform: y' = y + height * 0.5 * (ndc_y + 1)
    const y: f32 = H;
    const height: f32 = -H;
    return y + height * 0.5 * (ndc_y + 1.0);
}

fn windowY_win_projflip(ndc_y: f32, H: f32) f32 {
    // Windows/Linux path: positive viewport height + projection Y flip
    // (equivalent to negating NDC y before the viewport transform).
    const y: f32 = 0.0;
    const height: f32 = H;
    const ndc_y_after: f32 = -ndc_y; // effect of m[5] = -m[5]
    return y + height * 0.5 * (ndc_y_after + 1.0);
}

test "projection flip vs negative viewport are equivalent across Y samples" {
    const H: f32 = 2000.0;
    const samples = [_]f32{ -1.0, -0.5, 0.0, 0.5, 1.0 };

    inline for (samples) |ny| {
        const a = windowY_macos(ny, H);
        const b = windowY_win_projflip(ny, H);
        try std.testing.expectApproxEqAbs(@as(f64, a), @as(f64, b), 0.00001);
    }
}
