// Hair seen end-on: the skin's own triangles lifted in layers (tools/character/hair_groom, "shell"), each
// keeping the hairs taller than itself. A buzz cut, the stubble of a shaved side, the scalp between the
// ribbons of a longer style, and the mass of an eyebrow under its hairs.
//
// The vertex colour: R = 1 where strands lie over the shell (a longer head of hair: the hairline is theirs, the
// shell keeps inside it; a beard with hairs: its cap is thinner), G = a random value per vertex, B = the layer's height (0 at the skin .. 1 the hairs'
// tips; 0 is the cap), A = the hair's density there (the hairline is stippled out). Opaque, cut by discard: it sorts and
// shadows like the skin it covers.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

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
// Hair roughness, 0..1.
uniform float roughness_base : hint_range(0.0, 1.0) = 0.62;
// 1 = this is a beard: its length is the avatar's beard length (hair_look.y), not its hair's.
uniform float is_beard : hint_range(0.0, 1.0) = 0.0;
// How far the hairs lean, in tiles per unit of height: 0 = standing straight.
uniform vec2 lean = vec2(0.0, 0.25);

// ── Per avatar ──────────────────────────────────────────────────────────────────────────────────────
// Linear hair colour (CharacterAppearance.hair_colour). Index 9, the characters' 8..11.
instance uniform vec4 hair_colour : instance_index(9) = vec4(0.1, 0.07, 0.05, 1.0);
// How much of the length is kept, 0..1 (1 = uncut): x = the hair's, y = the beard's.
instance uniform vec4 hair_look : instance_index(11) = vec4(1.0, 1.0, 0.0, 0.0);

// Share of the dots a beard's cap keeps under its hairs: FFHQ's bearded men show skin between their hairs
// (a beard's mean light 0.55 of the way from the cheek's to the hair's); a whole cap measured 0.82-0.89.
const float BEARD_CAP_SHARE = 0.75;

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
	// Under a beard's hairs (R = 1) the cap keeps only BEARD_CAP_SHARE of the dots: whole, it was a dark mask.
	float share = mix(1.0, BEARD_CAP_SHARE, is_beard * step(0.5, COLOR.r));
	float cap = step(layer, 0.01) * step(1.0 - sparse * sparse * share, cap_g + 0.001);
	if (cap < 0.5 && (layer < 0.01 || height < layer)) {
		discard;
	}
	vec3 base = mix(max(hair_colour.rgb, vec3(0.022, 0.019, 0.017)), vec3(0.012, 0.01, 0.009), darken);
	base *= 1.0 + (hair.g - 0.5) * 2.0 * strand_variation;
	// Light reaches the skin between sparse hairs: the root shadow comes in with the density.
	ALBEDO = base * mix(1.0 - root_shadow * sparse, 1.0, layer);
	ROUGHNESS = roughness_base;
	SPECULAR = 0.25;
}
