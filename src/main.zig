const std = @import("std");
const glfw = @import("glfw");
const vk = @import("vulkan");

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

// Optional: present alongside the exe; not directly used in this file.
const vert_spv = @embedFile("generated/shaders/triangle_vert");
const frag_spv = @embedFile("generated/shaders/triangle_frag");

const Allocator = std.mem.Allocator;

const VK_FALSE32: vk.Bool32 = @enumFromInt(vk.FALSE);
const VK_TRUE32: vk.Bool32 = @enumFromInt(vk.TRUE);

const window_title_cstr: [*:0]const u8 = "VRGame — Zigadel Prototype\x00";
const window_title_base: []const u8 = "VRGame — Zigadel Prototype";

// ─────────────────────────────────────────────────────────────────────────────
// World geo: axis-aligned checkerboard floor in WORLD SPACE
// ─────────────────────────────────────────────────────────────────────────────
const GRID_HALF: i32 = 64;
const GRID_STEP: f32 = 1.0;
const GRID_SIZE: i32 = GRID_HALF * 2;
const QUAD_COUNT: usize = @intCast(GRID_SIZE * GRID_SIZE);
const FLOOR_VERTS: u32 = @intCast(QUAD_COUNT * 6);

const TOTAL_VERTICES: u32 = FLOOR_VERTS;
const VERTEX_BUFFER_SIZE: vk.DeviceSize =
    @intCast(@as(usize, TOTAL_VERTICES) * @sizeOf(Vertex));

// Depth resources
const DepthResources = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
};

// Push-constant block (std430 layout, 16*4 bytes)
const Push = extern struct { m: [16]f32 };

fn readWholeFile(alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const limit: std.Io.Limit = @enumFromInt(max_bytes);
    return try std.fs.cwd().readFileAlloc(path, alloc, limit);
}

fn loadSpirvFromExeDirAligned(alloc: Allocator, rel: []const u8) ![]u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(alloc);
    defer alloc.free(exe_dir);

    const full = try std.fs.path.join(alloc, &.{ exe_dir, rel });
    defer alloc.free(full);

    var tmp = try readWholeFile(alloc, full, 16 * 1024 * 1024);
    defer alloc.free(tmp);

    if (tmp.len % 4 != 0) return error.BadSpirvSize;

    const out = try alloc.alignedAlloc(u8, .@"4", tmp.len);
    @memcpy(out, tmp);
    return out;
}

fn updateWindowTitle(window: *glfw.Window, fps: f64, cam: *const Camera3D) void {
    var buf: [200]u8 = undefined;
    const title = std.fmt.bufPrintZ(
        &buf,
        "{s} | FPS: {d:.1} | Cam: x={d:.2}, y={d:.2}, z={d:.2}",
        .{ window_title_base, fps, cam.position.x, cam.position.y, cam.position.z },
    ) catch return;
    glfw.setWindowTitle(window, title);
}

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

fn sampleCameraInput(window: *glfw.Window) CameraInput {
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
    const rmb = glfw.getMouseButton(window, glfw.c.GLFW_MOUSE_BUTTON_RIGHT);
    if (rmb == glfw.c.GLFW_PRESS) {
        const raw = glfw.getCursorPos(window);
        const pos = [2]f64{ raw.x, raw.y };
        if (CursorState.last_pos) |prev| {
            const dx = pos[0] - prev[0];
            const dy = pos[1] - prev[1];
            ci.look_delta_x = @as(f32, @floatCast(dx));
            ci.look_delta_y = @as(f32, @floatCast(dy));
        }
        CursorState.last_pos = pos;
    } else {
        CursorState.last_pos = null;
    }
    return ci;
}

// ─────────────────────────────────────────────────────────────────────────────
// Depth helpers
// ─────────────────────────────────────────────────────────────────────────────
fn createDepthResources(gc: *const GraphicsContext, format: vk.Format, extent: vk.Extent2D) !DepthResources {
    const img = try gc.vkd.createImage(gc.dev, &vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    }, null);

    const reqs = gc.vkd.getImageMemoryRequirements(gc.dev, img);
    const mem = try gc.allocate(reqs, .{ .device_local_bit = true });
    try gc.vkd.bindImageMemory(gc.dev, img, mem, 0);

    const view = try gc.vkd.createImageView(gc.dev, &vk.ImageViewCreateInfo{
        .flags = .{},
        .image = img,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);

    return .{ .image = img, .memory = mem, .view = view };
}

fn destroyDepthResources(gc: *const GraphicsContext, depth: DepthResources) void {
    gc.vkd.destroyImageView(gc.dev, depth.view, null);
    gc.vkd.destroyImage(gc.dev, depth.image, null);
    gc.vkd.freeMemory(gc.dev, depth.memory, null);
}

// ─────────────────────────────────────────────────────────────────────────────
// Geometry: fill WORLD-SPACE floor (once)
// ─────────────────────────────────────────────────────────────────────────────
fn writeFloorWorld(verts: [*]Vertex) void {
    var idx: usize = 0;
    const half: i32 = GRID_HALF;
    const step: f32 = GRID_STEP;

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

            const ix: i32 = x + GRID_HALF;
            const iz: i32 = z + GRID_HALF;
            const is_light = (((ix + iz) & 1) == 0);
            const color: [3]f32 = if (is_light)
                .{ 0.86, 0.88, 0.92 }
            else
                .{ 0.20, 0.22, 0.26 };

            verts[idx + 0] = .{ .pos = p00, .color = color };
            verts[idx + 1] = .{ .pos = p10, .color = color };
            verts[idx + 2] = .{ .pos = p11, .color = color };
            verts[idx + 3] = .{ .pos = p00, .color = color };
            verts[idx + 4] = .{ .pos = p11, .color = color };
            verts[idx + 5] = .{ .pos = p01, .color = color };
            idx += 6;
        }
    }
    std.debug.assert(idx == @as(usize, TOTAL_VERTICES));
}

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────
pub fn main() !void {
    _ = glfw.setErrorCallback(errorCallback);
    try glfw.init();
    defer glfw.terminate();

    // Start with a logical window size; swapchain will pick the real pixel size.
    var desired_window_extent = vk.Extent2D{ .width = 1280, .height = 800 };

    glfw.defaultWindowHints();
    glfw.windowHint(glfw.c.GLFW_CLIENT_API, glfw.c.GLFW_NO_API);

    if (glfw.getPrimaryMonitor()) |mon| {
        const wa = glfw.getMonitorWorkarea(mon);
        if (wa.width > 0 and wa.height > 0) {
            desired_window_extent.width = @intCast(@divTrunc(wa.width * 3, 4));
            desired_window_extent.height = @intCast(@divTrunc(wa.height * 3, 4));
        } else if (glfw.getVideoMode(mon)) |vm| {
            desired_window_extent.width = @intCast(@divTrunc(vm.width * 3, 4));
            desired_window_extent.height = @intCast(@divTrunc(vm.height * 3, 4));
        }
    }

    const window = try glfw.createWindow(
        @as(i32, @intCast(desired_window_extent.width)),
        @as(i32, @intCast(desired_window_extent.height)),
        window_title_cstr,
        null,
        null,
    );
    defer glfw.destroyWindow(window);

    const allocator = std.heap.c_allocator;
    var gc = try GraphicsContext.init(allocator, window_title_cstr, window);
    defer gc.deinit();

    // Use framebuffer pixels (Retina-aware) for the swapchain extent.
    var extent = gc.framebufferExtent();

    var swapchain = try Swapchain.init(&gc, allocator, extent);
    defer swapchain.deinit();

    // Keep local 'extent' synchronized with the swapchain's real extent.
    extent = swapchain.extent;

    // Pipeline layout with push constants (mat4 VP)
    const push_range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = @sizeOf(Push),
    };
    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &vk.PipelineLayoutCreateInfo{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_range),
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const depth_format: vk.Format = .d32_sfloat;
    var depth = try createDepthResources(&gc, depth_format, extent);
    defer destroyDepthResources(&gc, depth);

    const render_pass = try createRenderPass(&gc, swapchain, depth_format);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    const pipeline = try createPipeline(&gc, pipeline_layout, render_pass);
    defer gc.vkd.destroyPipeline(gc.dev, pipeline, null);

    var framebuffers = try createFramebuffers(&gc, allocator, render_pass, swapchain, depth.view);
    defer destroyFramebuffers(&gc, allocator, framebuffers);

    // Command pool can reset individual buffers
    const cmd_pool = try gc.vkd.createCommandPool(gc.dev, &vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.vkd.destroyCommandPool(gc.dev, cmd_pool, null);

    // Vertex buffers
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

    // Allocate per-swapchain command buffers
    var cmdbufs = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    defer allocator.free(cmdbufs);
    try gc.vkd.allocateCommandBuffers(gc.dev, &vk.CommandBufferAllocateInfo{
        .command_pool = cmd_pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);

    // Write world-space floor once into staging, copy to device-local
    {
        const ptr = try gc.vkd.mapMemory(gc.dev, smem, 0, vk.WHOLE_SIZE, .{});
        defer gc.vkd.unmapMemory(gc.dev, smem);
        const verts: [*]Vertex = @ptrCast(@alignCast(ptr));
        writeFloorWorld(verts);
        try copyBuffer(&gc, cmd_pool, vbuf, sbuf, VERTEX_BUFFER_SIZE);
    }

    var camera = Camera3D.init(
        Vec3.init(0.0, 1.7, 4.0),
        (@as(f32, @floatFromInt(70)) * (@as(f32, @floatCast(std.math.pi)) / 180.0)),
        @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height)),
        0.1,
        500.0,
    );

    var frame_timer = FrameTimer.init(nowMsFromGlfw(), 1000);

    while (!glfw.windowShouldClose(window)) {
        const tick = frame_timer.tick(nowMsFromGlfw());
        var dt = @as(f32, @floatCast(tick.dt));
        if (tick.fps_updated) updateWindowTitle(window, tick.fps, &camera);

        const esc = glfw.getKey(window, glfw.c.GLFW_KEY_ESCAPE);
        if (esc == glfw.c.GLFW_PRESS or esc == glfw.c.GLFW_REPEAT) glfw.setWindowShouldClose(window, true);

        const ls = glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_SHIFT);
        const rs = glfw.getKey(window, glfw.c.GLFW_KEY_RIGHT_SHIFT);
        if (ls == glfw.c.GLFW_PRESS or ls == glfw.c.GLFW_REPEAT or rs == glfw.c.GLFW_PRESS or rs == glfw.c.GLFW_REPEAT) {
            dt *= 2.5;
        }

        const input = sampleCameraInput(window);
        camera.update(dt, input);

        // Acquire cmdbuf for current image
        const cmdbuf = cmdbufs[swapchain.image_index];

        // Record draw
        try gc.vkd.resetCommandBuffer(cmdbuf, .{});
        try gc.vkd.beginCommandBuffer(cmdbuf, &vk.CommandBufferBeginInfo{
            .flags = .{},
            .p_inheritance_info = null,
        });

        // Viewport/scissor from *actual framebuffer pixels* (fixes Retina)
        swapchain.cmdSetViewportAndScissor(&gc, cmdbuf);

        const clear_color = vk.ClearValue{ .color = .{ .float_32 = .{ 0.05, 0.05, 0.07, 1.0 } } };
        const clear_depth = vk.ClearValue{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } };
        var clears = [_]vk.ClearValue{ clear_color, clear_depth };

        const rp_begin = vk.RenderPassBeginInfo{
            .render_pass = render_pass,
            .framebuffer = framebuffers[swapchain.image_index],
            // Use the swapchain's real extent, not the logical window size.
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
            .clear_value_count = @intCast(clears.len),
            .p_clear_values = &clears,
        };
        gc.vkd.cmdBeginRenderPass(cmdbuf, &rp_begin, vk.SubpassContents.@"inline");

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);

        const offsets = [_]vk.DeviceSize{0};
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @as([*]const vk.Buffer, @ptrCast(&vbuf)), &offsets);

        // Push VP (aspect already matches pixels)
        const push = Push{ .m = camera.viewProjMatrix().m };
        gc.vkd.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(Push), @ptrCast(&push));

        gc.vkd.cmdDraw(cmdbuf, TOTAL_VERTICES, 1, 0, 0);
        gc.vkd.cmdEndRenderPass(cmdbuf);
        try gc.vkd.endCommandBuffer(cmdbuf);

        // Present
        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        // Handle resize either via suboptimal present or explicit GLFW callback flag.
        if (state == .suboptimal or gc.takeResizeFlag()) {
            // Get the current framebuffer size in pixels.
            const fb = gc.framebufferExtent();
            if (fb.width == 0 or fb.height == 0) {
                glfw.pollEvents();
                continue;
            }

            // Recreate swapchain & size-dependent resources.
            try swapchain.recreate(fb);
            extent = swapchain.extent;

            const new_aspect: f32 =
                @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height));
            if (comptime @hasField(@TypeOf(camera), "aspect")) camera.aspect = new_aspect;

            destroyFramebuffers(&gc, allocator, framebuffers);
            destroyDepthResources(&gc, depth);
            depth = try createDepthResources(&gc, depth_format, extent);
            framebuffers = try createFramebuffers(&gc, allocator, render_pass, swapchain, depth.view);
        }

        glfw.pollEvents();
    }

    try swapchain.waitForAllFences();
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

// ─────────────────────────────────────────────────────────────────────────────
fn createFramebuffers(
    gc: *const GraphicsContext,
    allocator: Allocator,
    render_pass: vk.RenderPass,
    swapchain: Swapchain,
    depth_view: vk.ImageView,
) ![]vk.Framebuffer {
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

fn destroyFramebuffers(
    gc: *const GraphicsContext,
    allocator: Allocator,
    framebuffers: []const vk.Framebuffer,
) void {
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

fn createPipeline(
    gc: *const GraphicsContext,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
) !vk.Pipeline {
    const A = std.heap.c_allocator;
    const vert_bytes = try loadSpirvFromExeDirAligned(A, "shaders/triangle_vert");
    defer A.free(vert_bytes);
    const frag_bytes = try loadSpirvFromExeDirAligned(A, "shaders/triangle_frag");
    defer A.free(frag_bytes);

    const vert = try gc.vkd.createShaderModule(gc.dev, &vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = vert_bytes.len,
        .p_code = @ptrCast(@alignCast(vert_bytes.ptr)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, vert, null);

    const frag = try gc.vkd.createShaderModule(gc.dev, &vk.ShaderModuleCreateInfo{
        .flags = .{},
        .code_size = frag_bytes.len,
        .p_code = @ptrCast(@alignCast(frag_bytes.ptr)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .flags = .{}, .stage = .{ .vertex_bit = true }, .module = vert, .p_name = "main", .p_specialization_info = null },
        .{ .flags = .{}, .stage = .{ .fragment_bit = true }, .module = frag, .p_name = "main", .p_specialization_info = null },
    };

    const vi = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @as([*]const vk.VertexInputBindingDescription, @ptrCast(&Vertex.binding_description)),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = @as([*]const vk.VertexInputAttributeDescription, @ptrCast(&Vertex.attribute_description)),
    };

    const ia = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = VK_FALSE32,
    };

    const vp = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = undefined, // dynamic
        .scissor_count = 1,
        .p_scissors = undefined, // dynamic
    };

    const rs = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = VK_FALSE32,
        .rasterizer_discard_enable = VK_FALSE32,
        .polygon_mode = .fill,
        .cull_mode = .{}, // no culling for demo
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
    const dyn_state = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dyn.len,
        .p_dynamic_states = &dyn,
    };

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
