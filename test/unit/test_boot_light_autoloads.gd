extends GutTest
## The autoloads load before the game's first frame, on the main thread, and so does every script the
## GDScript analyzer meets while compiling them: a global class or an autoload named in their code, a
## preload, a scene's ext_resource. Naming one gameplay class there (Player, Planet, a rock...) pulled in
## a cycle of 255 scripts and their scenes: 12.8 s at boot, Windows calling the game "not responding"
## (2026-11-19). The autoloads load gameplay scripts with load() when they first need them, untyped.
##
## This follows the same edges from every autoload and fails, with the chain, when one of those scripts
## comes back. Comments and strings are skipped (a path in a string is only an edge inside preload()).

## Scripts that must not load with the autoloads: each opens the gameplay cycle.
const FORBIDDEN: Array[String] = [
	"res://scenes/player/player.gd",
	"res://scenes/player/player_client.gd",
	"res://scenes/planet/planet_body.gd",
	"res://scenes/planet/planet_terrain.gd",
	"res://scenes/_universe/environment/terrain/rocks/rock_mining.gd",
	"res://server/server.gd",
	"res://scenes/globals/prop_net.gd",
	"res://ui/direct_chat/direct_chat.gd",
]
## Files the autoloads may bring in all together (64 on 2026-11-19, 645 before).
const MAX_FILES := 120

var _classes: Dictionary = {}  # global class or autoload name -> path
var _identifier := RegEx.new()
var _preload := RegEx.new()
var _ext_resource := RegEx.new()


func before_all() -> void:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		_classes[String(entry["class"])] = String(entry["path"])
	for autoload in _autoloads():
		_classes[autoload[0]] = autoload[1]
	_identifier.compile("\\b[A-Z][A-Za-z0-9_]*\\b")
	_preload.compile("preload\\(\\s*\"([^\"]+)\"")
	_ext_resource.compile("\\[ext_resource[^\\]]*path=\"([^\"]+)\"")


func test_the_autoloads_do_not_load_the_gameplay_scripts() -> void:
	var from: Dictionary = {}  # path -> the path that brought it in ("" for an autoload)
	var queue: Array[String] = []
	for autoload in _autoloads():
		from[autoload[1]] = ""
		queue.append(autoload[1])
	while not queue.is_empty() and from.size() <= MAX_FILES * 2:
		var path: String = queue.pop_front()
		for next: String in _dependencies(path):
			if not from.has(next):
				from[next] = path
				queue.append(next)
	for path in FORBIDDEN:
		assert_false(from.has(path), "an autoload loads %s: %s" % [path.get_file(), _chain(from, path)])
	assert_lt(from.size(), MAX_FILES, "files loaded with the autoloads")


func test_the_names_spelt_out_in_the_autoloads_match() -> void:
	assert_eq(load("res://server/mission_heartbeat.gd").PLANET_GROUP, Planet.GROUP)
	assert_eq(load("res://scenes/globals/client_perf.gd").PLANET_GROUP, Planet.GROUP)
	assert_eq(RockMining.WEIGHT_REDUCTION_FACTOR, MineralRegistry.WEIGHT_REDUCTION_FACTOR)


## [name, script path] of every autoload that is a script.
static func _autoloads() -> Array:
	var out: Array = []
	for property: Dictionary in ProjectSettings.get_property_list():
		var key: String = property["name"]
		if not key.begins_with("autoload/"):
			continue
		var path: String = str(ProjectSettings.get_setting(key)).trim_prefix("*")
		if path.ends_with(".gd"):
			out.append([key.trim_prefix("autoload/"), path])
	return out


## What the analyzer (a script) or the loader (a scene, a resource) loads along with [param path].
func _dependencies(path: String) -> Array[String]:
	var out: Array[String] = []
	if not FileAccess.file_exists(path):
		return out
	var text := FileAccess.get_file_as_string(path)
	if path.ends_with(".gd"):
		var code := _code_of(text)
		for found in _identifier.search_all(code):
			var target: String = _classes.get(found.get_string(), "")
			if target != "" and target != path and not target in out:
				out.append(target)
		for found in _preload.search_all(code):
			out.append(_resolved(found.get_string(1)))
	elif path.ends_with(".tscn") or path.ends_with(".tres"):
		for found in _ext_resource.search_all(text):
			var target := _resolved(found.get_string(1))
			if target.get_extension() in ["gd", "tscn", "tres"]:
				out.append(target)
	return out


static func _resolved(path: String) -> String:
	if path.begins_with("uid://"):
		return ResourceUID.get_id_path(ResourceUID.text_to_id(path))
	return path


## [param text] without its comments, and with its strings emptied unless one is a preload's path.
static func _code_of(text: String) -> String:
	var out := PackedStringArray()
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == "#":
			var end := text.find("\n", i)
			i = n if end < 0 else end
			continue
		if c == "\"" or c == "'":
			var quote := text.substr(i, 3) if text.substr(i, 3) in ["\"\"\"", "'''"] else c
			var j := i + quote.length()
			while j < n and text.substr(j, quote.length()) != quote:
				j += 2 if text[j] == "\\" else 1
			var literal := text.substr(i, j + quote.length() - i)
			out.append(literal if literal.contains("res://") or literal.contains("uid://") else "\"\"")
			i = j + quote.length()
			continue
		out.append(c)
		i += 1
	return "".join(out)


static func _chain(from: Dictionary, path: String) -> String:
	var chain: PackedStringArray = []
	var at := path
	while at != "":
		chain.append(at.get_file())
		at = from.get(at, "")
	return " <- ".join(chain)
