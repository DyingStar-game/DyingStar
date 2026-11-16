// Hair seen end-on: the skin's own triangles lifted in layers (tools/character/hair_groom, "shell"), each
// keeping the hairs taller than itself. A buzz cut, the stubble of a shaved side, the scalp between the
// ribbons of a longer style, and the mass of an eyebrow under its hairs.
//
// The vertex colour: R = 1 where strands lie over the shell (a longer head of hair over shaved sides: the
// hairline is theirs, the shell keeps inside it), G = a random value per vertex, B = the layer's height (0 at the skin .. 1 the hairs'
// tips; 0 is the cap), A = the hair's density there (the hairline is stippled out). Opaque, cut by discard: it sorts and
// shadows like the skin it covers. Lit as hair (human_hair_bsdf.gdshaderinc), along hairs that rise from the
// skin and lean along the shell's tangent.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://assets/_universe/characters/human/shaders/human_hair_bsdf.gdshaderinc"

// One dot per hair, tiling: R = the hair's height under the texel, G = a random value per hair, B = the
// hair's full height (hair_shell.png).
uniform sampler2D dot_texture : filter_linear_mipmap, repeat_enable;
// Tiles of the dot texture across the skin's UV: higher = finer, denser hair.
uniform float tiling : hint_range(1.0, 400.0) = 4.0;
// How much darker than the hair colour, 0..1 (eyebrows are a little darker than the head).
uniform float darken : hint_range(0.0, 1.0) = 0.0;
// How dark the hair is at the skin, 0..1: light does not reach between the hairs.
uniform float root_shadow : hint_range(0.0, 1.0) = 0.45;
// How much lighter or darker one hair may be than its neighbour, 0..1.
uniform float strand_variation : hint_range(0.0, 1.0) = 0.25;
// Strength of the highlights (R, TT and TRT together), 0..2: 1 = Karis' hair. Short hairs packed end-on
// shine less than a combed head of hair: 0.12 keeps a buzz cut's brightness of the former lighting.
uniform float spec_strength : hint_range(0.0, 2.0) = 0.12;
// How rough the hairs' surface is, 0..1: lower = thinner, brighter highlights. Short hairs seen end-on
// show broad, soft ones.
uniform float roughness : hint_range(0.1, 1.0) = 0.55;
// Tilt of a hair's scales (deg): shifts the highlights along the hair.
uniform float cuticle_tilt : hint_range(0.0, 10.0) = 3.0;
// How far light wraps around the hair's volume, 0..1: 0 = a hard terminator, higher = softer.
uniform float wrap : hint_range(0.0, 1.0) = 0.1;
// How much the short hairs rise from the skin against how much they lie along it (the shell's tangent):
// 0 = flat along the skin, higher = standing up.
uniform float stand : hint_range(0.0, 3.0) = 0.6;
// 1 = this is a beard: its length is the avatar's beard length (hair_look.y), not its hair's.
uniform float is_beard : hint_range(0.0, 1.0) = 0.0;
// How far the hairs lean, in tiles per unit of height: 0 = standing straight.
uniform vec2 lean = vec2(0.0, 0.25);
// Share of the dots the cap keeps where the hair is dense, 0..1: 1 = whole, no skin between them (a buzz cut);
// lower = skin between the dots, over the shade under them (a stubble: whole, its cap was a black block).
uniform float cap_share : hint_range(0.0, 1.0) = 1.0;

// ── Per avatar ──────────────────────────────────────────────────────────────────────────────────────
// Linear hair colour (CharacterAppearance.hair_colour). Index 9, the characters' 8..11.
instance uniform vec4 hair_colour : instance_index(9) = vec4(0.1, 0.07, 0.05, 1.0);
// How much of the length is kept, 0..1 (1 = uncut): x = the hair's, y = the beard's.
instance uniform vec4 hair_look : instance_index(11) = vec4(1.0, 1.0, 0.0, 0.0);

// The hairs' direction, in view space, for light().
varying vec3 hair_direction;

void fragment() {
	float layer = COLOR.b;
	float density = COLOR.a;
	vec4 hair = texture(dot_texture, UV * tiling + lean * layer);
	// Where the hair thins out, fewer hairs are kept (the tallest last) and the cap under them is stippled.
	// Under strands the shell keeps well inside the hairline: at its edge, skin shows between the strands' roots
	// as on a real head, where a stippled, shadowed cap drew a dark ragged band.
	float sparse = mix(smoothstep(0.0, 0.75, density), smoothstep(0.85, 1.0, density), COLOR.r);
	float height = hair.r * mix(0.45, 1.0, mix(hair_look.x, hair_look.y, is_beard)) * step(1.0 - sparse, hair.b * 0.999 + 0.001);
	// The lowest layer is the cap: whole where the hair is dense, so that no skin shows between the dots.
	// The finer dots (tiling 12: a beard's, a head of hair's) are read unfiltered there: the mipmaps' average would
	// fill the gaps between them (a painted mask), the dots themselves, under a pixel, read as a shadow with skin
	// between -- at a hairline, a fine stipple instead of the 1.5 mm dark spots a coarse tiling drew.
	float cap_g = textureLod(dot_texture, UV * tiling, 0.0).g;
	// (Under a beard's hairs there is no shell: BeardGroom draws the skin seen through them, style "scalp".)
	float cap = step(layer, 0.01) * step(1.0 - sparse * sparse * cap_share, cap_g + 0.001);
	if (cap < 0.5 && (layer < 0.01 || height < layer)) {
		discard;
	}
	vec3 base = mix(max(hair_colour.rgb, vec3(0.022, 0.019, 0.017)), vec3(0.012, 0.01, 0.009), darken);
	base *= 1.0 + (hair.g - 0.5) * 2.0 * strand_variation;
	// Light reaches the skin between sparse hairs: the root shadow comes in with the density.
	ALBEDO = base * mix(1.0 - root_shadow * sparse, 1.0, layer);
	hair_direction = normalize(TANGENT + NORMAL * stand);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	vec3 lit = LIGHT_COLOR * ATTENUATION;
	DIFFUSE_LIGHT += lit * hair_scatter(hair_direction, NORMAL, LIGHT, wrap) / PI;
	SPECULAR_LIGHT += lit / PI * hair_highlights(hair_direction, VIEW, LIGHT, ALBEDO, roughness,
			radians(cuticle_tilt), spec_strength, 1.0);
}
