shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Volcanic caldera rock shader — dark basalt with glowing heat cracks
// near the lava pool.  UV.y encodes height: 0 = lava pool floor, 1 = outer rim.
// Vertex COLOR provides per-vertex tinting from the procedural geometry.

group_uniforms Rock;
uniform vec4 basalt_color : source_color = vec4(0.10, 0.07, 0.06, 1.0);
uniform vec4 scoria_color : source_color = vec4(0.25, 0.12, 0.08, 1.0);
uniform float roughness_value : hint_range(0.0, 1.0, 0.01) = 0.92;

group_uniforms HeatCracks;
uniform vec4 crack_glow_color : source_color = vec4(1.0, 0.35, 0.05, 1.0);
uniform float crack_intensity : hint_range(0.0, 8.0, 0.1) = 3.5;
uniform float crack_scale : hint_range(0.5, 20.0, 0.1) = 6.0;
uniform float crack_threshold : hint_range(0.0, 1.0, 0.01) = 0.62;
uniform float crack_sharpness : hint_range(1.0, 40.0, 0.5) = 12.0;
uniform float heat_height : hint_range(0.0, 1.0, 0.01) = 0.4;

group_uniforms Animation;
uniform float pulse_speed : hint_range(0.0, 3.0, 0.01) = 0.5;
uniform float pulse_amplitude : hint_range(0.0, 0.5, 0.01) = 0.15;

// ── Noise ────────────────────────────────────────────────────
float hash(vec2 p) {
	float h = dot(p, vec2(127.1, 311.7));
	return fract(sin(h) * 43758.5453123);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i + vec2(0.0, 0.0)), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

float fbm(vec2 p, int octaves) {
	float value = 0.0;
	float amp = 0.5;
	mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		value += amp * noise(p);
		p = rot * p * 2.0;
		amp *= 0.5;
	}
	return value;
}

// Worley-style cell noise for crack pattern.
float worley(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float min_d = 1.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbor = vec2(float(x), float(y));
			vec2 point_pos = vec2(hash(i + neighbor), hash((i + neighbor) * 1.7));
			vec2 diff = neighbor + point_pos - f;
			float d = length(diff);
			min_d = min(min_d, d);
		}
	}
	return min_d;
}

// ── Fragment ─────────────────────────────────────────────────
void fragment() {
	float height_t = UV.y;  // 0 = lava floor, 1 = outer rim.
	vec2 uv_world = UV * crack_scale;

	// Base rock colour: blend basalt to scoria with FBM noise.
	float rock_noise = fbm(uv_world * 1.5, 4);
	vec3 rock = mix(basalt_color.rgb, scoria_color.rgb, rock_noise * 0.6);
	// Mix in vertex colour for geometry-driven tinting.
	rock = mix(rock, COLOR.rgb, 0.35);

	// Heat proximity factor: stronger near the lava pool (low UV.y).
	float heat = smoothstep(heat_height, 0.0, height_t);

	// Crack pattern: Worley noise → edge detection → sharp cracks.
	float w = worley(uv_world + vec2(TIME * 0.02, TIME * 0.01));
	float crack = 1.0 - smoothstep(crack_threshold - 0.05, crack_threshold, w);
	crack *= heat;  // Cracks only appear near the heat zone.

	// Pulsing glow in the cracks.
	float pulse = 1.0 + pulse_amplitude * sin(TIME * pulse_speed * 6.2832);
	float glow = pow(crack, 1.0 / crack_sharpness) * crack_intensity * pulse;

	// Mix crack glow colour into the surface.
	vec3 crack_color = crack_glow_color.rgb * glow;

	ALBEDO = rock;
	ROUGHNESS = mix(roughness_value, 0.3, crack * 0.5);
	METALLIC = 0.0;
	EMISSION = crack_color;

	// Bump from FBM noise derivatives.
	float eps = 0.01;
	float ndx = fbm((uv_world + vec2(eps, 0.0)) * 1.5, 4) - rock_noise;
	float ndy = fbm((uv_world + vec2(0.0, eps)) * 1.5, 4) - rock_noise;
	NORMAL_MAP = normalize(vec3(-ndx, -ndy, eps));
	NORMAL_MAP_DEPTH = 0.6;
}
