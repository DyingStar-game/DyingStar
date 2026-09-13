/*
	-------------------------------------------------------------
	PLANET SURFACE — STOCHASTIC HEX-TILING (Mikkelsen's adaptation)
	-------------------------------------------------------------
	Kills the visible repetition of a seamless tile texture over a whole planet:
	the surface is covered by a virtual hexagonal grid, every hex vertex gets a
	random offset + rotation of the texture, and each fragment blends the three
	hex vertices around it.  Heitz & Neyret's "high-performance by-example noise",
	in Morten S. Mikkelsen's "Practical Real-Time Hex-Tiling" (JCGT 2022) form.

	Origin: https://godotshaders.com/shader/stochastic-hex-tiling-mikkelsens-adaptation
	(nodding_sloth's Godot port of Mikkelsen's listings 1, 2, 4, 5, 6, 8).

	What this planet version changes compared to the original:
	  - TRIPLANAR instead of the world XZ plane (the ground is a sphere).
	  - Coordinates come from tri_pos (chunk_origin_mod + local vertex), never
	    from the float32 world position: at planetary distances world_pos has
	    ~0.5 m steps and shreds any texel smaller than that.  See
	    terrain_biome.gdshader for the full story.
	  - The hex grid is made PERIODIC over the 8192 m wrap of tri_pos so the
	    wrap boundary is invisible (an ordinary hex grid is never periodic on
	    a square; see the GRID_X note below).
	  - Hex-tiled normal, roughness and height maps (same three samples /
	    weights); height drives a one-step parallax and the blend bias.
	  - Integer hash instead of sin(): stable whatever the vertex index.

	MIT License

	Copyright (c) 2022 mmikk, noddingSloth

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
*/

shader_type spatial;
// cull_disabled (same reason as terrain_biome.gdshader): HEALPix chunks + skirts can
// face away from the camera; cull_back would punch black holes in the ground.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

group_uniforms surface;
// The seamless texture.  Organic patterns (sand, dirt, gravel, regolith) hide the
// hex blend best.  Anisotropic: the ground is mostly seen at grazing angles.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
// Matching tangent-space normal map (OpenGL +Y).  Unset = flat.
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_strength : hint_range(0.0, 4.0, 0.05) = 1.0;
// Roughness map, hex-tiled with the same samples.  Unset = white (1.0), so
// `roughness` alone drives the result.  Read from `roughness_channel`: R for
// a plain *_rough map, G for an ORM (occlusion / roughness / metallic) map.
uniform sampler2D roughness_texture : hint_roughness_r, filter_linear_mipmap_anisotropic, repeat_enable;
uniform int roughness_channel : hint_enum("R", "G", "B", "A") = 0;
// Multiplies the roughness map (1.0 = map as is).
uniform float roughness : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float metallic  : hint_range(0.0, 1.0, 0.01) = 0.0;
// Height map (grayscale, white = high), hex-tiled with the same samples.  Used
// twice: as a one-step parallax (height_scale, metres of relief: 0 = off) and
// as the blend bias between the three hex samples (height_blend: 1 = the
// higher tile wins the transition, 0 = Mikkelsen's luminance heuristic).
// Without a map the texture is white → no parallax shift, flat blend bias.
uniform sampler2D height_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float height_scale : hint_range(0.0, 0.5, 0.005) = 0.05;
uniform float height_blend : hint_range(0.0, 1.0, 0.01) = 1.0;
// Tint the texture by the vertex colour (the biome colour on terrain chunks).
// 0 = pure texture, 1 = texture * COLOR.
uniform float vertex_color_strength : hint_range(0.0, 1.0, 0.01) = 0.0;

group_uniforms hex_tiling;
// Texture repeats per metre (0.25 = one tile every 4 m).  Snapped to 1/4096 so
// the pattern is periodic over the 8192 m wrap (see snap_scale).
uniform float tile_scale : hint_range(0.001, 8.0, 0.001) = 0.25;
// Random rotation of the texture in each hex tile.
// 0.0 = none (textures with parallel lines, bricks), 1.0 = full ±180° (organic).
uniform float rot_strength : hint_range(0.0, 1.0, 0.01) = 0.5;
// Restores the contrast lost by blending three samples.
// 0.50 = raw blend (blurry), 0.75 = Mikkelsen's default, 0.99 = grid becomes visible.
uniform float contrast_adjust : hint_range(0.01, 0.99, 0.01) = 0.75;
// Triplanar axis selection sharpness (higher = narrower blend at plane changes).
uniform float triplanar_sharpness : hint_range(1.0, 16.0, 0.1) = 4.0;

// Chunk origin wrapped to WRAP metres, set per chunk by planet_terrain.gd
// (fposmod(chunk_center, 8192)).  tri_pos = chunk_origin_mod + VERTEX stays
// below ~8300 m → sub-millimetre float32 precision at every tiling scale.
instance uniform vec3 chunk_origin_mod;
// Must match `_wrap` in planet_terrain.gd.
const float WRAP = 8192.0;

/*
	Periodicity of the hex grid over the wrap.
	Every component of tri_pos jumps by WRAP at the wrap boundary, so a plane's
	UV jumps by D = WRAP * s along both of its axes.  The blend must be identical
	on both sides, which means the hex LATTICE must be D-periodic in x AND in y.
	A regular triangular lattice never is (its x period is 1/(2√3), its y period
	is 1/2 — irrational ratio), so the grid is squeezed along x by GRID_X so that
	its x period becomes 2/7 (GRID_X = (7/2) / (2√3) ≈ 1.0104: a 1 % anisotropy
	of the blend hexagons, invisible).  With D a multiple of 2 both periods
	divide D: 2 = 7 × (2/7) = 4 × (1/2).  The TEXTURE is untouched (only the
	grid coordinate is squeezed) and only needs D integer.
	Hence the snap: s = k / 4096  →  D = 2k, and in hex-vertex indices one
	period of D is (7k, 0) along x and (-4k, 8k) along y (see canon_id()).
*/
const float TWO_SQRT3 = 3.46410162;          // 2√3
const float GRID_X = 3.5 / TWO_SQRT3;        // 1.01036297
const float SNAP = 4096.0;

varying vec3 world_normal;
varying vec3 tri_pos;    // chunk_origin_mod + chunk-local vertex (wrapped, precise)
varying vec3 local_pos;  // chunk-local vertex only — for derivatives (smallest = most precise)

// Tiling scale snapped so WRAP * s is an even integer (see above).
float snap_scale(float raw) {
	return max(round(raw * SNAP), 1.0) / SNAP;
}

/*
	-------------------------------------------------------------
	TRANSLATED FROM MIKKELSEN'S PAPER (Appendix Listings 1, 2, 4, 5, 6, 8)
	-------------------------------------------------------------
*/

// st is the grid-space coordinate of the fragment INSIDE its 2×2 period cell
// (0 ≤ st < 2, already squeezed by GRID_X).  Vertex indices are relative to
// the cell; the caller adds the cell's lattice offset.
void TriangleGrid(out float w1, out float w2, out float w3,
		out ivec2 vertex1, out ivec2 vertex2, out ivec2 vertex3,
		vec2 st) {
	// Scaling of the input
	st *= TWO_SQRT3;

	// Skew input space into simplex triangle grid.
	// GLSL mat2 is column-major, so this is transposed from HLSL.
	mat2 gridToSkewedGrid = mat2(vec2(1.0, 0.0), vec2(-0.57735027, 1.15470054));
	vec2 skewedCoord = gridToSkewedGrid * st;

	ivec2 baseId = ivec2(floor(skewedCoord));
	vec3 temp = vec3(fract(skewedCoord), 0.0);
	temp.z = 1.0 - temp.x - temp.y;

	float s = step(0.0, -temp.z);
	float s2 = 2.0 * s - 1.0;

	w1 = -temp.z * s2;
	w2 = s - temp.y * s2;
	w3 = s - temp.x * s2;

	vertex1 = baseId + ivec2(int(s), int(s));
	vertex2 = baseId + ivec2(int(s), int(1.0 - s));
	vertex3 = baseId + ivec2(int(1.0 - s), int(s));
}

// Hex-vertex centre in st space (un-squeezed).
vec2 MakeCenST(ivec2 Vertex) {
	mat2 invSkewMat = mat2(vec2(1.0, 0.0), vec2(0.5, 1.0 / 1.15470054));
	return (invSkewMat * vec2(Vertex)) / TWO_SQRT3 / vec2(GRID_X, 1.0);
}

// Floor division for ints (GLSL `/` truncates toward zero).
int floor_div(int a, int b) {
	int q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
	return q;
}

// Fold a global hex-vertex index onto the wrap period: the lattice generated
// by (7k, 0) and (-4k, 8k).  Two vertices that differ by one wrap get the
// same hash → same offset, same rotation → seamless across the wrap.
ivec2 canon_id(ivec2 v, int k) {
	int py = 8 * k;
	int b = floor_div(v.y, py);
	v -= b * ivec2(-4 * k, py);
	int px = 7 * k;
	v.x -= floor_div(v.x, px) * px;
	return v;
}

// PCG hash (Jarzynski & Olano) — exact for any index, unlike fract(sin()).
uint pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

// Three independent [0, 1) values per hex vertex: xy = UV offset, z = rotation.
vec3 hash3(ivec2 p) {
	uint h1 = pcg(uint(p.x) + pcg(uint(p.y)));
	uint h2 = pcg(h1);
	uint h3 = pcg(h2);
	return vec3(uvec3(h1, h2, h3) >> 8u) * (1.0 / 16777216.0);
}

// Random rotation of the tile; hash-driven instead of Mikkelsen's
// abs(x*y)+abs(x+y) formula, whose float32 product breaks on large indices.
mat2 LoadRot2x2(float h, float rotStrength) {
	float angle = (h * 2.0 - 1.0) * PI * rotStrength;   // ±π × strength
	float cs = cos(angle);
	float si = sin(angle);
	return mat2(vec2(cs, si), vec2(-si, cs));
}

vec3 Gain3(vec3 x, float r) {
	// Increase contrast when r > 0.5 and reduce contrast if less.
	float k = log(1.0 - r) / log(0.5);
	vec3 s = 2.0 * step(vec3(0.5), x);
	vec3 m = 2.0 * (1.0 - s);

	vec3 res = 0.5 * s + 0.25 * m * pow(max(vec3(0.0), s + x * m), vec3(k));
	return res / (res.x + res.y + res.z);
}

// Split one wrapped coordinate p (metres) into its 2-unit hex period cell and
// the in-cell st offset, in integer arithmetic so the split is exact whatever
// the tiling scale (st = p * k / 4096; one cell = 8192 / k metres).
void split_axis(float p, int k, out int cell, out float st) {
	float pf = floor(p);
	int num = int(pf) * k;                 // st * 4096, exact
	int c = floor_div(num, 8192);
	float f = float(num - c * 8192) * (1.0 / SNAP)
			+ (p - pf) * (float(k) * (1.0 / SNAP));   // [0, 2 + s)
	if (f >= 2.0) {
		f -= 2.0;
		c += 1;
	}
	cell = c;
	st = f;
}

/*
	Hex grid for one plane: the three tile UVs around the fragment, their
	rotations and the raw triangle weights.
	  p        plane coordinate of the fragment (two components of tri_pos, metres)
	  s, k     snapped tiling scale and its integer numerator (s = k / 4096)
*/
void hex_grid(vec2 p, float s, int k, float rotStrength,
		out vec2 st1, out vec2 st2, out vec2 st3,
		out mat2 rot1, out mat2 rot2, out mat2 rot3, out vec3 w) {
	// Fragment → period cell + precise in-cell coordinate.
	ivec2 cell;
	vec2 st;
	split_axis(p.x, k, cell.x, st.x);
	split_axis(p.y, k, cell.y, st.y);

	// Get triangle info on the squeezed grid coordinate.
	ivec2 vertex1, vertex2, vertex3;
	TriangleGrid(w.x, w.y, w.z, vertex1, vertex2, vertex3, st * vec2(GRID_X, 1.0));

	// Cell-relative → global vertex index (one cell = (7,0) along x, (-4,8) along y),
	// then folded onto the wrap period.
	ivec2 cell_off = cell.x * ivec2(7, 0) + cell.y * ivec2(-4, 8);
	vec3 h1 = hash3(canon_id(vertex1 + cell_off, k));
	vec3 h2 = hash3(canon_id(vertex2 + cell_off, k));
	vec3 h3 = hash3(canon_id(vertex3 + cell_off, k));

	rot1 = LoadRot2x2(h1.z, rotStrength);
	rot2 = LoadRot2x2(h2.z, rotStrength);
	rot3 = LoadRot2x2(h3.z, rotStrength);

	// Centres stay cell-relative: the cell origin is an even integer in st,
	// i.e. a whole number of texture repeats, so it can be dropped — that is
	// what keeps the sampled UV small and float32-precise.
	vec2 cen1 = MakeCenST(vertex1);
	vec2 cen2 = MakeCenST(vertex2);
	vec2 cen3 = MakeCenST(vertex3);

	st1 = (rot1 * (st - cen1)) + cen1 + h1.xy;
	st2 = (rot2 * (st - cen2)) + cen2 + h2.xy;
	st3 = (rot3 * (st - cen3)) + cen3 + h3.xy;
}

// Final blend weights: triangle weights sharpened, biased by D (the height or
// luminance of each sample, so the "higher" tile wins the transition), then
// contrast-restored.
vec3 hex_weights(vec3 D, vec3 w, float r) {
	float g_fallOffContrast = 0.6; // Mikkelsen's defaults
	float g_exp = 7.0;

	D = mix(vec3(1.0), D, g_fallOffContrast);
	vec3 W = D * pow(w, vec3(g_exp));
	W /= (W.x + W.y + W.z);

	// Apply contrast curve
	if (r != 0.5) {
		W = Gain3(W, r);
	}
	return W;
}

// Blended height alone (parallax pre-pass): grid + three height taps.
float hex_height(vec2 p, vec2 dSTdx, vec2 dSTdy, float s, int k, float rotStrength, float r) {
	vec2 st1, st2, st3;
	mat2 rot1, rot2, rot3;
	vec3 w;
	hex_grid(p, s, k, rotStrength, st1, st2, st3, rot1, rot2, rot3, w);
	vec3 H = vec3(textureGrad(height_texture, st1, rot1 * dSTdx, rot1 * dSTdy).r,
	              textureGrad(height_texture, st2, rot2 * dSTdx, rot2 * dSTdy).r,
	              textureGrad(height_texture, st3, rot3 * dSTdx, rot3 * dSTdy).r);
	vec3 W = hex_weights(H, w, r);
	return dot(W, H);
}

/*
	One hex-tiled plane, all maps.
	  p        plane coordinate of the fragment (two components of tri_pos, metres)
	  dpdx/y   screen derivatives of the same two components (from local_pos)
	  view_t   view direction (fragment → camera, world) projected on the plane
	Returns the blended albedo; nxy gets the blended tangent-space normal xy,
	rough the blended roughness.
*/
vec3 hex_plane(vec2 p, vec2 dpdx, vec2 dpdy, vec2 view_t, float s, int k,
		float rotStrength, float r, out vec2 nxy, out float rough) {
	// Texture-space derivatives for mipmapping (before manipulating UVs).
	vec2 dSTdx = dpdx * s;
	vec2 dSTdy = dpdy * s;

	// Parallax (offset-limited, one step): the point actually seen sits where the
	// relief meets the view ray, shifted toward the camera by the height.  Done
	// in metres on the plane coordinate, so it needs no tangent frame and no
	// per-plane sign juggling.  1/(V.N) is dropped on purpose (no swimming at
	// grazing angles).
	if (height_scale > 0.0) {
		float h = hex_height(p, dSTdx, dSTdy, s, k, rotStrength, r);
		p += view_t * ((h - 0.5) * height_scale);
	}

	vec2 st1, st2, st3;
	mat2 rot1, rot2, rot3;
	vec3 w;
	hex_grid(p, s, k, rotStrength, st1, st2, st3, rot1, rot2, rot3, w);

	// Fetch input textures using explicit derivatives to prevent seam artifacts.
	vec2 g1x = rot1 * dSTdx, g1y = rot1 * dSTdy;
	vec2 g2x = rot2 * dSTdx, g2y = rot2 * dSTdy;
	vec2 g3x = rot3 * dSTdx, g3y = rot3 * dSTdy;
	vec4 c1 = textureGrad(albedo_texture, st1, g1x, g1y);
	vec4 c2 = textureGrad(albedo_texture, st2, g2x, g2y);
	vec4 c3 = textureGrad(albedo_texture, st3, g3x, g3y);

	// Blend bias: luminance (Mikkelsen) or real height, per height_blend.
	vec3 Lw = vec3(0.299, 0.587, 0.114);
	vec3 D = vec3(dot(c1.rgb, Lw), dot(c2.rgb, Lw), dot(c3.rgb, Lw));
	if (height_blend > 0.0) {
		vec3 H = vec3(textureGrad(height_texture, st1, g1x, g1y).r,
		              textureGrad(height_texture, st2, g2x, g2y).r,
		              textureGrad(height_texture, st3, g3x, g3y).r);
		D = mix(D, H, height_blend);
	}
	vec3 W = hex_weights(D, w, r);

	// Normal map: same samples, same weights.  Godot normal maps are OpenGL
	// (+Y = image top) while the plane's v axis runs down the image, so y is
	// flipped; then the tile was rotated by rot in UV space, so its gradient
	// rotates back by rotᵀ.
	const vec2 FLIP_V = vec2(1.0, -1.0);
	vec2 n1 = transpose(rot1) * ((textureGrad(normal_texture, st1, g1x, g1y).xy * 2.0 - 1.0) * FLIP_V);
	vec2 n2 = transpose(rot2) * ((textureGrad(normal_texture, st2, g2x, g2y).xy * 2.0 - 1.0) * FLIP_V);
	vec2 n3 = transpose(rot3) * ((textureGrad(normal_texture, st3, g3x, g3y).xy * 2.0 - 1.0) * FLIP_V);
	nxy = W.x * n1 + W.y * n2 + W.z * n3;

	// Roughness: same samples, same weights, one channel.
	vec4 r1 = textureGrad(roughness_texture, st1, g1x, g1y);
	vec4 r2 = textureGrad(roughness_texture, st2, g2x, g2y);
	vec4 r3 = textureGrad(roughness_texture, st3, g3x, g3y);
	rough = W.x * r1[roughness_channel] + W.y * r2[roughness_channel] + W.z * r3[roughness_channel];

	// Blend the 3 samples together using calculated weights
	return W.x * c1.rgb + W.y * c2.rgb + W.z * c3.rgb;
}

/*
	-------------------------------------------------------------
	PLANET SPATIAL IMPLEMENTATION
	-------------------------------------------------------------
*/

void vertex() {
	// CUSTOM0 is zero on terrain vertices and holds the inverse skirt drop on
	// skirt vertices, so the texture stays continuous down the skirts.
	vec3 surface = VERTEX + CUSTOM0.xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	tri_pos      = chunk_origin_mod + surface;
	local_pos    = surface;
}

void fragment() {
	// Triplanar weights from the geometric normal.
	vec3 n = pow(abs(world_normal), vec3(triplanar_sharpness));
	n /= (n.x + n.y + n.z);

	float s = snap_scale(tile_scale);
	int k = int(round(s * SNAP));

	// Derivatives once, in uniform control flow, from the chunk-local vertex:
	// chunk_origin_mod is constant per instance so d(tri_pos) == d(local_pos),
	// and local_pos is the smallest (most precise) quantity available.  Every
	// texture fetch below is textureGrad, so the per-plane branches are safe.
	vec3 dpx = dFdx(local_pos);
	vec3 dpy = dFdy(local_pos);

	// View direction fragment → camera, world space, from the view-space VERTEX
	// (camera-relative, so float32-precise at astronomic world positions).
	vec3 view_w = normalize(mat3(INV_VIEW_MATRIX) * (-VERTEX));

	vec3 albedo = vec3(0.0);
	vec3 delta = vec3(0.0);   // world-space normal perturbation
	float rough = 0.0;
	vec2 nt;
	float rt;
	// Planes with a negligible weight are skipped: a fragment usually needs one
	// plane, two near an edge, three only in the corners.
	if (n.x > 0.002) {
		albedo += hex_plane(tri_pos.yz, dpx.yz, dpy.yz, view_w.yz, s, k, rot_strength, contrast_adjust, nt, rt) * n.x;
		delta  += vec3(0.0, nt.x, nt.y) * n.x;
		rough  += rt * n.x;
	}
	if (n.y > 0.002) {
		albedo += hex_plane(tri_pos.xz, dpx.xz, dpy.xz, view_w.xz, s, k, rot_strength, contrast_adjust, nt, rt) * n.y;
		delta  += vec3(nt.x, 0.0, nt.y) * n.y;
		rough  += rt * n.y;
	}
	if (n.z > 0.002) {
		albedo += hex_plane(tri_pos.xy, dpx.xy, dpy.xy, view_w.xy, s, k, rot_strength, contrast_adjust, nt, rt) * n.z;
		delta  += vec3(nt.x, nt.y, 0.0) * n.z;
		rough  += rt * n.z;
	}

	// Perturb the TRUE geometric normal with each plane's tangent gradient mapped
	// onto its two world axes (never rebuild the normal from the planes: that
	// warps it toward the dominant axis — see terrain_biome.gdshader).
	vec3 shaded_normal = normalize(world_normal + delta * normal_strength);

	ALBEDO    = albedo * mix(vec3(1.0), COLOR.rgb, vertex_color_strength);
	ROUGHNESS = clamp(rough * roughness, 0.0, 1.0);
	METALLIC  = metallic;
	NORMAL    = normalize((VIEW_MATRIX * vec4(shaded_normal, 0.0)).xyz);
}
