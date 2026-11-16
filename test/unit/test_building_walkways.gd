extends GutTest
## BuildingWalkways: a spawn building of several storeys gets, on each façade, a walkway before each upper
## storey and a half-landing stair past its end -- each half flight landing exactly on the deck it serves.

const BUILDING := "res://scenes/_universe/structures/buildings/spawn_building.tscn"


func test_one_storey_has_none() -> void:
	var building := _building(2, 3, 1)
	building._create_apartments()
	assert_false(building.has_node(NodePath(BuildingWalkways.NODE_NAME)))
	building.free()
	KnownEngineErrors.forgive_floor_material(self)


func test_each_upper_storey_of_each_facade_gets_two_half_flights() -> void:
	var building := _building(2, 3, 3)
	building._create_apartments()
	var flights: Array = building.find_children("*", "StaticBody3D", true, false).filter(
			func(n: Node) -> bool: return n.scene_file_path.ends_with("stair_half_flight.tscn"))
	assert_eq(flights.size(), 2 * 2 * 2, "2 façades x 2 upper storeys x 2 half flights")
	building.free()
	KnownEngineErrors.forgive_floor_material(self)


## The rails of a flight hung in the air at their ends (no post under them).
func test_a_post_stands_under_both_ends_of_each_flight_rail() -> void:
	var feet: Array[Vector3] = BuildingWalkways.flight_post_feet()
	var half: float = BuildingWalkways.RAIL_BAR * 0.5
	for x: float in [half, BuildingWalkways.LANE_W - half]:
		var side: Array = feet.filter(func(p: Vector3) -> bool: return is_equal_approx(p.x, x))
		assert_gt(side.size(), 1, "posts on the side at x = %.2f" % x)
		assert_almost_eq((side[0] as Vector3).z, half, 1e-6, "one at the foot of the flight")
		assert_almost_eq((side[-1] as Vector3).z, BuildingWalkways.HALF_RUN - half, 1e-6, "one at its head")
		for i in range(1, side.size()):
			assert_lte((side[i] as Vector3).z - (side[i - 1] as Vector3).z, BuildingWalkways.POST_STEP + 1e-6,
					"no further apart than a railing's")
	for foot: Vector3 in feet:
		assert_almost_eq(foot.y, foot.z * BuildingWalkways.HALF_RISE / BuildingWalkways.HALF_RUN, 1e-6,
				"standing on the slope")


func test_each_built_flight_has_its_posts() -> void:
	var building := _building(1, 3, 2)
	building._create_apartments()
	var flights: Array = building.find_children("*", "StaticBody3D", true, false).filter(
			func(n: Node) -> bool: return n.scene_file_path.ends_with("stair_half_flight.tscn"))
	assert_eq(flights.size(), 2, "one storey up: two half flights")
	for flight: Node in flights:
		var posts: Array = flight.find_children(BuildingWalkways.FLIGHT_POST_PREFIX + "*", "MeshInstance3D", false, false)
		assert_eq(posts.size(), BuildingWalkways.flight_post_feet().size(), "every post of the flight")
	building.free()
	KnownEngineErrors.forgive_floor_material(self)


## The treads stuck out of the stringers: as wide as the lane, their ends flush with the outer faces.
func test_the_treads_fit_between_the_stringers() -> void:
	var flight: Node3D = BuildingWalkways.STAIR_SCENE.instantiate()
	var tread := flight.get_node("Tread1") as MeshInstance3D
	var stringer := flight.get_node("StringerL") as MeshInstance3D
	var inner: float = stringer.position.x + (stringer.mesh as BoxMesh).size.x * 0.5
	assert_almost_eq(tread.position.x - (tread.mesh as BoxMesh).size.x * 0.5, inner, 1e-4, "up to its inner face")
	var rail := flight.get_node("RailL") as MeshInstance3D
	var slope_y: float = rail.position.z * BuildingWalkways.HALF_RISE / BuildingWalkways.HALF_RUN
	assert_almost_eq(rail.position.y - slope_y, BuildingWalkways.RAIL_H, 1e-3, "the rail as high as a deck's")
	flight.free()


func test_the_half_flights_land_on_their_decks() -> void:
	var h: float = 2.6
	for f in [1, 2]:
		var start: float = BuildingWalkways.level_y(f - 1, h)
		var half: float = start + BuildingWalkways.HALF_RISE
		assert_almost_eq(half + BuildingWalkways.HALF_RISE, BuildingWalkways.level_y(f, h), 1e-6,
				"two half flights climb exactly one storey (storey %d)" % f)
	assert_almost_eq(BuildingWalkways.level_y(1, h), 2.6 + 0.12, 1e-6, "level with the containers' floor")


func test_the_second_row_s_facade_faces_the_other_way() -> void:
	var xf: Transform3D = BuildingWalkways.facade_transform(1, 4, -6.1, 2.6)
	assert_almost_eq(xf * Vector3.ZERO, Vector3(-12.2, 0.0, 10.4), Vector3.ONE * 1e-6, "its doors at 2 x_spacing")
	assert_almost_eq(xf.basis * Vector3.RIGHT, Vector3.LEFT, Vector3.ONE * 1e-6, "out of its doors: -x")


func test_columns_stand_at_both_ends_and_between() -> void:
	var at: Array[float] = BuildingWalkways.column_stations(10.0, 5.2)
	assert_eq(at.size(), 3, "both ends and one between: no span over 5.2 m")
	assert_almost_eq(at[0], BuildingWalkways.COLUMN_W * 0.5, 1e-6, "flush with the start")
	assert_almost_eq(at[-1], 10.0 - BuildingWalkways.COLUMN_W * 0.5, 1e-6, "flush with the end")
	assert_eq(BuildingWalkways.column_stations(2.0, 5.2).size(), 2, "a short one: its two ends")


func test_the_pad_takes_in_the_stairs() -> void:
	var flat: Dictionary = SpawnBuilding.terrain_pad_box({"rows": 1, "cols": 3, "floors": 1})
	var tall: Dictionary = SpawnBuilding.terrain_pad_box({"rows": 1, "cols": 3, "floors": 2})
	assert_almost_eq((tall["size"] as Vector3).x - (flat["size"] as Vector3).x, BuildingWalkways.STAIR_OUT, 1e-6)
	assert_almost_eq((tall["size"] as Vector3).z - (flat["size"] as Vector3).z, BuildingWalkways.STAIR_ZONE, 1e-6)



func _building(rows: int, cols: int, floors: int) -> SpawnBuilding:
	var building := (load(BUILDING) as PackedScene).instantiate() as SpawnBuilding
	building.rows = rows
	building.cols = cols
	building.floors = floors
	return building
