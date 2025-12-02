const std = @import("std");
const Vertex = @import("vertex").Vertex;

/// Public world constants (so main.zig can size buffers at comptime)
pub const GRID_HALF: i32 = 64;
pub const GRID_STEP: f32 = 1.0;

const GRID_SIZE: i32 = GRID_HALF * 2;
const QUAD_COUNT: usize = @intCast(GRID_SIZE * GRID_SIZE);

pub const FLOOR_VERTS: u32 = @intCast(QUAD_COUNT * 6);
pub const CUBE_VERTS: u32 = 36;
pub const TOTAL_VERTICES: u32 = FLOOR_VERTS + CUBE_VERTS;

/// Fills `verts` with a checkerboard floor (two triangles per cell).
pub fn writeFloorWorld(verts: []Vertex) void {
    var idx: usize = 0;
    const up = [3]f32{ 0.0, 1.0, 0.0 };

    var z: i32 = -GRID_HALF;
    while (z < GRID_HALF) : (z += 1) {
        const z0 = @as(f32, @floatFromInt(z)) * GRID_STEP;
        const z1 = z0 + GRID_STEP;

        var x: i32 = -GRID_HALF;
        while (x < GRID_HALF) : (x += 1) {
            const x0 = @as(f32, @floatFromInt(x)) * GRID_STEP;
            const x1 = x0 + GRID_STEP;

            const p00 = [3]f32{ x0, 0.0, z0 };
            const p10 = [3]f32{ x1, 0.0, z0 };
            const p11 = [3]f32{ x1, 0.0, z1 };
            const p01 = [3]f32{ x0, 0.0, z1 };

            const is_light = (((x + GRID_HALF) + (z + GRID_HALF)) & 1) == 0;
            const color: [3]f32 = if (is_light) .{ 0.86, 0.88, 0.92 } else .{ 0.20, 0.22, 0.26 };

            verts[idx + 0] = .{ .pos = p00, .normal = up, .color = color };
            verts[idx + 1] = .{ .pos = p10, .normal = up, .color = color };
            verts[idx + 2] = .{ .pos = p11, .normal = up, .color = color };
            verts[idx + 3] = .{ .pos = p00, .normal = up, .color = color };
            verts[idx + 4] = .{ .pos = p11, .normal = up, .color = color };
            verts[idx + 5] = .{ .pos = p01, .normal = up, .color = color };
            idx += 6;
        }
    }

    std.debug.assert(idx == @as(usize, FLOOR_VERTS));
}

/// Appends a unit cube (centered at origin, y in [0,1]) to `verts`.
pub fn writeUnitCube(verts: []Vertex) void {
    const c_top = [3]f32{ 0.55, 0.70, 0.95 };
    const c_side = [3]f32{ 0.65, 0.95, 0.92 };

    var i: usize = 0;

    const x0: f32 = -0.5;
    const x1: f32 = 0.5;
    const z0: f32 = -0.5;
    const z1: f32 = 0.5;

    // +Y (top)
    var n = [3]f32{ 0, 1, 0 };
    const top = [_][3]f32{
        .{ x0, 1, z0 }, .{ x1, 1, z0 }, .{ x1, 1, z1 },
        .{ x0, 1, z0 }, .{ x1, 1, z1 }, .{ x0, 1, z1 },
    };
    for (top) |p| {
        verts[i] = .{ .pos = p, .normal = n, .color = c_top };
        i += 1;
    }

    // -Y (bottom)
    n = .{ 0, -1, 0 };
    const bot = [_][3]f32{
        .{ x0, 0, z1 }, .{ x1, 0, z1 }, .{ x1, 0, z0 },
        .{ x0, 0, z1 }, .{ x1, 0, z0 }, .{ x0, 0, z0 },
    };
    for (bot) |p| {
        verts[i] = .{ .pos = p, .normal = n, .color = c_side };
        i += 1;
    }

    // +X
    n = .{ 1, 0, 0 };
    const px = [_][3]f32{
        .{ x1, 0, z0 }, .{ x1, 1, z0 }, .{ x1, 1, z1 },
        .{ x1, 0, z0 }, .{ x1, 1, z1 }, .{ x1, 0, z1 },
    };
    for (px) |p| {
        verts[i] = .{ .pos = p, .normal = n, .color = c_side };
        i += 1;
    }

    // -X
    n = .{ -1, 0, 0 };
    const nx = [_][3]f32{
        .{ x0, 0, z1 }, .{ x0, 1, z1 }, .{ x0, 1, z0 },
        .{ x0, 0, z1 }, .{ x0, 1, z0 }, .{ x0, 0, z0 },
    };
    for (nx) |p| {
        verts[i] = .{ .pos = p, .normal = n, .color = c_side };
        i += 1;
    }

    // +Z
    n = .{ 0, 0, 1 };
    const pz = [_][3]f32{
        .{ x0, 0, z1 }, .{ x1, 0, z1 }, .{ x1, 1, z1 },
        .{ x0, 0, z1 }, .{ x1, 1, z1 }, .{ x0, 1, z1 },
    };
    for (pz) |p| {
        verts[i] = .{ .pos = p, .normal = n, .color = c_side };
        i += 1;
    }

    // -Z
    n = .{ 0, 0, -1 };
    const nz = [_][3]f32{
        .{ x1, 0, z0 }, .{ x0, 0, z0 }, .{ x0, 1, z0 },
        .{ x1, 0, z0 }, .{ x0, 1, z0 }, .{ x1, 1, z0 },
    };
    for (nz) |p| {
        verts[i] = .{ .pos = p, .normal = n, .color = c_side };
        i += 1;
    }

    std.debug.assert(i == @as(usize, CUBE_VERTS));
}
