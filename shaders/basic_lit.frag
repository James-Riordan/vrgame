#version 450

layout(location = 0) in vec3 v_color;
layout(location = 1) in vec3 v_normal_ws;
layout(location = 2) in vec3 v_pos_ws;

layout(location = 0) out vec4 out_color;

// simple key light + faint fill
const vec3 LIGHT_DIR = normalize(vec3(0.35, 0.85, 0.35)); // from above-right
const float AMBIENT = 0.25;
const float DIFFUSE_STRENGTH = 0.95;

void main() {
    vec3 n = normalize(v_normal_ws);
    float ndl = max(dot(n, LIGHT_DIR), 0.0);
    float lit = AMBIENT + DIFFUSE_STRENGTH * ndl;

    vec3 rgb = v_color * lit;
    out_color = vec4(rgb, 1.0);
}
