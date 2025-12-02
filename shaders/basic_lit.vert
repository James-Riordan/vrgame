#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;

layout(location = 0) out vec3 v_color;
layout(location = 1) out vec3 v_normal_ws;
layout(location = 2) out vec3 v_pos_ws;

layout(set = 0, binding = 0) uniform CameraUBO {
    mat4 vp;
};

layout(push_constant, std430) uniform Push {
    mat4 model;
} pushs;

void main() {
    // world-space position & normal
    vec4 pos_ws4 = pushs.model * vec4(in_pos, 1.0);
    v_pos_ws = pos_ws4.xyz;

    // normal: ignore non-uniform scaling for now (model is orthonormal in this demo)
    v_normal_ws = mat3(pushs.model) * in_normal;

    v_color = in_color;

    gl_Position = vp * pos_ws4;
}
