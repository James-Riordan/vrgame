#version 450

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec3 v_color;

layout(location = 0) out vec4 out_color;

layout(set = 0, binding = UBO_BINDING) uniform Scene {
    mat4 vp;
    vec4 light_dir;
    vec4 light_color;
    vec4 ambient;
    float time;
} ubo;

void main() {
    vec3 n = normalize(v_normal);
    float ndl = max(dot(n, normalize(ubo.light_dir.xyz)), 0.0);
    vec3 c = v_color * (ubo.ambient.rgb + ubo.light_color.rgb * ndl);
    out_color = vec4(c, 1.0);
}
