#version 450
layout(location=0) in vec3 v_world_pos;
layout(location=1) in vec3 v_normal;
layout(location=2) in vec3 v_color;
layout(location=0) out vec4 out_color;

// Simple directional light
const vec3 L_dir = normalize(vec3(0.6, 1.0, 0.7));
const vec3 ambient = vec3(0.10);

// Analytic checkerboard on y=0 with subtle grid lines
vec3 floor_shade(vec3 N, vec3 base) {
    float ndotl = max(dot(normalize(N), L_dir), 0.0);
    vec3 lit = base * (ambient + ndotl);
    return lit;
}

void main() {
    vec3 N = normalize(v_normal);
    vec3 albedo = v_color;

    // If fragment is near the floor (y≈0), draw a clean checker + grid
    if (abs(v_world_pos.y) < 1e-4) {
        float scale = 1.0;                   // 1 unit tiles
        vec2 uv = v_world_pos.xz / scale;
        float checker = mod(floor(uv.x) + floor(uv.y), 2.0);
        vec3 tile_a = vec3(0.86, 0.88, 0.92);
        vec3 tile_b = vec3(0.20, 0.22, 0.26);
        vec3 cb = mix(tile_b, tile_a, checker);

        // grid lines (anti-aliased)
        vec2 g = abs(fract(uv) - 0.5);
        float line = 1.0 - smoothstep(0.48, 0.49, max(g.x, g.y));
        vec3 grid = mix(cb, vec3(0.04, 0.05, 0.06), line * 0.65);

        out_color = vec4(floor_shade(N, grid), 1.0);
        return;
    }

    // For non-floor (cube), softly lit “hero blue”
    vec3 base = vec3(0.25, 0.35, 1.00);
    out_color = vec4(floor_shade(N, base), 1.0);
}
