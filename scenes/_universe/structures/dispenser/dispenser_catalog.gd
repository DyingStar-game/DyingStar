class_name DispenserCatalog
extends RefCounted

## What an ItemDispenser offers: every item .tres of one folder, in file-name order — vehicle parts
## (VehicleComponentSpec), rations, tools (DispenserItem). An item is anything with a display_name, an
## icon and a scene_path, plus an optional count. A new item is a new .tres in the folder, with no
## list to edit. Read through ResourceLoader.list_directory, which also sees an exported build's
## remapped files (a DirAccess listing there only finds the .remap stubs).

## Folder -> its items, loaded once and shared (read-only for the callers).
static var _by_dir: Dictionary = {}


## The items of [param dir].
static func all(dir: String) -> Array[Resource]:
	if not _by_dir.has(dir):
		var found: Array[Resource] = []
		var files: PackedStringArray = ResourceLoader.list_directory(dir)
		files.sort()
		for file: String in files:
			if not file.ends_with(".tres"):
				continue
			var item: Resource = load(dir.path_join(file))
			if item != null and "scene_path" in item and str(item.scene_path) != "":
				found.append(item)
		_by_dir[dir] = found
	return _by_dir[dir]


## The item of [param dir] saved at [param path], or null when it is not one of them: what a client
## asks for is checked against the catalogue, never loaded from the path it sent.
static func find(dir: String, path: String) -> Resource:
	for item: Resource in all(dir):
		if item.resource_path == path:
			return item
	return null


## How many [param item] hands out per delivery (1 unless it says otherwise).
static func count_of(item: Resource) -> int:
	return maxi(int(item.get("count")), 1) if "count" in item else 1
