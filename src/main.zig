const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const vk = @import("vulkan");
const depth = @import("graphics/depth.zig");

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

const Allocator = std.mem.Allocator;

const IS_MAC = builtin.os.tag == .macos;

const VK_FALSE32: vk.Bool32 = @enumFromInt(vk.FALSE);
const VK_TRUE32: vk.Bool32 = @enumFromInt(vk.TRUE);

const window_title_cstr: [*:0]const u8 = "VRGame — Zigadel Prototype\x00";
const window_title_base: []const u8 = "VRGame — Zigadel Prototype";

// ──────────────────────────────────────────────────────────────────────────────
// World
const GRID_HALF: i32 = 64;
const GRID_STEP: f32 = 1.0;
const GRID_SIZE: i32 = GRID_HALF * 2;
const QUAD_COUNT: usize = @intCast(GRID_SIZE * GRID_SIZE);
const FLOOR_VERTS: u32 = @intCast(QUAD_COUNT * 6);
const CUBE_VERTS: u32 = 36;
const TOTAL_VERTICES: u32 = FLOOR_VERTS + CUBE_VERTS;
const VERTEX_BUFFER_SIZE: vk.DeviceSize =
    @intCast(@as(usize, TOTAL_VERTICES) * @sizeOf(Vertex));

// ──────────────────────────────────────────────────────────────────────────────
// Instances
const CUBE_INSTANCES: usize = 1024; // can go higher; CPU-cull keeps perf sane

const Instance = extern struct {
    // std430-friendly: mat4 as 4x vec4 then color
    model: [16]f32,
    color: [4]f32,
};

var cube_pos: [CUBE_INSTANCES][3]f32 = undefined; // world centers
var spin_axis: [CUBE_INSTANCES][3]f32 = undefined; // unit axes
var spin_speed: [CUBE_INSTANCES]f32 = undefined; // rad/s
var inst_color: [CUBE_INSTANCES][4]f32 = undefined; // rgb + 1

// ──────────────────────────────────────────────────────────────────────────────
// UBOs
const SceneUBO = extern struct {
    vp: [16]f32,
    light_dir: [4]f32, // xyz used; w unused
    light_color: [4]f32, // rgb used; w unused
    ambient: [4]f32, // rgb used; w unused
    time: f32,
    _pad: [3]f32 = .{ 0, 0, 0 },
};

// ──────────────────────────────────────────────────────────────────────────────
// Flip policy: portable + correct via negative viewport height
const VIEWPORT_Y_FLIP: bool = true;
const PROJECTION_Y_FLIP: bool = false;

// ──────────────────────────────────────────────────────────────────────────────
// Declarative config (overridden by config.json if present)
const Config = struct {
    fov_deg: f32 = 70.0,
    mouse_sens: f32 = 0.12,
    invert_y: bool = false,
    enable_raw_mouse: bool = true,
    base_move_speed_scale: f32 = 1.0,
    sprint_mult: f32 = 2.5,
    allow_alt_enter: bool = true,
    allow_f11: bool = true,
    allow_cmd_ctrl_f_mac: bool = true,
};

// JSON overlay type
const ConfigFile = struct {
    fov_deg: ?f32 = null,
    mouse_sens: ?f32 = null,
    invert_y: ?bool = null,
    enable_raw_mouse: ?bool = null,
    base_move_speed_scale: ?f32 = null,
    sprint_mult: ?f32 = null,
    allow_alt_enter: ?bool = null,
    allow_f11: ?bool = null,
    allow_cmd_ctrl_f_mac: ?bool = null,
};

var CONFIG: Config = .{};

// ──────────────────────────────────────────────────────────────────────────────
// Static system state
const InputState = struct {
    var just_locked: bool = false;
    var raw_mouse_enabled: bool = false;
    var raw_mouse_checked: bool = false;
};

const WindowState = struct {
    var fullscreen: bool = false;
    var saved_x: i32 = 100;
    var saved_y: i32 = 100;
    var saved_w: i32 = 1280;
    var saved_h: i32 = 800;
};

// ──────────────────────────────────────────────────────────────────────────────
// Time
fn nowMsFromGlfw() i64 {
    return @as(i64, @intFromFloat(glfw.getTime() * 1000.0));
}

// ──────────────────────────────────────────────────────────────────────────────
// GLFW error hook
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

    if (CONFIG.allow_f11 and !IS_MAC) {
        const down = glfw.getKey(window, glfw.c.GLFW_KEY_F11) == glfw.c.GLFW_PRESS;
        if (down and !Latch.f11) toggle = true;
        Latch.f11 = down;
    }

    if (CONFIG.allow_cmd_ctrl_f_mac and IS_MAC) {
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

fn sampleCameraInput(window: *glfw.Window, look_active: bool) CameraInput {
    var ci: CameraInput = .{};
    const Key = struct {
        fn isDown(w: *glfw.Window, key: c_int) bool {
            const s = glfw.getKey(w, key);
            return s == glfw.c.GLFW_PRESS or s == glfw.c.GLFW_REPEAT;
        }
    };

    if (Key.isDown(window, glfw.c.GLFW_KEY_W)) ci.move_forward = true;
    if (Key.isDown(window, glfw.c.GLFW_KEY_S)) ci.move_backward = true;
    if (Key.isDown(window, glfw.c.GLFW_KEY_A)) ci.move_left = true;
    if (Key.isDown(window, glfw.c.GLFW_KEY_D)) ci.move_right = true;
    if (Key.isDown(window, glfw.c.GLFW_KEY_SPACE)) ci.move_up = true;
    if (Key.isDown(window, glfw.c.GLFW_KEY_LEFT_CONTROL)) ci.move_down = true;

    const CursorState = struct {
        var last_pos: ?[2]f64 = null;
    };

    if (look_active) {
        const raw = glfw.getCursorPos(window);
        const pos = [2]f64{ raw.x, raw.y };

        if (InputState.just_locked or CursorState.last_pos == null) {
            CursorState.last_pos = pos;
            InputState.just_locked = false;
            return ci;
        }

        const prev = CursorState.last_pos.?;
        const dx = pos[0] - prev[0];
        const dy = pos[1] - prev[1];

        var y = @as(f32, @floatCast(dy)) * CONFIG.mouse_sens;
        if (CONFIG.invert_y) y = -y;

        ci.look_delta_x = @as(f32, @floatCast(dx)) * CONFIG.mouse_sens;
        ci.look_delta_y = y;

        CursorState.last_pos = pos;
    } else {
        CursorState.last_pos = null;
    }

    return ci;
}

// ──────────────────────────────────────────────────────────────────────────────
// Geometry writers (floor + one unit cube)
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
// CPU helpers

inline fn clamp01(x: f32) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

// Column-major mat4 multiply with vec4 (assumes Mat4.m is column-major)
fn mulPoint4x4(m: [16]f32, p: [4]f32) [4]f32 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12] * p[3],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13] * p[3],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14] * p[3],
        m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15] * p[3],
    };
}

fn centerInsideClip(vp: [16]f32, world_center: [3]f32) bool {
    const c = mulPoint4x4(vp, .{ world_center[0], world_center[1], world_center[2], 1.0 });
    if (c[3] <= 0.0) return false; // behind camera
    const ax = @abs(c[0]);
    const ay = @abs(c[1]);
    const az = @abs(c[2]);
    return (ax <= c[3] and ay <= c[3] and az <= c[3]);
}

fn axisAngleMat4(axis_in: [3]f32, angle: f32, translate: [3]f32) [16]f32 {
    // normalize
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

    // Column-major 4x4
    return .{
        t * x * x + c,     t * x * y + s * z, t * x * z - s * y, 0.0,
        t * x * y - s * z, t * y * y + c,     t * y * z + s * x, 0.0,
        t * x * z + s * y, t * y * z - s * x, t * z * z + c,     0.0,
        translate[0],      translate[1],      translate[2],      1.0,
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// SplitMix64 (deterministic, dependency-free)
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

// was: fn u01(s: *u64) f32 { ... }
fn uniform01(s: *u64) f32 {
    // 24-bit mantissa to f32 in [0,1]
    const v: u32 = @intCast(splitmix64_next(s) >> 40);
    return @as(f32, @floatFromInt(v)) * (1.0 / 16777215.0);
}

fn randUnitVec3(s: *u64) [3]f32 {
    const z = 2.0 * uniform01(s) - 1.0;
    const a = 2.0 * std.math.pi * uniform01(s);
    const r = std.math.sqrt(@max(0.0, 1.0 - z * z));
    return .{ r * std.math.cos(a), r * std.math.sin(a), z };
}

fn scatterInstances(seed: u64) void {
    var s = seed;
    const R: f32 = @as(f32, @floatFromInt(GRID_HALF)) * GRID_STEP - 4.0;

    // was: inline for (0..CUBE_INSTANCES) |i| {
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
    const k0 = 1.0;
    const k1 = 2.0 / 3.0;
    const k2 = 1.0 / 3.0;
    const k3 = 3.0;

    const r = v * (k0 - clamp01(@abs(@mod(h * k3, 2.0) - 1.0)) * s);
    const g = v * (k0 - clamp01(@abs(@mod(h * k3 + k2 * 2.0, 2.0) - 1.0)) * s);
    const b = v * (k0 - clamp01(@abs(@mod(h * k3 + k1 * 2.0, 2.0) - 1.0)) * s);
    return .{ r, g, b };
}

// Fill instance buffer with only visible instances; returns count
fn buildVisibleInstances(
    vp: [16]f32,
    time_sec: f32,
    out_ptr: [*]Instance,
    max_instances: usize,
) usize {
    var count: usize = 0;

    // was: inline for (0..CUBE_INSTANCES) |i| {
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
// Shader + pipeline
fn readFileAlignedAbsolute(alloc: Allocator, abs_path: []const u8, comptime alignment: std.mem.Alignment) ![]u8 {
    var file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    const st = try file.stat();
    if (st.size == 0) return error.EmptyFile;

    const size: usize = @intCast(st.size);
    var tmp = try alloc.alloc(u8, size);
    defer alloc.free(tmp);

    var off: usize = 0;
    while (off < size) {
        const n = try file.read(tmp[off..]);
        if (n == 0) break;
        off += n;
    }
    if (off != size) return error.UnexpectedEof;

    const out = try alloc.alignedAlloc(u8, alignment, size);
    @memcpy(out, tmp);
    return out;
}

fn loadSpirvFromExeDirAligned(alloc: Allocator, rel: []const u8) ![]u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(alloc);
    defer alloc.free(exe_dir);

    const full = try std.fs.path.join(alloc, &.{ exe_dir, rel });
    defer alloc.free(full);

    const bytes = try readFileAlignedAbsolute(alloc, full, .@"4");
    if (bytes.len % 4 != 0) {
        alloc.free(bytes);
        return error.BadSpirvSize;
    }
    return bytes;
}

fn loadFirstSpirv(alloc: Allocator, title: []const u8, candidates: []const []const u8) ![]u8 {
    var last_err: anyerror = error.FileNotFound;
    for (candidates) |rel| {
        const got = loadSpirvFromExeDirAligned(alloc, rel) catch |e| {
            last_err = e;
            continue;
        };
        std.log.info("Using {s} shader: {s} ({d} bytes)", .{ title, rel, got.len });
        return got;
    }
    return last_err;
}

fn createPipeline(gc: *const GraphicsContext, layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
    const A = std.heap.c_allocator;

    const vert_candidates = [_][]const u8{
        "shaders/basic_lit_vert",
        "shaders/basic_lit.vert.spv",
    };
    const frag_candidates = [_][]const u8{
        "shaders/basic_lit_frag",
        "shaders/basic_lit.frag.spv",
    };

    const vert_bytes = try loadFirstSpirv(A, "VERT", &vert_candidates);
    defer A.free(vert_bytes);
    const frag_bytes = try loadFirstSpirv(A, "FRAG", &frag_candidates);
    defer A.free(frag_bytes);

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

    // Vertex + Instance bindings & attributes
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
        Vertex.binding_description,
        instance_binding,
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
    const rs = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = VK_FALSE32,
        .rasterizer_discard_enable = VK_FALSE32,
        .polygon_mode = .fill,
        .cull_mode = .{}, // disable for now
        .front_face = .clockwise,
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
        .depth_test_enable = VK_TRUE32,
        .depth_write_enable = VK_TRUE32,
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

// ──────────────────────────────────────────────────────────────────────────────
// Framebuffers / Render pass
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

    return try gc.vkd.createRenderPass(gc.dev, &vk.RenderPassCreateInfo{
        .flags = .{},
        .attachment_count = @intCast(attachments.len),
        .p_attachments = &attachments,
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 0,
        .p_dependencies = undefined,
    }, null);
}

// ──────────────────────────────────────────────────────────────────────────────
// Small file helpers (Zig 0.16)
fn readAllAllocAbsolute(alloc: Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    const st = try file.stat();
    if (st.size == 0) return error.EmptyFile;
    if (st.size > max_bytes) return error.FileTooBig;

    const size: usize = @intCast(st.size);
    var buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);

    var off: usize = 0;
    while (off < size) {
        const n = try file.read(buf[off..]);
        if (n == 0) break;
        off += n;
    }
    if (off != size) return error.UnexpectedEof;

    return buf;
}

fn readAllAllocFromDir(alloc: Allocator, dir: std.fs.Dir, sub_path: []const u8, max_bytes: usize) ![]u8 {
    var file = try dir.openFile(sub_path, .{});
    defer file.close();

    const size_u64 = try file.getEndPos();
    if (size_u64 == 0) return error.EmptyFile;
    if (size_u64 > max_bytes) return error.FileTooBig;

    const size: usize = @intCast(size_u64);
    var buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);

    var off: usize = 0;
    while (off < size) {
        const n = try file.read(buf[off..]);
        if (n == 0) break;
        off += n;
    }
    if (off != size) return error.UnexpectedEof;

    return buf;
}

// ──────────────────────────────────────────────────────────────────────────────
// Config loader
fn loadConfig(alloc: Allocator) Config {
    const filename = "config.json";
    var cfg: Config = .{}; // defaults

    // 1) Try executable directory
    if (std.fs.selfExeDirPathAlloc(alloc) catch null) |exe_dir_path| {
        defer alloc.free(exe_dir_path);

        if (std.fs.path.join(alloc, &.{ exe_dir_path, filename }) catch null) |full_path| {
            defer alloc.free(full_path);

            if (readAllAllocAbsolute(alloc, full_path, 1 << 20) catch null) |bytes| {
                defer alloc.free(bytes);

                const parsed = std.json.parseFromSlice(ConfigFile, alloc, bytes, .{
                    .ignore_unknown_fields = true,
                }) catch {
                    std.log.warn("config.json in exe dir: parse failed; using defaults", .{});
                    return cfg;
                };
                defer parsed.deinit();

                cfg = overlayConfig(cfg, parsed.value);
                std.log.info("Loaded config.json from executable directory", .{});
                return cfg;
            }
        }
    }

    // 2) Try current working directory
    if (readAllAllocFromDir(alloc, std.fs.cwd(), filename, 1 << 20) catch null) |bytes| {
        defer alloc.free(bytes);

        const parsed = std.json.parseFromSlice(ConfigFile, alloc, bytes, .{
            .ignore_unknown_fields = true,
        }) catch {
            std.log.warn("config.json in CWD: parse failed; using defaults", .{});
            return cfg;
        };
        defer parsed.deinit();

        cfg = overlayConfig(cfg, parsed.value);
        std.log.info("Loaded config.json from current working directory", .{});
        return cfg;
    }

    // 3) Defaults
    std.log.info("config.json not found; using defaults", .{});
    return cfg;
}

fn overlayConfig(base: Config, file: ConfigFile) Config {
    var out = base;
    if (file.fov_deg) |v| out.fov_deg = v;
    if (file.mouse_sens) |v| out.mouse_sens = v;
    if (file.invert_y) |v| out.invert_y = v;
    if (file.enable_raw_mouse) |v| out.enable_raw_mouse = v;
    if (file.base_move_speed_scale) |v| out.base_move_speed_scale = v;
    if (file.sprint_mult) |v| out.sprint_mult = v;
    if (file.allow_alt_enter) |v| out.allow_alt_enter = v;
    if (file.allow_f11) |v| out.allow_f11 = v;
    if (file.allow_cmd_ctrl_f_mac) |v| out.allow_cmd_ctrl_f_mac = v;
    return out;
}

// ──────────────────────────────────────────────────────────────────────────────
// Buffer staging copy (used only for static vbuf upload)
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

    const window = try glfw.createWindow(
        @as(i32, @intCast(extent.width)),
        @as(i32, @intCast(extent.height)),
        window_title_cstr,
        null,
        null,
    );
    defer glfw.destroyWindow(window);

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

    var swapchain = try Swapchain.init(&gc, A, extent);
    defer swapchain.deinit();

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

    // Descriptor set layout (SceneUBO at set=0, binding=0)
    const ubo_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .p_immutable_samplers = null,
    };
    const dsl = try gc.vkd.createDescriptorSetLayout(gc.dev, &vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = 1,
        .p_bindings = @ptrCast(&ubo_binding),
    }, null);
    defer gc.vkd.destroyDescriptorSetLayout(gc.dev, dsl, null);

    // Pipeline layout (set=0 + NO push constants)
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

    // Instance buffer (HOST VISIBLE + COHERENT; updated each frame; no staging)
    const ibuf = try gc.vkd.createBuffer(gc.dev, &vk.BufferCreateInfo{
        .flags = .{},
        .size = @as(vk.DeviceSize, @intCast(CUBE_INSTANCES * @sizeOf(Instance))),
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer gc.vkd.destroyBuffer(gc.dev, ibuf, null);

    const ireqs = gc.vkd.getBufferMemoryRequirements(gc.dev, ibuf);
    const imem = try gc.allocate(ireqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.vkd.freeMemory(gc.dev, imem, null);
    try gc.vkd.bindBufferMemory(gc.dev, ibuf, imem, 0);

    const ibase_ptr = try gc.vkd.mapMemory(gc.dev, imem, 0, vk.WHOLE_SIZE, .{});
    defer gc.vkd.unmapMemory(gc.dev, imem);
    const instances_ptr: [*]Instance = @ptrCast(@alignCast(ibase_ptr));

    // Scene UBO (host-visible; small; updated per-frame)
    const ubo_size: vk.DeviceSize = @sizeOf(SceneUBO);
    const ubo_buf = try gc.vkd.createBuffer(gc.dev, &vk.BufferCreateInfo{
        .flags = .{},
        .size = ubo_size,
        .usage = .{ .uniform_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer gc.vkd.destroyBuffer(gc.dev, ubo_buf, null);

    const ubo_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, ubo_buf);
    const ubo_mem = try gc.allocate(ubo_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.vkd.freeMemory(gc.dev, ubo_mem, null);
    try gc.vkd.bindBufferMemory(gc.dev, ubo_buf, ubo_mem, 0);

    const ubo_map = try gc.vkd.mapMemory(gc.dev, ubo_mem, 0, vk.WHOLE_SIZE, .{});
    defer gc.vkd.unmapMemory(gc.dev, ubo_mem);
    const ubo_view: *SceneUBO = @ptrCast(@alignCast(ubo_map));

    // Descriptor set
    const pool_sizes = [_]vk.DescriptorPoolSize{.{ .type = .uniform_buffer, .descriptor_count = 1 }};
    const desc_pool = try gc.vkd.createDescriptorPool(gc.dev, &vk.DescriptorPoolCreateInfo{
        .flags = .{},
        .max_sets = 1,
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = &pool_sizes,
    }, null);
    defer gc.vkd.destroyDescriptorPool(gc.dev, desc_pool, null);

    var set: vk.DescriptorSet = .null_handle;
    const alloc_info = vk.DescriptorSetAllocateInfo{
        .descriptor_pool = desc_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&dsl),
    };
    try gc.vkd.allocateDescriptorSets(gc.dev, &alloc_info, @ptrCast(&set));

    const ubo_info = vk.DescriptorBufferInfo{ .buffer = ubo_buf, .offset = 0, .range = ubo_size };
    const write = vk.WriteDescriptorSet{
        .dst_set = set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer,
        .p_image_info = undefined,
        .p_buffer_info = @ptrCast(&ubo_info),
        .p_texel_buffer_view = undefined,
    };
    gc.vkd.updateDescriptorSets(gc.dev, 1, @ptrCast(&write), 0, undefined);

    // Command buffers
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
        @as(f32, @floatFromInt(swapchain.extent.width)) /
            @as(f32, @floatFromInt(swapchain.extent.height)),
        0.1,
        500.0,
    );

    var frame_timer = FrameTimer.init(nowMsFromGlfw(), 1000);

    // Instance scatter (deterministic)
    scatterInstances(0xCAFEBABE1234_5678);

    // Control latch
    const LockState = struct {
        var locked: bool = false;
    };

    while (!glfw.windowShouldClose(window)) {
        const tick = frame_timer.tick(nowMsFromGlfw());
        var dt = @as(f32, @floatCast(tick.dt));
        dt *= CONFIG.base_move_speed_scale;

        // Sprint
        const ls = glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_SHIFT);
        const rs = glfw.getKey(window, glfw.c.GLFW_KEY_RIGHT_SHIFT);
        if (ls == glfw.c.GLFW_PRESS or ls == glfw.c.GLFW_REPEAT or
            rs == glfw.c.GLFW_PRESS or rs == glfw.c.GLFW_REPEAT)
        {
            dt *= CONFIG.sprint_mult;
        }

        // Fullscreen, Quit
        handleFullscreenShortcuts(window);
        const esc = glfw.getKey(window, glfw.c.GLFW_KEY_ESCAPE);
        if (esc == glfw.c.GLFW_PRESS or esc == glfw.c.GLFW_REPEAT) glfw.setWindowShouldClose(window, true);

        // Rescatter: R (deterministic same seed for now)
        if (glfw.getKey(window, glfw.c.GLFW_KEY_R) == glfw.c.GLFW_PRESS) {
            scatterInstances(0xCAFEBABE1234_5678);
        }

        // RMB to lock look
        const rmb_down = (glfw.getMouseButton(window, glfw.c.GLFW_MOUSE_BUTTON_RIGHT) == glfw.c.GLFW_PRESS);
        if (rmb_down and !LockState.locked) {
            glfw.setInputMode(window, glfw.c.GLFW_CURSOR, glfw.c.GLFW_CURSOR_DISABLED);

            if (CONFIG.enable_raw_mouse and !InputState.raw_mouse_checked) {
                InputState.raw_mouse_checked = true;
                if (glfw.rawMouseMotionSupported()) {
                    glfw.setInputMode(window, glfw.c.GLFW_RAW_MOUSE_MOTION, glfw.c.GLFW_TRUE);
                    InputState.raw_mouse_enabled = true;
                    std.log.info("Raw mouse: ENABLED", .{});
                } else {
                    std.log.info("Raw mouse: NOT SUPPORTED on this platform", .{});
                }
            }

            InputState.just_locked = true;
            LockState.locked = true;
        } else if (!rmb_down and LockState.locked) {
            glfw.setInputMode(window, glfw.c.GLFW_CURSOR, glfw.c.GLFW_CURSOR_NORMAL);
            LockState.locked = false;
        }

        const input = sampleCameraInput(window, rmb_down);
        camera.update(dt, input);

        // Build Scene UBO
        var vp = camera.viewProjMatrix();
        if (PROJECTION_Y_FLIP) vp.m[5] = -vp.m[5];

        const time_sec: f32 = @floatCast(glfw.getTime());
        const light_dir = [4]f32{ -0.4, -1.0, -0.3, 0.0 }; // downward
        const light_color = [4]f32{ 1.0, 0.97, 0.92, 0.0 }; // warm-ish
        const ambient = [4]f32{ 0.12, 0.13, 0.15, 0.0 };

        ubo_view.* = .{
            .vp = vp.m,
            .light_dir = light_dir,
            .light_color = light_color,
            .ambient = ambient,
            .time = time_sec,
            ._pad = .{ 0, 0, 0 },
        };

        // Instance 0 = floor (identity model, neutral color)
        instances_ptr[0] = .{
            .model = Mat4.identity().m,
            .color = .{ 1.0, 1.0, 1.0, 1.0 },
        };

        // Fill cubes starting at instance slot 1
        const visible_count = buildVisibleInstances(
            vp.m,
            time_sec,
            instances_ptr + 1,
            CUBE_INSTANCES - 1,
        );

        // Title (FPS minimal)
        if (tick.fps_updated) {
            var buf: [200]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &buf,
                "{s} | FPS: {d:.1} | vis:{d}",
                .{ window_title_base, tick.fps, visible_count },
            ) catch null;
            if (title) |z| glfw.setWindowTitle(window, z);
        }

        // Record
        const cmdbuf = cmdbufs[swapchain.image_index];
        try gc.vkd.resetCommandBuffer(cmdbuf, .{});
        try gc.vkd.beginCommandBuffer(cmdbuf, &vk.CommandBufferBeginInfo{ .flags = .{}, .p_inheritance_info = null });

        const fb_extent = swapchain.extent;

        var viewport = vk.Viewport{
            .x = 0,
            .y = if (VIEWPORT_Y_FLIP) @as(f32, @floatFromInt(fb_extent.height)) else 0,
            .width = @as(f32, @floatFromInt(fb_extent.width)),
            .height = if (VIEWPORT_Y_FLIP)
                -@as(f32, @floatFromInt(fb_extent.height))
            else
                @as(f32, @floatFromInt(fb_extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = fb_extent };
        gc.vkd.cmdSetViewport(cmdbuf, 0, 1, @as([*]const vk.Viewport, @ptrCast(&viewport)));
        gc.vkd.cmdSetScissor(cmdbuf, 0, 1, @as([*]const vk.Rect2D, @ptrCast(&scissor)));

        const clear_color = vk.ClearValue{ .color = .{ .float_32 = .{ 0.05, 0.05, 0.07, 1.0 } } };
        const clear_depth = vk.ClearValue{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } };
        var clears = [_]vk.ClearValue{ clear_color, clear_depth };

        const rp_begin = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffers[swapchain.image_index],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = fb_extent },
            .clear_value_count = @intCast(clears.len),
            .p_clear_values = &clears,
        };
        gc.vkd.cmdBeginRenderPass(cmdbuf, &rp_begin, vk.SubpassContents.@"inline");

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);

        const bufs = [_]vk.Buffer{ vbuf, ibuf };
        const offs = [_]vk.DeviceSize{ 0, 0 };
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, bufs.len, &bufs, &offs);
        gc.vkd.cmdBindDescriptorSets(cmdbuf, .graphics, pipeline_layout, 0, 1, @ptrCast(&set), 0, undefined);

        // Floor
        gc.vkd.cmdDraw(cmdbuf, FLOOR_VERTS, 1, 0, 0);

        // Cubes use instances [1 .. 1+visible_count)
        if (visible_count > 0) {
            gc.vkd.cmdDraw(cmdbuf, CUBE_VERTS, @intCast(visible_count), FLOOR_VERTS, 1);
        }

        gc.vkd.cmdEndRenderPass(cmdbuf);
        try gc.vkd.endCommandBuffer(cmdbuf);

        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        // Resize path
        if (state == .suboptimal) {
            waitForNonZeroFramebuffer(window);
            const fb2 = glfw.getFramebufferSize(window);
            extent.width = @intCast(@max(@as(i32, 1), fb2.width));
            extent.height = @intCast(@max(@as(i32, 1), fb2.height));

            if (extent.width > 0 and extent.height > 0) {
                try swapchain.recreate(extent);

                const new_aspect: f32 =
                    @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height));
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

                // Realloc cmdbufs to match swapchain
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

        glfw.pollEvents();
    }

    try swapchain.waitForAllFences();
}

// ── Sanity test
test "viewport flip only" {
    try std.testing.expect(VIEWPORT_Y_FLIP and !PROJECTION_Y_FLIP);
}
