@tool
class_name RockCatalogue
## The rock catalogue — what a `rock_type` slug on a biome zone means.
##
## Source of truth: tools/planettech/qgis/layers/rocks.py, exported to
## res://assets/_universe/_shared/materials/rocks.json by export_rocks.py
## (export_biomes.py refreshes it with every biome export). Per rock:
##   label, formula, colors [light, dark] (hex), night_colors (chameleon rocks),
##   impurities [{element, ppm_min, ppm_max, ions, optional}], minerals
##   [{name, formula}], purity, surface (false = underground only).
##
## Loaded once, then read-only: safe to call from the mesh workers. The tint
## is a pure function of position (SurfaceNoise), so every client and the
## server bake the same vertex colours.

const PATH := "res://assets/_universe/_shared/materials/rocks.json"

## Feature sizes of the shading between a rock's light and dark tints: large
## blotches and finer streaks (the corundum iron stain uses the same pattern).
## A rock may override them one day from rocks.json; for now they are global.
const BLOTCH_M := 2800.0
const STREAK_M := 700.0

static var _rocks: Dictionary = {}
static var _colors: Dictionary = {}     # slug → [Color light, Color dark]
static var _night: Dictionary = {}      # slug → [Color, Color] (chameleon only)
static var _loaded := false
static var _mutex := Mutex.new()


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_mutex.lock()
	if not _loaded:
		_load()
		_loaded = true
	_mutex.unlock()


static func _load() -> void:
	var rocks := {}
	var colors := {}
	var night := {}
	if FileAccess.file_exists(PATH):
		var txt := FileAccess.get_file_as_string(PATH)
		var parsed: Variant = JSON.parse_string(txt)
		if typeof(parsed) == TYPE_DICTIONARY:
			rocks = (parsed as Dictionary).get("rocks", {})
	else:
		push_warning("[RockCatalogue] %s not found — run tools/planettech/qgis/export_rocks.py" % PATH)
	for slug in rocks:
		var r: Dictionary = rocks[slug]
		var pair := _pair(r.get("colors"))
		if not pair.is_empty():
			colors[slug] = pair
		var npair := _pair(r.get("night_colors"))
		if not npair.is_empty():
			night[slug] = npair
	_rocks = rocks
	_colors = colors
	_night = night


static func _pair(v: Variant) -> Array:
	if v is Array and (v as Array).size() == 2:
		return [Color.html(str(v[0])), Color.html(str(v[1]))]
	return []


## Force a reload (tests, editor tooling after a re-export).
static func reload() -> void:
	_mutex.lock()
	_load()
	_loaded = true
	_mutex.unlock()


static func has(slug: String) -> bool:
	_ensure_loaded()
	return _rocks.has(slug)


## The raw catalogue entry, {} when unknown.
static func get_rock(slug: String) -> Dictionary:
	_ensure_loaded()
	return _rocks.get(slug, {})


static func slugs() -> Array:
	_ensure_loaded()
	return _rocks.keys()


## [light, dark] daylight tints, or [] when the rock has none.
static func colors_of(slug: String) -> Array:
	_ensure_loaded()
	return _colors.get(slug, [])


## [light, dark] night tints of a chameleon rock, or [] otherwise.
static func night_colors_of(slug: String) -> Array:
	_ensure_loaded()
	return _night.get(slug, [])


## Does this rock exist at the surface (false: underground only, e.g. hercynite)?
static func is_surface(slug: String) -> bool:
	return bool(get_rock(slug).get("surface", true))


## The ground colour of [param slug] at a point [param dir] of a sphere of
## [param radius]: the rock's light tint blended toward its dark tint by a
## deterministic two-octave mottling, so a zone shows every shade between the
## two instead of one flat colour. Returns [param fallback] for a rock without
## colours.
static func tint(dir: Vector3, radius: float, slug: String, fallback: Color = Color(0.5, 0.5, 0.5)) -> Color:
	var pair := colors_of(slug)
	if pair.is_empty():
		return fallback
	var t := SurfaceNoise.mottle(dir, radius, BLOTCH_M, STREAK_M)
	return (pair[0] as Color).lerp(pair[1] as Color, t)
