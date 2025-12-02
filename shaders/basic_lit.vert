#version 450

layout(location=0) in vec3 inPos;
layout(location=1) in vec3 inNormal;
layout(location=2) in vec3 inColor;

layout(location=3) in vec4 iM0;
layout(location=4) in vec4 iM1;
layout(location=5) in vec4 iM2;
layout(location=6) in vec4 iM3;
layout(location=7) in vec4 iColor;

layout(set=0, binding=0) uniform SceneUBO {
    mat4 vp;
    vec4 light_dir;
    vec4 light_color;
    vec4 ambient;
    float time;
} U;

layout(location=0) out vec3 vNormal;
layout(location=1) out vec3 vColor;
layout(location=2) out vec3 vLightDir;
layout(location=3) out vec3 vLightColor;
layout(location=4) out vec3 vAmbient;

void main() {
    mat4 model = mat4(iM0, iM1, iM2, iM3);

    vec4 wpos = model * vec4(inPos, 1.0);
    gl_Position = U.vp * wpos;

    // (approx) normal transform for rigid transforms
    vNormal = normalize(mat3(model) * inNormal);

    // modulate per-vertex color by per-instance color
    vColor = clamp(inColor * iColor.rgb, 0.0, 1.0);

    vLightDir   = normalize(-U.light_dir.xyz);
    vLightColor = U.light_color.rgb;
    vAmbient    = U.ambient.rgb;
}
