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

# The plateau's colour — milky white stained iron-yellow — is no longer here:
# it is the catalogue rock "corundum_milky" (rocks.py), the planet's
# corundum_default_rock, shaded by RockImpurity like every other rock.


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
## crack: a box section, flat floor and vertical walls.
## [param radius]      — planet radius in metres (nominal sphere).
## [param spacing_m]   — approx. block size between cracks.
## [param width_m]     — crack width at the surface.
## [param depth_m]     — crack depth below the plateau surface.
## [param vtx_spacing_m] — the mesh's vertex spacing in metres (0 = disable
##   LOD fade).  When the vertices are too far apart to resolve a crack
##   (spacing approaching width_m) the carve FADES OUT instead of aliasing
##   into a spiky mess — this is what removed the flat-grey LOD1 band.
##   Pass 0 for the server collision grid so cracks always exist in physics.
## [param noise] — the planet's CrackNoise (PlanetData.crack_noise()): seed,
##   meander and rim noise. Null = the plain network (seed 0, straight edges).
static func crack_offset(dir: Vector3, radius: float,
		spacing_m: float, width_m: float, depth_m: float,
		vtx_spacing_m: float = 0.0, noise: CrackNoise = null) -> float:
	if spacing_m <= 0.0 or width_m <= 0.0 or depth_m <= 0.0:
		return 0.0
	# LOD: skip the crack entirely once the mesh is too coarse to represent it
	# (fewer than ~2 vertices across its width — it would only alias) and to let
	# coarse LODs avoid the expensive Voronoi.  But do NOT ramp the DEPTH with
	# LOD: a partial depth leaves the visual crack floor metres above the
	# full-depth PHYSICS floor (which always samples at full depth), so the
	# player ends up standing below the rendered surface.  Wherever the crack
	# IS drawn, it is drawn at full depth — so visual and physics agree.
	return crack_offset_from_edge(
		crack_edge_distance_m(dir, radius, spacing_m, width_m, vtx_spacing_m, noise),
		width_m, depth_m)


## Distance en mètres au bord de crack le plus proche, ou INF quand aucune crack n'est
## dessinée ici (paramètres nuls, ou LOD trop grossier).
##
## Scindé de [method crack_offset] pour que l'appelant garde la distance : le Voronoï 3D
## est la partie chère (deux passes 3×3×3, ~160 sin() par appel), et le calcul des
## normales l'évaluait CINQ fois par sommet — une au centre dans la boucle des sommets,
## quatre de plus pour le gradient. Or l'offset est nul dès que la distance dépasse la
## demi-largeur, et la distance à un bord est 1-lipschitzienne : un sommet assez loin
## d'une crack garantit que ses quatre points de gradient le sont aussi, donc que les
## quatre offsets valent zéro. Conserver la distance du centre permet de le savoir sans
## réévaluer quoi que ce soit.
##
## Le découpage est arithmétiquement neutre : mêmes opérations, même ordre, même
## float64. crack_offset() ci-dessus produit exactement ce qu'il produisait avant.
##
## Organic since the CrackNoise: the Voronoi is read at a warped point (the
## crack wanders) and the rim noise is taken off the distance (each rim is
## eaten on its own) — see [method _edge_distance].
static func crack_edge_distance_m(dir: Vector3, radius: float,
		spacing_m: float, width_m: float, vtx_spacing_m: float = 0.0,
		noise: CrackNoise = null) -> float:
	if spacing_m <= 0.0 or width_m <= 0.0:
		return INF
	# LOD: skip the crack entirely once the mesh is too coarse to represent it.
	if vtx_spacing_m > 0.0 and vtx_spacing_m >= width_m * 0.5:
		return INF
	var nz := noise if noise != null else CrackNoise.plain()
	if use_native_voronoi and nz.native != null:
		return nz.native.EdgeDistance(dir, radius, spacing_m, vtx_spacing_m)
	return _edge_distance(dir, radius, spacing_m, vtx_spacing_m, nz)


## The distance to the nearest rim line (m, before the width): the Voronoi
## edge distance at the meander-warped point, less the rim noise. The octaves
## are gated on the pitch floored at the finest chunk's. Reference of
## CrackVoronoiNative.EdgeDistance, same operations in the same order.
static func _edge_distance(dir: Vector3, radius: float, spacing_m: float, vtx_spacing_m: float,
		nz: CrackNoise) -> float:
	var eff := maxf(vtx_spacing_m, nz.finest_m)
	var q := nz.warp(dir * radius, dir, radius, eff)
	var d := _voronoi_gd(q / spacing_m, nz).w * spacing_m
	return d - nz.rim(dir, radius, eff)


## Which block of the network [param dir] stands on, for whoever draws the network
## as LINES rather than carving it (the star chart, from too high up for a mesh to
## hold a crack): [the point the Voronoi is read at, the feature point of the cell
## it falls in], both in cell units. Two directions on the same block answer the
## same feature point; where it changes between two of them, a crack runs between
## — along the plane halfway between the two feature points, which is where
## [method _edge_distance] reaches zero.
##
## The same warped point as [method _edge_distance], at full detail, so the lines
## wander as the cracks do. The rim noise is not in it: it eats the rims, it does
## not move the crack.
static func crack_cell(dir: Vector3, radius: float, spacing_m: float,
		noise: CrackNoise = null) -> Array[Vector3]:
	var nz := noise if noise != null else CrackNoise.plain()
	var q := nz.warp(dir * radius, dir, radius, nz.finest_m) / spacing_m
	return [q, _voronoi_site(q, nz)]


## The feature point of the cell holding [param x]: the first pass of
## [method _voronoi_gd], answered as an absolute position so it names the cell.
static func _voronoi_site(x: Vector3, nz: CrackNoise) -> Vector3:
	var n := x.floor()
	var ix := int(n.x)
	var iy := int(n.y)
	var iz := int(n.z)
	var site := Vector3.ZERO
	var md := 1.0e9
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var p := n + Vector3(i, j, k) + _jitter(ix + i, iy + j, iz + k, nz)
				var d := p.distance_squared_to(x)
				if d < md:
					md = d
					site = p
	return site


## How far inside the rim the foot of the wall sits, in metres: the
## horizontal run of the wall, so a 180 m wall stands at 89.98°. Not zero:
## the foot has to read as inside the crack (d < half) and the rim as outside.
const CRACK_FOOT_INSET_M := 0.05


## Profondeur de carve pour une distance au bord déjà connue. Pure, sans Voronoï.
## A box section: flat floor, vertical walls, square corners at the rim and at
## the foot. On a vertex grid a vertical wall only exists where the vertices
## SIT on both of its edges: see [method crack_rim_snap], which the chunk
## builders apply.
static func crack_offset_from_edge(d_m: float, width_m: float, depth_m: float) -> float:
	if depth_m <= 0.0 or width_m <= 0.0:
		return 0.0
	if d_m >= width_m * 0.5:
		return 0.0
	return -depth_m


## A grid vertex within [param max_move_m] of the wall, moved ONTO it: onto
## the rim from the plateau side, onto the foot from the crack side.
##
## Why: the wall is vertical. A grid vertex lands anywhere around it, so the
## wall drawn between two vertices would lean by up to a pitch and the rim
## would go up and down tooth by tooth (crenellated canyon tops). Sliding the
## plateau vertices nearest the wall horizontally onto the rim, and the floor
## vertices nearest it onto the foot (CRACK_FOOT_INSET_M further in), leaves
## a polyline of vertices at zero drop and one at full depth right under it:
## the wall between them is vertical, the corners at both ends square.
##
## Returns (dir.x, dir.y, dir.z, edge distance in m at that dir): the moved
## direction with the distance set to the half-width (rim) or the half-width
## less the inset (foot) when it moved, the grid direction and its true
## distance when it did not (too far, or the edge plane too flat to reach),
## INF for the distance when the crack is not drawn at this pitch. Pure: the
## mesh and the fine collision grid, on the same pitch, move the same vertices
## the same way — a border vertex included, as the neighbour on the same grid
## moves it identically; pass max_move_m = 0 only where a coarser neighbour
## owns the edge (the LOD stitch).
static func crack_rim_snap(dir: Vector3, radius: float, spacing_m: float, width_m: float,
		vtx_spacing_m: float, max_move_m: float, noise: CrackNoise = null) -> Vector4:
	if spacing_m <= 0.0 or width_m <= 0.0 \
			or (vtx_spacing_m > 0.0 and vtx_spacing_m >= width_m * 0.5):
		return Vector4(dir.x, dir.y, dir.z, INF)
	var nz := noise if noise != null else CrackNoise.plain()
	if use_native_voronoi and nz.native != null:
		return nz.native.Snap(dir, radius, spacing_m, width_m, vtx_spacing_m, max_move_m,
				CRACK_FOOT_INSET_M)
	return _snap(dir, radius, spacing_m, width_m, vtx_spacing_m, max_move_m, nz)


## Newton on the tangent plane toward the rim (plateau side) or the foot (crack
## side): the rim is a curve now, so the vertex follows the gradient of the
## distance, taken by forward differences SNAP_PROBE_M along two tangent axes
## (the value at the vertex is already known), until it lands within
## SNAP_TOLERANCE_M. A vertex farther than the reach, one whose gradient
## vanishes (the crack's centre line) or whose step would exceed the reach
## stays where it is. Reference of CrackVoronoiNative.Snap.
static func _snap(dir: Vector3, radius: float, spacing_m: float, width_m: float,
		vtx_spacing_m: float, max_move_m: float, nz: CrackNoise) -> Vector4:
	var d := _edge_distance(dir, radius, spacing_m, vtx_spacing_m, nz)
	if max_move_m <= 0.0:
		return Vector4(dir.x, dir.y, dir.z, d)
	var half := width_m * 0.5
	# The plateau side goes to the rim, the crack side to the foot.
	var target := half if d >= half else half - CRACK_FOOT_INSET_M
	var f := d - target
	if absf(f) > max_move_m * SNAP_REACH_SLOPE:
		return Vector4(dir.x, dir.y, dir.z, d)
	var x := dir
	var hr := SNAP_PROBE_M / radius
	for it in SNAP_ITERATIONS:
		var up_ref := Vector3.UP if absf(x.y) < 0.99 else Vector3.RIGHT
		var t1 := x.cross(up_ref).normalized()
		var t2 := x.cross(t1)
		var here := f + target
		var g1 := (_edge_distance((x + t1 * hr).normalized(), radius, spacing_m, vtx_spacing_m, nz) - here) \
				/ SNAP_PROBE_M
		var g2 := (_edge_distance((x + t2 * hr).normalized(), radius, spacing_m, vtx_spacing_m, nz) - here) \
				/ SNAP_PROBE_M
		var gl2 := g1 * g1 + g2 * g2
		if gl2 < SNAP_MIN_GRADIENT_SQ:
			return Vector4(dir.x, dir.y, dir.z, d)
		var step := -f / gl2
		x = (x + (t1 * (step * g1) + t2 * (step * g2)) / radius).normalized()
		f = _edge_distance(x, radius, spacing_m, vtx_spacing_m, nz) - target
		if absf(f) <= SNAP_TOLERANCE_M:
			break
	# Where it landed must BE the wall: near a cell corner the gradient is weak
	# and a step can shoot tens of metres into the crack — a plateau vertex
	# declared on the rim, standing on the floor. Such a vertex stays put.
	if absf(f) > SNAP_TOLERANCE_M or x.distance_to(dir) * radius > max_move_m:
		return Vector4(dir.x, dir.y, dir.z, d)
	return Vector4(x.x, x.y, x.z, target)


## Step of the snap's forward differences (m).
const SNAP_PROBE_M := 0.5
## Newton steps of the snap, at most: the rim is a plane (one step lands) bent
## by noise of hundreds of metres of wavelength — one or two more take the bend;
## it stops as soon as it is within SNAP_TOLERANCE_M.
const SNAP_ITERATIONS := 5
## How fast the noisy distance may change (m per m): up to ~1.8 with the
## CrackNoise clamps (value noise slopes 3.75/λ per unit of amplitude). The
## pre-check skips a vertex whose distance is beyond reach even at that slope.
const SNAP_REACH_SLOPE := 2.0
## How close to the rim or the foot a snapped vertex must have landed (m).
const SNAP_TOLERANCE_M := 0.02
## Below this squared gradient the vertex is on a ridge of the distance (the
## crack's centre line, a cell corner): no direction to slide.
const SNAP_MIN_GRADIENT_SQ := 1.0e-4


## Tests flip this to exercise the GDScript twin, which stays the reference.
static var use_native_voronoi := true


## Distance (in cell units) from [param x] to the nearest Voronoi cell
## boundary — Inigo Quilez's 3D "Voronoi edges" algorithm.  The 2-sphere
## slices the 3D Voronoi diagram into polygonal blocks, producing the
## orthogonal monolithic-crack look on the surface.
static func _voronoi_edge_distance(x: Vector3, nz: CrackNoise = null) -> float:
	return _voronoi_edge_dn(x, nz).w


## [method _voronoi_edge_distance] with the unit normal of the nearest edge
## plane (pointing across it, from the closest cell into its neighbour) in
## xyz and the distance in w.
##
## Answered by CrackVoronoiNative when the assembly is there — the same arithmetic in the same
## order. The GDScript below stays the reference and the fallback; test_crack_voronoi_native.gd
## holds the two equal bit for bit.
static func _voronoi_edge_dn(x: Vector3, nz: CrackNoise = null) -> Vector4:
	var n := nz if nz != null else CrackNoise.plain()
	if use_native_voronoi and n.native != null:
		return n.native.EdgeDn(x)
	return _voronoi_gd(x, n)


## The cell's feature point jitter in [0,1)³: MountainNoise's integer hash, one
## seed per axis — no sine, so every machine draws the same network.
static func _jitter(ix: int, iy: int, iz: int, nz: CrackNoise) -> Vector3:
	return Vector3(MountainNoise.cell(ix, iy, iz, nz.voronoi_seed(0)),
			MountainNoise.cell(ix, iy, iz, nz.voronoi_seed(1)),
			MountainNoise.cell(ix, iy, iz, nz.voronoi_seed(2)))


static func _voronoi_gd(x: Vector3, nz: CrackNoise) -> Vector4:
	var n := x.floor()
	var f := x - n
	var ix := int(n.x)
	var iy := int(n.y)
	var iz := int(n.z)
	# Pass 1: locate the closest feature point.
	var mr := Vector3.ZERO
	var mg := Vector3.ZERO
	var md := 1.0e9
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var g := Vector3(i, j, k)
				var r := g + _jitter(ix + i, iy + j, iz + k, nz) - f
				var d := r.dot(r)
				if d < md:
					md = d
					mr = r
					mg = g
	# Pass 2: minimum distance to the edge between the closest point and
	# each of its neighbours.
	var edge := 1.0e9
	var normal := Vector3.ZERO
	var mgx := int(mg.x)
	var mgy := int(mg.y)
	var mgz := int(mg.z)
	for k in range(-1, 2):
		for j in range(-1, 2):
			for i in range(-1, 2):
				var g := mg + Vector3(i, j, k)
				var r := g + _jitter(ix + mgx + i, iy + mgy + j, iz + mgz + k, nz) - f
				var diff := r - mr
				if diff.dot(diff) > 1.0e-5:   # skip the closest cell itself
					var nd := diff.normalized()
					var e := (0.5 * (mr + r)).dot(nd)
					if e < edge:
						edge = e
						normal = nd
	return Vector4(normal.x, normal.y, normal.z, edge)
