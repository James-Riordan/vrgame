#version 450
layout(location=0) in vec3 vNormal;
layout(location=1) in vec3 vColor;
layout(location=2) in vec3 vLightDir;
layout(location=3) in vec3 vLightColor;
layout(location=4) in vec3 vAmbient;

layout(location=0) out vec4 outColor;

void main() {
    float ndl = max(dot(normalize(vNormal), vLightDir), 0.0);
    vec3 col = vColor * (vAmbient + vLightColor * ndl);
    outColor = vec4(col, 1.0);
}
