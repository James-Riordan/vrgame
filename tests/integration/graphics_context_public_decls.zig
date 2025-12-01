const std = @import("std");
const gc = @import("graphics_context");

test "integration: GraphicsContext exposes expected public decls" {
    try std.testing.expect(@hasDecl(gc, "GraphicsContext"));

    // accept either a top-level init function or a builder/init struct
    const ok =
        @hasDecl(gc, "init") or
        @hasDecl(gc, "initInstanceOnly") or
        (@hasDecl(gc.GraphicsContext, "init")) or
        (@hasDecl(gc.GraphicsContext, "initInstanceOnly")) or
        (@hasDecl(gc, "Builder")) or
        (@hasDecl(gc, "create") or @hasDecl(gc, "createInstance"));

    try std.testing.expect(ok);
}
