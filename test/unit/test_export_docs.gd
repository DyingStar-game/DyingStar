extends GutTest
## Every @export of the game has its Inspector tooltip: a `##` doc comment directly above it (see
## CLAUDE.md). The team tunes the game in the Inspector; a knob with no text tells them nothing.
##
## Read as text, not through the script API: a script with a parse error, or one that needs the scene
## tree, is still checked. Third-party addons are left to their authors.

## Folders not checked, under res://.
const SKIPPED : Array[String] = [
	"res://.godot", "res://test", "res://addons/gut", "res://addons/open-world-database",
	"res://addons/uuid", "res://addons/godot-livekit", "res://addons/mqtt",
]

var _export := RegEx.create_from_string("^\\s*@export(?!_group|_subgroup|_category)\\w*")
var _var := RegEx.create_from_string("\\bvar\\b")


func test_every_export_has_a_tooltip() -> void:
	var missing : PackedStringArray = []
	for path: String in _scripts("res://"):
		missing.append_array(undocumented(path, FileAccess.get_file_as_string(path)))
	assert_eq(missing.size(), 0, "@export without a ## line above (the Inspector tooltip):\n" + "\n".join(missing))


func test_the_rule_reads_stacked_annotations_and_groups() -> void:
	var src := "\n".join([
		"## Documented.", "@export var a: int = 0",
		"## Documented, annotation on its own line.", "@export_range(0, 1)", "var b: float = 0.0",
		"@export_group(\"G\")", "## Documented under its group.", "@export var c: int = 0",
		"## The group comes between: lost.", "@export_group(\"H\")", "@export var d: int = 0",
		"# A plain comment is no tooltip.", "@export var e: int = 0",
		"@export var f: int = 0",
	])
	var found : PackedStringArray = undocumented("x.gd", src)
	assert_eq(found, PackedStringArray(["x.gd:11", "x.gd:13", "x.gd:14"]))


## "path:line" of every @export variable in [param source] without a `##` line directly above it (or
## above the annotations stacked on it).
func undocumented(path: String, source: String) -> PackedStringArray:
	var lines : PackedStringArray = source.split("\n")
	var out : PackedStringArray = []
	for i in lines.size():
		if _export.search(lines[i]) == null:
			continue
		var declares : bool = _var.search(lines[i]) != null \
				or (i + 1 < lines.size() and _var.search(lines[i + 1]) != null)
		if not declares or (_var.search(lines[i]) == null and _export.search(lines[i + 1]) != null):
			continue  # a stacked annotation: the variable's own @export line is checked instead
		var above : int = i - 1
		while above >= 0 and _export.search(lines[above]) != null and _var.search(lines[above]) == null:
			above -= 1
		if above < 0 or not lines[above].strip_edges().begins_with("##"):
			out.append("%s:%d" % [path, i + 1])
	return out


func _scripts(dir_path: String) -> PackedStringArray:
	var out : PackedStringArray = []
	if dir_path.trim_suffix("/") in SKIPPED:
		return out
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for sub: String in dir.get_directories():
		out.append_array(_scripts(dir_path.path_join(sub)))
	for file: String in dir.get_files():
		if file.ends_with(".gd"):
			out.append(dir_path.path_join(file))
	return out
