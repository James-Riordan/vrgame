#version 450

// Vertex attributes
layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;

// Per-instance model (mat4 split across 4x vec4) and per-instance color
layout(location = 3) in vec4 i_m0;
layout(location = 4) in vec4 i_m1;
layout(location = 5) in vec4 i_m2;
layout(location = 6) in vec4 i_m3;
layout(location = 7) in vec4 i_color;

// UBO (binding chosen in build.zig: UBO_BINDING=0)
layout(set = 0, binding = UBO_BINDING) uniform Scene {
    mat4 vp;
    vec4 light_dir;
    vec4 light_color;
    vec4 ambient;
    float time;
} ubo;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec3 v_color;

mat4 instModel() { return mat4(i_m0, i_m1, i_m2, i_m3); }

void main() {
    mat4 M = instModel();
    vec4 wp = M * vec4(in_pos, 1.0);
    gl_Position = ubo.vp * wp;

    // approximate normal transform (assumes uniform scale)
    v_normal = normalize(mat3(M) * in_normal);
    v_color  = clamp(i_color.rgb * in_color, 0.0, 1.0);
}
