#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;

layout(push_constant) uniform Push {
    mat4 model;
} push_pc;

layout(set = 0, binding = 0) uniform CameraUBO {
    mat4 vp;
} cam;

layout(location = 0) out vec3 v_color;
layout(location = 1) out vec3 v_normal_ws;
layout(location = 2) out vec3 v_pos_ws;

void main() {
    mat3 nmat = mat3(push_pc.model);
    vec3 n_ws = normalize(nmat * in_normal);

    vec4 pos_ws = push_pc.model * vec4(in_pos, 1.0);
    gl_Position = cam.vp * pos_ws;

    v_color = in_color;
    v_normal_ws = n_ws;
    v_pos_ws = pos_ws.xyz;
}
