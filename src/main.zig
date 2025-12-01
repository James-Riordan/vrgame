const std = @import("std");
const builtin = @import("builtin");
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

const Allocator = std.mem.Allocator;

const VK_FALSE32: vk.Bool32 = @enumFromInt(vk.FALSE);
const VK_TRUE32: vk.Bool32 = @enumFromInt(vk.TRUE);

const window_title_cstr: [*:0]const u8 = "VRGame — Zigadel Prototype\x00";
const window_title_base: []const u8 = "VRGame — Zigadel Prototype";

// ── World grid
const GRID_HALF: i32 = 64;
const GRID_STEP: f32 = 1.0;
const GRID_SIZE: i32 = GRID_HALF * 2;
const QUAD_COUNT: usize = @intCast(GRID_SIZE * GRID_SIZE);
const FLOOR_VERTS: u32 = @intCast(QUAD_COUNT * 6);
const CUBE_VERTS: u32 = 36;
const TOTAL_VERTICES: u32 = FLOOR_VERTS + CUBE_VERTS;
const VERTEX_BUFFER_SIZE: vk.DeviceSize =
    @intCast(@as(usize, TOTAL_VERTICES) * @sizeOf(Vertex));

// Depth resources
const DepthResources = struct { image: vk.Image, memory: vk.DeviceMemory, view: vk.ImageView };

// Push-constant block (std430)
const Push = extern struct { model: [16]f32 };

// Camera UBO
const CameraUBO = extern struct { vp: [16]f32 };

// ── Y-flip policy: always flip via negative viewport height (portable & correct)
const VIEWPORT_Y_FLIP: bool = true;
const PROJECTION_Y_FLIP: bool = false;

// ── Clock helpers
fn nowMsFromGlfw() i64 {
    return @as(i64, @intFromFloat(glfw.getTime() * 1000.0));
}

// ── GLFW error hook
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

// Poll until the framebuffer has non-zero size (prevents zero-extent swapchain).
fn waitForNonZeroFramebuffer(window: *glfw.Window) void {
    const deadline = nowMsFromGlfw() + 250;
    while (true) {
        const fb = glfw.getFramebufferSize(window);
        if (fb.width > 0 and fb.height > 0) break;
        glfw.pollEvents();
        if (nowMsFromGlfw() >= deadline) break;
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

// ── Depth helpers
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

// ── Buffer copy
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

// ── Framebuffers / Render pass / Pipeline
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

// ── SPIR-V loading (robust names + logging)
fn readFileAligned(alloc: Allocator, path: []const u8, comptime alignment: std.mem.Alignment) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
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

    const bytes = try readFileAligned(alloc, full, .@"4");
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
        "shaders/basic_lit.vert.spv",
        "shaders/basic_lit_vert.spv",
        "shaders/basic_lit.vert",
        "shaders/basic_lit_vert",
        "shaders/triangle.vert.spv",
        "shaders/triangle_vert.spv",
        "shaders/triangle.vert",
        "shaders/triangle_vert",
    };
    const frag_candidates = [_][]const u8{
        "shaders/basic_lit.frag.spv",
        "shaders/basic_lit_frag.spv",
        "shaders/basic_lit.frag",
        "shaders/basic_lit_frag",
        "shaders/triangle.frag.spv",
        "shaders/triangle_frag.spv",
        "shaders/triangle.frag",
        "shaders/triangle_frag",
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

    const vi = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @as([*]const vk.VertexInputBindingDescription, @ptrCast(&Vertex.binding_description)),
        .vertex_attribute_description_count = @intCast(Vertex.attribute_description.len),
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
        .p_viewports = undefined,
        .scissor_count = 1,
        .p_scissors = undefined,
    };

    const rs = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = VK_FALSE32,
        .rasterizer_discard_enable = VK_FALSE32,
        .polygon_mode = .fill,
        .cull_mode = .{}, // no culling; winding unaffected by viewport flip
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
        .dynamic_state_count = @intCast(dyn.len),
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

// ── Geometry writers
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

// Allocate per-swapchain command buffers once (idempotent helper).
fn cmdbufsForSwap(gc: *const GraphicsContext, A: Allocator, pool: vk.CommandPool, count: usize) []vk.CommandBuffer {
    const State = struct {
        var bufs: ?[]vk.CommandBuffer = null;
    };
    if (State.bufs) |b| return b;
    var bufs = A.alloc(vk.CommandBuffer, count) catch @panic("oom");
    gc.vkd.allocateCommandBuffers(gc.dev, &vk.CommandBufferAllocateInfo{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(count),
    }, bufs.ptr) catch @panic("alloc cmdbufs");
    State.bufs = bufs;
    return bufs;
}

// ── Main
pub fn main() !void {
    _ = glfw.setErrorCallback(errorCallback);
    try glfw.init();
    defer glfw.terminate();

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

    // Ensure initial framebuffer is not zero.
    waitForNonZeroFramebuffer(window);

    // Use true framebuffer pixels (retina-safe).
    const fb = glfw.getFramebufferSize(window);
    extent.width = @intCast(@max(@as(i32, 1), fb.width));
    extent.height = @intCast(@max(@as(i32, 1), fb.height));

    const allocator = std.heap.c_allocator;
    var gc = try GraphicsContext.init(allocator, window_title_cstr, window);
    defer gc.deinit();

    var swapchain = try Swapchain.init(&gc, allocator, extent);
    defer swapchain.deinit();

    // Descriptor set layout (CameraUBO at set=0, binding=0)
    const ubo_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
        .p_immutable_samplers = null,
    };
    const dsl = try gc.vkd.createDescriptorSetLayout(gc.dev, &vk.DescriptorSetLayoutCreateInfo{
        .flags = .{},
        .binding_count = 1,
        .p_bindings = @ptrCast(&ubo_binding),
    }, null);
    defer gc.vkd.destroyDescriptorSetLayout(gc.dev, dsl, null);

    // Pipeline layout with push constants (mat4 model) and set=0
    const push_range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = @sizeOf(Push),
    };
    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &vk.PipelineLayoutCreateInfo{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&dsl),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_range),
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const depth_format: vk.Format = .d32_sfloat;
    var depth = try createDepthResources(&gc, depth_format, swapchain.extent);
    defer destroyDepthResources(&gc, depth);

    const render_pass = try createRenderPass(&gc, swapchain, depth_format);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    const pipeline = try createPipeline(&gc, pipeline_layout, render_pass);
    defer gc.vkd.destroyPipeline(gc.dev, pipeline, null);

    var framebuffers = try createFramebuffers(&gc, allocator, render_pass, swapchain, depth.view);
    defer destroyFramebuffers(&gc, allocator, framebuffers);

    // Command pool
    const cmd_pool = try gc.vkd.createCommandPool(gc.dev, &vk.CommandPoolCreateInfo{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = gc.graphics_queue.family,
    }, null);
    defer gc.vkd.destroyCommandPool(gc.dev, cmd_pool, null);

    // Vertex buffer (floor + cube) and staging
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

    // Upload world vertices
    {
        const ptr = try gc.vkd.mapMemory(gc.dev, smem, 0, vk.WHOLE_SIZE, .{});
        defer gc.vkd.unmapMemory(gc.dev, smem);
        const verts: [*]Vertex = @ptrCast(@alignCast(ptr));
        writeFloorWorld(verts[0..FLOOR_VERTS]);
        writeUnitCube(verts[FLOOR_VERTS..(FLOOR_VERTS + CUBE_VERTS)]);
        try copyBuffer(&gc, cmd_pool, vbuf, sbuf, VERTEX_BUFFER_SIZE);
    }

    // Camera
    const fovy: f32 = @floatCast(std.math.degreesToRadians(70.0));
    var camera = Camera3D.init(
        Vec3.init(0.0, 1.7, 4.0),
        fovy,
        @as(f32, @floatFromInt(swapchain.extent.width)) /
            @as(f32, @floatFromInt(swapchain.extent.height)),
        0.1,
        500.0,
    );

    var frame_timer = FrameTimer.init(nowMsFromGlfw(), 1000);

    // Camera UBO buffer + descriptor set
    const ubo_size: vk.DeviceSize = @sizeOf(CameraUBO);
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

    // Lazy-allocated command buffers (cached)
    const cmdbufs = cmdbufsForSwap(&gc, allocator, cmd_pool, framebuffers.len);

    while (!glfw.windowShouldClose(window)) {
        const tick = frame_timer.tick(nowMsFromGlfw());
        var dt = @as(f32, @floatCast(tick.dt));
        if (tick.fps_updated) {
            var buf: [200]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &buf,
                "{s} | FPS: {d:.1} | Cam: x={d:.2}, y={d:.2}, z={d:.2}",
                .{ window_title_base, tick.fps, camera.position.x, camera.position.y, camera.position.z },
            ) catch null;
            if (title) |z| glfw.setWindowTitle(window, z);
        }

        const esc = glfw.getKey(window, glfw.c.GLFW_KEY_ESCAPE);
        if (esc == glfw.c.GLFW_PRESS or esc == glfw.c.GLFW_REPEAT) glfw.setWindowShouldClose(window, true);

        const ls = glfw.getKey(window, glfw.c.GLFW_KEY_LEFT_SHIFT);
        const rs = glfw.getKey(window, glfw.c.GLFW_KEY_RIGHT_SHIFT);
        if (ls == glfw.c.GLFW_PRESS or ls == glfw.c.GLFW_REPEAT or rs == glfw.c.GLFW_PRESS or rs == glfw.c.GLFW_REPEAT) {
            dt *= 2.5;
        }

        const input = sampleCameraInput(window);
        camera.update(dt, input);

        // Update UBO (VP); projection unchanged (flip handled by viewport).
        var vp = camera.viewProjMatrix();
        if (PROJECTION_Y_FLIP) vp.m[5] = -vp.m[5];
        {
            const ptr = try gc.vkd.mapMemory(gc.dev, ubo_mem, 0, vk.WHOLE_SIZE, .{});
            defer gc.vkd.unmapMemory(gc.dev, ubo_mem);
            const u: *CameraUBO = @ptrCast(@alignCast(ptr));
            u.* = .{ .vp = vp.m };
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
        const offsets = [_]vk.DeviceSize{0};
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @as([*]const vk.Buffer, @ptrCast(&vbuf)), &offsets);
        gc.vkd.cmdBindDescriptorSets(cmdbuf, .graphics, pipeline_layout, 0, 1, @ptrCast(&set), 0, undefined);

        // Floor: identity model
        var model = Mat4.identity();
        var push = Push{ .model = model.m };
        gc.vkd.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(Push), @ptrCast(&push));
        gc.vkd.cmdDraw(cmdbuf, FLOOR_VERTS, 1, 0, 0);

        // Cube: translate up by 0.5
        model = Mat4.identity();
        model.m[12] = 0.0; // x
        model.m[13] = 0.5; // y
        model.m[14] = 0.0; // z
        push = .{ .model = model.m };
        gc.vkd.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true }, 0, @sizeOf(Push), @ptrCast(&push));
        gc.vkd.cmdDraw(cmdbuf, CUBE_VERTS, 1, FLOOR_VERTS, 0);

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

                destroyFramebuffers(&gc, allocator, framebuffers);
                destroyDepthResources(&gc, depth);
                depth = try createDepthResources(&gc, depth_format, swapchain.extent);
                framebuffers = try createFramebuffers(&gc, allocator, render_pass, swapchain, depth.view);
            }
        }

        glfw.pollEvents();
    }

    try swapchain.waitForAllFences();
}

// ── Sanity test
test "viewport flip is sole active mode" {
    try std.testing.expect(VIEWPORT_Y_FLIP and !PROJECTION_Y_FLIP);
}
