const std = @import("std");
const fs = std.fs;
const mem = std.mem;

/// Does `abs_dir/name` exist and is it a directory?
fn containsSubdir(alloc: mem.Allocator, abs_dir: []const u8, name: []const u8) bool {
    const p = std.fs.path.join(alloc, &.{ abs_dir, name }) catch return false;
    defer alloc.free(p);

    var d = fs.openDirAbsolute(p, .{}) catch return false;
    d.close();
    return true;
}

/// Walk upward from CWD until we find a directory that contains "src".
fn findWorkspaceRoot(alloc: mem.Allocator) ![]u8 {
    var cur = try fs.cwd().realpathAlloc(alloc, ".");
    errdefer alloc.free(cur);

    while (true) {
        if (containsSubdir(alloc, cur, "src")) return cur;

        const parent_opt = std.fs.path.dirname(cur);
        if (parent_opt) |parent| {
            if (mem.eql(u8, parent, cur)) break; // reached FS root
            const next = try alloc.dupe(u8, parent);
            alloc.free(cur);
            cur = next;
        } else break;
    }

    alloc.free(cur);
    return error.NotFound;
}

test "repo layout sanity" {
    const A = std.testing.allocator;

    const root = try findWorkspaceRoot(A);
    defer A.free(root);

    // Must at least have `src/` at the workspace root.
    try std.testing.expect(containsSubdir(A, root, "src"));

    // And we can open that root dir.
    var rd = try fs.openDirAbsolute(root, .{});
    defer rd.close();
}
