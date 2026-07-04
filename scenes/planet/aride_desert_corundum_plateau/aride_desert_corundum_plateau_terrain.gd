@tool
class_name ArideDesertCorundumPlateauTerrain
## Terrain module for the **aride_desert-corundum_plateau** biome.
##
## High plateaus of extremely hard rock. The walls are sharp and virtually
## unaffected by conventional erosion.
##
## Category: terrestrial.  Layer group: individual.

# ── Constants ──────────────────────────────────────────────────────

## Biome type string as defined in the QGIS catalogue.
const BIOME_TYPE := "aride_desert-corundum_plateau"
## Biome index in the catalogue (0-based).
const BIOME_INDEX := 91
## Category tag for grouping.
const CATEGORY := "terrestrial"

## Feature size of the large iron-rich blotches, in metres.
const IRON_BLOTCH_M := 2800.0
## Feature size of the finer iron streaks, in metres.
const IRON_STREAK_M := 700.0
## Iron-poor tone (cool milky white) and iron-rich tone (warm ochre-yellow).
const MILKY := Color(0.905, 0.880, 0.820)
const IRON  := Color(0.815, 0.680, 0.410)


# ── Procedural crack network ───────────────────────────────────────
# The plateau is fractured into monolithic blocks by a network of deep,
# steep-walled cracks (see reference: milky corundum with iron impurities).
#
# crack_offset() is a PURE, DETERMINISTIC function of the surface direction
# only — it never reads height, time, or RNG state.  Because the client
# visual mesh (generate_mesh) and the server collision shape
# (generate_collision_shape) both call it with the SAME PlanetData params,
# the cracks are guaranteed bit-for-bit identical on both sides: any crack
# you can fall into on the server is visible on the client, and vice-versa.

## Return the height offset (≤ 0, in metres) the crack network carves at
## [param dir].  Zero when the point is on solid block, negative inside a
## crack with a flat floor and near-vertical walls (1 − t⁴ profile).
## [param radius]      — planet radius in metres (nominal sphere).
## [param spacing_m]   — approx. block size between cracks.
## [param width_m]     — crack width at the surface.
## [param depth_m]     — crack depth below the plateau surface.
## [param vtx_spacing_m] — the mesh's vertex spacing in metres (0 = disable
##   LOD fade).  When the vertices are too far apart to resolve a crack
##   (spacing approaching width_m) the carve FADES OUT instead of aliasing
##   into a spiky mess — this is what removed the flat-grey LOD1 band.
##   Pass 0 for the server collision grid so cracks always exist in physics.
static func crack_offset(dir: Vector3, radius: float,
		spacing_m: float, width_m: float, depth_m: float,
		vtx_spacing_m: float = 0.0) -> float:
	if spacing_m <= 0.0 or width_m <= 0.0 or depth_m <= 0.0:
		return 0.0
	# LOD: skip the crack entirely once the mesh is too coarse to represent it
	# (fewer than ~2 vertices across its width — it would only alias) and to let
	# coarse LODs avoid the expensive Voronoi.  But do NOT ramp the DEPTH with
	# LOD: a partial depth leaves the visual crack floor metres above the
	# full-depth PHYSICS floor (which always samples at full depth), so the
	# player ends up standing below the rendered surface.  Wherever the crack
	# IS drawn, it is drawn at full depth — so visual and physics agree.
	if vtx_spacing_m > 0.0 and vtx_spacing_m >= width_m * 0.5:
		return 0.0
	# Surface point expressed in Voronoi-cell units (1 cell ≈ spacing_m).
	var p := dir * (radius / spacing_m)
	var edge_cells := _voronoi_edge_distance(p)
	var d_m := edge_cells * spacing_m          # metres to nearest cell edge
	var half := width_m * 0.5
	if d_m >= half:
		return 0.0
	var t := d_m / half                        # 0 at crack centre, 1 at rim
	var t2 := t * t
	return -depth_m * (1.0 - t2 * t2)          # flat floor, steep walls (1 − t⁴)


## Deterministic per-cell jitter in [0,1)³ — the classic fract(sin(dot))
## hash.  Identical on client and server because it uses only IEEE doubles
## and no engine state.
static func _hash3(c: Vector3) -> Vector3:
	var x := sin(c.dot(Vector3(127.1, 311.7, 74.7))) * 43758.5453123
	var y := sin(c.dot(Vector3(269.5, 183.3, 246.1))) * 43758.5453123
	var z := sin(c.dot(Vector3(113.5, 271.9, 124.6))) * 43758.5453123
	return Vector3(x - floor(x), y - floor(y), z - floor(z))


## Distance (in cell units) from [param x] to the nearest Voronoi cell
## boundary — Inigo Quilez's 3D "Voronoi edges" algorithm.  The 2-sphere
## slices the 3D Voronoi diagram into polygonal blocks, producing the
## orthogonal monolithic-crack look on the surface.
static func _voronoi_edge_distance(x: Vector3) -> float:
	var n := x.floor()
	var f := x - n
	# Pass 1: locate the closest feature point.
	var mr := Vector3.ZERO
	var mg := Vector3.ZERO
	var md := 1.0e9
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var g := Vector3(i, j, k)
				var r := g + _hash3(n + g) - f
				var d := r.dot(r)
				if d < md:
					md = d
					mr = r
					mg = g
	# Pass 2: minimum distance to the edge between the closest point and
	# each of its neighbours.
	var edge := 1.0e9
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var g := mg + Vector3(i, j, k)
				var r := g + _hash3(n + g) - f
				var diff := r - mr
				if diff.dot(diff) > 1.0e-5:   # skip the closest cell itself
					edge = minf(edge, (0.5 * (mr + r)).dot(diff.normalized()))
	return edge


# ── Iron-impurity colouring ────────────────────────────────────────
# Milky corundum stained with iron gives a white↔yellow mottling.  We bake
# this into the vertex colour (albedo) as a pure function of direction, so
# it needs no shader change and only affects the corundum surface.
# Tuning constants (IRON_BLOTCH_M, MILKY, …) live in the constants section.

## Blend a corundum surface colour between milky-white and iron-yellow using
## two octaves of value noise.  [param base] (the biome colour) is folded in
## so tweaking the .tres still shifts the overall hue.
static func iron_tint(dir: Vector3, radius: float, base: Color) -> Color:
	var lo := MILKY.lerp(base, 0.35)
	var hi := IRON.lerp(base, 0.25)
	var blotch := _vnoise(dir * (radius / IRON_BLOTCH_M))
	var streak := _vnoise(dir * (radius / IRON_STREAK_M))
	var t := clampf(blotch * 0.7 + streak * 0.3, 0.0, 1.0)
	return lo.lerp(hi, t)


## Darken / warm the interior of a crack toward iron staining, proportional to
## how deep the carve is ([param crack_off] ≤ 0).  Solid blocks are unchanged.
static func crack_stain(col: Color, crack_off: float, crack_depth_m: float) -> Color:
	if crack_off >= 0.0 or crack_depth_m <= 0.0:
		return col
	var f := clampf(-crack_off / crack_depth_m, 0.0, 1.0)   # 0 at rim, 1 at floor
	var stain := IRON * 0.55                                # dark rusty shadow tone
	return col.lerp(stain, f * 0.6)


# ── Value noise (scalar, deterministic) ────────────────────────────
# Trilinearly-interpolated lattice noise built on the same _hash3 as the
# crack network, so client and server stay in lock-step.

static func _hash1(c: Vector3) -> float:
	return _hash3(c).x


static func _vnoise(p: Vector3) -> float:
	var i := p.floor()
	var f := p - i
	# Quintic smoothstep for C² continuity (no lattice creases).
	var w := f * f * f * (f * (f * 6.0 - Vector3(15, 15, 15)) + Vector3(10, 10, 10))
	var c000 := _hash1(i + Vector3(0, 0, 0))
	var c100 := _hash1(i + Vector3(1, 0, 0))
	var c010 := _hash1(i + Vector3(0, 1, 0))
	var c110 := _hash1(i + Vector3(1, 1, 0))
	var c001 := _hash1(i + Vector3(0, 0, 1))
	var c101 := _hash1(i + Vector3(1, 0, 1))
	var c011 := _hash1(i + Vector3(0, 1, 1))
	var c111 := _hash1(i + Vector3(1, 1, 1))
	var x00 := lerpf(c000, c100, w.x)
	var x10 := lerpf(c010, c110, w.x)
	var x01 := lerpf(c001, c101, w.x)
	var x11 := lerpf(c011, c111, w.x)
	var y0 := lerpf(x00, x10, w.y)
	var y1 := lerpf(x01, x11, w.y)
	return lerpf(y0, y1, w.z)
