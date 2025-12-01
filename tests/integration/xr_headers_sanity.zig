const std = @import("std");

// Contract: the OpenXR module must be importable via build.zig wiring.
// If codegen/import breaks, this test won't even compile.
test "integration: openxr module wires in" {
    _ = @import("openxr");
    try std.testing.expect(true);
}
