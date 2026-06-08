shader_type spatial;
render_mode cull_back;
// Mining rock: local-space triplanar albedo + ORE pockets (3D object-space noise, shows
// on the surface AND on cut faces) + NEUTRAL fault grooves that DARKEN the rock and CARVE
// a groove (procedural normal bump). Faults are neutral on purpose: they do NOT reveal
// which ore the rock holds. Each fault plane is { normal, offset } in LOCAL space:
//   distance(fragment) = dot(normal, local_pos) - offset

uniform sampler2D albedo_tex : source_color;
uniform float tex_scale = 1.0;

// ── Ore ──────────────────────────────────────────────────────────────────────
uniform vec3 ore_color : source_color = vec3(0.1, 0.8, 0.2);
uniform float ore_scale = 6.0;
uniform float ore_threshold = 0.55;   // lower = more ore (richer piece)
uniform float ore_softness = 0.156;
uniform float ore_metallic = 1.0;
uniform float ore_roughness = 0.059;
uniform float ore_emission = 9.3;
uniform vec3 noise_offset = vec3(0.0);   // per-rock offset so each rock's ore differs

// ── Neutral fault grooves (carved cracks) ────────────────────────────────────
uniform int plane_count = 0;
uniform vec3 plane_normals[8];
uniform float plane_offsets[8];
uniform float groove_width = 0.03;
uniform float groove_darkness = 0.0;   // albedo multiplier at the crack (0 = black)
uniform float groove_strength = 0.1;   // bump depth (negative flips dug/raised)

varying vec3 v_local;
varying vec3 v_normal;

void vertex() {
	v_local = VERTEX;
	v_normal = NORMAL;
}

float _hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float _vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(_hash(i + vec3(0,0,0)), _hash(i + vec3(1,0,0)), f.x),
			mix(_hash(i + vec3(0,1,0)), _hash(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(_hash(i + vec3(0,0,1)), _hash(i + vec3(1,0,1)), f.x),
			mix(_hash(i + vec3(0,1,1)), _hash(i + vec3(1,1,1)), f.x), f.y),
		f.z);
}

float _fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * _vnoise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	// Local-space triplanar albedo.
	vec3 bw = abs(normalize(v_normal));
	bw /= max(bw.x + bw.y + bw.z, 0.0001);
	vec3 p = v_local * tex_scale;
	vec3 col = texture(albedo_tex, p.zy).rgb * bw.x
	         + texture(albedo_tex, p.xz).rgb * bw.y
	         + texture(albedo_tex, p.xy).rgb * bw.z;

	// Ore pockets (3D noise; appears on the surface AND on cut faces). noise_offset shifts
	// the pattern per rock so they don't all look identical.
	float n = _fbm((v_local + noise_offset) * ore_scale);
	float ore = smoothstep(ore_threshold, ore_threshold + ore_softness, n);
	col = mix(col, ore_color, ore);

	// Neutral fault grooves: crack mask + cross-groove gradient.
	float crack = 0.0;
	vec3 grad = vec3(0.0);
	for (int i = 0; i < plane_count; i++) {
		float sd = dot(plane_normals[i], v_local) - plane_offsets[i];
		float a = 1.0 - smoothstep(groove_width * 0.3, groove_width, abs(sd));
		crack = max(crack, a);
		grad += plane_normals[i] * (-sign(sd)) * a;
	}
	col *= mix(1.0, groove_darkness, crack);   // darken the rock along the faults

	ALBEDO = col;
	METALLIC = ore * ore_metallic;
	ROUGHNESS = mix(0.9, ore_roughness, ore);
	EMISSION = ore_color * ore * ore_emission;

	// Carve the groove by tilting the normal toward the crack center (fake bump map).
	if (crack > 0.001) {
		vec3 nrm = normalize(v_normal);
		vec3 tgrad = grad - dot(grad, nrm) * nrm;
		if (length(tgrad) > 1e-5) {
			vec3 tgrad_view = (VIEW_MATRIX * MODEL_MATRIX * vec4(normalize(tgrad), 0.0)).xyz;
			NORMAL = normalize(NORMAL - tgrad_view * crack * groove_strength);
		}
	}
}
