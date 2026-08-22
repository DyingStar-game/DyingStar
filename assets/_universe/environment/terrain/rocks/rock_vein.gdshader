shader_type spatial;
render_mode cull_back;
// Mining rock: local-space triplanar albedo + ORE pockets (3D object-space noise, shows
// on the surface AND on cut faces) + NEUTRAL fault grooves that DARKEN the rock and CARVE
// a groove (procedural normal bump). Faults are neutral on purpose: they do NOT reveal
// which ore the rock holds. Each fault plane is { normal, offset } in LOCAL space:
//   distance(fragment) = dot(normal, local_pos) - offset

uniform sampler2D albedo_tex : source_color;
uniform float tex_scale = 1.0;
// Exterior relief + finish of the barren rock, from the HOST ROCK mineral (MineralDef "Host Rock"
// group). Defaults reproduce exactly what every rock looked like before host rocks existed: no
// normal map, roughness 0.9 — so a rock whose spawner sends no host_rock_id is untouched.
uniform bool rock_use_normal = false;
uniform sampler2D rock_normal_tex : hint_normal;
uniform float rock_normal_strength = 1.0;
uniform float rock_roughness : hint_range(0.0, 1.0) = 0.9;

// ── Ore ──────────────────────────────────────────────────────────────────────
uniform vec3 ore_color : source_color = vec3(0.1, 0.8, 0.2);
uniform float ore_scale = 6.0;
uniform float ore_threshold = 0.55;   // lower = more ore (richer piece)
uniform float ore_softness = 0.156;
uniform float ore_metallic = 1.0;
uniform float ore_roughness = 0.059;
uniform float ore_emission = 9.3;
uniform vec3 noise_offset = vec3(0.0);   // per-rock offset so each rock's ore differs

// Ore texture (optional): when ore_use_texture, the ore is drawn with a triplanar texture
// (local space, like the rock) tinted by ore_color, instead of a flat color. Driven per
// mineral by MineralDef (gold, ...). Same noise field, so volume/dispersion/persistence keep.
uniform bool ore_use_texture = false;
uniform sampler2D ore_albedo_tex : source_color, hint_default_white;
uniform sampler2D ore_normal_tex : hint_normal;
uniform float ore_tex_scale = 1.0;
uniform float ore_normal_strength = 1.0;

// ── Neutral fault grooves (carved cracks) ────────────────────────────────────
uniform int plane_count = 0;
uniform vec3 plane_normals[8];
uniform float plane_offsets[8];
uniform float groove_width = 0.005;
uniform vec3 groove_color : source_color = vec3(0.318, 0.188, 0.086);  // the crack's own colour
uniform float groove_strength = 0.1;   // bump depth (negative flips dug/raised)
// Crack irregularity. The plane distance is WARPED by object-space noise before it is thresholded,
// so the fault reads as a real fracture instead of a ruled line.
uniform float crack_warp_freq = 9.0;   // how tight the meanders are
uniform float crack_warp_amp = 0.045;  // how far the crack wanders off its plane (local units; 0 = straight)
uniform float crack_width_var : hint_range(0.0, 1.0) = 0.7;  // how much the width breathes along it

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

	// Ore look: a flat color, or a triplanar texture (local space, like the rock) tinted by
	// ore_color. Same noise mask, so the ore keeps its volume / cut faces / persistence.
	vec3 ore_col = ore_color;
	if (ore_use_texture) {
		vec3 op = v_local * ore_tex_scale;
		ore_col = (texture(ore_albedo_tex, op.zy).rgb * bw.x
		         + texture(ore_albedo_tex, op.xz).rgb * bw.y
		         + texture(ore_albedo_tex, op.xy).rgb * bw.z) * ore_color;
	}
	col = mix(col, ore_col, ore);

	// Neutral fault grooves: crack mask + cross-groove gradient.
	//
	// The noise is sampled on the fragment PROJECTED onto the plane, so it does not vary across the
	// groove's thickness: the result is a displaced CURVE, not a fuzzy slab. And because it lives in
	// object space, offset by noise_offset (per rock, derived from the replicated ore_seed), the
	// meander is identical on every client AND on both halves after a cut — the line drawn before
	// the cut matches the edge it leaves behind.
	float crack = 0.0;
	vec3 grad = vec3(0.0);
	for (int i = 0; i < plane_count; i++) {
		float sd = dot(plane_normals[i], v_local) - plane_offsets[i];
		vec3 pp = (v_local - plane_normals[i] * sd) * crack_warp_freq
		        + noise_offset + float(i) * 13.7;   // decorrelate the planes from one another
		sd += (_fbm(pp) - 0.5) * 2.0 * crack_warp_amp;
		// Width breathes along the crack. The 0.3 floor keeps it strictly positive: a zero width
		// would make the smoothstep below degenerate and the crack vanish.
		float w = groove_width * mix(1.0, 0.3 + _vnoise(pp * 2.3) * 1.4, crack_width_var);
		float a = 1.0 - smoothstep(w * 0.3, w, abs(sd));
		a *= a;   // crisper lips, darker core
		crack = max(crack, a);
		grad += plane_normals[i] * (-sign(sd)) * a;
	}
	col = mix(col, groove_color, crack);   // the fault shows its OWN colour, not just a darkening

	ALBEDO = col;
	METALLIC = ore * ore_metallic;
	ROUGHNESS = mix(rock_roughness, ore_roughness, ore);
	// Kill emission along the crack too: on a cut face the ore glows, and colouring only the
	// albedo would let the groove line wash out over bright ore pockets.
	EMISSION = ore_col * ore * ore_emission * (1.0 - crack);

	// Host-rock relief: triplanar normal map (local space) on the BARREN surface. Applied before
	// the ore block below and faded out where the ore takes over (1.0 - ore), so on a rich pocket
	// the ore's own relief wins instead of the two fighting.
	if (rock_use_normal && rock_normal_strength > 0.0) {
		vec3 rp = v_local * tex_scale;
		vec3 rnx = texture(rock_normal_tex, rp.zy).xyz * 2.0 - 1.0;
		vec3 rny = texture(rock_normal_tex, rp.xz).xyz * 2.0 - 1.0;
		vec3 rnz = texture(rock_normal_tex, rp.xy).xyz * 2.0 - 1.0;
		vec3 rn_local = normalize(rnx * bw.x + rny * bw.y + rnz * bw.z);
		vec3 rn_view = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(rn_local, 0.0)).xyz);
		NORMAL = normalize(mix(NORMAL, rn_view, clamp((1.0 - ore) * rock_normal_strength, 0.0, 1.0)));
	}

	// Ore relief: triplanar normal map (local space) blended in over the ore pockets.
	if (ore_use_texture && ore > 0.001 && ore_normal_strength > 0.0) {
		vec3 np = v_local * ore_tex_scale;
		vec3 onx = texture(ore_normal_tex, np.zy).xyz * 2.0 - 1.0;
		vec3 ony = texture(ore_normal_tex, np.xz).xyz * 2.0 - 1.0;
		vec3 onz = texture(ore_normal_tex, np.xy).xyz * 2.0 - 1.0;
		vec3 on_local = normalize(onx * bw.x + ony * bw.y + onz * bw.z);
		vec3 on_view = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(on_local, 0.0)).xyz);
		NORMAL = normalize(mix(NORMAL, on_view, clamp(ore * ore_normal_strength, 0.0, 1.0)));
	}

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
