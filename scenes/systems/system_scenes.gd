class_name SystemScenes
extends RefCounted

## What celestial bodies EXIST, read from the scene FILES — never from the scene tree.
##
## A body is replicated like any other object, so only those in GORC range are ever in the tree: the
## first version of the system chart listed four bodies out of nineteen for exactly that reason. The
## files, on the other hand, are always all there, and their root nodes carry everything needed to
## name, colour, size and orbit a body without building a single terrain.
##
## Static on purpose: this answers a question about the PROJECT, not about any node, so it holds no
## state and belongs to no scene. Two callers today — the system chart (StarMap) and the teleporter's
## destination catalogue — and they used to be one implementation each.
##
## ⚠️ Reading a SAVED scene is not the same as reading a live node: see [method radius_of].

## Where systems live. One subdirectory per star system; today there is only `tarsis`, and scanning
## rather than hard-coding it is the whole reason a second one would cost nothing.
const SYSTEMS_ROOT: String = "res://scenes/systems"

## Radius used for a body whose scene names none. A plausible terrestrial value, so a body nobody has
## filled in is merely wrong rather than invisible.
const FALLBACK_RADIUS_M: float = 6.0e6


## Every system in the project, sorted. A directory counts as a system as soon as it holds one body
## scene, so an empty or stray folder never shows up in a menu.
static func systems() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(SYSTEMS_ROOT)
	if dir == null:
		push_warning("[SystemScenes] cannot open %s" % SYSTEMS_ROOT)
		return out
	var seen: PackedStringArray = dir.get_directories()
	for name: String in seen:
		if not body_files(name).is_empty():
			out.append(name)
	out.sort()
	if out.is_empty():
		# Never fail silently. A caller only sees an empty menu, and the reason — a directory holding no
		# file we recognise as a scene — is invisible from there.
		push_warning("[SystemScenes] no system under %s; directories seen: [%s]" % [
			SYSTEMS_ROOT, ", ".join(seen),
		])
	return out


static func system_dir(system: String) -> String:
	return "%s/%s" % [SYSTEMS_ROOT, system]


static func path_of(system: String, file_name: String) -> String:
	return "%s/%s" % [system_dir(system), file_name]


## The scene file name behind a directory entry, or "" when the entry is not a scene.
##
## ⚠️ An exported build does NOT keep a scene next to its folder: the binary scene moves under
## res://.godot/exported/ and a `<name>.tscn.remap` stands in its place. Measured in the shipped PCK:
## scenes/systems/tarsis holds nineteen `tarsis_*.tscn.remap` and not one .tscn or .scn — which is
## why every menu built from this list was full in the editor and EMPTY in production.
## load() follows the remap on its own, so the name to keep is the one WITHOUT that suffix: exactly
## the path the editor uses. Normalising here rather than widening the filter is what keeps
## get_basename() giving "tarsis_4" instead of "tarsis_4.tscn".
static func scene_name_of(entry: String) -> String:
	var file_name: String = entry.trim_suffix(".remap")
	if file_name.ends_with(".tscn") or file_name.ends_with(".scn"):
		return file_name
	return ""


## Scene file names of a system's bodies, SORTED — which also orders every parent before its moons
## ("tarsis_3" before "tarsis_3_1"), the property [method parent_key_of] relies on.
static func body_files(system: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(system_dir(system))
	if dir == null:
		return out
	for entry: String in dir.get_files():
		var file_name: String = scene_name_of(entry)
		if file_name != "":
			out.append(file_name)
	out.sort()
	return out


## Body keys of a system, sorted: "tarsis_1", "tarsis_3", "tarsis_3_1", … A key is the scene's
## basename, and it is ALSO the PlanetData.planet_name, the `<key>_poi.json` prefix and the
## `<key>_chunks` directory. That one regular convention is what lets these live apart.
static func body_keys(system: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for f: String in body_files(system):
		out.append(f.get_basename())
	return out


## The root node's saved property overrides, WITHOUT instantiating the scene — instantiating a planet
## would build its terrain, which is exactly what reading files is for.
static func root_properties(path: String) -> Dictionary:
	var out: Dictionary = {}
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		return out
	var state: SceneState = packed.get_state()
	if state.get_node_count() == 0:
		return out
	for i: int in range(state.get_node_property_count(0)):
		out[state.get_node_property_name(0, i)] = state.get_node_property_value(0, i)
	return out


## ⚠️ The extension is resolved, not assumed: body_files() accepts a binary .scn too, and rebuilding
## "<key>.tscn" would then load nothing. ResourceLoader.exists() follows remaps; DirAccess does not.
static func body_properties(system: String, key: String) -> Dictionary:
	var path: String = path_of(system, "%s.tscn" % key)
	if not ResourceLoader.exists(path):
		path = path_of(system, "%s.scn" % key)
	return root_properties(path)


## The body a moon orbits, by the naming convention — "tarsis_3_1" belongs to "tarsis_3" — which is
## how the scenes are laid out and what the network parenting mirrors. Empty for a planet.
## [param known] holds the keys already accepted, so a planet whose name merely contains an
## underscore is not mistaken for somebody's moon.
static func parent_key_of(key: String, known: Dictionary) -> String:
	var cut: int = key.rfind("_")
	if cut > 0 and known.has(key.substr(0, cut)):
		return key.substr(0, cut)
	return ""


## Proper name of a body, as the GDD gives it — "SandBox - Tarsis III". Falls back to the key, which
## is at least unambiguous.
static func display_name_of(key: String, props: Dictionary) -> String:
	var label: String = str(props.get("display_name", ""))
	return label if label != "" else key


## Radius in metres, from a body's SAVED properties.
##
## ⚠️ NOT planet_data.radius: in a saved scene that property still holds its 1000 m default, because
## the real value is only applied at runtime by apply_chunk_manifest(). Reading files statically —
## which is the whole point here — made every planet a kilometre wide.
static func radius_of(props: Dictionary) -> float:
	var km: float = float(props.get("map_radius_km", 0.0))
	if km > 0.0:
		return km * 1000.0
	return FALLBACK_RADIUS_M
