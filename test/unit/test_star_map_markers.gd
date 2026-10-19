extends GutTest
## StarMapMarkers: what carries a MapMarker is drawn as its footprint laid flat at its base -- true size
## close in, no smaller than a floor further out -- turned with the object. And the scenes that carry one.

const BUILDING := AABB(Vector3(-6.0, 0.0, -4.0), Vector3(12.0, 8.0, 8.0))
const SCENES: Array[String] = [
	"res://scenes/_universe/structures/industrial/mines/mining_depot.tscn",
	"res://scenes/_universe/structures/buildings/teleporter/teleporter.tscn",
	"res://scenes/_universe/vehicles/ground/trucks/truck.tscn",
	"res://scenes/_universe/structures/dispenser/food_dispenser.tscn",
	"res://scenes/_universe/structures/dispenser/tool_dispenser.tscn",
	"res://scenes/_universe/structures/dispenser/component_dispenser.tscn",
	"res://scenes/_universe/structures/buildings/apartment_ares_worker_001.tscn",
	"res://scenes/_universe/structures/industrial/garage.tscn",
	"res://scenes/_universe/structures/industrial/cargo_depot.tscn",
]


func test_close_in_the_rectangle_is_the_footprint() -> void:
	var xf: Transform3D = StarMapMarkers.rect_transform(Transform3D.IDENTITY, BUILDING, 0.01, 0.0)
	assert_almost_eq(xf.basis.get_scale(), Vector3(12.0, 1.0, 8.0), Vector3(1e-6, 1e-6, 1e-6))
	assert_almost_eq(xf.origin, Vector3(0.0, 0.0, 0.0), Vector3(1e-6, 1e-6, 1e-6), "at its base, not its middle")


func test_far_out_the_floor_keeps_it_visible() -> void:
	var xf: Transform3D = StarMapMarkers.rect_transform(Transform3D.IDENTITY, BUILDING, 50.0, 0.0)
	assert_almost_eq(xf.basis.get_scale(), Vector3(50.0, 1.0, 50.0), Vector3(1e-6, 1e-6, 1e-6))


func test_it_lies_on_the_object_s_ground_turned_with_it() -> void:
	var place := Transform3D(Basis(Vector3.UP, PI / 4.0), Vector3(10.0, 2.0, -3.0))
	var xf: Transform3D = StarMapMarkers.rect_transform(place, BUILDING, 0.01, 0.05)
	assert_almost_eq(xf.origin, place.origin + Vector3.UP * 0.05, Vector3(1e-6, 1e-6, 1e-6), "lifted off its base")
	assert_almost_eq(xf.basis.x.normalized().dot(place.basis.x), 1.0, 1e-6)


func test_a_set_footprint_wins_over_the_meshes() -> void:
	var marker := MapMarker.new()
	marker.footprint_size = Vector3(4.0, 3.0, 2.0)
	assert_eq(marker.footprint().size, Vector3(4.0, 3.0, 2.0))
	assert_almost_eq(marker.footprint().get_center().x, 0.0, 1e-6)
	marker.free()


func test_the_scenes_carry_a_marker() -> void:
	# Read off the scene files: loading them pulls in their whole art (and its own import warnings).
	for path in SCENES:
		var text: String = FileAccess.get_file_as_string(path)
		# Its own node, or an inherited one overridden (a food dispenser is a component dispenser).
		assert_true(text.contains('[node name="MapMarker" '), path)
		assert_true(text.contains('icon = ExtResource("mm_icon")'), path + ": its pictogram")
		# Its name on hover is player-facing text: a %% key (en + fr), never the scene's file name.
		assert_true(text.contains('label = "%%'), path + ": its name is a localisation key")


func test_a_blockout_of_csg_shapes_has_a_footprint() -> void:
	# The dispensers are made of CSG boxes, no mesh at all: measured on meshes only, they had no
	# footprint and the chart never drew them (playtest 2026-10-19).
	var dispenser: Node = (load("res://scenes/_universe/structures/dispenser/component_dispenser.tscn") as PackedScene).instantiate()
	add_child_autofree(dispenser)
	var marker := dispenser.get_node("MapMarker") as MapMarker
	var box: AABB = marker.footprint()
	assert_gt(box.size.x, 0.1)
	assert_gt(box.size.z, 0.1)
