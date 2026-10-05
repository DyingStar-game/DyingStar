extends GutTest
## A networked prop travels under its PropSync's type_name, and Horizon only accepts a type it has a
## definition for: anything else is dropped ("Object definition not found for type"), so the prop
## exists on the server and nowhere else. Nothing on the game side errors. A PropSync left at its
## default ("generic_prop", which has no definition) is the usual way to get there.
## Read from the files rather than instantiated: no scene is loaded for a question about its text.

const SCENE_ROOTS: Array[String] = ["res://scenes", "res://levels"]
const DEFAULT_TYPE := "generic_prop"


func test_every_prop_sync_names_a_type_horizon_knows() -> void:
	var unknown: PackedStringArray = []
	var checked := 0
	for root: String in SCENE_ROOTS:
		for path: String in _scenes_under(root):
			var type := _prop_sync_type(FileAccess.get_file_as_string(path))
			if type == "":
				continue
			checked += 1
			var def := "%s/%s%s" % [ServerPropsIO.DEFS_DIR, type, ServerPropsIO.DEFS_SUFFIX]
			if not FileAccess.file_exists(def):
				unknown.append("%s (%s)" % [path, type])
	# A scan that finds nothing would pass every scene for the wrong reason.
	assert_gt(checked, 10, "the scan reaches the networked scenes")
	assert_eq(unknown, PackedStringArray(), "set type_name on the PropSync node to a type with a definition")


## The type_name of the scene's own PropSync node, its default when the line is absent, or "" when
## the scene has no PropSync.
func _prop_sync_type(text: String) -> String:
	var node := RegEx.create_from_string("\\[node name=\"PropSync\"[^\\]]*\\]\\n((?:(?!\\n\\[)[\\s\\S])*)")
	var found := node.search(text.replace("\r\n", "\n"))
	if found == null:
		return ""
	var type := RegEx.create_from_string("type_name = \"([^\"]+)\"").search(found.get_string(1))
	return type.get_string(1) if type != null else DEFAULT_TYPE


func _scenes_under(dir: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for file: String in DirAccess.get_files_at(dir):
		if file.ends_with(".tscn"):
			found.append(dir.path_join(file))
	for sub: String in DirAccess.get_directories_at(dir):
		found.append_array(_scenes_under(dir.path_join(sub)))
	return found
