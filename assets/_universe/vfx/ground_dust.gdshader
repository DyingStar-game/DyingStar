shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, diffuse_lambert_wrap;
// Look of one ground-dust particle (DustEmitter): a soft, ragged blob facing the camera, the colour of
// the ground it came from (COLOR, set at emission), thinning out as it ages.
//
// Lit, not unshaded: dust is lit by the sun like the ground it came from, so it goes dark at night
// instead of glowing. Faded where it meets the ground (proximity fade) so a puff has no hard edge
// along the terrain.
//
// The billboard keeps MODELVIEW_MATRIX's own translation and only replaces its rotation: Godot builds
// that matrix in high precision, and rebuilding it from MODEL_MATRIX (as the stock particle billboard
// does) would make the dust shake at astronomic coordinates.
//
// INSTANCE_CUSTOM: x = spin angle, y = age (s), w = lifetime (s) — see ground_dust_process.gdshader.

// Overall opacity at full density.
uniform float opacity : hint_range(0.0, 1.0, 0.01) = 0.55;
// Width (0..1 of the radius) of the blob's soft edge.
uniform float edge_softness : hint_range(0.0, 1.0, 0.01) = 0.6;
// Distance (m) over which the dust fades out as it meets the ground or a wall.
uniform float proximity_fade : hint_range(0.0, 4.0, 0.01) = 0.6;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying float age;
varying float spin;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm3(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < 3; i++) {
		v += a * noise(p);
		p = rot * p * 2.0;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	age = clamp(INSTANCE_CUSTOM.y / max(INSTANCE_CUSTOM.w, 0.001), 0.0, 1.0);
	spin = INSTANCE_CUSTOM.x;
	float size = length(MODEL_MATRIX[0].xyz);
	float c = cos(spin);
	float s = sin(spin);
	MODELVIEW_MATRIX[0] = vec4(c * size, s * size, 0.0, 0.0);
	MODELVIEW_MATRIX[1] = vec4(-s * size, c * size, 0.0, 0.0);
	MODELVIEW_MATRIX[2] = vec4(0.0, 0.0, size, 0.0);
	MODELVIEW_NORMAL_MATRIX = mat3(1.0);
}

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float blob = 1.0 - smoothstep(1.0 - edge_softness, 1.0, length(centered));
	// Ragged and drifting: the noise is offset by the spin (each puff its own pattern) and eaten away
	// as the puff ages, so it frays rather than fades as a disc.
	float n = fbm3(centered * 2.5 + vec2(spin * 3.1, age * 1.5));
	blob *= smoothstep(0.1, 0.6, n + 0.35 - age * 0.3);
	float life = smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.3, 1.0, age));
	ALBEDO = COLOR.rgb;
	ALPHA = blob * life * COLOR.a * opacity;
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	behind.xyz /= behind.w;
	ALPHA *= clamp(1.0 - smoothstep(behind.z + proximity_fade, behind.z, VERTEX.z), 0.0, 1.0);
}
