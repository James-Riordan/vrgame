const std = @import("std");

test {
    _ = @import("e2e/smoke_cli_build.zig");
}

test {
    std.testing.refAllDecls(@This());
}
