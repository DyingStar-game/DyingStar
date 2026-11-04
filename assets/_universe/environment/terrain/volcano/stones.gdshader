shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// The stones thrown by the volcano (StoneField): every instance computes its own flight from its row
// of stone_tex, so thousands of stones cost no CPU at all between their birth and their landing. A float
// texture, not INSTANCE_CUSTOM: instance data reaches the shader as half floats, which would put a
// long flight metres off the place StoneField computed for its landing.
//
// Row 0: launch velocity xyz, birth (modulo the period).  Row 1: radius, flight time, seed, 0 = hidden.

#include "res://assets/_universe/environment/terrain/volcano/rock_surface.gdshaderinc"

uniform sampler2D stone_tex : filter_nearest;
uniform float t_mod = 0.0;
uniform float period = 60.0;
uniform float gravity = 9.81;
uniform vec3 cam_local;

varying float v_heat;
varying float v_far;
varying vec3 v_q;

void vertex() {
	vec4 a = texelFetch(stone_tex, ivec2(INSTANCE_ID, 0), 0);
	vec4 b = texelFetch(stone_tex, ivec2(INSTANCE_ID, 1), 0);
	float age = mod(t_mod - a.w, period);
	if (b.w < 0.5 || b.w > 1.5 || age >= b.y) {
		VERTEX = vec3(0.0, -1e7, 0.0);
	} else {
		float t = min(age, b.y);
		vec3 pos = a.xyz * t + vec3(0.0, -0.5 * gravity * t * t, 0.0);
		vec3 vel = age < b.y ? a.xyz + vec3(0.0, -gravity * t, 0.0) : vec3(0.0);
		float dist = length(pos - cam_local);
		v_q = VERTEX * pow(b.x, 0.7) * 0.5 + vec3(b.z * 37.0);
		// A stone never gets smaller than about a pixel: from afar it is the glowing dot that counts.
		float size = max(b.x, dist * 0.0009);
		// Gone at the end of its slot, before the slot is reused.
		size *= 1.0 - smoothstep(period - 8.0, period - 2.0, age);
		// Its own proportions: flattened, elongated, from its seed.
		vec3 v = VERTEX * vec3(mix(0.75, 1.25, fract(b.z * 7.3)), mix(0.6, 1.05, fract(b.z * 3.1)), mix(0.8, 1.2, fract(b.z * 5.7))) * size;
		// Its tumble, around an axis of its own.
		float spin = min(age, b.y) * (b.z - 0.5) * 6.0 + b.z * 40.0;
		float c = cos(spin);
		float s = sin(spin);
		v = vec3(v.x * c - v.z * s, v.y, v.x * s + v.z * c);
		NORMAL = vec3(NORMAL.x * c - NORMAL.z * s, NORMAL.y, NORMAL.x * s + NORMAL.z * c);
		// Streak along the flight: what the eye keeps of a fast stone, far away. Up close a stone is a stone.
		float speed = length(vel);
		if (speed > 1.0) {
			vec3 dir = vel / speed;
			v += dir * dot(v, dir) * min(speed * 0.04, 5.0) * smoothstep(120.0, 1500.0, dist);
		}
		VERTEX = v + pos;
		v_heat = 1.0 - smoothstep(4.0, 40.0, age);
		v_far = smoothstep(300.0, 1500.0, dist);
	}
}

void fragment() {
	vec3 albedo;
	vec3 emission;
	vec3 normal;
	rock_shade(v_q, v_heat, NORMAL, VERTEX, albedo, emission, normal);
	// Cracks are not seen from afar: the whole stone glows instead of aliasing.
	vec3 dot_glow = mix(vec3(0.5, 0.05, 0.005), vec3(5.0, 1.7, 0.35), v_heat * v_heat) * v_heat;
	ALBEDO = albedo;
	EMISSION = mix(emission, dot_glow, v_far);
	NORMAL = mix(normal, NORMAL, v_far);
	ROUGHNESS = 0.95;
}
