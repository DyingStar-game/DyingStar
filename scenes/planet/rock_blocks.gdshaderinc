/*
	ROCK BLOCKS — rocky terrain below the mesh pitch.
	Shared by planet_surface.gdshader and terrain_biome.gdshader.

	A rocky_terrain zone (QGIS) is a RockFieldRelief field: its blocks of 75 m
	and more are geometry (the sampler); the 1-20 m blocks inside them are drawn
	here. The chunk bakes, per vertex, into CUSTOM1: x = the field's intensity ×
	envelope, y = the small-block size (m), z = level + 8 × type (the QGIS style,
	RockFieldRelief.STYLES), w = the vertex's altitude (m) — zero outside every
	field, where the only cost is one branch. Each type has its own recipe:
	slabs / columnar / yardang / strata share the blocks below; chalk (Seven
	Sisters) is rock_chalk().

	The blocks are a 3D Voronoi of tri_pos (the surface slices it, so a block is
	never stretched by a projection and no two patterns overlap, whatever the
	slope or the latitude), with a whole number of cells per ROCK_WRAP (the
	8192 m wrap of tri_pos) so it never seams at the wrap. Every joint gets its
	own width and depth from the pair of blocks it separates: some are open
	cracks, most hairlines — rock, not grouted paving. Drawn as darkened joints,
	a bevel sloping into each joint, a slight tilt and shade per block. Integer
	hash only; no derivative (callers branch on CUSTOM1, a non-uniform condition).
*/

group_uniforms rock_blocks;
// How dark the deepest joint gets at full intensity (0 = invisible, 1 = black).
uniform float rock_joint_darkening : hint_range(0.0, 1.0, 0.01) = 0.4;
// Width of the widest joint, as a share of the block size (each joint draws
// 25-100 % of it).
uniform float rock_joint_width : hint_range(0.005, 0.3, 0.005) = 0.05;
// Strength of the bevel into the joints (normal tilt).
uniform float rock_bevel_strength : hint_range(0.0, 2.0, 0.05) = 0.7;
// Random tilt of each block's face (normal).
uniform float rock_tilt_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
// Brightness variation between blocks (±).
uniform float rock_block_contrast : hint_range(0.0, 0.5, 0.01) = 0.08;
// The blocks fade out between half and all of this many block sizes from the
// camera (6 m blocks, 25 → gone at 150 m): farther, they would alias.
uniform float rock_fade_blocks : hint_range(4.0, 100.0, 1.0) = 25.0;
group_uniforms rock_chalk;
// Chalk: height of the knobs of the lumpy surface, as a share of the crack size
// (the normal's relief; 0 = smooth).
uniform float chalk_lump_strength : hint_range(0.0, 0.5, 0.01) = 0.14;
// Chalk: how far the cracks wander, as a share of the crack size (above ~0.66
// the cracks fold into loops).
uniform float chalk_crack_wander : hint_range(0.0, 0.66, 0.01) = 0.6;
// Chalk: share of the crack network drawn as open cracks (the rest hairlines).
uniform float chalk_crack_share : hint_range(0.0, 1.0, 0.01) = 0.55;
// Chalk: how dark an open crack gets (0 = invisible, 1 = black).
uniform float chalk_crack_darkening : hint_range(0.0, 1.0, 0.01) = 0.55;
// Chalk: spacing of the flint bands on the walls (m).
uniform float chalk_band_spacing_m : hint_range(0.3, 10.0, 0.1) = 1.8;
// Chalk: how dark a flint band gets on a sheer wall (0 = none).
uniform float chalk_band_darkening : hint_range(0.0, 1.0, 0.01) = 0.5;
// Chalk: brightness variation of the rock (stains, ±).
uniform float chalk_stain_contrast : hint_range(0.0, 0.5, 0.01) = 0.1;
group_uniforms;

// Must match `_wrap` in planet_terrain.gd (tri_pos wraps every this many metres).
const float ROCK_WRAP = 8192.0;

uint rock_pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

int rock_floor_div(int a, int b) {
	int q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
	return q;
}

// A block cell's id, and three [0, 1) values from it: xyz = the feature point.
uint rock_id(ivec3 c) {
	return rock_pcg(uint(c.x) + rock_pcg(uint(c.y) + rock_pcg(uint(c.z) ^ 0x68E31DA4u)));
}

vec3 rock_jitter(uint id) {
	uint h1 = rock_pcg(id);
	uint h2 = rock_pcg(h1);
	uint h3 = rock_pcg(h2);
	return vec3(uvec3(h1, h2, h3) >> 8u) * (1.0 / 16777216.0);
}

float rock_unit(uint h) {
	return float(rock_pcg(h) >> 8u) * (1.0 / 16777216.0);
}

ivec3 rock_wrap(ivec3 c, int n) {
	return c - ivec3(rock_floor_div(c.x, n), rock_floor_div(c.y, n), rock_floor_div(c.z, n)) * n;
}

// [0, 1) value of lattice point c (wrapped to n per ROCK_WRAP) for seed s — one
// PCG per point: the noise below reads eight per octave.
float rock_lat(ivec3 c, int n, uint s) {
	ivec3 w = rock_wrap(c, n);
	uint un = uint(n);
	uint idx = uint(w.x) + un * (uint(w.y) + un * uint(w.z));
	return float(rock_pcg(idx ^ s) >> 8u) * (1.0 / 16777216.0);
}

/*
	Value noise in [0, 1) with its gradient (Inigo Quilez's analytic
	derivatives, quintic fade), periodic over ROCK_WRAP: [param p] in metres,
	n lattice cells per wrap. x = value, yzw = gradient per metre.
*/
vec4 rock_vnoised(vec3 p, int n, uint s) {
	float cs = ROCK_WRAP / float(n);
	vec3 x = p / cs;
	vec3 i = floor(x);
	vec3 f = x - i;
	ivec3 c = ivec3(i);
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float a = rock_lat(c, n, s);
	float b = rock_lat(c + ivec3(1, 0, 0), n, s);
	float cc = rock_lat(c + ivec3(0, 1, 0), n, s);
	float d = rock_lat(c + ivec3(1, 1, 0), n, s);
	float e = rock_lat(c + ivec3(0, 0, 1), n, s);
	float g = rock_lat(c + ivec3(1, 0, 1), n, s);
	float h = rock_lat(c + ivec3(0, 1, 1), n, s);
	float k = rock_lat(c + ivec3(1, 1, 1), n, s);
	float k0 = a;
	float k1 = b - a;
	float k2 = cc - a;
	float k3 = e - a;
	float k4 = a - b - cc + d;
	float k5 = a - cc - e + h;
	float k6 = a - b - e + g;
	float k7 = -a + b + cc - d + e - g - h + k;
	float v = k0 + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z
			+ k6 * u.z * u.x + k7 * u.x * u.y * u.z;
	vec3 grad = du * vec3(k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
			k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
			k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
	return vec4(v, grad / cs);
}

/*
	3D Voronoi edges (Inigo Quilez's two passes, 3×3×3 each), n cells per
	ROCK_WRAP on every axis. edge = distance to the nearest edge (cell units),
	en = unit direction from the fragment's block toward it, id1 / id2 = the
	two blocks it separates.
*/
void rock_voronoi(vec3 p, int n, out float edge, out vec3 en, out uint id1, out uint id2) {
	float cs = ROCK_WRAP / float(n);
	vec3 x = p / cs;
	vec3 ip = floor(x);
	vec3 f = x - ip;
	ivec3 ii = ivec3(ip);
	float md = 8.0;
	vec3 mr = vec3(0.0);
	ivec3 mg = ivec3(0);
	id1 = 0u;
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				ivec3 g = ivec3(i, j, k);
				uint id = rock_id(rock_wrap(ii + g, n));
				vec3 r = vec3(g) + rock_jitter(id) - f;
				float d = dot(r, r);
				if (d < md) {
					md = d;
					mr = r;
					mg = g;
					id1 = id;
				}
			}
		}
	}
	edge = 8.0;
	en = vec3(0.0);
	id2 = id1;
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				ivec3 g = mg + ivec3(i, j, k);
				uint id = rock_id(rock_wrap(ii + g, n));
				vec3 r = vec3(g) + rock_jitter(id) - f;
				vec3 dd = r - mr;
				float l2 = dot(dd, dd);
				if (l2 > 1e-5) {
					vec3 nd = dd * inversesqrt(l2);
					float e = dot(0.5 * (mr + r), nd);
					if (e < edge) {
						edge = e;
						en = nd;
						id2 = id;
					}
				}
			}
		}
	}
}

// Slabs / columnar / yardang / strata: Voronoi blocks with varied joints.
float rock_slabs(vec4 rk, vec3 tri, vec3 nrm, float amount, inout vec3 shaded_normal) {
	int n = max(int(round(ROCK_WRAP / rk.y)), 1);
	float edge;
	vec3 en;
	uint id1;
	uint id2;
	rock_voronoi(tri, n, edge, en, id1, id2);
	// The joint's own look, the same from both blocks (xor is symmetric):
	// mostly hairlines, now and then an open crack.
	float js = rock_unit(id1 ^ id2);
	float depth = js * js;
	float jw = rock_joint_width * mix(0.25, 1.0, js);
	float prof = smoothstep(0.0, jw, edge);
	float slope = 6.0 * (edge / jw) * (1.0 - edge / jw) * step(edge, jw);
	// Tangent toward the edge, and the block's tilt, both in the surface.
	vec3 te = en - nrm * dot(en, nrm);
	vec3 tilt = rock_jitter(id1 ^ 0x5bd1e995u) - 0.5;
	tilt -= nrm * dot(tilt, nrm);
	shaded_normal = normalize(shaded_normal
			+ (te * (slope * rock_bevel_strength * mix(0.3, 1.0, depth))
			+ tilt * (2.0 * rock_tilt_strength)) * amount);
	float shade = 1.0 + (rock_unit(id1 ^ 0x27d4eb2fu) - 0.5) * 2.0 * rock_block_contrast * amount;
	return shade * (1.0 - rock_joint_darkening * amount * mix(0.25, 1.0, depth) * (1.0 - prof));
}


/*
	Chalk (Seven Sisters): a lumpy surface (three octaves of noise bending the
	normal, never a flat facet), cracks that wander (the Voronoi of a position
	pushed along a low noise's gradient) of which only a share is open, the
	rest hairlines; on the walls, dotted flint bands following the altitude
	([param rk].w), wobbling a little.
*/
float rock_chalk(vec4 rk, vec3 tri, vec3 nrm, vec3 up, float amount, inout vec3 shaded_normal) {
	float s = rk.y;
	// Lumps: three octaves, 2 s down to s / 2.
	int n0 = max(int(round(ROCK_WRAP / (2.0 * s))), 1);
	vec4 l0 = rock_vnoised(tri, n0, 0x1234567u);
	vec4 l1 = rock_vnoised(tri, n0 * 2, 0x89abcdeu);
	vec4 l2 = rock_vnoised(tri, n0 * 4, 0x2468aceu);
	vec3 grad = (l0.yzw + 0.5 * l1.yzw + 0.25 * l2.yzw) * (2.0 * s * chalk_lump_strength);
	grad -= nrm * dot(grad, nrm);
	// Cracks: Voronoi of the position pushed along a low noise's gradient.
	float crack_cs = 1.5 * s;
	int nc = max(int(round(ROCK_WRAP / crack_cs)), 1);
	// The push is a gradient, so its own slope is the noise's curvature: one
	// octave two cracks wide, and wander ≤ 0.66 — beyond, the space folds and
	// the cracks close into loops.
	vec4 wn = rock_vnoised(tri, max(nc / 2, 1), 0x13579bdu);
	vec3 pw = tri + wn.yzw * (chalk_crack_wander * crack_cs * crack_cs);
	float edge;
	vec3 en;
	uint id1;
	uint id2;
	rock_voronoi(pw, nc, edge, en, id1, id2);
	float js = rock_unit(id1 ^ id2);
	float open_crack = step(js, chalk_crack_share);
	float cw = mix(0.012, 0.035, rock_unit(id1 ^ id2 ^ 0x9e3779b9u)) * mix(0.5, 1.0, open_crack);
	float crack = 1.0 - smoothstep(0.0, cw, edge);
	float vis = mix(0.18, 1.0, open_crack);
	vec3 te = en - nrm * dot(en, nrm);
	float bevel = 6.0 * (edge / cw) * (1.0 - edge / cw) * step(edge, cw);
	// Flint bands on the walls: dark nodule lines every chalk_band_spacing_m of
	// altitude, wobbling with the lumps, dotted by the finest octave.
	float steep = smoothstep(0.35, 0.75, 1.0 - abs(dot(nrm, up)));
	float t = (rk.w + (l0.x - 0.5) * 0.6 * chalk_band_spacing_m) / chalk_band_spacing_m;
	float ft = fract(t);
	float band = 1.0 - smoothstep(0.0, 0.07, min(ft, 1.0 - ft));
	band *= smoothstep(0.4, 0.62, l2.x) * steep;
	shaded_normal = normalize(shaded_normal - grad * amount
			+ te * (bevel * 0.5 * vis * amount));
	float stain = 1.0 + (l0.x - 0.5) * 2.0 * chalk_stain_contrast * amount;
	return stain * (1.0 - chalk_crack_darkening * vis * crack * amount)
			* (1.0 - chalk_band_darkening * band * amount);
}

/*
	The rock at a fragment: [param rk] = CUSTOM1, [param tri] = the wrapped
	triplanar position, [param nrm] = the geometric normal and [param up] the
	planet's up (world), [param dist] = camera distance (m). Returns the albedo
	factor (1 = none) and bends [param shaded_normal] (world space).
*/
float rock_blocks(vec4 rk, vec3 tri, vec3 nrm, vec3 up, float dist, inout vec3 shaded_normal) {
	if (rk.x <= 0.01 || rk.y <= 0.1) {
		return 1.0;
	}
	float fade_d = rock_fade_blocks * rk.y;
	float amount = clamp(rk.x, 0.0, 1.0) * (1.0 - smoothstep(0.5 * fade_d, fade_d, dist));
	if (amount <= 0.01) {
		return 1.0;
	}
	int rtype = int(rk.z + 0.5) / 8;
	if (rtype == 4) {
		return rock_chalk(rk, tri, nrm, up, amount, shaded_normal);
	}
	return rock_slabs(rk, tri, nrm, amount, shaded_normal);
}
