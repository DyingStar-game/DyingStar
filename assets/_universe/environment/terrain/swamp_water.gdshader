shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, depth_draw_always;

// Swamp / shallow-water shader.
// A thin translucent water sheet placed directly over terrain vertices.
// Very gentle waves, murky brown-green colouring, no dramatic foam.
// Re-uses the core wave algorithm from ocean_surface.gdshader but tuned
// for standing shallow water in bayous, bogs, and marshes.

// ── Uniforms ──────────────────────────────────────────────────
group_uniforms Water;
uniform vec4 water_color_deep : source_color = vec4(0.12, 0.18, 0.08, 1.0);
uniform vec4 water_color_shallow : source_color = vec4(0.22, 0.28, 0.14, 1.0);
uniform float water_depth_factor : hint_range(0.0, 5.0, 0.01) = 0.8;
uniform float alpha : hint_range(0.0, 1.0, 0.01) = 0.55;

group_uniforms Waves;
uniform float wave_height : hint_range(0.0, 5.0, 0.01) = 0.08;
uniform float wave_choppy : hint_range(0.0, 4.0, 0.01) = 0.3;
uniform float wave_speed  : hint_range(0.0, 5.0, 0.01) = 0.15;
uniform float wave_frequency : hint_range(0.0, 1.0, 0.001) = 0.3;
uniform int   wave_octaves : hint_range(1, 8) = 3;
uniform float wave_scale : hint_range(0.1, 500.0, 0.1) = 120.0;

group_uniforms Surface;
uniform float metallic_value : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float roughness_value : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float specular_value : hint_range(0.0, 1.0, 0.01) = 0.4;
uniform float fresnel_power : hint_range(0.0, 10.0, 0.1) = 3.0;
uniform float normal_strength : hint_range(0.0, 50.0, 0.1) = 3.0;

// Murk — darkens the water towards edges to simulate algae / tannin.
group_uniforms Murk;
uniform vec4 murk_color : source_color = vec4(0.06, 0.09, 0.04, 1.0);
uniform float murk_intensity : hint_range(0.0, 1.0, 0.01) = 0.3;

group_uniforms Planet;
uniform float planet_radius = 1000.0;
uniform float water_level_offset = 0.0;

// ── Hash / noise helpers ──────────────────────────────────────
float hash(vec2 p) {
	float h = dot(p, vec2(127.1, 311.7));
	return fract(sin(h) * 43758.5453123);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return -1.0 + 2.0 * mix(
		mix(hash(i + vec2(0.0, 0.0)), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

// ── Wave function (same core as ocean_surface) ────────────────
vec3 wavedx(vec2 position, vec2 direction, float freq, float timeshift) {
	float x = dot(direction, position) * freq + timeshift;
	float wave = exp(sin(x) - 1.0);
	float dx   = wave * cos(x);
	return vec3(wave, -dx * direction.x, -dx * direction.y);
}

vec3 get_waves(vec2 position, int octaves, float t) {
	float freq = wave_frequency;
	float amp  = 1.0;
	float choppy = wave_choppy;
	float speed = wave_speed;

	float total_height = 0.0;
	vec2  total_deriv  = vec2(0.0);

	mat2 octave_rot = mat2(vec2(0.87, 0.48), vec2(-0.48, 0.87));

	for (int i = 0; i < 8; i++) {
		if (i >= octaves) break;
		vec2 dir = (mod(float(i), 2.0) < 0.5)
			? vec2(1.0, 0.6) : vec2(-0.7, 1.0);
		dir = normalize(dir);

		vec3 w = wavedx(position, dir, freq, t * speed);
		position += dir * w.y * choppy * amp;
		position += dir * w.z * choppy * amp;

		total_height += w.x * amp;
		total_deriv  += vec2(w.y, w.z) * amp * freq;

		freq *= 1.9;
		amp  *= 0.22;
		choppy = mix(choppy, 1.0, 0.2);
		speed *= 1.07;
		position *= octave_rot;
	}

	return vec3(total_height, total_deriv);
}

// ── Vertex shader ─────────────────────────────────────────────
varying vec3 sphere_normal;
varying float wave_h;
varying vec2 surface_uv;  // lon/lat based UV for fragment patterns
varying float edge_fade;  // 0 = polygon edge, 1 = interior

void vertex() {
	// NORMAL contains the sphere direction (set by PlanetChunk mesh gen).
	// VERTEX is chunk-local (centred on chunk_center), so normalize(VERTEX)
	// would NOT give the sphere direction — always use NORMAL here.
	vec3 dir = normalize(NORMAL);
	sphere_normal = dir;
	edge_fade = COLOR.r;  // passed from PlanetChunk mesh builder

	float lon = atan(dir.z, dir.x);
	float lat = asin(clamp(dir.y, -1.0, 1.0));
	vec2 wave_uv = vec2(lon, lat) * wave_scale;
	surface_uv = wave_uv;

	vec3 w = get_waves(wave_uv, wave_octaves, TIME);
	wave_h = w.x;

	// Very subtle displacement — just gentle ripples.
	VERTEX += dir * (w.x * wave_height);

	vec3 tangent_lon = normalize(vec3(-dir.z, 0.0, dir.x));
	vec3 tangent_lat = cross(dir, tangent_lon);
	vec3 normal_offset = (tangent_lon * w.y + tangent_lat * w.z) * normal_strength;
	NORMAL = normalize(dir - normal_offset);
}

// ── Fragment shader ───────────────────────────────────────────
void fragment() {
	float ndotv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndotv, fresnel_power);

	// Animated murky ripple pattern — gives visible surface texture.
	vec2 ripple_uv1 = surface_uv * 3.7 + vec2(TIME * 0.02, TIME * 0.015);
	vec2 ripple_uv2 = surface_uv * 5.3 - vec2(TIME * 0.018, TIME * 0.025);
	float ripple = noise(ripple_uv1) * 0.5 + noise(ripple_uv2) * 0.5;
	// Remap from [-1,1] to [0,1]
	ripple = ripple * 0.5 + 0.5;

	// Shallow murky blend with ripple variation.
	float depth_t = clamp(ndotv * water_depth_factor + wave_h * 0.15 + ripple * 0.2, 0.0, 1.0);
	vec3 base = mix(water_color_deep.rgb, water_color_shallow.rgb, depth_t);

	// Murk towards edges — simulates tannin / algae in still water.
	base = mix(base, murk_color.rgb, murk_intensity * (1.0 - ndotv));

	// Subtle dappled light caustics — bright spots through canopy.
	float caustic_uv = noise(surface_uv * 8.0 + vec2(TIME * 0.03, TIME * -0.02));
	float caustic = smoothstep(0.3, 0.7, caustic_uv * 0.5 + 0.5) * 0.15;
	base += vec3(caustic * 0.6, caustic, caustic * 0.4);

	// Subtle sky reflection on fresnel edges (green-grey sky tint).
	base = mix(base, vec3(0.4, 0.5, 0.35), fresnel * 0.25);

	ALBEDO = base;
	// Smooth boundary fade: alpha ramps from 0 at polygon edge to full
	// inside.  smoothstep gives a natural non-linear transition.
	float boundary_fade = smoothstep(0.0, 1.0, edge_fade);
	ALPHA = alpha * boundary_fade;
	METALLIC = metallic_value;
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;
}
