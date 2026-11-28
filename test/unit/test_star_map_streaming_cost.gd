extends GutTest

## What the chart pays while a body's streamed modifiers come down (RemoteModifierPack), and that it
## stops paying once they are in. Playtest 2026-11-28: the chart opened on Tarsis III fell to 8 FPS and
## drew one relief tile. Each tile asked about every export-level modifier tile UNDER it — a million under
## a tile of the whole-globe view — which put thirty thousand tiles on the download queue in four minutes,
## held the chart's workers for minutes and the main thread with them; and a tile that answered "not yet"
## had its lines laid again, and the whole mesh rebuilt, at every frame.
##
## Nothing here touches the network: the packs are fakes held in memory.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_streaming_cost.gd

## The body the fakes stand in for, by its export level and size: Tarsis III's.
const EXPORT_NSIDE: int = 1024
const RADIUS: float = 6356000.0
## A made-up body for the town test, its manifest seeded into StarMapRelief's cache.
const KEY: String = "streaming_cost_test"
const SMALL_NSIDE: int = 8
const SMALL_RADIUS: float = 1000000.0
const TILE_RES: int = 16


## A streamed pack that counts what it is asked, the tiles of one level of which are on their way.
class _CountingPack extends RemoteModifierPack:
	var asked: int = 0
	var waiting_nside: int = -1

	func tile_state(nside: int, _ipix: int) -> int:
		asked += 1
		return ModifierPack.TILE_PENDING if nside == waiting_nside else ModifierPack.TILE_ABSENT

	func read_tile(_nside: int, _ipix: int) -> PackedByteArray:
		return PackedByteArray()


## Lines of a kind that count how often they are laid and drawn, every tile answering [member data_in].
class _CountingLines extends StarMapTileLines:
	var data_in: bool = false
	var laid: int = 0
	var assembled: int = 0

	func _available() -> bool:
		return true

	func _laying() -> Array:
		laid += 1
		var answer: bool = data_in
		var lay: Callable = func(_id: int) -> Array:
			if not answer:
				return []
			return [PackedVector3Array([Vector3.RIGHT, Vector3.UP]), PackedColorArray([Color.WHITE, Color.WHITE])]
		# On this thread: what is counted is how often the tiles are asked, not a worker's timing.
		return [lay, false]

	func _assemble() -> void:
		assembled += 1
		super._assemble()


func after_each() -> void:
	StarMapRelief._manifests.erase(KEY)
	StarMapTiles._frame_readers.erase(KEY)


## A body the size of Tarsis III whose modifiers stream from [param pack], with a canyon network.
func _streamed_body(pack: RemoteModifierPack) -> PlanetData:
	var data := PlanetData.new()
	data.radius = RADIUS
	data.export_nside = EXPORT_NSIDE
	data.corundum_default_biome = true
	data.crack_spacing_m = 4000.0
	data.crack_width_m = 150.0
	data.remote_modifiers = pack
	data._modifier_pack = pack
	data._modifier_pack_tried = true
	return data


# ---------------------------------------------------------------------------
# What a tile asks
# ---------------------------------------------------------------------------

## A tile of the whole-globe view asks about the modifier tiles its own relief reads — a few dozen — and
## never about the million export tiles under it, which the relief at that level does not read.
func test_a_coarse_tile_asks_about_a_handful_of_tiles() -> void:
	var pack := _CountingPack.new()
	var data: PlanetData = _streamed_body(pack)
	assert_false(StarMapCanyons.awaits_modifiers(data, 1, 4), "nothing on its way at its level")
	assert_lt(pack.asked, 64, "a handful of tiles asked, not the %d under it" % (EXPORT_NSIDE * EXPORT_NSIDE))
	pack.asked = 0
	assert_false(StarMapCanyons.awaits_zones(data, 1, 4), "the canyons do not trace it either")
	assert_lt(pack.asked, 64, "and do not walk what is under it")


## The export tiles under the ones the canyons DO trace are still waited for: a zone tile on its way
## reads as no zone, and a canyon would be laid across a massif.
func test_a_traced_tile_still_waits_for_the_zones_under_it() -> void:
	var pack := _CountingPack.new()
	pack.waiting_nside = EXPORT_NSIDE
	var data: PlanetData = _streamed_body(pack)
	var nside: int = EXPORT_NSIDE >> 3
	assert_true(StarMapCanyons.traces(data, nside), "sanity: the canyons trace n%d here" % nside)
	assert_false(StarMapCanyons.awaits_modifiers(data, nside, 9), "its relief reads its own level, which is in")
	pack.asked = 0
	assert_true(StarMapCanyons.awaits_zones(data, nside, 9), "its zones are on their way")
	assert_lte(pack.asked, 64 + 64, "the 64 export tiles under it, and its own set")


# ---------------------------------------------------------------------------
# A tile that answers "not yet"
# ---------------------------------------------------------------------------

## A tile waiting on its streamed data is asked again after a while, not at every frame, and nothing is
## rebuilt meanwhile; once its data is in it is laid, drawn, and the frames after cost nothing.
func test_a_waiting_tile_is_not_laid_again_at_every_frame() -> void:
	var lines := _CountingLines.new()
	add_child_autofree(lines)
	var view: Dictionary = {StarMapGround.tile_id(SMALL_NSIDE, 3): true}
	lines.refresh(view)
	assert_eq(lines.laid, 1, "asked once")
	for _frame: int in range(30):
		lines.refresh(view)
	assert_eq(lines.laid, 1, "not asked again while the wait lasts")
	assert_eq(lines.assembled, 1, "and nothing put together again")
	lines.data_in = true
	lines._retry_at_ms = 0  # the wait over
	lines.refresh(view)
	assert_eq(lines.laid, 2, "asked again once the wait is over")
	assert_not_null(lines.mesh, "and drawn, its data in")
	var settled: int = lines.assembled
	for _frame: int in range(30):
		lines.refresh(view)
	assert_eq(lines.laid, 2, "settled: never asked again")
	assert_eq(lines.assembled, settled, "nor drawn again")


## A wait is set by a tile that answered "not yet", and only by one: lines all laid never come back.
func test_lines_all_laid_set_no_wait() -> void:
	var lines := _CountingLines.new()
	lines.data_in = true
	add_child_autofree(lines)
	lines.refresh({StarMapGround.tile_id(SMALL_NSIDE, 3): true})
	assert_eq(lines._retry_at_ms, -1)


# ---------------------------------------------------------------------------
# A town over relief still streaming in
# ---------------------------------------------------------------------------

## A flat plateau whose every level down to SMALL_NSIDE is in memory, its modifiers streamed by [param pack].
func _plateau(pack: RemoteModifierPack) -> PlanetData:
	var data := PlanetData.new()
	data.planet_name = KEY
	data.radius = SMALL_RADIUS
	data.max_height = 500.0
	data.height_offset = 0.0
	data.terrain_exaggeration = 1.0
	data.chunk_heightmap_res = TILE_RES
	data.chunk_resolution = 32
	data.max_quadtree_depth = 6
	data.export_nside = SMALL_NSIDE
	data.export_nside_min = 1
	data.chunk_is_pyramid = true
	data.chunk_heightmaps_dir = ""
	var nside: int = 1
	while nside <= SMALL_NSIDE:
		for ipix: int in range(12 * nside * nside):
			var flat := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
			flat.fill(Color(0.5, 0.0, 0.0))
			data.store_chunk_image("hp_n%d_p%d" % [nside, ipix], flat, [])
		nside *= 2
	data.set_mountain_overrides([], [])
	data.remote_modifiers = pack
	data._modifier_pack = pack
	data._modifier_pack_tried = true
	return data


## A town read while its massif was on its way is not sampled again while it still is — that was two
## height samples a town at every frame — and is, once it has landed.
func test_a_waiting_town_is_read_again_once_its_ground_lands() -> void:
	StarMapRelief._manifests[KEY] = {"radius": SMALL_RADIUS, "nside_max": SMALL_NSIDE, "max_height": 500.0,
			"height_offset": 0.0}
	var pack := _CountingPack.new()
	pack.waiting_nside = SMALL_NSIDE
	var reader := StarMapTiles.new()
	reader.body_key = KEY
	reader.data = _plateau(pack)
	StarMapTiles._frame = Engine.get_process_frames()
	StarMapTiles._frame_readers[KEY] = reader
	var layer := StarMapPoiLayer.new()
	add_child_autofree(layer)
	var town: Dictionary = {"dir": HEALPix.pix2vec_nest(SMALL_NSIDE, 4 * SMALL_NSIDE * SMALL_NSIDE + 50)}
	var list: Array[Dictionary] = [town]
	layer.entries = list
	layer._read_heights(KEY, true)
	assert_true(bool(town["ground_pending"]), "read over relief on its way, and known as such")
	var marked: float = 42.0
	town["surface"] = marked  # what a second sample would overwrite
	layer._read_heights(KEY, false)
	assert_eq(float(town["surface"]), marked, "still waiting: not sampled again")
	assert_gt(layer._heights_retry_at_ms, Time.get_ticks_msec(), "and asked again in a moment, not next frame")
	pack.waiting_nside = -1
	layer._read_heights(KEY, false)
	assert_false(bool(town["ground_pending"]), "landed")
	assert_ne(float(town["surface"]), marked, "and read again")
	assert_false(layer._heights_waiting, "nothing left to ask about")
