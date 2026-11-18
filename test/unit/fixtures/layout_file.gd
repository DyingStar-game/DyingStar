class_name LayoutFile
extends RefCounted

## What the layout tests read from a village or city layout scene, and from the scenes it places,
## WITHOUT instancing the layout: its buildings pull in materials that raise engine errors on load.
## One reader for every layout test, so a resave by the editor (a `unique_id`, an identity transform
## it leaves out) breaks none of them.

const LOCALISATION := "res://tools/localization/localisation.csv"


## The networked items [param layout] (res:// path) places, in its file's order: {scene, xform (in the
## layout's frame), key, parent}. A folder (a bare Node3D with no script, poi_villages.is_folder) is
## seen through: what stands in it counts as standing under the root, its key its name alone. With
## [param nested], the items placed UNDER one of those (the containers of a storage area) too, their
## key "parent/name" as poi_villages draws their uuid from; else those only, their key their name.
## A node with no transform line stands at its parent's origin: Godot leaves an identity transform
## out of the file.
static func items(layout: String, nested: bool = true) -> Array:
	var text := FileAccess.get_file_as_string(layout).replace("\r\n", "\n")
	var paths := {}
	for ext in RegEx.create_from_string("\\[ext_resource [^\\]]*path=\"([^\"]+)\" id=\"([^\"]+)\"\\]").search_all(text):
		paths[ext.get_string(2)] = ext.get_string(1)
	var head := RegEx.create_from_string("^name=\"([^\"]+)\" parent=\"([^\"]+)\"[^\\]]*instance=ExtResource\\(\"([^\"]+)\"\\)")
	var place := RegEx.create_from_string("\\ntransform = (Transform3D\\([^)]*\\))")
	var folder := RegEx.create_from_string("^name=\"([^\"]+)\" type=\"Node3D\" parent=\"([^\"]+)\"")
	var folders := {".": Transform3D.IDENTITY}  # a folder's path -> its transform in the layout's frame
	var frames := {}  # the path of an item under the root or a folder -> [its transform, its key]
	var out: Array = []
	for block in text.split("\n[node "):
		var t := place.search(block)
		var xf: Transform3D = str_to_var(t.get_string(1)) if t != null else Transform3D.IDENTITY
		var f := folder.search(block)
		if f != null and folders.has(f.get_string(2)) and not block.contains("\nscript = "):
			folders[_path(f.get_string(2), f.get_string(1))] = folders[f.get_string(2)] * xf
			continue
		var m := head.search(block)
		if m == null:
			continue
		var name := m.get_string(1)
		var parent := m.get_string(2)
		if folders.has(parent):
			xf = folders[parent] * xf
			frames[_path(parent, name)] = [xf, name]
			parent = "."
		elif not nested or not frames.has(parent):
			continue
		else:
			xf = frames[parent][0] * xf
			parent = frames[parent][1]
			name = "%s/%s" % [parent, name]
		out.append({"scene": paths.get(m.get_string(3), ""), "xform": xf, "key": name, "parent": parent})
	return out


## The scene-file path of the node [param name] under [param parent] ("." = the root).
static func _path(parent: String, name: String) -> String:
	return name if parent == "." else "%s/%s" % [parent, name]


## The scenes instanced straight under [param layout]'s root, each once.
static func root_scenes(layout: String) -> Array[String]:
	var out: Array[String] = []
	for it: Dictionary in items(layout, false):
		if it["scene"] != "" and not out.has(it["scene"]):
			out.append(it["scene"])
	return out


## How many of [param from] (as [method items] returns them) are [param scene].
static func count(from: Array, scene: String) -> int:
	return from.filter(func(it: Dictionary) -> bool: return it["scene"] == scene).size()


## The scene [param scene] inherits (its root is an instance of it), or "" for a scene of its own.
static func base_of(scene: String) -> String:
	var state := (load(scene) as PackedScene).get_state()
	var base := state.get_node_instance(0) if state.get_node_count() > 0 else null
	return base.resource_path if base != null else ""


## Whether [param scene] spawns as a networked prop: it carries a PropSync, of its own or in the scene
## it inherits. Read from the packed state: nothing is instanced.
static func is_networked(scene: String) -> bool:
	var state := (load(scene) as PackedScene).get_state()
	for i in state.get_node_count():
		for p in state.get_node_property_count(i):
			if state.get_node_property_name(i, p) == &"script":
				var script := state.get_node_property_value(i, p) as Script
				if script != null and script.resource_path.ends_with("/prop_sync.gd"):
					return true
	var base := base_of(scene)
	return base != "" and is_networked(base)


## The translation table: key -> {en, fr}, read as the game reads it (quoted fields included).
static func translations() -> Dictionary:
	var out := {}
	var file := FileAccess.open(LOCALISATION, FileAccess.READ)
	if file == null:
		return out
	var header := Array(file.get_csv_line())
	var en_col := header.find("en")
	var fr_col := header.find("fr")
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() > maxi(en_col, fr_col) and row[0].strip_edges() != "":
			out[row[0]] = {"en": row[en_col], "fr": row[fr_col]}
	file.close()
	return out
