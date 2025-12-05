const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");

const depth = @import("depth");
const texture = @import("texture");

const GraphicsContext = @import("graphics_context").GraphicsContext;
const Swapchain = @import("swapchain").Swapchain;
const Vertex = @import("vertex").Vertex;

const frame_time = @import("frame_time");
const FrameTimer = frame_time.FrameTimer;

const camera3d = @import("camera3d");
const Camera3D = camera3d.Camera3D;
const CameraInput = camera3d.CameraInput;

const math3d = @import("math3d");
const Vec3 = math3d.Vec3;
const Mat4 = math3d.Mat4;

const Orbit = @import("orbit");

const Allocator = std.mem.Allocator;

// ──────────────────────────────────────────────────────────────────────────────
// Platform / graphics toggles
const IS_MAC = builtin.os.tag == .macos;

// Flip policy:
// - Windows/Linux: viewport flip (neg height), NO projection flip.
// - macOS: projection flip, NO viewport flip.
pub const VIEWPORT_Y_FLIP: bool = !IS_MAC; // Windows/Linux = true, macOS = false
pub const PROJECTION_Y_FLIP: bool = IS_MAC; // macOS = true, Windows/Linux = false

comptime {
    if (IS_MAC) {
        if (VIEWPORT_Y_FLIP or !PROJECTION_Y_FLIP) @compileError("macOS: projection flip only.");
    } else {
        if (!VIEWPORT_Y_FLIP or PROJECTION_Y_FLIP) @compileError("Windows/Linux: viewport flip only.");
    }
}

// Optional debug toggles
const FORCE_DEBUG_FLAT_SHADERS: bool = false;
const DEBUG_DISABLE_DEPTH: bool = false;

const VK_FALSE32: vk.Bool32 = @enumFromInt(vk.FALSE);
const VK_TRUE32: vk.Bool32 = @enumFromInt(vk.TRUE);

const window_title_cstr: [*:0]const u8 = "VRGame — Zigadel Prototype\x00";
const window_title_base: []const u8 = "VRGame — Zigadel Prototype";

// ──────────────────────────────────────────────────────────────────────────────
// World geometry (simple floor grid + unit cube)
const GRID_HALF: i32 = 64;
const GRID_STEP: f32 = 1.0;
const GRID_SIZE: i32 = GRID_HALF * 2;
const QUAD_COUNT: usize = @intCast(GRID_SIZE * GRID_SIZE);
const FLOOR_VERTS: u32 = @intCast(QUAD_COUNT * 6);
const CUBE_VERTS: u32 = 36;
const TOTAL_VERTICES: u32 = FLOOR_VERTS + CUBE_VERTS;
const VERTEX_BUFFER_SIZE: vk.DeviceSize =
    @intCast(@as(usize, TOTAL_VERTICES) * @sizeOf(Vertex));

// Instance data (per-cube)
const CUBE_INSTANCES: usize = 1024;
const Instance = extern struct {
    model: [16]f32, // std430-friendly (4x vec4)
    color: [4]f32,
};

var cube_pos: [CUBE_INSTANCES][3]f32 = undefined;
var spin_axis: [CUBE_INSTANCES][3]f32 = undefined;
var spin_speed: [CUBE_INSTANCES]f32 = undefined;
var inst_color: [CUBE_INSTANCES][4]f32 = undefined;

// Scene UBO
const SceneUBO = extern struct {
    vp: [16]f32,
    light_dir: [4]f32, // xyz
    light_color: [4]f32, // rgb
    ambient: [4]f32, // rgb
    time: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },
};

const CameraStyle = enum { fly, blender_orbit };

// ──────────────────────────────────────────────────────────────────────────────
// Runtime config (simple, only what we actually use)
const Config = struct {
    // Camera & input
    fov_deg: f32 = 70.0,
    mouse_sens: f32 = 0.12,
    invert_y: bool = false,
    enable_raw_mouse: bool = true,

    // Movement
    base_move_speed_scale: f32 = 1.0,
    sprint_mult: f32 = 2.5,

    // Windowing
    allow_alt_enter: bool = true,
    allow_f11: bool = true,
    allow_cmd_ctrl_f_mac: bool = true,

    // Debug
    debug_heartbeat_every: u32 = 120, // frame heartbeat interval
    debug_no_draw: bool = false,

    // Look smoothing
    look_smooth_halflife_ms: f32 = 60.0,
    look_expo: f32 = 0.15,
    max_pitch_deg: f32 = 89.0,
    camera_style: CameraStyle = .blender_orbit,

    // Blender-like orbit tuning
    orbit_yaw_sens: f32 = 0.008, // rad per px (horizontal)
    orbit_pitch_sens: f32 = 0.008, // rad per px (vertical)
    orbit_pan_sens: f32 = 1.0, // world-units per px @ radius=1
    orbit_dolly_wheel: f32 = 1.20, // wheel zoom factor per notch (>1)
    orbit_dolly_drag: f32 = 0.003, // Ctrl+RMB vertical drag factor
    orbit_min_radius: f32 = 0.15,
    orbit_max_radius: f32 = 500.0,
};

var CONFIG: Config = .{};

// ──────────────────────────────────────────────────────────────────────────────
// Static state for small input helpers
const InputState = struct {
    var just_locked: bool = false; // set for one frame after cursor lock
    var raw_mouse_enabled: bool = false; // once enabled, stays true
    var raw_mouse_checked: bool = false; // check & enable only once
};

const WindowState = struct {
    var fullscreen: bool = false;
    var saved_x: i32 = 100;
    var saved_y: i32 = 100;
    var saved_w: i32 = 1280;
    var saved_h: i32 = 800;
};

const MouseLatch = struct { // edge-trigger for RMB
    pub var rmb_was_down: bool = false;
};

const LookState = struct {
    pub var have_prev: bool = false;
    pub var prev_pos: [2]f64 = .{ 0, 0 };
    pub var filt_dx: f32 = 0.0;
    pub var filt_dy: f32 = 0.0;
};

// ──────────────────────────────────────────────────────────────────────────────
// Small math helpers
fn normalize3(v: [3]f32) [3]f32 {
    const s = std.math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (s <= 0.0) return .{ 0, 0, 0 };
    return .{ v[0] / s, v[1] / s, v[2] / s };
}
fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
fn scale3(a: [3]f32, s: f32) [3]f32 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn mul4x4(a: [16]f32, b: [16]f32) [16]f32 {
    var r: [16]f32 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            r[i + 4 * j] =
                a[0 + 4 * j] * b[i + 0] +
                a[1 + 4 * j] * b[i + 4] +
                a[2 + 4 * j] * b[i + 8] +
                a[3 + 4 * j] * b[i + 12];
        }
    }
    return r;
}

fn perspectiveRH_ZO(fov: f32, aspect: f32, zn: f32, zf: f32) [16]f32 {
    const f = 1.0 / std.math.tan(fov * 0.5);
    return .{
        f / aspect, 0, 0,                     0,
        0,          f, 0,                     0,
        0,          0, zf / (zn - zf),        -1,
        0,          0, (zf * zn) / (zn - zf), 0,
    };
}

fn lookAtRH(eye: [3]f32, target: [3]f32, up_world: [3]f32) [16]f32 {
    const fwd = normalize3(sub3(target, eye));
    const right = normalize3(cross3(fwd, up_world));
    const up = cross3(right, fwd);
    return .{
        right[0],          up[0],          -fwd[0],        0,
        right[1],          up[1],          -fwd[1],        0,
        right[2],          up[2],          -fwd[2],        0,
        -dot3(right, eye), -dot3(up, eye), dot3(fwd, eye), 1,
    };
}

const OrbitState = struct {
    target: [3]f32 = .{ 0.0, 0.5, 0.0 },
    radius: f32 = 6.0,
    yaw: f32 = 0.0, // radians
    pitch: f32 = -0.15, // radians
};

// Local scroll accumulator
const Scroll = struct {
    pub var dy: f64 = 0.0;
};
fn onScroll(_: ?*glfw.Window, _: f64, yoff: f64) callconv(.c) void {
    Scroll.dy += yoff;
}

// Keep/restore previous GLFW scroll callback (safer for composability)
const ScrollCB = ?*const fn (?*glfw.Window, f64, f64) callconv(.c) void;
var prev_scroll_cb: ScrollCB = null;

fn installScroll(window: *glfw.Window) void {
    prev_scroll_cb = glfw.setScrollCallback(window, onScroll);
}
fn restoreScroll(window: *glfw.Window) void {
    _ = glfw.setScrollCallback(window, prev_scroll_cb);
}

inline fn clamp01(x: f32) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

fn smoothingAlpha(halflife_ms: f32, dt: f32) f32 {
    if (halflife_ms <= 0.0) return 1.0;
    const k: f32 = std.math.ln2 / (halflife_ms / 1000.0);
    return 1.0 - @as(f32, @floatCast(std.math.exp(-k * dt)));
}

fn applyExpo(x: f32, expo: f32) f32 {
    if (expo <= 0.0) return x;
    const s: f32 = if (x < 0) -1 else 1;
    const a: f32 = @abs(x);
    return s * std.math.pow(f32, a, 1.0 + expo);
}

fn mulPoint4x4(m: [16]f32, p: [4]f32) [4]f32 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12] * p[3],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13] * p[3],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[15] * p[3],
        m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15] * p[3],
    };
}

fn centerInsideClip(vp: [16]f32, world_center: [3]f32) bool {
    const c = mulPoint4x4(vp, .{ world_center[0], world_center[1], world_center[2], 1.0 });
    if (c[3] <= 0.0) return false;
    const ax = @abs(c[0]);
    const ay = @abs(c[1]);
    const pad: f32 = 1.02;
    return (ax <= c[3] * pad) and
        (ay <= c[3] * pad) and
        (c[2] >= 0.0) and (c[2] <= c[3] * pad);
}

fn axisAngleMat4(axis_in: [3]f32, angle: f32, translate: [3]f32) [16]f32 {
    var ax = axis_in;
    const len = std.math.sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
    if (len > 0.0) {
        ax[0] /= len;
        ax[1] /= len;
        ax[2] /= len;
    } else {
        ax = .{ 0, 1, 0 };
    }

    const c = std.math.cos(angle);
    const s = std.math.sin(angle);
    const t = 1.0 - c;
    const x = ax[0];
    const y = ax[1];
    const z = ax[2];

    return .{
        t * x * x + c,     t * x * y + s * z, t * x * z - s * y, 0.0,
        t * x * y - s * z, t * y * y + c,     t * y * z + s * x, 0.0,
        t * x * z + s * y, t * y * z - s * x, t * z * z + c,     0.0,
        translate[0],      translate[1],      translate[2],      1.0,
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// PRNG helpers (SplitMix64)
fn splitmix64_next(s: *u64) u64 {
    s.* +%= 0x9E3779B97F4A7C15;
    var z = s.*;
    z ^= z >> 30;
    z *%= 0xBF58476D1CE4E5B9;
    z ^= z >> 27;
    z *%= 0x94D049BB133111EB;
    z ^= z >> 31;
    return z;
}

fn uniform01(s: *u64) f32 {
    const v: u32 = @intCast(splitmix64_next(s) >> 40);
    return @as(f32, @floatFromInt(v)) * (1.0 / 16777215.0);
}

fn randUnitVec3(s: *u64) [3]f32 {
    const z = 2.0 * uniform01(s) - 1.0;
    const a = 2.0 * std.math.pi * uniform01(s);
    const r = std.math.sqrt(@max(0.0, 1.0 - z * z));
    return .{ r * std.math.cos(a), r * std.math.sin(a), z };
}

// Scatter instances around the origin, leaving a small clear area near (0,0)
fn scatterInstances(seed: u64) void {
    var s = seed;
    const R: f32 = @as(f32, @floatFromInt(GRID_HALF)) * GRID_STEP - 4.0;

    for (0..CUBE_INSTANCES) |i| {
        var x = (uniform01(&s) * 2.0 - 1.0) * R;
        var z = (uniform01(&s) * 2.0 - 1.0) * R;
        if (@abs(x) < 4.0 and @abs(z) < 4.0) {
            x += if (x >= 0) 4.0 else -4.0;
            z += if (z >= 0) 4.0 else -4.0;
        }
        cube_pos[i] = .{ x, 0.5, z };
        spin_axis[i] = randUnitVec3(&s);
        spin_speed[i] = 0.4 + 1.6 * uniform01(&s);

        const h = uniform01(&s);
        const sat = 0.45 + 0.25 * uniform01(&s);
        const val = 0.8 + 0.2 * uniform01(&s);
        inst_color[i] = .{ val, sat, h, 1.0 };
    }
}

fn hsvToRgb(h: f32, s: f32, v: f32) [3]f32 {
    const k0: f32 = 1.0;
    const k1: f32 = 2.0 / 3.0;
    const k2: f32 = 1.0 / 3.0;
    const k3: f32 = 3.0;
    const r = v * (k0 - clamp01(@abs(@mod(h * k3, 2.0) - 1.0)) * s);
    const g = v * (k0 - clamp01(@abs(@mod(h * k3 + k2 * 2.0, 2.0) - 1.0)) * s);
    const b = v * (k0 - clamp01(@abs(@mod(h * k3 + k1 * 2.0, 2.0) - 1.0)) * s);
    return .{ r, g, b };
}

// Build instance buffer with only visible instances; returns count
fn buildVisibleInstances(
    vp: [16]f32,
    time_sec: f32,
    out_ptr: [*]Instance,
    max_instances: usize,
) usize {
    var count: usize = 0;

    for (0..CUBE_INSTANCES) |i| {
        if (!centerInsideClip(vp, cube_pos[i])) continue;
        if (count >= max_instances) break;

        const axis = spin_axis[i];
        const angle = spin_speed[i] * time_sec;
        const model = axisAngleMat4(axis, angle, cube_pos[i]);

        const h = inst_color[i][2];
        const s = inst_color[i][1];
        const v = inst_color[i][0];
        const rgb = hsvToRgb(h, s, v);

        out_ptr[count] = .{
            .model = model,
            .color = .{ rgb[0], rgb[1], rgb[2], 1.0 },
        };
        count += 1;
    }
    return count;
}

// ──────────────────────────────────────────────────────────────────────────────
// Geometry writers
fn writeFloorWorld(verts: []Vertex) void {
    var idx: usize = 0;
    const half: i32 = GRID_HALF;
    const step: f32 = GRID_STEP;
    const up = [3]f32{ 0.0, 1.0, 0.0 };

    var z: i32 = -half;
    while (z < half) : (z += 1) {
        const z0 = @as(f32, @floatFromInt(z)) * step;
        const z1 = @as(f32, @floatFromInt(z + 1)) * step;

        var x: i32 = -half;
        while (x < half) : (x += 1) {
            const x0 = @as(f32, @floatFromInt(x)) * step;
            const x1 = @as(f32, @floatFromInt(x + 1)) * step;

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

fn writeUnitCube(verts: []Vertex) void {
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

// ──────────────────────────────────────────────────────────────────────────────
// File IO + shader loading (4-byte aligned SPIR-V reads)
fn readAlignedAbsolute2(alloc: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    var file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    const end_pos = try file.getEndPos();
    if (end_pos == 0) return error.EmptyFile;
    if (end_pos > 16 * 1024 * 1024) return error.FileTooBig;

    const size: usize = @intCast(end_pos);
    var buf = try alloc.alignedAlloc(u8, .@"4", size);
    errdefer alloc.free(buf);

    var off: usize = 0;
    while (off < size) {
        const n = try file.read(buf[off..]);
        if (n == 0) break;
        off += n;
    }
    if (off != size) return error.UnexpectedEof;
    if (size % 4 != 0) return error.BadSpirvSize;

    return buf;
}

fn readAlignedFromCwd2(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(rel, .{});
    defer file.close();

    const end_pos = try file.getEndPos();
    if (end_pos == 0) return error.EmptyFile;
    if (end_pos > 16 * 1024 * 1024) return error.FileTooBig;

    const size: usize = @intCast(end_pos);
    var buf = try alloc.alignedAlloc(u8, .@"4", size);
    errdefer alloc.free(buf);

    var off: usize = 0;
    while (off < size) {
        const n = try file.read(buf[off..]);
        if (n == 0) break;
        off += n;
    }
    if (off != size) return error.UnexpectedEof;
    if (size % 4 != 0) return error.BadSpirvSize;

    return buf;
}

fn loadShaderBytes(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    var last_err: anyerror = error.FileNotFound;

    // 1) <exe_dir>/<rel_path>
    if (std.fs.selfExeDirPathAlloc(allocator) catch null) |exe_dir| {
        defer allocator.free(exe_dir);

        if (std.fs.path.join(allocator, &.{ exe_dir, rel_path }) catch null) |abs1| {
            defer allocator.free(abs1);
            if (readAlignedAbsolute2(allocator, abs1)) |bytes| {
                std.log.info("Loaded shader from exe dir: {s}", .{abs1});
                return bytes;
            } else |e| last_err = e;
        }

        // 2) <exe_dir>/../assets/<rel_path>
        if (std.fs.path.resolve(allocator, &.{ exe_dir, "..", "assets", rel_path }) catch null) |abs2| {
            defer allocator.free(abs2);
            if (readAlignedAbsolute2(allocator, abs2)) |bytes| {
                std.log.info("Loaded shader from exe assets: {s}", .{abs2});
                return bytes;
            } else |e| last_err = e;
        }
    }

    // 3) CWD/<rel_path>
    if (readAlignedFromCwd2(allocator, rel_path)) |bytes| {
        std.log.info("Loaded shader from CWD: {s}", .{rel_path});
        return bytes;
    } else |e| last_err = e;

    // 4) CWD/assets/<rel_path>
    if (std.fs.path.join(allocator, &.{ "assets", rel_path }) catch null) |rel_assets| {
        defer allocator.free(rel_assets);
        if (readAlignedFromCwd2(allocator, rel_assets)) |bytes| {
            std.log.info("Loaded shader from CWD assets: {s}", .{rel_assets});
            return bytes;
        } else |e| last_err = e;
    }

    return last_err;
}

fn loadConfig(_: std.mem.Allocator) Config {
    // TODO: optionally read JSON/TOML later; defaults are fine for now.
    return .{};
}

// ──────────────────────────────────────────────────────────────────────────────
// Vulkan helpers (pipeline, pass, framebuffers, copies)
fn createPipeline(gc: *const GraphicsContext, layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
    const A = std.heap.c_allocator;

    const want_vert = if (FORCE_DEBUG_FLAT_SHADERS) "shaders/DEBUG_flat.vert.spv" else "shaders/basic_lit.vert.spv";
    const want_frag = if (FORCE_DEBUG_FLAT_SHADERS) "shaders/DEBUG_flat.frag.spv" else "shaders/basic_lit.frag.spv";

    const vert_bytes = try loadShaderBytes(A, want_vert);
    defer A.free(vert_bytes);
    const frag_bytes = try loadShaderBytes(A, want_frag);
    defer A.free(frag_bytes);

    if (!FORCE_DEBUG_FLAT_SHADERS) {
        if (vert_bytes.len < 64 or frag_bytes.len < 64) return error.BadShaderAssets;
    }

    const vert = try gc.vkd.createShaderModule(gc.dev, &vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = vert_bytes.len,
        .p_code = @as([*]const u32, @ptrCast(@alignCast(vert_bytes.ptr))),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, vert, null);

    const frag = try gc.vkd.createShaderModule(gc.dev, &vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = frag_bytes.len,
        .p_code = @as([*]const u32, @ptrCast(@alignCast(frag_bytes.ptr))),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .flags = .{}, .stage = .{ .vertex_bit = true }, .module = vert, .p_name = "main", .p_specialization_info = null },
        .{ .flags = .{}, .stage = .{ .fragment_bit = true }, .module = frag, .p_name = "main", .p_specialization_info = null },
    };

    comptime {
        if (Vertex.attribute_description.len != 3)
            @compileError("Vertex must expose 3 attributes: pos(0), normal(1), color(2).");
    }

    const instance_binding = vk.VertexInputBindingDescription{
        .binding = 1,
        .stride = @sizeOf(Instance),
        .input_rate = .instance,
    };

    const bindings = [_]vk.VertexInputBindingDescription{
        Vertex.binding_description, // binding 0
        instance_binding, // binding 1
    };

    const a_v0 = Vertex.attribute_description[0];
    const a_v1 = Vertex.attribute_description[1];
    const a_v2 = Vertex.attribute_description[2];

    const attrs = [_]vk.VertexInputAttributeDescription{
        a_v0,                                                                           a_v1,                                                                                                               a_v2,
        .{ .location = 3, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = 0 },  .{ .location = 4, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = 16 },                                     .{ .location = 5, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = 32 },
        .{ .location = 6, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = 48 }, .{ .location = 7, .binding = 1, .format = .r32g32b32a32_sfloat, .offset = @intCast(@offsetOf(Instance, "color")) },
    };

    const vi = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = @intCast(bindings.len),
        .p_vertex_binding_descriptions = &bindings,
        .vertex_attribute_description_count = @intCast(attrs.len),
        .p_vertex_attribute_descriptions = &attrs,
    };

    const ia = vk.PipelineInputAssemblyStateCreateInfo{ .flags = .{}, .topology = .triangle_list, .primitive_restart_enable = VK_FALSE32 };
    const vp = vk.PipelineViewportStateCreateInfo{ .flags = .{}, .viewport_count = 1, .p_viewports = undefined, .scissor_count = 1, .p_scissors = undefined };

    // Positive viewport height everywhere; standard front face.
    const rs = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = VK_FALSE32,
        .rasterizer_discard_enable = VK_FALSE32,
        .polygon_mode = .fill,
        .cull_mode = .{}, // disabled while iterating; safe default
        .front_face = .counter_clockwise,
        .depth_bias_enable = VK_FALSE32,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const ms = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = VK_FALSE32,
        .min_sample_shading = 1,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = VK_FALSE32,
        .alpha_to_one_enable = VK_FALSE32,
    };

    const ds = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = if (DEBUG_DISABLE_DEPTH) VK_FALSE32 else VK_TRUE32,
        .depth_write_enable = if (DEBUG_DISABLE_DEPTH) VK_FALSE32 else VK_TRUE32,
        .depth_compare_op = .less,
        .depth_bounds_test_enable = VK_FALSE32,
        .stencil_test_enable = VK_FALSE32,
        .front = .{ .fail_op = .keep, .pass_op = .keep, .depth_fail_op = .keep, .compare_op = .always, .compare_mask = 0, .write_mask = 0, .reference = 0 },
        .back = .{ .fail_op = .keep, .pass_op = .keep, .depth_fail_op = .keep, .compare_op = .always, .compare_mask = 0, .write_mask = 0, .reference = 0 },
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };

    const blend_att = vk.PipelineColorBlendAttachmentState{
        .blend_enable = VK_FALSE32,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
    const blend = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = VK_FALSE32,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @as([*]const vk.PipelineColorBlendAttachmentState, @ptrCast(&blend_att)),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dyn = [_]vk.DynamicState{ .viewport, .scissor };
    const dyn_state = vk.PipelineDynamicStateCreateInfo{ .flags = .{}, .dynamic_state_count = @intCast(dyn.len), .p_dynamic_states = &dyn };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &stages,
        .p_vertex_input_state = &vi,
        .p_input_assembly_state = &ia,
        .p_tessellation_state = null,
        .p_viewport_state = &vp,
        .p_rasterization_state = &rs,
        .p_multisample_state = &ms,
        .p_depth_stencil_state = &ds,
        .p_color_blend_state = &blend,
        .p_dynamic_state = &dyn_state,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.vkd.createGraphicsPipelines(
        gc.dev,
        .null_handle,
        1,
        @as([*]const vk.GraphicsPipelineCreateInfo, @ptrCast(&gpci)),
        null,
        @as([*]vk.Pipeline, @ptrCast(&pipeline)),
    );
    return pipeline;
}

fn createFramebuffers(gc: *const GraphicsContext, allocator: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain, depth_view: vk.ImageView) ![]vk.Framebuffer {
    const fbs = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(fbs);

    var i: usize = 0;
    errdefer for (fbs[0..i]) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);

    for (fbs) |*fb| {
        const attachments = [_]vk.ImageView{ swapchain.swap_images[i].view, depth_view };
        fb.* = try gc.vkd.createFramebuffer(gc.dev, &vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = @intCast(attachments.len),
            .p_attachments = &attachments,
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return fbs;
}

fn destroyFramebuffers(gc: *const GraphicsContext, allocator: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);
    allocator.free(framebuffers);
}

fn createRenderPass(gc: *const GraphicsContext, swapchain: Swapchain, depth_format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = swapchain.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const depth_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = depth_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .dont_care,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .depth_stencil_attachment_optimal,
    };

    const color_ref = vk.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth_ref = vk.AttachmentReference{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };

    const subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_ref),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = @ptrCast(&depth_ref),
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    const attachments = [_]vk.AttachmentDescription{ color_attachment, depth_attachment };

    const deps = [_]vk.SubpassDependency{
        .{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
            .dependency_flags = .{},
        },
        .{
            .src_subpass = 0,
            .dst_subpass = vk.SUBPASS_EXTERNAL,
            .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
            .dst_access_mask = .{},
            .dependency_flags = .{},
        },
    };

    return try gc.vkd.createRenderPass(gc.dev, &vk.RenderPassCreateInfo{
        .flags = .{},
        .attachment_count = @intCast(attachments.len),
        .p_attachments = &attachments,
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = @intCast(deps.len),
        .p_dependencies = &deps,
    }, null);
}

fn copyBuffer(gc: *const GraphicsContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.vkd.allocateCommandBuffers(gc.dev, &vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.vkd.freeCommandBuffers(gc.dev, pool, 1, @ptrCast(&cmdbuf));

    try gc.vkd.beginCommandBuffer(cmdbuf, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const region = vk.BufferCopy{ .src_offset = 0, .dst_offset = 0, .size = size };
    gc.vkd.cmdCopyBuffer(cmdbuf, src, dst, 1, @ptrCast(&region));

    try gc.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };

    try gc.vkd.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.vkd.queueWaitIdle(gc.graphics_queue.handle);
}

// ──────────────────────────────────────────────────────────────────────────────
// Main
pub fn main() !void {
    _ = glfw.setErrorCallback(errorCallback);
    try glfw.init();
    defer glfw.terminate();

    CONFIG = loadConfig(std.heap.c_allocator);
    if (CONFIG.debug_no_draw) {
        std.log.warn("CONFIG.debug_no_draw=true → draw calls are skipped", .{});
    }

    var extent = vk.Extent2D{ .width = 1280, .height = 800 };
    glfw.defaultWindowHints();
    glfw.windowHint(glfw.c.GLFW_CLIENT_API, glfw.c.GLFW_NO_API);

    if (glfw.getPrimaryMonitor()) |mon| {
        const wa = glfw.getMonitorWorkarea(mon);
        if (wa.width > 0 and wa.height > 0) {
            extent.width = @intCast(@divTrunc(wa.width * 3, 4));
            extent.height = @intCast(@divTrunc(wa.height * 3, 4));
        } else if (glfw.getVideoMode(mon)) |vm| {
            extent.width = @intCast(@divTrunc(vm.width * 3, 4));
            extent.height = @intCast(@divTrunc(vm.height * 3, 4));
        }
    }

    const window = try glfw.createWindow(@as(i32, @intCast(extent.width)), @as(i32, @intCast(extent.height)), window_title_cstr, null, null);
    defer glfw.destroyWindow(window);

    installScroll(window);
    defer restoreScroll(window);

    {
        const pos = glfw.getWindowPos(window);
        const sz = glfw.getWindowSize(window);
        WindowState.saved_x = pos.x;
        WindowState.saved_y = pos.y;
        WindowState.saved_w = sz.width;
        WindowState.saved_h = sz.height;
    }

    waitForNonZeroFramebuffer(window);

    const fb = glfw.getFramebufferSize(window);
    extent.width = @intCast(@max(@as(i32, 1), fb.width));
    extent.height = @intCast(@max(@as(i32, 1), fb.height));

    const A = std.heap.c_allocator;

    var gc = try GraphicsContext.init(A, window_title_cstr, window);
    defer gc.deinit();

    const props = gc.vki.getPhysicalDeviceProperties(gc.pdev);
    std.log.info("GPU: {s} | API {d}.{d}.{d}", .{
        std.mem.sliceTo(&props.device_name, 0),
        (props.api_version >> 22) & 0x3ff,
        (props.api_version >> 12) & 0x3ff,
        props.api_version & 0xfff,
    });
    if (props.device_type == .cpu) std.log.err("Selected CPU/WARP device — this will be extremely slow.", .{});
    std.log.info("Queues: graphics_family={d}, present_family={d}", .{ gc.graphics_queue.family, gc.present_queue.family });
    std.log.info("Y-Flip: VIEWPORT_Y_FLIP={}, PROJECTION_Y_FLIP={}", .{ VIEWPORT_Y_FLIP, PROJECTION_Y_FLIP });

    var swapchain = try Swapchain.init(&gc, A, extent);
    defer swapchain.deinit();

    std.log.info("Swapchain: extent={d}x{d} | format={s} | present_mode={s} | images={d} | first index={d}", .{
        swapchain.extent.width,                    swapchain.extent.height,
        @tagName(swapchain.surface_format.format), @tagName(swapchain.present_mode),
        swapchain.swap_images.len,                 swapchain.image_index,
    });

    // Depth
    const depth_format: vk.Format = try depth.chooseDepthFormat(gc.vki, gc.pdev);
    const mem_props = gc.vki.getPhysicalDeviceMemoryProperties(gc.pdev);

    var depth_res = try depth.createDepthResources(gc.vkd, gc.dev, .{
        .extent = swapchain.extent,
        .memory_props = mem_props,
        .format = depth_format,
        .sample_count = .{ .@"1_bit" = true },
        .allocator = null,
    });
    defer depth_res.destroy(gc.vkd, gc.dev, null);

    // Descriptor set layout (set=0).
    const ubo_binding_index: u32 = 0;
    const sampler_binding_index: u32 = 1;

    const ubo_binding = vk.DescriptorSetLayoutBinding{
        .binding = ubo_binding_index,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .p_immutable_samplers = null,
    };
    const sampler_binding = vk.DescriptorSetLayoutBinding{
        .binding = sampler_binding_index,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment_bit = true },
        .p_immutable_samplers = null,
    };
    const dsl_bindings = [_]vk.DescriptorSetLayoutBinding{ ubo_binding, sampler_binding };

    const dsl = try gc.vkd.createDescriptorSetLayout(gc.dev, &vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = @intCast(dsl_bindings.len),
        .p_bindings = &dsl_bindings,
    }, null);
    defer gc.vkd.destroyDescriptorSetLayout(gc.dev, dsl, null);

    // Pipeline layout
    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &vk.PipelineLayoutCreateInfo{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&dsl),
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(&gc, swapchain, depth_format);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    const pipeline = try createPipeline(&gc, pipeline_layout, render_pass);
    defer gc.vkd.destroyPipeline(gc.dev, pipeline, null);

    var framebuffers = try createFramebuffers(&gc, A, render_pass, swapchain, depth_res.view);
    defer destroyFramebuffers(&gc, A, framebuffers);

    // Command pool
    const cmd_pool = try gc.vkd.createCommandPool(gc.dev, &vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.vkd.destroyCommandPool(gc.dev, cmd_pool, null);

    // Static geometry buffer (device-local) + staging
    const vbuf = try gc.vkd.createBuffer(gc.dev, &vk.BufferCreateInfo{
        .flags = .{},
        .size = VERTEX_BUFFER_SIZE,
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer gc.vkd.destroyBuffer(gc.dev, vbuf, null);

    const vreqs = gc.vkd.getBufferMemoryRequirements(gc.dev, vbuf);
    const vmem = try gc.allocate(vreqs, .{ .device_local_bit = true });
    defer gc.vkd.freeMemory(gc.dev, vmem, null);
    try gc.vkd.bindBufferMemory(gc.dev, vbuf, vmem, 0);

    const sbuf = try gc.vkd.createBuffer(gc.dev, &vk.BufferCreateInfo{
        .flags = .{},
        .size = VERTEX_BUFFER_SIZE,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer gc.vkd.destroyBuffer(gc.dev, sbuf, null);

    const sreqs = gc.vkd.getBufferMemoryRequirements(gc.dev, sbuf);
    const smem = try gc.allocate(sreqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.vkd.freeMemory(gc.dev, smem, null);
    try gc.vkd.bindBufferMemory(gc.dev, sbuf, smem, 0);

    {
        const ptr = try gc.vkd.mapMemory(gc.dev, smem, 0, vk.WHOLE_SIZE, .{});
        defer gc.vkd.unmapMemory(gc.dev, smem);
        const verts: [*]Vertex = @ptrCast(@alignCast(ptr));
        writeFloorWorld(verts[0..FLOOR_VERTS]);
        writeUnitCube(verts[FLOOR_VERTS..(FLOOR_VERTS + CUBE_VERTS)]);
        try copyBuffer(&gc, cmd_pool, vbuf, sbuf, VERTEX_BUFFER_SIZE);
    }

    // Per-image (triple-buffered) instance + UBO buffers and descriptor sets
    const image_count: usize = swapchain.swap_images.len;

    var ibufs = try A.alloc(vk.Buffer, image_count);
    defer {
        for (ibufs) |b| gc.vkd.destroyBuffer(gc.dev, b, null);
        A.free(ibufs);
    }

    var imems = try A.alloc(vk.DeviceMemory, image_count);
    defer {
        for (imems) |m| gc.vkd.freeMemory(gc.dev, m, null);
        A.free(imems);
    }

    var instances_ptrs = try A.alloc([*]Instance, image_count);
    defer A.free(instances_ptrs);

    var ubo_bufs = try A.alloc(vk.Buffer, image_count);
    defer {
        for (ubo_bufs) |b| gc.vkd.destroyBuffer(gc.dev, b, null);
        A.free(ubo_bufs);
    }

    var ubo_mems = try A.alloc(vk.DeviceMemory, image_count);
    defer {
        for (ubo_mems) |m| gc.vkd.freeMemory(gc.dev, m, null);
        A.free(ubo_mems);
    }

    var ubo_views = try A.alloc(*SceneUBO, image_count);
    defer A.free(ubo_views);

    const per_ibuf_size: vk.DeviceSize = @sizeOf(Instance) * @as(vk.DeviceSize, @intCast(CUBE_INSTANCES));
    const ubo_size: vk.DeviceSize = @sizeOf(SceneUBO);

    for (0..image_count) |i| {
        // Instance buffer
        ibufs[i] = try gc.vkd.createBuffer(gc.dev, &vk.BufferCreateInfo{
            .flags = .{},
            .size = per_ibuf_size,
            .usage = .{ .vertex_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        }, null);

        const ireqs = gc.vkd.getBufferMemoryRequirements(gc.dev, ibufs[i]);
        imems[i] = try gc.allocate(ireqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        try gc.vkd.bindBufferMemory(gc.dev, ibufs[i], imems[i], 0);

        const iptr = try gc.vkd.mapMemory(gc.dev, imems[i], 0, vk.WHOLE_SIZE, .{});
        instances_ptrs[i] = @ptrCast(@alignCast(iptr));

        // UBO
        ubo_bufs[i] = try gc.vkd.createBuffer(gc.dev, &vk.BufferCreateInfo{
            .flags = .{},
            .size = ubo_size,
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        }, null);

        const ureqs = gc.vkd.getBufferMemoryRequirements(gc.dev, ubo_bufs[i]);
        ubo_mems[i] = try gc.allocate(ureqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        try gc.vkd.bindBufferMemory(gc.dev, ubo_bufs[i], ubo_mems[i], 0);

        const uptr = try gc.vkd.mapMemory(gc.dev, ubo_mems[i], 0, vk.WHOLE_SIZE, .{});
        ubo_views[i] = @ptrCast(@alignCast(uptr));
    }

    // Descriptor pool & per-image descriptor sets
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .combined_image_sampler, .descriptor_count = @intCast(image_count) },
        .{ .type = .uniform_buffer, .descriptor_count = @intCast(image_count) },
    };
    const desc_pool = try gc.vkd.createDescriptorPool(gc.dev, &vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = @intCast(image_count),
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = &pool_sizes,
    }, null);
    defer gc.vkd.destroyDescriptorPool(gc.dev, desc_pool, null);

    var sets = try A.alloc(vk.DescriptorSet, image_count);
    defer A.free(sets);

    var set_layouts = try A.alloc(vk.DescriptorSetLayout, image_count);
    defer A.free(set_layouts);
    for (0..image_count) |i| set_layouts[i] = dsl;

    try gc.vkd.allocateDescriptorSets(gc.dev, &vk.DescriptorSetAllocateInfo{
        .descriptor_pool = desc_pool,
        .descriptor_set_count = @intCast(image_count),
        .p_set_layouts = set_layouts.ptr,
    }, sets.ptr);

    // Default texture (checkerboard) for now
    var default_tex = try texture.createCheckerboard(&gc, A, 512, 32);
    defer default_tex.destroy(gc.vkd, gc.dev, null);

    for (0..image_count) |i| {
        const img_info = vk.DescriptorImageInfo{
            .sampler = default_tex.sampler,
            .image_view = default_tex.view,
            .image_layout = .shader_read_only_optimal,
        };
        const ubo_info = vk.DescriptorBufferInfo{
            .buffer = ubo_bufs[i],
            .offset = 0,
            .range = ubo_size,
        };

        const img_infos = [_]vk.DescriptorImageInfo{img_info};
        const ubo_infos = [_]vk.DescriptorBufferInfo{ubo_info};

        const writes = [_]vk.WriteDescriptorSet{
            .{
                .dst_set = sets[i],
                .dst_binding = ubo_binding_index,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_image_info = undefined,
                .p_buffer_info = ubo_infos[0..].ptr,
                .p_texel_buffer_view = undefined,
            },
            .{
                .dst_set = sets[i],
                .dst_binding = sampler_binding_index,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .p_image_info = img_infos[0..].ptr,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        };

        gc.vkd.updateDescriptorSets(gc.dev, @intCast(writes.len), @ptrCast(&writes), 0, undefined);
    }

    // Command buffers (per-image)
    var cmdbufs = blk: {
        var bufs = try A.alloc(vk.CommandBuffer, framebuffers.len);
        errdefer A.free(bufs);
        try gc.vkd.allocateCommandBuffers(gc.dev, &vk.CommandBufferAllocateInfo{
            .command_pool = cmd_pool,
            .level = .primary,
            .command_buffer_count = @intCast(bufs.len),
        }, bufs.ptr);
        break :blk bufs;
    };
    defer {
        if (cmdbufs.len != 0) {
            gc.vkd.freeCommandBuffers(gc.dev, cmd_pool, @intCast(cmdbufs.len), cmdbufs.ptr);
            A.free(cmdbufs);
        }
    }

    // Camera
    var camera = Camera3D.init(
        Vec3.init(0.0, 1.7, 4.0),
        @floatCast(std.math.degreesToRadians(CONFIG.fov_deg)),
        @as(f32, @floatFromInt(swapchain.extent.width)) / @as(f32, @floatFromInt(swapchain.extent.height)),
        0.1,
        500.0,
    );

    var frame_timer = FrameTimer.init(nowMsFromGlfw(), 1000);

    var orbit_enabled: bool = false;
    var orbit: Orbit.OrbitState = .{};

    scatterInstances(0xCAFEBABE1234_5678);

    std.log.info("Entering main loop…", .{});

    var frame_count: u64 = 0;

    while (!glfw.windowShouldClose(window)) {
        const img_index = swapchain.image_index;
        const cur_img = swapchain.currentSwapImage();
        try cur_img.*.waitForFence(&gc);

        const tick = frame_timer.tick(nowMsFromGlfw());
        const raw_dt = @as(f32, @floatCast(tick.dt));
        var move_dt = raw_dt * CONFIG.base_move_speed_scale;

        const lshift = glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_SHIFT);
        const rshift = glfw.getKey(window, glfw.c.GLFW_KEY_RIGHT_SHIFT);
        const sprinting = (lshift != glfw.c.GLFW_RELEASE) or (rshift != glfw.c.GLFW_RELEASE);
        if (sprinting) move_dt *= CONFIG.sprint_mult;

        handleFullscreenShortcuts(window);
        const esc = glfw.getKey(window, glfw.c.GLFW_KEY_ESCAPE);
        if (esc == glfw.c.GLFW_PRESS or esc == glfw.c.GLFW_REPEAT) glfw.setWindowShouldClose(window, true);

        if (glfw.getKey(window, glfw.c.GLFW_KEY_R) == glfw.c.GLFW_PRESS) {
            scatterInstances(0xCAFEBABE1234_5678);
        }

        const okey = glfw.getKey(window, glfw.c.GLFW_KEY_O) == glfw.c.GLFW_PRESS;
        const OToggle = struct {
            var prev: bool = false;
        };
        if (okey and !OToggle.prev) {
            orbit_enabled = !orbit_enabled;

            if (orbit_enabled) {
                var vptmp = camera.viewProjMatrix();
                if (PROJECTION_Y_FLIP) vptmp.m[5] = -vptmp.m[5];
                const cfg = Orbit.OrbitConfig{
                    .yaw_sens = CONFIG.orbit_yaw_sens,
                    .pitch_sens = CONFIG.orbit_pitch_sens,
                    .dolly_wheel = CONFIG.orbit_dolly_wheel,
                    .min_radius = CONFIG.orbit_min_radius,
                    .max_radius = CONFIG.orbit_max_radius,
                    .max_pitch_deg = CONFIG.max_pitch_deg,
                };
                orbit.pickTargetFromVP(vptmp.m, cfg);
                std.log.info("Orbit: ON", .{});
            } else {
                std.log.info("Orbit: OFF", .{});
            }
        }
        OToggle.prev = okey;

        const rmb_down = (glfw.getMouseButton(window, glfw.c.GLFW_MOUSE_BUTTON_RIGHT) == glfw.c.GLFW_PRESS);
        const became_down = rmb_down and !MouseLatch.rmb_was_down;
        const became_up = !rmb_down and MouseLatch.rmb_was_down;
        MouseLatch.rmb_was_down = rmb_down;

        if (became_down and !InputState.raw_mouse_checked) {
            InputState.raw_mouse_checked = true;
            if (CONFIG.enable_raw_mouse and glfw.rawMouseMotionSupported()) {
                glfw.setInputMode(window, glfw.c.GLFW_RAW_MOUSE_MOTION, glfw.c.GLFW_TRUE);
                InputState.raw_mouse_enabled = true;
                std.log.info("Raw mouse: ENABLED", .{});
            } else {
                std.log.info("Raw mouse: NOT SUPPORTED on this platform", .{});
            }
        }

        if (became_down) {
            glfw.setInputMode(window, glfw.c.GLFW_CURSOR, glfw.c.GLFW_CURSOR_DISABLED);
            InputState.just_locked = true;
            LookState.have_prev = false;
            LookState.filt_dx = 0;
            LookState.filt_dy = 0;
        }
        if (became_up) {
            glfw.setInputMode(window, glfw.c.GLFW_CURSOR, glfw.c.GLFW_CURSOR_NORMAL);
        }

        const cin = sampleCameraInput(window, rmb_down, raw_dt);

        if (orbit_enabled) {
            const wheel = @as(f32, @floatCast(Scroll.dy));
            if (wheel != 0) {
                const factor = std.math.pow(f32, CONFIG.orbit_dolly_wheel, -wheel);
                const r = orbit.radius * factor;
                orbit.radius = @max(CONFIG.orbit_min_radius, @min(CONFIG.orbit_max_radius, r));
                Scroll.dy = 0;
            }
        }

        camera.update(move_dt, cin);

        // Build Scene UBO for THIS image
        var vp = camera.viewProjMatrix();
        if (PROJECTION_Y_FLIP) vp.m[5] = -vp.m[5];

        const time_sec: f32 = @floatCast(glfw.getTime());
        const light_dir = [4]f32{ 0.4, 1.0, 0.3, 0.0 };
        const light_color = [4]f32{ 1.0, 0.97, 0.92, 0.0 };
        const ambient = [4]f32{ 0.16, 0.17, 0.19, 0.0 };

        ubo_views[img_index].* = .{
            .vp = vp.m,
            .light_dir = light_dir,
            .light_color = light_color,
            .ambient = ambient,
            .time = time_sec,
            ._pad = .{ 0, 0, 0 },
        };

        // Instance 0 = floor (identity model)
        instances_ptrs[img_index][0] = .{
            .model = Mat4.identity().m,
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
        };

        // Fill cubes starting at instance slot 1
        const visible_count = buildVisibleInstances(
            vp.m,
            time_sec,
            instances_ptrs[img_index] + 1,
            CUBE_INSTANCES - 1,
        );

        // Explicit flush helps on some stacks (even with HOST_COHERENT)
        {
            const ranges = [_]vk.MappedMemoryRange{
                .{ .memory = ubo_mems[img_index], .offset = 0, .size = vk.WHOLE_SIZE },
                .{ .memory = imems[img_index], .offset = 0, .size = vk.WHOLE_SIZE },
            };
            try gc.vkd.flushMappedMemoryRanges(gc.dev, @intCast(ranges.len), &ranges);
        }

        if (tick.fps_updated) {
            var buf_title: [200]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &buf_title,
                "{s} | FPS: {d:.1} | vis:{d}",
                .{ window_title_base, tick.fps, visible_count },
            ) catch null;
            if (title) |z| glfw.setWindowTitle(window, z);
        }

        const cmdbuf = cmdbufs[img_index];
        try gc.vkd.resetCommandBuffer(cmdbuf, .{});
        try gc.vkd.beginCommandBuffer(cmdbuf, &vk.CommandBufferBeginInfo{ .flags = .{}, .p_inheritance_info = null });

        const fb_extent = swapchain.extent;

        // Positive height everywhere (no negative viewport).
        var viewport = vk.Viewport{
            .x = 0,
            .y = if (VIEWPORT_Y_FLIP)
                @as(f32, @floatFromInt(fb_extent.height))
            else
                0,
            .width = @as(f32, @floatFromInt(fb_extent.width)),
            .height = if (VIEWPORT_Y_FLIP)
                -@as(f32, @floatFromInt(fb_extent.height))
            else
                @as(f32, @floatFromInt(fb_extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        };

        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = fb_extent };

        const clear_color = vk.ClearValue{ .color = .{ .float_32 = .{ 0.05, 0.05, 0.07, 1.0 } } };
        const clear_depth = vk.ClearValue{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } };
        var clears = [_]vk.ClearValue{ clear_color, clear_depth };

        const rp_begin = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffers[img_index],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = fb_extent },
            .clear_value_count = @intCast(clears.len),
            .p_clear_values = &clears,
        };
        gc.vkd.cmdBeginRenderPass(cmdbuf, &rp_begin, vk.SubpassContents.@"inline");

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);
        gc.vkd.cmdSetViewport(cmdbuf, 0, 1, @as([*]const vk.Viewport, @ptrCast(&viewport)));
        gc.vkd.cmdSetScissor(cmdbuf, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&scissor)));

        const bufs = [_]vk.Buffer{ vbuf, ibufs[img_index] };
        const offs = [_]vk.DeviceSize{ 0, 0 };
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, bufs.len, &bufs, &offs);
        gc.vkd.cmdBindDescriptorSets(cmdbuf, .graphics, pipeline_layout, 0, 1, @ptrCast(&sets[img_index]), 0, undefined);

        if (!CONFIG.debug_no_draw) {
            gc.vkd.cmdDraw(cmdbuf, FLOOR_VERTS, 1, 0, 0);
            if (visible_count > 0) {
                gc.vkd.cmdDraw(cmdbuf, CUBE_VERTS, @intCast(visible_count), FLOOR_VERTS, 1);
            }
        }

        gc.vkd.cmdEndRenderPass(cmdbuf);

        try gc.vkd.endCommandBuffer(cmdbuf);

        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            error.DeviceLost => blk: {
                std.log.err("Present returned DEVICE_LOST (frame {d})", .{frame_count});
                break :blk Swapchain.PresentState.suboptimal;
            },
            else => |narrow| return narrow,
        };

        if (state == .suboptimal) {
            waitForNonZeroFramebuffer(window);
            const fb2 = glfw.getFramebufferSize(window);
            extent.width = @intCast(@max(@as(i32, 1), fb2.width));
            extent.height = @intCast(@max(@as(i32, 1), fb2.height));

            if (extent.width == 0 or extent.height == 0) {
                glfw.pollEvents();
                continue;
            }

            if (extent.width > 0 and extent.height > 0) {
                swapchain.recreate(extent) catch |e| switch (e) {
                    error.InvalidSurfaceDimensions => {
                        glfw.pollEvents();
                        continue;
                    },
                    else => |fatal| return fatal,
                };

                std.log.info("Recreated swapchain: extent={d}x{d} images={d} first index={d}", .{ swapchain.extent.width, swapchain.extent.height, swapchain.swap_images.len, swapchain.image_index });

                const new_aspect: f32 = @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height));
                if (comptime @hasField(@TypeOf(camera), "aspect")) camera.aspect = new_aspect;

                destroyFramebuffers(&gc, A, framebuffers);
                depth_res.destroy(gc.vkd, gc.dev, null);
                depth_res = try depth.createDepthResources(gc.vkd, gc.dev, .{
                    .extent = swapchain.extent,
                    .memory_props = mem_props,
                    .format = depth_format,
                    .sample_count = .{ .@"1_bit" = true },
                    .allocator = null,
                });
                framebuffers = try createFramebuffers(&gc, A, render_pass, swapchain, depth_res.view);

                gc.vkd.freeCommandBuffers(gc.dev, cmd_pool, @intCast(cmdbufs.len), cmdbufs.ptr);
                A.free(cmdbufs);

                cmdbufs = blk2: {
                    var new_cmd_bufs = try A.alloc(vk.CommandBuffer, framebuffers.len);
                    errdefer A.free(new_cmd_bufs);
                    try gc.vkd.allocateCommandBuffers(
                        gc.dev,
                        &vk.CommandBufferAllocateInfo{
                            .command_pool = cmd_pool,
                            .level = .primary,
                            .command_buffer_count = @intCast(new_cmd_bufs.len),
                        },
                        new_cmd_bufs.ptr,
                    );
                    break :blk2 new_cmd_bufs;
                };
            }
        }

        frame_count += 1;
        glfw.pollEvents();
    }

    try swapchain.waitForAllFences();
}

// ──────────────────────────────────────────────────────────────────────────────
// GLFW helpers (error, wait, fullscreen)
fn nowMsFromGlfw() i64 {
    return @as(i64, @intFromFloat(glfw.getTime() * 1000.0));
}

fn errorCallback(err_code: c_int, desc: [*c]const u8) callconv(.c) void {
    var msg: []const u8 = "no description";
    if (desc) |p| {
        const z: [*:0]const u8 = @ptrCast(p);
        msg = std.mem.span(z);
    }
    if (glfw.errorCodeFromC(err_code)) |e| {
        std.log.err("GLFW error {s} ({d}): {s}", .{ @tagName(e), err_code, msg });
    } else {
        std.log.err("GLFW error code: {d}: {s}", .{ err_code, msg });
    }
}

fn waitForNonZeroFramebuffer(window: *glfw.Window) void {
    const deadline = nowMsFromGlfw() + 250;
    while (true) {
        const fb = glfw.getFramebufferSize(window);
        if (fb.width > 0 and fb.height > 0) break;
        glfw.pollEvents();
        if (nowMsFromGlfw() >= deadline) break;
    }
}

fn toggleFullscreen(window: *glfw.Window) void {
    if (!WindowState.fullscreen) {
        const pos = glfw.getWindowPos(window);
        const sz = glfw.getWindowSize(window);
        WindowState.saved_x = pos.x;
        WindowState.saved_y = pos.y;
        WindowState.saved_w = sz.width;
        WindowState.saved_h = sz.height;

        const mon = glfw.getPrimaryMonitor() orelse return;
        const mode = glfw.getVideoMode(mon) orelse return;
        glfw.setWindowMonitor(window, mon, 0, 0, mode.width, mode.height, mode.refresh_rate);
        WindowState.fullscreen = true;
    } else {
        glfw.setWindowMonitor(
            window,
            null,
            WindowState.saved_x,
            WindowState.saved_y,
            WindowState.saved_w,
            WindowState.saved_h,
            0,
        );
        WindowState.fullscreen = false;
    }
}

fn handleFullscreenShortcuts(window: *glfw.Window) void {
    const Latch = struct {
        var altenter: bool = false;
        var f11: bool = false;
        var cmdctrlf: bool = false;
    };

    var toggle = false;

    if (CONFIG.allow_alt_enter) {
        const alt = (glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_ALT) == glfw.c.GLFW_PRESS) or
            (glfw.getKey(window, glfw.c.GLFW_KEY_RIGHT_ALT) == glfw.c.GLFW_PRESS);
        const enter = glfw.getKey(window, glfw.c.GLFW_KEY_ENTER) == glfw.c.GLFW_PRESS;
        const down = alt and enter;
        if (down and !Latch.altenter) toggle = true;
        Latch.altenter = down;
    }

    if (CONFIG.allow_f11) {
        const down = glfw.getKey(window, glfw.c.GLFW_KEY_F11) == glfw.c.GLFW_PRESS;
        if (down and !Latch.f11) toggle = true;
        Latch.f11 = down;
    }

    if (CONFIG.allow_cmd_ctrl_f_mac) {
        const cmd = (glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_SUPER) == glfw.c.GLFW_PRESS) or
            (glfw.getKey(window, glfw.c.GLFW_KEY_RIGHT_SUPER) == glfw.c.GLFW_PRESS);
        const ctrl = (glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_CONTROL) == glfw.c.GLFW_PRESS) or
            (glfw.getKey(window, glfw.c.GLFW_KEY_RIGHT_CONTROL) == glfw.c.GLFW_PRESS);
        const f = glfw.getKey(window, glfw.c.GLFW_KEY_F) == glfw.c.GLFW_PRESS;
        const down = cmd and ctrl and f;
        if (down and !Latch.cmdctrlf) toggle = true;
        Latch.cmdctrlf = down;
    }

    if (toggle) toggleFullscreen(window);
}

// Input sampling
fn sampleCameraInput(window: *glfw.Window, look_active: bool, dt: f32) CameraInput {
    var ci: CameraInput = .{};

    // Movement keys
    if (glfw.getKey(window, glfw.c.GLFW_KEY_W) != glfw.c.GLFW_RELEASE) ci.move_forward = true;
    if (glfw.getKey(window, glfw.c.GLFW_KEY_S) != glfw.c.GLFW_RELEASE) ci.move_backward = true;
    if (glfw.getKey(window, glfw.c.GLFW_KEY_A) != glfw.c.GLFW_RELEASE) ci.move_left = true;
    if (glfw.getKey(window, glfw.c.GLFW_KEY_D) != glfw.c.GLFW_RELEASE) ci.move_right = true;
    if (glfw.getKey(window, glfw.c.GLFW_KEY_SPACE) != glfw.c.GLFW_RELEASE) ci.move_up = true;
    if (glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_CONTROL) != glfw.c.GLFW_RELEASE) ci.move_down = true;

    if (!look_active) {
        LookState.have_prev = false;
        return ci;
    }

    // Raw mouse → filtered, “human-like” deltas
    const raw = glfw.getCursorPos(window);
    const pos = [2]f64{ raw.x, raw.y };

    // Skip first frame after lock to avoid giant jump
    if (InputState.just_locked or !LookState.have_prev) {
        LookState.have_prev = true;
        LookState.prev_pos = pos;
        InputState.just_locked = false;
        return ci;
    }

    const dx_px = pos[0] - LookState.prev_pos[0];
    const dy_px = pos[1] - LookState.prev_pos[1];
    LookState.prev_pos = pos;

    const a = smoothingAlpha(CONFIG.look_smooth_halflife_ms, dt);
    LookState.filt_dx += a * (@as(f32, @floatCast(dx_px)) - LookState.filt_dx);
    LookState.filt_dy += a * (@as(f32, @floatCast(dy_px)) - LookState.filt_dy);

    const lx = applyExpo(LookState.filt_dx * CONFIG.mouse_sens, CONFIG.look_expo);
    var ly = applyExpo(LookState.filt_dy * CONFIG.mouse_sens, CONFIG.look_expo);
    if (CONFIG.invert_y) ly = -ly;

    ci.look_delta_x = lx;
    ci.look_delta_y = ly;
    return ci;
}

// ── Sanity test (projection flip only on macOS)
test "platform Y-flip policy" {
    if (IS_MAC) {
        try std.testing.expect(VIEWPORT_Y_FLIP == true);
        try std.testing.expect(PROJECTION_Y_FLIP == false);
    } else {
        try std.testing.expect(VIEWPORT_Y_FLIP == false);
        try std.testing.expect(PROJECTION_Y_FLIP == true);
    }
}
