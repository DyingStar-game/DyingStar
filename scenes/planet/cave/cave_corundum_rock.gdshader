shader_type spatial;
// Milky corundum of the cave walls, floor and rocks (CaveMineral): not a stone texture but a white, half
// translucent crystal. Under the surface the view ray crosses a few layers of milky clouds (procedural noise):
// where they are thick the rock is milk white, where they thin out the eye sees deeper, into a greyer and
// more coloured depth. Fine growth bands and rare iron stains mark it like a real crystal, light wraps
// around the relief and spreads inside the stone (custom light()), and the lustre is glossy, almost wet, from
// the lights only: the sky's reflection (which reaches the caves) is cut, it would grey the whole cave.
// Inside the milk, scattered inclusions of chromium (ruby) glow an even red all the time: irregular shards and
// streaks with a clean edge and only a thin glow around (the red light they throw on the rock around them comes
// from the AreaLight3D that CaveMineral.add_inclusion_lights sets on the most visible ones, with this very
// layout). Under the UV torch (a negative light reaching RENDER_MASK_FLUORESCENT) they flare and the milk itself
// glows white. Only in a rock that fluoresces at all (rocks.py): iron-quenched rocks (blue, green, black) stay
// dark.
// Everything is in the MESH frame (the cave mesh is cave-local; decoration instances are offset by their
// index), so no world coordinate and no precision loss at planetary distances.
//
// Per cave (CaveMineral.dress_surface): the rock's colour, how far the milk is tinted toward it, and its
// fluorescence (colour, strength 0..1).
render_mode diffuse_lambert_wrap;

instance uniform vec3 wall_tint = vec3(0.72, 0.66, 0.58);
instance uniform float tint_strength = 0.45;
instance uniform vec4 glow = vec4(0.0);

uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
// Colour of the milk where the crystal is cloudiest.
uniform vec3 milk_color : source_color = vec3(0.95, 0.94, 0.91);
// Brightness of the clear depth seen through the thin clouds (0..1 of the milk): lower = darker, glassier.
uniform float depth_brightness : hint_range(0.0, 1.0, 0.01) = 0.7;
// How much more the clear depth takes the rock's colour than the milk does (0..1).
uniform float depth_saturation : hint_range(0.0, 1.0, 0.01) = 0.6;
// Size of the milky clouds (repeats per metre): higher = smaller clouds.
uniform float cloud_scale : hint_range(0.1, 10.0, 0.05) = 1.6;
// Share of the stone that is milky cloud (0..1): lower = more clear pockets, more translucent.
uniform float cloud_cover : hint_range(0.0, 1.0, 0.01) = 0.6;
// Opacity of the milky clouds and of the clear crystal (per metre): higher = more opaque.
uniform float milk_density : hint_range(0.0, 40.0, 0.1) = 9.0;
uniform float clear_density : hint_range(0.0, 10.0, 0.05) = 0.8;
// Spacing (m) of the cloud layers along the view: larger = deeper-looking stone, stronger parallax.
uniform float layer_depth_m : hint_range(0.01, 1.0, 0.01) = 0.12;
// Growth bands: direction across them (mesh frame), spacing (m), sharpness and brightness.
uniform vec3 band_axis = vec3(0.25, 1.0, 0.15);
uniform float band_spacing_m : hint_range(0.005, 1.0, 0.005) = 0.06;
uniform float band_sharpness : hint_range(1.0, 64.0, 1.0) = 32.0;
uniform float band_strength : hint_range(0.0, 1.0, 0.01) = 0.07;
// Iron stains: colour, share of the surface (0..1) and size (repeats per metre).
uniform vec3 stain_color : source_color = vec3(0.78, 0.5, 0.26);
uniform float stain_amount : hint_range(0.0, 0.5, 0.005) = 0.06;
uniform float stain_scale : hint_range(0.1, 10.0, 0.05) = 2.5;
// Relief of the surface (normal map): tiling per metre and strength (0 flat).
uniform float normal_scale : hint_range(0.01, 2.0, 0.01) = 0.05;
uniform float normal_strength : hint_range(0.0, 2.0, 0.01) = 0.2;
// Light wrapping round the relief (0 = hard Lambert, 1 = lit all round): the soft look of a translucent stone.
uniform float wrap : hint_range(0.0, 1.0, 0.01) = 0.5;
// Light spreading inside the stone and coming back out around the beam, in the depth colour (0..1).
uniform float scatter : hint_range(0.0, 1.0, 0.01) = 0.35;
// Glossy lustre: highlight tightness (higher = smaller, wetter glints) and strength.
uniform float sheen_power : hint_range(2.0, 512.0, 1.0) = 80.0;
uniform float sheen : hint_range(0.0, 2.0, 0.01) = 0.45;
// Glowing ruby inclusions: spacing (m) of the grid they are scattered on (one at most per cell) and share of the
// cells holding one (0..1): lower spacing or higher share = more inclusions. CaveMineral reads these two,
// spot_size_m, spot_raggedness and spot_color to light the inclusions it sees: keep them set in this shader's
// materials.
uniform float spot_spacing_m : hint_range(0.3, 20.0, 0.05) = 4.0;
uniform float spot_chance : hint_range(0.0, 1.0, 0.01) = 0.6;
// Depth (m) of the inclusions under the surface (parallax).
uniform float spot_depth_m : hint_range(0.0, 1.0, 0.01) = 0.05;
// Size (m, half-length of the main lobe) of the largest inclusions (they range from half to all of it; capped
// so an inclusion, its lobes, its depth and its glow fit within one spacing).
uniform float spot_size_m : hint_range(0.02, 4.0, 0.01) = 1.0;
// Shape: how elongated the lobes can get (1 = round) and how ragged the outline is (0 = smooth).
uniform float spot_elongation : hint_range(1.0, 8.0, 0.05) = 4.0;
uniform float spot_raggedness : hint_range(0.0, 1.0, 0.01) = 0.4;
// Softness of their edge (share of the size): 0 = cut out, higher = blurred.
uniform float spot_edge : hint_range(0.0, 1.0, 0.01) = 0.08;
// Thin glow just outside them (0 = none); the wide red light on the rock is the AreaLight3D's.
uniform float spot_halo : hint_range(0.0, 1.0, 0.01) = 0.06;
// Colour of the inclusions (chromium: ruby red) and its strength without UV (emission).
uniform vec3 spot_color : source_color = vec3(1.0, 0.08, 0.05);
uniform float spot_glow : hint_range(0.0, 20.0, 0.05) = 1.6;
// Under the UV torch: how much the inclusions flare, and how much the milk itself glows white (0 = dark beam).
uniform float fluo_uv : hint_range(0.0, 20.0, 0.05) = 0.6;
uniform float fluo_base : hint_range(0.0, 1.0, 0.005) = 0.05;
// Share of the environment's ambient light the rock gets (0..1): the sky lights the caves too and greys the
// white milk; the torch and the glow lights do the rest.
uniform float ambient_light : hint_range(0.0, 1.0, 0.01) = 0.25;
// Screen-space subsurface scattering (0..1): blurs the light inside the stone; costs GPU time.
uniform float subsurface : hint_range(0.0, 1.0, 0.01) = 0.25;

// How far an inclusion reaches into the rock compared to across it (INCLUSION_FLATTEN): deep inclusions cut the
// surface more often. Its lobes and warp reach INCLUSION_EXTENT of its size, its glow INCLUSION_GLOW_REACH.
// CaveMineral uses the same values.
const float INCLUSION_FLATTEN = 0.4;
const float INCLUSION_EXTENT = 1.6;
const float INCLUSION_GLOW_REACH = 1.15;

varying vec3 v_pos;
varying vec3 v_normal;
varying vec3 v_scatter;
varying vec3 v_fluo;
varying float v_milk_glow;

void vertex() {
	// Decoration instances share one mesh: offset each one so no two rocks show the same clouds.
	v_pos = VERTEX + vec3(float(INSTANCE_ID) * 7.31, float(INSTANCE_ID) * 3.17, float(INSTANCE_ID) * 5.73);
	v_normal = NORMAL;
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
			mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
			mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float clouds(vec3 p) {
	return (value_noise(p) * 0.57 + value_noise(p * 2.03 + 17.1) * 0.29 + value_noise(p * 4.11 + 41.7) * 0.14);
}

// Distance (in lobe sizes, 1 = on the outline) from v to an ellipsoid lobe stretched along a random axis.
float lobe(vec3 v, vec3 seed, float size) {
	vec3 axis = normalize(vec3(hash13(seed + 41.1), hash13(seed + 43.7), hash13(seed + 47.3)) - 0.5 + 1e-3);
	float stretch = 1.0 + (spot_elongation - 1.0) * hash13(seed + 53.9);
	float along = dot(v, axis);
	return length(axis * along + (v - axis * along) * stretch) / size;
}

// The ruby inclusions around q, on a surface of mesh-frame normal n: (inside 0..1, thin glow outside). Each sits
// anywhere in its grid cell and reaches one cell at most (depth, lobes and glow included), so the 3×3×3 cells
// around q hold every one that can show. Its shape: three stretched lobes of different sizes and directions,
// warped and roughened by noise, deep into the rock — a shard or a streak, not a disc.
vec2 inclusions(vec3 q, vec3 n) {
	vec3 g = q / spot_spacing_m;
	vec3 centre_cell = floor(g);
	float reach = INCLUSION_EXTENT * (1.0 + 0.5 * spot_raggedness) * INCLUSION_GLOW_REACH;
	float size_max = min(spot_size_m, spot_spacing_m * (1.0 - INCLUSION_FLATTEN) / reach);
	vec2 found = vec2(0.0);
	for (int i = 0; i < 27; i++) {
		vec3 cell = centre_cell + vec3(float(i % 3) - 1.0, float((i / 3) % 3) - 1.0, float(i / 9) - 1.0);
		if (hash13(cell + 13.7) > spot_chance) {
			continue;
		}
		vec3 centre = cell + vec3(hash13(cell + 3.1), hash13(cell + 7.9), hash13(cell + 11.3));
		vec3 v = (g - centre) * spot_spacing_m;
		v -= n * dot(v, n) * INCLUSION_FLATTEN;
		float size = size_max * (0.5 + 0.5 * hash13(cell + 29.3));
		if (dot(v, v) > size * size * reach * reach) {
			continue;
		}
		// Warp the space around it: the lobes bend and the outline wanders.
		vec3 wq = q / size * 0.8 + cell * 5.0;
		v += (vec3(value_noise(wq), value_noise(wq + 19.3), value_noise(wq + 37.9)) - 0.5) * size * 0.8;
		float d = lobe(v, cell, size);
		for (int k = 1; k < 3; k++) {
			vec3 seed = cell + float(k) * 17.17;
			vec3 offset = (vec3(hash13(seed + 3.3), hash13(seed + 5.5), hash13(seed + 9.9)) - 0.5) * size * 1.2;
			d = min(d, lobe(v - offset, seed, size * (0.35 + 0.35 * hash13(seed + 23.1))));
		}
		d *= 1.0 + spot_raggedness * (value_noise(q / size * 3.0 + cell * 7.0) - 0.5);
		float inside = 1.0 - smoothstep(1.0 - spot_edge, 1.0, d);
		float glow_out = max(1.0 - (d - 1.0) / (INCLUSION_GLOW_REACH - 1.0), 0.0);
		found = max(found, vec2(inside, glow_out * glow_out * (1.0 - inside)));
	}
	return found;
}

// A thin bright line every band_spacing_m across band_axis, wavering with the clouds.
float band(vec3 q, float cloud) {
	float t = dot(q, normalize(band_axis)) / band_spacing_m + cloud * 1.2;
	return pow(abs(sin(t * PI)), band_sharpness) + 0.5 * pow(abs(sin(t * 0.37 * PI + 1.3)), band_sharpness * 2.0);
}

void fragment() {
	vec3 n = normalize(v_normal);
	vec3 w = pow(abs(n), vec3(4.0));
	w /= w.x + w.y + w.z;
	float peak = max(max(wall_tint.r, wall_tint.g), max(wall_tint.b, 1e-3));
	vec3 hue = wall_tint / peak;
	vec3 milk = milk_color * mix(vec3(1.0), hue, tint_strength);
	vec3 deep = milk_color * depth_brightness * mix(vec3(1.0), hue, min(tint_strength + depth_saturation, 1.0));
	// The view ray in the mesh frame, entering the rock (the cave transform is a rotation: transpose inverts it).
	vec3 to_eye = normalize(transpose(mat3(MODEL_MATRIX)) * (mat3(INV_VIEW_MATRIX) * VIEW));
	float facing = max(dot(to_eye, n), 0.3);
	// Front to back through the clouds: each layer covers what lies behind it.
	vec3 colour = vec3(0.0);
	float through = 1.0;
	for (int layer = 0; layer < 4; layer++) {
		float depth = layer_depth_m * float(layer);
		vec3 q = v_pos - to_eye * depth / facing;
		float cloud = clouds(q * cloud_scale);
		float milky = smoothstep(1.0 - cloud_cover - 0.12, 1.0 - cloud_cover + 0.12, cloud);
		float alpha = 1.0 - exp(-mix(clear_density, milk_density, milky) * layer_depth_m);
		vec3 layer_colour = milk * (1.0 - 0.06 * float(layer)) * (1.0 + band_strength * band(q, cloud));
		colour += through * alpha * layer_colour;
		through *= 1.0 - alpha;
	}
	colour += through * deep;
	float stain = smoothstep(1.0 - stain_amount, 1.0 - stain_amount + 0.06, clouds(v_pos * stain_scale + 91.3));
	colour = mix(colour, colour * stain_color * 1.1, stain * 0.8);
	ALBEDO = colour;
	// The ruby inclusions, just under the surface: an even red, a thin glow around.
	float fluorescent = glow.a > 0.0 ? 1.0 : 0.0;
	vec2 inclusion = inclusions(v_pos - to_eye * spot_depth_m / facing, n) * fluorescent;
	v_fluo = spot_color * (inclusion.x + spot_halo * inclusion.y);
	// Under the torch too an inclusion stays ruby red, not milk lit pink.
	ALBEDO = mix(ALBEDO, spot_color * 0.5, inclusion.x);
	v_milk_glow = fluo_base * fluorescent;
	EMISSION = v_fluo * spot_glow;
	// Light coming back out of the depth takes the rock's colour.
	v_scatter = mix(milk, deep / max(depth_brightness, 0.05), 0.5);

	vec3 p = v_pos * normal_scale;
	vec2 nx = (texture(normal_tex, p.zy).xy * 2.0 - 1.0) * normal_strength;
	vec2 ny = (texture(normal_tex, p.xz).xy * 2.0 - 1.0) * normal_strength;
	vec2 nz = (texture(normal_tex, p.xy).xy * 2.0 - 1.0) * normal_strength;
	// Whiteout blend of the three planar normal maps around the mesh normal.
	vec3 bent = normalize(vec3(0.0, nx.y, nx.x) * w.x + vec3(ny.x, 0.0, ny.y) * w.y + vec3(nz.x, nz.y, 0.0) * w.z + n);
	NORMAL = normalize(mat3(VIEW_MATRIX) * (MODEL_NORMAL_MATRIX * bent));
	ROUGHNESS = 0.4;
	// The sky's reflection reaches the caves: a mirror term would grey them. The lustre is light() only.
	SPECULAR = 0.0;
	AO = ambient_light;
	AO_LIGHT_AFFECT = 0.0;
	SSS_STRENGTH = subsurface;
}

void light() {
	if (LIGHT_COLOR.r < 0.0) {
		// The UV torch: no visible light, it makes the inclusions flare and the milk glow white (the milk
		// scatters it all round, so faces turned away glow a little too).
		float uv = dot(-LIGHT_COLOR, vec3(1.0 / 3.0)) * ATTENUATION * (0.35 + 0.65 * max(dot(NORMAL, LIGHT), 0.0));
		SPECULAR_LIGHT += (v_fluo * fluo_uv + ALBEDO * v_milk_glow) * uv;
	}
	vec3 light_colour = max(LIGHT_COLOR, vec3(0.0)) / PI * ATTENUATION;
	float ndl = dot(NORMAL, LIGHT);
	// A custom light() gets no albedo applied: it is ours to multiply.
	DIFFUSE_LIGHT += ALBEDO * max((ndl + wrap) / (1.0 + wrap), 0.0) * light_colour;
	DIFFUSE_LIGHT += v_scatter * scatter * (0.5 + 0.5 * max(ndl, 0.0)) * light_colour;
	vec3 half_vector = normalize(VIEW + LIGHT);
	float lustre = pow(max(dot(NORMAL, half_vector), 0.0), sheen_power) * (sheen_power + 8.0) / 8.0;
	SPECULAR_LIGHT += lustre * sheen * max(ndl, 0.0) * light_colour;
}
