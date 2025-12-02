#version 450
#ifndef UBO_BINDING
#define UBO_BINDING 0
#endif

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;

layout(location = 3) in vec4 i_m0;
layout(location = 4) in vec4 i_m1;
layout(location = 5) in vec4 i_m2;
layout(location = 6) in vec4 i_m3;
layout(location = 7) in vec4 i_color; // instance tint (rgb) + unused a

layout(location = 0) out vec3 v_normal_ws;
layout(location = 1) out vec3 v_color;
layout(location = 2) out vec3 v_pos_ws;

layout(set = 0, binding = UBO_BINDING) uniform SceneUBO {
    mat4 vp;
    vec4 light_dir;
    vec4 light_color;
    vec4 ambient;
    float time;
} U;

void main() {
    mat4 M = mat4(i_m0, i_m1, i_m2, i_m3);     // instance model matrix (column-major)
    vec4 wp = M * vec4(in_pos, 1.0);           // world position

    // Approx normal transform (good enough without non-uniform scaling)
    v_normal_ws = mat3(M) * in_normal;
    v_pos_ws = wp.xyz;
    v_color = in_color * i_color.rgb;

    gl_Position = U.vp * wp;                    // clip-space position
}
