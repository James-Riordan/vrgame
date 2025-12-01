const std = @import("std");

test {
    _ = @import("integration/math3d_sanity.zig");
    _ = @import("integration/math3d_projection_props.zig");
    _ = @import("integration/shaders_exist.zig");
    _ = @import("integration/glsl_sources_present.zig");
    _ = @import("integration/xr_registry_exists.zig");
    _ = @import("integration/vertex_contract.zig");
    _ = @import("integration/graphics_context_exports.zig");
    _ = @import("integration/camera3d_exports.zig");
    _ = @import("integration/frame_time_exports.zig");
    _ = @import("integration/vk_structs_compile.zig");
    _ = @import("integration/glfw_exports.zig");
    _ = @import("integration/math3d_lookat_orthonormal.zig");
    _ = @import("integration/math3d_perspective_basic.zig");
    _ = @import("integration/xr_headers_sanity.zig");
    _ = @import("integration/types_size_sanity.zig");
    _ = @import("integration/shader_sources_exist.zig");
    _ = @import("integration/math3d_viewproj_center_ndc.zig");
    _ = @import("integration/graphics_context_public_decls.zig");
    _ = @import("integration/swapchain_public_decls.zig");
    _ = @import("integration/camera3d_public_decls.zig");
    _ = @import("integration/frame_time_public_decls.zig");
    _ = @import("integration/glfw_vulkan_headers_sanity.zig");
    _ = @import("integration/repo_layout_sanity.zig");
}

test {
    std.testing.refAllDecls(@This());
}
