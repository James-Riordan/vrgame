#version 450
layout(location = 0) out vec3 v_color;
void main() {
    const vec2 P[3] = vec2[](
        vec2(-0.8, -0.6),
        vec2( 0.8, -0.6),
        vec2( 0.0,  0.6)
    );
    const vec3 C[3] = vec3[](
        vec3(1,0,0),
        vec3(0,1,0),
        vec3(1,0,1)
    );
    gl_Position = vec4(P[gl_VertexIndex], 0.0, 1.0);
    v_color = C[gl_VertexIndex];
}
