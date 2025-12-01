const std = @import("std");
const vk = @import("vulkan");

test "vulkan headers present and key decls exist" {
    try std.testing.expect(@hasDecl(vk, "Pipeline"));
    try std.testing.expect(@hasDecl(vk, "ShaderModuleCreateInfo"));
    try std.testing.expect(@hasDecl(vk, "PipelineShaderStageCreateInfo"));
    try std.testing.expect(@hasDecl(vk, "PipelineVertexInputStateCreateInfo"));
}
