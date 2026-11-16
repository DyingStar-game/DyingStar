// The scalp under a head of hair's strands (HairGroom._shell, style "scalp"): the skin there is seen through
// the hairs, darkened by their roots and by their shade, never a painted cap. A layer half a millimetre over
// the skin, blended: as opaque as the hair is dense (COLOR.a), fading out over the whole hairline -- where an
// opaque cap appeared at a density of 0.85 and drew a hard edge 1.5 cm in from the hairline, with stippled
// specks along it.
//
// The vertex colour: R = 1 (strands lie over it), G = a random value per vertex, B = 0 (the cap), A = the
// hair's density there. Drawn before the strands (render_priority -1, CharacterMaterials), writing no depth:
// the strands blend over it.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://assets/_universe/characters/human/shaders/human_hair_bsdf.gdshaderinc"

// One dot per hair, tiling (hair_shell.png): G = a random value per hair. Read filtered: from a few pixels
// away a scalp's roots are a shade, not specks.
uniform sampler2D dot_texture : filter_linear_mipmap, repeat_enable;
// Tiles of the dot texture across the skin's UV.
uniform float tiling : hint_range(1.0, 400.0) = 12.0;
// How much of the skin the roots and the hairs' shade hide where the hair is dense, 0..1: lower = the skin
// shows between the hairs (a parting, a thin crown), higher = a full head of hair.
uniform float scalp_cover : hint_range(0.0, 1.0) = 0.85;
// How the cover follows the density, from the hairline in: 1 = in proportion, higher = the cover comes in
// later (more skin at the hairline), lower = sooner.
uniform float cover_curve : hint_range(0.3, 3.0) = 1.3;
// How much darker than the hair colour the roots are, 0..1: the light barely reaches the skin under the hair.
uniform float root_shadow : hint_range(0.0, 1.0) = 0.45;
// How much darker than the hair colour, 0..1 (as the other hair shaders).
uniform float darken : hint_range(0.0, 1.0) = 0.0;
// How much lighter or darker the roots vary from one spot to the next, 0..1.
uniform float strand_variation : hint_range(0.0, 1.0) = 0.25;
// How much the ambient light is dimmed under the hair, 0..1.
uniform float ambient_shade : hint_range(0.0, 1.0) = 0.6;
// Strength of the roots' highlights, 0..2 (1 = Karis' hair): faint, under the hair.
uniform float spec_strength : hint_range(0.0, 2.0) = 0.05;
// How rough the roots are, 0..1.
uniform float roughness : hint_range(0.1, 1.0) = 0.6;
// How far light wraps around the head, 0..1.
uniform float wrap : hint_range(0.0, 1.0) = 0.1;

// ── Per avatar ──────────────────────────────────────────────────────────────────────────────────────
// Linear hair colour (CharacterAppearance.hair_colour). Index 9, the characters' 8..11.
instance uniform vec4 hair_colour : instance_index(9) = vec4(0.1, 0.07, 0.05, 1.0);

varying vec3 hair_direction;

void fragment() {
	float density = COLOR.a;
	float grain = texture(dot_texture, UV * tiling).g;
	ALPHA = scalp_cover * pow(clamp(density, 0.0, 1.0), cover_curve);
	vec3 base = mix(max(hair_colour.rgb, vec3(0.022, 0.019, 0.017)), vec3(0.012, 0.01, 0.009), darken);
	base *= 1.0 + (grain - 0.5) * 2.0 * strand_variation;
	ALBEDO = base * (1.0 - root_shadow);
	AO = 1.0 - ambient_shade;
	hair_direction = normalize(TANGENT + NORMAL * 0.3);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	vec3 lit = LIGHT_COLOR * ATTENUATION / PI;
	DIFFUSE_LIGHT += lit * hair_scatter(hair_direction, NORMAL, LIGHT, wrap);
	SPECULAR_LIGHT += lit * hair_highlights(hair_direction, VIEW, LIGHT, ALBEDO, roughness, radians(3.0),
			spec_strength, 1.0);
}
