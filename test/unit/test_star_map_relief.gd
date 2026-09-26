extends GutTest

## The star chart's ground: one tile at a time.
##
## This suite was written against a builder that produced a WHOLE patch — up to four hundred tiles
## welded into one mesh. That design is gone, and the reason belongs here rather than in a commit
## message: rebuilding everything to change anything meant every camera movement cost the whole view,
## and the guard the mesh produced moved the camera, which asked for another rebuild. The chart never
## settled. [StarMapGround] now owns a set of tiles and changes only the difference.
##
## Most of what follows depends on a tile cache, which is a fact about the MACHINE and not about the
## repository: a checkout that has never run the game has none, and that is a legitimate state — the
## chart simply draws smooth spheres. Those tests report as pending rather than failing.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_star_map_relief.gd

## The body most likely to have been walked on, hence to have tiles cached.
const BODY: String = "tarsis_3"
## A terrestrial radius, for the pure geometry tests that need one.
const RADIUS: float = 6356000.0
## Subdivisions per tile edge, as [StarMapGround] asks for them.
const RES: int = 24


# ---------------------------------------------------------------------------
# Always
# ---------------------------------------------------------------------------

## A body nobody has ever approached has no tiles, and that is an ordinary answer: the chart keeps its
## sphere. It must never be an error, a warning, or a wait.
func test_a_body_without_cached_tiles_is_silent() -> void:
	assert_false(StarMapRelief.has_data("no_such_body"))
	assert_null(StarMapRelief.build_tile("no_such_body", 1, 0, RES))
	assert_false(StarMapRelief.has_data(""))
	assert_null(StarMapRelief.build_tile("", 1, 0, RES))


## And a nonsensical request is refused rather than crashed on.
func test_a_nonsensical_request_is_refused() -> void:
	assert_null(StarMapRelief.build_tile(BODY, 1, 0, 0), "a grid of nothing builds nothing")


## Heights are drawn as they are, and what makes that readable is how fine the ground is sampled.
##
## This asserted a FLOOR as well: that the exaggeration had to lift the summits to a percent of the
## radius or they would be invisible. True of a chart that could only draw the whole globe at 25 km per
## sample — Tarsis III's summits stand 9 000 m over a radius of 6 356 km, 0.14 %, a fraction of a pixel.
## It now draws 198 m per sample, where a hillside of a few hundred metres stands on its own merits, and
## overstating heights on top of that would be inventing terrain nobody is standing on.
##
## The ceiling stays, because what it guards has not changed: the camera guard is derived from this same
## surface, so every extra multiple pushes the closest approach further off the ground.
func test_heights_are_drawn_as_they_are() -> void:
	var peak_share: float = 9000.0 / RADIUS
	assert_lt(peak_share * 100.0, 0.2, "sanity: the true summits really are a fifth of a percent")
	assert_lt(peak_share * StarMapRelief.EXAGGERATION, 0.02,
			"never so tall that they push the closest approach out of reach of the ground")
	# One sample of ground at the finest level a body publishes, against the relief it has to describe.
	# Far apart, and true heights read as nothing; close, and they read as themselves.
	var finest_sample: float = PI * RADIUS / (sqrt(3.0 * PI) * 1024.0 * 32.0)
	assert_lt(finest_sample * 20.0, 9000.0,
			"the finest sample has to be small beside the relief, or true heights cannot show")


# ---------------------------------------------------------------------------
# One tile
# ---------------------------------------------------------------------------

## The shape of what is built: a grid, then a skirt hanging from its edge. Pins the arithmetic of
## both, which is the part that silently produces a torn surface.
func test_a_tile_has_the_expected_grid_and_skirt() -> void:
	var mesh: ArrayMesh = _tile(1, 0)
	if mesh == null:
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var stride: int = RES + 1
	assert_eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
			stride * stride + _rim_size(), "one vertex per grid node, plus one per rim node")
	# Two triangles per cell for the surface; the skirt gives each rim segment a quad, and emits it
	# with BOTH windings on purpose — see _add_skirt.
	assert_eq((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size(),
			RES * RES * 6 + _rim_size() * 12, "two triangles per cell, four per rim segment")


## The skirt must hang BELOW the surface it is attached to, and not by a silly amount.
##
## It exists to fill the crack between two tiles, which is as deep as the height step across their
## shared edge. Too shallow and the crack shows through it; too deep and it becomes a wall standing off
## the limb of the planet — which is what happens if it is dimensioned on the tile's whole relief
## instead of on its largest single step.
func test_the_skirt_hangs_below_the_surface() -> void:
	var mesh: ArrayMesh = _tile(1, 0)
	if mesh == null:
		return
	var points: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var stride: int = RES + 1
	# Each skirt vertex against the RIM vertex it hangs from, in the order _rim_ring walks. Against the
	# tile's lowest point instead — which is what this asked at first — the claim is only true while the
	# skirt is deeper than the tile's whole relief, and a skirt that deep is the defect, not the
	# contract: measured around Mining village 01, walls of 127 to 1016 m under 100 to 900 m of ground,
	# showing as dark diagonals along every tile edge.
	var rim: PackedInt32Array = StarMapRelief._rim_ring(stride)
	var first: int = stride * stride
	assert_eq(points.size() - first, rim.size(), "one skirt vertex per rim vertex, in step")
	var deepest: float = 0.0
	for i: int in range(rim.size()):
		var drop: float = points[rim[i]].length() - points[first + i].length()
		assert_gt(drop, 0.0, "skirt vertex %d hangs below the rim it is attached to" % i)
		deepest = maxf(deepest, drop)
	assert_lt(deepest, StarMapRelief.MESH_RADIUS * 0.05, "but never a wall standing off the limb")


## Every triangle must be a FRONT face by Godot's rule, which is that front faces are wound clockwise
## seen from the front — the opposite of the right-hand rule.
##
## Written the textbook way at first: the cross products all pointed outward, this passed, and the
## globe rendered inside out. A test that asserts the wrong convention is worse than no test, because
## it certifies the bug. It also catches the other half: HEALPix's twelve base faces do not all carry
## the same handedness, so the winding has to be measured per tile.
func test_every_tile_is_wound_the_right_way() -> void:
	var checked: int = 0
	for ipix: int in range(12):
		var mesh: ArrayMesh = _tile(1, ipix)
		if mesh == null:
			continue
		checked += 1
		var arrays: Array = mesh.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var inward: int = 0
		var step: int = 0
		# The SURFACE triangles only. The skirt that follows them is deliberately double-wound, so it
		# would fail this and should: which way a crack-filler faces is not worth computing.
		var surface_end: int = RES * RES * 6
		while step < surface_end:
			var a: Vector3 = points[indices[step]]
			var b: Vector3 = points[indices[step + 1]]
			var c: Vector3 = points[indices[step + 2]]
			# Clockwise from outside means the right-hand cross product points INWARD. That is the
			# front face here, however strange it reads.
			if (b - a).cross(c - a).dot(a + b + c) >= 0.0:
				inward += 1
			step += 60
		assert_eq(inward, 0, "tile %d: no triangle may be culled when seen from outside" % ipix)
	if checked == 0:
		pending("aucune tuile en cache pour %s sur cette machine" % BODY)


## Normals must point OUT, and this is not implied by the winding — it is contradicted by it. They are
## accumulated from face cross products, and the faces are wound Godot's way, so the raw sum points
## inward. Left that way the globe is lit from the far side: every slope bright where it should be
## dark, which looks like an art problem rather than a sign flip.
func test_normals_point_outward() -> void:
	var mesh: ArrayMesh = _tile(1, 4)
	if mesh == null:
		return
	var arrays: Array = mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	assert_eq(normals.size(), points.size(), "one normal per vertex")
	var wrong: int = 0
	for i: int in range(0, points.size(), 7):
		if normals[i].dot(points[i].normalized()) <= 0.0:
			wrong += 1
	assert_eq(wrong, 0, "no vertex may face into the planet")


## The whole point: the surface must actually vary. A tile built from a missing or misread payload
## comes out perfectly smooth, which looks exactly like success.
func test_a_tile_actually_has_relief() -> void:
	var mesh: ArrayMesh = _tile(1, 4)
	if mesh == null:
		return
	var points: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var lowest: float = INF
	var highest: float = 0.0
	var stride: int = RES + 1
	for i: int in range(stride * stride):  # the surface, not the skirt hanging under it
		lowest = minf(lowest, points[i].length())
		highest = maxf(highest, points[i].length())
	assert_gt(highest - lowest, 0.0005,
			"a whole base tile of a terrestrial planet cannot be flat to within a metre")


## A tile has to be cheap, because the chart builds them a handful at a time while the camera moves.
## The budget is generous — it runs on a worker — but a tile that took a second would mean the ground
## could never keep up with a turn.
func test_building_one_tile_is_quick() -> void:
	if not StarMapRelief.has_data(BODY):
		pending("aucune tuile en cache pour %s sur cette machine" % BODY)
		return
	var started: int = Time.get_ticks_msec()
	StarMapRelief.build_tile(BODY, 1, 0, RES)
	assert_lt(Time.get_ticks_msec() - started, 250,
			"one tile must cost far less than the quarter second between two decisions")


# ---------------------------------------------------------------------------
# The level the ground is read at
# ---------------------------------------------------------------------------

## Reading one level at every zoom was the original defect: the chart asked for nside 1 — 203 km of
## ground per sample — whether the planet filled a dozen pixels or the whole screen. Descending has to
## buy detail.
##
## Asserted over the RANGE rather than at each of six heights picked by hand. Two neighbouring heights
## sharing a level is ordinary and correct — that is what a level is — and demanding a step at each of
## them pins the boundaries rather than the behaviour, so it fails the day the chart gets better at
## choosing. It did: the budget is now spent against the tiles actually collected instead of an
## estimate of the cap's area, and the far end moved from n4 to n8, finer, for the same budget.
func test_the_level_gets_finer_as_the_camera_descends() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	var last: int = 0
	var first: int = 0
	for altitude: float in [2.0e7, 3.6e6, 3.18e5, 2.0e4, 2.0e3, 5.0e2]:
		var nside: int = StarMapRelief.level_for(manifest, Vector3.UP, altitude, RADIUS)
		assert_gte(nside, last, "coming closer may never buy LESS detail")
		assert_lte(nside, 1024, "and never ask for a level the body does not publish")
		if first == 0:
			first = nside
		last = nside
	assert_gt(last / first, 8, "across the whole descent, detail has to multiply")


## And what it settles on is the FINEST level that fits: one step further would overrun the budget.
##
## The claim behind the question "could we not have one more level?". Before the walk counted for
## itself, the answer came from an estimate of the cap's area, and near the ground that estimate runs
## half again too high: measured at 4 km over Tarsis III it predicted 131 tiles where 85 were collected,
## so a level that fitted with room to spare was refused and the ground was drawn twice as coarse as it
## could have been.
func test_the_level_chosen_is_the_finest_that_fits() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	var tested: int = 0
	for altitude: float in [3.6e6, 3.18e5, 2.0e4, 4.0e3, 5.0e2]:
		var plan: Dictionary = StarMapRelief.patch_for(manifest, Vector3.UP, altitude, RADIUS)
		var level: int = int(plan["level"])
		assert_lte((plan["tiles"] as PackedInt32Array).size(), StarMapRelief.PATCH_TILES_MAX,
				"at %.0f km, what is chosen fits" % (altitude / 1000.0))
		if level >= 1024:
			continue  # already at what the body publishes; there is no finer to refuse
		tested += 1
		assert_eq(StarMapRelief.patch_tiles(level * 2, Vector3.UP, altitude, RADIUS).size(), 0,
				"at %.0f km, n%d is refused, which is why n%d was taken"
				% [altitude / 1000.0, level * 2, level])
	assert_gt(tested, 2, "sanity: several heights really did have a finer level to refuse")


## The level chosen must be one the patch can actually be BUILT at, at every altitude.
##
## This asserted an ESTIMATE at first, and the estimate was optimistic twice over: it measured the bare
## horizon while the walk covers the horizon widened by a pixel (29° at nside 2), and it measured an
## area while the walk keeps every tile whose centre falls inside, boundary ring included. The planet
## came out drawn as a pac-man — the patch ran out of budget in the middle of the visible disc — and
## this test passed throughout. So it walks the patch now.
func test_every_chosen_level_can_actually_be_built() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	for altitude: float in [2.0e7, 3.6e6, 3.18e5, 2.0e4, 2.0e3, 5.0e2, 1.0]:
		var nside: int = StarMapRelief.level_for(manifest, Vector3.UP, altitude, RADIUS)
		var tiles: PackedInt32Array = StarMapRelief.patch_tiles(
				nside, Vector3.UP, altitude, RADIUS)
		assert_gt(tiles.size(), 0,
				"at %.0f m, level n%d must cover the view rather than stop inside it"
				% [altitude, nside])
		assert_lte(tiles.size(), StarMapRelief.PATCH_TILES_MAX,
				"and never exceed the budget at %.0f m" % altitude)


## No near view, no patch: the answer is the whole globe. A body seen from across the system has no
## "ground under the camera" to centre anything on.
func test_no_near_view_means_the_whole_globe() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	assert_eq(StarMapRelief.level_for(manifest, Vector3.ZERO, 500.0, RADIUS),
			StarMapRelief.TILE_NSIDE, "with no direction there is nothing to centre a patch on")
	assert_eq(StarMapRelief.level_for(manifest, Vector3.UP, -1.0, RADIUS),
			StarMapRelief.TILE_NSIDE, "and a body that is not being watched keeps its globe")


## A body that publishes only the coarsest level must never be asked for more, however close you get.
## Measured on this machine: tarsis_8 has nothing but n1 — published, never walked on.
func test_a_body_that_publishes_nothing_fine_is_never_asked_for_it() -> void:
	var manifest: Dictionary = {"nside_max": 1, "radius": 3000000.0}
	assert_eq(StarMapRelief.level_for(manifest, Vector3.UP, 100.0, 3000000.0), 1,
			"nside_max is a ceiling, and a metre off the ground does not lift it")


## The patch is grown from the pixel under the camera outward, and it must contain that pixel, stay
## inside the visible cap, and stop at the budget. Enumerating 12n² pixels instead would be impossible:
## at the finest level this pyramid goes to there are twelve million of them.
func test_the_patch_is_a_bounded_cap_around_the_camera() -> void:
	var altitude: float = 3.18e5
	var nside: int = StarMapRelief.level_for(
			{"nside_max": 1024, "radius": RADIUS}, Vector3.UP, altitude, RADIUS)
	assert_gt(nside, StarMapRelief.TILE_NSIDE, "sanity: this altitude deserves a patch")
	var tiles: PackedInt32Array = StarMapRelief.patch_tiles(nside, Vector3.UP, altitude, RADIUS)
	assert_gt(tiles.size(), 0, "there is ground under the camera, so there are tiles")
	assert_lte(tiles.size(), StarMapRelief.PATCH_TILES_MAX, "and never more than the budget")
	assert_true(tiles.has(HEALPix.vec2pix_nest(nside, Vector3.UP)),
			"the pixel directly under the camera must be in it")
	var horizon: float = acos(RADIUS / (RADIUS + altitude))
	var slack: float = HEALPix.pixel_angular_size(nside) * 2.0
	for ipix: int in tiles:
		assert_lt(HEALPix.pix2vec_nest(nside, ipix).angle_to(Vector3.UP), horizon + slack,
				"no tile may be pulled in from beyond the horizon")


# ---------------------------------------------------------------------------
# The ground measured is the ground drawn
# ---------------------------------------------------------------------------

## surface_factor decides how close the camera may come and how wide the scale bar's stick is; the mesh
## decides what you see. Answered at different levels they are different surfaces, and the camera then
## either stops short of nothing or sinks through a mountain. This is the most likely thing in the
## whole feature to drift, because nothing else would complain.
func test_the_ground_measured_is_the_ground_drawn() -> void:
	_assert_agrees(1, 4)


## And at a FINE level, which is where it broke once: surface_factor locates a direction with
## _vec_to_face_xy, which answers in pixel units across a FACE and takes a face index. At nside 1 a
## pixel IS a face and both are the number 0..11, so passing the pixel straight in was right by
## coincidence for as long as nside was always 1. At n8 it was wrong for two thirds of the surface.
func test_the_ground_agrees_at_a_fine_level_too() -> void:
	_assert_agrees(8, 100)


## A body with no tiles reports a plain sphere rather than guessing.
func test_a_body_without_relief_reports_a_plain_sphere() -> void:
	assert_eq(StarMapRelief.surface_factor("no_such_body", Vector3.UP), 1.0)


# ---------------------------------------------------------------------------
# The level and its tiles, decided together
# ---------------------------------------------------------------------------

## A plan is always something that can actually be drawn.
##
## level_for answers from an ESTIMATE of how many tiles the view holds, and the estimate can be
## optimistic — that is how a planet once shipped drawn as a pac-man, the patch having run out of budget
## in the middle of the visible disc. Whatever the height and whatever is already on screen, the plan has
## to come back with tiles, within the budget, and at the level it claims.
func test_a_plan_is_always_buildable() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	for altitude: float in [2.0e7, 3.6e6, 3.18e5, 2.0e4, 2.0e3, 5.0e2, 1.0, 0.0]:
		for current: int in [0, 1, 8, 64, 1024]:
			var plan: Dictionary = StarMapRelief.patch_for(
					manifest, Vector3.UP, altitude, RADIUS, current)
			var level: int = int(plan["level"])
			var tiles: PackedInt32Array = plan["tiles"]
			var where: String = "a %.0f m, avec n%d deja a l'ecran" % [altitude, current]
			assert_gt(tiles.size(), 0, "il faut des tuiles, %s" % where)
			assert_lte(tiles.size(), StarMapRelief.PATCH_TILES_MAX, "sans depasser le budget, %s"
					% where)
			assert_gte(level, StarMapRelief.TILE_NSIDE, "et un niveau reel, %s" % where)
			for ipix: int in tiles:
				assert_lt(ipix, StarMapRelief.npix(level),
						"chaque tuile appartient au niveau annonce, %s" % where)


## Climbing to a finer level has to clear a margin; it may never overshoot what the height allows, nor
## drop below what is already drawn.
##
## Scanned rather than asserted on a height picked by hand: where the boundary falls depends on the tile
## budget and on the cap estimate, so a hand-picked height would quietly stop testing anything the day
## either changes. The last assertion is the one that keeps FINER_MARGIN from being decoration — it has
## to actually decide something, somewhere.
func test_going_finer_has_to_clear_a_margin() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	var bit: int = 0
	var climbs: int = 0
	for i: int in range(160):
		var altitude: float = 2.0e7 * pow(0.9, float(i))
		var eager: int = StarMapRelief.level_for(manifest, Vector3.UP, altitude, RADIUS)
		for current: int in [1, 2, 8, 32, 128]:
			if eager <= current:
				continue
			climbs += 1
			var level: int = int(StarMapRelief.patch_for(
					manifest, Vector3.UP, altitude, RADIUS, current)["level"])
			assert_lte(level, eager,
					"a %.0f m, jamais plus fin que ce que la hauteur permet" % altitude)
			assert_gte(level, current,
					"a %.0f m, et jamais plus grossier que ce qui est deja dessine" % altitude)
			if level < eager:
				bit += 1
	assert_gt(climbs, 20, "sanity: des montees en niveau ont bien ete essayees")
	assert_gt(bit, 0, "la marge doit retenir au moins une montee, sinon elle ne sert a rien")


## And falling back is immediate: no margin, no hesitation.
##
## Asymmetric on purpose. Coarsening costs nothing — the tiles are already built, and the coarse ones
## replace them — while refusing to coarsen keeps a fine patch alive for a view that has left it behind.
func test_falling_back_is_immediate() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	for current: int in [8, 64, 1024]:
		var plan: Dictionary = StarMapRelief.patch_for(
				manifest, Vector3.UP, 2.0e7, RADIUS, current)
		assert_eq(int(plan["level"]), StarMapRelief.level_for(manifest, Vector3.UP, 2.0e7, RADIUS),
				"depuis n%d, la hauteur seule decide du retour en arriere" % current)


## A body that is not being watched keeps its globe, whatever was on screen a moment ago.
func test_no_near_view_falls_all_the_way_back() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	var plan: Dictionary = StarMapRelief.patch_for(manifest, Vector3.UP, -1.0, RADIUS, 256)
	assert_eq(int(plan["level"]), StarMapRelief.TILE_NSIDE)
	assert_eq((plan["tiles"] as PackedInt32Array).size(), 12, "the twelve tiles of the whole sphere")


# ---------------------------------------------------------------------------
# How much ground the screen is showing
# ---------------------------------------------------------------------------

## Far out, the cone of the view swallows the body, and the honest bound is the horizon.
func test_a_body_that_fits_on_screen_is_bounded_by_its_horizon() -> void:
	var half_fov: float = deg_to_rad(50.0)
	assert_lt(StarMapRelief.view_half_angle(RADIUS * 20.0, RADIUS, half_fov), 0.0,
			"the whole body is in frame: nothing to bound")
	assert_eq(StarMapRelief.cap_angle(RADIUS * 19.0, RADIUS, -1.0),
			StarMapRelief.horizon_angle(RADIUS * 19.0, RADIUS),
			"and with no measurement offered, the cap IS the horizon")


## Close in, the two part company, and the view is much the smaller.
##
## The numbers are the ones measured in game: 224 km over Tarsis III, where the horizon stands at 15°
## — 1 660 km of ground — while the screen was showing a few hundred km of it.
func test_close_in_the_screen_shows_far_less_than_the_horizon() -> void:
	var altitude: float = 224000.0
	var half_fov: float = deg_to_rad(57.8)
	var view: float = StarMapRelief.view_half_angle(RADIUS + altitude, RADIUS, half_fov)
	var horizon: float = StarMapRelief.horizon_angle(altitude, RADIUS)
	assert_gt(view, 0.0, "the cone's edge lands on the ground, so there is a figure to give")
	assert_lt(view, horizon * 0.5, "and it is a fraction of the horizon")
	assert_eq(StarMapRelief.cap_angle(altitude, RADIUS, view), view,
			"the cap takes the smaller of the two")
	assert_eq(StarMapRelief.cap_angle(altitude, RADIUS, horizon * 10.0), horizon,
			"and never goes beyond the horizon, whatever it is handed")


## Which is what buys the detail: the same tile budget, spent on the ground actually in front of you.
##
## Measured before this bound existed: a sample of ground 13 km wide while the scale bar read 20 km, so
## one sample of terrain was as coarse as the whole measuring stick.
func test_bounding_by_the_view_buys_a_finer_level() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	var half_fov: float = deg_to_rad(57.8)
	var finer: int = 0
	for altitude: float in [4.0e5, 2.24e5, 1.0e5, 3.0e4, 1.0e4]:
		var view: float = StarMapRelief.view_half_angle(RADIUS + altitude, RADIUS, half_fov)
		var blind: int = int(StarMapRelief.patch_for(
				manifest, Vector3.UP, altitude, RADIUS, 0, -1.0)["level"])
		var seeing: int = int(StarMapRelief.patch_for(
				manifest, Vector3.UP, altitude, RADIUS, 0, view)["level"])
		assert_gte(seeing, blind, "at %.0f km, never coarser for knowing more" % (altitude / 1000.0))
		if seeing > blind:
			finer += 1
	assert_gt(finer, 3, "and finer at most of those heights, which is the whole point")


## And no regression out where the body fits on screen: there, the two answer the same.
func test_far_out_the_bound_changes_nothing() -> void:
	var manifest: Dictionary = {"nside_max": 1024, "radius": RADIUS}
	var half_fov: float = deg_to_rad(57.8)
	for altitude: float in [3.0e6, 6.0e6, 2.0e7]:
		var view: float = StarMapRelief.view_half_angle(RADIUS + altitude, RADIUS, half_fov)
		assert_eq(int(StarMapRelief.patch_for(manifest, Vector3.UP, altitude, RADIUS, 0, view)["level"]),
				int(StarMapRelief.patch_for(
						manifest, Vector3.UP, altitude, RADIUS, 0, -1.0)["level"]),
				"at %.0f km the whole body is in frame, so nothing is bounded" % (altitude / 1000.0))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## One tile of the test body, or null with the suite marked pending when this machine has no cache.
func _tile(nside: int, ipix: int) -> ArrayMesh:
	if not StarMapRelief.has_data(BODY):
		pending("aucune tuile en cache pour %s sur cette machine" % BODY)
		return null
	var mesh: ArrayMesh = StarMapRelief.build_tile(BODY, nside, ipix, RES)
	assert_not_null(mesh, "tiles are cached, so n%d f%d must build" % [nside, ipix])
	return mesh


## How many vertices go round the edge of a tile: the perimeter of the grid, counted once.
func _rim_size() -> int:
	return 4 * RES


## Every vertex of a tile, compared with what surface_factor says about the same direction.
func _assert_agrees(nside: int, ipix: int) -> void:
	var mesh: ArrayMesh = _tile(nside, ipix)
	if mesh == null:
		return
	var points: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var checked: int = 0
	var strayed: int = 0
	var total: float = 0.0
	# Surface vertices only: a skirt vertex is deliberately BELOW the ground, so measuring it against
	# the ground would be measuring the skirt's depth.
	var stride: int = RES + 1
	for i: int in range(0, stride * stride, 3):
		var drawn: float = points[i].length() / StarMapRelief.MESH_RADIUS
		var measured: float = StarMapRelief.surface_factor(BODY, points[i].normalized(), nside)
		var apart: float = absf(drawn - measured)
		total += apart
		if apart > 0.001:
			strayed += 1
		checked += 1
	assert_gt(checked, 50, "sanity: enough vertices were actually compared")
	# Judged on the average and on how many stray, not on the single worst: a vertex on the seam
	# between two tiles belongs to both, each tile is sampled with its own edges extended, and the two
	# answers differ by whatever the terrain does across that seam. A LEVEL mismatch, by contrast,
	# moves most of the surface — which is what these two numbers see.
	assert_lt(total / float(checked), 0.0002,
			"n%d: on average the measured ground must sit on the drawn ground" % nside)
	assert_lt(float(strayed) / float(checked), 0.08,
			"n%d: and only the tile edges may stray from it" % nside)
