extends GutTest
## No scene or resource embeds an `Image` sub-resource. The export converts every .tres / .tscn to the
## binary format, and an embedded Image does not survive that round trip: the Texture2DArray holding
## them loads EMPTY in the exported game and the server logs `Condition "img.is_null()" is true` twice
## per boot (terrain_biome.tres, 2026-11-24 — the editor and the unit tests, which read the text file,
## never see it). A texture goes in its own imported file (a PNG, or a PNG imported as a 2D array).
##
## Read as text: a resource that fails to load is still checked. Third-party addons are left alone.

## Folders not checked, under res://.
const SKIPPED: Array[String] = [
	"res://.godot", "res://build", "res://addons/gut", "res://addons/open-world-database",
	"res://addons/uuid", "res://addons/godot-livekit", "res://addons/mqtt",
]
const EMBEDDED_IMAGE := "[sub_resource type=\"Image\""


func test_no_text_resource_embeds_an_image() -> void:
	var offenders: PackedStringArray = []
	for path: String in _text_resources("res://"):
		if FileAccess.get_file_as_string(path).contains(EMBEDDED_IMAGE):
			offenders.append(path)
	assert_eq(offenders.size(), 0,
		"embedded Image sub-resources load empty once exported (binary conversion):\n" + "\n".join(offenders))


func _text_resources(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if dir_path.trim_suffix("/") in SKIPPED:
		return out
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for sub: String in dir.get_directories():
		out.append_array(_text_resources(dir_path.path_join(sub)))
	for file: String in dir.get_files():
		if file.ends_with(".tres") or file.ends_with(".tscn"):
			out.append(dir_path.path_join(file))
	return out
