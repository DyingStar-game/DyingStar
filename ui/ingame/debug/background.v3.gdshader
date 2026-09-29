shader_type canvas_item;

// --- Paramètres par instance (à définir via set_instance_shader_parameter) ---
instance uniform vec2 rect_size;
instance uniform float instance_seed = 0.0; // Conseillé : randf() * 1000.0
instance uniform vec4 corner_cuts = vec4(0.0); // TL, TR, BR, BL (px, coupe à 45°)

// --- Paramètres partagés ---
uniform vec4 background_color : source_color;
uniform vec3 yellow_base : source_color;
uniform vec3 yellow_darker : source_color;
uniform sampler2DArray background_textures : source_color, filter_nearest;

group_uniforms corner_cut;
uniform float piece_gap = 2.0;  // vide entre la forme et la pièce détachée
uniform float cut_round = 3.0;  // arrondi des extrémités de la coupe
group_uniforms;

// --- Réglages des cassures ---
const float CORNER_RADIUS = 4.0;
const vec2 CORNER_DIRS[4] = vec2[4](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(1.0, 1.0), vec2(-1.0, 1.0));
const float BREAK_MARGIN  = 15.0; // Distance minimale aux coins
const float MIN_EDGE_LEN  = 40.0; // Longueur de bord minimale pour avoir des cassures
const float BREAK_ZONE    = 4.0; // Profondeur (px) où la cassure retire le fond
const int   MAX_BREAKS    = 4;    // Maximum de cassures par bord

// Hachage déterministe (0..1). Garder des graines modestes (< ~1000)
// pour éviter les pertes de précision de sin() sur certains GPU.
float random_from_seed(float seed) {
    return fract(sin(seed * 12.9898) * 43758.5453);
}

// Profil d'UNE cassure : 1 à 4 trous, chacun suivi d'un îlot jaune.
// Retourne 0.0 dans un trou, 1.0 ailleurs.
float get_complex_break_profile(float current, float center, float break_seed) {
    float dist_to_center = abs(current - center);
    int total_voids = 1 + int(random_from_seed(break_seed * 11.11) * 4.0);
    float cursor = 0.0;

    for (int i = 0; i < 4; i++) {
        if (i >= total_voids) break;

        float segment_seed = break_seed + float(i) * 54.32;
        float void_width   = 2.0 + floor(random_from_seed(segment_seed * 2.1) * 4.0);
        float yellow_width = 2.0 + floor(random_from_seed(segment_seed * 7.8) * 4.0);

        if (dist_to_center >= cursor && dist_to_center < cursor + void_width) {
            return 0.0;
        }
        cursor += void_width;

        if (dist_to_center >= cursor && dist_to_center < cursor + yellow_width) {
            return 1.0;
        }
        cursor += yellow_width;
    }
    return 1.0;
}

// Masque de cassure pour UN bord.
// along  : position du pixel le long du bord (y pour gauche/droite, x pour haut/bas)
// length : longueur du bord
// side_seed : graine propre à ce bord
// Nombre de cassures : de 0 à max_allowed (croît avec le log2 de la longueur).
float evaluate_side_breaks(float along, float length, float side_seed) {
    float usable = length - BREAK_MARGIN * 2.0;
    if (length < MIN_EDGE_LEN || usable <= 0.0) {
        return 1.0;
    }

    int max_allowed = min(1 + int(floor(log2(length / MIN_EDGE_LEN))), MAX_BREAKS);
    int count = int(random_from_seed(side_seed * 87.65) * float(max_allowed + 1)); // 0..max_allowed

    float mask = 1.0;
    for (int i = 0; i < MAX_BREAKS; i++) {
        if (i >= count) break;

        float break_seed = side_seed + float(i) * 123.45;
        float break_pos  = BREAK_MARGIN + random_from_seed(break_seed) * usable;
        mask *= get_complex_break_profile(along, break_pos, break_seed);
    }
    return mask;
}

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i + vec2(0.0, 0.0)), hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float sd_rounded_rect(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

float sd_round_intersect(float d1, float d2, float r) {
    vec2 u = max(vec2(r + d1, r + d2), vec2(0.0));
    return min(-r, max(d1, d2)) + length(u);
}

void fragment() {
    vec2 size = rect_size.x > 0.0 ? rect_size : vec2(100.0);
    vec2 pixel_pos = UV * size;
    vec2 center_pos = pixel_pos - size * 0.5;

    // --- Texture choisie aléatoirement par instance ---
    ivec3 tex_dim = textureSize(background_textures, 0);
    int layer = min(int(random_from_seed(instance_seed * 3.71) * float(tex_dim.z)), tex_dim.z - 1);

    vec2 from_top_right = vec2(size.x - pixel_pos.x, pixel_pos.y);
    vec2 bg_uv = vec2(1.0 - from_top_right.x / float(tex_dim.x),
                      from_top_right.y / float(tex_dim.y));
    vec4 texture_bg_color = texture(background_textures, vec3(bg_uv, float(layer)));

    // --- Forme ---
	// --- Rectangle Simple ---
    //float dist = sd_rounded_rect(center_pos, size * 0.5 - vec2(1.0), CORNER_RADIUS);
	// --- Rectangle avec cassures d'angle ---
	vec2 inner_bounds = size * 0.5 - vec2(1.0);
	float d_rect = sd_rounded_rect(center_pos, inner_bounds, CORNER_RADIUS);
	float dist = d_rect;   // forme principale (coins coupés)
	float d_piece = 1e5;   // pièces détachées

	for (int i = 0; i < 4; i++) {
	    float c = corner_cuts[i];
	    if (c <= 0.0) continue;
	    // Distance signée à la diagonale : positive du côté retiré
	    float sd_cut = (dot(CORNER_DIRS[i], center_pos) - (inner_bounds.x + inner_bounds.y - c)) * 0.70710678;
	    dist    = sd_round_intersect(dist, sd_cut, cut_round);                      // forme restante
	    d_piece = min(d_piece, sd_round_intersect(d_rect, piece_gap - sd_cut, cut_round)); // morceau retiré
	}

    // --- Bordure jaune bruitée ---
    float noise_val = noise(UV * 20.0);
    vec3 mixed_yellow = mix(yellow_darker, yellow_base, noise_val);
    vec4 border_color = vec4(mixed_yellow, 0.40);

    // --- Cassures sur les 4 bords (graine différente par bord) ---
    float break_mask = 1.0;
    if (pixel_pos.x < BREAK_ZONE)
        break_mask *= evaluate_side_breaks(pixel_pos.y, size.y, instance_seed);           // gauche
    if (size.x - pixel_pos.x < BREAK_ZONE)
        break_mask *= evaluate_side_breaks(pixel_pos.y, size.y, instance_seed + 101.7);   // droite
    if (pixel_pos.y < BREAK_ZONE)
        break_mask *= evaluate_side_breaks(pixel_pos.x, size.x, instance_seed + 203.4);   // haut
    if (size.y - pixel_pos.y < BREAK_ZONE)
        break_mask *= evaluate_side_breaks(pixel_pos.x, size.x, instance_seed + 305.1);   // bas

    float ring = smoothstep(-2.0, -1.0, dist);
	vec4 inner_color = mix(texture_bg_color, background_color, ring * (1.0 - break_mask));

    // --- Masques (smoothstep avec edge0 < edge1, comportement défini) ---
    float inside_mask = 1.0 - smoothstep(0.0, 1.0, dist);
    float border_mask = smoothstep(-2.0, 0.0, dist) - smoothstep(0.0, 1.0, dist);
    border_mask *= break_mask;

    vec4 final_color = mix(vec4(0.0), inner_color, inside_mask);
    final_color = mix(final_color, border_color, border_mask);
	
	float piece_mask = 1.0 - smoothstep(0.0, 1.0, d_piece);
	final_color = mix(final_color, border_color, piece_mask); // pleine, même couleur que la bordure

    COLOR = final_color;
}