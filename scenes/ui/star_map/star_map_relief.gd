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

## Most tiles one view may want. A GUARD, no longer the rule that picks the level.
##
## The level used to be chosen by this number: the finest single level whose tiles in view fitted in
## it. The ground is now cut by the planet's own rule instead — see [method patch_for] — and this only
## stops a camera grazing the ground from asking for more than a worker pool can build in a few seconds:
## past it, the finest level allowed is halved until the view fits.
##
## Measured with the rule the game uses, over Tarsis III with the ground known to n1024, the quadtree
## wants far fewer: see test_star_map_relief.gd for the counts it is held to.
const PATCH_TILES_MAX: int = 600


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


## The tiles to draw for a camera [param altitude_m] above [param centre_dir], at mixed levels, and
## the level of the one under the camera.
##
## Cut by the PLANET's rule ([PlanetLod]), so the chart and the ground you land on are divided the same
## way: fine under the eye, coarser ring by ring out to the horizon. Bounded by what is known — one level
## beyond the data under the camera, see [method data_depth] — because drawing finer than the ground is
## known stretches one sample over dozens of vertices and calls it detail.
##
## [param view_angle] is how much of the surface the screen shows, see [method cap_angle].
static func plan_patch(body_key: String, centre_dir: Vector3, altitude_m: float,
		view_angle: float = -1.0) -> Dictionary:
	var manifest: Dictionary = _manifest(body_key)
	# One level beyond what the ground is actually known to, and no further.
	#
	# Exactly at it would be honest and would also wedge shut: the chart would stop asking for anything
	# finer, so nothing finer would ever be downloaded, so the depth would never grow. One level beyond
	# leaves the view half a step ahead of its data — a doubling, against the sixty-fourfold stretch this
	# replaces — and keeps the stream probing the level below.
	var cap: int = data_depth(body_key, centre_dir) * 2
	return patch_for(manifest, centre_dir, altitude_m,
			float(manifest.get("radius", 0.0)), view_angle, cap)


## The same decision, against a manifest handed in rather than read from disk, so the arithmetic can be
## pinned without tiles on the machine running the test.
##
## Returns [code]{"tiles": PackedInt64Array of StarMapGround ids, "level": int, "ceiling": int}[/code].
## [code]level[/code] is the level of the tile under the camera; [code]ceiling[/code] the finest level
## the walk was allowed, after [constant PATCH_TILES_MAX] had its say.
static func patch_for(manifest: Dictionary, centre_dir: Vector3, altitude_m: float,
		radius: float, view_angle: float = -1.0, cap: int = 0) -> Dictionary:
	var ceiling: int = maxi(int(manifest.get("nside_max", TILE_NSIDE)), TILE_NSIDE)
	if cap > 0:
		ceiling = mini(ceiling, maxi(cap, TILE_NSIDE))
	if centre_dir.length_squared() <= 0.0 or altitude_m < 0.0 or radius <= 0.0:
		return _globe()  # no near view: a body nobody is watching keeps its twelve tiles
	var centre: Vector3 = centre_dir.normalized()
	var reach: float = cap_angle(altitude_m, radius, view_angle)
	while true:
		var tiles := PackedInt64Array()
		for base: int in range(npix(TILE_NSIDE)):
			_quadtree(TILE_NSIDE, base, centre, altitude_m, radius, reach, ceiling, tiles)
		if tiles.size() <= PATCH_TILES_MAX or ceiling <= TILE_NSIDE:
			return {"tiles": tiles, "level": _level_under(tiles, centre, ceiling), "ceiling": ceiling}
		@warning_ignore("integer_division")
		ceiling /= 2
	return _globe()  # not reached: the loop returns once the ceiling is down to the globe


## The twelve tiles of the whole sphere.
static func _globe() -> Dictionary:
	var tiles := PackedInt64Array()
	for ipix: int in range(npix(TILE_NSIDE)):
		tiles.append(StarMapGround.tile_id(TILE_NSIDE, ipix))
	return {"tiles": tiles, "level": TILE_NSIDE, "ceiling": TILE_NSIDE}


## Each pixel's centre, its diagonal and its reach (see [method pixel_reach]) on the UNIT sphere, by id.
## The walk visits the same few hundred nodes four times a second, and the corners behind those two are
## the costly part of a visit.
static var _node_geom: Dictionary = {}
const NODE_GEOM_KEPT: int = 65536


## One node of the walk: dropped when it lies wholly outside what the camera can see, cut by
## [PlanetLod] when the camera is close enough and the ceiling allows, kept as a leaf otherwise.
static func _quadtree(nside: int, ipix: int, cam_dir: Vector3, altitude_m: float, radius: float,
		reach: float, ceiling: int, out: PackedInt64Array) -> void:
	var id: int = StarMapGround.tile_id(nside, ipix)
	var geom: Array = _node_geom.get(id, [])
	if geom.is_empty():
		if _node_geom.size() >= NODE_GEOM_KEPT:
			_node_geom.clear()
		geom = [HEALPix.pix2vec_nest(nside, ipix), PlanetLod.chunk_diagonal(nside, ipix, 1.0),
				pixel_reach(nside, ipix)]
		_node_geom[id] = geom
	var centre: Vector3 = geom[0]
	var diag: float = float(geom[1]) * radius
	# Kept whenever any part of the pixel can be in view: its centre may lie outside while a corner
	# does not, and the pixel under the camera is always kept, its distance being nothing.
	if centre.angle_to(cam_dir) > reach + float(geom[2]):
		return
	if nside < ceiling and PlanetLod.wants_split(
			PlanetLod.distance(cam_dir, centre, radius, altitude_m), diag):
		for child: int in HEALPix.child_pixels(ipix):
			_quadtree(nside * 2, child, cam_dir, altitude_m, radius, reach, ceiling, out)
		return
	out.append(id)


## How far a pixel reaches from its centre, as an angle: the farthest of its four corners.
##
## NOT half its diagonal. A HEALPix pixel is a diamond, and near a pole its corners are nowhere near
## equidistant: the base pixel holding the north pole has its centre 0.84 rad from the pole and a half
## diagonal of 0.71. Culled on the half diagonal, the pixel under a camera parked over the pole was
## thrown away at the root, and the chart drew no ground at all there below 3 000 km.
static func pixel_reach(nside: int, ipix: int) -> float:
	var centre: Vector3 = HEALPix.pix2vec_nest(nside, ipix)
	var reach: float = 0.0
	for corner: Vector3 in HEALPix.get_pixel_corners(nside, ipix):
		reach = maxf(reach, centre.angle_to(corner))
	return reach


## The level of the tile that holds [param centre].
static func _level_under(tiles: PackedInt64Array, centre: Vector3, ceiling: int) -> int:
	var nside: int = ceiling
	while nside > TILE_NSIDE:
		if tiles.has(StarMapGround.tile_id(nside, HEALPix.vec2pix_nest(nside, centre))):
			return nside
		@warning_ignore("integer_division")
		nside /= 2
	return TILE_NSIDE



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


## Is this tile's OWN data on disk, as opposed to an ancestor's standing in for it?
##
## The question a tile built from a coarser level has to be able to answer before it is worth building
## again. Without it, a tile whose data the service does not have is rebuilt from the same ancestor for
## ever — it comes back provisional, so it is asked again, and the loop spends the build budget that the
## tiles which really did arrive are waiting for.
##
## Asked of the body's [StarMapTiles]: a path test on disk, or the loaded planet's own cache when there
## is one. Main thread only, like everything that resolves a reader.
##
## ⚠️ It used to keep one probe per body, with the version read ONCE. A probe made before the floor had
## landed kept an empty version for the rest of the session, answered no for every tile, and so no
## provisional tile was ever built again.
static func tile_is_cached(body_key: String, nside: int, ipix: int,
		reader: StarMapTiles = null) -> bool:
	if reader == null:
		reader = StarMapTiles.for_body(body_key)
	return reader.has_own(nside, ipix)


## The finest level whose OWN data is on disk under [param dir] — how well this ground is really known.
##
## Not the same as what the body publishes, and the difference is the whole point. Measured on
## Tarsis III: the mining villages have real tiles down to n1024, while every one of the fifteen railway
## cities stops at n8 or n16. Drawn at n1024 regardless, the chart stretches a sol known to 12 km over a
## view asking for 198 m — sixty-four times — and the readout reports the fineness of the MESH as though
## it were the fineness of the ground.
##
## Every level is looked at rather than stopping at the first gap: the cache is filled by whatever has
## been asked for, not top-down, so a hole at one level says nothing about the ones under it. Eleven
## path tests, no reads, four times a second.
static func data_depth(body_key: String, dir: Vector3) -> int:
	var deepest: int = TILE_NSIDE
	var nside: int = TILE_NSIDE
	var ceiling: int = finest_nside(body_key)
	var reader: StarMapTiles = StarMapTiles.for_body(body_key)
	while nside < ceiling:
		nside *= 2
		if reader.has_own(nside, HEALPix.vec2pix_nest(nside, dir)):
			deepest = nside
	return deepest


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
##
## Through the body's reader, so a LOADED planet counts even with nothing streamed — its own pack is
## data — and so the disk is not listed every frame to find a version that has not changed.
static func has_data(body_key: String) -> bool:
	return body_key != "" and StarMapTiles.for_body(body_key).usable()


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
## [param paint] says what the ground here is made of — a fallback rock and the outlined patches of
## other rock laid over it, as [StarMapZones] reads them. Empty leaves the tile white, which lets the
## body's own colour through: what the chart did everywhere before it could tell one stretch of a planet
## from another.
##
## [param reader] is where the heights come from, resolved on the main thread by the caller — see
## [StarMapTiles]. Left out, the disk alone is read, which is what a test or a worker without one gets.
static func build_tile(body_key: String, nside: int, ipix: int, grid_res: int,
		paint: Dictionary = {}, reader: StarMapTiles = null) -> ArrayMesh:
	var manifest: Dictionary = _manifest(body_key)
	var radius: float = float(manifest.get("radius", 0.0))
	if radius <= 0.0 or grid_res <= 0 or body_key == "":
		return null
	if reader == null:
		# The whole body — its PlanetData included — can only be resolved on the main thread; a worker
		# handed nothing gets the disk alone and the chart's own sampler.
		reader = StarMapTiles.for_body(body_key) \
				if OS.get_thread_caller_id() == OS.get_main_thread_id() \
				else StarMapTiles.on_disk(body_key)
	if not reader.usable():
		return null
	# The level the heights really came from, which is not always the one asked for: what is not cached
	# is lifted from the nearest ancestor. A tile built that way is PROVISIONAL — the ground it shows is
	# a coarser ground stretched over it — and saying so is what lets it be built again when the real
	# data arrives. Without it, a tile downloaded behind the chart's back is never drawn: nothing asks a
	# tile already on screen whether it could now be better.
	var from: Array = [0]
	var started: int = Time.get_ticks_usec() if StarMapGround.DEBUG_GROUND else 0
	var heights: PackedFloat32Array = _tile_or_ancestor(reader, nside, ipix, from)
	var read: int = Time.get_ticks_usec() if StarMapGround.DEBUG_GROUND else 0
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
	var mountains: Array = paint.get("mountains", [])
	var ridges: Array = paint.get("ridges", [])
	# Summed in C# when the assembly is there — the path the terrain takes, and what made a tile under
	# mountains cost 29 ms in GDScript where the same tile without them cost 6. The GDScript sum stays as
	# the fallback, and a tile with no feature at all asks neither.
	var mountain_set: RefCounted = paint.get("mountain_set", null)
	var has_relief: bool = not mountains.is_empty() or not ridges.is_empty()
	# Ground covered by one step of the mesh. A feature narrower than this cannot be drawn honestly, and
	# saying so is what keeps a knife-edge crest from coming out as a row of spikes.
	var pitch: float = radius * HEALPix.pixel_angular_size(nside) / float(grid_res)
	# The GAME's sampler when the body's PlanetData is to hand — which is every body with a scene — so
	# the chart draws the ground a ship will land on rather than a second opinion about it. Measured
	# against the game at the same level before this, over Tarsis III: within 4 m on average at n256
	# and n1024 but out by up to 175 m there, and by 750 m at n16, the chart reading each tile alone
	# with its own smoothed kernel where the game crosses tile edges. Called the way a chunk calls it:
	# one TileFrame and one set of mountains per tile, the tile known, the rim through
	# sample_height_boundary so two tiles agree along the edge they share.
	var data: PlanetData = reader.data
	var frame: PlanetData.TileFrame = null
	if data != null:
		frame = data.make_tile_frame()
		data.prepare_mountain_frame(frame, nside, ipix)
		CrackCarve.prepare_frame(data, frame, nside, ipix)
	var points := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	for vy: int in range(stride):
		for vx: int in range(stride):
			var dir: Vector3 = grid[vy][vx]
			# Per vertex, and by the OUTLINE of the patch it falls in: one rock for a whole tile drew
			# the boundary between two biomes along the edges of the mesh instead of along the shape
			# the level design drew, which reads as rectangles of colour laid over the ground.
			if not paint.is_empty():
				colours.append(RockCatalogue.tint(dir, radius, _rock_at(paint, dir), Color.WHITE))
			var metres: float
			if data != null:
				# Mountains included: the sampler adds them, at this tile's pitch, as it does for a chunk.
				if vx == 0 or vy == 0 or vx == grid_res or vy == grid_res:
					metres = data.sample_height_boundary(dir, ipix, -1, Vector2i(-1, -1), null,
							nside, frame, pitch)
				else:
					metres = data.sample_height_for_direction(dir, ipix, -1, Vector2i(-1, -1), null,
							nside, frame, pitch)
			else:
				# u follows the face's x, v its y — the same parametrisation get_pixel_grid walks, so a
				# vertex and the texel under it are the same place by construction.
				metres = _sample(heights, side,
						float(vx) / float(grid_res), float(vy) / float(grid_res)) * span + base
				# The massifs and crests the level design laid on top of the height field. They are not
				# in the tiles: the game adds them as it builds a chunk. Same call the terrain makes,
				# with the tile's own spacing as the pitch — that is what tells a crest it is narrower
				# than one step and must not be drawn as a spike.
				if mountain_set != null:
					metres += mountain_set.Offset(dir, radius, pitch)
				elif has_relief:
					metres += MountainRelief.offset(dir, radius, mountains, ridges, pitch)
			points.append(dir * (MESH_RADIUS * (1.0 + EXAGGERATION * metres / radius)))
			normals.append(dir)
	_add_patch_indices(indices, points, 0, stride)
	_smooth_normals(points, normals, indices)
	_add_skirt(points, normals, indices, stride,
			MESH_RADIUS * HEALPix.pixel_side_length(nside, 1.0) / float(grid_res))
	# The skirt duplicates the rim, so the colours have to follow it or the array comes out shorter than
	# the vertices and Godot drops the whole lot without a word - a tile that silently loses its colour
	# looks exactly like a tile that was never given one.
	if not colours.is_empty():
		for i: int in _rim_ring(stride):
			colours.append(colours[i])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_NORMAL] = normals
	if colours.size() == points.size():
		arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.set_meta("source_nside", int(from[0]))
	if StarMapGround.DEBUG_GROUND:
		StarMapTiles.stat_add("tiles", 1)
		StarMapTiles.stat_add("provisional", 1 if int(from[0]) < nside else 0)
		StarMapTiles.stat_add("read_us", read - started)
		StarMapTiles.stat_add("build_us", Time.get_ticks_usec() - read)
	return mesh


## Height fields kept for [method surface_factor], by body key. A body with no tiles is cached as an
## empty entry, so the disk is searched once and not once a frame.
##
## Deliberately NOT written by [method build], which runs on a worker: this is read from the main
## thread, and one shared dictionary written from two is a race for no gain. Twelve tile reads is a
## couple of milliseconds, once per body.
static var _fields: Dictionary = {}
## How many resolved tiles a field keeps. It is a memo in front of [StarMapTiles], which holds the heights
## themselves: bounded because the roads ask about thousands of directions across hundreds of tiles.
const FIELD_TILES_KEPT: int = 512


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
	# Through the game's sampler whenever the mesh is, and at the pitch the mesh of that level is built
	# at, so the ground measured is still the ground drawn.
	var data: PlanetData = StarMapTiles.for_body(body_key).data
	if data != null and data.radius > 0.0:
		var pitch: float = data.radius * HEALPix.pixel_angular_size(nside) \
				/ float(StarMapGround.GRID_RES)
		var metres_here: float = data.sample_height_for_direction(dir, -1, -1, Vector2i(-1, -1),
				null, nside, null, pitch)
		return 1.0 + EXAGGERATION * metres_here / data.radius
	var field: Dictionary = _field_for(body_key, nside)
	if field.is_empty():
		return 1.0
	var face: int = HEALPix.vec2pix_nest(nside, dir)
	var tiles: Dictionary = field["tiles"]
	var reader: StarMapTiles = StarMapTiles.for_body(body_key)
	var memo: Dictionary = tiles.get(face, {})
	# A tile resampled from an ancestor is asked again once its own data is there, or the camera would
	# be guarded against the coarse ground for the rest of the session while the fine one is drawn.
	if memo.is_empty() or (not bool(memo["own"]) and reader.has_own(nside, face)):
		# Fetched the same way the MESH fetches it — the tile if it is cached, otherwise its nearest
		# cached ancestor resampled. Any other route here and the camera would be guarded against a
		# surface the screen is not showing, which is the one thing this must never be.
		if tiles.size() >= FIELD_TILES_KEPT:
			tiles.clear()  # the heights themselves live in the reader's cache; this is only a memo
		var from: Array = [0]
		memo = {"h": _tile_or_ancestor(reader, nside, face, from), "own": int(from[0]) == nside}
		tiles[face] = memo
	if (memo["h"] as PackedFloat32Array).is_empty():
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
	var heights: PackedFloat32Array = memo["h"]
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
	if radius > 0.0 and has_data(body_key):
		# Opened empty and filled ONE TILE AT A TIME, as directions come in. This answers about a single
		# point — where the ground is under the camera, how wide the scale bar's stick is — and a view
		# asks about a handful of tiles, never the level's millions. Reading the level up front meant
		# listing a directory and loading several hundred tiles to answer a question about one.
		field = {
			"tiles": {}, "radius": radius,
			"span": float(manifest.get("max_height", 0.0)),
			"base": float(manifest.get("height_offset", 0.0)),
		}
		# Only a field that can answer is remembered. An empty one was kept for good, so a body opened
		# before its floor had landed stayed a smooth sphere to the guard for the rest of the session.
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


## [param from] is an optional one-element slot the level the data actually came from is written into.
## A caller that cares whether it read the tile itself or resampled an ancestor passes [code][0][/code];
## everyone else passes nothing and the walk is unchanged.
##
## Every level goes through [param reader], which keeps what it decodes: an ancestor standing in for
## hundreds of descendants is read once, not once for each of them.
static func _tile_or_ancestor(reader: StarMapTiles, nside: int, ipix: int,
		from: Array = []) -> PackedFloat32Array:
	var level: int = nside
	var at: int = ipix
	while level >= TILE_NSIDE:
		var heights: PackedFloat32Array = reader.heights(level, at)
		# Side deduced from the payload, never from the manifest: the two coincide for published tiles,
		# and planet_data learnt the hard way that assuming it reads out of bounds when they do not.
		var side: int = int(round(sqrt(float(heights.size()))))
		if side > 1 and side * side == heights.size():
			if not from.is_empty():
				from[0] = level
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


## Which rock a direction stands on: the first patch whose outline holds it, else the tile's fallback.
##
## First rather than smallest or last. The patches of a tile do not overlap — they are one partition of
## the ground drawn as separate polygons — so there is nothing to arbitrate, and looking for a better
## answer than the first would only cost the remaining tests.
##
## ⚠️ Longitude is not wrapped. A patch straddling ±180° would be tested against a point on the far
## side of the cut and lost, which would show as that one tile keeping its fallback rock. Left as is:
## the cut is one meridian, and the fallback is the right colour for that ground anyway.
static func _rock_at(paint: Dictionary, dir: Vector3) -> String:
	var patches: Array = paint.get("patches", [])
	if not patches.is_empty():
		var lonlat: Vector2 = HEALPix.vec2lonlat(dir)
		for entry: Variant in patches:
			var patch: Dictionary = entry
			if patch.has("bounds") and not (patch["bounds"] as Rect2).has_point(lonlat):
				continue
			if Geometry2D.is_point_in_polygon(lonlat, patch["polygon"]):
				return str(patch["rock"])
	return str(paint.get("fallback", ""))


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
			# Split along whichever diagonal the ground is FLATTER across.
			#
			# A quad of four heights is not a surface until it is cut in two, and the cut is a fold the
			# lighting shows. Cut every quad the same way and every fold runs the same way, so the whole
			# tile carries a corduroy of parallel creases at forty-five degrees to the grid — which is
			# what showed on screen, on one diagonal and never the other, and no amount of smoothing the
			# height field could touch it because the fold is in the MESH, not in the data.
			#
			# Choosing per quad costs two subtractions and makes the fold follow the terrain instead:
			# along a ridge it lies on the ridge, along a slope it lies on the contour.
			var flat_10_01: bool = absf(points[i10].length() - points[i01].length()) 					<= absf(points[i00].length() - points[i11].length())
			if flip:
				if flat_10_01:
					indices.append_array([i00, i01, i10, i10, i01, i11])
				else:
					indices.append_array([i00, i11, i10, i00, i01, i11])
			elif flat_10_01:
				indices.append_array([i00, i10, i01, i10, i11, i01])
			else:
				indices.append_array([i00, i10, i11, i00, i11, i01])


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
