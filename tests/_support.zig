const std = @import("std");

pub const A = std.testing.allocator;

/// Safe file read with hard cap to avoid OOM in tests.
pub fn readFileAllocLimit(path: []const u8, limit_bytes: usize) ![]u8 {
    const Limit = std.Io.Limit;
    const lim: Limit = @enumFromInt(limit_bytes);
    return try std.fs.cwd().readFileAlloc(path, A, lim);
}

/// Simple PRNG for property tests (seeded deterministically per test seed).
pub fn prng() std.rand.DefaultPrng {
    var seed: u64 = 0xC0FFEE;
    // Mix in the global test seed if available in env (optional).
    if (std.process.getEnvVarOwned(A, "ZTEST_SEED")) |s| {
        defer A.free(s);
        seed ^= std.hash.Wyhash.hash(0, s);
    }
    return std.rand.DefaultPrng.init(seed);
}

/// Approx helpers
pub fn approxEq(a: f32, b: f32, eps: f32) bool {
    return @abs(a - b) <= eps;
}

pub fn approxVec3(a: anytype, b: anytype, eps: f32) bool {
    return approxEq(a.x, b.x, eps) and approxEq(a.y, b.y, eps) and approxEq(a.z, b.z, eps);
}
