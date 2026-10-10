@tool
extends EditorExportPlugin

## Stamps every export (server, Linux client, Windows client, local) with its own
## BuildInfo id: res://build_id.json exists only inside the exported pack, never in
## the repository, so the editor keeps an empty id.


func _get_name() -> String:
	return "DyingStarBuildId"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var id := BuildInfo.make_build_id()
	add_file(BuildInfo.PATH, JSON.stringify({"build_id": id}).to_utf8_buffer(), false)
	print("[BuildId] export stamped with build id %s" % id)
