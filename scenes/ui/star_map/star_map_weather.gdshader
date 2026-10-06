shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_never;
// The synoptic chart over a body (StarMapWeather): the pressure anomaly as a diverging fill — blue
// where the air is low, red where it is high, clear where it is normal — with isobars every
// `isobar_pa`, and the dust in the air as an ochre veil. The fields come as one texture sampled on a
// lon/lat grid (r = pressure anomaly Pa, g = dust optical depth, b = humidity, a = wind m/s); the
// shell's own position says which texel to read, in the body's frame (longitude = atan2(z, x),
// latitude = asin(y)), so no UV convention of the sphere mesh is relied on.

uniform sampler2D fields : filter_linear, repeat_enable;
// 0 = not drawn, 1 = fully drawn: the chart fades the layer with the zoom.
uniform float alpha = 1.0;
uniform float isobar_pa = 400.0;
uniform float range_pa = 2000.0;

const vec3 LOW = vec3(0.15, 0.35, 0.95);
const vec3 HIGH = vec3(0.95, 0.25, 0.15);
const vec3 OCHRE = vec3(0.80, 0.55, 0.25);
const vec3 INK = vec3(0.10, 0.10, 0.12);

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	vec3 d = normalize(v_local);
	float lon = atan(d.z, d.x);
	float lat = asin(clamp(d.y, -1.0, 1.0));
	vec2 uv = vec2(lon / 6.2831853 + 0.5, 0.5 - lat / 3.1415927);
	vec4 f = texture(fields, uv);
	// The fill: transparent at a normal pressure, saturating at ±range_pa.
	float t = clamp(f.r / range_pa, -1.0, 1.0);
	vec3 colour = t < 0.0 ? mix(vec3(1.0), LOW, -t) : mix(vec3(1.0), HIGH, t);
	float a = 0.55 * pow(abs(t), 0.7);
	// The dust veil over it.
	float dust = clamp(f.g * 0.4, 0.0, 0.7);
	colour = mix(colour, OCHRE, dust);
	a = a + dust * (1.0 - a);
	// The isobars: one line wherever the pressure crosses a multiple of isobar_pa, a pixel or so wide
	// whatever the zoom (fwidth says how much the level changes across one pixel).
	float level = f.r / isobar_pa;
	float width = max(fwidth(level) * 1.5, 1e-4);
	float line = 1.0 - smoothstep(0.0, width, abs(fract(level + 0.5) - 0.5));
	float ink = line * 0.75;
	colour = mix(colour, INK, ink);
	a = a + ink * (1.0 - a);
	ALBEDO = colour;
	ALPHA = a * alpha;
}
