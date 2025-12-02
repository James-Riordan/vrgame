#version 450
#ifndef UBO_BINDING
#define UBO_BINDING 0
#endif

layout(location = 0) in vec3 v_normal_ws;
layout(location = 1) in vec3 v_color;
layout(location = 2) in vec3 v_pos_ws;

layout(location = 0) out vec4 out_color;

layout(set = 0, binding = UBO_BINDING) uniform SceneUBO {
    mat4 vp;
    vec4 light_dir;    // xyz used (directional)
    vec4 light_color;  // rgb used
    vec4 ambient;      // rgb used
    float time;
} U;

void main() {
    vec3 N = normalize(v_normal_ws);
    vec3 L = normalize(-U.light_dir.xyz);      // light coming from light_dir
    float diff = max(dot(N, L), 0.0);

    vec3 rgb = v_color * (U.ambient.rgb + diff * U.light_color.rgb);
    out_color = vec4(rgb, 1.0);
}
