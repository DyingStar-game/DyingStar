extends GutTest

## The chart's relief over STREAMED modifiers: the massifs, ridges, volcanoes and rock fields the ground
## is shaped by come down tile by tile (RemoteModifierPack) since 2026-11-18, and the chart lost them —
## its copy of a body that is not loaded never took the streamed pack, and a tile drawn while its
## modifier tile was on its way stayed flat for good (playtest 2026-11-28: "the mountains no longer
## show on the chart").
##
## Everything but the last test runs on a made-up plateau held in memory, with a fake pack: nothing here
## touches the network.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_streamed_relief.gd

## The made-up body: its manifest is seeded into StarMapRelief's cache, its reader into StarMapTiles'.
const KEY: String = "streamed_relief_test"
## A real body, for the one claim about the chart's copy of a scene's planet.
const BODY: String = "tarsis_3"
const RADIUS: float = 1000000.0
const NSIDE: int = 8
const TILE_RES: int = 16
## Well inside an equatorial face (see test_star_map_canyons.gd).
const IPIX: int = 4 * NSIDE * NSIDE + 50
## Steps per edge of the tiles built here: few, the claims are about what a tile SAYS, not its shape.
const GRID: int = 4


## A streamed pack holding nothing, the tiles of ONE level of which are still on their way.
class _StreamingPack extends RemoteModifierPack:
	## The level whose tiles are published and not downloaded yet; none when negative.
	var waiting_nside: int = -1

	func tile_state(nside: int, _ipix: int) -> int:
		return ModifierPack.TILE_PENDING if nside == waiting_nside else ModifierPack.TILE_ABSENT

	func read_tile(_nside: int, _ipix: int) -> PackedByteArray:
		return PackedByteArray()


## A streamed pack whose manifest says the body has massifs, as a published one does; its tiles hold
## nothing.
class _MountainPack extends RemoteModifierPack:
	func _init() -> void:
		_apply_manifest({"parts": {"mountain": {"counts": {"features": 1}}}})
		_path = "fake://mountains"

	func tile_state(_nside: int, _ipix: int) -> int:
		return ModifierPack.TILE_ABSENT

	func read_tile(_nside: int, _ipix: int) -> PackedByteArray:
		return PackedByteArray()


var _shared_before: Variant = null
var _stream_before: bool = false


func before_each() -> void:
	StarMapRelief._manifests[KEY] = {"radius": RADIUS, "nside_max": NSIDE, "max_height": 500.0,
			"height_offset": 0.0}
	_shared_before = RemoteModifierPack._shared.get(BODY)
	_stream_before = StarMapTiles.stream_modifiers


func after_each() -> void:
	StarMapRelief._manifests.erase(KEY)
	StarMapTiles._frame_readers.erase(KEY)
	if _shared_before == null:
		RemoteModifierPack._shared.erase(BODY)
	else:
		RemoteModifierPack._shared[BODY] = _shared_before
	StarMapTiles.stream_modifiers = _stream_before
	StarMapTiles.forget(BODY)  # no copy made here outlives the test


## A flat plateau whose every level down to NSIDE is in memory, no massif, and the pack [param pack]
## attached as the streamed one.
func _plateau(pack: RemoteModifierPack) -> PlanetData:
	var data := PlanetData.new()
	data.planet_name = KEY
	data.radius = RADIUS
	data.max_height = 500.0
	data.height_offset = 0.0
	data.terrain_exaggeration = 1.0
	data.chunk_heightmap_res = TILE_RES
	data.chunk_resolution = 32
	data.max_quadtree_depth = 6
	data.export_nside = NSIDE
	data.export_nside_min = 1
	data.chunk_is_pyramid = true
	data.chunk_heightmaps_dir = ""
	var nside: int = 1
	while nside <= NSIDE:
		for ipix: int in range(12 * nside * nside):
			var flat := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
			flat.fill(Color(0.5, 0.0, 0.0))
			data.store_chunk_image("hp_n%d_p%d" % [nside, ipix], flat, [])
		nside *= 2
	data.set_mountain_overrides([], [])  # warms what the sampler reads, with no mountain
	data.remote_modifiers = pack
	data._modifier_pack = pack
	data._modifier_pack_tried = true
	return data


## The reader the chart resolves for [constant KEY] this frame ([method StarMapTiles.for_body]).
func _resolve(data: PlanetData) -> StarMapTiles:
	var reader := StarMapTiles.new()
	reader.body_key = KEY
	reader.data = data
	StarMapTiles._frame = Engine.get_process_frames()
	StarMapTiles._frame_readers[KEY] = reader
	return reader


## A ground over [constant KEY] that wants the one tile and shows [param mesh] for it.
func _ground_showing(mesh: Mesh) -> StarMapGround:
	var ground := StarMapGround.new()
	ground.body_key = KEY
	add_child_autofree(ground)
	var id: int = StarMapGround.tile_id(NSIDE, IPIX)
	ground._desired[id] = true
	var node := MeshInstance3D.new()
	node.mesh = mesh
	ground.add_child(node)
	ground._active[id] = node
	ground._built_from[id] = NSIDE
	return ground


# ---------------------------------------------------------------------------
# A tile drawn before its massifs
# ---------------------------------------------------------------------------

## A tile built while a modifier tile it is shaped by streams in says so, and the planet it was read
## through; one built with everything in says it is final.
func test_a_tile_built_while_its_modifiers_stream_in_says_so() -> void:
	var pack := _StreamingPack.new()
	pack.waiting_nside = NSIDE
	var data: PlanetData = _plateau(pack)
	var reader: StarMapTiles = _resolve(data)
	var early: ArrayMesh = StarMapRelief.build_tile(KEY, NSIDE, IPIX, GRID, {}, reader)
	assert_not_null(early, "sanity: the plateau is in memory")
	if early == null:
		return
	assert_true(bool(early.get_meta(StarMapRelief.META_MODIFIERS_PENDING)), "drawn without its massifs, and says so")
	assert_eq(int(early.get_meta(StarMapRelief.META_READ_THROUGH)), data.get_instance_id(),
			"and which planet it was read through")
	pack.waiting_nside = -1
	var late: ArrayMesh = StarMapRelief.build_tile(KEY, NSIDE, IPIX, GRID, {}, reader)
	assert_false(bool(late.get_meta(StarMapRelief.META_MODIFIERS_PENDING)), "everything in: final")


## That tile is not kept as final: asked about at each decision, it is left alone while its tiles are
## still on their way — built again now it would come back just as flat — and built again, over the one
## on screen, once they have landed.
func test_a_tile_drawn_flat_is_built_again_once_its_modifiers_land() -> void:
	var pack := _StreamingPack.new()
	pack.waiting_nside = NSIDE
	var data: PlanetData = _plateau(pack)
	var reader: StarMapTiles = _resolve(data)
	var mesh: ArrayMesh = StarMapRelief.build_tile(KEY, NSIDE, IPIX, GRID, {}, reader)
	assert_not_null(mesh, "sanity: the plateau is in memory")
	if mesh == null:
		return
	var ground: StarMapGround = _ground_showing(mesh)
	var id: int = StarMapGround.tile_id(NSIDE, IPIX)
	assert_eq(ground._retry_outdated(6), 0, "still on their way: nothing to gain yet")
	assert_false(ground._pending.has(id), "not queued")
	pack.waiting_nside = -1
	_resolve(data)
	assert_eq(ground._retry_outdated(6), 1, "landed: worth building again")
	assert_true(ground._pending.has(id), "queued")
	assert_true(ground._redo.has(id), "as a rebuild of the one on screen")
	assert_true(ground._active.has(id), "which stays up until its replacement is")
	assert_eq(ground._retry_outdated(6), 0, "and asked once, not at every decision")


## A tile read through another planet than the body is read through now is built again: the chart's
## copy of a body, made before its modifiers were open, knew no mountain.
func test_a_tile_read_through_another_planet_is_built_again() -> void:
	var before: PlanetData = _plateau(_StreamingPack.new())
	var mesh: ArrayMesh = StarMapRelief.build_tile(KEY, NSIDE, IPIX, GRID, {}, _resolve(before))
	assert_not_null(mesh, "sanity: the plateau is in memory")
	if mesh == null:
		return
	var ground: StarMapGround = _ground_showing(mesh)
	var id: int = StarMapGround.tile_id(NSIDE, IPIX)
	assert_eq(ground._retry_outdated(6), 0, "read through the planet the body is read through: final")
	_resolve(_plateau(_StreamingPack.new()))
	assert_eq(ground._retry_outdated(6), 1, "another planet now: built again")
	assert_true(ground._pending.has(id) and ground._redo.has(id), "over the one on screen")


## A stand-in with no reading on it (a test's bare mesh) is left alone: nothing says it is outdated.
func test_a_tile_with_no_reading_is_left_alone() -> void:
	_resolve(_plateau(_StreamingPack.new()))
	var ground: StarMapGround = _ground_showing(BoxMesh.new())
	assert_eq(ground._retry_outdated(6), 0)


# ---------------------------------------------------------------------------
# The chart's copy of a body that is not loaded
# ---------------------------------------------------------------------------

## The shared pack is looked up, never opened: a body nobody opened has none, and asking costs no network.
func test_the_shared_pack_is_looked_up_and_never_opened() -> void:
	RemoteModifierPack._shared.erase(BODY)
	assert_null(RemoteModifierPack.shared_if_open(BODY), "nobody opened it: none, and nothing was asked of the service")
	assert_false(RemoteModifierPack._shared.has(BODY), "and nothing was remembered as tried either")
	var pack := _MountainPack.new()
	RemoteModifierPack._shared[BODY] = {"pack": pack, "msec": Time.get_ticks_msec()}
	assert_true(RemoteModifierPack.shared_if_open(BODY) == pack, "opened by someone else: that one")
	RemoteModifierPack._shared[BODY] = {"pack": null, "msec": Time.get_ticks_msec()}
	assert_null(RemoteModifierPack.shared_if_open(BODY), "tried and failed: none")


## The copy takes the body's streamed modifiers once the pack is open — and with them its mountains —
## as a NEW copy, the one made before staying as it was for whatever is still reading it. Out of the
## chart it reads none, as every suite that takes a copy as its fixture expects.
func test_the_offline_copy_has_its_mountains_once_the_pack_is_open() -> void:
	RemoteModifierPack._shared.erase(BODY)
	StarMapTiles.stream_modifiers = true
	StarMapTiles.forget(BODY)
	var early: PlanetData = StarMapTiles.offline_data(BODY)
	if early == null:
		pending("pas de PlanetData ou de tuiles %s sur cette machine" % BODY)
		return
	assert_null(early.remote_modifiers, "the pack is not open: the copy has none, and opened none")
	assert_true(StarMapTiles.offline_data(BODY) == early, "and is kept while nothing changes")
	var pack := _MountainPack.new()
	RemoteModifierPack._shared[BODY] = {"pack": pack, "msec": Time.get_ticks_msec()}
	var late: PlanetData = StarMapTiles.offline_data(BODY)
	assert_false(late == early, "made again once the pack is open")
	assert_true(late.remote_modifiers == pack, "reading the body's shared streamed pack")
	assert_true(late.mountains_active(), "and its mountains")
	assert_null(early.remote_modifiers, "the old copy is left as it was")
	assert_true(StarMapTiles.offline_data(BODY) == late, "kept from then on")
	StarMapTiles.stream_modifiers = false
	assert_null(StarMapTiles.offline_data(BODY).remote_modifiers, "out of the chart: no modifier")
