extends GutTest
## project.godot keeps the reflection atlas at a few probes (rendering/reflections/reflection_atlas/
## reflection_count): Godot's 64 by default took 500 MiB of video memory from the first probe drawn
## (2026-11-27). Godot 4.7 crashes when more probes than that are on screen, so every ReflectionProbe of
## the game must be an InteriorProbe, drawn only while the camera is inside its building. This finds the
## probes of every scene and script (tests and third-party addons aside) and fails on one that is not.

const INTERIOR_PROBE := "res://scenes/_universe/structures/buildings/interior_probe.gd"
## Most probes the camera can be inside at once (overlapping buildings and their margins), well under it.
const MAX_ATLAS := 16
const SKIPPED_DIRS: Array[String] = ["res://addons", "res://test", "res://.godot"]

var _node := RegEx.create_from_string("\\[node name=\"([^\"]+)\" type=\"ReflectionProbe\"[^\\]]*\\]")
var _script_line := RegEx.create_from_string("^script = ExtResource\\(\"([^\"]+)\"\\)")


func test_the_atlas_is_kept_small() -> void:
	var count: int = ProjectSettings.get_setting("rendering/reflections/reflection_atlas/reflection_count", 64)
	assert_lte(count, MAX_ATLAS, "reflection_count: 7.8 MiB of video memory per probe, used or not")
	assert_gte(count, 4, "room for the building around the camera and the ones within its margin")


func test_every_probe_of_a_scene_is_an_interior_probe() -> void:
	var found: int = 0
	for path: String in _files(".tscn"):
		var text := FileAccess.get_file_as_string(path)
		for m: RegExMatch in _node.search_all(text):
			found += 1
			assert_eq(_script_of(text, m.get_end()), INTERIOR_PROBE,
					"%s: ReflectionProbe '%s' must be an InteriorProbe" % [path, m.get_string(1)])
	assert_gt(found, 0, "the scan found the game's probes")


func test_no_script_makes_a_plain_probe() -> void:
	for path: String in _files(".gd"):
		if path == INTERIOR_PROBE:
			continue
		assert_false(FileAccess.get_file_as_string(path).contains("ReflectionProbe.new("),
				"%s makes a ReflectionProbe: use InteriorProbe" % path)


## The script on the node whose header ends at [param from]: its property lines run to the next blank line.
func _script_of(text: String, from: int) -> String:
	var end := text.find("\n\n", from)
	for line: String in text.substr(from, (end if end != -1 else text.length()) - from).split("\n"):
		var m := _script_line.search(line)
		if m != null:
			var id := m.get_string(1)
			var res := RegEx.create_from_string("\\[ext_resource[^\\]]*path=\"([^\"]+)\"[^\\]]*id=\"%s\"\\]" % id)
			var ext := res.search(text)
			return ext.get_string(1) if ext != null else ""
	return ""


func _files(suffix: String) -> Array[String]:
	var out: Array[String] = []
	var dirs: Array[String] = ["res://"]
	while not dirs.is_empty():
		var dir: String = dirs.pop_back()
		for sub: String in DirAccess.get_directories_at(dir):
			var full := dir.path_join(sub)
			if not sub.begins_with(".") and not full in SKIPPED_DIRS:
				dirs.append(full)
		for file: String in DirAccess.get_files_at(dir):
			if file.ends_with(suffix):
				out.append(dir.path_join(file))
	return out
