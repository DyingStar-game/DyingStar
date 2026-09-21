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
	return crack_offset_from_edge(
		crack_edge_distance_m(dir, radius, spacing_m, width_m, vtx_spacing_m),
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
static func crack_edge_distance_m(dir: Vector3, radius: float,
		spacing_m: float, width_m: float, vtx_spacing_m: float = 0.0) -> float:
	if spacing_m <= 0.0 or width_m <= 0.0:
		return INF
	# LOD: skip the crack entirely once the mesh is too coarse to represent it.
	if vtx_spacing_m > 0.0 and vtx_spacing_m >= width_m * 0.5:
		return INF
	# Surface point expressed in Voronoi-cell units (1 cell ≈ spacing_m).
	var p := dir * (radius / spacing_m)
	return _voronoi_edge_distance(p) * spacing_m


## Profondeur de carve pour une distance au bord déjà connue. Pure, sans Voronoï.
static func crack_offset_from_edge(d_m: float, width_m: float, depth_m: float) -> float:
	if depth_m <= 0.0 or width_m <= 0.0:
		return 0.0
	var half := width_m * 0.5
	if d_m >= half:
		return 0.0
	var t := d_m / half                        # 0 at crack centre, 1 at rim
	var t2 := t * t
	return -depth_m * (1.0 - t2 * t2)          # flat floor, steep walls (1 − t⁴)


## Deterministic per-cell jitter in [0,1)³ — SurfaceNoise.hash3, kept under
## its old name so the crack network reads as before.
static func _hash3(c: Vector3) -> Vector3:
	return SurfaceNoise.hash3(c)


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
