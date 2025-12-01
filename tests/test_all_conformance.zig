const std = @import("std");

test {
    _ = @import("conformance/pipeline_defaults.zig");
}

test {
    std.testing.refAllDecls(@This());
}
