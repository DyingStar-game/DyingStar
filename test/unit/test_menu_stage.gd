extends GutTest
## The menu stage: placing on a sphere by distance and bearing, borrowing and returning the global
## state, and the set as authored in menu_stage_world.tscn.

const R : float = 6_361_000.0


func _frame(anchor: Vector3 = Vector3(1.0, 0.3, -0.4)) -> SurfaceFrame:
	return SurfaceFrame.new(anchor.normalized() * R, R, func(_dir: Vector3) -> float: return R)


func test_a_distance_is_measured_along_the_ground() -> void:
	var frame := _frame()
	for d in [12.0, 200.0, 8000.0, 20000.0]:
		var arc : float = frame.anchor_dir.angle_to(frame.dir_at(d, 37.0)) * R
		assert_almost_eq(arc, d, d * 1e-6 + 1e-3, "%.0f m of ground" % d)


func test_points_sit_on_the_ground_plus_their_lift() -> void:
	var frame := _frame()
	assert_almost_eq(frame.point(500.0, 90.0).length(), R, 0.01, "on the ground")
	assert_almost_eq(frame.point(500.0, 90.0, 2.6).length(), R + 2.6, 0.01, "a stacked container")


func test_bearing_to_reads_back_the_bearing_placed_at() -> void:
	var frame := _frame()
	for bearing in [0.0, 45.0, 170.0, 300.0]:
		assert_almost_eq(frame.bearing_to(frame.point(7600.0, bearing)), bearing, 0.01, "bearing %d" % bearing)


func test_a_basis_stands_up_and_faces_its_bearing() -> void:
	var frame := _frame()
	var dir : Vector3 = frame.dir_at(100.0, 10.0)
	var basis : Basis = frame.basis_at(dir, 90.0)
	assert_almost_eq(basis.y.dot(dir), 1.0, 1e-6, "up is away from the centre")
	assert_almost_eq(basis.z.dot(dir), 0.0, 1e-6, "facing along the ground")


func test_the_session_gives_back_what_it_borrowed() -> void:
	var saved : Array = [NetworkOrchestrator.universe_scene, Globals.time_scale, Globals.debug_time_offset]
	var session := StageSession.new()
	var root := Node.new()
	autofree(root)
	session.begin(root)
	assert_eq(NetworkOrchestrator.universe_scene, root, "the sky finds its star under the stage")
	assert_eq(Globals.time_scale, 0.0, "the clock is frozen")
	Globals.debug_time_offset = 12345.0  # what StageClock does
	session.end()
	assert_eq([NetworkOrchestrator.universe_scene, Globals.time_scale, Globals.debug_time_offset], saved,
		"no frozen sun nor shifted clock leaks into the game")


var _world_scene : PackedScene


## Loaded once, outside the tests: opening Tarsis 3's resources prints engine warnings (stale UIDs, a
## material) that GUT would count as errors of whichever test happened to load them first.
func before_all() -> void:
	_world_scene = load(MenuStage.WORLD_SCENE)
	autofree(_world_scene.instantiate())


## The set, as authored in menu_stage_world.tscn (instantiated, not added: nothing runs).
func _world() -> Node3D:
	var world : Node3D = _world_scene.instantiate()
	autofree(world)
	return world


func test_the_set_covers_every_distance_band() -> void:
	var world := _world()
	var outpost : StageOutpost = world.get_node("Tarsis3/Outpost")
	var anchor : Vector3 = outpost.anchor_local()
	assert_ne(anchor, Vector3.ZERO, "the anchor (Teleporter) is found")
	var bands : Array = [false, false, false, false, false, false]  # <50, 200, 1k, 3k, 8k, >=15k
	for piece in outpost.get_children():
		if not piece is Node3D or piece.name == &"Stations":
			continue
		var d : float = anchor.normalized().angle_to((piece as Node3D).position.normalized()) * anchor.length()
		var i : int = 0 if d < 50.0 else 1 if d < 500.0 else 2 if d < 2000.0 else 3 if d < 5000.0 else 4 if d < 12000.0 else 5
		bands[i] = true
	assert_eq(bands, [true, true, true, true, true, true], "LOD and distances can be judged at every range")


func test_the_set_has_figures_and_moving_trucks() -> void:
	var outpost : StageOutpost = _world().get_node("Tarsis3/Outpost")
	assert_gt(outpost.find_children("*", "Mannequin", false, false).size(), 3, "workers")
	assert_gt(outpost.find_children("*", "StageDriver", false, false).size(), 0, "a truck on the road")


func test_every_menu_screen_has_a_viewpoint() -> void:
	var outpost : StageOutpost = _world().get_node("Tarsis3/Outpost")
	for key in [&"home", &"settings", &"settings_graphics"]:
		assert_not_null(outpost.station(key), "%s" % key)
	var tuning : Array = outpost.stations().filter(func(s: StageStation) -> bool: return s.is_tuning())
	assert_gt(tuning.size(), 2, "several tuning viewpoints")
	for station in tuning:
		assert_true(station.label.begins_with("%%SHOWCASE_VIEW_"), "labelled for translation")


func test_the_hour_reads_as_a_clock() -> void:
	assert_eq(StageTuning.clock(17.25), "17:15", "a quarter past five")
	assert_eq(StageTuning.clock(0.0), "00:00", "midnight")
	assert_eq(StageTuning.clock(23.99), "23:59", "almost midnight")
