shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Lava flow (LavaSettings / GradeBed): molten, glowing lava with plates of
// crust drifting downstream on it. The crust is the GROUND'S OWN ROCK: COLOR is
// the rock tint baked per vertex by PlanetChunk (road_ground_tint × the state's
// darkening), RAW like every vertex colour of the terrain.
//
// UV is the flow frame of RoadRibbon's FLOW mode: x = along / tile
// (downstream), y = across / tile. PlanetChunk shifts each chunk's UVs by a
// whole number of tiles, so every pattern here is PERIODIC over one tile —
// otherwise the lava would show a seam at every chunk border.
//
// heat 1 / crust_coverage ~0.4 = active; ~0.35 / 0.8 = cooling; 0 / 1 = solid.

group_uniforms Crust;
uniform float crust_coverage : hint_range(0.0, 1.0, 0.01) = 0.4;
// Plates per tile, across and along (integers keep the tile period).
uniform float plate_cells : hint_range(1.0, 32.0, 1.0) = 14.0;
uniform float crust_roughness : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float crust_relief : hint_range(0.0, 4.0, 0.01) = 1.5;

group_uniforms Heat;
uniform float heat : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform vec4 glow_hot : source_color = vec4(1.0, 0.85, 0.45, 1.0);
uniform vec4 glow_mid : source_color = vec4(1.0, 0.45, 0.08, 1.0);
uniform vec4 glow_cool : source_color = vec4(0.45, 0.05, 0.02, 1.0);
uniform float glow_energy : hint_range(0.0, 32.0, 0.1) = 3.0;
// Tiles per second along the flow, at full heat (the molten layer); the
// crust plates drift at plate_drift of that.
uniform float flow_speed : hint_range(0.0, 1.0, 0.001) = 0.01;
uniform float plate_drift : hint_range(0.0, 1.0, 0.01) = 0.55;

// ── Periodic value noise: lattice wrapped every `period` cells ─────────
float hash2(vec2 c) {
	return fract(sin(dot(c, vec2(127.1, 311.7))) * 43758.5453);
}

float pnoise(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	vec2 i0 = mod(i, period);
	vec2 i1 = mod(i + 1.0, period);
	float a = hash2(i0);
	float b = hash2(vec2(i1.x, i0.y));
	float c = hash2(vec2(i0.x, i1.y));
	float d = hash2(i1);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// fBm over one tile: octave k runs at cells·2^k and wraps at the same count.
float pfbm(vec2 uv, float cells, int octaves) {
	float v = 0.0;
	float a = 0.5;
	float n = cells;
	for (int k = 0; k < 5; k++) {
		if (k >= octaves) break;
		v += a * pnoise(uv * n, n);
		n *= 2.0;
		a *= 0.5;
	}
	return v;
}

// Crust mask in [0, 1] (1 = crust) and the plate's own height.
float crust_at(vec2 uv) {
	float n = pfbm(uv, plate_cells, 4);
	float th = 1.0 - crust_coverage;
	return smoothstep(th - 0.06, th + 0.06, n * 1.15 - 0.075);
}

void fragment() {
	float t = TIME * flow_speed * max(heat, 0.05);
	vec2 uv_plate = UV - vec2(t * plate_drift, 0.0);
	vec2 uv_melt = UV - vec2(t, 0.0);

	float c = crust_coverage >= 0.999 ? 1.0 : crust_at(uv_plate);
	// Fine grain of the crust and of the molten skin.
	float grain = pfbm(uv_plate, 96.0, 3);
	float swirl = pfbm(uv_melt + vec2(0.0, 0.08 * pfbm(uv_melt, 8.0, 2)), 20.0, 4);

	// Molten colour: white-yellow in the hottest threads, orange, dark red
	// where it cools against the plates.
	float hot = clamp(swirl * 1.3 - 0.3, 0.0, 1.0) * (1.0 - 0.7 * c);
	vec3 melt = mix(glow_cool.rgb, glow_mid.rgb, smoothstep(0.1, 0.55, hot));
	melt = mix(melt, glow_hot.rgb, smoothstep(0.6, 0.95, hot));

	vec3 rock = COLOR.rgb * (0.7 + 0.45 * grain);
	// Incandescent plate rims while the flow is hot.
	float rim = c * (1.0 - c) * 4.0;

	ALBEDO = mix(melt * 0.35, rock, c);
	ROUGHNESS = mix(0.3, crust_roughness, c);
	METALLIC = 0.0;
	EMISSION = (melt * (1.0 - c) + glow_mid.rgb * rim * 0.6) * glow_energy * heat;

	// Relief: raised plates, grainy crust, a smooth melt.
	float e = 1.0 / 256.0;
	float h0 = c + 0.25 * grain * c;
	float hx = (crust_coverage >= 0.999 ? 1.0 : crust_at(uv_plate + vec2(e, 0.0))) + 0.25 * grain * c;
	float hy = (crust_coverage >= 0.999 ? 1.0 : crust_at(uv_plate + vec2(0.0, e))) + 0.25 * grain * c;
	vec2 g = vec2(hx - h0, hy - h0) / e * 0.01 * crust_relief;
	NORMAL_MAP = normalize(vec3(-g.x, -g.y, 1.0)) * 0.5 + 0.5;
}
