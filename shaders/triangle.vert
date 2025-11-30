#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_color;

layout(location = 0) out vec3 v_color;

void main() {
    v_color = in_color;

    // Match the world bounds in game.zig
    const float half_width  = 2.0;
    const float half_height = 1.5;

    // Map world XY → NDC [-1, 1]
    vec2 ndc = vec2(
        in_pos.x / half_width,
        in_pos.y / half_height
    );

    gl_Position = vec4(ndc, 0.0, 1.0);
}
