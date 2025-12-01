#version 450

layout(location = 0) in vec3 inPos;    // Vertex.pos
layout(location = 1) in vec3 inColor;  // Vertex.color

// Matches Zig: extern struct { m: [16]f32 }  (column-major mat4)
layout(push_constant) uniform Push {
    mat4 VP;
} pc;

layout(location = 0) out vec3 vColor;

void main() {
    gl_Position = pc.VP * vec4(inPos, 1.0);
    vColor = inColor;
}
