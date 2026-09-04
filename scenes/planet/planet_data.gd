# gdlint: disable=max-public-methods
@tool
class_name PlanetData
extends Resource
# gdlint: disable=class-definitions-order
## Planet configuration resource.
## Stores radius, textures, LOD distances, and provides coordinate conversion
## between sphere surface and equirectangular UV (matching QGIS EPSG:4326).

const PlanetPackScript = preload("res://scenes/planet/planet_pack.gd")
const HeightPackScript = preload("res://scenes/planet/height_pack.gd")
const ModifierPackScript = preload("res://scenes/planet/modifier_pack.gd")

@export_group("General")
## for example "tarsis_3" correspond to the QGIS file name
@export var planet_name: String = ""
## Radius in meters (distance from center to sea-level surface).
var radius: float = 1000.0
## Maximum terrain elevation above sea-level radius, in meters.
var max_height: float = 1000.0
## Elevation offset in meters (negative when craters dig below sea-level).
var height_offset: float = 0.0
## DEBUG: counts height samples that fell back to the equirect global heightmap
## because the per-chunk .r32 tile was missing/unreadable AT SAMPLE TIME. A
## non-zero count at runtime means chunks are being built from the fallback map
## instead of the real elevation tiles → high plateaus collapse toward sea level
## (the tarsis_3 "terrain 3-6 km below the props" symptom).
var _height_fallback_hits: int = 0
## Vertical exaggeration applied to sampled elevation. Real planetary relief is
## ~0.1% of the radius (Earth-like) and reads as flat at true 1:1 scale; raise
## this (e.g. 3–8) to make terrain visually dramatic. Applies to both the visual
## mesh and collision, so they stay consistent. 1.0 = true scale.
@export var terrain_exaggeration: float = 1.0
## Physical atmosphere of this body (null = airless). Owns the shell thickness,
## the scattering coefficients and the star constants seen from here. Generated
## by addons/dyingstar/build_atmosphere_profiles.gd from the system JSON.
@export var atmosphere_profile: AtmosphereProfile = null
## Surface gravity in m/s² (Earth = 9.8).
@export var surface_gravity: float = 9.8
## Radius of the gravity influence zone above the surface, in meters.
## Independent of atmosphere: a moon with no atmosphere still has gravity here.
## Default 100 000 m (100 km). Gravity falls off with inverse-square law beyond the surface.
@export var gravity_reach: float = 100000.0

## Optional path to the planet JSON file exported from QGIS
## (e.g. "assets/qgis/export/tarsis_3/planet.json").
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
## Total export tiles = 12 × nside². This is the FINEST pyramid level (nside_max).
var export_nside: int = 32
## Coarsest baked pyramid level (nside_min). When a chunk is coarser than
## export_nside, it reads the tile at its own nside from n{nside}/ instead of
## point-sampling many nside_max tiles. == export_nside for legacy single-level
## (flat-layout) exports, so those behave exactly as before.
var export_nside_min: int = 0
## True when the chunk dir is a pyramid (n{nside}/face_{face}/f{ipix}.r32).
## False for legacy flat layout (face_{face}/f{ipix}.r32).
var chunk_is_pyramid: bool = false
## Fingerprint of the exported elevation data, from manifest["data_version"]
## (tools/qgis/export_elevation.py compute_data_version). PlanetTerrain folds it
## into its chunk disk-cache key so a re-export automatically invalidates cached
## meshes and collision shapes: radius / max_height / height_offset / tile_res can
## all stay identical while every elevation changes, which used to leave the cache
## reporting "valid" and serving pre-export terrain. Empty for manifests written
## before the field existed — those keep exactly the key they had, so caches for
## planets that have not been re-exported stay valid.
var chunk_data_version: String = ""
## Equirectangular heightmap — kept as fallback only (editor preview, etc.).
@export var heightmap: Texture2D
## Equirectangular biome map — colour encodes biome type / vegetation.
@export var biomemap: Texture2D

## Taxonomy family for footsteps and impacts on this body's bare ground — one of the "family" values
## in tools/schema/tags.json ("sand", "rock", "ice"…).
##
## Needed because a biome cannot answer for most of a planet: populate zones are SPARSE by design,
## they say where things are placed rather than covering the surface, and no planet ships a biomemap.
## Outside a zone, sample_biome_at() itself falls through to a hardcoded colour. So the honest answer
## for open ground is a per-body default, stated once here, rather than a guess made per step.
## A biome that does cover the ground still wins (see BiomeDefinition.surface_family).
@export var surface_family: String = ""
## Equirectangular colour map that was the ultra-far LOD sphere's albedo. The sphere is removed, so this
## is currently unused — kept as an @export so existing scenes don't churn (may feed a future far map).
@export var colormap: Texture2D

@export_group("LOD Distances")
## Distance thresholds from the planet surface (in meters) for each LOD tier.
@export var lod0_distance: float = 5000.0
@export var lod1_distance: float = 50000.0
@export var lod2_distance: float = 200000.0
## NOTE: unused since get_lod_level() caps the tier at 3 (the far-LOD placeholder sphere is removed —
## distant bodies render their coarse LOD-3 chunks at every distance, star-lit on the celestial layer).
## Kept for scene compatibility and in case the sphere hand-off is ever re-enabled.
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

@export_group("Corundum override")
## TEMPORARY whole-planet switch for the "milky corundum with iron" look +
## procedural blocky crack network.  When true, every chunk is rendered with
## the aride_desert-corundum_plateau material (and, once Phase 2 lands, carved
## with the crack network) regardless of its actual biome.  Later this can be
## turned OFF and the same logic driven by the QGIS corundum_plateau biome
## polygon instead — no code change, just flip this flag.
@export var corundum_override_whole_planet: bool = false
## Approximate size of a monolithic block between cracks, in metres.
@export var crack_spacing_m: float = 90.0
## Width of each carved crack at the surface, in metres.
@export var crack_width_m: float = 14.0
## Depth each crack is carved below the plateau surface, in metres.
@export var crack_depth_m: float = 22.0
## DEBUG: paint chunk skirt curtains bright magenta to distinguish them from
## real terrain / crack interiors when diagnosing dark-band artifacts.
@export var debug_color_skirts: bool = false

## Directory of per-chunk elevation data exported by tools/qgis/export_elevation.py.
## When non-empty, load_chunk_heightmap() reads raw float32 tiles from the dense
## heights.pack archive inside this dir instead of generating heightmaps from
## recipes. Path is relative to res://, e.g. "assets/qgis/export/tarsis_5_chunks".
@export var chunk_heightmaps_dir: String = ""
## Samples per edge of each exported .r32 tile (matches TILE_RES in the exporter).
@export var chunk_heightmap_res: int = 25
## Read roads, craters, rivers, caves and biome zones from
## <chunk_heightmaps_dir>/terrainmodifier.pack. Turn off to fall back to the
## legacy roads_geojson/BiomeQuery path — an A/B switch for comparing the two.
@export var use_modifier_pack: bool = true

@export_group("Roads")
## Path to a GeoJSON file with road polygons (buffered from LineStrings).
## Exported by the QGIS pipeline as {planet}_roads_buffered.json.
## When provided, road overlays are rendered on terrain chunks.
## Path is relative to res://, e.g. "assets/qgis/.export/tarsis_3_roads_buffered.json".
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
## Path is relative to res://, e.g. "assets/qgis/export/tarsis_3/biomes.geojson".
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
## Serialises get_road_material_cached(): mesh generation runs on
## WorkerThreadPool tasks and several can want the same material at once.
var _road_material_mutex: Mutex = Mutex.new()

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

## ── Height pack (dense .r32 tile archive) ────────────────────────
## All pyramid elevation tiles of chunk_heightmaps_dir packed into a single
## heights.pack file (written by tools/qgis/export_elevation.py). This is the
## ONLY source of elevation tiles: O(1) arithmetic offsets, per-thread read
## handles (lock-free from WorkerThreadPool tasks) and coarse levels
## preloaded in RAM.
var _height_pack = null  # HeightPackScript instance
var _height_pack_tried: bool = false
var _height_pack_mutex: Mutex = Mutex.new()

## ── Modifier pack (sparse per-chunk vector archive) ──────────────
## terrainmodifier.pack: roads, craters, linear features, radial features and
## biome populate zones, already clipped to their HEALPix tile and decimated
## per LOD level (written by tools/qgis/link_modifiers.py from the per-kind
## parts each exporter produces).
##
## Roads in particular are PARTITIONED across tiles, so a chunk draws only its
## own stretch. Before this, every chunk whose bbox touched a road re-extruded
## the whole centerline, and neighbouring chunks at different LODs sampled
## height at different pyramid levels — which is how one road ended up rendered
## twice, ~2 m apart.
var _modifier_pack = null  # ModifierPackScript instance
var _modifier_pack_tried: bool = false
var _modifier_pack_mutex: Mutex = Mutex.new()

## Decoded modifier tiles, keyed "mp_nN_pP". Kept separate from _chunk_images so
## road/feature reads never contend with heightmap reads on the same mutex.
var _modifier_tiles: Dictionary = {}
var _modifier_order: Array[String] = []
var _modifier_bytes: int = 0
var _modifier_mutex: Mutex = Mutex.new()
const MAX_MODIFIER_CACHE_BYTES: int = 64 * 1024 * 1024
## Rough Variant overhead of a decoded tile over its packed payload. Estimating
## from the payload size is far cheaper and more stable than trying to measure
## Dictionary/Array memory.
const MODIFIER_DECODE_BLOAT: int = 6

## Runtime feature injections (Horizon biome updates). The pack is immutable and
## decoded tiles are LRU-evicted, so an injection cannot be written into them —
## it would vanish on the next eviction. It lives here instead and is applied on
## every read. Entries: {kind_key, biome_type, bbox_min, bbox_max, record}.
var _mod_overlay_add: Array[Dictionary] = []
var _mod_overlay_remove: Array[Dictionary] = []
var _mod_overlay_mutex: Mutex = Mutex.new()

## Where the roads fly over a procedural chasm (see RoadBridge). Computed once
## per planet by walking the roads against the crack field — deterministic, so
## the client and the server agree without replicating anything.
var _bridge_spans: Array = []
var _bridge_spans_built: bool = false
var _bridge_spans_mutex: Mutex = Mutex.new()

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


## Altitude of the top of the atmosphere above the surface, in meters, or 0 for an
## airless body. Single reader of the profile's shell thickness, so nothing else
## has to know whether this body carries a profile at all.
func get_atmosphere_top() -> float:
	if atmosphere_profile == null:
		return 0.0
	return atmosphere_profile.atmosphere_top


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
		# planet.json is the retired per-planet metadata file. Its terrain values
		# (radius / height range / nside / tile_res) now live in the chunk
		# manifest.json, applied by apply_chunk_manifest() right after this call;
		# the rest (lod distances, has_ocean, geojson paths) come from the .tscn
		# PlanetData resource. A missing file is therefore the normal case — return
		# quietly. (A present-but-broken file still warns below.)
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
## Pyramid level a chunk of [param hp_nside] should sample: its own nside,
## clamped to the baked range [nside_min, nside_max]. For non-pyramid (legacy
## flat) exports this collapses to export_nside, preserving old behavior.
func sample_nside_for(hp_nside: int) -> int:
	if not chunk_is_pyramid:
		return export_nside
	return clampi(hp_nside, export_nside_min, export_nside)


## Load the .r32 tile (ipix) at pyramid level [param nside]. nside <= 0 means
## "finest" (export_nside), which is what every legacy caller gets by default.
func load_chunk_heightmap(ipix: int, nside: int = -1) -> Image:
	var ns := nside if nside > 0 else export_nside
	var key := "hp_n%d_p%d" % [ns, ipix]
	# Server fast path: cache is read-only after preload, skip mutex + LRU.
	if _server_no_evict:
		var cached := _chunk_images.get(key) as Image
		if cached != null:
			return cached
		# File mode: lazily load the exported tile (thread-safe via mutex).
		if chunk_heightmaps_dir != "":
			return _file_load_and_cache(key, ipix, ns)
		return null
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
	# File mode: load the per-chunk elevation tile (.r32) directly from disk.
	if chunk_heightmaps_dir != "":
		return _file_load_and_cache(key, ipix, ns)
	# Not cached yet — return null so callers fall back to global heightmap.
	# The async recipe pipeline in PlanetTerrain will generate and cache it.
	return null


## Load a per-chunk elevation tile (.r32) and insert it into the image cache.
## Thread-safe; safe to call from WorkerThreadPool mesh/collision tasks.
## Returns null if the tile is missing/malformed (caller falls back to global).
func _file_load_and_cache(key: String, ipix: int, nside: int) -> Image:
	var img := _read_r32_tile(ipix, nside)
	if img == null:
		return null
	_cache_mutex.lock()
	# Another thread may have loaded the same tile while we read from disk.
	if _chunk_images.has(key):
		var existing := _chunk_images[key] as Image
		_cache_mutex.unlock()
		return existing
	_chunk_images[key] = img
	_cache_order.append(key)
	_cache_bytes += img.get_width() * img.get_height() * 4
	_cache_mutex.unlock()
	if not _server_no_evict:
		_evict_lru()
	return img


## The chunk manifest, as applied by apply_chunk_manifest(). Kept so the pack
## openers can honour the file-name fields it carries.
var _chunk_manifest: Dictionary = {}
var _loose_manifest_tried: bool = false
var _loose_manifest_cache: Dictionary = {}


## The LOOSE manifest.json, read at most once.
##
## Separate from _chunk_manifest because of an ordering knot: heights.pack
## embeds a copy of the manifest and is opened BEFORE apply_chunk_manifest()
## parses it (that copy is the fallback when the loose file is missing). So the
## name of the pack cannot come from the embedded manifest — that would require
## opening the pack to learn what to open. Only the loose file can break the
## cycle; without it the default name is the only way to bootstrap.
func _loose_manifest() -> Dictionary:
	if _loose_manifest_tried:
		return _loose_manifest_cache
	_loose_manifest_tried = true
	var path := _chunk_base_path() + "/manifest.json"
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			_loose_manifest_cache = parsed
	return _loose_manifest_cache


## Name of a pack file declared by the manifest, or [param fallback].
func _manifest_file(key: String, fallback: String) -> String:
	var name: String = _chunk_manifest.get(key, "")
	if name == "":
		name = _loose_manifest().get(key, "")
	return name if name != "" else fallback


## chunk_heightmaps_dir resolved to an absolute res://-style base path.
func _chunk_base_path() -> String:
	var base := chunk_heightmaps_dir
	if not base.begins_with("res://") and not base.begins_with("user://") \
			and not base.begins_with("/"):
		base = "res://" + base
	return base


## Open chunk_heightmaps_dir/heights.pack once (thread-safe, idempotent).
## Returns the open pack or null when the planet ships loose tiles instead.
## apply_chunk_manifest() calls this on the main thread so worker tasks
## normally find the pack already open.
func _ensure_height_pack():
	if _height_pack_tried:
		return _height_pack
	_height_pack_mutex.lock()
	if not _height_pack_tried:
		var pack = HeightPackScript.new()
		# Honour manifest["pack_file"] instead of hardcoding the name, so a
		# planet can ship a differently-named archive. The field was written by
		# the exporter and silently ignored here for a long time.
		var path := _chunk_base_path() + "/" + _manifest_file(
				"pack_file", "heights.pack")
		if FileAccess.file_exists(path) and pack.open(path):
			_height_pack = pack
			print("[PlanetData] heights.pack opened: %s" % path)
		_height_pack_tried = true
	_height_pack_mutex.unlock()
	return _height_pack


## Open chunk_heightmaps_dir/terrainmodifier.pack once (thread-safe, idempotent).
## Returns the open pack, or null when the planet has no modifier data — in
## which case every accessor below degrades to the pre-pack behaviour.
func _ensure_modifier_pack():
	if _modifier_pack_tried:
		return _modifier_pack
	_modifier_pack_mutex.lock()
	if not _modifier_pack_tried:
		_modifier_pack_tried = true
		if use_modifier_pack and chunk_heightmaps_dir != "":
			var pack = ModifierPackScript.new()
			var path := _chunk_base_path() + "/" + _manifest_file(
					"modifiers_file", "terrainmodifier.pack")
			if not FileAccess.file_exists(path):
				push_warning("[PlanetData] no terrainmodifier.pack at %s — " % path
						+ "roads, craters, rivers and biome overlays will be "
						+ "absent. Produce it with tools/qgis/export_roads.py "
						+ "(and the other export_*.py), which relink it.")
			elif pack.open(path):
				_modifier_pack = pack
				var caps: Dictionary = pack.get_manifest().get("kind_max_nside", {})
				var road_cap := int(caps.get("road", 0))
				var quadtree_nside := 1 << max_quadtree_depth
				# The invariant the partitioning rests on: chunks finer than the
				# deepest baked road level would share an ancestor tile, and a
				# shared tile means two chunks extruding the same road.
				if road_cap > 0 and road_cap < quadtree_nside:
					push_warning("[PlanetData] %s bakes roads only to n%d but "
							% [path, road_cap]
							+ "max_quadtree_depth=%d needs n%d — deep chunks will "
							% [max_quadtree_depth, quadtree_nside]
							+ "clip at runtime. Re-export roads.")
				print("[PlanetData] terrainmodifier.pack opened: %s (levels %s)"
						% [path, str(pack.get_levels())])
	_modifier_pack_mutex.unlock()
	return _modifier_pack


## The open modifier pack, or null when this planet has none.
func get_modifier_pack():
	return _ensure_modifier_pack()


## Deepest baked nside for [param kind] (a ModifierPack.KIND_* constant).
## Falls back to export_nside so callers behave sanely without a pack.
func modifier_max_nside_for(kind: int) -> int:
	var pack = _ensure_modifier_pack()
	if pack == null:
		return export_nside
	var cap: int = pack.max_nside_for_kind(kind)
	return cap if cap > 0 else export_nside


## Decoded modifier tile for [param ipix] at pyramid level [param nside].
## Returns {} when the pack is absent or the tile holds nothing.
##
## Follows _file_load_and_cache()'s pattern: check the cache under the lock,
## DECODE OUTSIDE IT (decoding is the expensive part and decode_tile() is pure),
## then re-check and insert — another worker thread may have decoded the same
## tile meanwhile.
func get_chunk_modifiers(nside: int, ipix: int) -> Dictionary:
	var pack = _ensure_modifier_pack()
	if pack == null:
		return {}
	var key := "mp_n%d_p%d" % [nside, ipix]
	_modifier_mutex.lock()
	var hit: Variant = _modifier_tiles.get(key)
	if hit != null:
		if not _server_no_evict:
			var idx := _modifier_order.find(key)
			if idx >= 0:
				_modifier_order.remove_at(idx)
			_modifier_order.append(key)
		_modifier_mutex.unlock()
		return hit
	_modifier_mutex.unlock()

	var raw: PackedByteArray = pack.read_tile(nside, ipix)
	if raw.is_empty():
		return {}
	var decoded: Dictionary = pack.decode_tile(raw, radius * PI / 180.0)

	_modifier_mutex.lock()
	var again: Variant = _modifier_tiles.get(key)
	if again != null:
		_modifier_mutex.unlock()
		return again
	_modifier_tiles[key] = decoded
	_modifier_order.append(key)
	_modifier_bytes += int(decoded.get("_raw_bytes", 0)) * MODIFIER_DECODE_BLOAT
	_modifier_mutex.unlock()
	if not _server_no_evict:
		_evict_modifier_lru()
	return decoded


func _evict_modifier_lru() -> void:
	if _server_no_evict:
		return
	_modifier_mutex.lock()
	while _modifier_bytes > MAX_MODIFIER_CACHE_BYTES and not _modifier_order.is_empty():
		var oldest: String = _modifier_order[0]
		_modifier_order.remove_at(0)
		var gone: Variant = _modifier_tiles.get(oldest)
		if gone != null:
			_modifier_bytes -= int((gone as Dictionary).get("_raw_bytes", 0)) \
					* MODIFIER_DECODE_BLOAT
			_modifier_tiles.erase(oldest)
	if _modifier_bytes < 0:
		_modifier_bytes = 0
	_modifier_mutex.unlock()


func clear_modifier_cache() -> void:
	_modifier_mutex.lock()
	_modifier_tiles.clear()
	_modifier_order.clear()
	_modifier_bytes = 0
	_modifier_mutex.unlock()


## Read and decode a raw float32 (.r32) tile for [param ipix] into a FORMAT_RF
## Image. Tiles are normalized [0,1]; sample_height_for_direction() converts the
## sample to metres via height_offset + value*max_height.
## Tiles are read exclusively from heights.pack (O(1) offset, per-thread
## handles) — there is no loose-file fallback; a planet without a pack has no
## elevation tiles and callers fall back to the global heightmap.
func _read_r32_tile(ipix: int, nside: int = -1) -> Image:
	var ns := nside if nside > 0 else export_nside
	var res := chunk_heightmap_res
	var expected := res * res * 4
	var pack = _ensure_height_pack()
	if pack == null:
		return null
	var bytes: PackedByteArray = pack.read_tile(ns, ipix)
	if bytes.is_empty():
		return null
	if bytes.size() != expected:
		if not _chunk_format_logged:
			push_warning("[PlanetData] r32 tile n%d/f%d: size %d != expected %d (res=%d)"
					% [ns, ipix, bytes.size(), expected, res])
			_chunk_format_logged = true
		return null
	return Image.create_from_data(res, res, false, Image.FORMAT_RF, bytes)


## Load chunk_heightmaps_dir/manifest.json (written by export_elevation.py) and
## apply radius, export N_side, tile resolution, and the height normalization
## range (height_offset / max_height) so they match the exporter exactly.
## Call once after chunk_heightmaps_dir is set (PlanetTerrain.initialize does).
## Returns true on success; false if file-mode is off or the manifest is missing.
func apply_chunk_manifest() -> bool:
	if chunk_heightmaps_dir == "":
		return false
	# Open heights.pack now (main thread) so WorkerThreadPool tasks never pay
	# the open cost, and so the embedded manifest can replace a missing
	# manifest.json (packed exports may ship the single .pack file only).
	var pack = _ensure_height_pack()
	if pack == null:
		# No pack = no elevation tiles at all (there is no loose-file
		# fallback) — every height sample will hit the global heightmap.
		push_warning("[PlanetData] heights.pack missing in %s — planet has no "
				% _chunk_base_path()
				+ "elevation tiles (re-run tools/qgis/export_elevation.py)")
	var path := _chunk_base_path() + "/manifest.json"
	var data: Variant
	if FileAccess.file_exists(path):
		data = JSON.parse_string(FileAccess.get_file_as_string(path))
	elif pack != null:
		data = pack.get_manifest()
		path = "heights.pack (embedded)"
	else:
		push_warning("[PlanetData] chunk manifest not found: %s" % path)
		return false
	if typeof(data) != TYPE_DICTIONARY or (data as Dictionary).is_empty():
		push_warning("[PlanetData] invalid chunk manifest: %s" % path)
		return false
	_chunk_manifest = data
	if data.has("radius"):
		radius = float(data["radius"])
	if data.has("chunk_export_depth"):
		chunk_export_depth = int(data["chunk_export_depth"])  # setter sets export_nside
	elif data.has("nside"):
		export_nside = int(data["nside"])
	if data.has("nside_max"):
		export_nside = int(data["nside_max"])
	if data.has("tile_res"):
		chunk_heightmap_res = int(data["tile_res"])
	if data.has("height_offset"):
		height_offset = float(data["height_offset"])
	if data.has("max_height"):
		max_height = float(data["max_height"])
	# Pyramid descriptor. Legacy flat exports omit these → single level, so the
	# coarsest level equals the finest (clamp is a no-op) and paths stay flat.
	chunk_is_pyramid = bool(data.get("pyramid", false))
	chunk_data_version = str(data.get("data_version", ""))
	if data.has("nside_min"):
		export_nside_min = int(data["nside_min"])
	else:
		export_nside_min = export_nside
	print("[PlanetData] chunk manifest applied: radius=%.0f export_nside=%d "
			% [radius, export_nside]
			+ "nside_min=%d pyramid=%s tile_res=%d height_offset=%.1f max_height=%.1f"
			% [export_nside_min, chunk_is_pyramid, chunk_heightmap_res, height_offset, max_height]
			+ " data_version=%s" % ("(none)" if chunk_data_version == "" else chunk_data_version))
	return true


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
			_overlay_add(ipix, "linear_features", feature)
		elif geom_type == "polygon" or geom_type == "point":
			# Add as a populate zone.
			var verts: Array = geometry.get("vertices", [])
			# "partial", not "polygon": PlanetChunk._dir_in_populate_zone() only
			# special-cases "full" and "point", and every recipe/pack producer
			# writes "partial" for an outlined zone.
			var zone := {
				"biome_type": biome_type,
				"coverage": "point" if geom_type == "point" else "partial",
			}
			if geom_type == "point" and verts.size() >= 1:
				zone["lon"] = verts[0][0] if verts[0] is Array else verts[0].x
				zone["lat"] = verts[0][1] if verts[0] is Array else verts[0].y
			elif verts.size() >= 3:
				# Write BOTH outline keys. Consumers are split: the per-vertex
				# containment test and the recipe/pack exports use `vertices`
				# (Array of [lon, lat]), older cliff code read `polygon`
				# (PackedVector2Array). Writing only `polygon` made injected
				# zones invisible to _dir_in_populate_zone() entirely.
				var packed := PackedVector2Array()
				packed.resize(verts.size())
				var norm: Array = []
				norm.resize(verts.size())
				for i in verts.size():
					var v = verts[i]
					var lon_v: float = float(v[0]) if v is Array else float(v.x)
					var lat_v: float = float(v[1]) if v is Array else float(v.y)
					packed[i] = Vector2(lon_v, lat_v)
					norm[i] = [lon_v, lat_v]
				zone["vertices"] = norm
				zone["polygon"] = packed
			if not _chunk_populate_zones.has(key):
				_chunk_populate_zones[key] = []
			_chunk_populate_zones[key].append(zone)
			_overlay_add(ipix, "populate_zones", zone)

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
		_overlay_remove(ipix, "populate_zones", "biome_type", biome_type)
		_overlay_remove(ipix, "linear_features", "type", biome_type)


## Record a runtime injection so it survives modifier-tile LRU eviction.
##
## The pack is immutable and get_chunk_modifiers() hands out cached decoded
## tiles that are evicted under memory pressure, so writing an injection into
## one would make it disappear at an arbitrary later moment. The overlay is
## consulted on every read instead, and holds only Horizon-driven updates.
func _overlay_add(ipix: int, list_key: String, record: Dictionary) -> void:
	_mod_overlay_mutex.lock()
	_mod_overlay_add.append({
		"ipix": ipix, "list_key": list_key, "record": record,
	})
	_mod_overlay_mutex.unlock()


func _overlay_remove(ipix: int, list_key: String, type_key: String,
		biome_type: String) -> void:
	if biome_type == "":
		return
	_mod_overlay_mutex.lock()
	# Drop any pending add of the same type first, so add-then-remove nets out
	# instead of leaving a record the remove filter has to chase forever.
	var kept: Array[Dictionary] = []
	for a in _mod_overlay_add:
		if int(a["ipix"]) == ipix and a["list_key"] == list_key \
				and (a["record"] as Dictionary).get(type_key, "") == biome_type:
			continue
		kept.append(a)
	_mod_overlay_add = kept
	_mod_overlay_remove.append({
		"ipix": ipix, "list_key": list_key,
		"type_key": type_key, "biome_type": biome_type,
	})
	_mod_overlay_mutex.unlock()


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
	# File mode (.r32 chunk tiles) has no .planetpack — the recipe/pack pipeline is
	# retired for these planets (heightmaps come from chunk_heightmaps_dir). Short-
	# circuit so callers (recipe loads, the safety-mesh reader) get a clean null
	# instead of attempting to open a file that isn't produced anymore, which spams
	# "PlanetPack: cannot open ... (err 7)" + "failed to open planet pack" every run.
	if chunk_heightmaps_dir != "":
		return null
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


## Modifier records of one kind for an export-level chunk: the pack's tile,
## plus runtime injections, minus runtime removals.
##
## Falls back to the legacy recipe caches when there is no pack, so every
## existing caller keeps working on a planet that has not been re-exported.
func _modifiers_of(ipix: int, list_key: String, legacy: Dictionary) -> Array:
	if _ensure_modifier_pack() == null:
		# No pack: the legacy caches ARE mutable, so inject_biome_feature() has
		# already written into them. Applying the overlay too would return every
		# injected feature twice.
		return legacy.get("hp_n%d_p%d" % [export_nside, ipix], [])
	return _apply_overlay(
		get_chunk_modifiers(export_nside, ipix).get(list_key, []), list_key, ipix)


## Apply the runtime injection overlay to [param base].
## Cheap by construction: the overlay only holds Horizon-driven injections, so
## it is empty in the overwhelmingly common case and this is one is_empty().
func _apply_overlay(base: Array, list_key: String, ipix: int) -> Array:
	_mod_overlay_mutex.lock()
	var has_add := not _mod_overlay_add.is_empty()
	var has_remove := not _mod_overlay_remove.is_empty()
	if not has_add and not has_remove:
		_mod_overlay_mutex.unlock()
		return base
	var adds := _mod_overlay_add.duplicate()
	var removes := _mod_overlay_remove.duplicate()
	_mod_overlay_mutex.unlock()

	var out: Array = []
	for rec in base:
		var drop := false
		for r in removes:
			if r["list_key"] == list_key and int(r["ipix"]) == ipix \
					and (rec as Dictionary).get(r["type_key"], "") == r["biome_type"]:
				drop = true
				break
		if not drop:
			out.append(rec)
	for a in adds:
		if a["list_key"] == list_key and int(a["ipix"]) == ipix:
			out.append(a["record"])
	return out


## Return the crater list for an export-level chunk.
##
## The 8-neighbour merge below only exists for RECIPE-sourced craters, whose
## export assigned each crater to a single chunk by an equirectangular AABB test
## that misses HEALPix face boundaries and high latitudes. The modifier pack has
## no such gap: tools/qgis/export/planet/modifier_geom.py writes a crater into
## every tile its influence radius reaches, so a pack-sourced list is already
## complete and the merge is skipped.
func get_chunk_craters(ipix: int) -> Array:
	if _ensure_modifier_pack() != null:
		return _modifiers_of(ipix, "craters", _chunk_craters)
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
	return _modifiers_of(ipix, "populate_zones", _chunk_populate_zones)


## Return all populate zones across every loaded export chunk, flattened.
func get_all_populate_zones() -> Array:
	var result: Array = []
	for zones in _chunk_populate_zones.values():
		result.append_array(zones)
	return result


## Return cached linear features for an export-level chunk.
## Each entry has: type, centerline, width_start_m, width_end_m, profile, etc.
func get_chunk_linear_features(ipix: int) -> Array:
	return _modifiers_of(ipix, "linear_features", _chunk_linear_features)


## Return cached radial features for an export-level chunk.
## Each entry has: type, lon, lat, radius_m, depth_m, profile.
func get_chunk_radial_features(ipix: int) -> Array:
	return _modifiers_of(ipix, "radial_features", _chunk_radial_features)


## Road records for a chunk, at the level [param nside] (roads are baked all the
## way down to the quadtree depth, unlike the other kinds which stop at
## export_nside). Each record is already clipped to this tile.
func get_chunk_roads(nside: int, ipix: int) -> Array:
	return get_chunk_modifiers(nside, ipix).get("roads", [])


## Every road on the planet, stitched back into WHOLE features.
##
## Read from the pack's COARSEST level, where one record normally covers an
## entire road: bridge detection must see a whole road, because a chasm span can
## be longer than a fine tile and a clipped record would report a truncated gap.
## Roads survive decimation almost intact at every level (the tolerance is
## clamped to half the road's own width, ~1.5 m), so the coarse copy is faithful.
##
## Pieces sharing a feature_id are concatenated in along-road order, which the
## absolute `_cum_lengths` make unambiguous.
func get_whole_roads() -> Array:
	var pack = _ensure_modifier_pack()
	if pack == null:
		return []
	var levels: PackedInt64Array = pack.get_levels()
	if levels.is_empty():
		return []
	var nside := int(levels[0])
	var by_feature: Dictionary = {}
	for ipix in pack.get_tile_ipix(nside):
		for r in get_chunk_roads(nside, int(ipix)):
			var fid: int = int(r.get("feature_id", -1))
			if not by_feature.has(fid):
				by_feature[fid] = []
			by_feature[fid].append(r)

	var out: Array = []
	for fid in by_feature:
		var pieces: Array = by_feature[fid]
		if pieces.size() == 1:
			out.append(pieces[0])
			continue
		pieces.sort_custom(func(a, b):
			return float((a["_cum_lengths"] as PackedFloat64Array)[0]) \
					< float((b["_cum_lengths"] as PackedFloat64Array)[0]))
		var cl := PackedVector2Array()
		var cum := PackedFloat64Array()
		for p in pieces:
			var pcl: PackedVector2Array = p["centerline"]
			var pcum: PackedFloat64Array = p["_cum_lengths"]
			for i in pcl.size():
				# Skip a duplicated joint vertex where two pieces meet.
				if cum.size() > 0 and absf(pcum[i] - cum[cum.size() - 1]) < 1e-6:
					continue
				cl.append(pcl[i])
				cum.append(pcum[i])
		var merged: Dictionary = (pieces[0] as Dictionary).duplicate()
		merged["centerline"] = cl
		merged["_cum_lengths"] = cum
		out.append(merged)
	return out


## Every chasm span the roads fly over, computed once and memoised.
##
## Deterministic: a pure walk of the roads against the procedural crack field,
## so the client and the server produce identical spans with no replication.
## See RoadBridge for why this cannot be baked at export time.
func get_bridge_spans() -> Array:
	if _bridge_spans_built:
		return _bridge_spans
	_bridge_spans_mutex.lock()
	if not _bridge_spans_built:
		var spans := RoadBridge.find_all_spans(self, get_whole_roads())
		_bridge_spans = spans
		_bridge_spans_built = true
		if not spans.is_empty():
			var truncated := 0
			for s in spans:
				if s.get("truncated", false):
					truncated += 1
			print("[PlanetData] %d road/chasm crossing(s) found on '%s'"
					% [spans.size(), planet_name]
					+ (" — %d too oblique for a bridge" % truncated if truncated else ""))
	_bridge_spans_mutex.unlock()
	return _bridge_spans


func clear_bridge_spans() -> void:
	_bridge_spans_mutex.lock()
	_bridge_spans.clear()
	_bridge_spans_built = false
	_bridge_spans_mutex.unlock()


## Road records for the HEALPix chunk (hp_nside, hp_ipix), resolving the pyramid
## level for you. Empty when the planet has no pack.
##
## Roads are baked down to the quadtree depth so a chunk normally gets its own
## tile and the records are exactly its stretch. A chunk finer than the deepest
## baked level falls back to the ancestor tile, whose pieces reach beyond this
## chunk — callers that emit geometry must clip; callers that test a point
## (prop spawners) do not care.
func get_roads_for_chunk(hp_nside: int, hp_ipix: int) -> Array:
	if hp_nside <= 0 or _ensure_modifier_pack() == null:
		return []
	var cap := modifier_max_nside_for(ModifierPackScript.KIND_ROAD)
	var nside: int = clampi(hp_nside, 1, cap)
	var ipix := hp_ipix
	var cur := hp_nside
	while cur > nside:
		ipix = HEALPix.parent_pixel(ipix)
		cur /= 2
	return get_chunk_roads(nside, ipix)


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
		_cached_neighbors = null, nside: int = -1) -> float:
	# nside <= 0 → finest level (export_nside). Chunk builders pass the chunk's
	# own pyramid level so a coarse chunk reads its coarse tile, not many fine ones.
	var ns := nside if nside > 0 else export_nside
	var ipix: int
	if known_export_ipix >= 0:
		ipix = known_export_ipix
	else:
		ipix = HEALPix.vec2pix_nest(ns, dir)
	var img := load_chunk_heightmap(ipix, ns)
	if img == null:
		# DEBUG: the per-chunk tile is not available at sample time — this vertex
		# gets its elevation from the equirect global map, which is a different
		# (usually flatter) surface. If this fires while building the plateau
		# chunks, that is why the runtime terrain sits kilometres below the props.
		_height_fallback_hits += 1
		if _height_fallback_hits <= 8 or _height_fallback_hits % 4096 == 0:
			print("[PlanetData][DBG] height fallback → equirect map: export_ipix=%d hits=%d (per-chunk .r32 missing/unreadable at sample time)" % [
				ipix, _height_fallback_hits])
		return sample_height_at(dir)

	# Get local UV within the pixel
	var local_uv := _direction_to_pixel_uv(dir, ipix, ns,
			_precomp_face, _precomp_xy)
	var h := _sample_image_bilinear_healpix(img, local_uv.x, local_uv.y, ipix,
			_cached_neighbors, ns)
	return (h * max_height + height_offset) * terrain_exaggeration


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
		_cached_neighbors = null, nside: int = -1) -> float:
	var ns := nside if nside > 0 else export_nside
	var vec_ipix := HEALPix.vec2pix_nest(ns, dir)
	if vec_ipix == chain_ipix:
		return sample_height_for_direction(dir, chain_ipix,
				_precomp_face, _precomp_xy, _cached_neighbors, ns)
	# Prefer the canonical tile (vec_ipix) when loaded — it is symmetric:
	# both sides of the boundary resolve to the same tile via vec2pix_nest.
	if load_chunk_heightmap(vec_ipix, ns) != null:
		return sample_height_for_direction(dir, vec_ipix, -1, Vector2i(-1, -1), null, ns)
	# Canonical tile not loaded — fall back to chain_ipix's tile (known-loaded).
	# UV is clamped to [0,1] by _direction_to_pixel_uv, so the edge pixels are
	# used rather than the catastrophic 0.0m from a missing global heightmap.
	return sample_height_for_direction(dir, chain_ipix,
			_precomp_face, _precomp_xy, _cached_neighbors, ns)


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
		ipix: int, _cached_neighbors = null, nside: int = -1) -> float:
	var ns := nside if nside > 0 else export_nside
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
		var v00 := _get_pixel_healpix(img, x0, y0, w, h, ipix, _cached_neighbors, ns)
		var v10 := _get_pixel_healpix(img, x1, y0, w, h, ipix, _cached_neighbors, ns)
		var v01 := _get_pixel_healpix(img, x0, y1, w, h, ipix, _cached_neighbors, ns)
		var v11 := _get_pixel_healpix(img, x1, y1, w, h, ipix, _cached_neighbors, ns)
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
		neighbors = HEALPix.get_neighbors_nest(ns, ipix)

	# Horizontal blend (left or right neighbour).
	if near_left and neighbors.has("W") and neighbors["W"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["W"], ns)
		if nb_img and nb_img.get_width() == w:
			var nb_u := (float(w) + fpx) / float(w)
			var nb_val := _sample_image_bilinear(nb_img, nb_u, v_norm)
			var t := clampf(1.0 - (fpx + 0.5) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)
	elif near_right and neighbors.has("E") and neighbors["E"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["E"], ns)
		if nb_img and nb_img.get_width() == w:
			var nb_u := clampf((fpx - float(w) + 0.5) / float(w), 0.0, 1.0)
			var nb_val := _sample_image_bilinear(nb_img, nb_u, v_norm)
			var t := clampf(1.0 - (float(w) - 0.5 - fpx) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)

	# Vertical blend (bottom or top neighbour).
	if near_bot and neighbors.has("S") and neighbors["S"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["S"], ns)
		if nb_img and nb_img.get_height() == h:
			var nb_v := (float(h) + fpy) / float(h)
			var nb_val := _sample_image_bilinear(nb_img, u_norm, nb_v)
			var t := clampf(1.0 - (fpy + 0.5) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)
	elif near_top and neighbors.has("N") and neighbors["N"] >= 0:
		var nb_img := load_chunk_heightmap(neighbors["N"], ns)
		if nb_img and nb_img.get_height() == h:
			var nb_v := clampf((fpy - float(h) + 0.5) / float(h), 0.0, 1.0)
			var nb_val := _sample_image_bilinear(nb_img, u_norm, nb_v)
			var t := clampf(1.0 - (float(h) - 0.5 - fpy) / blend_margin, 0.0, 1.0)
			val = lerpf(val, nb_val, t * 0.5)

	return val


## Read a single heightmap pixel, fetching from the neighbour HEALPix tile
## when (px, py) falls outside the current tile [0, w) × [0, h).
func _get_pixel_healpix(img: Image, px: int, py: int,
		w: int, h: int, ipix: int, _cached_neighbors = null, nside: int = -1) -> float:
	if px >= 0 and px < w and py >= 0 and py < h:
		return img.get_pixel(px, py).r

	var ns := nside if nside > 0 else export_nside
	# Out of bounds — try neighbor tile
	var neighbors: Dictionary
	if _cached_neighbors != null:
		neighbors = _cached_neighbors
	else:
		neighbors = HEALPix.get_neighbors_nest(ns, ipix)
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
		var nb_img := load_chunk_heightmap(nb_ipix, ns)
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


## Radial distance from the planet centre to the crack-aware surface along
## [param dir] (a planet-LOCAL unit direction).  This is the authoritative
## "ground" for server anti-tunnel clamps (player and props): the thin trimesh
## collision tunnels, so bodies below this are pushed back up to it. Uses the
## full-depth crack (vtx_spacing 0 = no LOD fade), matching the player.
## [param nside] selects the pyramid level to sample: pass the chunk's own
## sample nside so a coarse chunk is validated against its own coarse tile
## rather than the finest level (which legitimately differs by kilometres on
## steep terrain and would false-trip the cache validator). nside <= 0 → finest.
func crack_aware_surface_dist(dir: Vector3, nside: int = -1) -> float:
	var alt := sample_height_for_direction(dir, -1, -1, Vector2i(-1, -1), null, nside)
	if corundum_override_whole_planet:
		alt += ArideDesertCorundumPlateauTerrain.crack_offset(
			dir, radius, crack_spacing_m, crack_width_m, crack_depth_m, 0.0)
	return radius + alt


## HEALPix nside for server COLLISION chunks pinned under active bodies.
## Normally the export nside, but for planets whose visual mesh carries fine
## sub-features (the corundum crack network) it uses the client's FINEST LOD
## nside (max_quadtree_nside).  Paired with [method collision_col_res_for]
## returning chunk_resolution, the collision is then built on the EXACT same
## HEALPix grid (same nside AND res) the client renders at its finest LOD — so
## the collision surface is bit-identical to the visual mesh and the player
## can't stand above/below the rendered cracks.
##
## Only applied in file (chunk-heightmap) mode, whose shape task re-resolves
## the export tiles per vertex.
func collision_detail_nside() -> int:
	if chunk_heightmaps_dir == "" or not corundum_override_whole_planet:
		return export_nside
	return 1 << max_quadtree_depth


## Collision grid resolution for a chunk at [param nside].  Fine (crack) chunks
## at max_quadtree_nside use chunk_resolution to match the visual mesh's finest
## LOD grid exactly; coarse export-level chunks keep the denser recipe
## resolution so their larger tiles are still adequately sampled.
func collision_col_res_for(nside: int) -> int:
	if nside >= (1 << max_quadtree_depth):
		return chunk_resolution
	return maxi(_recipe_resolution, chunk_resolution)


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
	var bd := biome_at(dir)
	if bd != null:
		return bd.color

	# ── Path 3: fallback ──
	return Color(0.45, 0.35, 0.25, 1.0)


## The BiomeDefinition covering a body-fixed direction, or null when we cannot tell.
##
## Deliberately the EXACT path only — the populate zones, which name their biome_type. The biome map
## raster is not usable here: it stores a COLOUR, and there is no reverse lookup, so answering from it
## would mean matching the nearest of 126 biome colours. A footstep built on that guess would sound
## confident and be wrong; null lets the caller fall back honestly.
func biome_at(dir: Vector3) -> BiomeDefinition:
	if export_nside <= 0:
		return null
	var eipix := HEALPix.vec2pix_nest(export_nside, dir)
	var pz := get_chunk_populate_zones(eipix)
	if pz.is_empty():
		return null
	var matched := PlanetChunk._query_zones_at_direction(dir, pz)
	if matched.is_empty():
		return null
	return get_biome_by_type(String(matched[0].get("biome_type", "")))


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
	# Capped at 3: LOD 4 was a far-LOD placeholder SPHERE, now REMOVED by design — distant bodies render
	# their coarse LOD-3 chunks at every distance (on the celestial layer, lit by the star in the terrain
	# shader), so a planet keeps its real terrain instead of popping to a smooth sphere. lod3_distance is
	# now unused (kept as an @export so existing scenes don't churn).
	return 3


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


## Force the biome cache to build now, on the calling thread.
## MUST be called on the main thread during setup, before any WorkerThreadPool
## chunk-generation task runs — otherwise concurrent workers race the lazy
## _build_biome_cache() and some receive null lookups (see planet_body._ready).
func warm_biome_cache() -> void:
	if not _biome_cache_built:
		_build_biome_cache()


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


## Load (and memoise) a road material by resource path — thread-safe.
##
## PlanetChunk.generate_mesh() runs on WorkerThreadPool tasks and used to do the
## has/load/store dance on _road_material_cache inline, unsynchronised: several
## mesh tasks could call ResourceLoader.load() for the same path and write the
## Dictionary concurrently. Negative results are cached too, so a missing .tres
## is not re-probed once per chunk.
func get_road_material_cached(mat_path: String) -> Material:
	_road_material_mutex.lock()
	if _road_material_cache.has(mat_path):
		var hit = _road_material_cache[mat_path]
		_road_material_mutex.unlock()
		return hit as Material
	var loaded: Material = null
	if ResourceLoader.exists(mat_path):
		var res = ResourceLoader.load(mat_path)
		if res is Material:
			loaded = res
	_road_material_cache[mat_path] = loaded
	_road_material_mutex.unlock()
	return loaded


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
