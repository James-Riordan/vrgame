const std = @import("std");

const A = std.testing.allocator;

inline fn exists(path: []const u8) bool {
    _ = std.fs.cwd().statFile(path) catch return false;
    return true;
}

fn ensureDir(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn readFileAllocLimit(path: []const u8, limit_bytes: usize) ![]u8 {
    const lim: std.Io.Limit = @enumFromInt(limit_bytes);
    return try std.fs.cwd().readFileAlloc(path, A, lim);
}

fn runGlslc(argv: []const []const u8) !void {
    const res = try std.process.Child.run(.{
        .allocator = A,
        .argv = argv,
        .max_output_bytes = 1 << 20,
    });
    defer {
        A.free(res.stdout);
        A.free(res.stderr);
    }

    switch (res.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("glslc failed (code {d})\n{s}\n", .{ code, res.stderr });
                return error.GlslcFailed;
            }
        },
        else => {
            std.debug.print("glslc did not exit normally\n", .{});
            return error.GlslcFailed;
        },
    }
}

/// Compile only (no link) and write to `out` with -o.
/// We pass exactly one input file and make the output explicit.
fn compileIfMissing(stage: []const u8, src: []const u8, out: []const u8) !void {
    if (exists(out)) return;

    const parent = std.fs.path.dirname(out) orelse ".";
    try ensureDir(parent);

    const flag = try std.fmt.allocPrint(A, "-fshader-stage={s}", .{stage});
    defer A.free(flag);

    const argv = [_][]const u8{
        "glslc",
        "-c",
        flag,
        src,
        "-o",
        out,
    };
    try runGlslc(&argv);

    if (!exists(out)) return error.FileNotFound;
}

test "compiled SPIR-V files exist and are valid-looking" {
    const out_root = "zig-out/shaders";
    try ensureDir(out_root);

    const targets = [_]struct {
        name: []const u8,
        stage: []const u8,
        src: []const u8,
    }{
        .{ .name = "triangle_vert", .stage = "vert", .src = "shaders/triangle.vert" },
        .{ .name = "triangle_frag", .stage = "frag", .src = "shaders/triangle.frag" },
    };

    for (targets) |t| {
        const out_path = try std.fs.path.join(A, &.{ out_root, t.name });
        defer A.free(out_path);

        if (!exists(out_path)) {
            if (!exists(t.src)) {
                std.debug.print("Shader source missing: {s}\n", .{t.src});
                return error.TestExpectedEqual;
            }
            try compileIfMissing(t.stage, t.src, out_path);
        }

        const buf = try readFileAllocLimit(out_path, 16 * 1024 * 1024);
        defer A.free(buf);

        try std.testing.expect(buf.len >= 8);

        // SPIR-V magic number 0x07230203 (little endian on disk).
        const magic = std.mem.readInt(u32, buf[0..4], .little);
        try std.testing.expectEqual(@as(u32, 0x07230203), magic);

        // Version dword is next (sanity read only).
        const _version = std.mem.readInt(u32, buf[4..8], .little);
        _ = _version;
    }
}
