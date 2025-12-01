#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;

layout(location = 0) out vec3 v_color;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec3 v_world_pos;

layout(set = 0, binding = 0) uniform CameraUBO {
    mat4 vp;
} cam;

layout(push_constant) uniform Push {
    mat4 model;
} pushc;

void main() {
    mat4 m = pushc.model;
    vec4 wp = m * vec4(in_pos, 1.0);
    gl_Position = cam.vp * wp;

    v_world_pos = wp.xyz;
    v_normal = mat3(m) * in_normal;
    v_color = in_color;
}
