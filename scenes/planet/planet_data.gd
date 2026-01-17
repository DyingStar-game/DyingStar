@tool
class_name PlanetData
extends Resource
# gdlint: disable=class-definitions-order
## Planet configuration resource.
## Stores radius, textures, LOD distances, and provides coordinate conversion
## between sphere surface and equirectangular UV (matching QGIS EPSG:4326).

const PlanetPackScript = preload("res://scenes/planet/planet_pack.gd")

@export_group("General")
## for example "tarsis_3" correspond to the QGIS file name
@export var planet_name: String = ""
## Radius in meters (distance from center to sea-level surface).
var radius: float = 1000.0
## Maximum terrain elevation above sea-level radius, in meters.
var max_height: float = 1000.0
## Elevation offset in meters (negative when craters dig below sea-level).
var height_offset: float = 0.0
## Atmosphere shell thickness in meters (0 = no atmosphere).
@export var atmosphere_height: float = 0.0
## Surface gravity in m/s² (Earth = 9.8).
@export var surface_gravity: float = 9.8
## Radius of the gravity influence zone above the surface, in meters.
## Independent of atmosphere: a moon with no atmosphere still has gravity here.
## Default 100 000 m (100 km). Gravity falls off with inverse-square law beyond the surface.
@export var gravity_reach: float = 100000.0

## Optional path to the planet JSON file exported from QGIS
## (e.g. "assets/qgis/export/tarsis_4/planet.json").
## When set, load_from_planet_json() is called automatically on _ready
## and overwrites radius, max_height, chunk_export_depth, etc.
var planet_json: String = str("assets/qgis/export/", planet_name, "/planet.json")

@export_group("Water")
@export var has_ocean: bool = false
## Water surface elevation relative to sea-level radius, in meters.
@export var water_level: float = 0.0

@export_group("Textures")
## Depth at which the chunk heightmaps were exported (matches export_depth
## in the QGIS chunk_manifest.json).  Chunks at runtime are mapped back to
## the nearest exported ancestor chunk.
@export var chunk_export_depth: int = 5:
	set(value):
		chunk_export_depth = value
		export_nside = 1 << value
## HEALPix export N_side parameter. Derived from chunk_export_depth: nside = 2^depth.
## Total export tiles = 12 × nside².
var export_nside: int = 32
## Equirectangular heightmap — kept as fallback only (editor preview, etc.).
@export var heightmap: Texture2D
## Equirectangular biome map — colour encodes biome type / vegetation.
@export var biomemap: Texture2D
## Small equirectangular colour map used for ultra-far LOD sphere.
@export var colormap: Texture2D

@export_group("LOD Distances")
## Distance thresholds from the planet surface (in meters) for each LOD tier.
@export var lod0_distance: float = 5000.0
@export var lod1_distance: float = 50000.0
@export var lod2_distance: float = 200000.0
@export var lod3_distance: float = 2000000.0
@export var lod4_distance: float = 500000000.0

@export_group("Terrain")
## Material applied to every terrain chunk mesh.  If not set, a default
## material using vertex colours as albedo is created automatically.
@export var terrain_material: Material
## Number of vertices per chunk edge at LOD 0 (finest detail).
@export var chunk_resolution: int = 32
## Maximum quadtree subdivision depth. Higher = smaller finest chunks.
@export var max_quadtree_depth: int = 14

@export_group("Roads")
## Path to a GeoJSON file with road polygons (buffered from LineStrings).
## Exported by the QGIS pipeline as {planet}_roads_buffered.json.
## When provided, road overlays are rendered on terrain chunks.
## Path is relative to res://, e.g. "assets/qgis/.export/tarsis_4_roads_buffered.json".
@export var roads_geojson: String = ""

## When true, crater profiles are already baked into chunk heightmaps
## by the QGIS export pipeline — skip runtime crater displacement.
var craters_baked: bool = false

## Per-planet biome overrides.  Any BiomeDefinition listed here takes
## priority over the auto-loaded defaults from res://scenes/planet/biomes/.
## Leave empty to use the shared set as-is.
var biome_definitions: Array[BiomeDefinition] = []

## Rules that map biome colours to vegetation meshes.
## Empty array = no vegetation on this planet.
var vegetation_rules: Array[VegetationRule] = []
## Path to a GeoJSON file with biome polygons (exported from QGIS).
## When provided, vegetation rules can match by biome_type against polygon
## zones instead of — or in addition to — sampling the biomemap colour.
## Path is relative to res://, e.g. "assets/qgis/export/tarsis_4/biomes.geojson".
var biomes_geojson: String = str("assets/qgis/export/", planet_name, "/biomes.json")

# ---------------------------------------------------------------------------
# Cached CPU-side images for height / biome sampling
# ---------------------------------------------------------------------------
var _heightmap_image: Image = null
var _biomemap_image: Image = null
var _biome_query = null  # BiomeQuery (null = not tried, false = tried & failed)
var _biome_query_tried: bool = false

## Road query — separate BiomeQuery for road polygons.
var _road_query = null   # BiomeQuery for roads_geojson
var _road_query_tried: bool = false

## Cache of loaded road materials: path → Material.
var _road_material_cache: Dictionary = {}

## Cache of loaded chunk heightmap images.  Key = "hp_nN_pP" → Image.
var _chunk_images: Dictionary = {}
var _empty_chunk_logged: bool = false
var _chunk_format_logged: bool = false

## ── Planet pack (runtime data source) ────────────────────────────
## All per-tile recipe binaries + chunk manifest are packed into a single
## .planetpack file per planet, produced by tools/qgis/pack_planet.py.
## Recipes are loaded exclusively from the pack at runtime — the old
## loose-file layout under assets/qgis/.export/ is no longer read.
var _pack = null  # PlanetPackScript instance
var _pack_tried: bool = false
var _pack_open_mutex: Mutex = Mutex.new()

## Cached safety-net collision faces (triangle vertex array). Built once on
## first call to load_safety_mesh_faces(). See _server_load_prebaked_collision
## in PlanetTerrain — this is the always-resident backstop mesh used when a
## body sits over a chunk that isn't loaded.
var _safety_mesh_faces: PackedVector3Array = PackedVector3Array()
var _safety_mesh_tried: bool = false

## Cache of crater data extracted from recipes.  Key = "hp_nN_pP" → Array.
## Each entry is a Dictionary with keys: lon, lat, radius_m, depth_m.
var _chunk_craters: Dictionary = {}

## Cache of populate zone data from v7+ recipes.  Key = "hp_nN_pP" → Array.
## Each zone is a Dictionary with keys: biome_type, coverage, vertices, etc.
var _chunk_populate_zones: Dictionary = {}

## Cache of linear feature data from recipes.  Key = "hp_nN_pP" → Array.
## Each entry has: type, centerline, width_start_m, width_end_m, profile, etc.
var _chunk_linear_features: Dictionary = {}

## Cache of radial feature data from recipes.  Key = "hp_nN_pP" → Array.
## Each entry has: type, lon, lat, radius_m, depth_m, profile.
var _chunk_radial_features: Dictionary = {}

## ── Recipe-based terrain generation ──────────────────────────────
## Pixel resolution per edge for recipe-generated heightmaps.
var _recipe_resolution: int = 256
## LRU eviction tracking: ordered list of chunk keys (oldest first).
var _cache_order: Array[String] = []
## Current total cache size in bytes (for LRU eviction budget).
var _cache_bytes: int = 0
## Maximum cache budget in bytes.  1024 MB for client.
const MAX_CACHE_BYTES: int = 1024 * 1024 * 1024
## When true, never evict cached chunks (server keeps everything).
var _server_no_evict: bool = false
## When true, skip loading 8 neighbor recipes to merge craters in
## _load_recipe_heightmap.  Set when the planet has no craters at all.
var skip_neighbor_crater_merge: bool = false
## Mutex protecting _chunk_images, _cache_order, and _cache_bytes so that
## mesh generation (WorkerThreadPool tasks) can safely read the image cache
## at the same time the main thread stores new recipe results.
var _cache_mutex: Mutex = Mutex.new()


func _get_heightmap_image() -> Image:
	if _heightmap_image == null and heightmap:
		_heightmap_image = heightmap.get_image()
	return _heightmap_image


## Enable server mode: keep all generated chunks in cache (no eviction).
func set_server_mode(enabled: bool) -> void:
	_server_no_evict = enabled


## DEPRECATED: No runtime code calls this any more.  Biome queries are now
## served from populate_zones in the v7 recipe.  Kept only for the
## has_ocean auto-detect side-effect and potential future road-adjacent use.
func _get_biome_query():
	if _biome_query == null and not _biome_query_tried and not biomes_geojson.is_empty():
		_biome_query_tried = true
		# Reconstruct path from planet_name if the default initializer produced
		# a broken path (planet_name was still "" when the var was evaluated).
		if biomes_geojson.ends_with("/_biomes.json") and not planet_name.is_empty():
			biomes_geojson = "assets/qgis/export/%s/biomes.json" % planet_name
		var bq = BiomeQuery.new()
		var path := "res://" + biomes_geojson if not biomes_geojson.begins_with("res://") else biomes_geojson
		if bq.load_geojson(path):
			_biome_query = bq
			# Auto-detect has_ocean from biome indices (works without loading tiles).
			if not has_ocean:
				for bi in bq.get_all_biome_indices():
					var bd := get_biome_by_index(bi)
					if bd and bd.is_liquid:
						has_ocean = true
						print("PlanetData: auto-set has_ocean=true (found liquid biome '%s')" % bd.biome_type)
						break
		else:
			push_warning("PlanetData: failed to load biome geojson '%s'" % path)
	return _biome_query


## Return the BiomeQuery for road polygons, lazily loaded from roads_geojson.
func get_road_query():
	if _road_query == null and not _road_query_tried and not roads_geojson.is_empty():
		_road_query_tried = true
		var rq = BiomeQuery.new()
		var path := "res://" + roads_geojson if not roads_geojson.begins_with("res://") else roads_geojson
		if rq.load_geojson(path):
			_road_query = rq
			print("PlanetData: loaded road query with %d zone(s)" % rq.zone_count())
		else:
			push_warning("PlanetData: failed to load roads geojson '%s'" % path)
	return _road_query


func get_biomemap_image() -> Image:
	if _biomemap_image == null and biomemap:
		_biomemap_image = biomemap.get_image()
		if _biomemap_image == null:
			push_warning("PlanetData: biomemap.get_image() returned null for '%s'" % planet_name)
	return _biomemap_image


# ---------------------------------------------------------------------------
# Planet JSON loader
# ---------------------------------------------------------------------------

## Load planet metadata from an exported QGIS planet JSON file.
## Overwrites radius, max_height, chunk_export_depth, and max_quadtree_depth
## with the values from the JSON so they stay in sync with the export pipeline.
## Returns true on success.
func load_from_planet_json(path: String = "") -> bool:
	if path.is_empty():
		path = planet_json
	# Fallback: if planet_json was lost or broken (e.g. format=4 serialization
	# drops non-@export vars, producing a broken default path with an empty
	# planet_name segment) but planet_name is now set, reconstruct the path.
	var broken := path.is_empty() or path.ends_with("/_planet.json") or path.find("//") >= 0
	if broken and not planet_name.is_empty():
		path = "assets/qgis/export/%s/planet.json" % planet_name
		planet_json = path
	if path.is_empty():
		return false

	var full_path := path
	if not full_path.begins_with("res://"):
		full_path = "res://" + full_path

	var fa := FileAccess.open(full_path, FileAccess.READ)
	if fa == null:
		push_warning("PlanetData: could not open planet JSON '%s'" % full_path)
		return false

	var json_text := fa.get_as_text()
	fa.close()

	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		push_warning("PlanetData: failed to parse planet JSON '%s': %s" % [
			full_path, json.get_error_message()])
		return false

	var data: Dictionary = json.data
	if data == null or data.is_empty():
		push_warning("PlanetData: planet JSON '%s' is empty" % full_path)
		return false

	# Overwrite exported properties from JSON
	if data.has("has_ocean"):
		has_ocean = bool(data["has_ocean"])
	elif data.has("has_water"):  # legacy key
		has_ocean = bool(data["has_water"])
	if data.has("planet_name"):
		planet_name = str(data["planet_name"])
	if data.has("radius"):
		radius = float(data["radius"])
	if data.has("max_height"):
		max_height = float(data["max_height"])
	elif data.has("elevation_max"):
		# Fallback: use elevation_max directly
		max_height = float(data["elevation_max"])
	if data.has("height_offset"):
		height_offset = float(data["height_offset"])
	if data.has("chunk_export_depth"):
		chunk_export_depth = int(data["chunk_export_depth"])
	if data.has("nside"):
		export_nside = int(data["nside"])
	elif data.has("chunk_export_depth"):
		export_nside = 1 << int(data["chunk_export_depth"])
	if data.has("max_quadtree_depth"):
		max_quadtree_depth = int(data["max_quadtree_depth"])

	# LOD distances from JSON (if present)
	if data.has("lod"):
		var lod_cfg: Dictionary = data["lod"]
		if lod_cfg.has("lod0_distance"):
			lod0_distance = float(lod_cfg["lod0_distance"])
		if lod_cfg.has("lod1_distance"):
			lod1_distance = float(lod_cfg["lod1_distance"])
		if lod_cfg.has("lod2_distance"):
			lod2_distance = float(lod_cfg["lod2_distance"])
		if lod_cfg.has("lod3_distance"):
			lod3_distance = float(lod_cfg["lod3_distance"])
		if lod_cfg.has("lod4_distance"):
			lod4_distance = float(lod_cfg["lod4_distance"])

	# Auto-populate GeoJSON paths from the "files" dict if not already set.
	if data.has("files"):
		var files: Dictionary = data["files"]
		# Derive the export directory from the planet JSON path itself.
		var export_dir := full_path.get_base_dir()
		if not export_dir.ends_with("/"):
			export_dir += "/"
		# Strip the "res://" prefix so the stored path is relative like biomes_geojson.
		var rel_dir := export_dir
		if rel_dir.begins_with("res://"):
			rel_dir = rel_dir.substr(6)
		if roads_geojson.is_empty() and files.has("roads_buffered"):
			roads_geojson = rel_dir + str(files["roads_buffered"])
			print("PlanetData: auto-set roads_geojson = '%s'" % roads_geojson)
		if (biomes_geojson.is_empty() or biomes_geojson.ends_with("/_biomes.json")) and files.has("biomes"):
			biomes_geojson = rel_dir + str(files["biomes"])
			print("PlanetData: auto-set biomes_geojson = '%s'" % biomes_geojson)
		# Spatial tile index: the QGIS pipeline exports "biomes_index" instead
		# of "biomes" when using tiled biome data.  Construct the expected
		# base path so BiomeQuery.load_geojson() finds the _index.json companion.
		if (biomes_geojson.is_empty() or biomes_geojson.ends_with("/_biomes.json")) \
				and files.has("biomes_index"):
			# biomes_index value is e.g. "tarsis_5_1_biomes_index.json"
			# Derive the base biomes path by stripping the "_index" suffix.
			var idx_file: String = str(files["biomes_index"])
			var base_file := idx_file.replace("_index.json", ".json")
			biomes_geojson = rel_dir + base_file
			print("PlanetData: auto-set biomes_geojson = '%s' (from biomes_index)" % biomes_geojson)

	if data.has("craters_baked") and data["craters_baked"]:
		craters_baked = true
		print("PlanetData: craters_baked = true (skip runtime crater displacement)")

	print("PlanetData: loaded planet JSON '%s' — radius=%.0f  max_height=%.1f  "
		% [full_path, radius, max_height]
		+ "chunk_export_depth=%d  export_nside=%d" % [chunk_export_depth, export_nside])
	return true
## Returns null if the recipe file doesn't exist or the chunk is empty.
## When null is returned, callers should fall back to the global heightmap.
## Recipe heightmap generation is handled asynchronously by the terrain
## system.  This method only returns already-cached Images.
## Thread-safe: may be called from WorkerThreadPool mesh tasks.
func load_chunk_heightmap(ipix: int) -> Image:
	var key := "hp_n%d_p%d" % [export_nside, ipix]
	# Server fast path: cache is read-only after preload, skip mutex + LRU.
	if _server_no_evict:
		return _chunk_images.get(key) as Image
	_cache_mutex.lock()
	if _chunk_images.has(key):
		# LRU touch: move to end of order list
		var idx := _cache_order.find(key)
		if idx >= 0:
			_cache_order.remove_at(idx)
			_cache_order.append(key)
		var result := _chunk_images[key] as Image
		_cache_mutex.unlock()
		return result
	_cache_mutex.unlock()
	# Not cached yet — return null so callers fall back to global heightmap.
	# The async recipe pipeline in PlanetTerrain will generate and cache it.
	return null


## Returns true if the recipe image for [param export_key] is cached.
## [param export_key] has the form "hp_nN_pP".  Thread-safe.
func is_chunk_cached(export_key: String) -> bool:
	_cache_mutex.lock()
	var result := _chunk_images.has(export_key)
	_cache_mutex.unlock()
	return result


## Store a recipe-generated heightmap [param img] and optional sub-pixel
## [param craters] in the cache.  Must be called from the main thread.
func store_chunk_image(key: String, img: Image, craters: Array,
		populate_zones: Array = [], linear_features: Array = [],
		radial_features: Array = []) -> void:
	_cache_mutex.lock()
	_chunk_images[key] = img
	_cache_order.append(key)
	_cache_bytes += img.get_width() * img.get_height() * 4
	_cache_mutex.unlock()
	_evict_lru()
	if not craters.is_empty():
		_chunk_craters[key] = craters
	if not populate_zones.is_empty():
		_chunk_populate_zones[key] = populate_zones
	if not linear_features.is_empty():
		_chunk_linear_features[key] = linear_features
	if not radial_features.is_empty():
		_chunk_radial_features[key] = radial_features


## Force-initialise the road query on the calling thread.
## Must be called from the main thread before the first mesh WorkerThreadPool
## task is submitted, so that background tasks see the query as read-only.
func ensure_queries_loaded() -> void:
	get_road_query()


## Invalidate the cached recipe data for a single export-level chunk.
## Call this before re-loading a recipe that has been modified by a biome
## injection so the next _load_recipe_heightmap picks up fresh data.
func invalidate_chunk_cache(export_key: String) -> void:
	_cache_mutex.lock()
	if _chunk_images.has(export_key):
		var old_img: Image = _chunk_images[export_key]
		if old_img:
			_cache_bytes -= old_img.get_width() * old_img.get_height() * 4
		_chunk_images.erase(export_key)
		_cache_order.erase(export_key)
	_cache_mutex.unlock()
	_chunk_craters.erase(export_key)
	_chunk_populate_zones.erase(export_key)
	_chunk_linear_features.erase(export_key)
	_chunk_radial_features.erase(export_key)


## Inject a biome feature into the cached populate_zones or linear_features
## for an export-level chunk.  Used by the server when Horizon sends a
## biome update (e.g. a new cave or road).
## [param nside] — export nside.
## [param ipix] — export-level pixel index.
## [param biome_update] — Dictionary with keys:
##     biome_type: String, action: "add"/"remove",
##     geometry: { type: "linear"/"polygon"/"point", vertices: [[lon,lat],...],
##                 width: float, depth: float }
func inject_biome_feature(nside: int, ipix: int, biome_update: Dictionary) -> void:
	var key := "hp_n%d_p%d" % [nside, ipix]
	var action: String = biome_update.get("action", "add")
	var biome_type: String = biome_update.get("biome_type", "")
	var geometry: Dictionary = biome_update.get("geometry", {})
	var geom_type: String = geometry.get("type", "")

	if action == "add":
		if geom_type == "linear":
			# Add as a linear feature.
			var feature := {
				"type": biome_type,
				"centerline": geometry.get("vertices", []),
				"width_start_m": geometry.get("width", 10.0),
				"width_end_m": geometry.get("width", 10.0),
				"depth_m": geometry.get("depth", 5.0),
				"profile": "v",
			}
			if not _chunk_linear_features.has(key):
				_chunk_linear_features[key] = []
			_chunk_linear_features[key].append(feature)
		elif geom_type == "polygon" or geom_type == "point":
			# Add as a populate zone.
			var verts: Array = geometry.get("vertices", [])
			var zone := {
				"biome_type": biome_type,
				"coverage": "point" if geom_type == "point" else "polygon",
			}
			if geom_type == "point" and verts.size() >= 1:
				zone["lon"] = verts[0][0] if verts[0] is Array else verts[0].x
				zone["lat"] = verts[0][1] if verts[0] is Array else verts[0].y
			elif verts.size() >= 3:
				var packed := PackedVector2Array()
				for v in verts:
					packed.append(Vector2(v[0], v[1]) if v is Array else v)
				zone["polygon"] = packed
			if not _chunk_populate_zones.has(key):
				_chunk_populate_zones[key] = []
			_chunk_populate_zones[key].append(zone)

	elif action == "remove":
		# Remove matching biome_type entries.
		if _chunk_populate_zones.has(key):
			var filtered: Array = []
			for z in _chunk_populate_zones[key]:
				if z.get("biome_type", "") != biome_type:
					filtered.append(z)
			_chunk_populate_zones[key] = filtered
		if _chunk_linear_features.has(key):
			var filtered: Array = []
			for lf in _chunk_linear_features[key]:
				if lf.get("type", "") != biome_type:
					filtered.append(lf)
			_chunk_linear_features[key] = filtered


## Load a recipe Dictionary from the planet pack.
## Entry names inside the pack follow "base_<N>/<key>.bin" where <key> is
## e.g. "hp_n64_p1234".  Binary uses Godot native variant format
## (store_var/get_var) matching tools/convert_recipes_binary.gd.
## Returns {"recipe": Dictionary, "format": "bin", "size": int} or {}.
func _load_recipe_dict(base_pixel: int, key: String) -> Dictionary:
	var pack = _get_pack()
	if pack == null:
		return {}
	var entry := "base_%d/%s.bin" % [base_pixel, key]
	if not pack.has_entry(entry):
		return {}
	var data: Variant = pack.read_entry_var(entry)
	if not (data is Dictionary) or (data as Dictionary).is_empty():
		return {}
	var size: int = pack.get_entry_size(entry)
	return {"recipe": data, "format": "bin", "size": size}


## Resolve the .planetpack for this planet (lazy).
## Returns null if the pack is missing.
func _get_pack():
	if _pack != null:
		return _pack
	_pack_open_mutex.lock()
	# Re-check after acquiring the lock (double-checked init).
	if _pack != null:
		_pack_open_mutex.unlock()
		return _pack
	if _pack_tried:
		_pack_open_mutex.unlock()
		return null
	_pack_tried = true
	if planet_name.is_empty():
		_pack_open_mutex.unlock()
		push_warning("PlanetData: cannot open pack — planet_name is empty")
		return null
	var path := "res://assets/qgis/export/%s.planetpack" % planet_name
	var pack = PlanetPackScript.new()
	if not pack.open(path):
		_pack_open_mutex.unlock()
		push_error("PlanetData: failed to open planet pack '%s'" % path)
		return null
	_pack = pack
	print("PlanetData: opened planet pack '%s' (%d entries)" % [path, pack.entry_count()])
	_pack_open_mutex.unlock()
	return _pack


## Build (or return cached) safety-net collision triangle face array.
## Reads the small "safety_mesh.json" entry from the planet pack
## (written by tools/qgis/export_planet.py::pack_planet_recipes()) and
## generates a coarse triangulated sphere at nside=4 (192 HEALPix pixels →
## 384 triangles) whose vertices sit at radius + elev_min - safety_margin.
## Returns an empty array when the pack/entry is unavailable; callers
## should treat that as "no safety net for this planet" and continue.
func load_safety_mesh_faces() -> PackedVector3Array:
	if _safety_mesh_tried:
		return _safety_mesh_faces
	_safety_mesh_tried = true

	var pack = _get_pack()
	if pack == null:
		return _safety_mesh_faces
	if not pack.has_entry("safety_mesh.json"):
		# Pack predates safety-mesh support — fall back to planet's own
		# radius / max_height fields.
		var fallback_meta := {
			"nside": 4,
			"radius_m": radius,
			"elev_min_m": -max_height + height_offset,
			"safety_margin_m": 200.0,
		}
		_safety_mesh_faces = _build_safety_mesh_faces(fallback_meta)
		return _safety_mesh_faces

	var meta: Variant = pack.read_entry_json("safety_mesh.json")
	if not (meta is Dictionary):
		push_warning("PlanetData: safety_mesh.json is not a Dictionary in '%s'" % planet_name)
		return _safety_mesh_faces
	_safety_mesh_faces = _build_safety_mesh_faces(meta as Dictionary)
	return _safety_mesh_faces


## Triangulate a coarse HEALPix sphere at meta.nside (typically 4 → 192 pixels).
## For each pixel, sample the 4 corners via HEALPix.get_pixel_grid(.., 1) and
## emit 2 triangles. All vertices are placed at meta.radius_m +
## meta.elev_min_m - meta.safety_margin_m so nothing can clip below.
func _build_safety_mesh_faces(meta: Dictionary) -> PackedVector3Array:
	var sm_nside: int = int(meta.get("nside", 4))
	var sm_radius: float = float(meta.get("radius_m", radius))
	var sm_elev_min: float = float(meta.get("elev_min_m", -max_height + height_offset))
	var sm_margin: float = float(meta.get("safety_margin_m", 200.0))
	# Final shell radius: below the deepest valley, with a margin so
	# nothing can ever rest underneath the visible terrain.
	var shell_r: float = sm_radius + sm_elev_min - sm_margin
	if shell_r <= 0.0:
		push_warning("PlanetData: safety_mesh shell radius <= 0 for '%s' (radius=%.1f elev_min=%.1f margin=%.1f); clamping" % [
			planet_name, sm_radius, sm_elev_min, sm_margin])
		shell_r = maxf(sm_radius * 0.5, 1.0)

	var npix: int = 12 * sm_nside * sm_nside
	var faces := PackedVector3Array()
	faces.resize(npix * 6)  # 2 triangles × 3 verts per pixel

	var fi := 0
	for ipix in npix:
		# 1×1 subdivision → 2 rows × 2 verts (the 4 pixel corners).
		var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(sm_nside, ipix, 1)
		var v00 := grid[0][0] * shell_r
		var v10 := grid[0][1] * shell_r
		var v01 := grid[1][0] * shell_r
		var v11 := grid[1][1] * shell_r
		# Two triangles, outward-facing (normals point away from planet centre).
		faces[fi]     = v00
		faces[fi + 1] = v01
		faces[fi + 2] = v10
		faces[fi + 3] = v10
		faces[fi + 4] = v01
		faces[fi + 5] = v11
		fi += 6

	print("PlanetData: built safety-net mesh for '%s' nside=%d shell_r=%.1f tris=%d" % [
		planet_name, sm_nside, shell_r, npix * 2])
	return faces


## Compute the set of export-nside HEALPix chunk keys whose surface
## footprint touches [param aabb_local] (an AABB expressed in this planet's
## local space, i.e. world AABB minus the planet's global position).
##
## Used by the server to decide which chunks need collision residency for
## its authoritative zone.  Samples the AABB corners + face centres + edge
## midpoints, projects each onto the planet sphere, looks up the touched
## HEALPix pixel, then optionally expands by [param ring_skirt] HEALPix
## neighbour rings (default 1) to cover boundary cases.
##
## Returns a deduplicated [PackedStringArray] of "hp_nN_pP" keys.  May be
## empty when the AABB lies entirely outside the planet (no chunk touched).
func chunks_in_aabb_world(aabb_local: AABB, ring_skirt: int = 1) -> PackedStringArray:
	var nside: int = export_nside
	var ns_pix_count: int = 12 * nside * nside

	# Reject AABBs that are clearly outside the planet shell.
	# Furthest point on AABB from origin (one of the 8 corners).
	var furthest := 0.0
	var corners := _aabb_corners(aabb_local)
	for c in corners:
		var d := c.length()
		if d > furthest:
			furthest = d
	# AABB is below planet surface entirely → no chunks intersect.
	if furthest < radius * 0.5:
		return PackedStringArray()

	var seen: Dictionary = {}

	# Helper to add an ipix and its ring expansion.
	var add_ipix := func(ipix: int):
		if ipix < 0 or ipix >= ns_pix_count:
			return
		var key := "hp_n%d_p%d" % [nside, ipix]
		seen[key] = ipix

	# Sample corners (8) + face centres (6) + edge midpoints (12).
	var samples := corners
	var size_v := aabb_local.size
	var pos_v := aabb_local.position
	var c0 := pos_v + size_v * 0.5
	# Face centres
	samples.append(Vector3(pos_v.x, c0.y, c0.z))
	samples.append(Vector3(pos_v.x + size_v.x, c0.y, c0.z))
	samples.append(Vector3(c0.x, pos_v.y, c0.z))
	samples.append(Vector3(c0.x, pos_v.y + size_v.y, c0.z))
	samples.append(Vector3(c0.x, c0.y, pos_v.z))
	samples.append(Vector3(c0.x, c0.y, pos_v.z + size_v.z))

	for sample in samples:
		# Skip degenerate (zero-length) projection vectors.
		var len_sq := sample.length_squared()
		if len_sq < 1.0e-6:
			continue
		var dir := sample / sqrt(len_sq)
		var ipix := HEALPix.vec2pix_nest(nside, dir)
		add_ipix.call(ipix)

	# Expand each seen ipix by [ring_skirt] HEALPix neighbour rings.
	for _r in ring_skirt:
		var to_add: Array[int] = []
		for k in seen.keys():
			var ip: int = seen[k]
			var nbrs: Dictionary = HEALPix.get_neighbors_nest(nside, ip)
			for v in nbrs.values():
				to_add.append(int(v))
		for ip2 in to_add:
			add_ipix.call(ip2)

	var out := PackedStringArray()
	for k in seen.keys():
		out.append(k as String)
	return out


## Return the 8 corners of an AABB as Array[Vector3].
static func _aabb_corners(b: AABB) -> Array[Vector3]:
	var p := b.position
	var s := b.size
	return [
		p,
		p + Vector3(s.x, 0, 0),
		p + Vector3(0, s.y, 0),
		p + Vector3(0, 0, s.z),
		p + Vector3(s.x, s.y, 0),
		p + Vector3(s.x, 0, s.z),
		p + Vector3(0, s.y, s.z),
		p + s,
	]


## Load only the recipe dict and merged crater data for [param ipix].
## Intended to be called **from the main thread** before submitting
## [method ChunkRecipeGenerator.generate_heightmap] to WorkerThreadPool.
## Keeping the file I/O on the main thread avoids acquiring this object's
## GDScript instance lock from worker threads, which would otherwise
## serialize all concurrent recipe tasks.
## Returns a Dictionary with keys "recipe", "format", "size", or empty on
## failure.
func _load_recipe_data_sync(ipix: int, key: String) -> Dictionary:
	var base_pixel := ipix / (export_nside * export_nside)
	var loaded := _load_recipe_dict(base_pixel, key)
	if loaded.is_empty():
		return {}
	var recipe: Dictionary = loaded["recipe"]
	if not skip_neighbor_crater_merge:
		var nb_nside: int = recipe.get("nside", export_nside)
		var neighbors := HEALPix.get_neighbors_nest(nb_nside, ipix)
		var extra_craters: Array = []
		for dir_name: String in neighbors:
			var nb_ipix: int = neighbors[dir_name]
			if nb_ipix < 0:
				continue
			extra_craters.append_array(_load_neighbor_recipe_craters(nb_ipix))
		if not extra_craters.is_empty():
			var existing: Array = recipe.get("craters", [])
			existing.append_array(extra_craters)
			recipe["craters"] = existing
	loaded["recipe"] = recipe
	return loaded


## Load a recipe file and generate a heightmap Image from it.
## Large craters are baked into the heightmap by the recipe generator;
## sub-pixel craters are returned for per-vertex displacement.
## Returns [Image_or_null, Array_of_subpixel_craters].
func _load_recipe_heightmap(ipix: int, key: String) -> Array:
	var t_total := Time.get_ticks_usec()
	var base_pixel := ipix / (export_nside * export_nside)

	var t0 := Time.get_ticks_usec()
	var loaded := _load_recipe_dict(base_pixel, key)
	if loaded.is_empty():
		return [null, []]
	var t_read_parse := Time.get_ticks_usec() - t0

	var recipe: Dictionary = loaded["recipe"]
	var fmt: String = loaded["format"]
	var file_size: int = loaded["size"]

	# ── Merge craters from neighbor chunk recipes ──────────────────
	# The export pipeline assigns craters to chunks via an equirectangular
	# AABB check which can miss craters near HEALPix face boundaries and
	# high latitudes.  Load the 8 neighbor recipes and merge their craters
	# so cross-boundary craters are correctly baked into this heightmap.
	# Skip entirely when the planet has no craters (avoids 8 reads per chunk).
	var t_neighbors: int = 0
	if not skip_neighbor_crater_merge:
		t0 = Time.get_ticks_usec()
		var nb_nside: int = recipe.get("nside", export_nside)
		var neighbors := HEALPix.get_neighbors_nest(nb_nside, ipix)
		var extra_craters: Array = []
		for dir_name: String in neighbors:
			var nb_ipix: int = neighbors[dir_name]
			if nb_ipix < 0:
				continue
			extra_craters.append_array(
				_load_neighbor_recipe_craters(nb_ipix))

		if not extra_craters.is_empty():
			var existing: Array = recipe.get("craters", [])
			existing.append_array(extra_craters)
			recipe["craters"] = existing
		t_neighbors = Time.get_ticks_usec() - t0

	# generate_heightmap returns [Image, Array_of_subpixel_craters].
	t0 = Time.get_ticks_usec()
	var gen_result := ChunkRecipeGenerator.generate_heightmap(
		recipe, _recipe_resolution, radius, height_offset, max_height)
	var t_generate := Time.get_ticks_usec() - t0

	var t_elapsed := Time.get_ticks_usec() - t_total
	if t_elapsed > 500_000:  # Log chunks taking > 500 ms
		print("[RecipeTiming] %s [%s]: total=%.1fms  read+parse=%.1fms  neighbors=%.1fms  generate=%.1fms  file_size=%d" % [
			key, fmt, t_elapsed / 1000.0, t_read_parse / 1000.0,
			t_neighbors / 1000.0, t_generate / 1000.0, file_size])

	var populate_zones := ChunkRecipeGenerator.get_populate_zones(recipe)
	var linear_feats: Array = recipe.get("linear_features", [])
	var radial_feats: Array = recipe.get("radial_features", [])
	if gen_result.size() >= 2:
		return [gen_result[0], gen_result[1], populate_zones, linear_feats, radial_feats]
	return [gen_result[0] if gen_result.size() > 0 else null, [], populate_zones, linear_feats, radial_feats]


## Load only the craters array from a neighbor recipe file.
## Returns [] if the file doesn't exist or has no craters.
func _load_neighbor_recipe_craters(ipix: int) -> Array:
	var nb_base := ipix / (export_nside * export_nside)
	var nb_key := "hp_n%d_p%d" % [export_nside, ipix]
	var loaded := _load_recipe_dict(nb_base, nb_key)
	if loaded.is_empty():
		return []
	var data: Dictionary = loaded["recipe"]
	return data.get("craters", [])


## Return the cached recipe crater list for an export-level chunk,
## including sub-pixel craters from cached neighbor chunks.
## Ensures cross-boundary craters are applied to per-vertex displacement.
func get_chunk_craters(ipix: int) -> Array:
	var key := "hp_n%d_p%d" % [export_nside, ipix]
	var own: Array = _chunk_craters.get(key, [])
	# Merge sub-pixel craters from cached neighbor export tiles.
	var neighbors := HEALPix.get_neighbors_nest(export_nside, ipix)
	var merged: Array = own.duplicate()
	for dir_name: String in neighbors:
		var nb_ipix: int = neighbors[dir_name]
		if nb_ipix < 0:
			continue
		var nb_key := "hp_n%d_p%d" % [export_nside, nb_ipix]
		var nb_arr: Array = _chunk_craters.get(nb_key, [])
		if not nb_arr.is_empty():
			merged.append_array(nb_arr)
	if merged.size() == own.size():
		return own
	# Deduplicate by (lon, lat, radius_m).
	var seen := {}
	var deduped: Array = []
	for cr in merged:
		var ck := "%.6f_%.6f_%.1f" % [float(cr["lon"]), float(cr["lat"]), float(cr["radius_m"])]
		if not seen.has(ck):
			seen[ck] = true
			deduped.append(cr)
	return deduped


## Return populate zones for an export-level chunk (from v7+ recipes).
## Each zone is a Dictionary with: biome_type, coverage, vertices (or lon/lat).
func get_chunk_populate_zones(ipix: int) -> Array:
	var key := "hp_n%d_p%d" % [export_nside, ipix]
	return _chunk_populate_zones.get(key, [])


## Return all populate zones across every loaded export chunk, flattened.
func get_all_populate_zones() -> Array:
	var result: Array = []
	for zones in _chunk_populate_zones.values():
		result.append_array(zones)
	return result


## Return cached linear features for an export-level chunk.
## Each entry has: type, centerline, width_start_m, width_end_m, profile, etc.
func get_chunk_linear_features(ipix: int) -> Array:
	var key := "hp_n%d_p%d" % [export_nside, ipix]
	return _chunk_linear_features.get(key, [])


## Return cached radial features for an export-level chunk.
## Each entry has: type, lon, lat, radius_m, depth_m, profile.
func get_chunk_radial_features(ipix: int) -> Array:
	var key := "hp_n%d_p%d" % [export_nside, ipix]
	return _chunk_radial_features.get(key, [])


const BASE_PIXEL_COUNT := 12


## Evict oldest cached chunk images when the cache exceeds the budget.
## Server mode (_server_no_evict) skips eviction entirely.
func _evict_lru() -> void:
	if _server_no_evict:
		return
	_cache_mutex.lock()
	while _cache_bytes > MAX_CACHE_BYTES and _cache_order.size() > 0:
		var oldest_key: String = _cache_order[0]
		_cache_order.remove_at(0)
		var old_img: Image = _chunk_images.get(oldest_key)
		if old_img != null:
			_cache_bytes -= old_img.get_width() * old_img.get_height() * 4
		_chunk_images.erase(oldest_key)
	_cache_mutex.unlock()


## Sample height from the chunk heightmap tile for a given direction vector.
## dir: unit direction on the sphere
## The function finds which export-level HEALPix pixel contains this direction,
## loads it, then samples bilinearly at the correct local UV position.
## When [param known_export_ipix] >= 0 it is used directly instead of calling
## vec2pix_nest, avoiding mis-classification at the polar/equatorial cap boundary.
func sample_height_for_direction(dir: Vector3, known_export_ipix: int = -1,
		_precomp_face: int = -1, _precomp_xy: Vector2i = Vector2i(-1, -1),
		_cached_neighbors = null) -> float:
	var ipix: int
	if known_export_ipix >= 0:
		ipix = known_export_ipix
	else:
		ipix = HEALPix.vec2pix_nest(export_nside, dir)
	var img := load_chunk_heightmap(ipix)
	if img == null:
		return sample_height_at(dir)

	# Get local UV within the pixel
	var local_uv := _direction_to_pixel_uv(dir, ipix, export_nside,
			_precomp_face, _precomp_xy)
	var h := _sample_image_bilinear_healpix(img, local_uv.x, local_uv.y, ipix,
			_cached_neighbors)
	return h * max_height + height_offset


## Sample height at a tile boundary vertex.  Uses vec2pix_nest to detect
## which export pixel the direction naturally belongs to.  If it differs
## from [param chain_ipix] (the deterministic parent-chain pixel) AND is
## a valid neighbour, uses vec_ipix directly — this is symmetric because
## vec2pix_nest is deterministic: both adjacent chunks resolve to the same
## tile for the same direction vector.
## When vec_ipix's tile is not yet loaded (async recipe not ready, or face
## boundary edge case), falls back to chain_ipix's tile — which is always
## loaded since we are generating this chunk. This avoids the catastrophic
## 0.0m fallback from a missing global heightmap.
func sample_height_boundary(dir: Vector3, chain_ipix: int,
		_precomp_face: int = -1, _precomp_xy: Vector2i = Vector2i(-1, -1),
		_cached_neighbors = null) -> float:
	var vec_ipix := HEALPix.vec2pix_nest(export_nside, dir)
	if vec_ipix == chain_ipix:
		return sample_height_for_direction(dir, chain_ipix,
				_precomp_face, _precomp_xy, _cached_neighbors)
	# Prefer the canonical tile (vec_ipix) when loaded — it is symmetric:
	# both sides of the boundary resolve to the same tile via vec2pix_nest.
	if load_chunk_heightmap(vec_ipix) != null:
		return sample_height_for_direction(dir, vec_ipix)
	# Canonical tile not loaded — fall back to chain_ipix's tile (known-loaded).
	# UV is clamped to [0,1] by _direction_to_pixel_uv, so the edge pixels are
	# used rather than the catastrophic 0.0m from a missing global heightmap.
	return sample_height_for_direction(dir, chain_ipix,
			_precomp_face, _precomp_xy, _cached_neighbors)


## Sample height for a cube-sphere chunk vertex.
## Converts cube-face (face, u, v) coords to a sphere direction, then
## delegates to [method sample_height_for_direction].
## The chunk bounds (u_min..u_max, v_min..v_max) are accepted for API
## compatibility but not currently used for tile selection.
func sample_height_for_chunk(
		face: int, u: float, v: float,
		_u_min: float, _u_max: float,
		_v_min: float, _v_max: float) -> float:
	var dir := cube_to_sphere(face, u, v)
	return sample_height_for_direction(dir)


## Compute the local UV [0,1]² of a direction within a HEALPix pixel.
## Uses the analytical inverse of _face_xy_to_vec to get continuous face
## coordinates, then subtracts the pixel's integer (ix, iy) to get the
## fractional position within the pixel.
## This replaces the old vec2pix_nest round-trip which quantised UVs to
## integer sub-pixel centres, causing terracing at high LOD and wrong
## values at pixel boundaries.
func _direction_to_pixel_uv(dir: Vector3, ipix: int, nside: int,
		_precomp_face: int = -1, _precomp_xy: Vector2i = Vector2i(-1, -1)) -> Vector2:
	var face: int
	var xy: Vector2i
	if _precomp_face >= 0:
		face = _precomp_face
		xy = _precomp_xy
	else:
		@warning_ignore("integer_division")
		face = ipix / (nside * nside)
		var local := ipix % (nside * nside)
		xy = HEALPix.nest2xy(local)

	var fc := HEALPix._vec_to_face_xy(dir, face, nside)
	var u := fc.x - float(xy.x)
	var v := fc.y - float(xy.y)
	return Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))


# ---------------------------------------------------------------------------
# Chunk helpers
# ---------------------------------------------------------------------------

## Check if an image is entirely black (all zeros) by sampling a grid
## of pixels.  This is used to detect empty chunk heightmaps so the
## caller can fall back to the global heightmap.
static func _is_image_empty(img: Image) -> bool:
	var w := img.get_width()
	var h := img.get_height()
	# Sample a 9×9 grid plus corners and centre
	var step_x := maxi(w / 8, 1)
	var step_y := maxi(h / 8, 1)
	for y in range(0, h, step_y):
		for x in range(0, w, step_x):
			if img.get_pixel(x, y).r > 0.0:
				return false
	return true


## Human-readable name for Image.Format enum values.
static func _format_name(fmt: int) -> String:
	match fmt:
		0: return "L8"
		1: return "LA8"
		2: return "R8"
		4: return "RGB8"
		5: return "RGBA8"
		8: return "RF"
		12: return "RH"
		_: return "fmt_%d" % fmt


# ---------------------------------------------------------------------------
# Bilinear image sampling
# ---------------------------------------------------------------------------

## Sample an image with bilinear interpolation.  u_norm and v_norm are in
## [0, 1] (normalised texture coordinates).  Returns the interpolated red
## channel value — used for heightmaps stored as 16-bit greyscale PNGs
## where the height lives in the R channel.
static func _sample_image_bilinear(img: Image, u_norm: float, v_norm: float) -> float:
	var w := img.get_width()
	var h := img.get_height()

	# Continuous pixel position (pixel centres are at +0.5)
	var fpx := u_norm * w - 0.5
	var fpy := v_norm * h - 0.5

	# Integer coordinates of the four surrounding pixels
	var x0 := clampi(int(floorf(fpx)), 0, w - 1)
	var y0 := clampi(int(floorf(fpy)), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)

	# Fractional blend weights
	var fx := clampf(fpx - floorf(fpx), 0.0, 1.0)
	var fy := clampf(fpy - floorf(fpy), 0.0, 1.0)

	# Read the four pixel values (red channel = height)
	var v00 := img.get_pixel(x0, y0).r
	var v10 := img.get_pixel(x1, y0).r
	var v01 := img.get_pixel(x0, y1).r
	var v11 := img.get_pixel(x1, y1).r

	# Bilinear blend
	return (v00 * (1.0 - fx) * (1.0 - fy)
			+ v10 * fx * (1.0 - fy)
			+ v01 * (1.0 - fx) * fy
			+ v11 * fx * fy)


## Cross-tile bilinear sampling for HEALPix tiles with boundary blend zone.
##
## Two problems are solved here:
## 1) When the 2×2 bilinear kernel extends past the tile edge, out-of-
##    bounds pixels are fetched from the neighbour tile (_get_pixel_healpix).
## 2) A blend zone (BLEND_PIXELS wide on each side) linearly fades between
##    the current tile's sample and the neighbour's sample so both tiles
##    converge to the same height at the seam.
func _sample_image_bilinear_healpix(
		img: Image, u_norm: float, v_norm: float,
		ipix: int, _cached_neighbors = null) -> float:
	var w := img.get_width()
	var h := img.get_height()

	# How many pixels from each tile edge to blend.  Higher = smoother
	# transition but slightly blurs the terrain at tile boundaries.
	const BLEND_PIXELS := 4

	# Continuous pixel position (pixel centres are at +0.5)
	var fpx := u_norm * float(w) - 0.5
	var fpy := v_norm * float(h) - 0.5

	# Integer coordinates of the four surrounding pixels (MAY be out of bounds)
	var x0 := int(floorf(fpx))
	var y0 := int(floorf(fpy))
	var x1 := x0 + 1
	var y1 := y0 + 1

	# Fractional blend weights
	var fx := clampf(fpx - floorf(fpx), 0.0, 1.0)
	var fy := clampf(fpy - floorf(fpy), 0.0, 1.0)

	# ── Sample current tile (always needed) ────────────────────────
	var val: float
	if x0 >= 0 and x1 < w and y0 >= 0 and y1 < h:
		var a00 := img.get_pixel(x0, y0).r
		var a10 := img.get_pixel(x1, y0).r
		var a01 := img.get_pixel(x0, y1).r
		var a11 := img.get_pixel(x1, y1).r
		val = (a00 * (1.0 - fx) * (1.0 - fy)
				+ a10 * fx * (1.0 - fy)
				+ a01 * (1.0 - fx) * fy
				+ a11 * fx * fy)
	else:
		# Out-of-bounds kernel pixel — fetch from neighbor tile
		var v00 := _get_pixel_healpix(img, x0, y0, w, h, ipix, _cached_neighbors)
		var v10 := _get_pixel_healpix(img, x1, y0, w, h, ipix, _cached_neighbors)
		var v01 := _get_pixel_healpix(img, x0, y1, w, h, ipix, _cached_neighbors)
		var v11 := _get_pixel_healpix(img, x1, y1, w, h, ipix, _cached_neighbors)
		val = (v00 * (1.0 - fx) * (1.0 - fy)
				+ v10 * fx * (1.0 - fy)
				+ v01 * (1.0 - fx) * fy
				+ v11 * fx * fy)

	# ── Fast path: not near any edge → done ────────────────────────
	var near_left  := fpx < float(BLEND_PIXELS)
	var near_right := fpx > float(w - 1 - BLEND_PIXELS)
	var near_bot   := fpy < float(BLEND_PIXELS)
	var near_top   := fpy > float(h - 1 - BLEND_PIXELS)

	if not (near_left or near_right or near_bot or near_top):
		return val

	# ── Blend with neighbour tile(s) in the margin zone ────────────
	var blend_margin := float(BLEND_PIXELS)
	var neighbors: Dictionary
	if _cached_neighbors != null:
		neighbors = _cached_neighbors
	else:
		neighbors = HEALPix.get_neighbors_nest(export_nside, ipix)

	# Horizontal blend (left or right neighbour).
	if near_left and neighbors.has("W") and neighbors["W"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["W"])
		if nb_img and nb_img.get_width() == w:
			var nb_u := (float(w) + fpx) / float(w)
			var nb_val := _sample_image_bilinear(nb_img, nb_u, v_norm)
			var t := clampf(1.0 - (fpx + 0.5) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)
	elif near_right and neighbors.has("E") and neighbors["E"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["E"])
		if nb_img and nb_img.get_width() == w:
			var nb_u := clampf((fpx - float(w) + 0.5) / float(w), 0.0, 1.0)
			var nb_val := _sample_image_bilinear(nb_img, nb_u, v_norm)
			var t := clampf(1.0 - (float(w) - 0.5 - fpx) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)

	# Vertical blend (bottom or top neighbour).
	if near_bot and neighbors.has("S") and neighbors["S"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["S"])
		if nb_img and nb_img.get_height() == h:
			var nb_v := (float(h) + fpy) / float(h)
			var nb_val := _sample_image_bilinear(nb_img, u_norm, nb_v)
			var t := clampf(1.0 - (fpy + 0.5) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)
	elif near_top and neighbors.has("N") and neighbors["N"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["N"])
		if nb_img and nb_img.get_height() == h:
			var nb_v := clampf((fpy - float(h) + 0.5) / float(h), 0.0, 1.0)
			var nb_val := _sample_image_bilinear(nb_img, u_norm, nb_v)
			var t := clampf(1.0 - (float(h) - 0.5 - fpy) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)

	return val


## Read a single heightmap pixel, fetching from the neighbour HEALPix tile
## when (px, py) falls outside the current tile [0, w) × [0, h).
func _get_pixel_healpix(img: Image, px: int, py: int,
		w: int, h: int, ipix: int, _cached_neighbors = null) -> float:
	if px >= 0 and px < w and py >= 0 and py < h:
		return img.get_pixel(px, py).r

	# Out of bounds — try neighbor tile
	var neighbors: Dictionary
	if _cached_neighbors != null:
		neighbors = _cached_neighbors
	else:
		neighbors = HEALPix.get_neighbors_nest(export_nside, ipix)
	var nb_ipix := -1
	var nb_px := px
	var nb_py := py

	if px < 0:
		nb_ipix = neighbors.get("W", -1)
		nb_px = w + px
	elif px >= w:
		nb_ipix = neighbors.get("E", -1)
		nb_px = px - w
	if py < 0:
		if nb_ipix < 0:
			nb_ipix = neighbors.get("S", -1)
		nb_py = h + py
	elif py >= h:
		if nb_ipix < 0:
			nb_ipix = neighbors.get("N", -1)
		nb_py = py - h

	if nb_ipix >= 0:
		var nb_img := load_chunk_heightmap(nb_ipix)
		if nb_img and nb_img.get_width() == w and nb_img.get_height() == h:
			nb_px = clampi(nb_px, 0, w - 1)
			nb_py = clampi(nb_py, 0, h - 1)
			return nb_img.get_pixel(nb_px, nb_py).r

	return img.get_pixel(clampi(px, 0, w - 1), clampi(py, 0, h - 1)).r


# ---------------------------------------------------------------------------
# Coordinate helpers
# ---------------------------------------------------------------------------

## Convert a unit direction vector to equirectangular UV in [0, 1].
## Matches the QGIS EPSG:4326 convention:
##   u  →  longitude  (0 = -180°, 1 = +180°)
##   v  →  latitude   (0 = +90° north pole, 1 = -90° south pole)
static func direction_to_uv(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var u := 0.5 + atan2(d.z, d.x) / TAU
	var v := 0.5 - asin(clampf(d.y, -1.0, 1.0)) / PI
	return Vector2(u, v)


## Convert cube-face local coordinates to a unit sphere direction.
## face: 0 = +X, 1 = -X, 2 = +Y, 3 = -Y, 4 = +Z, 5 = -Z
## u, v ∈ [-1, 1]
static func cube_to_sphere(face: int, u: float, v: float) -> Vector3:
	var point: Vector3
	match face:
		0: point = Vector3( 1.0,   v, -u)
		1: point = Vector3(-1.0,   v,  u)
		2: point = Vector3(   u, 1.0, -v)
		3: point = Vector3(   u,-1.0,  v)
		4: point = Vector3(   u,   v, 1.0)
		5: point = Vector3(  -u,   v,-1.0)
		_: point = Vector3.UP
	return point.normalized()


## Inverse of [method cube_to_sphere]: convert a unit direction back to
## cube-face coordinates.  Returns [code]{"face": int, "u": float, "v": float}[/code].
static func sphere_to_cube(dir: Vector3) -> Dictionary:
	var d := dir.normalized()
	var ax := absf(d.x)
	var ay := absf(d.y)
	var az := absf(d.z)
	var face: int = 0
	var u: float = 0.0
	var v: float = 0.0
	var s: float
	if ax >= ay and ax >= az:
		s = 1.0 / ax
		if d.x > 0.0:
			face = 0
			u = -d.z * s
			v = d.y * s
		else:
			face = 1
			u = d.z * s
			v = d.y * s
	elif ay >= ax and ay >= az:
		s = 1.0 / ay
		if d.y > 0.0:
			face = 2
			u = d.x * s
			v = -d.z * s
		else:
			face = 3
			u = d.x * s
			v = d.z * s
	else:
		s = 1.0 / az
		if d.z > 0.0:
			face = 4
			u = d.x * s
			v = d.y * s
		else:
			face = 5
			u = -d.x * s
			v = d.y * s
	return {"face": face, "u": u, "v": v}


# ---------------------------------------------------------------------------
# Texture sampling
# ---------------------------------------------------------------------------

## Sample the global heightmap and return the terrain height in meters.
## Prefer [method sample_height_for_chunk] when the chunk face & UV are known.
func sample_height_at(dir: Vector3) -> float:
	var img := _get_heightmap_image()
	if img == null:
		return 0.0
	var uv := direction_to_uv(dir)
	return _sample_image_bilinear(img, uv.x, uv.y) * max_height + height_offset


## Sample the biome map and return the biome colour.
## Priority: 1) biomemap texture pixel  2) BiomeQuery → BiomeDefinition.color
## 3) fallback base colour (gray-brown, suits most rocky planets).
func sample_biome_at(dir: Vector3) -> Color:
	# ── Path 1: biomemap texture (equirectangular raster from QGIS) ──
	var img := get_biomemap_image()
	if img != null:
		var uv := direction_to_uv(dir)
		var px := clampi(int(uv.x * img.get_width()), 0, img.get_width() - 1)
		var py := clampi(int(uv.y * img.get_height()), 0, img.get_height() - 1)
		return img.get_pixel(px, py)

	# ── Path 2: populate zones → BiomeDefinition.color ──
	if export_nside > 0:
		var eipix := HEALPix.vec2pix_nest(export_nside, dir)
		var pz := get_chunk_populate_zones(eipix)
		if not pz.is_empty():
			var matched := PlanetChunk._query_zones_at_direction(dir, pz)
			if not matched.is_empty():
				var bt: String = matched[0].get("biome_type", "")
				var bd := get_biome_by_type(bt)
				if bd:
					return bd.color

	# ── Path 3: fallback ──
	return Color(0.45, 0.35, 0.25, 1.0)


# ---------------------------------------------------------------------------
# LOD helpers
# ---------------------------------------------------------------------------

## Return the LOD tier (0–4) for a given distance from the planet surface.
func get_lod_level(surface_distance: float) -> int:
	if surface_distance < lod0_distance:
		return 0
	if surface_distance < lod1_distance:
		return 1
	if surface_distance < lod2_distance:
		return 2
	if surface_distance < lod3_distance:
		return 3
	return 4


## Return the per-edge vertex count for a given LOD tier.
func get_resolution_for_lod(lod: int) -> int:
	match lod:
		0: return chunk_resolution        # e.g. 32
		1: return maxi(chunk_resolution / 2, 8)  # 16
		2: return maxi(chunk_resolution / 4, 4)  # 8
		3: return 4
		_: return 4


# ---------------------------------------------------------------------------
# Biome lookup
# ---------------------------------------------------------------------------
var _biome_by_index: Dictionary = {}  # int → BiomeDefinition
var _biome_by_type: Dictionary = {}   # String → BiomeDefinition
var _biome_cache_built: bool = false

## Shared cache: all BiomeDefinitions auto-loaded from disk.
## Populated once, shared across all PlanetData instances.
static var _all_biomes_loaded: bool = false
static var _all_biomes: Array[BiomeDefinition] = []

const BIOMES_DIR := "res://scenes/planet/biomes/"

## Hardcoded fallback list of every biome .tres filename.
## DirAccess cannot enumerate res:// in exported (packed) builds,
## so we keep this list as a reliable fallback.
const _BIOME_FILES: PackedStringArray = [
	"maritime_river-acid_lake.tres", "meadow_steppe-agriculture_land.tres",
	"wetland-ammonia_swamp.tres", "volcanic_geothermal-ash_desert.tres", "maritime_river-beach.tres",
	"wetland-bog.tres", "brine_basin.tres",
	"rocky_landform-canyon.tres", "meadow_steppe-chlorinated_field.tres", "rocky_landform-cliff.tres",
	"spatial-crater.tres",
	"icy-cryovolcanic.tres", "crystalline-crystalline_fields.tres", "aride_desert-rocky_desert.tres",
	"aride_desert-salt_desert.tres", "aride_desert-sandy_desert.tres", "aride_desert-dry_river_bed.tres",
	"aride_desert-dusty_plain.tres",
	"forest-boreal_forest.tres", "forest-dead_forest.tres", "forest-temperate_forest.tres",
	"forest-tropical_forest.tres", "icy-frozen_ocean.tres", "volcanic_geothermal-fumarole.tres",
	"rocky_landform-cave.tres", "volcanic_geothermal-geothermal.tres", "icy-glacier.tres",
	"meadow_steppe-meadow.tres", "spatial-lunar_ground.tres", "icy-ice_crevasse.tres",
	"volcanic_geothermal-ice_geyser.tres", "icy-ice_plain.tres", "icy-ice_pick.tres",
	"aride_desert-iron_desert.tres", "maritime_river-lake.tres",
	"urban-landing_pad.tres", "volcanic_geothermal-lava_field.tres",
	"volcanic_geothermal-lava_lake.tres", "volcanic_geothermal-lava_river.tres",
	"volcanic_geothermal-magmatic_crust.tres", "wetland-mangrove.tres", "spatial-lunar_pool.tres",
	"aride_desert-metal_plain.tres", "icy-hydrocarbon_dune.tres", "icy-methane_lake.tres",
	"volcanic_geothermal-mineral_thermal_source.tres", "urban-mining_excavation.tres",
	"rocky_landform-alpine_mountain.tres", "rocky_landform-raw_mountain.tres", "icy-nitrogen_ice.tres",
	"maritime_river-ocean.tres", "volcanic_geothermal-obsidian_field.tres", "icy-permafrost.tres",
	"rocky_landform-pressure_canyon.tres", "crystalline-quartz_desert.tres",
	"radioactive_waste.tres", "maritime_river-river.tres", "maritime_river-delta.tres",
	"urban-ruins.tres", "crystalline-salt_crystal_field.tres", "meadow_steppe-savanna.tres",
	"icy-snow.tres", "meadow_steppe-steppe.tres",
	"icy-sublimation_pit.tres", "meadow_steppe-sulfur_plain.tres", "volcanic_geothermal-sulfur_volcano.tres",
	"liquid_hydrocarbon_areas.tres", "wetland-swamp.tres", "tar_basin.tres",
	"forest-terraformed_forest.tres", "meadow_steppe-terraformed_grass.tres", "icy-tundra.tres",
	"urban-urban.tres", "volcanic_geothermal-active_volcano.tres",
	"volcanic_geothermal-volcanic_basalt.tres", "meadow_steppe-wasteland_irradiated.tres",
	"rocky_landform-mining_cave.tres",
	"volcanic_geothermal-columnar_basalt_vertical.tres",
	"aride_desert-anhydrite_desert.tres",
	"aride_desert-valley_of_fire.tres",
	"aride_desert-corundum_plateau.tres",
	"aride_desert-corundum_sand_desert.tres",
	"rocky_landform-arachnoide.tres",
	"volcanic_geothermal-lava_dome.tres",
	"rocky_landform-perforated_limestone.tres",
	"volcanic_geothermal-pele_haire.tres",
	"icy-frozen_methane.tres",
]


## Scan the biomes directory and load every .tres file as a BiomeDefinition.
## Called once; the result is cached in the static _all_biomes array.
## Uses DirAccess first (works in editor), then falls back to the hardcoded
## _BIOME_FILES list (required for exported / packed builds).
static func _auto_load_all_biomes() -> void:
	if _all_biomes_loaded:
		return
	_all_biomes_loaded = true
	_all_biomes.clear()

	# --- Attempt 1: DirAccess scan (editor only) ---
	var dir := DirAccess.open(BIOMES_DIR)
	if dir != null:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and fname.ends_with(".tres"):
				var res = ResourceLoader.load(BIOMES_DIR + fname)
				if res is BiomeDefinition:
					_all_biomes.append(res)
				else:
					push_warning("PlanetData: '%s' loaded but is not BiomeDefinition (type=%s)" % [fname, type_string(typeof(res))])
			fname = dir.get_next()
		dir.list_dir_end()

	# --- Attempt 2: fallback to hardcoded list ---
	if _all_biomes.size() == 0:
		for fname in _BIOME_FILES:
			var path := BIOMES_DIR + fname
			if ResourceLoader.exists(path):
				var res = ResourceLoader.load(path)
				if res is BiomeDefinition:
					_all_biomes.append(res)
				else:
					push_warning("PlanetData: '%s' loaded but is not BiomeDefinition (type=%s)" % [fname, type_string(typeof(res))])

	print("PlanetData: auto-loaded %d BiomeDefinitions from %s" % [
		_all_biomes.size(), BIOMES_DIR])


func _build_biome_cache() -> void:
	_biome_by_index.clear()
	_biome_by_type.clear()

	# 1) Load the shared set from disk (once across all planets).
	_auto_load_all_biomes()
	for bd in _all_biomes:
		if bd == null:
			continue
		if bd.biome_index >= 0:
			_biome_by_index[bd.biome_index] = bd
		if not bd.biome_type.is_empty():
			_biome_by_type[bd.biome_type] = bd

	# 2) Per-planet overrides take priority.
	for bd in biome_definitions:
		if bd == null:
			continue
		if bd.biome_index >= 0:
			_biome_by_index[bd.biome_index] = bd
		if not bd.biome_type.is_empty():
			_biome_by_type[bd.biome_type] = bd

	_biome_cache_built = true


## Look up a BiomeDefinition by its numeric index. Returns null if not found.
func get_biome_by_index(idx: int) -> BiomeDefinition:
	if not _biome_cache_built:
		_build_biome_cache()
	return _biome_by_index.get(idx)


## Look up a BiomeDefinition by its type string. Returns null if not found.
func get_biome_by_type(btype: String) -> BiomeDefinition:
	if not _biome_cache_built:
		_build_biome_cache()
	return _biome_by_type.get(btype)


## Return the terrain_material_override from the first liquid BiomeDefinition,
## or null if none exists.  Used by PlanetChunk to add per-chunk water surfaces.
func get_liquid_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	# Check per-planet overrides first, then auto-loaded set.
	for bd in biome_definitions:
		if bd and bd.is_liquid and bd.terrain_material_override:
			return bd.terrain_material_override
	for bd in _all_biomes:
		if bd and bd.is_liquid and bd.terrain_material_override:
			return bd.terrain_material_override
	return null


## Return the shallow_water_material from the first BiomeDefinition that
## has has_shallow_water == true, or null if none.
func get_shallow_water_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	for bd in biome_definitions:
		if bd and bd.has_shallow_water and bd.shallow_water_material:
			return bd.shallow_water_material
	for bd in _all_biomes:
		if bd and bd.has_shallow_water and bd.shallow_water_material:
			return bd.shallow_water_material
	return null


## Return the terrain_material_override from the river BiomeDefinition,
## or null if none exists.  Used by PlanetChunk for river water overlays.
func get_river_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type("maritime_river-river")
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	return null


## Return the terrain_material_override from the volcanic_geothermal-active_volcano
## BiomeDefinition, or null.  Used by PlanetChunk for lava overlays.
func get_lava_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type("volcanic_geothermal-active_volcano")
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	return null


## Return the terrain_material_override from the lunar ground
## BiomeDefinition, or null.  Used by PlanetChunk for lunar ground overlays.
func get_lunar_ground_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type("spatial-lunar_ground")
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	return null


## Return the terrain_material_override from the volcanic_geothermal-lava_river
## BiomeDefinition, or null.  Used by PlanetChunk for lava river overlays.
func get_lava_river_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type("volcanic_geothermal-lava_river")
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	return null


## Return the terrain_material_override from the meadow_steppe-meadow
## BiomeDefinition, or null.  Used by PlanetChunk for grass ground overlays.
func get_meadow_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type("meadow_steppe-meadow")
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	return null


## Return the pebble texture material for dry riverbeds.  Used by PlanetChunk
## to overlay the riverbed floor with the ganges pebble texture.
func get_riverbed_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type(ArideDesertDryRiverBedTerrain.BIOME_TYPE)
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	# Fallback: load from the canonical material path.
	if ResourceLoader.exists(ArideDesertDryRiverBedTerrain.MATERIAL_PATH):
		return ResourceLoader.load(ArideDesertDryRiverBedTerrain.MATERIAL_PATH) as Material
	return null


## Return the leaf-litter ground material for temperate forest terrain.
## Used by PlanetChunk to overlay the forest floor with the leaves texture.
func get_forest_ground_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type(ForestTemperateForestTerrain.BIOME_TYPE)
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	if ResourceLoader.exists(ForestTemperateForestTerrain.MATERIAL_PATH):
		return ResourceLoader.load(ForestTemperateForestTerrain.MATERIAL_PATH) as Material
	return null


## Return the cliff face ORMMaterial3D.  Used by PlanetChunk for cliff
## face overlays on steep/vertical terrain within cliff biome polygons.
func get_cliff_material() -> Material:
	if not _biome_cache_built:
		_build_biome_cache()
	var bd := get_biome_by_type("rocky_landform-cliff")
	if bd and bd.terrain_material_override:
		return bd.terrain_material_override
	# Fallback: load from the canonical material path.
	if ResourceLoader.exists(RockyLandformCliffTerrain.MATERIAL_PATH):
		return ResourceLoader.load(RockyLandformCliffTerrain.MATERIAL_PATH) as Material
	return null


## Return the road overlay material for a given road_type and biome_type.
## Highway/road → always asphalt; path/trail → biome-adaptive material.
## Returns null if the material resource doesn't exist.
func get_road_material(road_type: String, biome_type: String = "") -> Material:
	var mat_path := RoadTerrain.get_material_path(road_type, biome_type)
	if _road_material_cache.has(mat_path):
		return _road_material_cache[mat_path]
	if ResourceLoader.exists(mat_path):
		var mat = ResourceLoader.load(mat_path)
		if mat is Material:
			_road_material_cache[mat_path] = mat
			return mat
		push_warning("PlanetData: '%s' is not a Material" % mat_path)
	else:
		push_warning("PlanetData: road material not found: '%s'" % mat_path)
	_road_material_cache[mat_path] = null
	return null


# ---------------------------------------------------------------------------
# Detail texture array
# ---------------------------------------------------------------------------

## Ordered list of detail texture filenames (index = layer in Texture2DArray).
## Layer 0 is always "blank" (flat grey, no detail).
const DETAIL_TEXTURE_NAMES: Array[String] = [
	"detail_blank",    # 0
	"detail_sand",     # 1
	"detail_rock",     # 2
	"detail_grass",    # 3
	"detail_forest",   # 4
	"detail_snow",     # 5
	"detail_volcanic", # 6
	"detail_mud",      # 7
	"detail_regolith", # 8
	"detail_cracked",  # 9
	"detail_crystal",  # 10
	"detail_martian",  # 11
]

const DETAIL_TEXTURES_DIR := "res://assets/textures/planet/detail/"

## Map: biome_type → detail layer index (overrides category default).
const DETAIL_BY_BIOME: Dictionary = {
	# terrestrial — most varied category, needs per-biome mapping
	"maritime_river-ocean": 0, "maritime_river-lake": 0, "maritime_river-river": 0,  # liquid → no detail
	"volcanic_geothermal-lava_river": 0,          # lava material overlay
	"volcanic_geothermal-columnar_basalt_vertical": 2,  # rock
	"maritime_river-delta": 7,                     # mud
	"maritime_river-beach": 1, "aride_desert-sandy_desert": 1, "aride_desert-dusty_plain": 1,  # sand
	"aride_desert-rocky_desert": 2, "rocky_landform-cliff": 2, "rocky_landform-raw_mountain": 2, "rocky_landform-alpine_mountain": 2,
	"rocky_landform-canyon": 2, # rock
	"aride_desert-salt_desert": 9,                              # cracked
	"aride_desert-anhydrite_desert": 9,                          # cracked
	"aride_desert-valley_of_fire": 1,                             # sand
	"aride_desert-corundum_plateau": 2,                            # rock
	"aride_desert-corundum_sand_desert": 1,                        # sand
	"rocky_landform-arachnoide": 2,                                # rock
	"rocky_landform-perforated_limestone": 2,                     # rock
	"volcanic_geothermal-lava_dome": 2,                            # rock
	"volcanic_geothermal-pele_haire": 2,                          # rock
	"meadow_steppe-meadow": 3, "meadow_steppe-savanna": 3, "meadow_steppe-steppe": 3,    # grass
	"forest-temperate_forest": 4, "forest-boreal_forest": 4, "forest-tropical_forest": 4,
	"forest-dead_forest": 4, "wetland-mangrove": 4, # forest
	"wetland-swamp": 7, "wetland-bog": 7,                   # mud
	"icy-tundra": 8, "icy-permafrost": 8,
	"spatial-crater": 8, "spatial-lunar_ground": 8,  # lunar ground
	"icy-snow": 5, "icy-glacier": 5,                  # snow
	# cryo
	"icy-ice_plain": 5, "icy-ice_crevasse": 9, "icy-ice_pick": 5,
	"icy-nitrogen_ice": 5, "icy-frozen_ocean": 5, "icy-sublimation_pit": 9,
	"volcanic_geothermal-ice_geyser": 5, "icy-methane_lake": 0, "icy-hydrocarbon_dune": 1,
	"icy-cryovolcanic": 6,
	"icy-frozen_methane": 5,                                     # snow/ice
	# atmosphere
	"rocky_landform-pressure_canyon": 2,
	"liquid_hydrocarbon_areas": 0,
	# toxic
	"meadow_steppe-sulfur_plain": 11, "volcanic_geothermal-sulfur_volcano": 6, "maritime_river-acid_lake": 0,
	"wetland-ammonia_swamp": 7, "meadow_steppe-chlorinated_field": 9, "radioactive_waste": 8,
	"tar_basin": 0, "brine_basin": 0,
	# mineral
	"crystalline-crystalline_fields": 10, "aride_desert-metal_plain": 10, "rocky_landform-cave": 10,
	"crystalline-quartz_desert": 10, "volcanic_geothermal-mineral_thermal_source": 7, "crystalline-salt_crystal_field": 9,
	# artificial
	"meadow_steppe-terraformed_grass": 3, "forest-terraformed_forest": 4,
	"urban-mining_excavation": 2, "urban-ruins": 2, "urban-urban": 2,
	"meadow_steppe-agriculture_land": 3, "urban-landing_pad": 0,
	"meadow_steppe-wasteland_irradiated": 8,
	"rocky_landform-mining_cave": 5,
}

## Fallback: category → detail layer index (used when biome_type not in map).
const DETAIL_BY_CATEGORY: Dictionary = {
	"terrestrial": 2,   # rock
	"volcanic": 6,
	"barren": 8,        # lunar ground
	"cryo": 5,          # snow
	"martian": 11,
	"atmosphere": 0,    # blank
	"toxic": 7,         # mud
	"mineral": 10,      # crystal
	"artificial": 2,    # rock
}

## World-space tiling scales per detail layer (tuned for planet scale ~2 Mm).
## Smaller = coarser tiling, larger = finer tiling.
const DETAIL_SCALE: Array[float] = [
	0.0,     # 0 blank — no sampling
	0.002,   # 1 sand — medium-fine
	0.001,   # 2 rock — medium
	0.003,   # 3 grass — fine
	0.0015,  # 4 forest — medium
	0.0008,  # 5 snow — coarse (smooth)
	0.001,   # 6 volcanic — medium
	0.0012,  # 7 mud — medium
	0.0025,  # 8 lunar ground — medium-fine
	0.0008,  # 9 cracked — coarse
	0.002,   # 10 crystal — medium-fine
	0.0015,  # 11 martian — medium
]

## Cached Texture2DArray for the shader.
var _detail_texture_array: Texture2DArray = null
var _detail_array_built: bool = false


## Return the detail layer index for a given BiomeDefinition.
func get_detail_layer(bd: BiomeDefinition) -> int:
	if bd == null:
		return 0
	# Explicit per-biome mapping first.
	if DETAIL_BY_BIOME.has(bd.biome_type):
		return DETAIL_BY_BIOME[bd.biome_type]
	# Category fallback.
	if DETAIL_BY_CATEGORY.has(bd.category):
		return DETAIL_BY_CATEGORY[bd.category]
	return 0


## Return the tiling scale for a given detail layer index.
func get_detail_scale_for_layer(layer: int) -> float:
	if layer < 0 or layer >= DETAIL_SCALE.size():
		return 0.0
	return DETAIL_SCALE[layer]


## Build a Texture2DArray from the 12 detail PNGs and assign it to the
## terrain ShaderMaterial.  Called once lazily from get_detail_texture_array().
func _build_detail_texture_array() -> void:
	_detail_array_built = true

	var images: Array[Image] = []
	for tex_name in DETAIL_TEXTURE_NAMES:
		var path := DETAIL_TEXTURES_DIR + tex_name + ".png"
		var tex := ResourceLoader.load(path) as Texture2D
		if tex == null:
			push_warning("PlanetData: cannot load detail texture '%s'" % path)
			# Create a blank fallback image.
			var blank := Image.create(512, 512, false, Image.FORMAT_L8)
			blank.fill(Color(0.5, 0.5, 0.5))
			images.append(blank)
		else:
			var img := tex.get_image()
			if img == null:
				push_warning("PlanetData: get_image() returned null for '%s'" % path)
				var blank := Image.create(512, 512, false, Image.FORMAT_L8)
				blank.fill(Color(0.5, 0.5, 0.5))
				images.append(blank)
			else:
				# Ensure consistent format.
				if img.get_format() != Image.FORMAT_L8:
					img.convert(Image.FORMAT_L8)
				img.generate_mipmaps()
				images.append(img)

	_detail_texture_array = Texture2DArray.new()
	var err := _detail_texture_array.create_from_images(images)
	if err != OK:
		push_error("PlanetData: failed to create detail Texture2DArray (err=%d)" % err)
		_detail_texture_array = null
		return

	print("PlanetData: built detail Texture2DArray with %d layers (%dx%d)" % [
		images.size(),
		images[0].get_width() if images.size() > 0 else 0,
		images[0].get_height() if images.size() > 0 else 0])

	# Push the array into the terrain ShaderMaterial if it exists.
	_apply_detail_to_material()


## Push the detail Texture2DArray into terrain_material (if it is a ShaderMaterial).
func _apply_detail_to_material() -> void:
	if _detail_texture_array == null:
		return
	if terrain_material is ShaderMaterial:
		var sm := terrain_material as ShaderMaterial
		sm.set_shader_parameter("detail_textures", _detail_texture_array)


## Get (and lazily build) the detail texture array.
func get_detail_texture_array() -> Texture2DArray:
	if not _detail_array_built:
		_build_detail_texture_array()
	return _detail_texture_array
