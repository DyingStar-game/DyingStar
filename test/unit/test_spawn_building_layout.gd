extends GutTest
## SpawnBuilding: one habitat container per apartment, laid on a grid of rows x cols x floors. The
## copies of the container stand side by side, the spawn point Horizon offsets for each slot stays in
## its own container, the door plate fits any name, and the buildings of a mining village never
## overlap now that a container is longer and narrower than the old apartment, nor rise above three levels.

const BUILDING := "res://scenes/_universe/structures/buildings/spawn_building.tscn"
const APARTMENT := "res://scenes/_universe/structures/buildings/container_apartment.tscn"
const VILLAGE := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
## A village's buildings stand three levels high at most: the ground floor, the 1st and the 2nd.
const MAX_FLOORS := 3


func test_the_copies_tile_the_grid_back_to_back() -> void:
	var building: SpawnBuilding = _building(2, 3)
	building._create_apartments()
	var rooms: Node = building.get_node("MultiMeshInstance3D")
	assert_eq(rooms.get_child_count(), 6, "rows x cols apartments")
	var first_row := rooms.get_node("0-2-0") as Node3D
	assert_almost_eq(first_row.position.z, 2.0 * building.z_spacing, 1e-6, "side by side along +Z")
	var second_row := rooms.get_node("1-0-0") as Node3D
	assert_almost_eq(second_row.position.x, 2.0 * building.x_spacing, 1e-6)
	# Turned to face the other way, it fills x in [2 x_spacing, x_spacing]: back to back with row 0.
	var far_corner: Vector3 = second_row.transform * Vector3(building.x_spacing, 0.0, 0.0)
	assert_almost_eq(far_corner.x, building.x_spacing, 1e-3)
	building.free()


func test_the_spawn_point_stays_in_each_slot() -> void:
	# Horizon (new_player.rs slot_offset) mirrors the point in the second row, whose containers are
	# turned half round: it must land at the same spot of each container -- the spot beside the bed.
	var building: SpawnBuilding = _building(2, 4)
	building._create_apartments()
	var p: Vector3 = building.spawn_point
	var rooms: Node = building.get_node("MultiMeshInstance3D")
	for row in 2:
		for col in 4:
			var x: float = building.x_spacing - p.x if row != 0 else p.x
			var z: float = building.z_spacing - p.z if row != 0 else p.z
			var at := Vector3(x + row * building.x_spacing, p.y, z + col * building.z_spacing)
			var room := rooms.get_node(SpawnBuilding.slot_name({"row": row, "col": col, "floor": 0})) as Node3D
			assert_almost_eq(room.transform.affine_inverse() * at, p, Vector3.ONE * 1e-4,
					"slot %d-%d: the same spot of its container" % [row, col])
	building.free()
	KnownEngineErrors.forgive_floor_material(self)


func test_the_container_fits_the_cell() -> void:
	var building: SpawnBuilding = _building(1, 1)
	var apartment: Node3D = (load(APARTMENT) as PackedScene).instantiate()
	var model := apartment.get_node("habitat_container") as Node3D
	var frame := model.get_node("frame") as MeshInstance3D
	var box: AABB = model.transform * frame.transform * frame.mesh.get_aabb()
	assert_almost_eq(box.size.x, absf(building.x_spacing), 0.01, "a container's length")
	assert_almost_eq(box.size.z, building.z_spacing, 0.01, "a container's width")
	assert_almost_eq(box.size.y, building.y_spacing, 0.01, "a container's height")
	assert_almost_eq(box.position, Vector3(building.x_spacing, 0.0, 0.0), Vector3.ONE * 0.01,
			"from the facade (x = 0) towards -x, on the ground")
	apartment.free()
	building.free()


func test_a_long_name_shrinks_to_fit_the_plate() -> void:
	assert_eq(ApartmentPlates.name_pixel_size(100.0, 0.22, 0.0006), 0.0006, "a short name keeps its size")
	assert_almost_eq(ApartmentPlates.name_pixel_size(1000.0, 0.22, 0.0006) * 1000.0, 0.22, 1e-9)
	assert_eq(ApartmentPlates.name_pixel_size(0.0, 0.22, 0.0006), 0.0006, "no text")


func test_the_id_plate_shows_its_colour_from_afar_too() -> void:
	# Past ShellLod.DETAIL_END_M only the far stand-in's plate is drawn: in the same colour as the plate,
	# red on a home someone lives in, green on a free one -- not the model's plain black.
	var building: SpawnBuilding = _building(1, 2)
	building.apartments = [{"floor": 0, "row": 0, "col": 1, "player_uuid": "abc", "player_name": "Ann"}]
	building._create_apartments()
	var rooms: Node = building.get_node("MultiMeshInstance3D")
	ApartmentPlates.show(rooms, building.apartments, "uuid", "")
	for slot: String in ["0-0-0", "0-1-0"]:
		var taken: bool = slot == "0-1-0"
		var plate := rooms.get_node(slot).find_child("ID", true, false) as GeometryInstance3D
		var painted: int = 0
		for mesh: MeshInstance3D in rooms.get_node(slot).find_child("ShellLod", true, false).find_children(
				"*", "MeshInstance3D", true, false):
			for i in mesh.mesh.get_surface_count():
				if mesh.get_surface_override_material(i) == plate.material_override:
					painted += 1
		assert_eq(painted, 1, "%s: the far stand-in's plate in the plate's colour" % slot)
		assert_eq((plate.material_override as StandardMaterial3D).albedo_color,
				ApartmentPlates.ID_PLATE_TAKEN if taken else ApartmentPlates.ID_PLATE_FREE, slot)
	building.free()
	KnownEngineErrors.forgive_floor_material(self)


func test_the_occupant_is_found_by_slot() -> void:
	var building: SpawnBuilding = _building(1, 2)
	building.apartments = [{"floor": 0, "row": 0, "col": 1, "player_uuid": "abc", "player_name": "Ann"}]
	building._create_apartments()
	var rooms: Node = building.get_node("MultiMeshInstance3D")
	var bed: Node = rooms.get_node("0-1-0").find_child("Bed", true, false)
	assert_eq(building.apartment_of(bed), rooms.get_node("0-1-0"))
	assert_eq(building.occupant_of(building.apartment_of(bed)), "abc")
	assert_eq(building.occupant_of(rooms.get_node("0-0-0")), "", "a free apartment")
	assert_null(building.apartment_of(building.get_node("MapMarker")), "outside the apartments")
	building.free()


func test_the_buildings_of_a_village_never_overlap() -> void:
	var village: Node3D = (load(VILLAGE) as PackedScene).instantiate()
	var rects: Array = []
	for child in village.get_children():
		if child is SpawnBuilding:
			var box: Dictionary = SpawnBuilding.terrain_pad_box({"rows": child.rows, "cols": child.cols,
					"floors": child.floors, "x_spacing": child.x_spacing, "z_spacing": child.z_spacing})
			var size: Vector3 = box["size"] - Vector3.ONE * 2.0 * SpawnBuilding.PAD_MARGIN_M
			rects.append({"name": child.name, "xf": child.transform * (box["local"] as Transform3D),
					"half": Vector2(size.x, size.z) * 0.5})
	assert_eq(rects.size(), 13, "the mining village's homes")
	var homes: int = 0
	for child in village.get_children():
		if child is SpawnBuilding:
			homes += child.rows * child.cols * child.floors
			assert_lte(child.floors, MAX_FLOORS, "%s: the ground floor and two storeys at most" % child.name)
	assert_eq(homes, 252, "about 250 apartments a village")
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			assert_false(_overlap(rects[i], rects[j]), "%s overlaps %s" % [rects[i].name, rects[j].name])
	village.free()
	KnownEngineErrors.forgive_floor_material(self)


## A building of [param rows] x [param cols], one floor, not in the tree.
func _building(rows: int, cols: int) -> SpawnBuilding:
	var building := (load(BUILDING) as PackedScene).instantiate() as SpawnBuilding
	building.rows = rows
	building.cols = cols
	return building


## Do two rectangles laid on the ground overlap (separating axis test, in the XZ plane)?
func _overlap(a: Dictionary, b: Dictionary) -> bool:
	var axes: Array[Vector2] = []
	for r in [a, b]:
		var basis: Basis = (r.xf as Transform3D).basis
		axes.append(Vector2(basis.x.x, basis.x.z).normalized())
		axes.append(Vector2(basis.z.x, basis.z.z).normalized())
	for axis in axes:
		var pa := _project(a, axis)
		var pb := _project(b, axis)
		if pa.y <= pb.x or pb.y <= pa.x:
			return false
	return true


## The [min, max] of the rectangle [param r] along [param axis].
func _project(r: Dictionary, axis: Vector2) -> Vector2:
	var xf: Transform3D = r.xf
	var lo := INF
	var hi := -INF
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var p: Vector3 = xf * Vector3(sx * r.half.x, 0.0, sz * r.half.y)
			var d: float = Vector2(p.x, p.z).dot(axis)
			lo = minf(lo, d)
			hi = maxf(hi, d)
	return Vector2(lo, hi)
