// Human skin seen from afar (CharacterMaterials picks it past NEAR_DISTANCE): the engine's own lighting,
// no micro relief. human_skin.gdshader is the close-up one; both read the same maps and the same
// per-avatar values, so swapping them does not change a person's look.
//
// One set of maps per body zone (face, torso, arms, legs), shared by every avatar; what differs from one
// person to the next is three numbers.
//
//   - colour: two painted skins, a light and a dark one, mixed by the person's skin tone, then warmed or
//     cooled a little;
//   - relief: a normal map baked from the sculpt's height (pores, lips, knuckles), and a second one of
//     old-age wrinkles faded in with the person's age;
//   - roughness from its own map (oilier forehead and nose, matte cheeks);
//   - subsurface scattering in Godot's skin mode and transmittance through thin parts (ears, fingers).
//
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
// Relief strength: 1 = as baked, lower = smoother skin.
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
// Roughness multiplier over the map: lower = oilier, shinier skin.
uniform float roughness_scale : hint_range(0.0, 2.0) = 1.0;
// Roughness added to the map: the sculpt's map alone reads as wet skin under a hard sun.
uniform float roughness_floor : hint_range(0.0, 1.0) = 0.22;
// Specular level, 0..1 (0.5 = 4 % reflectance; skin is about 0.35).
uniform float specular_level : hint_range(0.0, 1.0) = 0.35;
// Subsurface scattering strength, 0..1: higher = softer, more translucent skin.
uniform float sss_strength : hint_range(0.0, 1.0) = 0.4;
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

void fragment() {
	vec3 light = texture(albedo_light, UV).rgb;
	vec3 dark = texture(albedo_dark, UV).rgb;
	vec3 albedo = mix(light, dark, pow(skin_look.x, TONE_CURVE));
	float warmth = skin_look.y - 0.5;
	ALBEDO = skin_details_colour(albedo * vec3(1.0 + warmth * 0.1, 1.0 + warmth * 0.02, 1.0 - warmth * 0.3), UV, skin_look.x, false);
	// The two reliefs, summed in tangent space (their slopes add).
	vec3 base = texture(normal_texture, UV).rgb * 2.0 - 1.0;
	vec3 aged = texture(age_normal_texture, UV).rgb * 2.0 - 1.0;
	vec3 n = normalize(vec3(base.xy + aged.xy * skin_look.z, base.z));
	NORMAL_MAP = n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = clamp(texture(roughness_texture, UV).r * roughness_scale + roughness_floor, 0.05, 1.0);
	SPECULAR = specular_level;
	// Dark skin scatters less visibly: melanin absorbs before the light spreads.
	SSS_STRENGTH = sss_strength * mix(1.0, 0.55, skin_look.x);
	SSS_TRANSMITTANCE_COLOR = transmittance_color;
	SSS_TRANSMITTANCE_DEPTH = transmittance_depth;
	SSS_TRANSMITTANCE_BOOST = transmittance_boost;
}
