shader_type spatial;
// A spark of static inside a dust wall (DustSparks): a quad standing upright, facing the eye, with a thin
// crooked arc drawn on it from its top to its bottom, a few side arcs branching off, and a faint glow.
// Added over what is behind it; hidden by the ground like anything else.
render_mode blend_add, cull_disabled, depth_draw_never, shadows_disabled, unshaded;

uniform sampler2D noise : repeat_enable, filter_linear_mipmap;
uniform vec3 colour : source_color = vec3(0.72, 0.84, 1.0);
// How crooked the arc is (shares of the quad's width: its large bends, its fine ones), how thick its core
// (a share of the width, never under a pixel and a half), and how wide and bright the glow round it.
uniform vec2 crooked = vec2(0.55, 0.1);
uniform float core = 0.004;
uniform float halo = 0.045;
uniform float halo_gain = 0.22;
// Side arcs: how many, and how far they lean per unit of height.
uniform int branches = 3;
uniform float lean = 0.55;
// How bright the spark is now (it flickers), and the number its shape is drawn from.
instance uniform float bright = 1.0;
instance uniform float seed = 0.0;
// How much of the open air the eye is in, 1 outside to 0 under the ground (a cave, a mine): the weather
// does not come in (WeatherPhenomena).
instance uniform float open_air = 1.0;

// Where the arc is across the quad (0 to 1) at a height (0 bottom, 1 top).
float path(float y, float s) {
	return 0.5 + (texture(noise, vec2(y * 0.55 + s, s * 1.37)).r - 0.5) * crooked.x
			+ (texture(noise, vec2(y * 2.9 + s * 2.3, 0.21 + s)).r - 0.5) * crooked.y;
}

// How lit a place is by an arc passing dist away across the quad: a thin core, a glow.
float arc(float dist, float thick) {
	return smoothstep(thick, thick * 0.3, dist) + halo_gain * exp(-dist * dist / (halo * halo));
}

void fragment() {
	float y = 1.0 - UV.y;
	float thick = max(core, fwidth(UV.x) * 1.5);
	// The arc fades in at its two ends.
	float ends = smoothstep(0.0, 0.06, y) * smoothstep(1.0, 0.9, y);
	float glow = arc(abs(UV.x - path(y, seed)), thick) * ends;
	for (int k = 0; k < branches; k++) {
		float s = seed + float(k) * 0.731;
		// A side arc leaves the main one at a height and runs down and aside, thinner, for a while.
		float from = 0.35 + 0.5 * fract(s * 7.31);
		float run = 0.15 + 0.2 * fract(s * 3.17);
		float side = fract(s * 5.03) < 0.5 ? -1.0 : 1.0;
		float down = from - y;
		if (down > 0.0 && down < run) {
			float x = path(from, seed) + side * down * lean + (texture(noise, vec2(y * 3.7 + s, s)).r - 0.5) * crooked.y * 1.5;
			glow += arc(abs(UV.x - x), thick * 0.7) * 0.6 * (1.0 - down / run);
		}
	}
	// Nothing at the quad's edges.
	glow *= smoothstep(0.0, 0.08, UV.x) * smoothstep(1.0, 0.92, UV.x);
	ALBEDO = colour * glow * bright * open_air;
	ALPHA = clamp(glow * bright * open_air, 0.0, 1.0);
}
