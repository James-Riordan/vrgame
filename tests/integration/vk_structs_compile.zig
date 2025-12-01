const vk = @import("vulkan");

// Typed Bool32 helpers for Zig 0.16/vulkan-zig
const FALSE = @as(vk.Bool32, @enumFromInt(0));
const TRUE = @as(vk.Bool32, @enumFromInt(1));

// This is a compile-time contract check: the common create-info structs we use
// can be instantiated with our preferred default patterns.
test "vulkan create-info patterns compile" {
    const ia = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = FALSE,
    };
    _ = ia;

    const vp = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = undefined,
        .scissor_count = 1,
        .p_scissors = undefined,
    };
    _ = vp;

    const rs = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = FALSE,
        .rasterizer_discard_enable = FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{}, // none
        .front_face = .clockwise,
        .depth_bias_enable = FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    _ = rs;

    const ms = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = FALSE,
        .min_sample_shading = 1,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = FALSE,
        .alpha_to_one_enable = FALSE,
    };
    _ = ms;

    const ds = vk.PipelineDepthStencilStateCreateInfo{
        .flags = .{},
        .depth_test_enable = TRUE,
        .depth_write_enable = TRUE,
        .depth_compare_op = .less,
        .depth_bounds_test_enable = FALSE,
        .stencil_test_enable = FALSE,
        .front = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .back = .{
            .fail_op = .keep,
            .pass_op = .keep,
            .depth_fail_op = .keep,
            .compare_op = .always,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .min_depth_bounds = 0.0,
        .max_depth_bounds = 1.0,
    };
    _ = ds;

    const blend_att = vk.PipelineColorBlendAttachmentState{
        .blend_enable = FALSE,
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
        .logic_op_enable = FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @as([*]const vk.PipelineColorBlendAttachmentState, @ptrCast(&blend_att)),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };
    _ = blend;
}
