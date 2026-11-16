// What makes one person's skin theirs, over the shared painted maps: freckles, moles, an uneven tone,
// redness, shadows under the eyes and expression lines -- each a per-avatar amount (CharacterAppearance
// skin details), drawn where the zone's region map allows it (tools/character/skin_detail).
// Included by human_skin.gdshader (everything) and human_skin_far.gdshader (colour only, no spots).

// Where each detail may show (skin_detail_<zone>_regions): R redness, G freckles, B under-eye shadow,
// A marks allowed (not on the lips, the lids' rims, in the nostrils).
uniform sampler2D region_texture : filter_linear_mipmap, repeat_disable;
// Expression lines (tangent-space normal map); the face's only, the other zones keep the flat default.
uniform sampler2D wrinkle_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
// What a smile does to the skin (tangent-space slopes, 0.5 = flat): RG = its folds (nasolabial folds, the
// cheek over them, crow's feet), BA = dimples. The face's only (smile_map = 1 there).
uniform sampler2D smile_texture : filter_linear_mipmap_anisotropic, repeat_disable;
// 1 where smile_texture is set (the face), 0 elsewhere: an unset texture reads as steep slopes.
uniform float smile_map : hint_range(0.0, 1.0) = 0.0;
// How much of the dimples shows on a face at rest, 0..1 (all of them as it smiles).
uniform float dimple_at_rest : hint_range(0.0, 1.0) = 0.12;
// How much a smile's folds and dimples darken the skin in them (light reaches less into a crease), 0..1.
uniform float smile_occlusion : hint_range(0.0, 1.0) = 0.35;
// Freckles across the zone's UV square: higher = smaller, more numerous (a face's square is a head).
uniform float freckle_scale = 115.0;
// Moles across the zone's UV square: higher = more, smaller.
uniform float mole_scale = 16.0;
// How much a freckle darkens the skin at full strength, 0..1.
uniform float freckle_darkness : hint_range(0.0, 1.0) = 0.62;
// Redness everyone has (cheeks, nose, ears), whatever their redness amount, 0..1.
uniform float base_redness : hint_range(0.0, 1.0) = 0.25;
// The lips' UV box (u0, v0, u1, v1): the face's only, empty elsewhere. In it, where the region map bars marks
// and the painted skin is red, the lips are tinted.
uniform vec4 lip_box = vec4(0.0);
// The face's redness, calibrated on FFHQ (cheek's a* over the forehead's: p25 0, median 3, p90 8 -- at redness 0,
// ~0.3, 1): how much of the painted blush a redness of 0 takes off, and how fast redness adds.
const float FACE_BLUSH_PAINTED = 1.25;
const float FACE_REDNESS_GAIN = 1.6;
// What the lips' colour is multiplied by: FFHQ's unmade lips are 12 L darker than the cheek and redder (a +8..10,
// b -4); the painted ones were 1-4 L darker, a +3..4.
uniform vec3 lip_tint : source_color = vec3(0.72, 0.55, 0.6);

// ── Per avatar (HumanAppearance) ────────────────────────────────────────────────────────────────────
// x = freckles, y = moles, z = expression lines, w = redness; 0..1. Index 12 (the characters own 8..13).
instance uniform vec4 skin_detail : instance_index(12) = vec4(0.0, 0.3, 0.2, 0.3);
// x = shadows under the eyes, y = uneven tone, z = this person's seed (0..1), w = dimples (0..1).
instance uniform vec4 skin_marks : instance_index(13) = vec4(0.3, 0.3, 0.0, 0.0);
// x = how much the face smiles now, 0..1 (FaceLife's smile and happy shapes). Index 14.
instance uniform vec4 face_motion : instance_index(14) = vec4(0.0);

// Two random numbers 0..1 per point, without sin(): a GPU's sin() loses its precision on the hundreds of
// cells a zone has, and the dots then cluster or vanish ("hash without sine", Dave Hoskins, MIT).
vec2 detail_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float detail_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = detail_hash(i).x;
	float b = detail_hash(i + vec2(1.0, 0.0)).x;
	float c = detail_hash(i + vec2(0.0, 1.0)).x;
	float d = detail_hash(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Dots scattered over cells of the UV square: how much of a dot covers this point (0..1), and its shade.
// density = share of the cells that hold one; size = its radius, in cells.
vec2 detail_spots(vec2 uv, float scale, float density, float size, float seed) {
	vec2 g = uv * scale + seed * vec2(37.0, 91.0);
	vec2 cell = floor(g);
	vec2 f = fract(g);
	vec2 best = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 h = detail_hash(cell + o);
			vec2 r = detail_hash(cell + o + vec2(13.1, 7.7));
			if (r.x < density) {
				// Not round: a freckle is a blot, stretched a little in its own direction.
				vec2 d = f - (o + h);
				float angle = r.y * 6.2831;
				d = mat2(vec2(cos(angle), sin(angle)), vec2(-sin(angle), cos(angle))) * d * vec2(1.0, 1.35);
				float radius = size * (0.45 + 0.9 * fract(r.y * 7.13));
				float cover = 1.0 - smoothstep(radius * 0.45, radius, length(d));
				if (cover > best.x) {
					best = vec2(cover, fract(r.x * 11.7 + r.y * 3.1));
				}
			}
		}
	}
	return best;
}

// The person's own skin over the painted one. melanin = skin tone (0 light .. 1 dark).
vec3 skin_details_colour(vec3 albedo, vec2 uv, float melanin, bool spots) {
	vec4 region = texture(region_texture, uv);
	float seed = skin_marks.z;
	// Uneven tone: broad blotches of slightly darker, redder or yellower skin.
	float blotch = detail_noise(uv * 9.0 + seed * 17.0) * 0.65 + detail_noise(uv * 31.0 + seed * 5.0) * 0.35;
	float uneven = skin_marks.y * (blotch - 0.5) * 2.0;
	albedo *= 1.0 - 0.09 * uneven;
	albedo *= mix(vec3(1.0), vec3(1.03, 0.97, 0.94), clamp(uneven, 0.0, 1.0) * 0.6);
	// Redness, where skin is thin and blood shows: shows less through a dark skin. The painted face already has a
	// blush (its cheeks 5 a* over its forehead, FFHQ's median is 3): there the amount is centred on it, a low redness
	// taking some off (at the same luminance), a high one adding (FACE_BLUSH_PAINTED, FACE_REDNESS_GAIN).
	float amount = base_redness + skin_detail.w * mix(0.85, FACE_REDNESS_GAIN, smile_map) - smile_map * FACE_BLUSH_PAINTED;
	float red = region.r * clamp(amount, -1.0, 1.0) * mix(1.0, 0.35, melanin);
	red *= 0.8 + 0.4 * detail_noise(uv * 60.0 + seed * 3.0);
	albedo = red >= 0.0 ? mix(albedo, albedo * vec3(1.06, 0.8, 0.8), red) : mix(albedo, albedo * vec3(0.794, 1.056, 1.056), -red);
	// The lips, darker and redder than the painted ones (less so on a dark skin, whose lips are near its tone).
	if (uv.x > lip_box.x && uv.x < lip_box.z && uv.y > lip_box.y && uv.y < lip_box.w) {
		vec3 painted = texture(albedo_light, uv).rgb;
		float lip_red = (painted.r - painted.g) / (painted.r + painted.g + painted.b + 1e-4);
		float lip = (1.0 - region.a) * smoothstep(0.29, 0.34, lip_red) * smoothstep(lip_box.y, lip_box.y + 0.012, uv.y);
		albedo = mix(albedo, albedo * lip_tint, lip * mix(1.0, 0.5, melanin));
	}
	// Shadows under the eyes: darker, a little violet.
	albedo = mix(albedo, albedo * vec3(0.8, 0.74, 0.8), region.b * skin_marks.x * 0.85);
	if (spots) {
		// Freckles: melanin dots, denser where the sun reaches; not on a dark skin, which they would not show on.
		// Freckles come in clusters: denser here, sparser there.
		float cluster = smoothstep(0.25, 0.75, detail_noise(uv * 14.0 + seed * 9.0));
		float freckle_density = clamp(skin_detail.x * region.g * (0.6 + 0.9 * cluster), 0.0, 0.95) * region.a;
		vec2 freckle = detail_spots(uv, freckle_scale, freckle_density, 0.42, seed);
		// Darkest in red: the skin's light scattering under it smears the red channel, which kept freckles orange
		// (centre over ring 0.97 / 0.86 / 0.76) where a photo's are a neutral brown (0.92 / 0.89 / 0.87); now 0.89 /
		// 0.88 / 0.87.
		vec3 melanin_dot = albedo * vec3(0.3, 0.6, 0.65);
		albedo = mix(albedo, melanin_dot, freckle.x * freckle_darkness * (0.55 + 0.45 * freckle.y) * mix(1.0, 0.3, melanin));
		// Moles: few, larger, darker, anywhere marks are allowed.
		vec2 mole = detail_spots(uv, mole_scale, skin_detail.y * 0.22 * region.a, 0.11, seed + 0.37);
		albedo = mix(albedo, albedo * vec3(0.42, 0.3, 0.24), mole.x * (0.7 + 0.3 * mole.y));
	}
	return albedo;
}

// The expression lines' slope (tangent space, -1..1), at this person's amount.
vec2 skin_details_slope(vec2 uv) {
	vec2 slope = (texture(wrinkle_texture, uv).rg * 2.0 - 1.0) * skin_detail.z;
	if (smile_map > 0.5) {
		vec4 s = texture(smile_texture, uv) * 2.0 - 1.0;
		float smiling = clamp(face_motion.x, 0.0, 1.0);
		slope += s.rg * smiling + s.ba * skin_marks.w * mix(dimple_at_rest, 1.0, smiling);
	}
	return slope;
}

// How much light reaches the skin, 0..1: a smile's folds and dimples are a little in shadow.
float skin_details_occlusion(vec2 uv) {
	if (smile_map < 0.5) {
		return 1.0;
	}
	vec4 s = texture(smile_texture, uv) * 2.0 - 1.0;
	float smiling = clamp(face_motion.x, 0.0, 1.0);
	float crease = length(s.rg) * smiling + length(s.ba) * skin_marks.w * mix(dimple_at_rest, 1.0, smiling);
	return 1.0 - smile_occlusion * clamp(crease, 0.0, 1.0);
}
