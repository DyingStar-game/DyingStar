shader_type spatial;
// Milky corundum of the cave walls, floor and rocks (CaveMineral): not a stone texture but a white, half
// translucent crystal. Under the surface the view ray crosses a few layers of milky clouds (procedural noise):
// where they are thick the rock is milk white, where they thin out the eye sees deeper, into a greyer and
// more coloured depth. Fine growth bands and rare iron stains mark it like a real crystal, light wraps
// around the relief and spreads inside the stone (custom light()), and the lustre is glossy, almost wet, from
// the lights only: the sky's reflection (which reaches the caves) is cut, it would grey the whole cave.
// Under the UV torch (a negative light reaching RENDER_MASK_FLUORESCENT) the milk glows white, in a rock that
// fluoresces at all (rocks.py): iron-quenched rocks (blue, green, black) stay dark. The red of the caves is in
// their ruby crystals (cave_crystal.gdshaderinc), not in the stone.
// Underground, no daylight: the sun and moons (directional lights) and the sky's ambient light do not reach the
// rock (daylight, ambient_light); only the torches and the crystals' glow lights do. What stands in the open
// air keeps them, as much as it is open (open_air_source): an entrance's surfaces by their ground cover (the
// vertex colour, CaveEntrance.ground_cover), the rocks around the mouth and on its approach by their own share
// (the MultiMesh custom data, CavePreviewBuilder).
// Everything is in the MESH frame (the cave mesh is cave-local; decoration instances are offset by their
// index), so no world coordinate and no precision loss at planetary distances.
//
// Per cave (CaveMineral.dress_surface): the rock's colour, how far the milk is tinted toward it, and its
// fluorescence (colour, strength 0..1).
render_mode diffuse_lambert_wrap;

instance uniform vec3 wall_tint = vec3(0.72, 0.66, 0.58);
instance uniform float tint_strength = 0.45;
instance uniform vec4 glow = vec4(0.0);
// Where this surface's share of open sky comes from (CaveMineral.dress_surface): 0 = none, all underground;
// 1 = the vertex colour's red (an entrance's ground cover); 2 = the MultiMesh instance's custom data red (a rock).
instance uniform float open_air_source = 0.0;

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
// Under the UV torch: how much the milk itself glows white (0 = dark beam).
uniform float fluo_base : hint_range(0.0, 1.0, 0.005) = 0.05;
// Share of the environment's ambient light the rock gets (0..1): 0 underground, the sky does not reach it; the
// torches and the glow lights do the rest.
uniform float ambient_light : hint_range(0.0, 1.0, 0.01) = 0.0;
// Share of the sun's and moons' light (directional lights) the rock gets (0..1): 0 underground, where the
// terrain's shadow would not always stop it (shadow distance, settings without shadows).
uniform float daylight : hint_range(0.0, 1.0, 0.01) = 0.0;
// Share of the environment's ambient light in the open air (0..1), for the rock outside the mouth: above 0.25
// the sky greys the white milk.
uniform float open_air_ambient : hint_range(0.0, 1.0, 0.01) = 0.25;
// Screen-space subsurface scattering (0..1): blurs the light inside the stone; costs GPU time.
uniform float subsurface : hint_range(0.0, 1.0, 0.01) = 0.25;

varying vec3 v_pos;
varying vec3 v_normal;
varying vec3 v_scatter;
varying float v_milk_glow;
// Share of open sky over this point (0 underground .. 1 in the open air).
varying float v_open;

void vertex() {
	// Decoration instances share one mesh: offset each one so no two rocks show the same clouds.
	v_pos = VERTEX + vec3(float(INSTANCE_ID) * 7.31, float(INSTANCE_ID) * 3.17, float(INSTANCE_ID) * 5.73);
	v_normal = NORMAL;
	v_open = open_air_source > 1.5 ? INSTANCE_CUSTOM.r : (open_air_source > 0.5 ? COLOR.r : 0.0);
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
	float fluorescent = glow.a > 0.0 ? 1.0 : 0.0;
	v_milk_glow = fluo_base * fluorescent;
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
	AO = mix(ambient_light, open_air_ambient, v_open);
	AO_LIGHT_AFFECT = 0.0;
	SSS_STRENGTH = subsurface;
}

void light() {
	if (LIGHT_COLOR.r < 0.0) {
		// The UV torch: no visible light, it makes the milk glow white (the milk scatters it all round, so
		// faces turned away glow a little too).
		float uv = dot(-LIGHT_COLOR, vec3(1.0 / 3.0)) * ATTENUATION * (0.35 + 0.65 * max(dot(NORMAL, LIGHT), 0.0));
		SPECULAR_LIGHT += ALBEDO * v_milk_glow * uv;
	}
	vec3 light_colour = max(LIGHT_COLOR, vec3(0.0)) / PI * ATTENUATION * (LIGHT_IS_DIRECTIONAL ? mix(daylight, 1.0, v_open) : 1.0);
	float ndl = dot(NORMAL, LIGHT);
	// A custom light() gets no albedo applied: it is ours to multiply.
	DIFFUSE_LIGHT += ALBEDO * max((ndl + wrap) / (1.0 + wrap), 0.0) * light_colour;
	DIFFUSE_LIGHT += v_scatter * scatter * (0.5 + 0.5 * max(ndl, 0.0)) * light_colour;
	vec3 half_vector = normalize(VIEW + LIGHT);
	float lustre = pow(max(dot(NORMAL, half_vector), 0.0), sheen_power) * (sheen_power + 8.0) / 8.0;
	SPECULAR_LIGHT += lustre * sheen * max(ndl, 0.0) * light_colour;
}
