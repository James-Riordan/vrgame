const std = @import("std");

pub const CameraStyle = enum { fps, blender_orbit };

pub const Config = struct {
    // Window / UX
    allow_alt_enter: bool = true,
    allow_f11: bool = true,
    allow_cmd_ctrl_f_mac: bool = true,

    // Rendering
    debug_no_draw: bool = false,
    debug_heartbeat_every: u32 = 120,

    // Camera: shared
    camera_style: CameraStyle = .fps,
    fov_deg: f32 = 70.0,
    znear: f32 = 0.1,
    zfar: f32 = 500.0,

    // FPS (Minecraft-like)
    fps_mouse_sens: f32 = 0.12, // deg/px scaled internally
    fps_invert_y: bool = false,
    fps_base_speed: f32 = 5.5,
    fps_sprint_mult: f32 = 2.5,
    fps_require_rmb: bool = false, // false = always look (PC shooter feel)

    // Orbit (Blender-like)
    orbit_yaw_sens: f32 = 0.008, // rad/px
    orbit_pitch_sens: f32 = 0.008, // rad/px
    orbit_pan_sens: f32 = 1.0, // world-units per px @ radius=1
    orbit_dolly_wheel: f32 = 1.20, // wheel zoom factor per notch
    orbit_dolly_drag: f32 = 0.003, // Ctrl+RMB vertical drag factor
    orbit_min_radius: f32 = 0.15,
    orbit_max_radius: f32 = 500.0,
    max_pitch_deg: f32 = 89.0,
};

const ConfigFile = struct {
    // mirror fields as optionals for JSON overlay
    allow_alt_enter: ?bool = null,
    allow_f11: ?bool = null,
    allow_cmd_ctrl_f_mac: ?bool = null,
    debug_no_draw: ?bool = null,
    debug_heartbeat_every: ?u32 = null,

    camera_style: ?[]const u8 = null,
    fov_deg: ?f32 = null,
    znear: ?f32 = null,
    zfar: ?f32 = null,

    fps_mouse_sens: ?f32 = null,
    fps_invert_y: ?bool = null,
    fps_base_speed: ?f32 = null,
    fps_sprint_mult: ?f32 = null,
    fps_require_rmb: ?bool = null,

    orbit_yaw_sens: ?f32 = null,
    orbit_pitch_sens: ?f32 = null,
    orbit_pan_sens: ?f32 = null,
    orbit_dolly_wheel: ?f32 = null,
    orbit_dolly_drag: ?f32 = null,
    orbit_min_radius: ?f32 = null,
    orbit_max_radius: ?f32 = null,
    max_pitch_deg: ?f32 = null,
};

fn parseStyle(s: []const u8) ?CameraStyle {
    if (std.ascii.eqlIgnoreCase(s, "fps")) return .fps;
    if (std.ascii.eqlIgnoreCase(s, "blender_orbit")) return .blender_orbit;
    return null;
}

fn overlay(base: Config, f: ConfigFile) Config {
    var c = base;

    if (f.allow_alt_enter) |v| c.allow_alt_enter = v;
    if (f.allow_f11) |v| c.allow_f11 = v;
    if (f.allow_cmd_ctrl_f_mac) |v| c.allow_cmd_ctrl_f_mac = v;
    if (f.debug_no_draw) |v| c.debug_no_draw = v;
    if (f.debug_heartbeat_every) |v| c.debug_heartbeat_every = v;

    if (f.camera_style) |s| {
        if (parseStyle(s)) |m| {
            c.camera_style = m;
        }
    }
    if (f.fov_deg) |v| c.fov_deg = v;
    if (f.znear) |v| c.znear = v;
    if (f.zfar) |v| c.zfar = v;

    if (f.fps_mouse_sens) |v| c.fps_mouse_sens = v;
    if (f.fps_invert_y) |v| c.fps_invert_y = v;
    if (f.fps_base_speed) |v| c.fps_base_speed = v;
    if (f.fps_sprint_mult) |v| c.fps_sprint_mult = v;
    if (f.fps_require_rmb) |v| c.fps_require_rmb = v;

    if (f.orbit_yaw_sens) |v| c.orbit_yaw_sens = v;
    if (f.orbit_pitch_sens) |v| c.orbit_pitch_sens = v;
    if (f.orbit_pan_sens) |v| c.orbit_pan_sens = v;
    if (f.orbit_dolly_wheel) |v| c.orbit_dolly_wheel = v;
    if (f.orbit_dolly_drag) |v| c.orbit_dolly_drag = v;
    if (f.orbit_min_radius) |v| c.orbit_min_radius = v;
    if (f.orbit_max_radius) |v| c.orbit_max_radius = v;
    if (f.max_pitch_deg) |v| c.max_pitch_deg = v;

    return c;
}

fn readAllAllocAbsolute(alloc: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();
    const st = try file.stat();
    if (st.size == 0 or st.size > max_bytes) return error.InvalidSize;
    const n: usize = @intCast(st.size);
    var buf = try alloc.alloc(u8, n);
    errdefer alloc.free(buf);
    var off: usize = 0;
    while (off < n) : (off += try file.read(buf[off..])) {}
    return buf;
}

pub fn load(alloc: std.mem.Allocator) Config {
    const cfg: Config = .{};
    const fname = "config.json";

    if (std.fs.selfExeDirPathAlloc(alloc) catch null) |exe_dir| {
        defer alloc.free(exe_dir);
        if (std.fs.path.join(alloc, &.{ exe_dir, fname }) catch null) |p| {
            defer alloc.free(p);
            if (readAllAllocAbsolute(alloc, p, 1 << 20) catch null) |bytes| {
                defer alloc.free(bytes);
                const parsed = std.json.parseFromSlice(ConfigFile, alloc, bytes, .{ .ignore_unknown_fields = true }) catch null;
                if (parsed) |pd| {
                    defer pd.deinit();
                    return overlay(cfg, pd.value);
                }
            }
        }
    }

    if (std.fs.cwd().readFileAlloc(alloc, fname, 1 << 20) catch null) |bytes| {
        defer alloc.free(bytes);
        const parsed = std.json.parseFromSlice(ConfigFile, alloc, bytes, .{ .ignore_unknown_fields = true }) catch null;
        if (parsed) |pd| {
            defer pd.deinit();
            return overlay(cfg, pd.value);
        }
    }

    return cfg;
}
