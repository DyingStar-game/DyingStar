@tool
extends RefCounted

## What the asset library lists: which project files are assets, what kind each one is and which tags
## it carries, and how a list of them is filtered.
##
## Pure logic: nothing here touches the editor, so it is unit-tested (test/unit/test_asset_catalog.gd).
## An asset is a Dictionary: {path, name, type, category, tags, needs_credit, credit, lod, lods}. credit
## is the file that credits it, filled in by whoever can read the folders (credit_source), "" when
## nothing does. lods are its levels of detail, when it has several (group_lods).

## The folders the library lists. Levels, UI and the rest are not level design material.
const ROOTS: PackedStringArray = ["res://assets", "res://scenes"]
## Left out of them: planets and whole systems are worlds, not something to place in one. A planet's
## scene also generates its terrain as soon as it is instanced, which is no way to look at an asset.
const EXCLUDED_FOLDERS: PackedStringArray = ["res://scenes/systems/", "res://scenes/planet/"]

const ALL := &"all"
const MODEL := &"model"
const SCENE := &"scene"
const MATERIAL := &"material"
const TEXTURE := &"texture"
const ICON := &"icon"
const SOUND := &"sound"
const SHADER := &"shader"

## The categories, in the order they are listed: [key, label, editor icon].
const CATEGORIES: Array = [
	[ALL, "All", &"FileList"],
	[MODEL, "3D models", &"MeshInstance3D"],
	[SCENE, "Scenes", &"PackedScene"],
	[MATERIAL, "Materials", &"StandardMaterial3D"],
	[TEXTURE, "Textures", &"ImageTexture"],
	[ICON, "Icons & markers", &"TextureRect"],
	[SOUND, "Sounds", &"AudioStreamPlayer"],
	[SHADER, "Shaders", &"Shader"],
]

## The category of every resource class that derives from one of these. A scene is told apart below.
const CATEGORY_OF_BASE: Array = [
	[&"Mesh", MODEL],
	[&"Material", MATERIAL],
	[&"Texture2D", TEXTURE],
	[&"AudioStream", SOUND],
	[&"Shader", SHADER],
]

## A scene imported from one of these is a model; any other scene was put together in the editor.
const MODEL_EXTENSIONS: PackedStringArray = ["glb", "gltf", "fbx", "blend"]

## How a level of detail is named: <asset>_lod<N>, 0 the finest.
const LOD_SUFFIX := "_lod"

## A shared material is mat_<family>_<descriptor>: the family is its tag, the same word as in
## Blender's Asset Browser and the footstep sounds.
const MATERIAL_PREFIX := "mat_"

## A texture in a folder named like this is an icon, a marker or an interface picture, listed apart from
## the surface textures: the folder's name holds one of these words...
const ICON_FOLDER_WORDS: PackedStringArray = ["icon", "marker"]
## ...or is one of these.
const ICON_FOLDERS: PackedStringArray = [
	"ui", "hud", "poi", "input", "interfaces", "mission_categories", "localizations", "menu"]

## What follows is the rule of tools/generate_credits.py, which the pull request check applies: keep
## the two alike. Only what is under this folder is credited...
const CREDITED_ROOT := "res://assets/"
## ...and only sounds, models and textures.
const CREDITED_EXTENSIONS: PackedStringArray = [
	"ogg", "mp3", "wav", "flac", "dsgarment", "glb", "gltf", "blend", "fbx", "obj",
	"png", "jpg", "jpeg", "exr", "webp", "tga", "hdr"]
## A shared material's credit is the author and license of its manifest.
const MATERIAL_MANIFEST := "material.json"
## A third-party library's own licence file credits everything under its folder.
const LIBRARY_LICENCES: PackedStringArray = ["license.txt", "license.md"]
## Text files that sit among the assets but credit nothing by name.
const NOT_CREDITS: PackedStringArray = ["license.txt", "license.md", "readme.txt", "blender_assets.cats.txt"]


## The asset behind a project file, or an empty Dictionary when the file is not one the library lists.
## [param type] is the resource class the editor's file system gives for it.
static func make_entry(path: String, type: StringName) -> Dictionary:
	for folder in EXCLUDED_FOLDERS:
		if path.begins_with(folder):
			return {}
	var category := category_of(type, path)
	if category == &"":
		return {}
	return {
		"path": path,
		"name": path.get_file().get_basename(),
		"type": String(type),
		"category": category,
		"tags": tags_of(path),
		"needs_credit": needs_credit(path),
		"credit": "",
		"lod": -1,
		"lods": [],
	}


## The category of a file of that resource class, or an empty name when the library does not list it.
static func category_of(type: StringName, path: String) -> StringName:
	if type == &"PackedScene":
		return MODEL if path.get_extension().to_lower() in MODEL_EXTENSIONS else SCENE
	if not ClassDB.class_exists(type):
		return &""
	for pair: Array in CATEGORY_OF_BASE:
		if type == pair[0] or ClassDB.is_parent_class(type, pair[0]):
			return ICON if pair[1] == TEXTURE and is_icon_path(path) else pair[1]
	return &""


## Whether the texture at [param path] is an icon, a marker or an interface picture, by its folders.
static func is_icon_path(path: String) -> bool:
	for folder in path.trim_prefix("res://").get_base_dir().to_lower().split("/", false):
		if folder in ICON_FOLDERS:
			return true
		for word in ICON_FOLDER_WORDS:
			if folder.contains(word):
				return true
	return false


## The level of detail a file name carries: {"base": the name without its suffix, "level": N}. The
## level is -1 for a name with no suffix (the asset itself, when its lower levels sit beside it).
static func lod_of(asset_name: String) -> Dictionary:
	var at := asset_name.to_lower().rfind(LOD_SUFFIX)
	var digits := asset_name.substr(at + LOD_SUFFIX.length()) if at > 0 else ""
	if digits == "" or not digits.is_valid_int() or digits.to_int() < 0 or digits.begins_with("+"):
		return {"base": asset_name, "level": -1}
	return {"base": asset_name.substr(0, at), "level": digits.to_int()}


## [param entries] with the levels of detail of an asset folded into one entry: it is listed once,
## under its name without the suffix, and carries its levels in "lods" (the finest first, itself
## included). Levels belong together when they share a folder, a base name and a file type. An asset
## with a single level is left as it is.
static func group_lods(entries: Array) -> Array:
	var groups := {}
	for entry: Dictionary in entries:
		var lod := lod_of(entry["name"])
		entry["lod"] = lod["level"]
		var key := _lod_key(entry, lod["base"])
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(entry)
	for key: String in groups:
		(groups[key] as Array).sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["lod"] < b["lod"])
	var kept: Array = []
	for entry: Dictionary in entries:
		var base: String = lod_of(entry["name"])["base"]
		var levels: Array = groups[_lod_key(entry, base)]
		if levels.size() < 2:
			kept.append(entry)
		elif is_same(entry, levels[0]):
			var head := entry.duplicate()
			head["name"] = base
			head["lods"] = levels
			kept.append(head)
	return kept


static func _lod_key(entry: Dictionary, base: String) -> String:
	var path: String = entry["path"]
	return "%s/%s.%s" % [path.get_base_dir(), base.to_lower(), path.get_extension().to_lower()]


## Whether the asset needs a credit and has none.
static func is_uncredited(entry: Dictionary) -> bool:
	return entry["needs_credit"] and entry["credit"] == ""


## The tags of a file, read from where it is and how it is named: the folders it sits in
## (assets/_universe/structures/industrial/garage.glb -> structures, industrial), then the family of a
## shared material (mat_metal_rusty, or a texture in that material's folder -> metal).
static func tags_of(path: String) -> PackedStringArray:
	var tags := PackedStringArray()
	var own_name := path.get_file().get_basename().to_lower()
	var family := _family_of(own_name)
	var folders := path.trim_prefix("res://").get_base_dir().split("/", false)
	for i in folders.size():
		var folder := folders[i].to_lower()
		if family == "":
			family = _family_of(folder)
		# The root, a grouping folder (_universe, _shared), a material's own folder or a folder named
		# after its one asset says nothing a filter could use.
		if i == 0 or folder.begins_with("_") or folder.begins_with(MATERIAL_PREFIX) or folder == own_name:
			continue
		if not tags.has(folder):
			tags.append(folder)
	if family != "" and not tags.has(family):
		tags.append(family)
	return tags


static func _family_of(file_or_folder: String) -> String:
	if not file_or_folder.begins_with(MATERIAL_PREFIX):
		return ""
	var parts := file_or_folder.trim_prefix(MATERIAL_PREFIX).split("_", false)
	return parts[0] if parts.size() >= 2 else ""


## Whether the project asks for a credit beside this file: a sound, a model or a texture someone made.
static func needs_credit(path: String) -> bool:
	return path.begins_with(CREDITED_ROOT) and path.get_extension().to_lower() in CREDITED_EXTENSIONS


## The file that credits the asset at [param path], or "" when nothing does: a credit .txt of its name
## (or <prefix>.txt for a set of <prefix>_* files) beside it, its material's manifest, or the licence
## file of the library it belongs to. [param files_in] gives the file names of a folder
## (func(folder: String) -> PackedStringArray), so the rule is tested without a disk.
static func credit_source(path: String, files_in: Callable) -> String:
	var folder := path.get_base_dir()
	var file := path.get_file()
	var stem := file.get_basename()
	var beside: PackedStringArray = files_in.call(folder)
	for other in beside:
		if other == MATERIAL_MANIFEST:
			return folder.path_join(other)
		if other.get_extension().to_lower() != "txt" or other.to_lower() in NOT_CREDITS:
			continue
		var base := other.get_basename()
		if stem == base or file.begins_with(base + "_"):
			return folder.path_join(other)
	# A library's licence, in this folder or in any above it short of the root.
	while folder.length() > CREDITED_ROOT.length():
		var names: PackedStringArray = files_in.call(folder)
		for other in names:
			if other.to_lower() in LIBRARY_LICENCES:
				return folder.path_join(other)
		folder = folder.get_base_dir()
	return ""


## The assets of [param category] (ALL for every one) that carry [param tag] ("" for any) and match
## [param search]: every word of it is found in the path or in a tag, whatever the case. With
## [param only_uncredited], only those that need a credit and have none.
static func filter(entries: Array, category: StringName, tag: String, search: String,
		only_uncredited: bool = false) -> Array:
	var words := search.to_lower().split(" ", false)
	var kept: Array = []
	for entry: Dictionary in entries:
		if category != ALL and entry["category"] != category:
			continue
		if only_uncredited and not is_uncredited(entry):
			continue
		var tags: PackedStringArray = entry["tags"]
		if tag != "" and not tags.has(tag):
			continue
		if not _matches(entry, words):
			continue
		kept.append(entry)
	return kept


static func _matches(entry: Dictionary, words: PackedStringArray) -> bool:
	if words.is_empty():
		return true
	var tags: PackedStringArray = entry["tags"]
	var haystack := (String(entry["path"]) + " " + " ".join(tags)).to_lower()
	for word in words:
		if not haystack.contains(word):
			return false
	return true


## How many assets each category holds: {category: count}, ALL included.
static func counts(entries: Array) -> Dictionary:
	var result := {ALL: entries.size()}
	for entry: Dictionary in entries:
		var category: StringName = entry["category"]
		result[category] = int(result.get(category, 0)) + 1
	return result


## The tags to offer, out of [param tag_counts] ([[tag, count], ...]), while [param typed] is being
## typed in the tag field: all of them in alphabetical order when nothing is typed, else those that
## start with it, then those that hold it. [param pinned], the tag in use, always comes first.
static func matching_tags(tag_counts: Array, typed: String, pinned: String = "") -> Array:
	var wanted := typed.strip_edges().to_lower()
	var by_name := tag_counts.duplicate()
	by_name.sort_custom(func(a: Array, b: Array) -> bool: return String(a[0]) < String(b[0]))
	var first: Array = []
	var starting: Array = []
	var holding: Array = []
	for pair: Array in by_name:
		var tag := String(pair[0])
		if tag == pinned:
			first.append(pair)
		elif wanted == "" or tag.begins_with(wanted):
			starting.append(pair)
		elif tag.contains(wanted):
			holding.append(pair)
	return first + starting + holding


## The tags found in [param category], the most used first: [[tag, count], ...].
static func tag_counts(entries: Array, category: StringName) -> Array:
	var found := {}
	for entry: Dictionary in entries:
		if category != ALL and entry["category"] != category:
			continue
		var tags: PackedStringArray = entry["tags"]
		for tag in tags:
			found[tag] = int(found.get(tag, 0)) + 1
	var result: Array = []
	for tag: String in found:
		result.append([tag, found[tag]])
	result.sort_custom(func(a: Array, b: Array) -> bool:
		return a[1] > b[1] if a[1] != b[1] else String(a[0]) < String(b[0]))
	return result
