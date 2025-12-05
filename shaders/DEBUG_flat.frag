#version 450
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

// Flat neon-green to be unmistakable on a grey clear color.
void main() {
    out_color = vec4(0.0, 1.0, 0.0, 1.0);
}
