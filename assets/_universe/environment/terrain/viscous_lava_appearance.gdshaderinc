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

float grain(vec2 p) {
	return noise2(p) * 0.58 + noise2(p * 2.1) * 0.28 + noise2(p * 4.3) * 0.14;
}


void lava_appearance(vec2 metres, vec2 phase, float heat, float crust, out vec3 albedo, out vec3 emission, out float roughness, out vec3 normal_map) {
	vec2 p = metres - phase * 0.18;
	float plates = grain(p * 0.78);
	float folds = sin(p.y * 8.0 + noise2(p * 1.4) * 7.0) * 0.5 + 0.5;
	float threshold = mix(0.72, 0.24, crust);
	float rock = smoothstep(threshold - 0.04, threshold + 0.04, plates);
	rock = mix(rock, 1.0, 1.0 - smoothstep(0.0, 0.13, heat));
	float fleck = grain(metres * 7.0);
	vec3 basalt = vec3(0.035, 0.032, 0.031) * (0.6 + fleck * 1.2 + folds * 0.2);
	vec3 melt = mix(vec3(0.48, 0.008, 0.001), vec3(1.0, 0.12, 0.002), heat);
	melt = mix(melt, vec3(1.0, 0.48, 0.025), smoothstep(0.80, 1.0, heat) * fleck * 0.35);
	albedo = mix(melt * 0.22, basalt, rock);
	roughness = mix(0.42, 0.94, rock);
	emission = melt * (1.0 - rock) * heat * 1.5;
	if (thermal_view) {
		albedo = mix(vec3(0.01, 0.05, 0.2), vec3(1.0, 0.08, 0.01), heat);
		emission = albedo * 0.65;
	}
	normal_map = normalize(vec3(dFdx(plates + folds * 0.08) * -2.0,
		dFdy(plates + folds * 0.08) * -2.0, 1.0)) * 0.5 + 0.5;
}
