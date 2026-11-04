// The look of a volcanic bomb, shared by the flying instances and the landed rocks: a dark grainy crust
// broken by a few irregular cracks that glow while the rock is hot. Everything reads object-space
// coordinates, so the cracks stay on the rock as it tumbles. crack_tex holds F2 - F1 of a cellular
// noise: 0 on the cell borders, which the warp keeps from reading as a regular net.

uniform sampler3D crack_tex : repeat_enable, filter_linear;
uniform vec3 crust_dark = vec3(0.05, 0.046, 0.044);
uniform vec3 crust_light = vec3(0.21, 0.19, 0.175);
uniform vec3 crust_ash = vec3(0.34, 0.32, 0.30);

void rock_shade(vec3 q, float heat, vec3 view_normal, vec3 view_pos, out vec3 albedo, out vec3 emission, out vec3 normal) {
	float mottle = textureLod(crack_tex, q * 0.11 + 0.71, 0.0).r;
	float wander = textureLod(crack_tex, q * 0.23 + 0.37, 0.0).r;
	vec3 warped = q + vec3(mottle, wander, mottle - wander) * 2.4;
	float big = textureLod(crack_tex, warped * 0.2, 0.0).r;
	float fine = textureLod(crack_tex, q * 0.83 + 0.31, 0.0).r;
	float grain = textureLod(crack_tex, q * 2.9 + 0.13, 0.0).r;
	// Hot rock opens wide cracks; as it cools they close into thin dark lines.
	float crack = 1.0 - smoothstep(0.0, mix(0.012, 0.055, heat), big);
	float glow = crack * smoothstep(0.03, 0.5, heat);
	albedo = mix(crust_dark, crust_light, smoothstep(0.05, 0.5, fine * 0.55 + grain * 0.45));
	// Ash settled on the rock once it has cooled.
	albedo = mix(albedo, crust_ash, smoothstep(0.75, 0.15, heat) * smoothstep(0.2, 0.5, mottle) * 0.4);
	albedo = mix(albedo, crust_dark * 0.6, crack * mix(0.5, 1.0, heat));
	vec3 hot = mix(vec3(1.6, 0.16, 0.012), vec3(6.5, 2.3, 0.45), heat * heat);
	emission = hot * glow;
	// Crust still warm between the cracks: a dull red that dies first.
	emission += vec3(0.5, 0.05, 0.004) * smoothstep(0.55, 1.0, heat) * (1.0 - crack) * smoothstep(0.3, 0.05, fine);
	// Bump from the screen derivatives of the height: no tangents needed on a generated mesh.
	float h = fine * 0.55 + grain * 0.2 + smoothstep(0.0, 0.08, big) * 0.25;
	vec3 dpdx = dFdx(view_pos);
	vec3 dpdy = dFdy(view_pos);
	float dhdx = dFdx(h);
	float dhdy = dFdy(h);
	vec3 r1 = cross(dpdy, view_normal);
	vec3 r2 = cross(view_normal, dpdx);
	float det = dot(dpdx, r1);
	float scale = 0.9 * sqrt(max(length(dpdx) * length(dpdy), 1e-8));
	normal = normalize(view_normal * abs(det) - sign(det) * (dhdx * r1 + dhdy * r2) * scale * 10.0 + view_normal * 1e-6);
}
