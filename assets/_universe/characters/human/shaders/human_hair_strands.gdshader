// Hair as hairs -- a head of hair (HairStrands), a beard, eyebrows, eyelashes: each a strip of two vertices per point, with no width of its own.
// The vertex shader gives it one across the line of sight: its true width plus a soft edge of
// expand_pixels, so a hair always shows its full width and thousands of them read as hair, where ribbons
// textured with hair read as ribbons. A hair thinner than a pixel covers the pixel only partly (its alpha
// says how much), as a real one does: from afar, many of them add up to the mass of the hair.
//
// UV.x = the side of the strip (0 or 1), UV.y = along the hair (0 root .. 1 tip). TANGENT = the hair's
// direction. NORMAL = away from the skull: the hair is lit as the volume it makes. A head of hair's own mesh
// (HairStrands.PACKED_FORMAT, 20 bytes a vertex instead of 32) has no UV nor tangent: CUSTOM0 = the direction
// and how far along (that is how it is told from the head's eyebrows, lashes and beard, whose CUSTOM0 reads 0),
// the side is the vertex's parity; vertex() puts them back where the rest reads them (strip_uv for UV).
// COLOR: R = how far
// along the style's longest strand (a shorter cut clips there), G = a random value per hair, B = the layer
// (0 against the head .. 1 outermost), A = the hair's density at the root.
//
// Drawn as in TressFX (AMD; its Godot port by Ismail Ivanov, MIT -- see HUMAN_SHADERS_LICENSE.md): the
// solid core of each hair writes depth in a pre-pass, then the whole strip is blended over it with its soft
// edge. Lit as a hair fibre is (human_hair_bsdf.gdshaderinc): Marschner's three highlights -- R white
// towards the root, TT through the hair against the light, TRT in its colour towards the tip -- and the
// light scattered between the hairs.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

#include "res://assets/_universe/characters/human/shaders/human_hair_bsdf.gdshaderinc"

// Width of a hair (m) at its root.
uniform float hair_width : hint_range(0.0001, 0.005) = 0.0008;
// Share of that width left at the tip, 0..1.
uniform float tip_width : hint_range(0.0, 1.0) = 0.45;
// Share of that width left to the hairs where the hair thins out (the hairline), 0..1: lower = a softer,
// finer hairline, 1 = as thick as the rest.
uniform float hairline_width : hint_range(0.0, 1.0) = 0.35;
// Soft edge added on each side of a hair (pixels): wider = smoother edges, a little more blur.
uniform float expand_pixels : hint_range(0.3, 2.0) = 0.7;
// The least a hair's strip is opaque, 0..1, however thin and far, for hairs that drop with distance
// (levels of detail) without lod_compensate: what is left must cover more; lower = hair thins out with distance.
uniform float min_coverage : hint_range(0.0, 1.0) = 0.6;
// Share of a hair's length over which its tip fades out, 0..1 (no hard stubs at the ends).
uniform float tip_fade : hint_range(0.0, 1.0) = 0.15;
// 1 = this is a beard: its length is the avatar's beard length (hair_look.y), not its hair's.
uniform float is_beard : hint_range(0.0, 1.0) = 0.0;
// How much darker than the hair colour, 0..1 (0 = the hair colour itself).
uniform float darken : hint_range(0.0, 1.0) = 0.0;
// Strength of the highlights (R, TT and TRT together), 0..2: 1 = Karis' hair, 0 = matt (eyelashes). 0.7 with
// the hairs' shade on each other (extinction_scale 0.06) keeps the hair's median brightness of the former
// lighting, on which hair_colour() and the photo reader were set (FFHQ): higher = glossier, brighter hair.
uniform float spec_strength : hint_range(0.0, 2.0) = 0.7;
// Strength of the light through the hair (TT: blond hair glowing against the sun), 0..2.
uniform float transmission : hint_range(0.0, 2.0) = 1.0;
// How rough the hair's surface is, 0..1: lower = thinner, brighter highlight bands (glossy, combed hair),
// higher = broad, soft ones (dry, frizzy hair). The bands' width is roughness^2 radians.
uniform float roughness : hint_range(0.1, 1.0) = 0.4;
// Tilt of a hair's scales (deg): shifts the white highlight towards the root by twice this and the coloured
// one towards the tip by four times -- why combed hair shows two bands. A real hair's: 2..4.
uniform float cuticle_tilt : hint_range(0.0, 10.0) = 3.0;
// How far light wraps around the hair's volume, 0..1: 0 = a hard terminator, higher = softer, fuller hair.
uniform float wrap : hint_range(0.0, 1.0) = 0.45;
// How much lighter or darker one hair may be than its neighbour, 0..1.
uniform float strand_variation : hint_range(0.0, 1.0) = 0.4;
// How dark the hair gets against the head and at its roots, 0..1 (0 = flat): hairs with no volume of their
// own (a beard, eyebrows); a head of hair is shaded by its volume.
uniform float inner_shadow : hint_range(0.0, 1.0) = 0.35;

// ── The light the hair stops (HairVolume, one per style; set by CharacterMaterials) ─────────────────────────
// R = extinction (1/m), G = optical depth from outside (the six axes' mean), in the mesh's frame.
uniform sampler3D density_volume : filter_linear, repeat_disable;
// 1 = density_volume is set: the hairs shade each other through it.
uniform float has_volume = 0.0;
uniform vec3 volume_origin = vec3(0.0);
uniform vec3 volume_size = vec3(1.0);
// Side of a cell of the volume (m): the march's step towards a light.
uniform float volume_cell = 0.01;
// How much light the hairs stop, as a share of their strips' cross-section, 0..0.5: lower = light reaches
// deeper into the hair (brighter, flatter), higher = the hair under the surface is darker (deeper, fuller
// hair). Light scattered forward goes on through a hair, so far less is stopped than the strips cover.
uniform float extinction_scale : hint_range(0.0, 0.5) = 0.06;
// How much the ambient light is dimmed inside the hair, 0..1 (0 = not at all).
uniform float ambient_shade : hint_range(0.0, 1.0) = 1.0;
// How much deeper in colour the light gets inside the hair, 0..1: 0 = the hair's colour throughout,
// higher = warmer, more saturated depths (1 turns blond orange).
uniform float deep_tint : hint_range(0.0, 1.0) = 0.35;

// ── Levels of detail that keep the coverage (a head of hair; set by CharacterMaterials) ─────────────────
// The engine draws the first share of the hairs (HairStrands.LODS, by the mesh's distance and the
// viewport's mesh_lod_threshold). The shader works out a share that is never more than the engine's, and
// changes smoothly: hairs past it are dropped, those left are widened by as much -- the hair covers as much
// at any distance, and no level pops in.
// 1 = the parameters below are set.
uniform float lod_compensate = 0.0;
// The style's number of hairs, and of vertices per hair (they are laid out hair after hair, in LOD order).
uniform int hair_count = 1;
uniform int vertices_per_hair = 2;
// The hairs' box in the mesh's frame (the engine measures the distance to it).
uniform vec3 lod_box_origin = vec3(0.0);
uniform vec3 lod_box_size = vec3(0.0);
// The levels: their error (m) and the share of the hairs they keep.
uniform vec4 lod_errors = vec4(1.0);
uniform vec4 lod_shares = vec4(1.0);
// The game view's mesh_lod_threshold (pixels), set by RenderApplier.
global uniform float mesh_lod_threshold;

// ── Motion (HairMotion: a head of hair's guides follow simulated strands; a beard swings) ────────────────────
// Per guide (HairMotionBinding, set by CharacterMaterials): its length (m), its strand_free code, the two simulated
// strands it follows (a * 64 + b) and the first's weight. TEXTURE_WIDTH (256) guides a row.
uniform sampler2D motion_binding : filter_nearest, repeat_disable;
// 1 = motion_binding is set: this head of hair may move.
uniform float has_motion = 0.0;
// The style's guides (the hairs are made child after child over them: a hair's guide is its rank modulo this).
uniform int guide_count = 1;
// How far from its root a loose hair stays put (m), and over how far past that its motion comes in (m).
uniform float fixed_length : hint_range(0.0, 0.3) = 0.07;
uniform float free_blend : hint_range(0.0, 0.2) = 0.05;
// How far from its root a beard's hair stays put (m): only the end of a long beard swings.
uniform float beard_fixed : hint_range(0.0, 0.2) = 0.05;
// Every moving avatar's row (HairMotion): per simulated strand, its SAMPLES points' displacements from rest (xyz, m,
// in the mesh's frame), evenly over its free part: the first where it stops staying put, the last its tip.
global uniform sampler2D hair_motion_rows : filter_nearest, repeat_disable;
const int MOTION_SAMPLES = 8;

// ── Per avatar ──────────────────────────────────────────────────────────────────────────────────────
// Linear hair colour (CharacterAppearance.hair_colour). Index 9, the characters' 8..11.
instance uniform vec4 hair_colour : instance_index(9) = vec4(0.1, 0.07, 0.05, 1.0);
// x = how much of the style's length is kept, 0..1 (1 = uncut).
instance uniform vec4 hair_look : instance_index(11) = vec4(1.0, 1.0, 0.0, 0.0);
// HairMotion. A head of hair: x = its row in hair_motion_rows + 1, or 0 and yzw = its swing as one (m, in the mesh's
// frame, at 10 cm past the fixed length; all 0 = still). A beard: xyz = its swing (likewise past beard_fixed), w = its
// length (m).
instance uniform vec4 hair_motion : instance_index(15) = vec4(0.0);

// The point in the mesh's frame (the volume's), and the view-to-mesh rotation (a light's direction), for light().
varying vec3 model_pos;
varying mat3 view_to_model;
// The hair's direction, in view space, for light().
varying vec3 hair_direction;
// UV, or what stands for it in a packed head of hair (read in place of UV everywhere).
varying vec2 strip_uv;
// The hair's true half width and its drawn half width (true + soft edge), in pixels.
varying float true_half;
varying float drawn_half;

// The share of the hairs drawn when an error of [allowed] metres is under a pixel: 1 up to half the first
// level's error, then down to each level's share at the error where the engine switches to it -- never more
// than the engine draws, eased in between (log-linear).
float lod_share(float allowed) {
	float from_error = lod_errors.x * 0.5;
	if (allowed <= from_error) {
		return 1.0;
	}
	float from_share = 1.0;
	for (int i = 0; i < 4; i++) {
		if (allowed < lod_errors[i]) {
			float t = clamp(log(allowed / from_error) / log(lod_errors[i] / from_error), 0.0, 1.0);
			return from_share * pow(lod_shares[i] / from_share, t);
		}
		from_error = lod_errors[i];
		from_share = lod_shares[i];
	}
	return from_share;
}

// Where a head of hair's hair is moved to: past its guide's fixed length, as the two simulated strands it follows
// are, at the same share of their free part. [param tangent] turns with it.
vec3 hair_moved(vec3 rest, inout vec3 tangent, int vertex_id, int vertices, float share, int row) {
	int guide = (vertex_id / vertices) % guide_count;
	vec4 b = texelFetch(motion_binding, ivec2(guide % 256, guide / 256), 0);
	float free_from = b.y < 0.0 ? fixed_length * -b.y : b.y;
	float weight = smoothstep(free_from, free_from + free_blend, share * b.x);
	if (weight <= 0.0) {
		return rest;
	}
	int pair = int(b.z + 0.5);
	int sa = pair / 64;
	int sb = pair - sa * 64;
	// The simulated strands' samples span their free part, from where they stop staying put to their tip.
	float at = clamp((share * b.x - free_from) / max(b.x - free_from, 1e-3), 0.0, 1.0) * float(MOTION_SAMPLES - 1);
	int j = min(int(at), MOTION_SAMPLES - 2);
	float u = at - float(j);
	vec3 d0 = mix(texelFetch(hair_motion_rows, ivec2(sb * MOTION_SAMPLES + j, row), 0).xyz,
			texelFetch(hair_motion_rows, ivec2(sa * MOTION_SAMPLES + j, row), 0).xyz, b.w);
	vec3 d1 = mix(texelFetch(hair_motion_rows, ivec2(sb * MOTION_SAMPLES + j + 1, row), 0).xyz,
			texelFetch(hair_motion_rows, ivec2(sa * MOTION_SAMPLES + j + 1, row), 0).xyz, b.w);
	// The strand's turn between its samples, over their spacing.
	tangent = normalize(tangent + weight * (d1 - d0) / max((b.x - free_from) / float(MOTION_SAMPLES - 1), 1e-3));
	return rest + mix(d0, d1, u) * weight;
}

void vertex() {
	model_pos = VERTEX;
	if (dot(CUSTOM0.xyz, CUSTOM0.xyz) > 0.25) {
		TANGENT = CUSTOM0.xyz;
		strip_uv = vec2(float(VERTEX_ID % 2), CUSTOM0.w);
	} else {
		strip_uv = UV;
	}
	if (has_motion > 0.5 && hair_motion.x > 0.5) {
		VERTEX = hair_moved(VERTEX, TANGENT, VERTEX_ID, vertices_per_hair, strip_uv.y, int(hair_motion.x + 0.5) - 1);
	} else if (has_motion > 0.5 && dot(hair_motion.yzw, hair_motion.yzw) > 0.0) {
		// Farther off, the hair swings as one (HairMotion's pendulum: yzw, m at 10 cm past the fixed length).
		int guide = (VERTEX_ID / vertices_per_hair) % guide_count;
		vec4 b = texelFetch(motion_binding, ivec2(guide % 256, guide / 256), 0);
		float past = max(strip_uv.y * b.x - (b.y < 0.0 ? fixed_length * -b.y : b.y), 0.0);
		VERTEX += hair_motion.yzw * smoothstep(0.0, free_blend, past) * (past / 0.1);
	} else if (is_beard > 0.5 && hair_motion.w > 0.0) {
		// A long beard's end swings: past beard_fixed, as much as it is past it.
		float past = max(COLOR.r * hair_motion.w - beard_fixed, 0.0);
		VERTEX += hair_motion.xyz * smoothstep(0.0, free_blend, past) * (past / 0.1);
	}
	view_to_model = inverse(mat3(MODEL_MATRIX)) * mat3(INV_VIEW_MATRIX);
	vec3 at = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 along = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
	// Across the line of sight (an orthographic camera looks down -Z everywhere).
	bool flat_view = PROJECTION_MATRIX[3][3] > 0.5;
	vec3 to_eye = flat_view ? vec3(0.0, 0.0, 1.0) : normalize(-at);
	vec3 across = cross(along, to_eye);
	across = length(across) > 1e-4 ? normalize(across) : vec3(1.0, 0.0, 0.0);
	// The size of a pixel at the hair, in metres. abs(): the engine flips the projection's Y when it renders
	// to a texture -- which it always does -- and a negative size made every hair's true width negative: all
	// of them drawn a pixel wide at min_coverage, however near.
	float pixel = (flat_view ? 2.0 : -at.z * 2.0) / abs(PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float widen = 1.0;
	bool dropped = false;
	if (lod_compensate > 0.5 && !flat_view) {
		// The engine's measure: the camera's distance to the box (world axes), the mesh's largest scale.
		vec3 half_box = 0.5 * lod_box_size;
		vec3 to_box = mat3(INV_VIEW_MATRIX) * (MODELVIEW_MATRIX * vec4(lod_box_origin + half_box, 1.0)).xyz;
		vec3 reach = abs(MODEL_MATRIX[0].xyz) * half_box.x + abs(MODEL_MATRIX[1].xyz) * half_box.y
				+ abs(MODEL_MATRIX[2].xyz) * half_box.z;
		float distance = length(max(abs(to_box) - reach, vec3(0.0)));
		float scale = max(length(MODEL_MATRIX[0].xyz), max(length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz)));
		float allowed = mesh_lod_threshold * distance * 2.0 / abs(PROJECTION_MATRIX[0][0] * VIEWPORT_SIZE.x * scale);
		float share = lod_share(allowed);
		float rank = (float(VERTEX_ID / vertices_per_hair) + 0.5) / float(hair_count);
		dropped = rank > share;
		widen = 1.0 / share;
	}
	// Where the hair thins out (the hairline: COLOR.a, the density at the root) its hairs are finer too.
	float fine = mix(hairline_width, 1.0, smoothstep(0.2, 0.9, COLOR.a));
	true_half = 0.5 * hair_width * fine * widen * mix(1.0, tip_width, strip_uv.y) / pixel;
	// A hair under a pixel is drawn a pixel wide and covers it partly (fragment()).
	drawn_half = max(true_half, 0.5) + expand_pixels;
	at += across * (strip_uv.x - 0.5) * 2.0 * drawn_half * pixel;
	// A dropped hair: all its vertices on one point, nothing drawn.
	POSITION = dropped ? vec4(0.0, 0.0, 2.0, 1.0) : PROJECTION_MATRIX * vec4(at, 1.0);
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
	float dist = abs(strip_uv.x - 0.5) * 2.0 * drawn_half;
	float cover = clamp((drawn_half - dist) / expand_pixels, 0.0, 1.0);
	if (true_half < 0.5) {
		// Where the hair thins out (the hairline) its hairs are finer, the floor lower: the skin shows through.
		float floor_cover = lod_compensate > 0.5 ? 0.0 : min_coverage * mix(0.35, 1.0, smoothstep(0.2, 0.9, COLOR.a));
		cover *= max(2.0 * true_half / (1.0 + expand_pixels), floor_cover);
	}
	// The tip fades, and so does the end of a cut hair.
	float tip = tip_fade > 0.0 ? 1.0 - smoothstep(1.0 - tip_fade, 1.0, strip_uv.y) : 1.0;
	float cut = length_kept >= 0.999 ? 1.0 : 1.0 - smoothstep(kept - 0.03, kept, COLOR.r);
	ALPHA = cover * tip * cut;
	// Even black hair is not black: its hairs catch light, each a little differently.
	vec3 base = mix(max(hair_colour.rgb, vec3(0.022, 0.019, 0.017)), vec3(0.012, 0.01, 0.009), darken);
	base *= 1.0 + (ident - 0.5) * 2.0 * strand_variation;
	if (has_volume > 0.5) {
		// The ambient light that gets in between the hairs to this one.
		float depth = texture(density_volume, (model_pos - volume_origin) / volume_size).g;
		AO = mix(1.0, exp(-extinction_scale * depth), ambient_shade);
		ALBEDO = base;
	} else {
		// Darker against the head and at the roots, where light does not reach between the hairs.
		float lit = mix(1.0 - inner_shadow, 1.0, COLOR.b) * mix(1.0 - inner_shadow, 1.05, smoothstep(0.0, 0.5, strip_uv.y));
		ALBEDO = base * lit;
	}
	// Lit as the volume the hair makes, whichever side of a strip is seen.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	hair_direction = normalize(TANGENT);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

// The light scattered between the hairs (diffuse) and the three highlights. The skull blocks the light
// from behind (head_block): without it, the far side's hairs would glow through the head wherever shadows
// are off (remote avatars far away).
// With a volume, the light that reaches this hair through the others (through): the highlights take it as it
// is; the scattered light gets in deeper -- it has gone round the hairs -- and deepens in colour on its way.
void light() {
	float head_block = smoothstep(-0.6, 0.05, dot(NORMAL, LIGHT));
	float through = 1.0;
	if (has_volume > 0.5) {
		vec3 dir = normalize(view_to_model * LIGHT) * volume_cell;
		vec3 p = model_pos + 0.5 * dir;
		float tau = 0.0;
		for (int i = 0; i < 8; i++) {
			tau += texture(density_volume, (p - volume_origin) / volume_size).r;
			p += dir;
		}
		through = exp(-extinction_scale * tau * volume_cell);
	}
	vec3 lit = LIGHT_COLOR * ATTENUATION * head_block / PI;
	DIFFUSE_LIGHT += lit * hair_scatter(hair_direction, NORMAL, LIGHT, wrap) * sqrt(through)
			* hair_scatter_tint(ALBEDO, through, deep_tint);
	SPECULAR_LIGHT += lit * through * hair_highlights(hair_direction, VIEW, LIGHT, ALBEDO, roughness,
			radians(cuticle_tilt), spec_strength, transmission);
}
