extends GutTest
## Guard: no SubViewport redrawn every frame unless someone wrote down why.
##
## A SubViewport in UPDATE_ALWAYS renders every frame whether it is seen or not, and its GPU time is
## NOT in the root viewport's (the benchmark lists them apart). Every truck carried a 1921x1112 screen
## redrawn that way wherever it stood, and the star map rendered its own world and sky from the start
## of the game, closed or not. The engine's default, UPDATE_WHEN_VISIBLE, draws a screen only while it
## is on screen; a script that needs more decides it at run time and is listed below with its reason.

## Files allowed to ask for UPDATE_ALWAYS, and why. Paths from res://.
const ALLOWED : Dictionary = {
	# The settings page IS on screen whenever it exists: it is freed when the menu closes.
	"res://ui/settings_page/settings_page.tscn": "the page exists only while the menu is open",
	# Asked only within max_distance of the view, with the engine on, and refresh_hz <= 0.
	"res://scenes/_universe/vehicles/rear_camera.gd": "gated by distance, power and refresh rate",
	# Does not ask for it: names the mode of each SubViewport in the benchmark report.
	"res://scenes/benchmark/benchmark_facts.gd": "names the mode in the report, never sets it",
}
const SKIPPED_DIRS : Array[String] = ["res://addons", "res://.godot", "res://test", "res://build"]


func test_no_subviewport_is_redrawn_every_frame_without_a_reason() -> void:
	var offenders : PackedStringArray = []
	for path in _files("res://"):
		if path in ALLOWED:
			continue
		var text : String = FileAccess.get_file_as_string(path)
		if path.ends_with(".tscn") and text.contains("render_target_update_mode = 4"):
			offenders.append(path + " (scene: render_target_update_mode = 4)")
		elif path.ends_with(".gd") and text.contains("UPDATE_ALWAYS"):
			offenders.append(path + " (script: UPDATE_ALWAYS)")
	assert_eq(offenders, PackedStringArray(), "use UPDATE_WHEN_VISIBLE, or add the file to ALLOWED with a reason")


func test_every_allowed_file_still_exists() -> void:
	for path in ALLOWED:
		assert_true(FileAccess.file_exists(path), "%s is listed but gone: remove it from ALLOWED" % path)


func _files(dir_path: String) -> PackedStringArray:
	var out : PackedStringArray = []
	if dir_path.trim_suffix("/") in SKIPPED_DIRS:
		return out
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for sub in dir.get_directories():
		out.append_array(_files(dir_path.path_join(sub)))
	for file in dir.get_files():
		if file.ends_with(".tscn") or file.ends_with(".gd"):
			out.append(dir_path.path_join(file))
	return out
