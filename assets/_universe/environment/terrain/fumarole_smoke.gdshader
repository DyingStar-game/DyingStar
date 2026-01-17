shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, blend_mix;

// Fumarole smoke / steam particle shader.
// Used as a process + render material for GPUParticles3D.
// Billboarded quads that drift upward, expand, fade from hot white-yellow
// to cool sulfuric grey, then dissolve.

group_uniforms Smoke;
uniform vec4 color_hot  : source_color = vec4(1.0, 0.95, 0.75, 0.6);
uniform vec4 color_warm : source_color = vec4(0.85, 0.78, 0.55, 0.45);
uniform vec4 color_cool : source_color = vec4(0.65, 0.62, 0.58, 0.25);
uniform float edge_softness : hint_range(0.0, 1.0, 0.01) = 0.45;

group_uniforms Wind;
uniform vec3 wind_direction = vec3(0.15, 0.0, 0.1);
uniform float wind_strength : hint_range(0.0, 2.0, 0.01) = 0.3;

// ── Noise ─────────────────────────────────────────────────────
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

float fbm3(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < 3; i++) {
		v += a * noise(p);
		p = rot * p * 2.0;
		a *= 0.5;
	}
	return v;
}

// ── Fragment ──────────────────────────────────────────────────
void fragment() {
	// CUSTOM.x = lifetime_t (0 → 1), set by the particle process.
	// COLOR.a  = initial alpha from GPUParticles.
	float life_t = COLOR.a;  // re-used as lifetime fraction via color ramp

	// Radial distance from quad centre for soft circular shape.
	vec2 centered = UV * 2.0 - 1.0;
	float r = length(centered);

	// Soft circle mask.
	float circle = 1.0 - smoothstep(1.0 - edge_softness, 1.0, r);

	// Noise break-up — makes the puff look irregular, not a perfect circle.
	float n = fbm3(centered * 3.0 + vec2(TIME * 0.2, TIME * 0.15));
	circle *= smoothstep(0.1, 0.55, n + 0.3);

	// Colour gradient from hot centre / young to cool edge / old.
	// GPUParticles3D color ramp encodes lifetime in COLOR.a (1 → 0).
	vec4 col = mix(color_cool, color_warm, smoothstep(0.0, 0.5, life_t));
	col = mix(col, color_hot, smoothstep(0.5, 1.0, life_t));

	ALBEDO = col.rgb;
	ALPHA = col.a * circle;

	// Subtle emission for the hot centre.
	EMISSION = col.rgb * smoothstep(0.6, 1.0, life_t) * 0.4;
}
