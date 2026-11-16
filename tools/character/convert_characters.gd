extends Node

## Brings saved characters up to the game's version, in bulk -- an export of the backend, a player's files.
##
##   godot --headless --path . res://tools/character/convert_characters.tscn -- --in=<file or folder> --out=<folder>
##   [--check]  read and report only, write nothing (before rolling out a game whose CharacterDocument.VERSION rose)
##
## Takes .json files holding a character sheet (CharacterSheet), a bare document (CharacterDocument) or an array of
## them, and .txt files of old look codes (CharacterAppearance.encode, one a line). Writes each file again under
## <out> in the same shape -- a .txt as a .json array of sheets -- every look written at the game's version, sheets
## keeping their id, name, dates and portrait. An item that cannot be read (another format, a newer version) is
## written back untouched, and listed. Prints a report, also written as <out>/report.json; exits with 1 when any
## item was refused. docs/CHARACTER_FORMAT.md tells the backend team when and how to run it.

var _report: Dictionary = {"files": 0, "items": 0, "upgraded": 0, "from": {}, "warnings": [], "refused": []}


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var source: String = String(args.get("in", ""))
	var out: String = String(args.get("out", ""))
	var check: bool = args.has("check")
	if source == "" or (out == "" and not check):
		printerr("usage: -- --in=<file or folder> --out=<folder> [--check]")
		get_tree().quit(2)
		return
	var files: PackedStringArray = []
	if DirAccess.dir_exists_absolute(source):
		for file: String in DirAccess.get_files_at(source):
			if file.get_extension() in ["json", "txt"] and file != "report.json":
				files.append(source.path_join(file))
	elif FileAccess.file_exists(source):
		files.append(source)
	if not check:
		DirAccess.make_dir_recursive_absolute(out)
	for path: String in files:
		var converted: Variant = _convert_file(path)
		_report["files"] += 1
		if not check and converted != null:
			var file_name: String = path.get_file().get_basename() + ".json"
			var f := FileAccess.open(out.path_join(file_name), FileAccess.WRITE)
			f.store_string(JSON.stringify(converted, "\t", true))
			f.close()
	var text: String = JSON.stringify(_report, "\t", true)
	print(text)
	if not check:
		var f := FileAccess.open(out.path_join("report.json"), FileAccess.WRITE)
		f.store_string(text)
		f.close()
	get_tree().quit(1 if not (_report["refused"] as Array).is_empty() else 0)


func _convert_file(path: String) -> Variant:
	var text: String = FileAccess.get_file_as_string(path)
	if path.get_extension() == "txt":
		var sheets: Array = []
		for line: String in text.split("\n", false):
			if line.strip_edges() != "":
				sheets.append(_convert_code(line.strip_edges(), "%s:%d" % [path.get_file(), sheets.size() + 1]))
		return sheets
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		_refuse(path.get_file(), "not JSON")
		return null
	if parsed is Array:
		var items: Array = []
		for i in (parsed as Array).size():
			items.append(_convert_item(parsed[i], "%s[%d]" % [path.get_file(), i]))
		return items
	return _convert_item(parsed, path.get_file())


## A sheet or a bare document, at the game's version (or untouched when it cannot be read).
func _convert_item(item: Variant, where: String) -> Variant:
	_report["items"] += 1
	var is_sheet: bool = item is Dictionary and (item as Dictionary).has("appearance")
	var result: Dictionary = CharacterSheet.upgrade(item) if is_sheet else CharacterDocument.from_document(item)
	_count(result, where)
	if result["error"] != "":
		return item
	if is_sheet:
		if result["changed"]:
			_report["upgraded"] += 1
		return result["sheet"]
	if int(result["from"]) < CharacterDocument.VERSION:
		_report["upgraded"] += 1
	return CharacterDocument.to_document(result["look"])


## An old look code as a sheet (no name, no portrait).
func _convert_code(code: String, where: String) -> Variant:
	_report["items"] += 1
	var result: Dictionary = CharacterDocument.parse(code)
	_count(result, where)
	if result["error"] != "":
		return code
	_report["upgraded"] += 1
	return CharacterSheet.make("", result["look"])


func _count(result: Dictionary, where: String) -> void:
	var from: String = str(result["from"])
	_report["from"][from] = int(_report["from"].get(from, 0)) + 1
	for w: String in result["warnings"]:
		(_report["warnings"] as Array).append("%s: %s" % [where, w])
	if result["error"] != "":
		_refuse(where, result["error"])


func _refuse(where: String, why: String) -> void:
	(_report["refused"] as Array).append("%s: %s" % [where, why])
