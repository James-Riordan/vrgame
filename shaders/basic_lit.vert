#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;

layout(location = 0) out vec3 v_color;
layout(location = 1) out vec3 v_normal;

layout(set = 0, binding = 0) uniform CameraUBO {
    mat4 vp;
} ubo;

layout(push_constant) uniform Push {
    mat4 model;
} pc;

void main() {
    v_color  = in_color;
    // Assuming no non-uniform scale; fine for current cube/floor
    v_normal = normalize(mat3(pc.model) * in_normal);

    gl_Position = ubo.vp * pc.model * vec4(in_pos, 1.0);
}
