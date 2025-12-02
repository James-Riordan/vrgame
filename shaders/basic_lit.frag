#version 450

layout(location = 0) in vec3 v_color;
layout(location = 1) in vec3 v_normal;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 N = normalize(v_normal);
    vec3 L = normalize(vec3(0.4, 1.0, 0.35)); // gentle key light
    float diff = max(dot(N, L), 0.0);

    vec3 ambient = 0.25 * v_color;
    vec3 lit = ambient + diff * v_color;

    out_color = vec4(lit, 1.0);
}
