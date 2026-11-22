extends GutTest
## A vehicle lift loads in an exported game: nothing vehicle_lift.gd preloads may pull in, through its
## dependencies, a script that names VehicleLift. The lift's model (vehicle_lift_model_a.tres) holds the landing
## and platform scenes, whose scripts do: preloaded, it closed a loop, and the export failed to load
## lift_landing.gd ("Can't load dependency") while the editor, loading in another order, never showed it.

const LIFT_SCRIPT := "res://scenes/_universe/structures/industrial/vehicle_lift/vehicle_lift.gd"


func test_no_preload_comes_back_to_the_lift() -> void:
	var source: String = FileAccess.get_file_as_string(LIFT_SCRIPT)
	var preloads := RegEx.create_from_string("preload\\(\\s*(?:LIFT_DIR\\s*\\+\\s*)?\"([^\"]+)\"")
	var lift_dir: String = LIFT_SCRIPT.get_base_dir() + "/"
	var found: int = 0
	for m in preloads.search_all(source):
		var path: String = m.get_string(1)
		if not path.begins_with("res://"):
			path = lift_dir + path
		found += 1
		var back: String = _naming_the_lift(path, {})
		assert_eq(back, "", "%s pulls in %s, which names VehicleLift: load it when needed" % [path, back])
	assert_gt(found, 0, "the scan found vehicle_lift.gd's preloads")


func test_the_default_model_still_comes() -> void:
	var lift := VehicleLift.new()
	var model: VehicleLiftModel = lift.lift_model()
	assert_not_null(model, "a lift with no model gets the first lift's")
	assert_eq(model.resource_path, VehicleLift.DEFAULT_MODEL_PATH)
	lift.free()


## The first script naming VehicleLift that [param path] pulls in (itself or its dependencies), "" if none.
func _naming_the_lift(path: String, seen: Dictionary) -> String:
	if seen.has(path):
		return ""
	seen[path] = true
	if path.get_extension() == "gd" and path != LIFT_SCRIPT:
		var words := RegEx.create_from_string("\\bVehicleLift\\b")
		if words.search(FileAccess.get_file_as_string(path)) != null:
			return path
	for dep: String in ResourceLoader.get_dependencies(path):
		var dep_path: String = dep.get_slice("::", 2) if dep.contains("::") else dep
		if dep_path.begins_with("uid://"):
			dep_path = ResourceUID.get_id_path(ResourceUID.text_to_id(dep_path))
		var hit: String = _naming_the_lift(dep_path, seen)
		if hit != "":
			return hit
	return ""
