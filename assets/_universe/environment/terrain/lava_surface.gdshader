shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Lava lake surface shader — glowing molten rock with animated flow.
// Emissive crust that cracks to reveal bright magma beneath.

group_uniforms Lava;
uniform vec4 lava_hot_color : source_color = vec4(1.0, 0.35, 0.05, 1.0);
uniform vec4 lava_cool_color : source_color = vec4(0.15, 0.02, 0.0, 1.0);
uniform vec4 crust_color : source_color = vec4(0.08, 0.04, 0.02, 1.0);
uniform float crust_coverage : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float flow_speed : hint_range(0.0, 2.0, 0.01) = 0.15;
uniform float turbulence : hint_range(0.0, 5.0, 0.01) = 2.5;
uniform float glow_intensity : hint_range(0.0, 10.0, 0.1) = 4.0;

group_uniforms Surface;
uniform float roughness_value : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float wave_height : hint_range(0.0, 5.0, 0.1) = 0.3;
uniform float normal_strength : hint_range(0.0, 3.0, 0.01) = 0.8;

group_uniforms Planet;
uniform float planet_radius = 1000.0;
uniform float water_level_offset = 0.0;

// ── Noise helpers ─────────────────────────────────────────────
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

// ── Vertex ────────────────────────────────────────────────────
varying vec3 sphere_normal;
varying float lava_noise;

void vertex() {
	// NORMAL contains the sphere direction (set by PlanetChunk mesh gen).
	// VERTEX is chunk-local (centred on chunk_center), so normalize(VERTEX)
	// would NOT give the sphere direction — always use NORMAL here.
	vec3 dir = normalize(NORMAL);
	sphere_normal = dir;

	float lon = atan(dir.z, dir.x);
	float lat = asin(clamp(dir.y, -1.0, 1.0));
	vec2 uv = vec2(lon, lat) * planet_radius * 0.001;

	// Slow flowing distortion
	vec2 flow = vec2(TIME * flow_speed * 0.3, TIME * flow_speed * 0.2);
	float n = fbm(uv * turbulence + flow, 5);
	lava_noise = n;

	// Add displacement along sphere normal (keep VERTEX chunk-local).
	float displacement = n * wave_height;
	VERTEX += dir * displacement;

	// Perturb normal slightly
	vec3 tangent_lon = normalize(vec3(-dir.z, 0.0, dir.x));
	vec3 tangent_lat = cross(dir, tangent_lon);
	float eps = 0.01;
	float n_dx = fbm((uv + vec2(eps, 0.0)) * turbulence + flow, 5);
	float n_dy = fbm((uv + vec2(0.0, eps)) * turbulence + flow, 5);
	vec3 perturbed = normalize(
		dir - (tangent_lon * (n_dx - n) + tangent_lat * (n_dy - n)) * wave_height * normal_strength / eps
	);
	NORMAL = perturbed;
}

// ── Fragment ──────────────────────────────────────────────────
void fragment() {
	// Crust pattern — dark solidified patches over bright magma
	float crust = smoothstep(crust_coverage - 0.1, crust_coverage + 0.1, lava_noise);

	// Lava temperature gradient
	vec3 hot = mix(lava_cool_color.rgb, lava_hot_color.rgb, lava_noise);
	vec3 surface_color = mix(hot, crust_color.rgb, crust);

	// Emission — hot lava glows, crust is darker
	float emission_factor = (1.0 - crust) * glow_intensity;
	vec3 emission = hot * emission_factor;

	ALBEDO = surface_color;
	ROUGHNESS = mix(0.3, roughness_value, crust);
	METALLIC = 0.0;
	EMISSION = emission;
}
