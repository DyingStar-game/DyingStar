shader_type spatial;

varying vec2 local_m;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), u.x),
		mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), u.x), u.y);
}

void vertex() {
	local_m = VERTEX.xz;
}

void fragment() {
	float coarse = noise2(local_m * 0.15);
	float grain = noise2(local_m * 3.0) * 0.6 + noise2(local_m * 9.0) * 0.4;
	ALBEDO = mix(vec3(0.048, 0.053, 0.061), vec3(0.12, 0.105, 0.09), coarse) * (0.6 + grain * 0.7);
	ROUGHNESS = 0.96;
	NORMAL_MAP = normalize(vec3(-dFdx(grain) * 1.2, -dFdy(grain) * 1.2, 1.0)) * 0.5 + 0.5;
}
