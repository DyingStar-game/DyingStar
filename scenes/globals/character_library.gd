class_name CharacterLibrary
extends RefCounted

## The player's characters (CharacterSheet each): list, fetch, save, remove. Every call is awaited -- the backend's
## API answers over HTTP (PlayerServices) -- and goes to [member backend]: today a folder on this machine
## (user://characters/<id>.json), tomorrow the backend, behind the same four calls. A sheet read is the sheet as
## kept; CharacterSheet.read() migrates its look.
##
## The look worn in game still goes through CharacterStore (its replicated string, sent on spawn, confirmed by the
## server); CharacterStore.active_id() names the sheet it came from.

## What a sheet's id is made of (random bytes, hex).
const ID_BYTES: int = 16

## The backend the calls go to: any object with list(), fetch(id), save(sheet) and remove(id).
static var backend: Variant = Local.new()


## Every sheet, the latest saved first ([] when none or unreachable).
static func list() -> Array:
	return await backend.list()


## The sheet [param id], or {} when there is none.
static func fetch(id: String) -> Dictionary:
	if id == "":
		return {}
	return await backend.fetch(id)


## Keep [param sheet] (a new one gets its id and creation date): the sheet as kept, or {} on failure.
static func save(sheet: Dictionary) -> Dictionary:
	return await backend.save(sheet)


## Remove the sheet [param id]: whether it was there.
static func remove(id: String) -> bool:
	return await backend.remove(id)


static func new_id() -> String:
	return Crypto.new().generate_random_bytes(ID_BYTES).hex_encode()


## The sheets in a folder of this machine, one JSON file each. The first time it is listed, the look kept by
## CharacterStore (the single character of before) becomes its first sheet.
class Local:
	extends RefCounted

	const DIR: String = "user://characters"

	var dir: String = DIR

	func _init(folder: String = DIR) -> void:
		dir = folder

	func list() -> Array:
		_adopt_store()
		var out: Array = []
		if not DirAccess.dir_exists_absolute(dir):
			return out
		for file: String in DirAccess.get_files_at(dir):
			if file.get_extension() == "json":
				var sheet: Dictionary = _load(dir.path_join(file))
				if not sheet.is_empty():
					out.append(sheet)
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("updated_at", "")) > String(b.get("updated_at", "")))
		return out

	func fetch(id: String) -> Dictionary:
		return _load(_path(id)) if _valid(id) else {}

	func save(sheet: Dictionary) -> Dictionary:
		var kept: Dictionary = sheet.duplicate(true)
		var now: String = Time.get_datetime_string_from_system(true) + "Z"
		if not _valid(String(kept.get("id", ""))):
			kept["id"] = CharacterLibrary.new_id()
			kept["created_at"] = now
		kept["updated_at"] = now
		DirAccess.make_dir_recursive_absolute(dir)
		var f := FileAccess.open(_path(kept["id"]), FileAccess.WRITE)
		if f == null:
			return {}
		f.store_string(JSON.stringify(kept, "\t", true))
		f.close()
		return kept

	func remove(id: String) -> bool:
		if not _valid(id) or not FileAccess.file_exists(_path(id)):
			return false
		return DirAccess.remove_absolute(_path(id)) == OK

	func _path(id: String) -> String:
		return dir.path_join(id + ".json")

	## An id is hex only: never a path out of the folder.
	func _valid(id: String) -> bool:
		return id != "" and id.is_valid_hex_number()

	func _load(path: String) -> Dictionary:
		if not FileAccess.file_exists(path):
			return {}
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		return parsed if parsed is Dictionary else {}

	func _adopt_store() -> void:
		if DirAccess.dir_exists_absolute(dir) and not DirAccess.get_files_at(dir).is_empty():
			return
		var look: CharacterAppearance = CharacterStore.saved()
		if look == null:
			return
		var kept: Dictionary = save(CharacterSheet.make("", look))
		if not kept.is_empty():
			CharacterStore.set_active_id(kept["id"])
