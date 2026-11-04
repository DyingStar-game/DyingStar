shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

// Smoke left by a stone: one ribbon per instance, every point of it computed from the stone's row in
// stone_tex. A point of the ribbon is the smoke the stone left tau seconds ago: where the arc was at
// (age - tau), drifted since by the wind and swollen with time. So the trail hangs in the air while the
// stone flies on, with no history kept anywhere. A promoted stone (w = 2) keeps its trail: the prop
// follows the same arc down to the impact.

uniform sampler2D stone_tex : filter_nearest;
uniform float t_mod = 0.0;
uniform float period = 60.0;
uniform float gravity = 9.81;
uniform int stride = 5;
uniform float trail_s = 7.0;
uniform vec3 cam_local;
uniform vec3 wind = vec3(-6.0, 0.0, 1.0);
uniform vec3 smoke_color = vec3(0.26, 0.25, 0.245);

varying float v_u;
varying float v_fade;
varying float v_seed;
varying float v_near;

vec3 smoke_at(vec3 v0, float flight, float age, float tau) {
	float e = clamp(age - tau, 0.0, flight);
	return v0 * e + vec3(0.0, -0.5 * gravity * e * e, 0.0) + (wind + vec3(0.0, 1.2, 0.0)) * tau;
}

void vertex() {
	int slot = INSTANCE_ID * stride;
	vec4 a = texelFetch(stone_tex, ivec2(slot, 0), 0);
	vec4 b = texelFetch(stone_tex, ivec2(slot, 1), 0);
	float age = mod(t_mod - a.w, period);
	v_u = UV.x;
	v_seed = b.z;
	v_fade = 0.0;
	if (b.w < 0.5 || age > b.y + trail_s) {
		VERTEX = vec3(0.0, -1e7, 0.0);
	} else {
		float tau = UV.x * trail_s;
		vec3 p = smoke_at(a.xyz, b.y, age, tau);
		vec3 next = smoke_at(a.xyz, b.y, age, tau + 0.15);
		vec3 along = next - p;
		float len = length(along);
		along = len > 0.001 ? along / len : vec3(0.0, 1.0, 0.0);
		vec3 side = cross(along, normalize(cam_local - p));
		float side_len = length(side);
		side = side_len > 0.001 ? side / side_len : vec3(1.0, 0.0, 0.0);
		float dist = length(cam_local - p);
		v_near = smoothstep(40.0, 260.0, dist);
		// Swells with time; never thinner than about a pixel, or it would shimmer from afar.
		float width = max(b.x * 0.9 + tau * 2.6, dist * 0.0013);
		VERTEX = p + side * VERTEX.x * width;
		// Dissolves from the tail; once the stone is down, what is left thins out.
		v_fade = 1.0 - smoothstep(0.0, trail_s, age - b.y);
		// Older than the stone: nothing was emitted yet at that point of the ribbon.
		v_fade *= smoothstep(0.0, 0.3, age - tau);
	}
}

void fragment() {
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float rag = 0.55 + 0.45 * sin(v_u * 37.0 + v_seed * 90.0) * sin(v_u * 91.0 + v_seed * 31.0);
	// Never a negative base: pow() is undefined there, and one invalid pixel becomes a white disc through the glow.
	float tail = pow(max(1.0 - v_u, 0.0), 1.4);
	ALBEDO = mix(smoke_color, vec3(1.0, 0.45, 0.12), smoothstep(0.03, 0.0, v_u) * 0.8);
	ALPHA = smoothstep(0.0, 0.7, across) * tail * mix(0.5, 1.0, rag) * v_fade * v_near * 0.65;
}
