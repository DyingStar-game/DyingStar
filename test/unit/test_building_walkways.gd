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
