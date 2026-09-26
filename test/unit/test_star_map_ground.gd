extends GutTest

## The star chart's ground: the set of tiles on screen, and how it changes.
##
## [StarMapGround] exists because the thing it replaced could not be made to work. A single mesh was
## rebuilt wholesale whenever anything changed; the rebuild produced a camera guard, the guard moved the
## camera, the moved camera chose another level, and the level asked for another rebuild. What is pinned
## here is the property that breaks that: the wanted set is recomputed from scratch, and the world is
## changed only BY THE DIFFERENCE — so a view that has not moved costs nothing at all.
##
## Deliberately runs with NO tile cache. The whole-globe level takes its twelve pixels from HEALPix
## arithmetic rather than from disk, so every claim below holds on a checkout that has never run the
## game. Building a tile needs the cache, and that is covered in test_star_map_relief.gd.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_ground.gd

## A body with no manifest and no tiles, which is what pins the ground to the globe level.
const NOWHERE: String = "no_such_body"
## A body that exists only as a manifest, seeded into StarMapRelief's cache. It is what lets a FINE
## level be exercised on a machine with no tiles at all: the level and the patch are decided from the
## manifest and from HEALPix arithmetic, and nothing on the way there touches the disk.
const MADE_UP: String = "test_only_body"
const RADIUS: float = 6356000.0
## Pixels in the whole globe: 12·1².
const GLOBE_TILES: int = 12


func before_each() -> void:
	StarMapRelief._manifests[MADE_UP] = {"radius": RADIUS, "nside_max": 64}


func after_each() -> void:
	StarMapRelief._manifests.erase(MADE_UP)


func _ground(key: String = NOWHERE) -> StarMapGround:
	var ground := StarMapGround.new()
	ground.body_key = key
	add_child_autofree(ground)
	return ground


## Fill in every tile the ground currently wants, as if the workers had all finished.
func _build_all(ground: StarMapGround) -> void:
	for id: int in ground._desired:
		if not ground._active.has(id):
			_place(ground, StarMapGround.id_nside(id), StarMapGround.id_ipix(id))
	ground._pending.clear()


## A stand-in for a built tile. The diff only ever asks whether a key is present and frees the node it
## finds, so a bare node is a faithful one.
func _place(ground: StarMapGround, nside: int, ipix: int) -> void:
	var node := Node3D.new()
	ground.add_child(node)
	ground._active[StarMapGround.tile_id(nside, ipix)] = node


# ---------------------------------------------------------------------------
# The key
# ---------------------------------------------------------------------------

## The level and the pixel share one integer, and that is what makes the diff, the ancestor walk and
## every lookup in this file a single integer operation.
##
## Checked at the top end rather than on small numbers, because the claim is about the packing holding:
## n8192 is past the finest level any body publishes, and 12·8192² is past the largest index that level
## can produce.
func test_a_level_and_a_pixel_share_one_key() -> void:
	for nside: int in [1, 2, 8, 1024, 8192]:
		for ipix: int in [0, 1, 11, 12 * nside * nside - 1]:
			var id: int = StarMapGround.tile_id(nside, ipix)
			assert_eq(StarMapGround.id_nside(id), nside, "level survives the round trip")
			assert_eq(StarMapGround.id_ipix(id), ipix, "pixel survives the round trip")


## And two different tiles never collide on one key — which, if it happened, would show as a tile that
## refuses to build because the chart believes it is already up.
func test_two_tiles_never_share_a_key() -> void:
	var seen: Dictionary = {}
	for nside: int in [1, 2, 4, 8]:
		for ipix: int in range(12 * nside * nside):
			var id: int = StarMapGround.tile_id(nside, ipix)
			assert_false(seen.has(id), "n%d f%d has a key of its own" % [nside, ipix])
			seen[id] = true


# ---------------------------------------------------------------------------
# The diff
# ---------------------------------------------------------------------------

## A first decision wants the whole globe and queues all of it.
func test_a_first_decision_queues_the_whole_globe() -> void:
	var ground: StarMapGround = _ground()
	ground._decide(Vector3.UP, -1.0)
	assert_eq(ground.level(), 1, "no manifest, so the coarsest level there is")
	assert_eq(ground.tiles_wanted(), GLOBE_TILES, "twelve pixels cover the sphere")
	assert_eq(ground.tiles_up(), 0, "and none of them is built yet")
	assert_eq(ground._pending.size(), GLOBE_TILES, "all twelve are queued")


## THE claim of the rewrite: deciding again on a view that has not moved asks for nothing.
##
## This is the whole difference from what came before, where an unchanged view rebuilt the same mesh
## every few seconds for as long as the chart was open. Measured there at 235 tiles, then 130, then 235
## again, at one unchanging level.
func test_an_unchanged_view_asks_for_nothing() -> void:
	var ground: StarMapGround = _ground()
	ground._decide(Vector3.UP, -1.0)
	for ipix: int in range(GLOBE_TILES):
		_place(ground, 1, ipix)
	ground._pending.clear()

	ground._decide(Vector3.UP, -1.0)
	assert_eq(ground._pending.size(), 0, "nothing to queue")
	assert_eq(ground.tiles_up(), GLOBE_TILES, "and nothing thrown away either")
	ground._decide(Vector3.UP.rotated(Vector3.RIGHT, 0.01), -1.0)
	assert_eq(ground._pending.size(), 0, "a nudge of the camera is still nothing to do")


## What is queued comes nearest-first, so the ground fills in under the eye rather than behind the body.
func test_the_queue_starts_under_the_camera() -> void:
	var ground: StarMapGround = _ground()
	var eye: Vector3 = Vector3(0.3, 0.8, -0.5).normalized()
	ground._decide(eye, -1.0)
	assert_eq(StarMapGround.id_ipix(ground._pending[0]), HEALPix.vec2pix_nest(1, eye),
			"the first tile queued is the one the camera is over")


# ---------------------------------------------------------------------------
# Replacing one surface with another
# ---------------------------------------------------------------------------

## A tile of the level being drawn that nobody wants any more has left the VIEW, and goes at once.
##
## This suite asserted the opposite at first, because it took the function's own wording — "is this tile
## superseded" — for the question the caller asks, which is "may I drop this". Nothing supersedes a tile
## that has merely gone out of view, so nothing ever let one go, and the ground piled up: 187 tiles on
## screen for 84 wanted while panning, 332 for 12 after pulling back. A test written from the callee's
## vocabulary instead of the caller's need, and it passed all the way through.
func test_a_current_tile_that_left_the_view_goes_at_once() -> void:
	var ground: StarMapGround = _ground()
	ground._level = 2
	assert_true(ground._may_drop(StarMapGround.tile_id(2, 5)),
			"it is not waiting for anything: nothing is coming to replace it")


## Going FINER, a coarse tile has to wait for all four of its children. Dropping it while one is still
## building opens a hole in the body for as long as that build takes — and at a level change, that is
## every tile at once.
func test_a_coarse_tile_waits_for_all_four_children() -> void:
	var ground: StarMapGround = _ground()
	ground._level = 2
	var parent: int = StarMapGround.tile_id(1, 3)
	for k: int in range(4):
		ground._desired[StarMapGround.tile_id(2, 3 * 4 + k)] = true
	for k: int in range(3):
		_place(ground, 2, 3 * 4 + k)
	assert_false(ground._may_drop(parent), "three children up out of four is a hole")
	_place(ground, 2, 3 * 4 + 3)
	assert_true(ground._may_drop(parent), "all four, and the parent may go")


## Going COARSER, a fine tile is replaced by a single ancestor, so it may go the moment that ancestor is
## up — and the walk to it has to be right at more than one step, since zooming out crosses several
## levels in one gesture.
func test_a_fine_tile_goes_once_its_ancestor_is_up() -> void:
	var ground: StarMapGround = _ground()
	ground._level = 1
	# n8 pixel 700, whose n1 ancestor is 700 >> 6 — two bits per level, three levels.
	var fine: int = StarMapGround.tile_id(8, 700)
	var ancestor: int = 700 >> 6
	assert_eq(HEALPix.vec2pix_nest(1, HEALPix.pix2vec_nest(8, 700)), ancestor,
			"sanity: the shift really does name the tile that covers it")
	assert_false(ground._may_drop(fine), "nothing else drawn yet, so it is all there is")
	_place(ground, 1, ancestor)
	assert_true(ground._may_drop(fine), "its ground is drawn by the ancestor now")


## More than one level apart the other way, the covering set is sixteen tiles or more, and the ground
## deliberately does not walk it: it waits for the queue to drain instead. Leaving two surfaces stacked
## for a moment is cheaper than the bookkeeping, and a two-level jump inward is rare.
func test_a_two_level_jump_waits_for_the_queue() -> void:
	var ground: StarMapGround = _ground()
	ground._level = 8
	var coarse: int = StarMapGround.tile_id(1, 2)
	ground._pending.append(StarMapGround.tile_id(8, 0))
	assert_false(ground._may_drop(coarse), "something is still queued")
	ground._pending.clear()
	assert_true(ground._may_drop(coarse), "queue empty, so what is up is all there will be")


## And the diff actually removes what it may: a stale tile whose replacement is on screen goes away,
## while one whose replacement is not stays, because dropping it would leave a hole.
func test_the_diff_drops_only_what_is_covered() -> void:
	var ground: StarMapGround = _ground()
	ground._decide(Vector3.UP, -1.0)
	# Two leftovers from a finer level: one whose n1 ancestor is up, one whose is not.
	_place(ground, 4, 0)
	_place(ground, 4, 11 * 16)
	_place(ground, 1, 0)
	var covered: int = StarMapGround.tile_id(4, 0)
	var orphan: int = StarMapGround.tile_id(4, 11 * 16)

	ground._decide(Vector3.UP, -1.0)
	assert_false(ground._active.has(covered), "its ancestor is drawn, so it goes")
	assert_true(ground._active.has(orphan),
			"nothing has replaced this one; dropping it would leave a hole")


# ---------------------------------------------------------------------------
# What is on screen, in total
# ---------------------------------------------------------------------------

## Panning at one level must not make the ground GROW.
##
## The one claim this suite was missing, and the one the game went on to break. Every case above asks
## about a single tile, and every one of them passed while the set as a whole ran away: measured in game
## at 116 tiles for 88 wanted, then 146, 158, 162, 164, 187 — climbing for as long as the camera moved,
## because a tile that merely left the view was never let go. Near the ground, where the level is fine and
## the patch slides furthest for a given turn, it ran away fastest. So this asks the aggregate question:
## after a decision, is there anything on screen that nothing wants and nothing is replacing?
func test_panning_does_not_let_the_ground_grow() -> void:
	var ground: StarMapGround = _ground(MADE_UP)
	# Low enough to land on a fine level, so the patch actually moves as the camera turns — at the globe
	# the wanted set is the same twelve whatever the camera does, and this would test nothing.
	var altitude: float = 4.0e4
	var eye: Vector3 = Vector3.UP
	ground._decide(eye, altitude)
	assert_gt(ground.level(), 1, "sanity: a fine level, or there is no patch to slide")
	_build_all(ground)
	var first: int = ground.tiles_up()
	assert_gt(first, 20, "sanity: a patch of some size")

	var peak: int = first
	for step: int in range(12):
		eye = eye.rotated(Vector3.RIGHT, 0.02).normalized()
		ground._decide(eye, altitude)
		_build_all(ground)
		peak = maxi(peak, ground.tiles_up())
		assert_lte(ground.tiles_up(), ground.tiles_wanted(),
				"pas %d: nothing may stay on screen that nothing wants" % step)
	assert_lt(peak, first * 2, "and the total never runs away as the view slides")


## Pulling right back to the globe leaves the globe, and not a pile of fine tiles over it.
##
## Measured in game at 332 tiles on screen for the twelve the globe wants.
func test_pulling_back_to_the_globe_clears_the_fine_tiles() -> void:
	var ground: StarMapGround = _ground(MADE_UP)
	ground._decide(Vector3.UP, 4.0e4)
	_build_all(ground)
	assert_gt(ground.tiles_up(), 20, "sanity: a fine patch to clear")

	# Twice: the first decision brings the globe in, and a coarse tile may only be trusted to cover its
	# descendants once it is actually up.
	ground._decide(Vector3.UP, -1.0)
	_build_all(ground)
	ground._decide(Vector3.UP, -1.0)
	assert_eq(ground.level(), 1, "back to the globe")
	assert_eq(ground.tiles_up(), GLOBE_TILES, "and holding exactly its twelve tiles")
