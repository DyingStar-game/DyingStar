// Hair as hairs -- a head of hair (HairStrands), a beard, eyebrows, eyelashes: each a strip of two vertices per point, with no width of its own.
// The vertex shader gives it one across the line of sight: its true width plus a soft edge of
// expand_pixels, so a hair always shows its full width and thousands of them read as hair, where ribbons
// textured with hair read as ribbons. A hair thinner than a pixel covers the pixel only partly (its alpha
// says how much), as a real one does: from afar, many of them add up to the mass of the hair.
//
// UV.x = the side of the strip (0 or 1), UV.y = along the hair (0 root .. 1 tip). TANGENT = the hair's
// direction. NORMAL = away from the skull: the hair is lit as the volume it makes. COLOR: R = how far
// along the style's longest strand (a shorter cut clips there), G = a random value per hair, B = the layer
// (0 against the head .. 1 outermost), A = the hair's density at the root.
//
// Drawn as in TressFX (AMD; its Godot port by Ismail Ivanov, MIT -- see HUMAN_SHADERS_LICENSE.md): the
// solid core of each hair writes depth in a pre-pass, then the whole strip is blended over it with its soft
// edge; the light has two highlights shifted along the hair (Marschner's R, white, towards the root, and
// TRT, in the hair's colour, towards the tip).
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

// Width of a hair (m) at its root.
uniform float hair_width : hint_range(0.0001, 0.005) = 0.0008;
// Share of that width left at the tip, 0..1.
uniform float tip_width : hint_range(0.0, 1.0) = 0.45;
// Soft edge added on each side of a hair (pixels): wider = smoother edges, a little more blur.
uniform float expand_pixels : hint_range(0.3, 2.0) = 0.7;
// The least a hair's strip is opaque, 0..1, however thin and far: a head of hair drops hairs with distance
// (its levels of detail), so what is left must cover more; lower = hair thins out with distance.
uniform float min_coverage : hint_range(0.0, 1.0) = 0.6;
// Share of a hair's length over which its tip fades out, 0..1 (no hard stubs at the ends).
uniform float tip_fade : hint_range(0.0, 1.0) = 0.15;
// 1 = this is a beard: its length is the avatar's beard length (hair_look.y), not its hair's.
uniform float is_beard : hint_range(0.0, 1.0) = 0.0;
// How much darker than the hair colour, 0..1 (0 = the hair colour itself).
uniform float darken : hint_range(0.0, 1.0) = 0.0;
// Strength of the first highlight (R: white, the light reflected off the hair's surface), 0..2.
uniform float sheen : hint_range(0.0, 2.0) = 0.07;
// Tightness of that highlight: higher = a thinner, sharper band (glossier hair).
uniform float sheen_tightness : hint_range(4.0, 200.0) = 80.0;
// Strength of the second highlight (TRT: through the hair and back, in its own colour), 0..2.
uniform float glow : hint_range(0.0, 2.0) = 0.3;
// Tightness of the second highlight: it is broader than the first.
uniform float glow_tightness : hint_range(2.0, 100.0) = 18.0;
// Tilt of a hair's scales (deg): shifts the first highlight towards the root by twice this, the second
// towards the tip by three times -- why combed hair shows two bands, a white one and a coloured one.
uniform float cuticle_tilt : hint_range(0.0, 10.0) = 4.0;
// How far light wraps around the hair's volume, 0..1: 0 = a hard terminator, higher = softer, fuller hair.
uniform float wrap : hint_range(0.0, 1.0) = 0.45;
// How much lighter or darker one hair may be than its neighbour, 0..1.
uniform float strand_variation : hint_range(0.0, 1.0) = 0.4;
// How dark the hair gets against the head and at its roots, 0..1 (0 = flat).
uniform float inner_shadow : hint_range(0.0, 1.0) = 0.35;

// ── Per avatar ──────────────────────────────────────────────────────────────────────────────────────
// Linear hair colour (CharacterAppearance.hair_colour). Index 9, the characters' 8..11.
instance uniform vec4 hair_colour : instance_index(9) = vec4(0.1, 0.07, 0.05, 1.0);
// x = how much of the style's length is kept, 0..1 (1 = uncut).
instance uniform vec4 hair_look : instance_index(11) = vec4(1.0, 1.0, 0.0, 0.0);

// The hair's direction, in view space, for light().
varying vec3 hair_direction;
// The hair's true half width and its drawn half width (true + soft edge), in pixels.
varying float true_half;
varying float drawn_half;

void vertex() {
	vec3 at = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 along = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
	// Across the line of sight (an orthographic camera looks down -Z everywhere).
	bool flat_view = PROJECTION_MATRIX[3][3] > 0.5;
	vec3 to_eye = flat_view ? vec3(0.0, 0.0, 1.0) : normalize(-at);
	vec3 across = cross(along, to_eye);
	across = length(across) > 1e-4 ? normalize(across) : vec3(1.0, 0.0, 0.0);
	// The size of a pixel at the hair, in metres.
	float pixel = (flat_view ? 2.0 : -at.z * 2.0) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	true_half = 0.5 * hair_width * mix(1.0, tip_width, UV.y) / pixel;
	// A hair under a pixel is drawn a pixel wide and covers it partly (fragment()).
	drawn_half = max(true_half, 0.5) + expand_pixels;
	at += across * (UV.x - 0.5) * 2.0 * drawn_half * pixel;
	POSITION = PROJECTION_MATRIX * vec4(at, 1.0);
}

void fragment() {
	float ident = COLOR.g;
	// A shorter cut: every hair ends near the kept length, none at quite the same place.
	float length_kept = mix(hair_look.x, hair_look.y, is_beard);
	float kept = length_kept >= 0.999 ? 2.0 : length_kept * (0.88 + 0.24 * ident);
	// The hairline thins out: fewer hairs where the hair is sparse.
	if (COLOR.r > kept || ident > COLOR.a * 1.4 + 0.1) {
		discard;
	}
	// Coverage across the strip: 1 inside the hair, fading out over the soft edge. A hair under a pixel is
	// drawn a pixel wide (plus the edge) and covers only its share of that: summed across the strip, as
	// much as its true width.
	float dist = abs(UV.x - 0.5) * 2.0 * drawn_half;
	float cover = clamp((drawn_half - dist) / expand_pixels, 0.0, 1.0);
	if (true_half < 0.5) {
		// Where the hair thins out (the hairline) its hairs are finer, the floor lower: the skin shows through.
		float floor_cover = min_coverage * mix(0.35, 1.0, smoothstep(0.2, 0.9, COLOR.a));
		cover *= max(2.0 * true_half / (1.0 + expand_pixels), floor_cover);
	}
	// The tip fades, and so does the end of a cut hair.
	float tip = tip_fade > 0.0 ? 1.0 - smoothstep(1.0 - tip_fade, 1.0, UV.y) : 1.0;
	float cut = length_kept >= 0.999 ? 1.0 : 1.0 - smoothstep(kept - 0.03, kept, COLOR.r);
	ALPHA = cover * tip * cut;
	// Even black hair is not black: its hairs catch light, each a little differently.
	vec3 base = mix(max(hair_colour.rgb, vec3(0.022, 0.019, 0.017)), vec3(0.012, 0.01, 0.009), darken);
	base *= 1.0 + (ident - 0.5) * 2.0 * strand_variation;
	// Darker against the head and at the roots, where light does not reach between the hairs.
	float lit = mix(1.0 - inner_shadow, 1.0, COLOR.b) * mix(1.0 - inner_shadow, 1.05, smoothstep(0.0, 0.5, UV.y));
	ALBEDO = base * lit;
	// Lit as the volume the hair makes, whichever side of a strip is seen.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	hair_direction = normalize(TANGENT);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

// Diffuse: light wraps around the volume the hair makes. Highlights (TressFX's ComputeDiffuseSpecFactors):
// the reflection direction about the hair, turned by the scales' tilt, against the view -- no mirror-like
// glare at grazing angles, which on hairs a pixel wide is only sparkle.
void light() {
	// (1 / PI: the engine's own diffuse term carries it, and the hair must sit in the same light as the skin.)
	float facing = clamp((dot(NORMAL, LIGHT) + wrap) / (1.0 + wrap), 0.0, 1.0) / PI;
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * facing;
	vec3 t = hair_direction;
	float cos_tl = dot(t, LIGHT);
	float cos_trl = -cos_tl;
	float sin_trl = sqrt(max(0.0, 1.0 - cos_tl * cos_tl));
	float cos_te = dot(t, VIEW);
	float sin_te = sqrt(max(0.0, 1.0 - cos_te * cos_te));
	float a = radians(cuticle_tilt);
	float cos_r = cos_trl * cos(2.0 * a) - sin_trl * sin(2.0 * a);
	float r = max(0.0, cos_r * cos_te + sqrt(max(0.0, 1.0 - cos_r * cos_r)) * sin_te);
	float cos_trt = cos_trl * cos(-3.0 * a) - sin_trl * sin(-3.0 * a);
	float trt = max(0.0, cos_trt * cos_te + sqrt(max(0.0, 1.0 - cos_trt * cos_trt)) * sin_te);
	vec3 band = vec3(pow(r, sheen_tightness) * sheen) + ALBEDO * pow(trt, glow_tightness) * glow;
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * facing * band;
}
