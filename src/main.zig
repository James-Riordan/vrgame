const std = @import("std");
const glfw = @import("glfw");
const vk = @import("vulkan");

const GraphicsContext = @import("graphics_context").GraphicsContext;
const Swapchain = @import("swapchain").Swapchain;
const Vertex = @import("vertex").Vertex;

const frame_time = @import("frame_time");
const FrameTimer = frame_time.FrameTimer;

const game = @import("game");
const InputState = game.InputState;
const Game = game.Game;

const camera3d = @import("camera3d");
const Camera3D = camera3d.Camera3D;
const CameraInput = camera3d.CameraInput;

// 3D math module used by Camera3D and for CPU-side transforms.
const math3d = @import("math3d");
const Vec3 = math3d.Vec3;
const Mat4 = math3d.Mat4;

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
// Hero / enemy geometry templates (local offsets in world units)
// ─────────────────────────────────────────────────────────────────────────────
//
// These are small triangles in local space. We position them in world-space
// based on the Game's hero/enemy positions, then transform via Camera3D.

const hero_template = [_]Vertex{
    .{ .pos = .{ 0.0, 0.20, 0.0 }, .color = .{ 0.9, 0.9, 0.9 } }, // tip
    .{ .pos = .{ -0.12, -0.12, 0.0 }, .color = .{ 0.2, 0.8, 1.0 } },
    .{ .pos = .{ 0.12, -0.12, 0.0 }, .color = .{ 0.2, 0.8, 1.0 } },
};

const enemy_template = [_]Vertex{
    .{ .pos = .{ 0.0, 0.22, 0.0 }, .color = .{ 1.0, 0.3, 0.3 } },
    .{ .pos = .{ -0.14, -0.14, 0.0 }, .color = .{ 0.8, 0.2, 0.2 } },
    .{ .pos = .{ 0.14, -0.14, 0.0 }, .color = .{ 0.8, 0.2, 0.2 } },
};

// Simple ground quad made of two triangles in XZ plane at y = -1.
// This will *visibly* show perspective when you move/fly the camera.
const ground_template = [_]Vertex{
    // Triangle 1
    .{ .pos = .{ -10.0, -1.0, -10.0 }, .color = .{ 0.15, 0.45, 0.15 } },
    .{ .pos = .{ 10.0, -1.0, -10.0 }, .color = .{ 0.18, 0.55, 0.18 } },
    .{ .pos = .{ 10.0, -1.0, 10.0 }, .color = .{ 0.12, 0.35, 0.12 } },

    // Triangle 2
    .{ .pos = .{ -10.0, -1.0, -10.0 }, .color = .{ 0.15, 0.45, 0.15 } },
    .{ .pos = .{ 10.0, -1.0, 10.0 }, .color = .{ 0.12, 0.35, 0.12 } },
    .{ .pos = .{ -10.0, -1.0, 10.0 }, .color = .{ 0.18, 0.55, 0.18 } },
};

const TOTAL_VERTICES: u32 =
    hero_template.len +
    enemy_template.len +
    ground_template.len;

const VERTEX_BUFFER_SIZE: vk.DeviceSize =
    @intCast(@as(usize, TOTAL_VERTICES) * @sizeOf(Vertex));

// ─────────────────────────────────────────────────────────────────────────────
// Utility
// ─────────────────────────────────────────────────────────────────────────────

fn updateWindowTitle(window: *glfw.Window, fps: f64, g: *const Game) void {
    // Small fixed buffer for the title; avoid heap allocation.
    var buf: [160]u8 = undefined;

    const title = std.fmt.bufPrintZ(
        &buf,
        "VRGame — Zigadel Prototype | FPS: {d:.1} | Hero: x={d:.2}, y={d:.2} | Score: {d}",
        .{ fps, g.player_x, g.player_y, g.score },
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
// Input sampling
// ─────────────────────────────────────────────────────────────────────────────

/// Game input: for now, only ESC to quit. Movement is handled by CameraInput.
fn sampleInput(window: *glfw.Window) InputState {
    var state: InputState = .{};

    const esc_state = glfw.getKey(window, glfw.c.GLFW_KEY_ESCAPE);
    if (esc_state == glfw.c.GLFW_PRESS or esc_state == glfw.c.GLFW_REPEAT) {
        state.quit = true;
    }

    return state;
}

/// Camera input: WASD + Space/Ctrl for movement, RMB drag for look.
fn sampleCameraInput(window: *glfw.Window) CameraInput {
    var ci: CameraInput = .{};

    // Movement: WASD
    const w_state = glfw.getKey(window, glfw.c.GLFW_KEY_W);
    const s_state = glfw.getKey(window, glfw.c.GLFW_KEY_S);
    const a_state = glfw.getKey(window, glfw.c.GLFW_KEY_A);
    const d_state = glfw.getKey(window, glfw.c.GLFW_KEY_D);

    if (w_state == glfw.c.GLFW_PRESS or w_state == glfw.c.GLFW_REPEAT) ci.move_forward = true;
    if (s_state == glfw.c.GLFW_PRESS or s_state == glfw.c.GLFW_REPEAT) ci.move_backward = true;
    if (a_state == glfw.c.GLFW_PRESS or a_state == glfw.c.GLFW_REPEAT) ci.move_left = true;
    if (d_state == glfw.c.GLFW_PRESS or d_state == glfw.c.GLFW_REPEAT) ci.move_right = true;

    // Vertical movement: Space (up), Left Ctrl (down)
    const space_state = glfw.getKey(window, glfw.c.GLFW_KEY_SPACE);
    const ctrl_state = glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_CONTROL);

    if (space_state == glfw.c.GLFW_PRESS or space_state == glfw.c.GLFW_REPEAT) ci.move_up = true;
    if (ctrl_state == glfw.c.GLFW_PRESS or ctrl_state == glfw.c.GLFW_REPEAT) ci.move_down = true;

    // Mouse look: right mouse button drag.
    const rmb = glfw.getMouseButton(window, glfw.c.GLFW_MOUSE_BUTTON_RIGHT);

    const State = struct {
        var last_x: f64 = 0.0;
        var last_y: f64 = 0.0;
        var has_last: bool = false;
    };

    if (rmb == glfw.c.GLFW_PRESS) {
        const pos = glfw.getCursorPos(window);

        if (State.has_last) {
            const dx = pos.x - State.last_x;
            const dy = pos.y - State.last_y;

            ci.look_delta_x = @as(f32, @floatCast(dx));
            ci.look_delta_y = @as(f32, @floatCast(dy));
        }

        State.last_x = pos.x;
        State.last_y = pos.y;
        State.has_last = true;
    } else {
        State.has_last = false;
    }

    return ci;
}

// ─────────────────────────────────────────────────────────────────────────────
// Geometry update: Game + Camera3D → Vertex buffer
// ─────────────────────────────────────────────────────────────────────────────

fn updateWorldVertices(
    gc: *const GraphicsContext,
    staging_memory: vk.DeviceMemory,
    g: *const Game,
    camera: *const Camera3D,
) !void {
    const data = try gc.vkd.mapMemory(gc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
    defer gc.vkd.unmapMemory(gc.dev, staging_memory);

    const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));

    const view_proj: Mat4 = camera.viewProjMatrix();

    const hero_xy = g.heroPosition();
    const enemy_xy = g.enemyPosition();

    const hero_origin = Vec3.init(hero_xy[0], hero_xy[1], 0.0);
    const enemy_origin = Vec3.init(enemy_xy[0], enemy_xy[1], 0.0);

    var idx: usize = 0;

    // ── Hero (no flash) ──────────────────────────────────────────────────
    for (hero_template) |v| {
        const local = Vec3.init(v.pos[0], v.pos[1], v.pos[2]);
        const world = hero_origin.add(local);
        const clip = view_proj.mulPoint3(world);

        gpu_vertices[idx] = .{
            .pos = .{ clip.x, clip.y, clip.z },
            .color = v.color,
        };
        idx += 1;
    }

    // ── Enemy (flash white when recently hit) ────────────────────────────
    const flash = g.hitFlashIntensity();
    const inv_flash = 1.0 - flash;
    const flash_color = [_]f32{ 1.0, 1.0, 1.0 };

    for (enemy_template) |v| {
        const local = Vec3.init(v.pos[0], v.pos[1], v.pos[2]);
        const world = enemy_origin.add(local);
        const clip = view_proj.mulPoint3(world);

        const c = v.color;
        gpu_vertices[idx] = .{
            .pos = .{ clip.x, clip.y, clip.z },
            .color = .{
                c[0] * inv_flash + flash_color[0] * flash,
                c[1] * inv_flash + flash_color[1] * flash,
                c[2] * inv_flash + flash_color[2] * flash,
            },
        };
        idx += 1;
    }

    // ── Ground (static world geometry) ───────────────────────────────────
    for (ground_template) |v| {
        const world = Vec3.init(v.pos[0], v.pos[1], v.pos[2]);
        const clip = view_proj.mulPoint3(world);

        gpu_vertices[idx] = .{
            .pos = .{ clip.x, clip.y, clip.z },
            .color = v.color,
        };
        idx += 1;
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
        .cull_mode = .{ .back_bit = true },
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
        .width = 800,
        .height = 600,
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

    // Camera setup: simple free-fly camera starting at (0, 0, 5)
    const aspect: f32 =
        @as(f32, @floatFromInt(swapchain.extent.width)) /
        @as(f32, @floatFromInt(swapchain.extent.height));
    const fov_y: f32 = @as(f32, @floatCast(std.math.pi)) / 3.0; // ~60°
    var camera = Camera3D.init(
        Vec3.init(0.0, 0.0, 5.0),
        fov_y,
        aspect,
        0.1,
        100.0,
    );

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
    // Game state + frame timer
    // ─────────────────────────────────────────────────────────────────────

    var game_state = Game.init();
    var frame_timer = FrameTimer.init(nowMsFromGlfw(), 1000); // 1s FPS window.

    // Prime the vertex buffer once so we don't start with garbage.
    {
        try updateWorldVertices(&gc, staging_memory, &game_state, &camera);
        try copyBuffer(&gc, pool, buffer, staging_buffer, VERTEX_BUFFER_SIZE);
    }

    while (!glfw.windowShouldClose(window)) {
        const tick = frame_timer.tick(nowMsFromGlfw());
        const dt = @as(f32, @floatCast(tick.dt));

        if (tick.fps_updated) {
            std.log.info(
                "FPS: {d:.2}, hero=({d:.2}, {d:.2}), score={d}",
                .{ tick.fps, game_state.player_x, game_state.player_y, game_state.score },
            );
            updateWindowTitle(window, tick.fps, &game_state);
        }

        // Camera controls (WASD + Space/Ctrl + RMB look).
        const cam_input = sampleCameraInput(window);
        camera.update(dt, cam_input);

        // Game input (Esc to quit).
        const input = sampleInput(window);
        if (input.quit) {
            glfw.setWindowShouldClose(window, true);
            break;
        }

        // Advance simple hero/enemy logic.
        game_state.update(dt, input);

        // Rebuild world → NDC vertices into staging, then copy to device-local buffer.
        try updateWorldVertices(&gc, staging_memory, &game_state, &camera);
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

            // Keep camera projection in sync with new swapchain size.
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
