#version 450

layout(location = 0) in vec3 v_color;
layout(location = 1) in vec3 v_normal_ws;
layout(location = 2) in vec3 v_pos_ws;

layout(location = 0) out vec4 out_color;

// Simple scene lighting
const vec3 AMBIENT = vec3(0.18);        // base ambient
const vec3 LIGHT_DIR = normalize(vec3(-0.4, -1.0, -0.25)); // directional (down-right-forward)
const vec3 LIGHT_COLOR = vec3(1.00, 0.97, 0.92);           // slightly warm key light

void main() {
    vec3 N = normalize(v_normal_ws);
    float ndl = max(dot(N, -LIGHT_DIR), 0.0);  // Lambert
    vec3 lit = AMBIENT + (LIGHT_COLOR * ndl);

    // simple diffuse, clamp to sane range; optional gamma-ish tweak
    vec3 col = v_color * lit;
    col = clamp(col, 0.0, 1.0);

    out_color = vec4(col, 1.0);
}
