const std = @import("std");
const glfw = @import("glfw");
const vk = @import("vulkan");

const GraphicsContext = @import("graphics_context").GraphicsContext;
const Swapchain = @import("swapchain").Swapchain;
const Vertex = @import("vertex").Vertex;

const frame_time = @import("frame_time");
const FrameTimer = frame_time.FrameTimer;

const math3d = @import("math3d");
const Vec3 = math3d.Vec3;

const camera3d = @import("camera3d");
const Camera3D = camera3d.Camera3D;
const CameraInput = camera3d.CameraInput;

const triangle_vert = @embedFile("triangle_vert");
const triangle_frag = @embedFile("triangle_frag");

const Allocator = std.mem.Allocator;

const VK_FALSE32: vk.Bool32 = @enumFromInt(vk.FALSE);
const VK_TRUE32: vk.Bool32 = @enumFromInt(vk.TRUE);

// Human-readable app name for Vulkan, logs, etc. (does NOT need NUL).
const app_name = "VRGame — Zigadel Prototype";

// NUL-terminated window title for GLFW.
const window_title: [:0]const u8 = "VRGame — Zigadel Prototype";

// ─────────────────────────────────────────────────────────────────────────────
// Simple 3D scene geometry in *world* space
// ─────────────────────────────────────────────────────────────────────────────

const SceneVertex = struct {
    pos: [3]f32,
    color: [3]f32,
};

/// Very simple scene:
/// - A big ground quad in XZ-plane (y = 0)
/// - A small red pyramid at the origin
const scene_vertices = [_]SceneVertex{
    // Ground plane (two triangles forming a big square)
    .{ .pos = .{ -5.0, 0.0, -5.0 }, .color = .{ 0.1, 0.4, 0.1 } },
    .{ .pos = .{ 5.0, 0.0, -5.0 }, .color = .{ 0.1, 0.4, 0.1 } },
    .{ .pos = .{ 5.0, 0.0, 5.0 }, .color = .{ 0.1, 0.6, 0.1 } },

    .{ .pos = .{ -5.0, 0.0, -5.0 }, .color = .{ 0.1, 0.4, 0.1 } },
    .{ .pos = .{ 5.0, 0.0, 5.0 }, .color = .{ 0.1, 0.6, 0.1 } },
    .{ .pos = .{ -5.0, 0.0, 5.0 }, .color = .{ 0.1, 0.6, 0.1 } },

    // Pyramid on the ground at the origin
    .{ .pos = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.8, 0.2, 0.2 } }, // top
    .{ .pos = .{ -0.5, 0.0, -0.5 }, .color = .{ 0.8, 0.4, 0.4 } },
    .{ .pos = .{ 0.5, 0.0, -0.5 }, .color = .{ 0.8, 0.4, 0.4 } },

    .{ .pos = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.8, 0.2, 0.2 } },
    .{ .pos = .{ 0.5, 0.0, -0.5 }, .color = .{ 0.8, 0.4, 0.4 } },
    .{ .pos = .{ 0.5, 0.0, 0.5 }, .color = .{ 0.8, 0.4, 0.4 } },

    .{ .pos = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.8, 0.2, 0.2 } },
    .{ .pos = .{ 0.5, 0.0, 0.5 }, .color = .{ 0.8, 0.4, 0.4 } },
    .{ .pos = .{ -0.5, 0.0, 0.5 }, .color = .{ 0.8, 0.4, 0.4 } },

    .{ .pos = .{ 0.0, 1.0, 0.0 }, .color = .{ 0.8, 0.2, 0.2 } },
    .{ .pos = .{ -0.5, 0.0, 0.5 }, .color = .{ 0.8, 0.4, 0.4 } },
    .{ .pos = .{ -0.5, 0.0, -0.5 }, .color = .{ 0.8, 0.4, 0.4 } },
};

const TOTAL_VERTICES: u32 = scene_vertices.len;
const VERTEX_BUFFER_SIZE: vk.DeviceSize =
    @intCast(@as(usize, scene_vertices.len) * @sizeOf(Vertex));

// ─────────────────────────────────────────────────────────────────────────────
// Utility
// ─────────────────────────────────────────────────────────────────────────────

fn updateWindowTitle(window: *glfw.Window, fps: f64, cam: *const Camera3D) void {
    // Small fixed buffer for the title; avoid heap allocation.
    var buf: [200]u8 = undefined;

    const title = std.fmt.bufPrintZ(
        &buf,
        "VRGame — Zigadel Prototype | FPS: {d:.1} | Cam: x={d:.2}, y={d:.2}, z={d:.2}",
        .{ fps, cam.position.x, cam.position.y, cam.position.z },
    ) catch {
        // Fallback to the static title if formatting fails for any reason.
        glfw.setWindowTitle(window, window_title);
        return;
    };

    glfw.setWindowTitle(window, title);
}

/// Convert GLFW's monotonic time (seconds as f64) into milliseconds (i64).
fn nowMsFromGlfw() i64 {
    const now_s: f64 = glfw.getTime();
    return @as(i64, @intFromFloat(now_s * 1000.0));
}

// ─────────────────────────────────────────────────────────────────────────────
// GLFW error callback
// ─────────────────────────────────────────────────────────────────────────────

fn errorCallback(code: c_int, description: [*c]const u8) callconv(.c) void {
    const msg: [:0]const u8 = if (description) |ptr|
        std.mem.span(ptr)
    else
        "no description";

    const err_code = glfw.errorCodeFromC(code);
    std.log.err("GLFW error {any}: {s}", .{ err_code, msg });
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    // Install error callback first, so even init() failures are logged.
    _ = glfw.setErrorCallback(errorCallback);

    // Initialize GLFW
    glfw.init() catch {
        if (glfw.getLastError()) |err_info| {
            const code_opt = glfw.errorCodeFromC(err_info.code);
            const code_str = if (code_opt) |ce| @tagName(ce) else "UnknownError";
            const desc_str: []const u8 = err_info.description orelse "no description";

            std.log.err(
                "failed to initialize GLFW: {s}: {s}",
                .{ code_str, desc_str },
            );
        } else {
            std.log.err("failed to initialize GLFW (no error info)", .{});
        }
        return error.GlfwInitFailed;
    };
    defer glfw.terminate();

    var extent = vk.Extent2D{
        .width = 1280,
        .height = 720,
    };

    // ── Vulkan window setup: no client API (no OpenGL), Vulkan-only.
    glfw.defaultWindowHints();
    glfw.windowHint(glfw.c.GLFW_CLIENT_API, glfw.c.GLFW_NO_API);

    // Create window with no client API (Vulkan-only).
    const window = glfw.createWindow(
        @as(i32, @intCast(extent.width)),
        @as(i32, @intCast(extent.height)),
        window_title,
        null,
        null,
    ) catch {
        if (glfw.getLastError()) |err_info| {
            const code_opt = glfw.errorCodeFromC(err_info.code);
            const code_str = if (code_opt) |ce| @tagName(ce) else "UnknownError";
            const desc_str: []const u8 = err_info.description orelse "no description";

            std.log.err(
                "failed to create GLFW window: {s}: {s}",
                .{ code_str, desc_str },
            );
        } else {
            std.log.err("failed to create GLFW window (no error info)", .{});
        }
        return error.CreateWindowFailed;
    };
    defer glfw.destroyWindow(window);

    const allocator = std.heap.page_allocator;

    const gc = try GraphicsContext.init(allocator, app_name, window);
    defer gc.deinit();

    std.debug.print("Using device: {s}\n", .{gc.deviceName()});

    var swapchain = try Swapchain.init(&gc, allocator, extent);
    defer swapchain.deinit();

    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(&gc, swapchain);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    const pipeline = try createPipeline(&gc, pipeline_layout, render_pass);
    defer gc.vkd.destroyPipeline(gc.dev, pipeline, null);

    var framebuffers = try createFramebuffers(&gc, allocator, render_pass, swapchain);
    defer destroyFramebuffers(&gc, allocator, framebuffers);

    const pool = try gc.vkd.createCommandPool(gc.dev, &.{
        .flags = .{},
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.vkd.destroyCommandPool(gc.dev, pool, null);

    // GPU vertex buffer (device-local).
    const buffer = try gc.vkd.createBuffer(gc.dev, &.{
        .flags = .{},
        .size = VERTEX_BUFFER_SIZE,
        .usage = .{
            .transfer_dst_bit = true,
            .vertex_buffer_bit = true,
        },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer gc.vkd.destroyBuffer(gc.dev, buffer, null);

    const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, buffer);
    const memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
    defer gc.vkd.freeMemory(gc.dev, memory, null);
    try gc.vkd.bindBufferMemory(gc.dev, buffer, memory, 0);

    // Persistent staging buffer (host-visible) used to update the geometry each frame.
    const staging_buffer = try gc.vkd.createBuffer(gc.dev, &.{
        .flags = .{},
        .size = VERTEX_BUFFER_SIZE,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer gc.vkd.destroyBuffer(gc.dev, staging_buffer, null);

    const staging_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, staging_buffer);
    const staging_memory = try gc.allocate(staging_reqs, .{
        .host_visible_bit = true,
        .host_coherent_bit = true,
    });
    defer gc.vkd.freeMemory(gc.dev, staging_memory, null);
    try gc.vkd.bindBufferMemory(gc.dev, staging_buffer, staging_memory, 0);

    var cmdbufs = try createCommandBuffers(
        &gc,
        pool,
        allocator,
        buffer,
        swapchain.extent,
        render_pass,
        pipeline,
        framebuffers,
    );
    defer destroyCommandBuffers(&gc, pool, allocator, cmdbufs);

    // ─────────────────────────────────────────────────────────────────────
    // Camera + frame timer
    // ─────────────────────────────────────────────────────────────────────

    const pi_f32: f32 = @floatCast(std.math.pi);
    const initial_aspect: f32 =
        @as(f32, @floatFromInt(extent.width)) /
        @as(f32, @floatFromInt(extent.height));

    var camera = Camera3D.init(
        Vec3.init(0.0, 1.5, 5.0),
        pi_f32 / 3.0, // 60 degrees
        initial_aspect,
        0.1,
        100.0,
    );

    var frame_timer = FrameTimer.init(nowMsFromGlfw(), 1000); // 1s FPS window.

    // Prime the vertex buffer once so we don't start with garbage.
    {
        try updateSceneVertices(&gc, staging_memory, &camera);
        try copyBuffer(&gc, pool, buffer, staging_buffer, VERTEX_BUFFER_SIZE);
    }

    while (!glfw.windowShouldClose(window)) {
        const tick = frame_timer.tick(nowMsFromGlfw());
        const dt = @as(f32, @floatCast(tick.dt));

        // ESC to quit
        const esc_state = glfw.getKey(window, glfw.c.GLFW_KEY_ESCAPE);
        if (esc_state == glfw.c.GLFW_PRESS or esc_state == glfw.c.GLFW_REPEAT) {
            glfw.setWindowShouldClose(window, true);
        }

        if (tick.fps_updated) {
            std.log.info(
                "FPS: {d:.2}, cam=({d:.2}, {d:.2}, {d:.2})",
                .{ tick.fps, camera.position.x, camera.position.y, camera.position.z },
            );
            updateWindowTitle(window, tick.fps, &camera);
        }

        const cam_input = sampleCameraInput(window);
        camera.update(dt, cam_input);

        // Rebuild world → NDC vertices into staging, then copy to device-local buffer.
        try updateSceneVertices(&gc, staging_memory, &camera);
        try copyBuffer(&gc, pool, buffer, staging_buffer, VERTEX_BUFFER_SIZE);

        const cmdbuf = cmdbufs[swapchain.image_index];

        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal) {
            const size = glfw.getWindowSize(window);

            // Handle minimized / zero-size window safely.
            if (size.width == 0 or size.height == 0) {
                glfw.pollEvents();
                continue;
            }

            extent.width = @intCast(size.width);
            extent.height = @intCast(size.height);

            try swapchain.recreate(extent);

            const new_aspect: f32 =
                @as(f32, @floatFromInt(extent.width)) /
                @as(f32, @floatFromInt(extent.height));

            camera.setAspect(new_aspect);

            destroyFramebuffers(&gc, allocator, framebuffers);
            framebuffers = try createFramebuffers(&gc, allocator, render_pass, swapchain);

            destroyCommandBuffers(&gc, pool, allocator, cmdbufs);
            cmdbufs = try createCommandBuffers(
                &gc,
                pool,
                allocator,
                buffer,
                swapchain.extent,
                render_pass,
                pipeline,
                framebuffers,
            );
        }

        glfw.pollEvents();
    }

    try swapchain.waitForAllFences();
}

// ─────────────────────────────────────────────────────────────────────────────
// Camera input sampling (WASD + Space/Ctrl + RMB look)
// ─────────────────────────────────────────────────────────────────────────────

fn sampleCameraInput(window: *glfw.Window) CameraInput {
    var ci: CameraInput = .{};

    // Movement: WASD + Space/Ctrl
    const w_state = glfw.getKey(window, glfw.c.GLFW_KEY_W);
    const s_state = glfw.getKey(window, glfw.c.GLFW_KEY_S);
    const a_state = glfw.getKey(window, glfw.c.GLFW_KEY_A);
    const d_state = glfw.getKey(window, glfw.c.GLFW_KEY_D);
    const space_state = glfw.getKey(window, glfw.c.GLFW_KEY_SPACE);
    const ctrl_state = glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_CONTROL);

    if (w_state == glfw.c.GLFW_PRESS or w_state == glfw.c.GLFW_REPEAT) {
        ci.move_forward = true;
    }
    if (s_state == glfw.c.GLFW_PRESS or s_state == glfw.c.GLFW_REPEAT) {
        ci.move_backward = true;
    }
    if (a_state == glfw.c.GLFW_PRESS or a_state == glfw.c.GLFW_REPEAT) {
        ci.move_left = true;
    }
    if (d_state == glfw.c.GLFW_PRESS or d_state == glfw.c.GLFW_REPEAT) {
        ci.move_right = true;
    }
    if (space_state == glfw.c.GLFW_PRESS or space_state == glfw.c.GLFW_REPEAT) {
        ci.move_up = true;
    }
    if (ctrl_state == glfw.c.GLFW_PRESS or ctrl_state == glfw.c.GLFW_REPEAT) {
        ci.move_down = true;
    }

    // RMB drag → look (yaw/pitch)
    const rmb = glfw.getMouseButton(window, glfw.c.GLFW_MOUSE_BUTTON_RIGHT);

    const State = struct {
        var last_pos: ?struct { x: f64, y: f64 } = null;
    };

    if (rmb == glfw.c.GLFW_PRESS) {
        const pos = glfw.getCursorPos(window);

        if (State.last_pos) |last| {
            const dx = pos.x - last.x;
            const dy = pos.y - last.y;

            ci.look_delta_x = @as(f32, @floatCast(dx));
            ci.look_delta_y = @as(f32, @floatCast(dy));
        }

        State.last_pos = .{ .x = pos.x, .y = pos.y };
    } else {
        State.last_pos = null;
    }

    return ci;
}

// ─────────────────────────────────────────────────────────────────────────────
// Geometry update: Scene → Vertex buffer (CPU-side view-projection)
// ─────────────────────────────────────────────────────────────────────────────

fn updateSceneVertices(
    gc: *const GraphicsContext,
    staging_memory: vk.DeviceMemory,
    camera: *const Camera3D,
) !void {
    const data = try gc.vkd.mapMemory(gc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
    defer gc.vkd.unmapMemory(gc.dev, staging_memory);

    const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));

    const view_proj = camera.viewProjMatrix();

    for (scene_vertices, 0..) |sv, i| {
        // Convert [3]f32 → Vec3 for mulPoint3
        const world = Vec3.init(sv.pos[0], sv.pos[1], sv.pos[2]);
        const projected = view_proj.mulPoint3(world); // Vec3 in NDC (after perspective divide)

        const ndc = [3]f32{ projected.x, projected.y, projected.z };

        gpu_vertices[i] = .{
            .pos = ndc,
            .color = sv.color,
        };
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buffer copy
// ─────────────────────────────────────────────────────────────────────────────

fn copyBuffer(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    dst: vk.Buffer,
    src: vk.Buffer,
    size: vk.DeviceSize,
) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.vkd.allocateCommandBuffers(gc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.vkd.freeCommandBuffers(gc.dev, pool, 1, @ptrCast(&cmdbuf));

    try gc.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
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

// ─────────────────────────────────────────────────────────────────────────────
// Command buffers
// ─────────────────────────────────────────────────────────────────────────────

fn createCommandBuffers(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    allocator: Allocator,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
) ![]vk.CommandBuffer {
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    errdefer allocator.free(cmdbufs);

    try gc.vkd.allocateCommandBuffers(gc.dev, &vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @truncate(cmdbufs.len),
    }, cmdbufs.ptr);
    errdefer gc.vkd.freeCommandBuffers(gc.dev, pool, @truncate(cmdbufs.len), cmdbufs.ptr);

    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @as(f32, @floatFromInt(extent.width)),
        .height = @as(f32, @floatFromInt(extent.height)),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    for (cmdbufs, 0..) |cmdbuf, i| {
        try gc.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{},
            .p_inheritance_info = null,
        });

        gc.vkd.cmdSetViewport(
            cmdbuf,
            0,
            1,
            @as([*]const vk.Viewport, @ptrCast(&viewport)),
        );
        gc.vkd.cmdSetScissor(
            cmdbuf,
            0,
            1,
            @as([*]const vk.Rect2D, @ptrCast(&scissor)),
        );

        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        gc.vkd.cmdBeginRenderPass(cmdbuf, &.{
            .render_pass = render_pass,
            .framebuffer = framebuffers[i],
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @as([*]const vk.ClearValue, @ptrCast(&clear)),
        }, .@"inline");

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);

        const offset = [_]vk.DeviceSize{0};
        gc.vkd.cmdBindVertexBuffers(
            cmdbuf,
            0,
            1,
            @as([*]const vk.Buffer, @ptrCast(&buffer)),
            &offset,
        );

        gc.vkd.cmdDraw(cmdbuf, TOTAL_VERTICES, 1, 0, 0);

        gc.vkd.cmdEndRenderPass(cmdbuf);
        try gc.vkd.endCommandBuffer(cmdbuf);
    }

    return cmdbufs;
}

fn destroyCommandBuffers(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    allocator: Allocator,
    cmdbufs: []vk.CommandBuffer,
) void {
    gc.vkd.freeCommandBuffers(gc.dev, pool, @truncate(cmdbufs.len), cmdbufs.ptr);
    allocator.free(cmdbufs);
}

// ─────────────────────────────────────────────────────────────────────────────
// Framebuffers
// ─────────────────────────────────────────────────────────────────────────────

fn createFramebuffers(
    gc: *const GraphicsContext,
    allocator: Allocator,
    render_pass: vk.RenderPass,
    swapchain: Swapchain,
) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| {
        gc.vkd.destroyFramebuffer(gc.dev, fb, null);
    };

    for (framebuffers) |*fb| {
        fb.* = try gc.vkd.createFramebuffer(gc.dev, &vk.FramebufferCreateInfo{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&swapchain.swap_images[i].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(
    gc: *const GraphicsContext,
    allocator: Allocator,
    framebuffers: []const vk.Framebuffer,
) void {
    for (framebuffers) |fb| {
        gc.vkd.destroyFramebuffer(gc.dev, fb, null);
    }
    allocator.free(framebuffers);
}

// ─────────────────────────────────────────────────────────────────────────────
// Render pass / pipeline
// ─────────────────────────────────────────────────────────────────────────────

fn createRenderPass(gc: *const GraphicsContext, swapchain: Swapchain) !vk.RenderPass {
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

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    return try gc.vkd.createRenderPass(gc.dev, &vk.RenderPassCreateInfo{
        .flags = .{},
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 0,
        .p_dependencies = undefined,
    }, null);
}

fn createPipeline(
    gc: *const GraphicsContext,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
) !vk.Pipeline {
    const vert = try gc.vkd.createShaderModule(gc.dev, &vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = triangle_vert.len,
        .p_code = @ptrCast(@alignCast(triangle_vert)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, vert, null);

    const frag = try gc.vkd.createShaderModule(gc.dev, &vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = triangle_frag.len,
        .p_code = @ptrCast(@alignCast(triangle_frag)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, frag, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
            .p_specialization_info = null,
        },
        .{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
            .p_specialization_info = null,
        },
    };

    const pvisci = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @as(
            [*]const vk.VertexInputBindingDescription,
            @ptrCast(&Vertex.binding_description),
        ),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
    };

    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = VK_FALSE32,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = undefined,
        .scissor_count = 1,
        .p_scissors = undefined,
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = VK_FALSE32,
        .rasterizer_discard_enable = VK_FALSE32,
        .polygon_mode = .fill,
        // IMPORTANT: disable culling for now so we see everything
        .cull_mode = .{}, // no bits set → no culling
        .front_face = .clockwise,
        .depth_bias_enable = VK_FALSE32,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = VK_FALSE32,
        .min_sample_shading = 1,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = VK_FALSE32,
        .alpha_to_one_enable = VK_FALSE32,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = VK_FALSE32,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = VK_FALSE32,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @as(
            [*]const vk.PipelineColorBlendAttachmentState,
            @ptrCast(&pcbas),
        ),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
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
