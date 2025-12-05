#version 450
// Renders a full-screen-ish triangle using gl_VertexIndex.
// No vertex attributes, no UBOs.
layout(location = 0) out vec2 v_uv;

void main() {
    // 3 vertices covering the screen
    const vec2 positions[3] = vec2[3](
        vec2(-1.0, -1.0),
        vec2( 3.0, -1.0),
        vec2(-1.0,  3.0)
    );
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
    v_uv = (gl_Position.xy * 0.5) + 0.5;
}
