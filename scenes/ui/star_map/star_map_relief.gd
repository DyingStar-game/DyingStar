class_name StarMapRelief
extends RefCounted

## Builds a displaced globe for one body out of the elevation tiles ALREADY ON DISK.
##
## The chart draws a body as a smooth sphere, which is honest but tells you nothing: every world looks
## like every other. The terrain pipeline already publishes a coarse whole-globe pyramid — the "floor",
## levels n1 to n8, fetched in one request the first time a planet is approached — and that is plenty
## for a thumbnail. This turns it into a mesh.
##
## Three things it deliberately does NOT do:
##
## - it never touches the network. [method RemoteTileSource.take] is documented to read the disk cache
##   and nothing else, and no download thread is started. A body whose tiles have never been fetched
##   simply has no relief, and the chart keeps its sphere.
## - it does not instantiate a planet. Doing that opens a tile source, a detail texture array, a gravity
##   area, a 512×256 ocean sphere and a quadtree — for nineteen bodies in a menu, out of the question.
## - it does not go near the fine levels. n1 is twelve tiles for a whole world; n1024 is a million.

## Where the streamed tiles land. The same default [RemoteTileSource] uses.
const CACHE_ROOT: String = "user://tile_cache/"
## Where the QGIS pipeline leaves each body's manifest, which carries the scale the tiles are in.
const EXPORT_ROOT: String = "res://assets/qgis/export"
## Witness that a floor has been fetched and unpacked. Its presence is what says a version directory is
## usable rather than half-written.
const FLOOR_MARKER: String = "floor.done"

## HEALPix level the WHOLE GLOBE is read at. One means the twelve base pixels — one tile each, the
## whole world in twelve files, and the only level at which twelve files IS the whole world.
##
## This is the far view, and it is all the far view can use: at n1 a tile spans 203 km of ground, so a
## planet drawn two hundred pixels across already has more pixels than samples.
const TILE_NSIDE: int = 1

## How many tiles one near view may be built from. 96 × 25² is some 60 000 vertices — the same order as
## the globe, built once per level change on a worker.
##
## It is also what CHOOSES the level, and that is the neat part: the visible ground shrinks as you
## descend, so holding the tile count fixed and taking the finest level that fits is the same thing as
## asking for constant detail on screen.
##
## Raised from 64 with the grid dropped from 32 to 24 in exchange, for the same vertex count. 64 with
## the headroom below left the choice one level coarse over a whole stretch of the range — n2 where the
## data offered n4 — and a tile carries 32 samples, so 24 subdivisions of it costs a little smoothing
## where 64 tiles cost a whole halving of the ground resolution.
##
## Then raised again, to 384, once the per-tile ancestor fallback existed. ⚠️ An earlier measurement said
## the budget bought nothing — 96, 384 and 1024 all chose the same level — and it was true at the time
## and is worth recording because it stopped being true: what capped the level then was the all-or-
## nothing rule refusing a level for one absent tile, not the budget. With every tile now resolvable
## from an ancestor, the budget is the cap again. Measured from the same point, per build on a worker:
##
##     budget   6 km up            2 km up            500 m up
##     96       LOD 6, 3176 m      LOD 7, 1588 m      LOD 8,  794 m    ~0.3 s
##     384      LOD 7, 1588 m      LOD 8,  794 m      LOD 9,  397 m    ~1.2 s
##     1024     LOD 8,  794 m      LOD 9,  397 m      LOD 10, 198 m    ~4.0 s
##
## Each fourfold buys one level and costs some three times the build. 1024 reaches 198 m, which is the
## pyramid's own finest — and four seconds, which is long enough to be felt even behind the old mesh.
## 384 is where the curve still pays: four times the ground detail for four times nothing, since the
## build runs on a worker with the previous mesh still on screen.
const PATCH_TILES_MAX: int = 384

## How much of the tile budget a FINER level has to fit inside before the chart will move up to it.
##
## Asymmetric on purpose: climbing a level rebuilds every tile in view and so has to earn it, while
## falling back is free and immediate. Without it a camera resting on the boundary between two levels
## flaps across it, and each flap is a patch rebuilt.
##
## A tenth, not a quarter. Levels are FOUR times apart in tile count, so a wide margin does not buy
## proportionally more calm — it simply refuses a level that fits. Measured at 4 km over Tarsis III:
## n512 wanted 340 tiles of the 384 available, well inside the budget, and a quarter-margin held the
## chart at n256 and drew the ground twice as coarse for it. A tenth still leaves a band of some 5 % of
## cap angle to settle in.
const FINER_MARGIN: float = 0.9


## How much the relief is overstated. One: it is not.
##
## It stood at twelve, and had to, back when the chart could only draw the whole globe: Tarsis III's
## full range is 12.4 km on a radius of 6 356 km — two tenths of a percent, a fraction of one pixel of a
## planet drawn on a screen. Twelve made it two percent, which reads.
##
## That reason is gone. The chart now draws the ground at 198 m per sample where it used to manage 25 km,
## so a hillside of a few hundred metres fills a real part of the view on its own merits. Overstating it
## on top of that would be inventing terrain nobody is standing on — and the camera guard is derived
## from this same surface, so every multiple also pushed the closest approach further off the ground.
##
## The cost is honest and worth stating: seen from far enough out that the whole body is in frame, the
## relief is once again a fraction of a pixel, and the planet reads as a smooth ball. That is what it
## actually looks like.
const EXAGGERATION: float = 1.0

## Vertex tint at the lowest and the highest ground, as a MULTIPLIER on the ground's own colour.
##
## A multiplier rather than a colour, so a world keeps its identity: each body merely darker in its
## basins and paler on its ridges. One ramp serves every one of them, nothing authored per planet.
##
## MUCH gentler than it was, because it no longer carries the whole appearance of a world on its own.
## It was calibrated against a single flat colour per body, where a swing from 0.52 to 1.0 was the only
## thing standing between the chart and a plain disc. Over real ground colour, which already varies from
## one vertex to the next, that same swing buries it under a blue-grey contour map.
##
## ⚠️ The ramp only ever DARKENS, and that is forced: an [ArrayMesh] stores its colour array as eight
## bits per channel, so anything above 1.0 is silently clamped away. A first pass ran the ridges up to
## 1.30 and they came out at exactly 1.0 — the highlands were simply the body's flat colour again, which
## is the very thing this is here to fix. The peaks therefore carry the ground's own colour and
## everything below is shaded down from it.
const LOW_TINT: Color = Color(0.70, 0.74, 0.82)
const HIGH_TINT: Color = Color(1.0, 1.0, 1.0)

## Tint of bare, steep ground, and the slope at which it takes over completely.
##
## The second half of "what does this world look like", and the reason the first half is not enough:
## altitude alone paints latitude-free bands, which read as a contour map rather than as terrain. Slope
## is what separates a plateau from the flank that leads up to it, and it is the same distinction the
## game's own terrain shader draws between ground and cliff.
##
## Both halves of the ramp are derived from the height field — the SHAPE of the ground, never its
## substance. What the ground is made of is a separate question, answered by [method _ground_colours].
const CLIFF_TINT: Color = Color(0.82, 0.80, 0.78)
## Slope, as 1 - dot(normal, radial), at which ground counts as fully bare. 0.15 is about 32 degrees on
## the EXAGGERATED relief, which is the point where a flank stops reading as a hillside.
const CLIFF_SLOPE: float = 0.15


## Radius the mesh is built at, matching the [SphereMesh] it replaces — everything the chart draws on a
## body is sized against 0.5, not against 1.
const MESH_RADIUS: float = 0.5


## The level to draw at AND the tiles that level needs, decided together.
##
## Together because they cannot be decided apart. [method level_for] answers from an ESTIMATE of how
## many tiles the view holds, and an estimate can be wrong: when it is, [method patch_tiles] runs out of
## budget half way across the visible disc and returns nothing rather than half a planet with space
## behind the other half. Something then has to drop a level and ask again, and if that something lives
## in the caller, the caller owns half of this arithmetic — which is how the level the ground drew and
## the level the guard measured came apart before.
##
## [param current] is the level already on screen, or 0 when there is none. It is what makes the choice
## asymmetric: see [constant FINER_MARGIN].
static func plan_patch(body_key: String, centre_dir: Vector3, altitude_m: float,
		current: int = 0, view_angle: float = -1.0) -> Dictionary:
	var manifest: Dictionary = _manifest(body_key)
	return patch_for(manifest, centre_dir, altitude_m,
			float(manifest.get("radius", 0.0)), current, view_angle)


## The same decision, against a manifest handed in rather than read from disk.
##
## Split out for the same reason [method level_for] is: the arithmetic is the part worth pinning, and a
## test that has to find a body with tiles cached on the machine running it can only pin it where those
## tiles happen to be.
static func patch_for(manifest: Dictionary, centre_dir: Vector3, altitude_m: float,
		radius: float, current: int = 0, view_angle: float = -1.0) -> Dictionary:
	var full: float = float(PATCH_TILES_MAX)
	var plan: Dictionary = _descend(manifest, centre_dir, altitude_m, radius, full, view_angle)
	if current > 0 and int(plan["level"]) > current:
		# Moving up costs a rebuild of everything that comes into view, so it has to clear a margin
		# rather than merely tie. Only the climb is held back: falling behind the view is decided by
		# the height alone, and is immediate.
		var held: Dictionary = _descend(manifest, centre_dir, altitude_m, radius,
				full * FINER_MARGIN, view_angle)
		if int(held["level"]) >= current:
			plan = held
	return plan


## One walk down the pyramid, keeping the finest level whose tiles fit in [param fit].
##
## The level and its tiles come out of the SAME descent, and the count that decides is the real one —
## the tiles actually collected — rather than an estimate of the cap's area. That estimate is what used
## to choose the level, and near the ground it is badly wrong: measured at 4 km over Tarsis III it
## predicted 131 tiles where the walk found 85, so a level that would have fitted in the budget with
## room to spare was refused, and the chart drew ground twice as coarse as it could have.
static func _descend(manifest: Dictionary, centre_dir: Vector3, altitude_m: float,
		radius: float, fit: float, view_angle: float) -> Dictionary:
	var ceiling: int = maxi(int(manifest.get("nside_max", TILE_NSIDE)), TILE_NSIDE)
	return _walk(centre_dir, cap_angle(altitude_m, radius, view_angle), ceiling, fit,
			centre_dir.length_squared() > 0.0 and altitude_m >= 0.0 and radius > 0.0)


## The one walk down the pyramid, and the only place a level or a patch is ever chosen.
##
## Keeps the finest level at or below [param ceiling] whose tiles number no more than [param fit],
## returning that level and its tiles together. [param near] is false when there is no near view at
## all — no direction, or a body nobody is watching — and the answer is then the globe.
##
## The count that decides is the REAL one, the tiles actually collected, never an estimate of the cap's
## area. That estimate is what used to choose the level, and near the ground it is badly wrong:
## measured at 4 km over Tarsis III it predicted 131 tiles where the walk found 85, so a level that
## fitted the budget with room to spare was refused and the chart drew ground twice as coarse as it
## could have.
static func _walk(centre_dir: Vector3, cap: float, ceiling: int, fit: float,
		near: bool) -> Dictionary:
	var globe := PackedInt32Array()
	for ipix: int in range(npix(TILE_NSIDE)):
		globe.append(ipix)
	var best: Dictionary = {"level": TILE_NSIDE, "tiles": globe}
	if not near:
		return best
	var centre: Vector3 = centre_dir.normalized()
	var keep: PackedInt32Array = globe
	var level: int = TILE_NSIDE
	while level < ceiling:
		level *= 2
		# Kept generously, to cover the whole pixel rather than its centre: a descendant can fall
		# inside the cap while its parent's own centre lies outside it.
		var reach: float = cos(minf(cap + HEALPix.pixel_angular_size(level), PI))
		var wider := PackedInt32Array()
		for parent: int in keep:
			for child: int in HEALPix.child_pixels(parent):
				if HEALPix.pix2vec_nest(level, child).dot(centre) >= reach:
					wider.append(child)
		# The pixel the camera is actually over, whatever the arithmetic says.
		#
		# A cap can be smaller than a pixel — four metres up, it is a thousandth of one — and a HEALPix
		# pixel is a diamond whose corners lie further from its centre than its own side length. Pruned
		# on that alone, the pixel holding the camera can be dropped, and then EVERYTHING is, because
		# there is nothing left to subdivide. The patch comes back empty and the chart draws no ground.
		var under: int = HEALPix.vec2pix_nest(level, centre)
		if not under in wider:
			wider.append(under)
		if wider.size() > PATCH_TILES_MAX * 4:
			break  # nothing finer can narrow down to something inside the budget
		keep = wider
		# And the exact question, at this level: what actually falls in the cap.
		var limit: float = cos(cap)
		var exact := PackedInt32Array()
		for ipix: int in keep:
			if HEALPix.pix2vec_nest(level, ipix).dot(centre) >= limit:
				exact.append(ipix)
		if exact.is_empty():
			exact.append(under)
		if float(exact.size()) > fit:
			break
		best = {"level": level, "tiles": exact}
	return best


## The finest level whose visible ground fits in [param fit] tiles, bounded by what this body
## publishes. [constant TILE_NSIDE] — the whole globe — when there is no near view to speak of.
static func level_for(manifest: Dictionary, centre_dir: Vector3, altitude_m: float,
		radius: float, fit: float = float(PATCH_TILES_MAX), view_angle: float = -1.0) -> int:
	return int(_descend(manifest, centre_dir, altitude_m, radius, fit, view_angle)["level"])


## How much of a body's surface a camera can see, as a half-angle at its centre.
##
## The exact figure, not the horizon: a cone of half-angle [param half_fov] from a camera
## [param distance] out, cut against a sphere of [param radius]. Negative when the cone's edge misses
## the sphere entirely — the limb is then inside the view, and the horizon is the honest answer.
##
## Taken on the DIAGONAL of the screen by the caller, so nothing in a corner falls outside it.
static func view_half_angle(distance: float, radius: float, half_fov: float) -> float:
	if radius <= 0.0 or half_fov <= 0.0 or distance <= radius:
		return -1.0
	var reach: float = distance * sin(half_fov)
	if reach >= radius:
		return -1.0
	# Sine rule on centre-camera-ground, taking the NEAR intersection.
	return asin(clampf(reach / radius, -1.0, 1.0)) - half_fov


## How much ground the chart has to hold, as a half-angle at the body's centre.
##
## The horizon is the limit of what CAN be seen from a height; [param view_angle] is how much of the
## surface the screen is actually showing, and close in the two are nothing alike. Measured at 224 km
## over Tarsis III: the horizon stood at 15°, some 1 660 km of ground, while the screen was showing
## about 340 km of it. Sizing the patch on the horizon there spends the whole tile budget five times
## wider than the view, and the level that budget can afford comes out two to three steps coarser than
## it needs to be — on screen, a sample of ground as wide as the scale bar.
##
## Negative when the caller has no measurement to offer, and then this is the horizon alone: that is
## also what it becomes far out, where the screen holds the whole body and the two agree.
static func cap_angle(altitude_m: float, radius: float, view_angle: float = -1.0) -> float:
	var horizon: float = horizon_angle(altitude_m, radius)
	return horizon if view_angle <= 0.0 else minf(horizon, view_angle)


## Half-angle of the spherical cap a camera [param altitude_m] up can see — how much of the world is
## in front of it. Public because the chart has to know how far it may drift across a body before the
## patch it was given stops covering the view.
static func horizon_angle(altitude_m: float, radius: float) -> float:
	if radius <= 0.0:
		return PI
	return acos(clampf(radius / (radius + maxf(altitude_m, 0.0)), -1.0, 1.0))


## The tiles a camera [param altitude_m] above [param centre_dir] can see, at [param nside].
##
## Found by walking DOWN the pyramid: the twelve pixels of the whole sphere, keep the ones that reach the
## cap, subdivide those, repeat. Work is proportional to the answer, which is what makes it usable at a
## level holding twelve million pixels — testing them all is out of the question past n16.
##
## It used to grow sideways instead, from the pixel under the camera through
## [method HEALPix.get_neighbors_nest]. That cannot be relied on: a flood fill only reaches what its
## neighbour graph connects, and HEALPix neighbours thin out and break along the seams between faces.
## Measured against a brute-force test over the whole level, the walk came back with 60 tiles where 80
## lay in the cap, 197 where 265 did, 321 where 853 did — 619 of 1 126 caps incomplete, and only for
## some directions. On screen that is a planet that simply stops, with space where the rest of it should
## be. Going down the pyramid needs no neighbours at all, so there is nothing left to be wrong.
##
## The cap reaches PAST the horizon, deliberately. What is drawn has to include the limb, or the body
## acquires a torn edge exactly where the eye reads its silhouette.
##
## Purely geometric: every tile in view is asked for, cached or not. What is not cached is lifted from
## its nearest cached ancestor — see [method _tile_or_ancestor] — so there is nothing to route around.
static func patch_tiles(nside: int, centre_dir: Vector3, altitude_m: float,
		radius: float, view_angle: float = -1.0) -> PackedInt32Array:
	if nside <= TILE_NSIDE:
		var globe := PackedInt32Array()
		for ipix: int in range(npix(TILE_NSIDE)):
			globe.append(ipix)
		return globe
	var plan: Dictionary = _walk(centre_dir, cap_angle(altitude_m, radius, view_angle), nside,
			float(PATCH_TILES_MAX),
			centre_dir.length_squared() > 0.0 and altitude_m >= 0.0 and radius > 0.0)
	# Nothing rather than a truncated cap, and nothing rather than a COARSER one. A level that does not
	# fit the budget is a level that cannot be DRAWN: half a planet with space behind the other half is
	# not a coarser reading of it, and that is exactly what shipped once, a globe rendered as a pac-man.
	return plan["tiles"] if int(plan["level"]) == nside else PackedInt32Array()


## How high the ground stands at [param local_dir], in TRUE metres above the reference sphere.
##
## The number a person wants, which is not the one the mesh is built from: [method surface_factor]
## answers as a multiple of the radius and carries [constant EXAGGERATION] with it, so it moves when
## that constant is tuned. An altitude must not. The export's own range is the check — Tarsis III runs
## from -1 700 m to +9 000 m, and that is what this hands back.
##
## Read from the height field rather than from the level design's export, because the export ships the
## field and leaves it EMPTY: all twenty-seven towns of Tarsis III carry a null elevation. Taking it
## from the field also makes it the ground the chart is drawing, rather than a second opinion about it.
static func ground_altitude_m(body_key: String, local_dir: Vector3) -> float:
	var radius: float = float(_manifest(body_key).get("radius", 0.0))
	if radius <= 0.0 or EXAGGERATION <= 0.0:
		return 0.0
	return (surface_factor(body_key, local_dir) - 1.0) * radius / EXAGGERATION


## The level the chart READS a body's ground at: the finest that body publishes.
##
## A property of the body, never of what happens to be on screen — and that is the whole point. Reading
## at the drawn level is what closed the loop this rewrite exists to remove: the level chose the reading,
## the reading set the camera guard, the guard set the altitude, and the altitude chose the level. Fixing
## it per body cuts the chain at the first link, by construction.
##
## The finest rather than something cheaper, because the reading must never be COARSER than what is
## drawn: the guard would then sit below visible terrain and the camera would sink into a mountain it
## can see. Measured, the cost is uninteresting: 5 µs warm, 0.2 ms the first time a pixel is asked
## about — on Tarsis III, once every 6 km travelled over the ground.
static func finest_nside(body_key: String) -> int:
	return maxi(int(_manifest(body_key).get("nside_max", TILE_NSIDE)), TILE_NSIDE)


## Pixels at a level. Kept here rather than reached for through HEALPix so the arithmetic that sizes a
## patch and the arithmetic that walks it cannot drift apart.
static func npix(nside: int) -> int:
	return 12 * nside * nside


## Is there anything to build for this body? Cheap enough to ask every frame, and it saves starting a
## build that would only return null.
static func has_data(body_key: String) -> bool:
	return body_key != "" and _cached_version(body_key) != ""


# ---------------------------------------------------------------------------
# Building one tile
# ---------------------------------------------------------------------------

## The mesh of ONE tile, in the body's own frame, or null when there is nothing to build it from.
##
## This is the whole of what this file does now. It used to build a whole patch — up to four hundred
## tiles welded together and handed over as a single mesh — which meant that changing anything meant
## rebuilding everything, and that the cost of a change was the cost of the entire view. One tile at a
## time is what lets [StarMapGround] move the camera without rebuilding the planet.
##
## Pure and static on purpose: it runs on a worker, takes only what it is given, keeps nothing. The two
## caches it does touch — the manifest and the cached version — are read-only after the first call.
##
## Radii are in MESH_RADIUS units, the same as the [SphereMesh] a body is otherwise drawn with, so a
## tile can be parented to the body and inherit its scale and its spin for nothing.
static func build_tile(body_key: String, nside: int, ipix: int, grid_res: int) -> ArrayMesh:
	var manifest: Dictionary = _manifest(body_key)
	var radius: float = float(manifest.get("radius", 0.0))
	var version: String = _cached_version(body_key)
	if radius <= 0.0 or version == "" or grid_res <= 0:
		return null
	# cache_root and shard_tiles keep their defaults; no thread is started and no url is set, so this
	# object can only ever read files.
	var source := RemoteTileSource.new()
	source.planet = body_key
	source.version = version
	var heights: PackedFloat32Array = _tile_or_ancestor(source, nside, ipix)
	if heights.is_empty():
		return null
	# Side deduced from the payload, never from the manifest: the two coincide for published tiles, and
	# planet_data learnt the hard way that assuming it reads out of bounds when they do not.
	var side: int = int(round(sqrt(float(heights.size()))))
	# Normalised 0..1 in the file; these two put it back into metres.
	var span: float = float(manifest.get("max_height", 0.0))
	var base: float = float(manifest.get("height_offset", 0.0))

	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(nside, ipix, grid_res)
	var stride: int = grid_res + 1
	var points := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for vy: int in range(stride):
		for vx: int in range(stride):
			var dir: Vector3 = grid[vy][vx]
			# u follows the face's x, v its y — the same parametrisation get_pixel_grid walks, so a
			# vertex and the texel under it are the same place by construction.
			var metres: float = _sample(heights, side,
					float(vx) / float(grid_res), float(vy) / float(grid_res)) * span + base
			points.append(dir * (MESH_RADIUS * (1.0 + EXAGGERATION * metres / radius)))
			normals.append(dir)
	_add_patch_indices(indices, points, 0, stride)
	_smooth_normals(points, normals, indices)
	_add_skirt(points, normals, indices, stride,
			MESH_RADIUS * HEALPix.pixel_side_length(nside, 1.0) / float(grid_res))

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Height fields kept for [method surface_factor], by body key. A body with no tiles is cached as an
## empty entry, so the disk is searched once and not once a frame.
##
## Deliberately NOT written by [method build], which runs on a worker: this is read from the main
## thread, and one shared dictionary written from two is a race for no gain. Twelve tile reads is a
## couple of milliseconds, once per body.
static var _fields: Dictionary = {}


## Where the ground stands at [param local_dir], as a multiple of the body's reference radius.
##
## One is the reference sphere, 1.02 a summit, 0.998 a basin — the same numbers the mesh is displaced
## by, read from the same tiles, so a point computed here lands on the surface drawn there.
##
## The chart needs this wherever it has to know where the ground IS rather than merely draw it: what
## the scale bar is measuring across, and how close the camera may come. Using the GLOBAL summit for
## those, as it did, is wrong by the whole relief of the body — a hundred and fifty km on Tarsis III
## once exaggerated, which made the scale bar read thirty-seven times too small.
## [param nside] is the level the tiles are read at, and left out it is [method finest_nside] — which is
## what every caller in the chart wants. It stays a parameter so a test can compare this reading against
## a mesh built at the SAME level: the two walk the same tiles through the same sampler, and if they ever
## stopped agreeing, nothing else would complain.
static func surface_factor(body_key: String, local_dir: Vector3, nside: int = 0) -> float:
	if local_dir.length_squared() <= 0.0:
		return 1.0
	if nside <= 0:
		nside = finest_nside(body_key)
	var dir: Vector3 = local_dir.normalized()
	var field: Dictionary = _field_for(body_key, nside)
	if field.is_empty():
		return 1.0
	var face: int = HEALPix.vec2pix_nest(nside, dir)
	var tiles: Dictionary = field["tiles"]
	if not tiles.has(face):
		# Fetched the same way the MESH fetches it — the tile if it is cached, otherwise its nearest
		# cached ancestor resampled. Any other route here and the camera would be guarded against a
		# surface the screen is not showing, which is the one thing this must never be.
		tiles[face] = _tile_or_ancestor(field["source"], nside, face)
	if (tiles[face] as PackedFloat32Array).is_empty():
		return 1.0
	# Back to the 0..1 WITHIN THE TILE, which is what _sample wants and what the mesh was built on.
	#
	# _vec_to_face_xy answers in pixel units across the whole FACE — 0..nside — and takes a face, not a
	# pixel. At nside 1 those are the same number and the same index, which is why passing the pixel
	# straight in worked for as long as nside was always 1. It stops working the moment it is not:
	# measured at n8, two thirds of the surface disagreed with the mesh drawn from the same tiles, by up
	# to 1.1 % of the radius — seventy km of exaggerated relief the camera would have been guarding
	# against in the wrong place.
	var located: Dictionary = HEALPix.pix2face_xy(nside, face)
	var in_face: Vector2 = HEALPix._vec_to_face_xy(dir, int(located["face"]), nside)
	var fc := Vector2(in_face.x - float(located["ix"]), in_face.y - float(located["iy"]))
	var heights: PackedFloat32Array = tiles[face]
	var side: int = int(round(sqrt(float(heights.size()))))
	var metres: float = _sample(heights, side, clampf(fc.x, 0.0, 1.0), clampf(fc.y, 0.0, 1.0)) \
			* float(field["span"]) + float(field["base"])
	return 1.0 + EXAGGERATION * metres / float(field["radius"])


static func _field_for(body_key: String, nside: int) -> Dictionary:
	var cache_key: String = "%s@%d" % [body_key, nside]
	if _fields.has(cache_key):
		return _fields[cache_key]
	var field: Dictionary = {}
	var manifest: Dictionary = _manifest(body_key)
	var radius: float = float(manifest.get("radius", 0.0))
	var version: String = _cached_version(body_key)
	if radius > 0.0 and version != "":
		# Opened empty and filled ONE TILE AT A TIME, as directions come in. This answers about a single
		# point — where the ground is under the camera, how wide the scale bar's stick is — and a view
		# asks about a handful of tiles, never the level's millions. Reading the level up front meant
		# listing a directory and loading several hundred tiles to answer a question about one.
		var source := RemoteTileSource.new()
		source.planet = body_key
		source.version = version
		field = {
			"tiles": {}, "source": source, "radius": radius,
			"span": float(manifest.get("max_height", 0.0)),
			"base": float(manifest.get("height_offset", 0.0)),
		}
	_fields[cache_key] = field
	return field


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

## Manifests, by body key. Cached because [method plan_patch] asks for one every frame now, and parsing
## the same JSON sixty times a second to be told the same radius is waste with a disk read attached.
static var _manifests: Dictionary = {}


static func _manifest(body_key: String) -> Dictionary:
	if _manifests.has(body_key):
		return _manifests[body_key]
	var out: Dictionary = {}
	var path: String = "%s/%s_chunks/manifest.json" % [EXPORT_ROOT, body_key]
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			out = parsed
	_manifests[body_key] = out
	return out


## Which cached version to read.
##
## Taken from the CACHE rather than from the export's own data_version, because the two disagree: on
## this machine tarsis_8's manifest says 30b9d4d6 while what was actually downloaded is a920c4bf. The
## version is decided by the stream channel, and asking the channel means a network round trip. Reading
## whatever is already on disk needs none, and "whatever is already on disk" is precisely what this can
## draw.
static func _cached_version(body_key: String) -> String:
	var root: String = CACHE_ROOT + body_key
	var dir: DirAccess = DirAccess.open(root)
	if dir == null:
		return ""
	for name: String in dir.get_directories():
		if FileAccess.file_exists("%s/%s/%s" % [root, name, FLOOR_MARKER]):
			return name
	return ""


static func _tile_or_ancestor(source: RemoteTileSource, nside: int, ipix: int) -> PackedFloat32Array:
	var level: int = nside
	var at: int = ipix
	while level >= TILE_NSIDE:
		var raw: PackedByteArray = source.take(level, at)
		# Side deduced from the payload, never from the manifest: the two coincide for published tiles,
		# and planet_data learnt the hard way that assuming it reads out of bounds when they do not.
		var side: int = int(round(sqrt(float(raw.size()) / 2.0)))
		if side > 1 and side * side * 2 == raw.size():
			var heights: PackedFloat32Array = HeightPack.widen_u16(raw, side).to_float32_array()
			@warning_ignore("integer_division")
			var span: int = nside / level
			return heights if level == nside else _sub_tile(heights, side, span, ipix)
		@warning_ignore("integer_division")
		level /= 2
		at = at >> 2  # nested order: a pixel's parent is its index with the last two bits dropped
	return PackedFloat32Array()


## The part of an ancestor tile that lies under one of its descendants, resampled to a full tile.
##
## [param span] is how many descendants fit along one side of the ancestor. Which of them this is comes
## from the low bits of the nested index — that is precisely what nested ordering encodes — read through
## the same [method HEALPix.nest2xy] the mesh builder uses, so the patch lands where the tile is drawn.
static func _sub_tile(heights: PackedFloat32Array, side: int, span: int,
		ipix: int) -> PackedFloat32Array:
	var within: Vector2i = HEALPix.nest2xy(ipix % (span * span))
	var out := PackedFloat32Array()
	out.resize(side * side)
	var step: float = 1.0 / float(span)
	for y: int in range(side):
		var v: float = (float(within.y) + (float(y) + 0.5) / float(side)) * step
		for x: int in range(side):
			var u: float = (float(within.x) + (float(x) + 0.5) / float(side)) * step
			out[y * side + x] = _sample(heights, side, u, v)
	return out


# ---------------------------------------------------------------------------
# Fetching — the one place this file is allowed to touch the network
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

## A wall hanging down from every edge of the tile, to hide the seams between tiles.
##
## Two tiles that meet are sampled with their OWN edges extended, so at the boundary they read two
## different texels and the ground steps by whatever the terrain does across one sample — 839 m on
## average over Tarsis III at nside 1, 3 843 m at worst. You see through the step: a thin dark crack
## along every tile edge, which is what a planet made of tiles looks like if nothing is done.
##
## ⚠️ The previous answer was to WELD the seams — find the twin vertices and average them. It worked
## and it cost 109 seconds on one patch, because its spatial hash degenerated when every rim vertex of
## a fine patch fell into one cell. Skirts are what the game uses ([code]planet_chunk.gd:1307[/code])
## and they are strictly local: no twin to find, no neighbour to know about, nothing quadratic.
##
## The drop follows the largest step between ADJACENT vertices of this tile, not the tile's whole
## relief. The game's comment explains why, and it is worth repeating: dimensioned on the full range
## the skirts become kilometre-high walls that cost fill rate and show at the limb.
static func _add_skirt(points: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array, stride: int, cell: float) -> void:
	var rim: PackedInt32Array = _rim_ring(stride)
	if rim.size() < 4:
		return
	# Each rim vertex gets its own depth, from its own two neighbours along the rim.
	#
	# One depth for the whole tile — the largest step anywhere on the rim — makes a single cliff in one
	# corner hang a wall that deep all the way ROUND, over ground that is flat. Measured at Mining
	# village 01: the worst step is 550 m at n256 and 1 750 m at n1024, while what a skirt actually has
	# to cover, the disagreement between two neighbouring tiles along the edge they share, is 27.6 m and
	# 1.1 m. Sizing on the steepness rather than on the disagreement, and then taking the maximum, is
	# two mistakes compounding.
	var steps := PackedFloat32Array()
	steps.resize(rim.size())
	for i: int in range(rim.size()):
		var here: float = points[rim[i]].length()
		var before: float = points[rim[(i + rim.size() - 1) % rim.size()]].length()
		var after: float = points[rim[(i + 1) % rim.size()]].length()
		steps[i] = maxf(absf(here - before), absf(here - after))
	# Twice the local step, with a floor of a hundredth of a cell so a flat rim still gets a skirt: a
	# crack of no height at all still shows a hairline where two meshes fail to touch exactly.
	#
	# BOTH numbers are vertical. The floor used not to be — it was a quarter of the cell's WIDTH, a
	# horizontal length standing in for a depth — and nothing said so while the relief was overstated
	# twelvefold and towered over it. Drawn at true height it does not.
	var first: int = points.size()
	for i: int in range(rim.size()):
		var top: Vector3 = points[rim[i]]
		var drop: float = maxf(steps[i] * 2.0, cell * 0.01)
		# Straight down the radial, and nothing else. There was a nudge here, said to keep the wall off
		# the surface it hangs from — but it displaced along that same radial, so all it ever did was
		# make the skirt shallower by its own amount. Harmless while the drop was hundreds of times
		# larger; with the drop sized on the local step it cancelled the floor exactly and left flat
		# stretches of rim with no skirt at all.
		points.append(top.normalized() * (top.length() - drop))
		normals.append(normals[rim[i]])
	for i: int in range(rim.size()):
		var j: int = (i + 1) % rim.size()
		var a: int = rim[i]
		var b: int = rim[j]
		var c: int = first + j
		var d: int = first + i
		# BOTH windings, deliberately. A skirt is scaffolding seen edge-on through a gap a few pixels
		# wide; which way it faces is not worth computing, and getting it wrong makes it invisible
		# exactly where it is needed. Four hundred extra triangles on a tile of eleven hundred.
		indices.append_array([a, b, c, a, c, d])
		indices.append_array([a, c, b, a, d, c])


## The tile's edge vertices, once round, in order. A closed ring: the last one is adjacent to the
## first, which is what lets the skirt be built from consecutive pairs without a special case.
static func _rim_ring(stride: int) -> PackedInt32Array:
	var ring := PackedInt32Array()
	for vx: int in range(stride):
		ring.append(vx)
	for vy: int in range(1, stride):
		ring.append(vy * stride + stride - 1)
	for vx: int in range(stride - 2, -1, -1):
		ring.append((stride - 1) * stride + vx)
	for vy: int in range(stride - 2, 0, -1):
		ring.append(vy * stride)
	return ring


## Smoothstep: the same 0..1, with the slope brought to zero at both ends.
static func _smoothed(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)


static func _sample(heights: PackedFloat32Array, side: int, u: float, v: float) -> float:
	var fx: float = u * float(side) - 0.5
	var fy: float = v * float(side) - 0.5
	var x0: int = clampi(int(floorf(fx)), 0, side - 1)
	var y0: int = clampi(int(floorf(fy)), 0, side - 1)
	var x1: int = clampi(x0 + 1, 0, side - 1)
	var y1: int = clampi(y0 + 1, 0, side - 1)
	# Smoothed weights, not the raw fractions. Straight bilinear is continuous but its SLOPE is not: it
	# breaks at every texel boundary, and a normal is a slope, so the break is lit. Unnoticeable while a
	# texel is about the size of a triangle, and glaring when it is not — the chart draws at the finest
	# level a body publishes while the tiles CACHED under a place may be six levels coarser, so one
	# texel of data can be magnified sixty-four times. Measured around Mining village 01: real data
	# stops at n16, 12.7 km a sample, under ground being drawn at 198 m a sample. Every texel then
	# became a facet the size of a village, with a hard crease along its edge.
	#
	# The cubic weight is zero-sloped at 0 and 1, so neighbouring patches leave the boundary flat from
	# both sides and the surface is smooth across it. It invents no detail — the same texels, read the
	# same way — it only stops the reconstruction from drawing its own grid. [method surface_factor]
	# comes through here too, so the ground measured still is the ground drawn.
	var tx: float = _smoothed(clampf(fx - floorf(fx), 0.0, 1.0))
	var ty: float = _smoothed(clampf(fy - floorf(fy), 0.0, 1.0))
	var top: float = lerpf(heights[y0 * side + x0], heights[y0 * side + x1], tx)
	var bottom: float = lerpf(heights[y1 * side + x0], heights[y1 * side + x1], tx)
	return lerpf(top, bottom, ty)


## Two triangles per cell, wound so the OUTSIDE is the side Godot draws.
##
## Two separate things decide this, and getting either wrong shows you the inside of the planet:
##
## - HEALPix's twelve base faces do not all carry the same handedness, so the orientation is measured
##   from the geometry rather than assumed. Half a globe inside out is a striking way to find that out.
## - **Godot's front faces are wound CLOCKWISE seen from the front**, which is the opposite of the
##   right-hand rule. A triangle whose cross product points outward is therefore the BACK face here and
##   gets culled. This cost a round trip: the first version was oriented mathematically, a test checked
##   that the cross products pointed outward, the test passed, and the globe was inside out. The test
##   now asserts Godot's convention instead of the textbook one.
static func _add_patch_indices(indices: PackedInt32Array, points: PackedVector3Array, first: int,
		stride: int) -> void:
	var a: int = first
	var b: int = first + 1
	var c: int = first + stride
	var outward: Vector3 = (points[a] + points[b] + points[c]) / 3.0
	var flip: bool = (points[b] - points[a]).cross(points[c] - points[a]).dot(outward) > 0.0
	for vy: int in range(stride - 1):
		for vx: int in range(stride - 1):
			var i00: int = first + vy * stride + vx
			var i10: int = i00 + 1
			var i01: int = i00 + stride
			var i11: int = i01 + 1
			if flip:
				indices.append_array([i00, i01, i10, i10, i01, i11])
			else:
				indices.append_array([i00, i10, i01, i10, i11, i01])


## Area-weighted vertex normals, accumulated over the faces. Without them the displacement is invisible:
## a sphere's own radial normals light every bump exactly as they lit the smooth ball it came from.
static func _smooth_normals(points: PackedVector3Array, normals: PackedVector3Array,
		indices: PackedInt32Array) -> void:
	var count: int = normals.size()
	for i: int in range(count):
		normals[i] = Vector3.ZERO
	var step: int = 0
	while step < indices.size():
		var a: int = indices[step]
		var b: int = indices[step + 1]
		var c: int = indices[step + 2]
		# Not normalised: the cross product's length is twice the triangle's area, which is exactly the
		# weight a vertex normal wants.
		var face: Vector3 = (points[b] - points[a]).cross(points[c] - points[a])
		normals[a] += face
		normals[b] += face
		normals[c] += face
		step += 3
	for i: int in range(count):
		var radial: Vector3 = points[i].normalized()
		var n: Vector3 = normals[i]
		# A degenerate cell leaves a zero vector, which would black out the vertex; the radial direction
		# is the right answer there and costs nothing.
		if n.length_squared() <= 0.0:
			normals[i] = radial
			continue
		# Turned to agree with the radial, because the accumulation above inherits the WINDING — and the
		# winding follows Godot's clockwise rule, so the raw cross products point INWARD. Left alone, the
		# globe would be lit from the far side: every slope bright where it should be dark. Comparing
		# against the radial rather than negating outright keeps this correct whichever way the winding
		# is ever changed.
		normals[i] = (-n if n.dot(radial) < 0.0 else n).normalized()
