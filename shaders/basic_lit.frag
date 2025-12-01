#version 450

layout(location = 0) in vec3 v_color;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec3 v_world_pos;

layout(location = 0) out vec4 out_color;

// Single hard-coded directional light for now.
const vec3 LIGHT_DIR = normalize(vec3(-0.4, -1.0, -0.3));
const vec3 LIGHT_COLOR = vec3(1.0, 1.0, 1.0);

void main() {
    vec3 n = normalize(v_normal);
    float ndl = max(dot(n, -LIGHT_DIR), 0.0);
    vec3 lit = v_color * (0.25 + 0.75 * ndl); // ambient + diffuse
    out_color = vec4(lit, 1.0);
}
