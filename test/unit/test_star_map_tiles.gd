extends GutTest

## Where the star chart reads a body's heights ([StarMapTiles]), what it costs, and the C# mountains its
## tiles are lifted by.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_tiles.gd

## The body most likely to have been walked on, hence to have tiles cached.
const BODY: String = "tarsis_3"
const RADIUS: float = 6356000.0
## Subdivisions per tile edge, as [StarMapGround] asks for them.
const RES: int = 24


## Prepare the body's PlanetData once, before any test: it prints as it opens its manifest and packs,
## and on a machine whose C# build lacks its dependency assemblies every print throws inside the
## OpenTelemetry bridge — which GUT would pin on whichever test happened to prepare it first.
func before_all() -> void:
	StarMapTiles.offline_data(BODY)


# ---------------------------------------------------------------------------
# Where the heights are read from
# ---------------------------------------------------------------------------

## A reader holding the whole-globe level and nothing finer, counting what it is asked.
class _GlobeOnly extends StarMapTiles:
	var asked: Dictionary = {}
	var ramp: PackedFloat32Array = PackedFloat32Array()

	func heights(nside: int, ipix: int) -> PackedFloat32Array:
		asked[nside] = int(asked.get(nside, 0)) + 1
		return ramp if nside == 1 and ipix == 0 else PackedFloat32Array()


## Every level of the ancestor walk goes through the reader, so the reader's cache is what serves an
## ancestor standing in for its descendants — not a fresh read of the file for each of them.
func test_the_ancestor_walk_reads_through_the_reader() -> void:
	var reader := _GlobeOnly.new()
	var side: int = 8
	for i: int in range(side * side):
		reader.ramp.append(float(i) / float(side * side))
	var from: Array = [0]
	var got: PackedFloat32Array = StarMapRelief._tile_or_ancestor(reader, 4, 5, from)
	assert_eq(int(from[0]), 1, "stood in for by the globe tile")
	assert_eq(got, StarMapRelief._sub_tile(reader.ramp, side, 4, 5), "and cut from it where it lies")
	assert_eq(int(reader.asked.get(4, 0)), 1, "its own level asked once")
	assert_eq(int(reader.asked.get(1, 0)), 1, "the globe asked once")


## The disk reader keeps what it decodes.
func test_the_disk_reader_decodes_a_tile_once() -> void:
	if StarMapTiles.cached_version(BODY) == "":
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	var reader: StarMapTiles = StarMapTiles.on_disk(BODY)
	var first: PackedFloat32Array = reader.heights(1, 0)
	assert_false(first.is_empty(), "the floor is on disk")
	var bucket: String = "%s/%s" % [BODY, reader.source.version]
	assert_true((StarMapTiles._floats[bucket] as Dictionary).has(StarMapGround.tile_id(1, 0)),
			"kept after the first read")
	assert_eq(reader.heights(1, 0), first, "and served from memory after")


## A body found empty is looked at again, rather than empty for the rest of the session.
##
## The probe this replaces read the version once: made before the floor had landed, it said "no tile
## is cached" for ever, and no provisional tile was ever built again.
func test_an_empty_version_is_looked_up_again() -> void:
	if StarMapRelief._cached_version(BODY) == "":
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	var now: int = Time.get_ticks_msec()
	StarMapTiles._versions[BODY] = {"version": "", "at": now}
	assert_eq(StarMapTiles.cached_version(BODY), "", "believed for a moment")
	StarMapTiles._versions[BODY] = {"version": "", "at": now - StarMapTiles.NO_VERSION_RETRY_MS - 1}
	assert_ne(StarMapTiles.cached_version(BODY), "", "then the disk is looked at again")


## The read counters say what share of a build went on reading heights — the figure that decides
## whether aligning the chart's levels on the planet's could be worth anything.
func test_the_read_counters_report_the_share_of_a_build() -> void:
	var line: String = StarMapTiles.stats_line({
		"tiles": 4, "provisional": 1, "read_us": 1000, "build_us": 19000,
		"planet_hit": 3, "planet_hit_us": 30, "disk_read": 1, "disk_read_us": 500,
	})
	assert_string_contains(line, "4 tuiles, 1 provisoires")
	assert_string_contains(line, "5.00 ms/tuile")
	assert_string_contains(line, "(5.0 %)", "a thousand of twenty thousand microseconds")
	assert_string_contains(line, "planet_hit 75% (3, 10 us moy.)")
	assert_eq(StarMapTiles.stats_line({}), "aucune tuile construite")


## The mountains summed in C# lift the ground exactly as the GDScript sum does — the C# path is what
## made a tile under mountains affordable, and it may not draw different mountains for it.
func test_native_mountains_draw_the_same_ground() -> void:
	if not StarMapRelief.has_data(BODY) or not MountainRelief.native_available():
		pending("pas de tuiles %s ou pas d'assembly C# sur cette machine" % BODY)
		return
	var zones := StarMapZones.new()
	zones.body_key = BODY
	zones.default_rock = ""
	zones.m_per_deg = RADIUS * PI / 180.0
	var compared: bool = false
	for poi: Dictionary in StarMapPoi.load_for(BODY):
		var ipix: int = HEALPix.vec2pix_nest(256, poi["dir"])
		var paint: Dictionary = zones.tile_of(256, ipix)
		if paint["mountain_set"] == null:
			continue
		var scripted: Dictionary = paint.duplicate()
		scripted["mountain_set"] = null
		# On the chart's own sampler, the fallback that sums the paint's mountains itself: the game's
		# sampler brings its own.
		var disk: StarMapTiles = StarMapTiles.on_disk(BODY)
		var a: ArrayMesh = StarMapRelief.build_tile(BODY, 256, ipix, RES, paint, disk)
		var b: ArrayMesh = StarMapRelief.build_tile(BODY, 256, ipix, RES, scripted, disk)
		if a == null or b == null:
			continue
		var pa: PackedVector3Array = a.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var pb: PackedVector3Array = b.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var worst: float = 0.0
		for i: int in range(pa.size()):
			worst = maxf(worst, absf(pa[i].length() - pb[i].length()) / StarMapRelief.MESH_RADIUS * RADIUS)
		assert_lt(worst, 1.0, "%s: native and GDScript mountains within a metre" % str(poi["label"]))
		compared = true
		break
	zones.close()
	if not compared:
		pending("aucune tuile de montagne sous un lieu de %s" % BODY)


## THE claim of drawing through the game's sampler: every vertex of a chart tile stands where the game
## puts the ground at that level — mountains included — so a ship arriving over a place finds what the
## chart showed. Before, the chart kept its own reading: within 4 m on average at n256 and n1024 but
## out by up to 175 m there, and by 750 m at n16.
func test_the_chart_draws_the_game_s_ground() -> void:
	var data: PlanetData = StarMapTiles.for_body(BODY).data
	if data == null:
		pending("pas de PlanetData ou de tuiles %s sur cette machine" % BODY)
		return
	for level: int in [16, 256, 1024]:
		var ipix: int = -1
		for poi: Dictionary in StarMapPoi.load_for(BODY):
			if str(poi["label"]) == "Mining village 02":
				ipix = HEALPix.vec2pix_nest(level, poi["dir"])
		var mesh: ArrayMesh = StarMapRelief.build_tile(BODY, level, ipix, RES)
		assert_not_null(mesh, "n%d builds" % level)
		if mesh == null:
			continue
		var points: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var pitch: float = data.radius * HEALPix.pixel_angular_size(level) / float(RES)
		# The grid's own directions, not the vertices' read back: those are float32, and on a cliff a
		# direction off by 1e-7 rad reads a ground metres away.
		var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(level, ipix, RES)
		var worst: float = 0.0
		# The interior only: the rim goes through sample_height_boundary, as a chunk's does.
		for vy: int in range(1, RES):
			for vx: int in range(1, RES):
				var p: Vector3 = points[vy * (RES + 1) + vx]
				var drawn: float = (p.length() / StarMapRelief.MESH_RADIUS - 1.0) * data.radius
				var game: float = data.sample_height_for_direction(grid[vy][vx], -1, -1,
						Vector2i(-1, -1), null, level, null, pitch)
				worst = maxf(worst, absf(drawn - game))
		assert_lt(worst, 1.0, "n%d: the chart's ground is the game's, to the metre" % level)
