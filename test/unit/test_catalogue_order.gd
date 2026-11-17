extends GutTest

## human_catalogue.json's lists only grow at the end: a character's replicated string (CharacterAppearance.encode)
## and Horizon's saved players hold POSITIONS in them. Its tools refuse to break that
## (tools/character/human_bank/catalogue_guard.py); this checks the catalogue in the repository against the order
## frozen in test/data/character/catalogue_order.json -- append there what you appended to the catalogue.

const FROZEN: String = "res://test/data/character/catalogue_order.json"


func _ids(entries: Array) -> Array:
	var out: Array = []
	for e: Variant in entries:
		out.append(e.get("id", e.get("key")) if e is Dictionary else e)
	return out


func _check(path: String, frozen: Array, now: Array) -> void:
	var ids: Array = _ids(now)
	for i in frozen.size():
		if i >= ids.size():
			fail_test("%s[%d] '%s' was removed: saved characters wearing it change" % [path, i, frozen[i]])
		elif ids[i] != frozen[i]:
			fail_test("%s[%d] '%s' is now '%s': saved characters change (only append at the end)" % [path, i, frozen[i],
					ids[i]])
	if ids.size() > frozen.size():
		gut.p("%s: %d new entries to append to %s" % [path, ids.size() - frozen.size(), FROZEN])


func test_saved_positions_keep_their_meaning() -> void:
	var frozen: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FROZEN))
	var cat: Dictionary = CharacterAppearance.catalogue()
	for list: String in ["modifiers", "eye_colours", "origins", "garments"]:
		_check(list, frozen.get(list, []), cat.get(list, []))
	for kind: String in frozen["assets"]:
		_check("assets/" + kind, frozen["assets"][kind], cat["assets"].get(kind, []))
	pass_test("every frozen position still names the same entry")
