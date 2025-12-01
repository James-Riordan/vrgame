const std = @import("std");
const swap = @import("swapchain");

test "integration: Swapchain module basic API surface" {
    // Accept either struct+methods or free helpers.
    const ok =
        @hasDecl(swap, "Swapchain") or
        @hasDecl(swap, "SupportDetails") or
        @hasDecl(swap, "chooseSurfaceFormat") or
        @hasDecl(swap, "create") or
        (@hasDecl(swap, "acquireNext") or @hasDecl(swap, "acquire"));

    try std.testing.expect(ok);
}
