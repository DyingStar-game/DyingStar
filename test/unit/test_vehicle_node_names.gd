extends GutTest
## Godot's naming convention on the vehicles: every node a vehicle scene declares is PascalCase (no
## underscore, no lowercase start). Their names are the keys of the replicated state (VehicleNetKey
## turns SlotFL into slot_fl) and the paths the scripts reach them by, so a stray "Slot_FL" or
## "hanbreak" is a bug waiting, not a style point. Nodes that come from a Blender model (overrides of
## an instanced scene's children) are named in Blender and left out.

const ROOT := "res://scenes/_universe/vehicles"
const DASHBOARD := "res://scenes/_universe/vehicles/ground/trucks/truck_ui.tscn"

var _node := RegEx.create_from_string("^\\[node name=\"([^\"]+)\"(.*)$")
var _pascal := RegEx.create_from_string("^[A-Z][A-Za-z0-9]*$")


func test_every_vehicle_node_is_pascal_case() -> void:
	var bad : PackedStringArray = []
	for path: String in _scenes(ROOT):
		bad.append_array(misnamed(path, FileAccess.get_file_as_string(path)))
	assert_eq(bad.size(), 0, "nodes not in PascalCase:\n" + "\n".join(bad))


func test_the_rule_skips_what_blender_names() -> void:
	var src := "\n".join([
		"[node name=\"SlotFL\" type=\"Marker3D\" parent=\".\"]",
		"[node name=\"Slot_FR\" type=\"Marker3D\" parent=\".\"]",
		"[node name=\"hanbreak\" type=\"Label\" parent=\".\"]",
		"[node name=\"Model\" parent=\".\" instance=ExtResource(\"1\")]",
		"[node name=\"Col_bed\" parent=\"Model/Carrosserie\" index=\"2\"]",
	])
	assert_eq(misnamed("x.tscn", src), PackedStringArray(["x.tscn:2 Slot_FR", "x.tscn:3 hanbreak"]))


func test_the_dashboard_finds_its_labels() -> void:
	var panel : Node = (load(DASHBOARD) as PackedScene).instantiate()
	for label in ["Speed", "RPM", "Load", "Overloaded", "Powertrain", "Transmission", "Handbrake", "Light",
			"Limiter", "Odometer"]:
		assert_not_null(panel.get_node_or_null(label), "the dashboard script reads $%s" % label)
	panel.free()


## "path:line name" of every node [param source] declares (type= or instance=) that is not PascalCase.
func misnamed(path: String, source: String) -> PackedStringArray:
	var out : PackedStringArray = []
	var lines : PackedStringArray = source.split("\n")
	for i in lines.size():
		var m : RegExMatch = _node.search(lines[i])
		if m == null:
			continue
		var rest : String = m.get_string(2)
		if not (" type=" in rest or " instance=" in rest):
			continue  # an override of an instanced scene's child: named where it comes from
		if _pascal.search(m.get_string(1)) == null:
			out.append("%s:%d %s" % [path, i + 1, m.get_string(1)])
	return out


func _scenes(dir_path: String) -> PackedStringArray:
	var out : PackedStringArray = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for sub: String in dir.get_directories():
		out.append_array(_scenes(dir_path.path_join(sub)))
	for file: String in dir.get_files():
		if file.ends_with(".tscn"):
			out.append(dir_path.path_join(file))
	return out
