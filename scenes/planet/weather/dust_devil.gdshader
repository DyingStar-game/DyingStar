shader_type spatial;
// One shell of a dust devil (WeatherPhenomena): a unit column, one radius wide and one height tall after
// the node's scale. A devil is a few shells one inside the other, each turning at its own speed: ragged,
// flaring upward, bending as it climbs, with a skirt of dust thrown out at its foot. Lit by hand (light,
// sun_local): a veil of dust has no surface for the sun to shade.
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, unshaded;

uniform sampler2D noise : repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
// How much wider than its foot the column is at its top, how far it bends (radii), how far the skirt is
// thrown at the foot (radii), and the distance to the ground the dust fades over (m).
uniform float flare = 1.8;
uniform float sway = 0.5;
uniform float skirt = 2.2;
uniform float soft_m = 12.0;
instance uniform vec3 tint = vec3(0.80, 0.66, 0.47);
instance uniform float strength = 1.0;
instance uniform float light = 1.0;
// Where the sun is, in the devil's own frame.
instance uniform vec3 sun_local = vec3(0.0, 1.0, 0.0);
instance uniform float spin = 1.0;
// Height over radius: keeps the dust's grain the same size on a squat devil and on a tall one.
instance uniform float slender = 10.0;
// Which shell, 0 (the outer one) to 1 (the core).
instance uniform float shell = 0.0;
// How much of the open air the eye is in, 1 outside to 0 under the ground (a cave, a mine): the weather
// does not come in (WeatherPhenomena).
instance uniform float open_air = 1.0;

varying float rise;
varying float sunlit;

void vertex() {
	rise = VERTEX.y + 0.5;
	vec2 ring = normalize(VERTEX.xz);
	float turn = atan(ring.y, ring.x) / TAU;
	float rag = textureLod(noise, vec2(turn * 2.0 + spin * TIME * 0.05 * (1.0 + shell), rise * slender * 0.05 - TIME * 0.03 + shell * 0.4), 0.0).r;
	float wide = mix(0.5, flare, pow(rise, 1.5)) * mix(1.0, 0.4, shell) * (0.7 + 0.6 * rag);
	wide += skirt * exp(-rise * 30.0) * (1.0 - shell);
	VERTEX.xz = ring * wide + vec2(sin(TIME * 0.6 + rise * 4.0) + 0.5 * sin(TIME * 0.23 + rise * 9.0),
			cos(TIME * 0.45 + rise * 3.3) + 0.5 * cos(TIME * 0.31 + rise * 7.0)) * sway * rise;
	VERTEX.y = rise;
	sunlit = dot(vec3(ring.x, 0.0, ring.y), normalize(sun_local)) * 0.5 + 0.5;
}

void fragment() {
	vec2 uv = vec2(UV.x * 3.0 + spin * (TIME * (0.3 + 0.25 * shell) + rise * 2.0), rise * slender * 0.1 - TIME * 0.2 + shell * 0.37);
	float grain = texture(noise, uv).r * 0.6 + texture(noise, uv * 2.7 + 0.3).r * 0.4;
	// Dense seen through its middle, thin at its edges; rooted at the ground, frayed at the top, thinner as
	// it climbs.
	float body = pow(abs(dot(normalize(NORMAL), normalize(VIEW))), 1.2);
	float column = smoothstep(0.0, 0.01, rise) * (1.0 - smoothstep(0.45 + 0.4 * grain, 1.0, rise)) * mix(1.0, 0.5, rise);
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float ground = clamp((-scene.z / scene.w + VERTEX.z) / soft_m, 0.0, 1.0);
	ALBEDO = tint * light * mix(0.55, 1.05, sunlit) * mix(0.8, 1.1, grain);
	ALPHA = clamp(smoothstep(0.25, 0.65, grain + 0.15 + 0.2 * (1.0 - rise)) * body * column * ground * strength
			* mix(0.55, 0.9, shell) * open_air, 0.0, 1.0);
}
