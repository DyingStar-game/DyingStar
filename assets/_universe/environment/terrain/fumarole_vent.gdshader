shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Fumarole vent surface — dark volcanic basalt with sulfur mineral crust
// and a hot glow in the inner throat of the vent.

group_uniforms Rock;
uniform vec4 basalt_color    : source_color = vec4(0.15, 0.12, 0.10, 1.0);
uniform vec4 sulfur_color    : source_color = vec4(0.72, 0.68, 0.22, 1.0);
uniform vec4 rim_color       : source_color = vec4(0.85, 0.80, 0.35, 1.0);
uniform float roughness_base : hint_range(0.0, 1.0, 0.01) = 0.92;
uniform float roughness_sulfur : hint_range(0.0, 1.0, 0.01) = 0.65;
uniform float sulfur_coverage : hint_range(0.0, 1.0, 0.01) = 0.4;
uniform float normal_bump    : hint_range(0.0, 3.0, 0.01) = 1.2;

group_uniforms Glow;
uniform vec4 glow_color : source_color = vec4(1.0, 0.6, 0.15, 1.0);
uniform float glow_intensity : hint_range(0.0, 8.0, 0.1) = 3.0;
// UV.y == 0 at the bottom (inner throat), 1 at the outer rim.
// Glow fades as UV.y increases.
uniform float glow_falloff : hint_range(0.5, 8.0, 0.1) = 3.0;

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

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < 4; i++) {
		v += a * noise(p);
		p = rot * p * 2.0;
		a *= 0.5;
	}
	return v;
}

// ── Vertex ────────────────────────────────────────────────────
varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

// ── Fragment ──────────────────────────────────────────────────
void fragment() {
	// UV.x = angle around the vent (0..1), UV.y = height (0=throat, 1=outer rim)
	float height_t = UV.y;

	// Sulfur deposit pattern — more at the rim, patchy across surface.
	float n = fbm(UV * vec2(8.0, 4.0));
	float sulfur_mask = smoothstep(0.3, 0.7, n) * sulfur_coverage;
	// More sulfur near the rim where minerals precipitate.
	sulfur_mask *= smoothstep(0.2, 0.8, height_t);

	// Mix basalt and sulfur.
	vec3 rock = mix(basalt_color.rgb, sulfur_color.rgb, sulfur_mask);
	// Rim highlight.
	float rim_mask = smoothstep(0.85, 1.0, height_t);
	rock = mix(rock, rim_color.rgb, rim_mask * 0.6);

	// Roughness — sulfur deposits are smoother/glossier than basalt.
	float rough = mix(roughness_base, roughness_sulfur, sulfur_mask);

	// Bump normal from noise.
	float eps = 0.005;
	float n_dx = fbm((UV + vec2(eps, 0.0)) * vec2(8.0, 4.0));
	float n_dy = fbm((UV + vec2(0.0, eps)) * vec2(8.0, 4.0));
	vec3 bump_normal = normalize(vec3(
		(n - n_dx) / eps * normal_bump,
		(n - n_dy) / eps * normal_bump,
		1.0
	));
	NORMAL_MAP = bump_normal * 0.5 + 0.5;

	// Hot glow inside the throat — fades toward the rim.
	float glow_mask = pow(1.0 - clamp(height_t, 0.0, 1.0), glow_falloff);
	vec3 emission = glow_color.rgb * glow_mask * glow_intensity;

	// Subtle heat shimmer — flickering noise in the inner area.
	float shimmer = noise(UV * 12.0 + vec2(TIME * 1.5, TIME * 0.8));
	emission += glow_color.rgb * shimmer * glow_mask * 0.5;

	ALBEDO = rock;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	EMISSION = emission;
}
