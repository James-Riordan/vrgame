const std = @import("std");
const math3d = @import("math3d");

const Vec3 = math3d.Vec3;
const Mat4 = math3d.Mat4;

fn degToRad(deg: f32) f32 {
    const pi_f32: f32 = @floatCast(std.math.pi);
    return deg * (pi_f32 / 180.0);
}

/// Inputs for a single frame of camera control.
/// Mouse deltas are in "pixels" or whatever unit you want; caller scales appropriately.
pub const CameraInput = struct {
    move_forward: bool = false,
    move_backward: bool = false,
    move_left: bool = false,
    move_right: bool = false,
    move_up: bool = false,
    move_down: bool = false,

    look_delta_x: f32 = 0.0,
    look_delta_y: f32 = 0.0,
};

/// Right-handed FPS-style camera.
/// - World up is +Y.
/// - Forward at yaw=0, pitch=0 points down -Z.
/// - Uses radians for yaw/pitch.
pub const Camera3D = struct {
    position: Vec3,
    yaw: f32,
    pitch: f32,

    fov_y: f32,
    aspect: f32,
    near: f32,
    far: f32,

    move_speed: f32,
    look_sensitivity: f32,

    pub fn init(
        position: Vec3,
        fov_y: f32,
        aspect: f32,
        near: f32,
        far: f32,
    ) Camera3D {
        return .{
            .position = position,
            .yaw = 0.0,
            .pitch = 0.0,
            .fov_y = fov_y,
            .aspect = aspect,
            .near = near,
            .far = far,
            .move_speed = 4.0,
            .look_sensitivity = 0.0025,
        };
    }

    pub fn setAspect(self: *Camera3D, aspect: f32) void {
        self.aspect = aspect;
    }

    fn forward(self: *const Camera3D) Vec3 {
        const cp = @cos(self.pitch);
        const sp = @sin(self.pitch);
        const cy = @cos(self.yaw);
        const sy = @sin(self.yaw);

        // yaw=0, pitch=0 -> (0,0,-1)
        return Vec3.init(
            cp * sy,
            sp,
            -cp * cy,
        ).normalized();
    }

    fn right(self: *const Camera3D) Vec3 {
        const f = self.forward();
        const world_up = Vec3.init(0.0, 1.0, 0.0);
        return f.cross(world_up).normalized();
    }

    fn up(self: *const Camera3D) Vec3 {
        const r = self.right();
        const f = self.forward();
        return r.cross(f).normalized();
    }

    pub fn viewMatrix(self: *const Camera3D) Mat4 {
        const eye = self.position;
        const center = eye.add(self.forward());
        const up_vec = self.up();
        return Mat4.lookAt(eye, center, up_vec);
    }

    pub fn projMatrix(self: *const Camera3D) Mat4 {
        return Mat4.perspective(self.fov_y, self.aspect, self.near, self.far);
    }

    pub fn viewProjMatrix(self: *const Camera3D) Mat4 {
        return self.projMatrix().mul(self.viewMatrix());
    }

    /// Apply one frame of input.
    /// `dt` in seconds. `input.look_delta_*` can be raw or pre-scaled; we multiply by sensitivity * dt.
    pub fn update(self: *Camera3D, dt: f32, input: CameraInput) void {
        // Mouse look: yaw around world up, pitch around local right.
        const look_scale = self.look_sensitivity;
        self.yaw -= input.look_delta_x * look_scale;
        self.pitch -= input.look_delta_y * look_scale;

        // Clamp pitch to avoid gimbal lock.
        const pitch_limit: f32 = degToRad(89.0);
        if (self.pitch > pitch_limit) self.pitch = pitch_limit;
        if (self.pitch < -pitch_limit) self.pitch = -pitch_limit;

        var move_dir = Vec3.zero();

        if (input.move_forward) move_dir = move_dir.add(self.forward());
        if (input.move_backward) move_dir = move_dir.sub(self.forward());
        if (input.move_right) move_dir = move_dir.add(self.right());
        if (input.move_left) move_dir = move_dir.sub(self.right());

        const world_up = Vec3.init(0.0, 1.0, 0.0);
        if (input.move_up) move_dir = move_dir.add(world_up);
        if (input.move_down) move_dir = move_dir.sub(world_up);

        if (move_dir.length() > 0.0) {
            const dir = move_dir.normalized();
            self.position = self.position.add(dir.scale(self.move_speed * dt));
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Camera3D forward/right/up basics" {
    var cam = Camera3D.init(
        Vec3.init(0.0, 0.0, 0.0),
        degToRad(60.0),
        16.0 / 9.0,
        0.1,
        100.0,
    );

    const f = cam.forward();
    const r = cam.right();
    const u = cam.up();

    // At yaw=0, pitch=0, forward should be roughly (0, 0, -1).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), f.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), f.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), f.z, 0.001);

    // Right should be roughly (1, 0, 0).
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), r.y, 0.001);

    // Up ~ (0,1,0).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), u.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), u.y, 0.001);
}

test "Camera3D simple movement" {
    var cam = Camera3D.init(
        Vec3.init(0.0, 0.0, 0.0),
        degToRad(60.0),
        16.0 / 9.0,
        0.1,
        100.0,
    );

    const dt: f32 = 1.0;
    var input = CameraInput{};
    input.move_forward = true;

    const start_pos = cam.position;
    cam.update(dt, input);

    // Moving forward at yaw=0 should reduce z.
    try std.testing.expect(cam.position.z < start_pos.z);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
