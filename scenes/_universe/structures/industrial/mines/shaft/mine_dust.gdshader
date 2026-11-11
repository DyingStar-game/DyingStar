shader_type spatial;
render_mode blend_mix, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, specular_disabled, fog_disabled;
// The dust cloud a falling layer of a mine's face raises (MineDustCloud): a volume, not particles. The cloud is a
// chain of capsules along the gallery's axis (seg_a[i] .. seg_b[i], radius); for each pixel the view ray's length
// inside it, cut by the scene's depth, gives the opacity (1 - exp(-density * length)). The rock hides it beyond the
// gallery's walls, so the capsules may be wider than the gallery.
//
// Only the back faces of the box round the chain are drawn, without depth test: the cloud shows from outside and
// from inside alike. Everything is in the MESH frame (the camera brought there through MODELVIEW_MATRIX, which
// Godot builds in high precision): no world coordinate, no shaking at planetary distances.
//
// Lit where the eye sinks into it (LIGHT_VERTEX: a few metres in at most, as deep as one sees): the lamps and the
// torch light it, scattered every way (custom light()), so it stays dark in the dark and turns a pale wall in a
// lamp's or a torch's beam. The sky's ambient does not reach a mine (PlayerSunLight.underground).

const int MAX_SEGMENTS = 16;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
// The cloud's axis, segment by segment (mesh frame), and how many are in use.
uniform vec3 seg_a[16];
uniform vec3 seg_b[16];
uniform int seg_count = 0;
// Radius (m) of the cloud round its axis.
uniform float radius = 4.0;
// Extinction (per m): how fast the dust hides what is behind it.
uniform float density = 0.0;
uniform vec3 dust_color : source_color = vec3(0.62, 0.6, 0.56);
// How much of the lamps' and torches' light the dust scatters back.
uniform float light_gain = 1.8;
// Light of its own, so a cloud in the dark still reads as a mass.
uniform float glow = 0.01;
// Length (m) over which the cloud thins out at its front, as it rushes up the gallery.
uniform float front_soft_m = 5.0;
// Seconds since the fall: the clouds roll.
uniform float drift = 0.0;

varying vec3 v_local;
varying vec3 v_camera;

void vertex() {
	v_local = VERTEX;
	v_camera = (inverse(MODELVIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

vec2 sphere_span(vec3 ro, vec3 rd, vec3 centre, float r) {
	vec3 oc = ro - centre;
	float b = dot(oc, rd);
	float h = b * b - (dot(oc, oc) - r * r);
	if (h < 0.0) {
		return vec2(1e9, -1e9);
	}
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}

// Entry and exit of the ray in the capsule a..b (x > y: missed).
vec2 capsule_span(vec3 ro, vec3 rd, vec3 a, vec3 b, float r) {
	vec2 sa = sphere_span(ro, rd, a, r);
	vec2 sb = sphere_span(ro, rd, b, r);
	vec2 span = vec2(min(sa.x, sb.x), max(sa.y, sb.y));
	vec3 ba = b - a;
	float length_ab = length(ba);
	if (length_ab < 1e-4) {
		return span;
	}
	vec3 axis = ba / length_ab;
	vec3 oc = ro - a;
	vec3 d_side = rd - axis * dot(rd, axis);
	vec3 o_side = oc - axis * dot(oc, axis);
	float qa = dot(d_side, d_side);
	float qb = dot(o_side, d_side);
	float h = qb * qb - qa * (dot(o_side, o_side) - r * r);
	if (qa < 1e-8 || h < 0.0) {
		return span;
	}
	h = sqrt(h);
	float t0 = (-qb - h) / qa;
	float t1 = (-qb + h) / qa;
	float along = dot(oc, axis);
	float speed = dot(rd, axis);
	if (abs(speed) > 1e-6) {
		float u0 = -along / speed;
		float u1 = (length_ab - along) / speed;
		t0 = max(t0, min(u0, u1));
		t1 = min(t1, max(u0, u1));
	} else if (along < 0.0 || along > length_ab) {
		return span;
	}
	if (t0 < t1) {
		span = vec2(min(span.x, t0), max(span.y, t1));
	}
	return span;
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

void fragment() {
	vec3 ro = v_camera;
	vec3 to_back = v_local - v_camera;
	float back = length(to_back);
	vec3 rd = to_back / max(back, 1e-5);
	// What the scene shows along this ray: the dust stops there.
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene = depth <= 0.0 ? 1e9 : length(behind.xyz / behind.w);
	vec2 span = vec2(1e9, -1e9);
	for (int i = 0; i < MAX_SEGMENTS; i++) {
		if (i >= seg_count) {
			break;
		}
		vec2 s = capsule_span(ro, rd, seg_a[i], seg_b[i], radius);
		span = vec2(min(span.x, s.x), max(span.y, s.y));
	}
	float t0 = max(span.x, 0.0);
	float t1 = min(min(span.y, scene), back);
	float inside = max(t1 - t0, 0.0);
	if (inside <= 0.0 || density <= 0.0) {
		discard;
	}
	// Rolling clouds: a few samples of slow noise along the way through, thinner towards the front.
	vec3 wind = vec3(0.11, 0.04, 0.07) * drift;
	vec3 front = seg_b[max(seg_count - 1, 0)];
	float thick = 0.0;
	for (int k = 0; k < 4; k++) {
		vec3 p = ro + rd * mix(t0, t1, (float(k) + 0.5) / 4.0);
		float puff = value_noise(p * 0.45 + wind) * 0.65 + value_noise(p * 1.3 - wind * 1.7) * 0.35;
		thick += (0.45 + puff * 1.1) * smoothstep(0.0, front_soft_m, length(p - front));
	}
	thick /= 4.0;
	ALPHA = 1.0 - exp(-density * thick * inside);
	// Lit where the eye sinks in: half the way it sees into the dust, a metre at least (a torch in the hand would
	// blind it white closer), smooth (no noise in it, or the edge of a torch's cone turns jagged).
	float seen = 1.5 / max(density, 1e-3);
	float lit = t0 + min(inside, max(seen * 0.5, 1.0));
	// The mesh frame is the view's turned and moved, not scaled: the same distance along the same ray.
	LIGHT_VERTEX = normalize(VERTEX) * lit;
	NORMAL = -normalize(VERTEX);
	ALBEDO = dust_color;
	EMISSION = dust_color * glow;
}

void light() {
	// Dust scatters every way: no facing, the light's colour and falloff only. A custom light() gets no albedo.
	DIFFUSE_LIGHT += ALBEDO * max(LIGHT_COLOR, vec3(0.0)) * ATTENUATION * light_gain / PI;
}
