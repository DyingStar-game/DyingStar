// Human skin, close up, on the Vitruvian body.
//
// One set of maps per body zone (face, torso, arms, legs), shared by every avatar; what differs from one
// person to the next is a few numbers (skin_look, and the details of human_skin_detail.gdshaderinc). Colour: a light and a dark painted skin mixed by the
// person's tone. Relief: the sculpt's normal map, old-age wrinkles faded in with age, and a tiling micro
// relief of pores. Roughness from its map.
//
// The lighting is MatMADNESS's Human Shaders skin (MIT, see HUMAN_SHADERS_LICENSE.md;
// https://github.com/matmadness/HumanShaders), adapted: light scatters under skin, further in red than in
// green and blue, so each channel is lit by its own, more or less blurred, normal (the normal map read at
// coarser mips) and wrapped past the terminator -- soft, reddish shadow edges without a screen-space pass
// doing all the work -- and the highlight is two lobes, a sharp one over a broad one, as oily skin shows.
// Godot's own subsurface pass (skin mode) and transmittance through thin parts stay on top.
//
// Costs three more normal-map reads per light and pixel: human_skin_far.gdshader takes over at a distance.
// Opaque and depth-writing: an avatar must hide what is behind it from depth-reading effects (mine dust).
shader_type spatial;
render_mode sss_mode_skin, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Base colour of light skin (this zone's UV layout).
uniform sampler2D albedo_light : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// Base colour of dark skin, same layout.
uniform sampler2D albedo_dark : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// Relief of the skin (tangent-space normal map).
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
// Old-age wrinkles (tangent-space normal map), added with the person's age.
uniform sampler2D age_normal_texture : hint_normal, filter_linear_mipmap, repeat_disable;
// Roughness map, 0..1.
uniform sampler2D roughness_texture : hint_roughness_r, filter_linear_mipmap, repeat_disable;
// Tiling micro relief of the pores: normal in red / green, occlusion in blue (Human Shaders, MIT).
uniform sampler2D micro_detail_texture : filter_linear_mipmap_anisotropic, repeat_enable;
// How many times the micro relief repeats over the zone's UV square.
uniform float micro_scale = 60.0;
// Micro relief strength, 0..1.
uniform float micro_normal_strength : hint_range(0.0, 1.0) = 0.35;
// Darkening in the pores, 0..1.
uniform float micro_ao_strength : hint_range(0.0, 1.0) = 0.3;
// Relief strength: 1 = as baked, lower = smoother skin.
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
// Roughness multiplier over the map: lower = oilier, shinier skin.
uniform float roughness_scale : hint_range(0.0, 2.0) = 1.0;
// Roughness added to the map: the sculpt's map alone reads as wet skin under a hard sun.
uniform float roughness_floor : hint_range(0.0, 1.0) = 0.22;
// Specular level, 0..1 (0.5 = 4 % reflectance; skin is about 0.35).
uniform float specular_level : hint_range(0.0, 1.0) = 0.4;
// How blurred the normal that lights the red channel is (mip levels): higher = softer, waxier skin.
uniform float skin_smoothness : hint_range(0.0, 10.0) = 4.0;
// Width of the light's fall-off past the terminator: higher = softer shadow edges.
uniform float falloff_softness : hint_range(0.7, 2.0) = 1.0;
// Subsurface scattering strength of the engine's skin pass, 0..1.
uniform float sss_strength : hint_range(0.0, 1.0) = 0.3;
// Colour of light that passes through thin parts (ears, fingers) when backlit.
uniform vec4 transmittance_color : source_color = vec4(0.85, 0.3, 0.22, 1.0);
// Thickness (m) under which back light still passes through.
uniform float transmittance_depth = 0.08;
// Extra back light passed through thin parts, 0..1.
uniform float transmittance_boost : hint_range(0.0, 1.0) = 0.15;

// ── Per avatar (HumanAppearance) ────────────────────────────────────────────────────────────────────
// x = skin tone (0 lightest .. 1 darkest), y = warmth (0.5 neutral), z = age wrinkles (0 none .. 1 full).
// instance_index is explicit (Godot allows 0..15): the instance uniform buffer is shared by every
// material of an instance, and indexless uniforms collide (see terrain_blend.gdshader, which holds
// 11..15). The characters own 8..10.
instance uniform vec3 skin_look : instance_index(8) = vec3(0.2, 0.5, 0.0);

#include "human_skin_detail.gdshaderinc"

// The dark skin comes in early along the tone: a middle tone is a brown skin, not a tanned light one.
const float TONE_CURVE = 0.6;

varying mat3 tangent_frame;
varying vec3 lit_albedo;
varying vec2 micro_slope;
varying float melanin;

// A tangent-space slope (xy of a normal map, -1..1) as a view-space normal.
vec3 to_view(vec2 slope) {
	return normalize(tangent_frame * vec3(slope, 1.0));
}

void fragment() {
	tangent_frame = mat3(TANGENT, BINORMAL, NORMAL);
	melanin = skin_look.x;
	vec3 albedo = mix(texture(albedo_light, UV).rgb, texture(albedo_dark, UV).rgb, pow(melanin, TONE_CURVE));
	float warmth = skin_look.y - 0.5;
	albedo *= vec3(1.0 + warmth * 0.1, 1.0 + warmth * 0.02, 1.0 - warmth * 0.3);
	albedo = skin_details_colour(albedo, UV, melanin, true);
	vec4 micro = texture(micro_detail_texture, UV * micro_scale);
	albedo *= mix(1.0, micro.b * 1.25, micro_ao_strength);
	albedo *= skin_details_occlusion(UV);
	ALBEDO = albedo;
	lit_albedo = albedo;
	// The reliefs, summed in tangent space (their slopes add).
	vec3 base = texture(normal_texture, UV).rgb * 2.0 - 1.0;
	vec3 aged = texture(age_normal_texture, UV).rgb * 2.0 - 1.0;
	micro_slope = (micro.rg * 2.0 - 1.0) * micro_normal_strength;
	vec3 n = normalize(vec3(base.xy + aged.xy * skin_look.z + skin_details_slope(UV) + micro_slope, base.z));
	NORMAL_MAP = n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = clamp(texture(roughness_texture, UV).r * roughness_scale + roughness_floor, 0.05, 1.0);
	SPECULAR = specular_level;
	// Dark skin scatters less visibly: melanin absorbs before the light spreads.
	SSS_STRENGTH = sss_strength * mix(1.0, 0.55, melanin);
	SSS_TRANSMITTANCE_COLOR = transmittance_color;
	SSS_TRANSMITTANCE_DEPTH = transmittance_depth;
	SSS_TRANSMITTANCE_BOOST = transmittance_boost;
}

float distribution_ggx(float n_dot_h, float alpha) {
	float a2 = alpha * alpha;
	float d = 1.0 + (a2 - 1.0) * n_dot_h * n_dot_h;
	return a2 / (PI * d * d);
}

float geometry_ggx(float n_dot_l, float n_dot_v, float alpha) {
	return 0.5 / max(mix(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, alpha), 1e-4);
}

void light() {
	vec3 light_colour = LIGHT_COLOR / PI;
	// Diffuse: one normal per channel, red the most blurred (it scatters the furthest), each wrapped
	// past the terminator. The pores stay on green and blue.
	vec2 slope_r = textureLod(normal_texture, UV, skin_smoothness).rg * 2.0 - 1.0;
	vec2 slope_g = textureLod(normal_texture, UV, skin_smoothness * 0.8).rg * 2.0 - 1.0 + micro_slope;
	vec2 slope_b = textureLod(normal_texture, UV, skin_smoothness * 0.7).rg * 2.0 - 1.0 + micro_slope;
	float wrap = 0.5;
	float sf = falloff_softness;
	// Melanin absorbs the scattered light: a dark skin's channels fall off together.
	float spread = mix(1.0, 0.35, melanin);
	vec3 wrapped = vec3(
		smoothstep(mix(0.44, 0.4, spread) / sf, 1.2 * sf, dot(to_view(slope_r * normal_strength), LIGHT) * wrap + (1.0 - wrap)),
		smoothstep(mix(0.44, 0.425, spread) / sf, 1.2 * sf, dot(to_view(slope_g * normal_strength), LIGHT) * wrap + (1.0 - wrap)),
		smoothstep(0.44 / sf, 1.2 * sf, dot(to_view(slope_b * normal_strength), LIGHT) * wrap + (1.0 - wrap)));
	DIFFUSE_LIGHT += wrapped * ATTENUATION * light_colour;

	// Specular: two GGX lobes, a sharp one over a broad one.
	vec3 half_vector = normalize(VIEW + LIGHT);
	float n_dot_l = max(dot(NORMAL, LIGHT), 0.0);
	float n_dot_v = max(dot(NORMAL, VIEW), 0.0);
	float n_dot_h = max(dot(NORMAL, half_vector), 0.0);
	float l_dot_h = max(dot(LIGHT, half_vector), 0.0);
	float f0 = 0.04 * specular_level * specular_level * 4.0;
	float m = 1.0 - l_dot_h;
	float fresnel = f0 + (clamp(50.0 * f0, 0.0, 1.0) - f0) * m * m * m * m * m;
	float alpha = ROUGHNESS * ROUGHNESS;
	float sharp = distribution_ggx(n_dot_h, alpha) * geometry_ggx(n_dot_l, n_dot_v, alpha);
	float broad = distribution_ggx(n_dot_h, alpha + 0.3) * geometry_ggx(n_dot_l, n_dot_v, alpha + 0.3);
	SPECULAR_LIGHT += max(n_dot_l * mix(broad, sharp, 0.6) * 2.0 * fresnel, 0.0) * LIGHT_COLOR * ATTENUATION;
}
