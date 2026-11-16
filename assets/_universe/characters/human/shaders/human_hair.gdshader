// Hair, eyebrows and eyelashes: cards textured with strands, cut by their alpha.
//
// depth_prepass_alpha: the dense part of the strands (alpha above the prepass threshold) is drawn in a
// depth prepass, so the hair still occludes and sorts like a solid and depth-reading effects (dust)
// stop at it, while the sparse fringe is alpha-blended on top -- a hard alpha cut made the hairline a
// jagged edge. Coverage is sharpened as the texture minifies so thin strands do not dissolve at a
// distance. The highlight stretches ALONG the strands (anisotropy following the cards' V direction),
// which reads as hair rather than a textured helmet.
shader_type spatial;
render_mode depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Strand colour and coverage (alpha).
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
// Colour multiplied over the texture (white = the texture's own colour).
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
// Specular level, 0..1: hair's cuticle reflects less than a polished surface.
uniform float specular_level : hint_range(0.0, 1.0) = 0.3;
// Mip-level coverage boost: keeps thin strands from fading out at a distance (0 = none).
uniform float coverage_boost : hint_range(0.0, 1.0) = 0.45;
// Strand roughness, 0..1: lower = glossier hair.
uniform float roughness_base : hint_range(0.0, 1.0) = 0.55;
// Highlight stretch along the strands, -1..1 (0 = round highlight).
uniform float anisotropy_amount : hint_range(-1.0, 1.0) = 0.35;
// Light passing through thin strands from behind, 0..1.
uniform float backlight_amount : hint_range(0.0, 1.0) = 0.25;
// Mean linear luminance of the texture's strands (human_catalogue.json strand_luminance): a coloured
// texel is brought back to it, so a chosen hair colour comes out as chosen whatever the texture's own.
uniform float strand_luminance : hint_range(0.001, 1.0) = 0.2;
// How much darker than the hair colour these strands are, 0..1: eyelashes stay dark on grey hair,
// eyebrows a little darker than the head (0 = the hair colour itself).
uniform float darken : hint_range(0.0, 1.0) = 0.0;

// ── Per avatar (CharacterAppearance.hair_colour) ────────────────────────────────────────────────────
// Linear hair colour; alpha 1 = recolour the strands with it (the texture's shading kept), alpha 0 =
// the texture's own colour. Index 9, the characters' 8..10 (see human_skin.gdshader).
instance uniform vec4 hair_colour : instance_index(9) = vec4(1.0, 1.0, 1.0, 0.0);

void fragment() {
	vec4 texel = texture(albedo_texture, UV);
	vec3 strands = texel.rgb;
	if (hair_colour.a > 0.5) {
		// The strands' own shading, relative to their mean. Textures painted near black (most eyebrows
		// and lashes, the afro) hold too few levels for that -- divided up, they come out in blocks -- so
		// there the coverage shades instead: thin strand edges darker than the dense core.
		float luminance = dot(strands, vec3(0.2126, 0.7152, 0.0722));
		float shade = strand_luminance > 0.02 ? clamp(pow(luminance / strand_luminance, 0.75), 0.0, 2.5)
				: mix(0.7, 1.1, texel.a);
		strands = mix(hair_colour.rgb, vec3(0.012, 0.01, 0.009), darken) * shade;
	}
	ALBEDO = strands * tint.rgb;
	// Sharpen coverage as the texture is minified, so distant hair keeps its volume.
	float lod_scale = 1.0 + coverage_boost * clamp(length(fwidth(UV)) * 512.0, 0.0, 4.0);
	ALPHA = clamp(texel.a * lod_scale, 0.0, 1.0);
	ROUGHNESS = roughness_base;
	SPECULAR = specular_level;
	ANISOTROPY = anisotropy_amount;
	ANISOTROPY_FLOW = vec2(0.0, 1.0);
	BACKLIGHT = ALBEDO * backlight_amount;
}
