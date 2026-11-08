shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

uniform float smoke_clock = 0.0;
varying float puff_age;
varying float seed;
varying float strength;

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	vec4 h = fract(sin(vec4(dot(i, vec2(127.1, 311.7)), dot(i + vec2(1, 0), vec2(127.1, 311.7)),
		dot(i + vec2(0, 1), vec2(127.1, 311.7)), dot(i + vec2(1, 1), vec2(127.1, 311.7)))) * 43758.5453);
	return mix(mix(h.x, h.y, u.x), mix(h.z, h.w, u.x), u.y);
}

void vertex() {
	puff_age = mod(smoke_clock - INSTANCE_CUSTOM.r + 32.0, 32.0);
	seed = INSTANCE_CUSTOM.g;
	strength = INSTANCE_CUSTOM.b;
	float alive = 1.0 - step(6.0, puff_age);
	float scale = (0.45 + puff_age * 0.25) * alive;
	vec3 drift_local = vec3(puff_age * 0.22 + sin(puff_age + seed * 6.28) * 0.22,
		puff_age * (0.55 + seed * 0.18), puff_age * 0.12);
	vec3 origin_view = MODELVIEW_MATRIX[3].xyz + (MODELVIEW_MATRIX * vec4(drift_local, 0.0)).xyz;
	MODELVIEW_MATRIX = mat4(vec4(1, 0, 0, 0), vec4(0, 1, 0, 0), vec4(0, 0, 1, 0), vec4(origin_view, 1.0));
	VERTEX.xy *= scale;
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float body = 1.0 - smoothstep(0.25, 1.0, length(p));
	float noise = noise2(UV * 4.0 + vec2(seed * 19.0, -puff_age * 0.13));
	float fade = smoothstep(0.0, 0.8, puff_age) * (1.0 - smoothstep(3.0, 6.0, puff_age));
	ALBEDO = mix(vec3(0.28, 0.29, 0.31), vec3(0.53, 0.51, 0.48), noise);
	ALPHA = body * (0.35 + noise * 0.65) * fade * strength * 0.23;
}
