shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled;
// Look of one ground-dust particle (DustEmitter): a soft, ragged blob facing the camera, the colour of
// the ground it came from (COLOR, set at emission), thinning out as it ages.
//
// Lit, not unshaded: dust is lit by the sun like the ground it came from, so it goes dark at night
// instead of glowing. And lit the way DUST is: a cloud of fine grains scatters light FORWARD
// (Henyey-Greenstein, g ≈ 0.65), so a puff between you and the sun glows at its edges while the same
// puff with the sun behind you is a flat, dull wash — the single most recognisable trait of real dust
// in the air, and what the eye reads as "dust" rather than "smoke". Faded where it meets the ground
// (proximity fade) so a puff has no hard edge along the terrain.
//
// The billboard keeps MODELVIEW_MATRIX's own translation and only replaces its rotation: Godot builds
// that matrix in high precision, and rebuilding it from MODEL_MATRIX (as the stock particle billboard
// does) would make the dust shake at astronomic coordinates. A grain that flies (the process shader
// stretched its X along the velocity: ground_dust_process.gdshader, stretch_per_ms) is laid along its
// motion on screen instead of spun: a streak of sand, not a spinning disc.
//
// INSTANCE_CUSTOM: x = spin angle, y = age (s), w = lifetime (s) — see ground_dust_process.gdshader.

// Overall opacity at full density.
uniform float opacity : hint_range(0.0, 1.0, 0.01) = 0.55;
// Width (0..1 of the radius) of the blob's soft edge.
uniform float edge_softness : hint_range(0.0, 1.0, 0.01) = 0.6;
// Distance (m) over which the dust fades out as it meets the ground or a wall.
uniform float proximity_fade : hint_range(0.0, 4.0, 0.01) = 0.6;
// Forward scattering: how much a puff lit from behind brightens over one lit from the side (0 = the
// plain wrapped lambert of before), and the asymmetry g of the phase function (0 = even, 1 = all
// forward; fine mineral dust sits around 0.6–0.7).
uniform float forward_glow : hint_range(0.0, 2.0, 0.01) = 0.6;
uniform float scatter_g : hint_range(0.0, 0.95, 0.01) = 0.65;
// How much the noise is warped into wisps (0 = the plain fractal of before).
uniform float wisp : hint_range(0.0, 1.0, 0.01) = 0.45;
// How ragged the outline is (0 = a round blob): the noise pushes the edge in and out by this much
// of the radius, so a puff never reads as a disc.
uniform float edge_ragged : hint_range(0.0, 1.5, 0.01) = 0.8;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying float age;
varying float spin;
varying float stretch;

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
	// The instance's axes in view space: Y and Z carry the plain size, X is longer when the grain flies.
	vec3 along = MODELVIEW_MATRIX[0].xyz;
	float size = length(MODELVIEW_MATRIX[1].xyz);
	float along_len = length(along);
	stretch = along_len / max(size, 1e-6);
	vec2 d2 = along.xy;
	float l2 = length(d2);
	if (stretch > 1.05 && l2 > 0.25 * along_len) {
		// Laid along the motion as seen on screen: X along it, as long as the stretch says, Y across.
		d2 /= l2;
		MODELVIEW_MATRIX[0] = vec4(d2 * along_len, 0.0, 0.0);
		MODELVIEW_MATRIX[1] = vec4(-d2.y * size, d2.x * size, 0.0, 0.0);
	} else {
		float c = cos(spin);
		float s = sin(spin);
		MODELVIEW_MATRIX[0] = vec4(c * size, s * size, 0.0, 0.0);
		MODELVIEW_MATRIX[1] = vec4(-s * size, c * size, 0.0, 0.0);
		stretch = 1.0;
	}
	MODELVIEW_MATRIX[2] = vec4(0.0, 0.0, size, 0.0);
	MODELVIEW_NORMAL_MATRIX = mat3(1.0);
}

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	// A gaussian core, not a disc: dense in the middle, thinning out with no rim, and an outline the
	// noise pushes in and out so no two puffs share a shape. The quad's own edge stays clean.
	float outline = noise(centered * 1.6 + vec2(spin * 2.3, 0.7)) - 0.5;
	float r = length(centered) * (1.0 + edge_ragged * outline);
	float blob = exp(-r * r * (2.0 + 2.0 * edge_softness)) * (1.0 - smoothstep(0.8, 1.0, length(centered)));
	// Ragged and drifting: the noise is offset by the spin (each puff its own pattern), warped into
	// wisps by a coarser noise, and eaten away as the puff ages, so it frays rather than fades as a disc.
	// A streak reads the noise along its length, so the grain is streaked, not blotched.
	vec2 p = vec2(centered.x * max(stretch, 1.0), centered.y) * 2.5 + vec2(spin * 3.1, age * 1.5);
	p += wisp * 1.2 * vec2(noise(p * 0.7 + 11.3) - 0.5, noise(p * 0.7 - 4.9) - 0.5);
	float n = fbm3(p);
	blob *= smoothstep(0.1, 0.6, n + 0.35 - age * 0.3);
	float life = smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.3, 1.0, age));
	ALBEDO = COLOR.rgb;
	ALPHA = blob * life * COLOR.a * opacity;
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	behind.xyz /= behind.w;
	ALPHA *= clamp(1.0 - smoothstep(behind.z + proximity_fade, behind.z, VERTEX.z), 0.0, 1.0);
}

void light() {
	// The wrapped lambert of a billboard (its normal faces the camera), plus the forward scattering:
	// the light that went through the puff and comes out toward the eye. cos θ between the light's
	// travel (-LIGHT) and the way to the eye (VIEW): 1 when the sun is right behind the puff.
	float wrap = clamp(dot(NORMAL, LIGHT) * 0.5 + 0.5, 0.0, 1.0);
	float cos_theta = dot(-LIGHT, VIEW);
	float g = scatter_g;
	float hg = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cos_theta, 1.5);
	float hg_side = (1.0 - g * g) / pow(1.0 + g * g, 1.5);  // the phase seen from the side: the reference
	float glow = forward_glow * max(hg / hg_side - 1.0, 0.0);
	DIFFUSE_LIGHT += (wrap + glow) * ATTENUATION * LIGHT_COLOR;
}
