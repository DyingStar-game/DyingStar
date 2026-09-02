@tool
class_name BiomeQuery
extends RefCounted
## Loads biome polygons from a GeoJSON file and provides efficient
## point-in-polygon queries using longitude / latitude coordinates.
##
## NOTE: With v7+ chunk recipes, per-chunk "populate_zones" are embedded
## directly in the recipe JSON.  New spawner-dispatch code in PlanetTerrain
## checks populate_zones first and falls back to BiomeQuery when unavailable.
## BiomeQuery remains authoritative for:
##   • Per-vertex terrain effects (liquid overlay, rivers, cliffs, craters)
##   • Road queries (loaded separately via roads_geojson)
##   • Static geometry utilities (_dir_to_lonlat, _aabb_overlap, etc.)
## Gradual migration: as more terrain effects move to recipe data, this
## class will shrink to road/POI queries and geometry helpers only.
##
## Supports two loading modes:
##   1. Legacy: load all zones from a single GeoJSON + .partN files (eager).
##   2. Spatial: load a lightweight index, then lazy-load per-tile GeoJSON
##      files on demand as chunks request biome data.
##
## Usage:
##   var bq := BiomeQuery.new()
##   bq.load_geojson("res://assets/qgis/.export/tarsis_3_biomes.json")
##   var zone := bq.query_biome_type(dir, "forest")
##   if not zone.is_empty():
##       print("Inside forest zone with density ", zone.density)

## Each loaded zone is a Dictionary:
##   { biome_type: String, density: float, tree_type: String,
##     biome_index: int, polygon: PackedVector2Array,
##     bbox_min: Vector2, bbox_max: Vector2,
##     depth: float, width: float, radius: float,
##     intensity: float, wave_intensity: float,
##     canopy_height: float, undergrowth: String,
##     flow_direction: String,
##     centerline: PackedVector2Array,  # original LineString (lon,lat) if linear
##     half_width_deg: float }          # half-width in degrees for cross-section
var _zones: Array[Dictionary] = []
var _loaded: bool = false

# ── Spatial tile index fields ──
var _spatial_mode: bool = false
var _spatial_index: Dictionary = {}       # parsed index JSON
var _tile_deg: float = 10.0
var _tile_num_cols: int = 36
var _tile_num_rows: int = 18
var _loaded_tiles: Dictionary = {}        # tile_key (String) → true
var _known_zone_ids: Dictionary = {}      # zone_id (int) → true (dedup)
var _base_dir: String = ""                # directory containing tile files
var _tile_zone_ranges: Dictionary = {}    # tile_key → {"start": int, "end": int} in _zones
var _tile_crater_ranges: Dictionary = {}  # tile_key → {"start": int, "end": int} in _crater_*

# ── Compact crater storage ─────────────────────────────────────────────────
## spatial-crater Point features are stored here instead of as heavyweight
## zone Dictionaries (~50 B per crater vs ~3 KB for a 64-vertex polygon zone).
var _crater_lons: PackedFloat32Array = []
var _crater_lats: PackedFloat32Array = []
var _crater_radii: PackedFloat32Array = []        ## metres
var _crater_biome_indices: PackedInt32Array = []

# ── Thread safety for spatial tile lazy-loading ────────────────────────────
# Tile files are loaded lazily from generate_mesh() which runs on
# WorkerThreadPool threads.  ResourceLoader.load() on a worker thread can
# re-enter the pool (executing other queued tasks), causing recursive
# modification of _zones / _crater_* arrays → heap corruption.
# The mutex serialises tile loading across threads; the re-entrance guard
# prevents the same thread from recursing via ResourceLoader.load().
var _mutex := Mutex.new()
var _loading_tiles_tid: int = 0  # OS thread-id currently inside tile-load (re-entrance guard)
var _main_thread_id: int = OS.get_thread_caller_id()


## Load biome zones from a GeoJSON / JSON file.
## Automatically detects and uses spatial tile index if available.
## Returns [code]true[/code] on success.
func load_geojson(path: String) -> bool:
	_zones.clear()
	_loaded = false

	# ── Check for spatial tile index first ──
	var stem := path.substr(0, path.length() - 5) if path.ends_with(".json") else path
	var index_path := "%s_index.json" % stem
	if _file_exists_any(index_path):
		return _load_spatial_index(index_path)

	# Try ResourceLoader first — works in exported builds where .json
	# files are imported as JSON resources bundled inside the PCK.
	var data: Dictionary = {}

	if ResourceLoader.exists(path):
		var res = ResourceLoader.load(path)
		if res is JSON:
			data = res.data
			print("[BiomeQuery] Loaded via ResourceLoader: %s" % path)
		else:
			push_warning("BiomeQuery: ResourceLoader returned %s instead of JSON for %s" % [typeof(res), path])

	# Fallback: read as raw text via FileAccess (works in editor / dev).
	if data.is_empty() and FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_warning("BiomeQuery: cannot open %s (err %d)" % [
				path, FileAccess.get_open_error()])
			return false
		var json_text := file.get_as_text()
		file.close()
		var json := JSON.new()
		var err := json.parse(json_text)
		if err != OK:
			push_warning("BiomeQuery: JSON parse error in %s: %s" % [
				path, json.get_error_message()])
			return false
		data = json.data
		print("[BiomeQuery] Loaded via FileAccess: %s" % path)

	if data.is_empty():
		push_warning("BiomeQuery: could not load %s via ResourceLoader or FileAccess" % path)
		return false
	if not data.has("features"):
		push_warning("BiomeQuery: no 'features' array in %s" % path)
		return false

	_append_features(data["features"])

	# ── Auto-discover split part files (.part2.json, .part3.json, …) ──
	# stem is already computed above for the index check.
	var part_num := 2
	while true:
		var part_path := "%s.part%d.json" % [stem, part_num]
		var part_data := _load_json_file(part_path)
		if part_data.is_empty():
			break
		if part_data.has("features"):
			_append_features(part_data["features"])
			print("[BiomeQuery] Loaded part %d: %s" % [part_num, part_path])
		part_num += 1

	_loaded = true
	print("[BiomeQuery] Loaded %d zone(s) from %s (%d part(s))" % [
		_zones.size(), path, part_num - 1])
	for i in _zones.size():
		var z: Dictionary = _zones[i]
		var fmt := (
			"[BiomeQuery]   zone[%d]: type=%s idx=%d density=%.1f "
			+ "tree=%s depth=%.0f radius=%.1f intensity=%.1f verts=%d bbox=(%.6f,%.6f)→(%.6f,%.6f)"
		)
		print(fmt % [
			i, z.biome_type, z.biome_index, z.density, z.tree_type, z.depth,
			z.radius, z.intensity,
			(z.polygon as PackedVector2Array).size(),
			z.bbox_min.x, z.bbox_min.y, z.bbox_max.x, z.bbox_max.y])
	return true


func _load_json_file(fpath: String) -> Dictionary:
	if ResourceLoader.exists(fpath):
		var res = ResourceLoader.load(fpath)
		if res is JSON:
			return res.data
	if FileAccess.file_exists(fpath):
		var file := FileAccess.open(fpath, FileAccess.READ)
		if file == null:
			return {}
		var json_text := file.get_as_text()
		file.close()
		var json := JSON.new()
		if json.parse(json_text) == OK:
			return json.data
	return {}


## Load a tile JSON file.  On the main thread ResourceLoader is used
## (reliable for exported builds where .json is imported).  On worker
## threads only FileAccess is used to avoid ResourceLoader.load()
## re-entering the WorkerThreadPool and interleaving other tasks.
func _load_tile_json(fpath: String) -> Dictionary:
	if OS.get_thread_caller_id() == _main_thread_id:
		if ResourceLoader.exists(fpath):
			var res = ResourceLoader.load(fpath)
			if res is JSON:
				return res.data
	if FileAccess.file_exists(fpath):
		var file := FileAccess.open(fpath, FileAccess.READ)
		if file == null:
			return {}
		var json_text := file.get_as_text()
		file.close()
		var json := JSON.new()
		if json.parse(json_text) == OK:
			return json.data
	return {}


## Check if a file exists via ResourceLoader or FileAccess.
func _file_exists_any(fpath: String) -> bool:
	return ResourceLoader.exists(fpath) or FileAccess.file_exists(fpath)


## Load the spatial tile index. Only loads the lightweight index JSON —
## tile data is lazy-loaded on demand by [method _ensure_tiles_for_region].
func _load_spatial_index(index_path: String) -> bool:
	var data := _load_json_file(index_path)
	if data.is_empty():
		push_warning("BiomeQuery: could not load spatial index '%s'" % index_path)
		return false

	_spatial_mode = true
	_spatial_index = data
	_tile_deg = float(data.get("tile_deg", 10.0))
	_tile_num_cols = int(data.get("num_cols", 36))
	_tile_num_rows = int(data.get("num_rows", 18))

	# Derive base directory from the index path
	var last_slash := index_path.rfind("/")
	_base_dir = index_path.substr(0, last_slash + 1) if last_slash >= 0 else ""

	_loaded_tiles.clear()
	_known_zone_ids.clear()
	_tile_zone_ranges.clear()
	_tile_crater_ranges.clear()
	_zones.clear()
	_crater_lons.clear()
	_crater_lats.clear()
	_crater_radii.clear()
	_crater_biome_indices.clear()
	_loaded = true

	var tile_count: int = (_spatial_index.get("tiles", {}) as Dictionary).size()
	var total_zones: int = int(data.get("total_zones", 0))
	print("[BiomeQuery] Loaded spatial index: %d tile(s), %d total zone(s) from %s" % [
		tile_count, total_zones, index_path])
	return true


## Convert a longitude/latitude point to its tile key string ("col_row").
func _lonlat_to_tile_key(lon: float, lat: float) -> String:
	var col := int((lon + 180.0) / _tile_deg)
	var row := int((lat + 90.0) / _tile_deg)
	col = clampi(col, 0, _tile_num_cols - 1)
	row = clampi(row, 0, _tile_num_rows - 1)
	return "%d_%d" % [col, row]


## Ensure all tile files overlapping a lon/lat region are loaded.
## Zones are deduplicated by zone_id across tiles.
func _ensure_tiles_for_region(bb_min: Vector2, bb_max: Vector2) -> void:
	if not _spatial_mode:
		return

	# Re-entrance guard: ResourceLoader.load() on worker threads can
	# interleave other WorkerThreadPool tasks, causing this method to be
	# called recursively on the same thread.  Bail out to prevent
	# concurrent modification of _zones / _crater_* packed arrays.
	var tid := OS.get_thread_caller_id()
	if _loading_tiles_tid == tid:
		return

	_mutex.lock()
	_loading_tiles_tid = tid

	var tiles_dict: Dictionary = _spatial_index.get("tiles", {})
	var col_min := int((bb_min.x + 180.0) / _tile_deg)
	var col_max := int((bb_max.x + 180.0) / _tile_deg)
	var row_min := int((bb_min.y + 90.0) / _tile_deg)
	var row_max := int((bb_max.y + 90.0) / _tile_deg)
	col_min = clampi(col_min, 0, _tile_num_cols - 1)
	col_max = clampi(col_max, 0, _tile_num_cols - 1)
	row_min = clampi(row_min, 0, _tile_num_rows - 1)
	row_max = clampi(row_max, 0, _tile_num_rows - 1)

	for col in range(col_min, col_max + 1):
		for row in range(row_min, row_max + 1):
			var tile_key := "%d_%d" % [col, row]
			if _loaded_tiles.has(tile_key):
				continue
			_loaded_tiles[tile_key] = true
			if not tiles_dict.has(tile_key):
				continue
			var tile_info: Dictionary = tiles_dict[tile_key]
			var tile_file: String = tile_info.get("file", "")
			if tile_file.is_empty():
				continue
			var tile_path := _base_dir + tile_file
			var tile_data := _load_tile_json(tile_path)
			if tile_data.is_empty():
				push_warning("BiomeQuery: could not load tile '%s'" % tile_path)
				continue
			var features: Array = tile_data.get("features", [])
			var _zs := _zones.size()
			var _cs := _crater_lons.size()
			_append_features_dedup(features)
			_tile_zone_ranges[tile_key] = {"start": _zs, "end": _zones.size()}
			_tile_crater_ranges[tile_key] = {"start": _cs, "end": _crater_lons.size()}
			print("[BiomeQuery] Loaded tile %s: %s (%d feature(s), %d crater(s))" % [
				tile_key, tile_path, features.size(), _crater_lons.size() - _cs])

	_loading_tiles_tid = 0
	_mutex.unlock()


## Ensure the tile containing a single lon/lat point is loaded.
func _ensure_tile_for_point(lonlat: Vector2) -> void:
	if not _spatial_mode:
		return
	var tile_key := _lonlat_to_tile_key(lonlat.x, lonlat.y)
	if _loaded_tiles.has(tile_key):
		return
	_ensure_tiles_for_region(lonlat, lonlat)


## Append features from a tile, skipping zones already loaded (by zone_id).
func _append_features_dedup(features: Array) -> void:
	for feature in features:
		var props: Dictionary = feature.get("properties", {})
		var zid = props.get("zone_id", -1)
		if zid is float:
			zid = int(zid)
		if zid >= 0 and _known_zone_ids.has(zid):
			continue
		if zid >= 0:
			_known_zone_ids[zid] = true
		_append_single_feature(feature)


func _append_features(features: Array) -> void:
	for feature in features:
		_append_single_feature(feature)


func _append_single_feature(feature: Dictionary) -> void:
	var props: Dictionary = feature.get("properties", {})
	var geom: Dictionary = feature.get("geometry", {})
	var gtype: String = geom.get("type", "")

	# ── Compact crater handling ────────────────────────────────────────────
	# Point features with biome_type "spatial-crater" are stored in flat
	# PackedFloat32Arrays instead of heavyweight zone Dictionaries.
	if gtype == "Point":
		if str(props.get("biome_type", "")) == "spatial-crater":
			var pt_coords: Array = geom.get("coordinates", [])
			if pt_coords.size() >= 2:
				_crater_lons.append(float(pt_coords[0]))
				_crater_lats.append(float(pt_coords[1]))
				var r = props.get("radius")
				_crater_radii.append(float(r) if r != null else 0.0)
				var bi = props.get("biome_index")
				_crater_biome_indices.append(int(bi) if bi != null else SpatialCraterTerrain.BIOME_INDEX)
		return

	if gtype != "Polygon":
		return

	var coords: Array = geom.get("coordinates", [])
	if coords.is_empty():
		return

	var ring: Array = coords[0]

	var polygon := PackedVector2Array()
	polygon.resize(ring.size())
	var bb_min := Vector2(INF, INF)
	var bb_max := Vector2(-INF, -INF)
	for i in ring.size():
		var pt := Vector2(ring[i][0], ring[i][1])
		polygon[i] = pt
		bb_min.x = minf(bb_min.x, pt.x)
		bb_min.y = minf(bb_min.y, pt.y)
		bb_max.x = maxf(bb_max.x, pt.x)
		bb_max.y = maxf(bb_max.y, pt.y)

	# ── Polygon craters: derive compact crater from centroid + radius ──
	# When spatial-crater features are exported as buffered Polygons instead
	# of compact Points, also populate the _crater_* packed arrays so that
	# query_craters_at_lonlat() / bbox_overlaps_craters() work correctly.
	if str(props.get("biome_type", "")) == "spatial-crater":
		var r = props.get("radius")
		if r != null and float(r) > 0.0:
			var cx := (bb_min.x + bb_max.x) * 0.5
			var cy := (bb_min.y + bb_max.y) * 0.5
			_crater_lons.append(cx)
			_crater_lats.append(cy)
			_crater_radii.append(float(r))
			var bi = props.get("biome_index")
			_crater_biome_indices.append(int(bi) if bi != null else SpatialCraterTerrain.BIOME_INDEX)

	var _btype = props.get("biome_type", "")
	var _density = props.get("density", 1.0)
	var _ttype = props.get("tree_type", "")
	var _bidx = props.get("biome_index", -1)
	var _depth = props.get("depth", 0.0)
	var _width = props.get("width", 0.0)
	var _width_start = props.get("width_start", 0.0)
	var _width_end = props.get("width_end", 0.0)
	var _radius = props.get("radius", 0.0)
	var _intensity = props.get("intensity", 0.0)
	var _wave = props.get("wave_intensity", 0.0)
	var _canopy = props.get("canopy_height", 0.0)
	var _under = props.get("undergrowth", "")
	var _flow = props.get("flow_direction", "")
	var _color_hex = props.get("color_hex", "")
	var _road_type = props.get("road_type", "")
	var _surface = props.get("surface", "")
	var _road_name = props.get("name", "")
	var _lanes = props.get("lanes", 0)
	var _centerline_raw = props.get("centerline", [])
	var _centerline := PackedVector2Array()
	if _centerline_raw is Array and not (_centerline_raw as Array).is_empty():
		for pt in _centerline_raw:
			if pt is Array and (pt as Array).size() >= 2:
				_centerline.append(Vector2(pt[0], pt[1]))
	var _eff_ws := float(_width_start) if _width_start != null else 0.0
	var _eff_we := float(_width_end) if _width_end != null else 0.0
	var _eff_w := float(_width) if _width != null else 0.0
	if _eff_w <= 0.0 and (_eff_ws > 0.0 or _eff_we > 0.0):
		_eff_w = maxf(_eff_ws, _eff_we)
	var zone := {
		"biome_type": str(_btype) if _btype != null else "",
		"density": float(_density) if _density != null else 1.0,
		"tree_type": str(_ttype) if _ttype != null else "",
		"biome_index": int(_bidx) if _bidx != null else -1,
		"depth": float(_depth) if _depth != null else 0.0,
		"width": _eff_w,
		"width_start": _eff_ws,
		"width_end": _eff_we,
		"radius": float(_radius) if _radius != null else 0.0,
		"intensity": float(_intensity) if _intensity != null else 0.0,
		"wave_intensity": float(_wave) if _wave != null else 0.0,
		"canopy_height": float(_canopy) if _canopy != null else 0.0,
		"undergrowth": str(_under) if _under != null else "",
		"flow_direction": str(_flow) if _flow != null else "",
		"color_hex": str(_color_hex) if _color_hex != null else "",
		"road_type": str(_road_type) if _road_type != null else "",
		"surface": str(_surface) if _surface != null else "",
		"road_name": str(_road_name) if _road_name != null else "",
		"lanes": int(_lanes) if _lanes != null else 0,
		"centerline": _centerline,
		"half_width_deg": _eff_w / 2.0 if _eff_w > 0.0 else 0.0,
		"polygon": polygon,
		"bbox_min": bb_min,
		"bbox_max": bb_max,
	}
	_zones.append(zone)


## Whether at least one zone has been loaded.
func is_loaded() -> bool:
	return _loaded


## Return the number of loaded polygon zones.
func zone_count() -> int:
	return _zones.size()


## Return the number of compact crater entries loaded.
func crater_count() -> int:
	return _crater_lons.size()


## Return crater array indices from tiles overlapping the given lon/lat region.
## In non-spatial mode returns all indices.  Used internally by crater queries.
func _crater_indices_for_region(bb_min: Vector2, bb_max: Vector2) -> PackedInt32Array:
	if not _spatial_mode:
		var all := PackedInt32Array()
		all.resize(_crater_lons.size())
		for i in _crater_lons.size():
			all[i] = i
		return all
	var result := PackedInt32Array()
	var col_min := int((bb_min.x + 180.0) / _tile_deg)
	var col_max := int((bb_max.x + 180.0) / _tile_deg)
	var row_min := int((bb_min.y + 90.0) / _tile_deg)
	var row_max := int((bb_max.y + 90.0) / _tile_deg)
	col_min = clampi(col_min, 0, _tile_num_cols - 1)
	col_max = clampi(col_max, 0, _tile_num_cols - 1)
	row_min = clampi(row_min, 0, _tile_num_rows - 1)
	row_max = clampi(row_max, 0, _tile_num_rows - 1)
	for col in range(col_min, col_max + 1):
		for row in range(row_min, row_max + 1):
			var tk := "%d_%d" % [col, row]
			if _tile_crater_ranges.has(tk):
				var rng: Dictionary = _tile_crater_ranges[tk]
				for i in range(rng["start"], rng["end"]):
					result.append(i)
	return result


## Return [code]true[/code] if any compact crater circle overlaps [param bb_min]/[param bb_max].
## The test expands each crater by [constant SpatialCraterTerrain.RIM_OUTER_MULT] so rim uplift
## areas are not missed.  Call after [method preload_region] to ensure tiles are loaded.
## [param m_per_deg] = planet_radius × PI / 180.0
func bbox_overlaps_craters(bb_min: Vector2, bb_max: Vector2, m_per_deg: float) -> bool:
	var rim_mult := SpatialCraterTerrain.RIM_OUTER_MULT
	var indices := _crater_indices_for_region(bb_min, bb_max)
	for i in indices:
		var r_deg := _crater_radii[i] * rim_mult / m_per_deg
		if _crater_lons[i] + r_deg >= bb_min.x and _crater_lons[i] - r_deg <= bb_max.x \
				and _crater_lats[i] + r_deg >= bb_min.y and _crater_lats[i] - r_deg <= bb_max.y:
			return true
	return false


## Return compact craters whose outer rim overlaps the given region.
## Pre-query this ONCE per chunk before the vertex loop, then iterate the
## returned array per-vertex with your own distance check.
## Each returned Dictionary: { lon, lat, radius_m, biome_index }.
## [param m_per_deg] = planet_radius × PI / 180.0
func get_craters_for_region(bb_min: Vector2, bb_max: Vector2, m_per_deg: float) -> Array:
	_ensure_tiles_for_region(bb_min, bb_max)
	var rim_mult := SpatialCraterTerrain.RIM_OUTER_MULT
	var results := []
	_mutex.lock()
	var indices := _crater_indices_for_region(bb_min, bb_max)
	for i in indices:
		var r_deg := _crater_radii[i] * rim_mult / m_per_deg
		if _crater_lons[i] + r_deg >= bb_min.x and _crater_lons[i] - r_deg <= bb_max.x \
				and _crater_lats[i] + r_deg >= bb_min.y and _crater_lats[i] - r_deg <= bb_max.y:
			results.append({
				"lon": float(_crater_lons[i]),
				"lat": float(_crater_lats[i]),
				"radius_m": float(_crater_radii[i]),
				"biome_index": int(_crater_biome_indices[i]),
			})
	_mutex.unlock()
	return results


## Return compact craters whose outer rim includes [param lonlat].
## Assumes the relevant tile is already loaded (call after [method preload_region]).
## Each returned Dictionary: { lon, lat, radius_m, biome_index, dist_m }.
## [param m_per_deg] = planet_radius × PI / 180.0
func query_craters_at_lonlat(lonlat: Vector2, m_per_deg: float) -> Array:
	var cos_lat := cos(deg_to_rad(lonlat.y))
	var results := []
	var rim_mult := SpatialCraterTerrain.RIM_OUTER_MULT
	var indices := _crater_indices_for_region(lonlat, lonlat)
	for i in indices:
		var dx := (lonlat.x - _crater_lons[i]) * cos_lat * m_per_deg
		var dy := (lonlat.y - _crater_lats[i]) * m_per_deg
		var dist_m := sqrt(dx * dx + dy * dy)
		if dist_m < _crater_radii[i] * rim_mult:
			results.append({
				"lon": float(_crater_lons[i]),
				"lat": float(_crater_lats[i]),
				"radius_m": float(_crater_radii[i]),
				"biome_index": int(_crater_biome_indices[i]),
				"dist_m": dist_m,
			})
	return results


## Return the full array of loaded zones (read-only access).
## In spatial mode, only returns zones from tiles loaded so far.
## Call [method preload_region] first to ensure relevant tiles are loaded.
func get_all_zones() -> Array[Dictionary]:
	if not _spatial_mode:
		return _zones
	# Return a snapshot so callers can iterate safely while other threads
	# may still load new tiles (which appends to the internal _zones).
	_mutex.lock()
	var snapshot: Array[Dictionary] = []
	snapshot.assign(_zones)
	_mutex.unlock()
	return snapshot


## Return only zones from tiles overlapping the given lon/lat bounding box.
## Much faster than [method get_all_zones] when the planet has many tiles.
func get_zones_for_region(bb_min: Vector2, bb_max: Vector2) -> Array[Dictionary]:
	if not _spatial_mode:
		return _zones
	_ensure_tiles_for_region(bb_min, bb_max)
	_mutex.lock()
	var result: Array[Dictionary] = []
	var col_min := int((bb_min.x + 180.0) / _tile_deg)
	var col_max := int((bb_max.x + 180.0) / _tile_deg)
	var row_min := int((bb_min.y + 90.0) / _tile_deg)
	var row_max := int((bb_max.y + 90.0) / _tile_deg)
	col_min = clampi(col_min, 0, _tile_num_cols - 1)
	col_max = clampi(col_max, 0, _tile_num_cols - 1)
	row_min = clampi(row_min, 0, _tile_num_rows - 1)
	row_max = clampi(row_max, 0, _tile_num_rows - 1)
	for col in range(col_min, col_max + 1):
		for row in range(row_min, row_max + 1):
			var tk := "%d_%d" % [col, row]
			if _tile_zone_ranges.has(tk):
				var rng: Dictionary = _tile_zone_ranges[tk]
				for i in range(rng["start"], rng["end"]):
					result.append(_zones[i])
	_mutex.unlock()
	return result


## Return zones from the tile(s) covering a single lon/lat point.
func _zones_for_point(lonlat: Vector2) -> Array[Dictionary]:
	if not _spatial_mode:
		return _zones
	var tk := _lonlat_to_tile_key(lonlat.x, lonlat.y)
	_mutex.lock()
	var result: Array[Dictionary] = []
	if _tile_zone_ranges.has(tk):
		var rng: Dictionary = _tile_zone_ranges[tk]
		for i in range(rng["start"], rng["end"]):
			result.append(_zones[i])
	_mutex.unlock()
	return result


## Ensure all tiles overlapping a lon/lat bounding box are loaded.
## Call this before [method get_all_zones] when you need zones for a
## specific area (e.g. a chunk's bounding box).  No-op in legacy mode.
func preload_region(bb_min: Vector2, bb_max: Vector2) -> void:
	_ensure_tiles_for_region(bb_min, bb_max)


## Return all unique biome_index values across the dataset.
## In spatial mode, reads from the index without loading tiles.
## In legacy mode, extracts from loaded zones.
func get_all_biome_indices() -> Array[int]:
	if _spatial_mode and _spatial_index.has("biome_indices"):
		var raw: Array = _spatial_index["biome_indices"]
		var result: Array[int] = []
		for v in raw:
			result.append(int(v))
		return result
	var seen: Dictionary = {}
	var result: Array[int] = []
	for zone in _zones:
		var idx: int = zone.biome_index
		if not seen.has(idx):
			seen[idx] = true
			result.append(idx)
	return result


## Query all zones that contain the given sphere direction.
## Returns an Array of zone dictionaries (may be empty).
func query_at_direction(dir: Vector3) -> Array[Dictionary]:
	if not _loaded:
		return []

	var lonlat := _dir_to_lonlat(dir)
	_ensure_tile_for_point(lonlat)
	var results: Array[Dictionary] = []
	var candidates := _zones_for_point(lonlat) if _spatial_mode else _zones
	for zone in candidates:
		if zone == null:
			continue
		if _bbox_contains(zone, lonlat) and _point_in_polygon(lonlat, zone.polygon):
			results.append(zone)
	return results


## Check if [param dir] is inside any zone whose [code]biome_type[/code]
## matches [param biome_type].  Returns the first matching zone Dictionary,
## or an empty Dictionary if none match.
func query_biome_type(dir: Vector3, biome_type: String) -> Dictionary:
	if not _loaded:
		return {}

	var lonlat := _dir_to_lonlat(dir)
	_ensure_tile_for_point(lonlat)
	var candidates := _zones_for_point(lonlat) if _spatial_mode else _zones
	for zone in candidates:
		if zone == null:
			continue
		if zone.biome_type == biome_type \
				and _bbox_contains(zone, lonlat) \
				and _point_in_polygon(lonlat, zone.polygon):
			return zone
	return {}


## Fast chunk-level test: does the chunk's lon/lat bounding box overlap
## the AABB of at least one zone with the given [param biome_type]?
## [param face], [param u_min] .. [param v_max] define the chunk's
## cube-face UV bounds.  Returns [code]true[/code] if at least one zone
## AABB intersects the chunk's conservative lon/lat AABB.
func chunk_overlaps_biome(face: int, u_min: float, u_max: float,
		v_min: float, v_max: float, biome_type: String) -> bool:
	if not _loaded:
		return false
	var cbb := _chunk_lonlat_bbox(face, u_min, u_max, v_min, v_max)
	var candidates := get_zones_for_region(cbb[0], cbb[1]) if _spatial_mode else _zones
	for zone in candidates:
		if zone == null:
			continue
		if zone.biome_type == biome_type \
				and _aabb_overlap(cbb[0], cbb[1], zone.bbox_min, zone.bbox_max):
			return true
	return false


## HEALPix variant: does the pixel overlap any zone with the given biome_type?
func chunk_overlaps_biome_hp(nside: int, ipix: int, biome_type: String) -> bool:
	if not _loaded:
		return false
	var cbb := _healpix_lonlat_bbox(nside, ipix)
	var candidates := get_zones_for_region(cbb[0], cbb[1]) if _spatial_mode else _zones
	for zone in candidates:
		if zone == null:
			continue
		if zone.biome_type == biome_type \
				and _aabb_overlap(cbb[0], cbb[1], zone.bbox_min, zone.bbox_max):
			return true
	return false


## Fast chunk-level test: does the chunk's lon/lat bounding box overlap
## the AABB of *any* loaded zone?  Useful to skip the entire vegetation
## scatter call for chunks that are far from all biome zones.
func chunk_overlaps_any_zone(face: int, u_min: float, u_max: float,
		v_min: float, v_max: float) -> bool:
	if not _loaded:
		return false
	var cbb := _chunk_lonlat_bbox(face, u_min, u_max, v_min, v_max)
	var candidates := get_zones_for_region(cbb[0], cbb[1]) if _spatial_mode else _zones
	for zone in candidates:
		if zone == null:
			continue
		if _aabb_overlap(cbb[0], cbb[1], zone.bbox_min, zone.bbox_max):
			return true
	return false


## HEALPix variant: does the pixel overlap any loaded zone?
func chunk_overlaps_any_zone_hp(nside: int, ipix: int) -> bool:
	if not _loaded:
		return false
	var cbb := _healpix_lonlat_bbox(nside, ipix)
	var candidates := get_zones_for_region(cbb[0], cbb[1]) if _spatial_mode else _zones
	for zone in candidates:
		if zone == null:
			continue
		if _aabb_overlap(cbb[0], cbb[1], zone.bbox_min, zone.bbox_max):
			return true
	return false


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## Build a conservative lon/lat AABB for a terrain chunk by sampling its
## 4 corners plus 4 edge midpoints and the centre (9 points).  This
## handles the nonlinear cube-to-sphere projection without missing
## extrema along curved edges.
static func _chunk_lonlat_bbox(face: int, u_min: float, u_max: float,
		v_min: float, v_max: float) -> Array[Vector2]:
	var u_mid := (u_min + u_max) * 0.5
	var v_mid := (v_min + v_max) * 0.5
	var bb_min := Vector2(INF, INF)
	var bb_max := Vector2(-INF, -INF)
	# Sample 9 points: 4 corners + 4 edge midpoints + centre.
	var samples := [
		Vector2(u_min, v_min), Vector2(u_max, v_min),
		Vector2(u_min, v_max), Vector2(u_max, v_max),
		Vector2(u_mid, v_min), Vector2(u_mid, v_max),
		Vector2(u_min, v_mid), Vector2(u_max, v_mid),
		Vector2(u_mid, v_mid),
	]
	for s in samples:
		var dir := PlanetData.cube_to_sphere(face, s.x, s.y)
		var ll := _dir_to_lonlat(dir)
		bb_min.x = minf(bb_min.x, ll.x)
		bb_min.y = minf(bb_min.y, ll.y)
		bb_max.x = maxf(bb_max.x, ll.x)
		bb_max.y = maxf(bb_max.y, ll.y)
	return [bb_min, bb_max]


## Build a conservative lon/lat AABB for a HEALPix pixel using corners,
## edge midpoints, and pixel center (9 samples).
static func _healpix_lonlat_bbox(nside: int, ipix: int) -> Array[Vector2]:
	var corners: Array = HEALPix.get_pixel_corners(nside, ipix)
	var center_dir := HEALPix.pix2vec_nest(nside, ipix)
	var bb_min := Vector2(INF, INF)
	var bb_max := Vector2(-INF, -INF)
	for ci in corners.size():
		var ll := _dir_to_lonlat(corners[ci])
		bb_min.x = minf(bb_min.x, ll.x)
		bb_min.y = minf(bb_min.y, ll.y)
		bb_max.x = maxf(bb_max.x, ll.x)
		bb_max.y = maxf(bb_max.y, ll.y)
		# Edge midpoint to next corner.
		var next := (ci + 1) % corners.size()
		var mid: Vector3 = (corners[ci] + corners[next]).normalized()
		var mll := _dir_to_lonlat(mid)
		bb_min.x = minf(bb_min.x, mll.x)
		bb_min.y = minf(bb_min.y, mll.y)
		bb_max.x = maxf(bb_max.x, mll.x)
		bb_max.y = maxf(bb_max.y, mll.y)
	var cll := _dir_to_lonlat(center_dir)
	bb_min.x = minf(bb_min.x, cll.x)
	bb_min.y = minf(bb_min.y, cll.y)
	bb_max.x = maxf(bb_max.x, cll.x)
	bb_max.y = maxf(bb_max.y, cll.y)
	return [bb_min, bb_max]


## 2-D axis-aligned bounding box overlap test.
static func _aabb_overlap(a_min: Vector2, a_max: Vector2,
		b_min: Vector2, b_max: Vector2) -> bool:
	return a_min.x <= b_max.x and a_max.x >= b_min.x \
		and a_min.y <= b_max.y and a_max.y >= b_min.y


## Convert a unit sphere direction to Vector2(longitude°, latitude°).
## Matches the PlanetData EPSG:4326 convention.
static func _dir_to_lonlat(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var lon := rad_to_deg(atan2(d.z, d.x))
	var lat := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	return Vector2(lon, lat)


## Fast bounding-box pre-check.
static func _bbox_contains(zone: Dictionary, point: Vector2) -> bool:
	return point.x >= zone.bbox_min.x and point.x <= zone.bbox_max.x \
		and point.y >= zone.bbox_min.y and point.y <= zone.bbox_max.y


## Ray-casting point-in-polygon test (2-D, works in lon/lat space).
static func _point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var n := polygon.size()
	if n < 3:
		return false

	var inside := false
	var j := n - 1
	for i in n:
		var pi := polygon[i]
		var pj := polygon[j]
		if ((pi.y > point.y) != (pj.y > point.y)) and \
				(point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside


## Compute the cross-section factor for a point within a linear zone (river,
## canyon).  Returns a Dictionary { "t": float, "along_t": float } where:
##   t       = 0.0 at the centerline, 1.0 at the edges
##   along_t = 0.0 at the start of the centerline, 1.0 at the end
## If the zone has no centerline data, returns { "t": 0.5, "along_t": 0.0 }.
## For rivers with progressive width, the half-width is interpolated along
## the centerline using along_t.
static func get_cross_section_t(zone: Dictionary, lonlat: Vector2) -> Dictionary:
	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	if cl.size() < 2:
		return { "t": 0.5, "along_t": 0.0 }

	var cum_lengths: PackedFloat64Array = zone.get("_cum_lengths", PackedFloat64Array())
	var total_length: float = zone.get("_total_length", 0.0)

	# Find nearest segment, perpendicular distance, and projection.
	var min_dist := INF
	var best_along_m := 0.0
	for i in cl.size() - 1:
		var a := cl[i]
		var b := cl[i + 1]
		var ab := b - a
		var ap := lonlat - a
		var ab_sq := ab.dot(ab)
		var proj_t := 0.0
		if ab_sq > 1e-20:
			proj_t = clampf(ap.dot(ab) / ab_sq, 0.0, 1.0)
		var closest := a + ab * proj_t
		var d := (lonlat - closest).length()
		if d < min_dist:
			min_dist = d
			var seg_start: float = cum_lengths[i] if i < cum_lengths.size() else 0.0
			var seg_end: float = cum_lengths[i + 1] if (i + 1) < cum_lengths.size() else total_length
			best_along_m = seg_start + proj_t * (seg_end - seg_start)

	var along_t := 0.0
	if total_length > 0.0:
		along_t = clampf(best_along_m / total_length, 0.0, 1.0)

	# Interpolate half-width at this position along the centerline.
	var hw_start: float = zone.get("half_width_start_deg", 0.0)
	var hw_end: float = zone.get("half_width_end_deg", 0.0)
	var hw: float
	if hw_start > 0.0 or hw_end > 0.0:
		hw = lerpf(hw_start, hw_end, along_t)
	else:
		# Legacy fallback: single half_width_deg or width field.
		hw = zone.get("half_width_deg", 0.0)
		if hw <= 0.0:
			hw = zone.get("width", 0.01) / 2.0

	if hw <= 0.0 or min_dist >= hw:
		return { "t": 1.0, "along_t": along_t }
	return { "t": clampf(min_dist / hw, 0.0, 1.0), "along_t": along_t }


## Compute the flow direction vector (in lon/lat space) at a point along
## the centerline.  Returns the tangent direction of the nearest segment.
## If flow_direction is "reverse", the vector is negated.
## Returns Vector2.ZERO for "none" or "static", or if no centerline exists.
static func get_flow_vector(zone: Dictionary, lonlat: Vector2) -> Vector2:
	var fd: String = zone.get("flow_direction", "none")
	if fd == "none":
		return Vector2.ZERO

	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	if cl.size() < 2:
		return Vector2.ZERO

	# Find nearest segment and its tangent.
	var min_dist := INF
	var best_tangent := Vector2.ZERO
	for i in cl.size() - 1:
		var d := _point_to_segment_dist(lonlat, cl[i], cl[i + 1])
		if d < min_dist:
			min_dist = d
			best_tangent = (cl[i + 1] - cl[i]).normalized()

	if fd == "reverse":
		best_tangent = -best_tangent
	elif fd == "static":
		return Vector2.ZERO
	# "forward" and "bidirectional" both use the tangent as-is.
	# (bidirectional handled at shader level with oscillation.)
	return best_tangent


## Compute flow-aligned coordinates for a point relative to a linear zone's
## centerline.  Returns Vector2(along_flow_m, across_flow_m) where:
##   along_flow_m = cumulative distance along the centerline to the nearest
##                  projection point (in metres).
##   across_flow_m = signed perpendicular distance from the centerline
##                   (in metres); positive = right of flow direction.
## [param m_per_deg] = planet_radius * PI / 180.
static func get_flow_aligned_coords(zone: Dictionary, lonlat: Vector2, m_per_deg: float) -> Vector2:
	var cl: PackedVector2Array = zone.get("centerline", PackedVector2Array())
	if cl.size() < 2:
		return Vector2.ZERO

	# Find the nearest centerline segment, its projection parameter,
	# and the cumulative distance up to that segment.
	var min_dist := INF
	var best_seg := 0
	var best_t := 0.0
	for i in cl.size() - 1:
		var ab := cl[i + 1] - cl[i]
		var len_sq := ab.length_squared()
		var t := 0.0
		if len_sq > 1e-12:
			t = clampf((lonlat - cl[i]).dot(ab) / len_sq, 0.0, 1.0)
		var proj := cl[i] + ab * t
		var d := (lonlat - proj).length()
		if d < min_dist:
			min_dist = d
			best_seg = i
			best_t = t

	# Along-flow: cumulative length of all segments before best_seg,
	# plus best_t fraction of the best segment.
	var along_deg := 0.0
	for i in best_seg:
		along_deg += (cl[i + 1] - cl[i]).length()
	along_deg += best_t * (cl[best_seg + 1] - cl[best_seg]).length()
	var along_m := along_deg * m_per_deg

	# Across-flow: signed perpendicular distance.
	# Sign is determined by the cross product of the segment direction
	# and the vector from the segment start to the point.
	var seg_dir := cl[best_seg + 1] - cl[best_seg]
	var to_point := lonlat - cl[best_seg]
	var cross := seg_dir.x * to_point.y - seg_dir.y * to_point.x
	var sign_f := 1.0 if cross >= 0.0 else -1.0
	var across_m := min_dist * m_per_deg * sign_f

	return Vector2(along_m, across_m)


## Minimum distance from a point inside a polygon to its nearest edge.
## Returns the distance in the same units as the polygon coordinates (degrees).
## If the polygon has fewer than 3 vertices, returns 0.
static func _dist_to_polygon_edge(point: Vector2, polygon: PackedVector2Array) -> float:
	var n := polygon.size()
	if n < 3:
		return 0.0
	var min_d := INF
	var j := n - 1
	for i in n:
		var d := _point_to_segment_dist(point, polygon[i], polygon[j])
		if d < min_d:
			min_d = d
		j = i
	return min_d


## Minimum distance from point [param p] to line segment [param a]→[param b].
static func _point_to_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 1e-12:
		return (p - a).length()
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	var proj := a + ab * t
	return (p - proj).length()
