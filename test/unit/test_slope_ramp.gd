extends GutTest
## The vehicle test ramps of the mining village: each grade climbs at its angle, fits on the depot yard,
## and is a networked prop the village spawns (a plain node in the layout would never reach the game).

const RAMP := preload("res://scenes/_universe/structures/test_track/slope_ramp.gd")
const POI := preload("res://scenes/_universe/structures/urban/poi_villages.gd")
const VILLAGE := "res://scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
const GRADES := {"05": 5.0, "10": 10.0, "25": 25.0, "35": 35.0}


func test_each_slope_climbs_at_its_angle() -> void:
	for angle: float in [5.0, 10.0, 25.0, 35.0]:
		var points: PackedVector2Array = RAMP.outline(angle, 5.0, 90.0, 10.0, 0.3)
		var up: Vector2 = points[2] - points[1]
		var down: Vector2 = points[4] - points[3]
		assert_almost_eq(rad_to_deg(atan2(up.y, up.x)), angle, 1e-3, "%d° up" % angle)
		assert_almost_eq(rad_to_deg(atan2(-down.y, down.x)), angle, 1e-3, "%d° down" % angle)


func test_a_gentle_grade_is_lowered_to_fit_the_length() -> void:
	var gentle: Vector2 = RAMP.profile(5.0, 5.0, 90.0, 10.0)
	assert_lt(gentle.x, 5.0, "5° at 5 m would need 114 m")
	assert_almost_eq(gentle.y * 2.0 + 10.0, 90.0, 1e-3, "foot to foot = max length")
	assert_eq(RAMP.profile(25.0, 5.0, 90.0, 10.0).x, 5.0, "a steep grade reaches the full height")


func test_the_sign_gives_degrees_and_percent() -> void:
	assert_eq(RAMP.grade_text(25.0), "25°\n47 %")


func test_a_ramp_scene_builds_a_solid_road() -> void:
	var ramp: Node3D = load("res://scenes/_universe/structures/test_track/slope_ramp_25.tscn").instantiate()
	add_child_autofree(ramp)
	assert_eq(ramp.get("angle_deg"), 25.0)
	var road := ramp.get_node_or_null("Road") as CSGPolygon3D
	assert_not_null(road, "road built")
	if road != null:
		assert_true(road.use_collision, "vehicles drive on it")


## Read from the file, as test_containers does: the layout's buildings raise engine errors on load.
func test_the_village_places_every_ramp_on_the_depot_yard() -> void:
	var text := FileAccess.get_file_as_string(VILLAGE).replace("\r\n", "\n")
	for key: String in GRADES:
		var scene := "res://scenes/_universe/structures/test_track/slope_ramp_%s.tscn" % key
		var ext := RegEx.create_from_string(
				"\\[ext_resource [^\\]]*path=\"%s\" id=\"([^\"]+)\"\\]" % scene).search(text)
		assert_not_null(ext, "%s referenced" % scene.get_file())
		if ext == null:
			continue
		var node := RegEx.create_from_string(
				"\\[node name=\"[^\"]+\" parent=\"([^\"]+)\"[^\\]]*instance=ExtResource\\(\"%s\"\\)\\]"
				% ext.get_string(1)).search(text)
		assert_not_null(node, "SlopeRamp%s placed" % key)
		if node != null:
			assert_eq(node.get_string(1), "Storage_DepotYard2", "SlopeRamp%s spawned with the yard" % key)


func test_every_ramp_scene_is_a_networked_prop_with_its_grade() -> void:
	for key: String in GRADES:
		var ramp: Node = load("res://scenes/_universe/structures/test_track/slope_ramp_%s.tscn" % key).instantiate()
		assert_true(POI.is_spawnable(ramp), "SlopeRamp%s is a networked prop" % key)
		assert_eq(ramp.get("angle_deg"), GRADES[key], "SlopeRamp%s grade reaches clients via its scene" % key)
		# Both feet and the signs beside them inside the yard's levelled ground (98.6 m long).
		var shape: Vector2 = RAMP.profile(GRADES[key], 5.0, 90.0, 10.0)
		assert_lt(shape.y + 5.0 + 1.5, 98.604 * 0.5, "SlopeRamp%s fits the yard" % key)
		ramp.free()
