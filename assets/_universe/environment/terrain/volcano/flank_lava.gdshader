shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
#include "res://scenes/planet/weather/dust_sea_light.gdshaderinc"

// Incandescent flows on a volcano's flanks (VolcanoVentGlow): ribbons laid on the relief, UV.x along
// the flow (0 at the source), UV.y across. Additive light only: the crust is the ground under the
// ribbon, only its hot cracks and its hot core add their glow, so the flow needs no lighting of its own
// and looks right by day and by night. Pulled a little towards the eye so the terrain's coarse LODs
// never swallow it. Drawn after the aerial pass, so it fades through the dust sea by itself (sea_fog).

uniform float heat = 0.0;
uniform float seed = 0.0;
uniform vec3 hot_color = vec3(1.6, 0.42, 0.06);
uniform vec3 dull_color = vec3(0.45, 0.05, 0.0);
// The vent's altitude (m over the planet's reference sphere): the mesh is in the vent's frame, so a point
// of a flow is that much plus its model height.
uniform float vent_alt_m = 0.0;

varying float v_dist;
varying float v_height;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	vec3 vv = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float d = length(vv);
	v_dist = d;
	v_height = VERTEX.y;
	float pull = 2.0 + d * 0.004;
	vv *= max(d - pull, d * 0.5) / max(d, 0.001);
	POSITION = PROJECTION_MATRIX * vec4(vv, 1.0);
}

void fragment() {
	float u = UV.x;
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	// Cracks in the crust: thin bright lines of a cellular-looking noise, slowly crawling down the flow.
	vec2 q = vec2(u * 60.0 - TIME * 0.02, UV.y * 3.0) + seed;
	float n = vnoise(q) * 0.65 + vnoise(q * 2.7 + 5.1) * 0.35;
	float cracks = 1.0 - smoothstep(0.0, 0.09, abs(n - 0.5));
	// Seen from far, the cracks alias: the flow becomes a dimmer, even glow instead.
	float far = smoothstep(1500.0, 6000.0, v_dist);
	float pattern = mix(cracks, 0.35, far);
	// The hot core along the middle, the source hotter than the toe, which has crusted over.
	float core = smoothstep(0.35, 1.0, across) * (1.0 - smoothstep(0.0, 0.7, u)) * 0.6;
	float glow = max(pattern * smoothstep(0.0, 0.35, across), core);
	float cooling = mix(1.0, 0.25, u);
	vec3 col = mix(dull_color, hot_color, clamp(heat * cooling * 1.2, 0.0, 1.0));
	// Rag the edges and the toe so the ribbon never shows a straight border.
	float edge = smoothstep(0.0, 0.25, across) * (1.0 - smoothstep(0.85, 1.0, u + (n - 0.5) * 0.2));
	ALBEDO = col * glow * edge * heat * cooling * sea_fog(v_dist, vent_alt_m + v_height);
}
