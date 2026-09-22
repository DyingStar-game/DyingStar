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
## (tools/planettech/qgis/export_elevation.py compute_data_version). PlanetTerrain folds it
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
@export var max_quadtree_depth: int = 13

@export_group("Corundum default biome")
## Makes aride_desert-corundum_plateau the planet's DEFAULT biome: the "milky
## corundum with iron" look + the procedural blocky crack network, wherever no
## populate zone names a biome. A zone whose biome_type resolves to a
## BiomeDefinition wins over it — its colour, its detail texture, its own
## material, and NO crack (the cracks are corundum geology, they stop at the
## zone edge, in the mesh and in the collision alike). A zone that names no
## biome (rock_type or colour only) does not count: corundum stays underneath.
## See [method corundum_applies_at] for the one rule every path shares.
@export var corundum_default_biome: bool = false
## The rock the corundum default ground is made of — a RockCatalogue slug
## (rocks.json). Its light ↔ dark tints, shaded by RockImpurity (deeper toward
## the crests and the crevasse floors, banded by the strata), are what the
## default ground bakes into its vertex colours; a zone with its own rock_type
## keeps its own rock. "corundum_milky" is the milky white ↔ iron yellow the
## plateau always had.
@export var corundum_default_rock: String = "corundum_milky"
## Approximate size of a monolithic block between cracks, in metres.
@export var crack_spacing_m: float = 90.0
## Width of each carved crack at the surface, in metres.
@export var crack_width_m: float = 14.0
## Depth each crack is carved below the plateau surface, in metres.
@export var crack_depth_m: float = 22.0
## A POI's influence sphere is kept whole: no crack inside it, and over this
## many metres outside it the crack depth ramps back to full (a ramp, not a
## step, so the collision and the mesh stay walkable at the edge). The
## spheres come from the planet's POI nodes (PlanetTerrain gives them to
## [method set_crack_exclusions] before the first chunk).
@export var crack_poi_margin_m: float = 300.0
## The crack network stops under the mountains: full depth on a range's
## outline (a ridge's foot), none this many metres inside — a ramp of its
## own, not the relief's feather, which can be kilometres and would run a
## canyon up to the crest.
@export var crack_mountain_fade_m: float = 600.0
## DEBUG: paint chunk skirt curtains bright magenta to distinguish them from
## real terrain / crack interiors when diagnosing dark-band artifacts.
@export var debug_color_skirts: bool = false

@export_group("Debug mountain")
## DEV: a synthetic mountain_range polygon + one ridge, injected as if the
## modifier pack carried them — to iterate on MountainRelief before the QGIS
## layer exists. Ignored once the pack has a mountain part. Every field below
## is baked into the chunk cache key.
@export var debug_mountain_enabled: bool = false
## Centre of the debug massif (lon, lat in degrees) and its radius (km).
@export var debug_mountain_lonlat: Vector2 = Vector2.ZERO
@export var debug_mountain_radius_km: float = 15.0
## Style keys of MountainNoise.Params (amplitude_m, wavelength_m, octaves,
## persistence, ridge, exponent, terrace_step_m, terrace_width, warp, lift_m,
## feather_m, seed). Missing keys take the defaults.
@export var debug_mountain_style: Dictionary = {"amplitude_m": 600.0, "wavelength_m": 6000.0, "octaves": 7, "ridge": 0.6, "exponent": 1.5}
## Debug ridge: crest points (lon, lat) — empty = no ridge — and its style
## keys (height_m, width_m, sharpness, roughness, warp_m, asymmetry,
## terrace_step_m, terrace_width, seed).
@export var debug_ridge_points: PackedVector2Array = PackedVector2Array()
@export var debug_ridge_style: Dictionary = {"height_m": 400.0, "width_m": 1200.0, "sharpness": 0.7, "asymmetry": 0.5}

## Directory of per-chunk elevation data exported by tools/planettech/qgis/export_elevation.py.
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

@export_group("Mining zones")
## Let the server seed mining zones across this planet on its own (MiningZonePlanner). OFF by
## default: a planet only grows deposits once a designer opts it in, so enabling the feature never
## silently populates every world in the universe.
@export var mining_zones_enabled: bool = false
## Share of candidate cells that actually carry a deposit, 0..1. The verdict is a hash of
## (planet uuid, chunk key), so it is stable across restarts and identical on every server — a
## barren cell costs nothing because it is never written to the database.
@export_range(0.0, 1.0) var mining_zone_deposit_rate: float = 0.15
## How much of its collision chunk a generated zone's square rock field spans, 0..1. The size in
## metres is derived from the chunk itself (HEALPix.pixel_side_length — ~794 m on tarsis_4), so it
## follows max_quadtree_depth automatically instead of having to be re-tuned by hand whenever the
## terrain LOD changes.
##
## 1.0 does NOT pave the chunk exactly: a HEALPix pixel is a curvilinear quad and the field is a
## square in the tangent plane with an arbitrary yaw, so at full fill it spills into the neighbouring
## chunks at the corners while still leaving gaps along the edges. Overlapping fields also confuse
## MiningZone._has_rocks_in_field, which would then see a neighbour's rocks as its own and skip
## generating. Stay a little under: 0.88 leaves a ~95 m breathing space between deposits.
@export_range(0.0, 1.0) var mining_zone_chunk_fill: float = 0.88
## Rocks per square kilometre inside a zone's field. A DENSITY rather than a count, so changing
## mining_zone_chunk_fill re-sizes the field without silently making every deposit look poorer.
## 120/km² is one rock per ~91 m, the historical 30-rocks-in-a-500 m-field look.
@export var mining_zone_rock_density: float = 120.0
## Minimum spacing (m) between two rocks of the same field.
@export var mining_zone_min_spacing: float = 8.0
## Relative share of each rock size in the mix (small, medium, large). Mirrors MiningZone's own
## weight_small/medium/large; any positive ratio works.
@export_range(0.0, 1.0) var mining_zone_weight_small: float = 0.6
@export_range(0.0, 1.0) var mining_zone_weight_medium: float = 0.3
@export_range(0.0, 1.0) var mining_zone_weight_large: float = 0.1
## Which minerals this planet yields, and their relative frequency. Ids must exist in
## MineralRegistry.ALL; unknown ones are dropped with a warning at planning time. The two arrays are
## read in parallel — a missing weight counts as 1.0.
@export var mining_zone_minerals: PackedStringArray = PackedStringArray(
	["iron", "gold", "cryptonite"])
@export var mining_zone_mineral_weights: PackedFloat32Array = PackedFloat32Array([0.6, 0.3, 0.1])
## The BARREN rock the ore sits in on THIS planet — the local geology. Every zone the planner
## seeds here weighs its rocks' gangue with this mineral's density (MiningZone._host_rock_density),
## so a vein in corundum weighs more than the same vein in sandstone. A hand-placed MiningZone can
## still override it per zone; leave that field empty and it inherits this one.
## Dropdown fed by MineralRegistry, restricted to the inert minerals (see _validate_property).
@export var mining_zone_host_rock: String = "granite"
## Range the per-zone ore richness is drawn from (0 = poor, 1 = rich).
@export_range(0.0, 1.0) var mining_zone_richness_min: float = 0.25
@export_range(0.0, 1.0) var mining_zone_richness_max: float = 0.75
## Clearance (m) kept OUTSIDE a POI's own influence sphere. tarsis_4's POIs range from 1 km
## (mining villages) to 40 km (major cities), and a deposit must not creep into any of them.
@export var mining_zone_poi_margin: float = 200.0
## Clearance (m) kept outside a road's own half-width, so a field never swallows the carriageway.
@export var mining_zone_road_margin: float = 50.0

@export_group("Bridges")
## Deck, ramp and abutment settings for the bridges carrying roads over the
## procedural chasms. Leave null to use the defaults; a profile is only worth
## authoring when a planet's terrain needs different ramps.
##
## Its signature() feeds the chunk disk-cache key: the ribbon is CUT to make
## room for the ramps, so changing a ramp changes baked chunk meshes.
@export var bridge_profile: BridgeProfile = null

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

## Cache of loaded chunk heightmap images.  Clé = id de tuile (voir [method _tile_id]) → Image.
var _chunk_images: Dictionary = {}
## Mêmes tuiles que _chunk_images, décodées en PackedFloat32Array.
##
## Les tuiles sont créées en FORMAT_RF depuis les octets bruts du pack : la donnée SOUS-JACENTE
## est déjà du float32, et `img.get_pixel(x, y).r` ne fait que la relire en construisant une
## Color (quatre floats) à chaque texel. Le noyau bilinéaire en demande quatre, le calcul des
## normales quatre échantillons par sommet, et la bande de mélange en ajoute encore : mesuré à
## ~17 400 get_pixel par chunk, pour 45 % du temps de génération passé dans l'échantillonnage.
## Indexer un PackedFloat32Array rend exactement la même valeur, sans l'allocation.
##
## Peuplé et purgé aux mêmes endroits que _chunk_images, sous le même _cache_mutex.
var _chunk_floats: Dictionary = {}
## Source HTTP optionnelle. Quand elle est posée, une tuile absente du pack local est
## cherchée dans son cache disque — jamais sur le réseau depuis le chemin chaud : c'est
## PlanetTerrain qui met en file et diffère le chunk (voir request_chunk_tiles).
var remote_source: RemoteTileSource = null
var _empty_chunk_logged: bool = false
var _chunk_format_logged: bool = false

## ── Planet pack (runtime data source) ────────────────────────────
## All per-tile recipe binaries + chunk manifest are packed into a single
## .planetpack file per planet, produced by tools/planettech/qgis/pack_planet.py.
## Recipes are loaded exclusively from the pack at runtime — the old
## loose-file layout under assets/qgis/.export/ is no longer read.
var _pack = null  # PlanetPackScript instance
var _pack_tried: bool = false
var _pack_open_mutex: Mutex = Mutex.new()

## ── Height pack (dense .r32 tile archive) ────────────────────────
## All pyramid elevation tiles of chunk_heightmaps_dir packed into a single
## heights.pack file (written by tools/planettech/qgis/export_elevation.py). This is the
## ONLY source of elevation tiles: O(1) arithmetic offsets, per-thread read
## handles (lock-free from WorkerThreadPool tasks) and coarse levels
## preloaded in RAM.
var _height_pack = null  # HeightPackScript instance
var _height_pack_tried: bool = false
var _height_pack_mutex: Mutex = Mutex.new()

## ── Modifier pack (sparse per-chunk vector archive) ──────────────
## terrainmodifier.pack: roads, craters, linear features, radial features and
## biome populate zones, already clipped to their HEALPix tile and decimated
## per LOD level (written by tools/planettech/qgis/link_modifiers.py from the per-kind
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

## Deck/ramp plans, and the stretches of ribbon they displace.
##
## Built ONCE, on the main thread, for every span at the same time. That is not
## an optimisation: the ribbon cutter runs on a mesh worker thread while the
## deck builder runs on the main one, and the two must use the same numbers or
## the road is cut open where nothing spans it. One shared table, filled before
## either of them runs, is what makes that impossible.
var _bridge_plans: Dictionary = {}            # span key → plan
var _bridge_excl: Dictionary = {}             # feature_id → Array[Vector2] merged
## feature_id → Array[Vector2] BRUTS, avant fusion. Gardés parce qu'un plan qui arrive en
## retard doit refusionner les intervalles de SA route, et refusionner exige les originaux.
var _bridge_excl_raw: Dictionary = {}
## Travées refusées faute de tuile d'élévation — et elles seules. Une travée dont le plan a
## échoué pour de bon (BridgePlan.ok == false) est un verdict déterministe, elle n'est PAS
## là-dedans : la rejouer redonnerait le même non.
##
## Sur un serveur, ce cas est la règle et non l'exception : le pod redémarre avec un cache
## de tuiles vide, et warm_bridge_plans() tourne dans initialize(), avant que le streaming
## n'ait livre quoi que ce soit. Sans rattrapage, la planète perd ses 37 ponts pour toute
## la session — or le tablier porte la SEULE collision au-dessus d'un gouffre, donc le
## joueur traverse un pont que son client, lui, affiche (son cache à lui est chaud).
var _bridge_spans_starved: Array[Dictionary] = []
## Budget total du préchargement des tuiles de travée, en millisecondes.
const BRIDGE_PREFETCH_BUDGET_MS := 5000
var _bridge_plans_built: bool = false
var _bridge_plans_mutex: Mutex = Mutex.new()
var _whole_roads_by_fid: Dictionary = {}
var _bridge_profile_cache: BridgeProfile = null

## Grade-limited lines — railways and highways / roads with a
## `max_slope_degrees`: one longitudinal profile per feature (see
## GradeProfile), the viaduct spans it implies, their deck plans and the bed
## exclusions under the decks. Same discipline as the bridge tables above:
## built ONCE on the main thread (warm_grade_profiles) before any mesh worker
## needs them, because the bed builder on a worker and the viaduct spawner on
## the main thread must read the same numbers.
var _grade_profiles: Dictionary = {}          # feature_id → profile
var _grade_spans: Array = []                  # viaduct spans, kind railway / profiled_road
var _grade_plans: Dictionary = {}             # span key → deck plan
var _grade_excl: Dictionary = {}              # feature_id → Array[Vector2] merged
var _grade_built: bool = false
var _grade_mutex: Mutex = Mutex.new()
## Lines refused at warm-up for a tile not yet downloaded: {road, tiles}.
## Same discipline as _bridge_spans_starved — the tiles are queued on the
## streaming source and retry_starved_grade_profiles() replays the line once
## they are all on disk. Measured on tarsis_3: the 600 km railway crosses
## ~190 export tiles at ~150 ms each over the network, so the 5 s prefetch
## below could never build it and, without this, the session kept the
## verdict "0 profile(s)" for ever — the track ran into the hills.
var _grade_starved: Array[Dictionary] = []
## Export ipix (at export_nside) under a starved line and their neighbours:
## a chunk there bakes a bed that will change the moment the profile is
## born, so its geometry must not be persisted meanwhile.
var _grade_starved_tiles: Dictionary = {}
## feature_id → the export tiles under that line — the 5 m walk of a 600 km
## line costs seconds, so it is done once, not on every retry.
var _grade_tiles_by_fid: Dictionary = {}
## Profiles being computed on the WorkerThreadPool: feature_id →
## {task_id, result_ref, road, tiles}. GradeProfile.compute samples the
## terrain every 5 m: 12 s for tarsis_3's 556 km railway and ~35 s for its
## graded road, measured — far too long for the main thread at planet load,
## where warm_grade_profiles() used to run it. A line being profiled is
## handled exactly like a starved one: its chunks are provisional, and they
## are rebuilt by PlanetTerrain when the profile is born.
var _grade_pending: Dictionary = {}
## -1 unknown, 0 no, 1 yes — memoised because collision_detail_nside() asks
## on every residency pass.
var _has_railways: int = -1
var _has_profiled_lines: int = -1
var _has_relief_biomes: int = -1
var _has_roads: int = -1
## -1 unknown, 0 no, 1 yes — the planet has procedural mountains (pack
## mountain / ridge parts, or the debug injection). Warmed on the main thread
## by warm_mountains(); the sampler only compares it.
var _has_mountains: int = -1
## Finest vertex pitch of this planet (terrain_vertex_spacing_m()), memoised
## by warm_mountains(): the floor of every mountain LOD gate, so a gameplay
## query (pitch 0 = "full detail") drops exactly the octaves the finest chunk
## drops.
var _mtn_finest_spacing: float = 0.0
## Prepared MountainRelief.Zone / Ridge lists that stand in for the pack
## (debug injection, tests). Built on the main thread, read-only afterwards.
var _mtn_override_zones: Array = []
var _mtn_override_ridges: Array = []
var _mtn_override_set: RefCounted = null
## Budget of the blocking tile prefetch under the profiled lines, in milliseconds.
const GRADE_PREFETCH_BUDGET_MS := 5000

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
## Suivi LRU : id de tuile → rang d'utilisation, croissant.
##
## Remplace la liste ordonnée : son « touch » faisait un Array.find() LINÉAIRE puis un
## remove_at()/append() à chaque lecture de tuile. Inoffensif à deux tuiles ; mais le chemin
## d'échantillonnage demande une tuile par échantillon de hauteur — 1,29 million de demandes
## pour 29 tuiles distinctes sur un relevé de génération (docs/PLANET_CHUNK_STREAMING.md).
## Une écriture de dictionnaire tient le même rôle en O(1) ; le balayage du minimum n'a lieu
## qu'à l'éviction, qui est rare (budget d'un gigaoctet pour des tuiles de quelques kilooctets).
var _cache_tick: Dictionary = {}
## Compteur monotone alimentant _cache_tick. Protégé par _cache_mutex comme le reste.
var _cache_seq: int = 0
## Current total cache size in bytes (for LRU eviction budget).
var _cache_bytes: int = 0
## Maximum cache budget in bytes.  1024 MB for client.
const MAX_CACHE_BYTES: int = 1024 * 1024 * 1024
## When true, never evict cached chunks (server keeps everything).
var _server_no_evict: bool = false
## When true, skip loading 8 neighbor recipes to merge craters in
## _load_recipe_heightmap.  Set when the planet has no craters at all.
var skip_neighbor_crater_merge: bool = false
## Mutex protecting _chunk_images, _cache_tick, and _cache_bytes so that
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

## Inspector: `mining_zone_host_rock` is a plain String (that id is what MiningZone looks up in
## MineralRegistry), but a designer should pick it from the registered inert minerals rather than
## type an id whose only symptom is a silent fall back to granite's density.
func _validate_property(property: Dictionary) -> void:
	if property["name"] == "mining_zone_host_rock":
		property["hint"] = PROPERTY_HINT_ENUM
		property["hint_string"] = MineralRegistry.enum_hint(MineralRegistry.Kind.INERT)


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


# ── Recensement des tuiles d'élévation (phase 0 de docs/PLANET_CHUNK_STREAMING.md) ──────────────
# Combien de tuiles DISTINCTES une vraie session touche-t-elle, et à quels niveaux ? La section 3 du
# doc répond 273 tuiles / 1,07 MiB, mais par SIMULATION de _traverse et par reconstitution depuis le
# cache de meshes — jamais par mesure directe. Ce compteur est la mesure directe : c'est lui qui
# dimensionne le bundle, le budget de cache et l'egress si on passe au streaming.
#
# Écrit depuis les tâches WorkerThreadPool (load_chunk_heightmap est appelé dans generate_mesh), donc
# protégé par son propre mutex — surtout pas _cache_mutex, dont le chemin serveur (_server_no_evict)
# se passe délibérément.
static var prof_tile_requests: int = 0
## Lectures disque réelles (cache d'Images manqué) — à comparer à prof_tile_requests.
static var prof_tile_disk_reads: int = 0
## Temps total passé dans load_chunk_heightmap, imbriqué dans la phase "verts" du chunk.
static var prof_tile_usec: int = 0
## "hp_n<nside>_p<ipix>" -> nombre de demandes. Sa TAILLE est le chiffre recherché.
static var prof_tiles_seen: Dictionary = {}
## Temps de lecture de tuile CUMULÉ PAR THREAD, pour que generate_mesh puisse mesurer sa PROPRE
## part plutôt que le total global.
##
## Sans ça, la ligne clé de la phase 0 est fausse : le premier relevé client affichait
## [code]tuiles=144.4% du temps mesh[/code]. Le total global comptait aussi les lectures faites hors
## génération — 488 chunks assemblés depuis le cache disque, les requêtes de gameplay, les
## spawners — pendant que le dénominateur ne couvrait que les 3 meshes réellement générés.
## Une part relative n'a de sens que si numérateur et dénominateur parlent du même travail.
##
## generate_mesh lit ce compteur au début et à la fin de son propre thread et prend la différence :
## chaque tâche worker a son entrée, personne ne partage rien. Même modèle que les FileAccess
## par thread de [HeightPack].
static var _prof_tile_usec_by_thread: Dictionary = {}
## Nom du point d'entrée public -> nombre d'appels. Attribue les demandes de tuiles à ce qui les
## provoque : le premier run serveur a montré ~80 demandes/s ALORS QU'AUCUN chunk n'était construit,
## et sans cette ventilation on ne peut pas dire d'où elles viennent.
static var prof_sampler_calls: Dictionary = {}
static var prof_tile_mutex: Mutex = Mutex.new()


static func prof_tiles_reset() -> void:
	prof_tile_mutex.lock()
	prof_tile_requests = 0
	prof_tile_disk_reads = 0
	prof_tile_usec = 0
	prof_tiles_seen.clear()
	prof_sampler_calls.clear()
	_prof_tile_usec_by_thread.clear()
	prof_tile_mutex.unlock()


## Temps de lecture de tuile cumulé par le thread appelant. Deux relevés encadrant un travail en
## donnent le coût de tuile propre, sans compter celui des autres threads.
## Remontées d'ancêtre PROVISOIRES, par thread appelant.
##
## Une remontée n'est pas anodine de la même façon selon la raison de l'absence :
##   - tuile réellement élaguée du pack → l'ancêtre est la tuile, à SPARSE_EPSILON_M (1 m) ;
##   - tuile publiée mais pas encore téléchargée → l'ancêtre est un parent plus lisse, et
##     l'écart n'est borné par rien (35,4 m mesurés sur tarsis_3).
## Seul le second cas est compté ici. Il sert à REFUSER la mise en cache disque de la
## géométrie qui en découle : sans ce refus, une surface bâtie sur une supposition devient
## indiscernable d'une surface correcte, et le fait pour toujours.
## Par thread parce que les chunks se construisent sur WorkerThreadPool, un par tâche.
## Volontairement des membres D'INSTANCE, pas des statiques : planet_data.gd appelle déjà
## PlanetChunk._query_zones_at_direction(), donc un appel statique en sens inverse ferme un
## cycle de résolution entre les deux classes — l'éditeur rend alors un PlanetChunk réduit à
## un GDScript nu ("Nonexistent function 'snap_to_f32' in base 'GDScript'"). Passer par
## l'instance `data`, que les deux générateurs reçoivent déjà, n'a pas ce problème.
var _climb_by_thread: Dictionary = {}
var _climb_mutex: Mutex = Mutex.new()
## "nside/ipix" -> la remontée depuis cette tuile est-elle une supposition ? Voir
## [method _climb_is_guess]. Par instance : la carte de présence appartient au corps.
var _presence_guess: Dictionary = {}


## La remontée depuis (nside, ipix) est-elle une SUPPOSITION plutôt qu'un élagage voulu ?
##
## Mémoïsé : sur un pack creux à 69,5 % la remontée est le cas NORMAL, donc ce test tombe
## sur le chemin chaud, une fois par sommet. Or la carte de présence est immuable pour une
## version de données — un tuple (nside, ipix) donne toujours la même réponse. Le memo
## ramène des milliers d'appels par chunk à un par tuile, soit ~9.
func _climb_is_guess(nside: int, ipix: int) -> bool:
	if remote_source == null:
		return false
	var key := "%d/%d" % [nside, ipix]
	_climb_mutex.lock()
	var hit: Variant = _presence_guess.get(key)
	_climb_mutex.unlock()
	if hit != null:
		return bool(hit)
	# Hors du verrou : presence_of prend le sien, et peut mettre une carte de shard en
	# file. Deux threads qui se croisent ici calculent la même valeur — sans conséquence.
	#
	# Toute la chaîne, pas le seul niveau demandé : une tuile élaguée dont le parent
	# publié n'est pas encore téléchargé fait remonter le sampler jusqu'au plancher, et
	# ce relief-là n'a rien d'une reconstruction au mètre (voir
	# TileResidency.tile_available). La remontée n'est légitime que si le plus fin
	# ancêtre PUBLIÉ est celui qu'on lit, c'est-à-dire s'il est sur disque.
	var state: int = TileResidency.finest_published_ancestor_state(self, ipix, nside)
	if state == TileResidency.PUBLISHED_UNKNOWN or state == TileResidency.PUBLISHED_ABSENT:
		# On ne SAIT pas encore (carte de shard en route) ou la tuile arrive : on suppose
		# le pire pour cette géométrie-ci — mais on ne le mémoïse SURTOUT pas. Figer un
		# « inconnu » interdirait pour toujours de cacher les tuiles réellement élaguées
		# de ce shard, c'est-à-dire la majorité d'un pack creux.
		return true
	var guess: bool = state != TileResidency.PUBLISHED_PRESENT
	_climb_mutex.lock()
	_presence_guess[key] = guess
	_climb_mutex.unlock()
	return guess


## Compte une remontée provisoire pour le thread courant.
func climb_mark() -> void:
	var tid := OS.get_thread_caller_id()
	_climb_mutex.lock()
	_climb_by_thread[tid] = int(_climb_by_thread.get(tid, 0)) + 1
	_climb_mutex.unlock()


## Remontées provisoires comptées pour le thread courant depuis le dernier climb_reset().
func climb_count() -> int:
	_climb_mutex.lock()
	var v: int = int(_climb_by_thread.get(OS.get_thread_caller_id(), 0))
	_climb_mutex.unlock()
	return v


## Remet à zéro le compteur du thread courant. À appeler avant de bâtir une géométrie.
func climb_reset() -> void:
	_climb_mutex.lock()
	_climb_by_thread[OS.get_thread_caller_id()] = 0
	_climb_mutex.unlock()


static func prof_thread_tile_usec() -> int:
	prof_tile_mutex.lock()
	var v: int = int(_prof_tile_usec_by_thread.get(OS.get_thread_caller_id(), 0))
	prof_tile_mutex.unlock()
	return v


## Compte un appel à un point d'entrée d'échantillonnage. Appelé depuis des tâches worker,
## donc sous le même mutex que le recensement de tuiles.
static func _prof_count_sampler(entry: String) -> void:
	prof_tile_mutex.lock()
	prof_sampler_calls[entry] = int(prof_sampler_calls.get(entry, 0)) + 1
	prof_tile_mutex.unlock()


## Cadre d'échantillonnage d'un chunk : tout ce qui ne dépend que de la TUILE, résolu au
## premier accès et gardé jusqu'à la fin du chunk.
##
## Un chunk lit sa propre tuile, et par ses sommets de bord celles qui la touchent : neuf au
## plus, contre 5 445 échantillons. Sans ce cadre, chaque échantillon refaisait la position
## dans la face et surtout get_neighbors_nest(), et un sommet de bord qui bascule sur la
## tuile voisine repartait SANS aucun précalcul — mesuré à 120 µs contre 32 pour un sommet
## intérieur, soit 31 % du coût d'échantillonnage du chunk pour 12 % des échantillons.
##
## Le cadre mémorise aussi les tableaux de floats. Il fige donc les tuiles pour la durée du
## chunk : si une autre tâche recharge une tuile pendant la construction, ce chunk termine
## sur celle qu'il a commencé à lire. C'est voulu — un chunk bâti moitié sur l'ancienne
## tuile, moitié sur la nouvelle, aurait une couture au milieu.
class TileFrame:
	extends RefCounted

	## Positions dans une entrée. Un Array indexé par des littéraux, pas un Dictionary ni des
	## constantes nommées : ce chemin est parcouru des dizaines de milliers de fois par chunk
	## et chaque résolution de nom s'y voit.
	##   0 floats · 1 face · 2 position dans la face · 3 voisines
	var _data: Resource
	## id de tuile -> entrée
	var _entries: Dictionary = {}
	## Mountain features of the chunk this frame serves (prepare_mountain_frame):
	## MountainRelief.Zone and Ridge lists. While mtn_ready is false the sampler
	## looks them up per direction instead.
	var mtn: Array = []
	var rdg: Array = []
	## MountainSetNative of the two lists (null → GDScript path).
	var mtn_set: RefCounted = null
	var mtn_ready := false

	func _init(data: Resource) -> void:
		_data = data

	## Tout ce qui ne dépend que de la tuile, calculé au premier accès.
	##
	## Les voisines sont calculées ici même pour une tuile lue seulement par le mélange de
	## bord, qui n'en a pas besoin : neuf tuiles par chunk au plus, contre un test par
	## échantillon si on les rendait paresseuses.
	func entry(ipix: int, nside: int) -> Array:
		# Même identifiant que le cache de PlanetData (_tile_id), écrit ici plutôt qu'appelé :
		# un appel statique par échantillon pour un décalage et un « ou ».
		var id := (nside << 32) | ipix
		var hit: Variant = _entries.get(id)
		if hit != null:
			return hit
		var npface := nside * nside
		@warning_ignore("integer_division")
		var made := [_data.load_chunk_floats(ipix, nside), ipix / npface,
				HEALPix.nest2xy(ipix % npface), HEALPix.get_neighbors_nest(nside, ipix)]
		_entries[id] = made
		return made

	func floats(ipix: int, nside: int) -> PackedFloat32Array:
		return entry(ipix, nside)[0]


## Cadre d'échantillonnage neuf, à garder le temps d'un chunk et à jeter avec lui.
func make_tile_frame() -> TileFrame:
	return TileFrame.new(self)


## Identifiant de tuile, pour les dictionnaires du cache.
##
## Les caches étaient indexés par la chaîne "hp_n<nside>_p<ipix>", reformatée à CHAQUE
## demande de tuile — soit une allocation et un formatage par échantillon de hauteur.
## Un entier porte la même information sans rien allouer : ipix tient sur 30 bits au plus
## (12·nside², nside ≤ 8192) et nside sur les bits hauts.
static func _tile_id(ipix: int, nside: int) -> int:
	return (nside << 32) | ipix


## Même identifiant, depuis la clé textuelle de l'API publique ("hp_n<nside>_p<ipix>").
## Les points d'entrée par clé (store_chunk_image, is_chunk_cached, invalidate_chunk_cache)
## sont froids — une fois par tuile, pas une fois par échantillon — donc l'analyse y est
## sans conséquence.
static func _tile_id_from_key(key: String) -> int:
	var p := key.find("_p")
	if not key.begins_with("hp_n") or p < 0:
		push_error("[PlanetData] clé de tuile inattendue: '%s'" % key)
		# Espace d'identifiants disjoint : jamais confondu avec un (ipix, nside) réel.
		return -absi(key.hash())
	return _tile_id(key.substr(p + 2).to_int(), key.substr(4, p - 4).to_int())


## Load the .r32 tile (ipix) at pyramid level [param nside]. nside <= 0 means
## "finest" (export_nside), which is what every legacy caller gets by default.
##
## Enveloppe de mesure : quand le rig est éteint (le cas normal) c'est un test booléen puis
## l'appel direct, donc le chemin chaud est inchangé.
func load_chunk_heightmap(ipix: int, nside: int = -1) -> Image:
	if not PropNet.prof_on:
		return _load_chunk_heightmap_impl(ipix, nside)
	var _t0 := Time.get_ticks_usec()
	var img := _load_chunk_heightmap_impl(ipix, nside)
	var _spent := Time.get_ticks_usec() - _t0
	var _key := "hp_n%d_p%d" % [nside if nside > 0 else export_nside, ipix]
	prof_tile_mutex.lock()
	prof_tile_requests += 1
	prof_tile_usec += _spent
	prof_tiles_seen[_key] = int(prof_tiles_seen.get(_key, 0)) + 1
	var _tid := OS.get_thread_caller_id()
	_prof_tile_usec_by_thread[_tid] = int(_prof_tile_usec_by_thread.get(_tid, 0)) + _spent
	prof_tile_mutex.unlock()
	return img


## Le pack d'élévation omet-il des tuiles ? Faux pour tout pack dense (v1, ou v2 non
## creux), auquel cas aucun appelant ne paie la remontée de niveau.
func pack_is_sparse() -> bool:
	# Une source distante implique la remontée de niveau : l'arborescence publiée vient
	# d'un pack qui peut être creux, et sans pack local il n'y a personne pour le dire.
	if remote_source != null:
		return true
	# Pas d'inférence ici : _ensure_height_pack() ne déclare pas de type de retour.
	var pack = _ensure_height_pack()
	return pack != null and pack.is_sparse()


## Plus fin ancêtre de (ipix, nside) dont la tuile est réellement stockée, en
## Vector2i(ipix, nside) ; (-1, -1) si aucun. En NESTED, le parent d'une tuile est
## simplement ipix >> 2 au niveau nside >> 1.
func _finest_present_ancestor(ipix: int, nside: int) -> Vector2i:
	var cur_ip := ipix
	var cur_ns := nside
	while cur_ns > export_nside_min:
		cur_ns >>= 1
		cur_ip >>= 2
		if not load_chunk_floats(cur_ip, cur_ns).is_empty():
			return Vector2i(cur_ip, cur_ns)
	return Vector2i(-1, -1)


## Une hauteur est-elle disponible pour cette tuile, directement ou via un ancêtre ?
##
## Sur un pack creux, une tuile absente est normale et non une anomalie : le garde qui
## refuse de mettre un mesh en cache quand sa tuile manquait doit donc accepter ce cas,
## sinon plus aucun chunk ne serait jamais mis en cache.
func has_usable_tile(ipix: int, nside: int = -1) -> bool:
	var ns := nside if nside > 0 else export_nside
	if not load_chunk_floats(ipix, ns).is_empty():
		return true
	return pack_is_sparse() and _finest_present_ancestor(ipix, ns).y > 0


## Tuile décodée en float32, pour le chemin d'échantillonnage chaud.
##
## Miroir exact de load_chunk_heightmap (même clé, même verrou, même « touch » LRU, même
## chargement paresseux) mais rendant les floats plutôt que l'Image : le noyau bilinéaire les
## indexe directement au lieu d'appeler get_pixel(), qui construit une Color par texel.
## Une seule prise de verrou sur le chemin chaud, comme avant.
## Décode une tuile en float32, quel que soit son format d'Image.
##
## Les tuiles du pack sont en FORMAT_RF et leurs octets SONT déjà les float32 : la
## conversion est alors une simple réinterprétation. Mais le chemin recipe
## (store_chunk_image) et les tuiles synthétiques des tests peuvent arriver dans un autre
## format, où get_data() n'est pas un multiple de 4 octets — `to_float32_array()` échoue
## alors en silence sur « size % sizeof(float) » et rend un tableau vide, c'est-à-dire un
## terrain plat. Ces formats-là sont décodés texel par texel, UNE fois à l'insertion,
## plutôt qu'à chaque échantillon comme avant.
## Côté d'une tuile carrée à partir du nombre de texels, ou -1 si elle ne l'est pas.
## Les tuiles HEALPix sont carrées par construction (_read_r32_tile en produit res × res) ;
## le contrôle est là pour que le cas contraire retombe sur la carte globale plutôt que de
## lire hors des bornes.
static func _tile_side(floats: PackedFloat32Array) -> int:
	var n := floats.size()
	if n <= 0:
		return -1
	var side := int(round(sqrt(float(n))))
	return side if side * side == n else -1


static func _decode_tile_floats(img: Image) -> PackedFloat32Array:
	if img.get_format() == Image.FORMAT_RF:
		return img.get_data().to_float32_array()
	var w := img.get_width()
	var h := img.get_height()
	var out := PackedFloat32Array()
	out.resize(w * h)
	for y in h:
		for x in w:
			out[y * w + x] = img.get_pixel(x, y).r
	return out


func load_chunk_floats(ipix: int, nside: int = -1) -> PackedFloat32Array:
	if not PropNet.prof_on:
		return _load_chunk_floats_impl(ipix, nside)
	# Même enveloppe de mesure que load_chunk_heightmap. La première version ne recopiait
	# que les COMPTEURS et pas le chronomètre : déplacer le chemin chaud ici faisait
	# tomber la ligne "tuiles=" à 0,2 % du temps mesh, ce qui ressemblait à un gain alors
	# que le temps était seulement devenu invisible (fondu dans "échantillons").
	var t0 := Time.get_ticks_usec()
	var out := _load_chunk_floats_impl(ipix, nside)
	var spent := Time.get_ticks_usec() - t0
	var key := "hp_n%d_p%d" % [nside if nside > 0 else export_nside, ipix]
	prof_tile_mutex.lock()
	prof_tile_requests += 1
	prof_tile_usec += spent
	prof_tiles_seen[key] = int(prof_tiles_seen.get(key, 0)) + 1
	var tid := OS.get_thread_caller_id()
	_prof_tile_usec_by_thread[tid] = int(_prof_tile_usec_by_thread.get(tid, 0)) + spent
	prof_tile_mutex.unlock()
	return out


func _load_chunk_floats_impl(ipix: int, nside: int = -1) -> PackedFloat32Array:
	var ns := nside if nside > 0 else export_nside
	var id := _tile_id(ipix, ns)

	if _server_no_evict:
		var hit: Variant = _chunk_floats.get(id)
		if hit != null:
			return hit
		if chunk_heightmaps_dir != "" and _file_load_and_cache(ipix, ns) != null:
			return _chunk_floats.get(id, PackedFloat32Array())
		return PackedFloat32Array()

	_cache_mutex.lock()
	var cached: Variant = _chunk_floats.get(id)
	if cached != null:
		_cache_seq += 1
		_cache_tick[id] = _cache_seq
		_cache_mutex.unlock()
		return cached
	_cache_mutex.unlock()

	if chunk_heightmaps_dir != "" and _file_load_and_cache(ipix, ns) != null:
		_cache_mutex.lock()
		var loaded: PackedFloat32Array = _chunk_floats.get(id, PackedFloat32Array())
		_cache_mutex.unlock()
		return loaded
	return PackedFloat32Array()


func _load_chunk_heightmap_impl(ipix: int, nside: int = -1) -> Image:
	var ns := nside if nside > 0 else export_nside
	var id := _tile_id(ipix, ns)
	# Server fast path: cache is read-only after preload, skip mutex + LRU.
	if _server_no_evict:
		var cached := _chunk_images.get(id) as Image
		if cached != null:
			return cached
		# File mode: lazily load the exported tile (thread-safe via mutex).
		if chunk_heightmaps_dir != "":
			return _file_load_and_cache(ipix, ns)
		return null
	_cache_mutex.lock()
	var result := _chunk_images.get(id) as Image
	if result != null:
		# LRU touch: une écriture, pas un parcours de liste.
		_cache_seq += 1
		_cache_tick[id] = _cache_seq
		_cache_mutex.unlock()
		return result
	_cache_mutex.unlock()
	# File mode: load the per-chunk elevation tile (.r32) directly from disk.
	if chunk_heightmaps_dir != "":
		return _file_load_and_cache(ipix, ns)
	# Not cached yet — return null so callers fall back to global heightmap.
	# The async recipe pipeline in PlanetTerrain will generate and cache it.
	return null


## Load a per-chunk elevation tile (.r32) and insert it into the image cache.
## Thread-safe; safe to call from WorkerThreadPool mesh/collision tasks.
## Returns null if the tile is missing/malformed (caller falls back to global).
func _file_load_and_cache(ipix: int, nside: int) -> Image:
	var img := _read_r32_tile(ipix, nside)
	if img == null:
		return null
	# Compté APRÈS la réussite : placé avant, il comptait aussi les tentatives sur une
	# tuile inexistante, et un serveur sans pack affichait « 28 937 lectures disque »
	# alors qu'aucune I/O n'avait eu lieu.
	if PropNet.prof_on:
		prof_tile_mutex.lock()
		prof_tile_disk_reads += 1
		prof_tile_mutex.unlock()
	var id := _tile_id(ipix, nside)
	_cache_mutex.lock()
	# Another thread may have loaded the same tile while we read from disk.
	var existing := _chunk_images.get(id) as Image
	if existing != null:
		_cache_mutex.unlock()
		return existing
	_chunk_images[id] = img
	_chunk_floats[id] = _decode_tile_floats(img)
	_cache_seq += 1
	_cache_tick[id] = _cache_seq
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
						+ "absent. Produce it with tools/planettech/qgis/export_roads.py "
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
				# The pack's along-metres, degree half-widths and buffers were
				# all measured with the radius its exporter had — the QGIS
				# project variable `planet_radius_m`. Against another radius
				# every length along a line is off by the ratio (tarsis_3: a
				# road part at 5 875 km on a 6 356 km planet, 7.6 %). The
				# rail modules size themselves by the true metric (see
				# GradeGeom.frame_at), the rest does not: re-export.
				var pack_radius := float(pack.get_manifest().get("radius", 0.0))
				if pack_radius > 0.0 and radius > 0.0 \
						and absf(pack_radius - radius) > 0.001 * radius:
					push_error("[PlanetData] '%s': terrainmodifier.pack was exported for a "
							% planet_name
							+ "planet radius of %.0f m but this planet's radius is %.0f m "
							% [pack_radius, radius]
							+ "(%.1f %% off): every along-line length in it is wrong. Set the "
							% (100.0 * absf(pack_radius - radius) / radius)
							+ "QGIS project variable planet_radius_m to %.0f and re-run "
							% radius
							+ "export_roads.py / export_biomes.py (they relink the pack).")
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
	# Le pack local est FACULTATIF quand une source distante est branchée : une planète
	# entièrement streamée n'en a pas du tout. Sortir ici parce qu'il manque rendrait le
	# cache distant inatteignable — exactement le cas d'un test où l'on retire le pack
	# pour vérifier que le streaming suffit.
	var pack = _ensure_height_pack()
	var bytes := PackedByteArray()
	if pack != null:
		bytes = pack.read_tile(ns, ipix)
	if bytes.is_empty() and remote_source != null:
		# Repli sur ce qui a déjà été téléchargé. take() ne touche pas au réseau.
		var raw := remote_source.take(ns, ipix)
		if not raw.is_empty():
			# L'encodage se déduit de la taille : la charge utile publiée est la copie
			# exacte des octets du pack source, donc u16 ou float32 selon ce dernier.
			bytes = HeightPack.widen_u16(raw, res) if raw.size() == res * res * 2 else raw
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
				+ "elevation tiles (re-run tools/planettech/qgis/export_elevation.py)")
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
	var result := _chunk_images.has(_tile_id_from_key(export_key))
	_cache_mutex.unlock()
	return result


## Store a recipe-generated heightmap [param img] and optional sub-pixel
## [param craters] in the cache.  Must be called from the main thread.
func store_chunk_image(key: String, img: Image, craters: Array,
		populate_zones: Array = [], linear_features: Array = [],
		radial_features: Array = []) -> void:
	var id := _tile_id_from_key(key)
	_cache_mutex.lock()
	_chunk_images[id] = img
	_chunk_floats[id] = _decode_tile_floats(img)
	_cache_seq += 1
	_cache_tick[id] = _cache_seq
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
	var id := _tile_id_from_key(export_key)
	_cache_mutex.lock()
	if _chunk_images.has(id):
		var old_img: Image = _chunk_images[id]
		if old_img:
			_cache_bytes -= old_img.get_width() * old_img.get_height() * 4
		_chunk_images.erase(id)
		_chunk_floats.erase(id)
		_cache_tick.erase(id)
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
			# The zone's ground props, when the update carries them — the
			# rock rules (cracks_apply_to_zone, the rock tint) read them.
			for prop in ["rock_type", "clarity", "color_hex"]:
				if biome_update.has(prop):
					zone[prop] = biome_update[prop]
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
## (written by tools/planettech/qgis/export_planet.py::pack_planet_recipes()) and
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
## no such gap: tools/planettech/qgis/export/planet/modifier_geom.py writes a crater into
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
	clear_bridge_plans()
	clear_grade_profiles()


## The bridge settings for this planet, defaulting to a stock profile.
func get_bridge_profile() -> BridgeProfile:
	if bridge_profile != null:
		return bridge_profile
	if _bridge_profile_cache == null:
		_bridge_profile_cache = BridgeProfile.new()
	return _bridge_profile_cache


## Stable identity of a span. Mirrors PlanetTerrain's bridge-node key.
static func bridge_span_key(span: Dictionary) -> String:
	# Profile spans (railway / graded road) never collide with crack spans of
	# the same feature: they get a kind prefix.
	var kind := str(span.get("kind", ""))
	var prefix := ""
	if kind == GradeSettings.SPAN_KIND_RAILWAY:
		prefix = "rw_"
	elif kind == GradeSettings.SPAN_KIND_ROAD:
		prefix = "rp_"
	return "%sf%d_%d" % [prefix, int(span.get("feature_id", -1)),
			int(span.get("along_start", 0.0))]


## One whole road by feature id, from the same stitched set bridge detection
## walked — so a plan and its span describe the same polyline.
func get_whole_road(fid: int) -> Dictionary:
	_ensure_bridge_plans()
	return _whole_roads_by_fid.get(fid, {})


## The deck/ramp plan for [param span], or an empty dictionary when it has none.
func get_bridge_plan(span: Dictionary) -> Dictionary:
	_ensure_bridge_plans()
	return _bridge_plans.get(bridge_span_key(span), {})


## Stretches of road [param fid] that a bridge occupies, as merged, sorted,
## non-overlapping [lo, hi] along-road intervals. The ribbon must not be drawn
## there: it would lie across the ramps and hang over the gorge.
func get_bridge_exclusions_for_feature(fid: int) -> Array:
	if not corundum_default_biome:
		return []
	_ensure_bridge_plans()
	return _bridge_excl.get(fid, [])


## Build every deck/ramp plan now, on the calling thread.
##
## Call this on the MAIN thread at load time. The mesh workers cut the road
## ribbon out from under the ramps, and PlanetData's lazy caches are not
## thread-safe to populate — a worker filling this table while another reads it
## is the same race that once left patches of terrain untextured.
func warm_bridge_plans() -> void:
	# Rapatrier d'abord les tuiles des travées : elles sont peu nombreuses (37 sur
	# tarsis_3, une par gouffre, au niveau export) et sans elles la planification ne peut
	# que refuser. Sur un serveur fraîchement démarré c'est LA différence entre 21 ponts
	# et zéro tablier — donc entre un pont et un trou.
	#
	# AVANT _ensure_bridge_plans, donc hors du verrou : fetch_now bloque, et le tenir sous
	# _bridge_plans_mutex ferait attendre là tout worker demandant un plan.
	_prefetch_bridge_span_tiles(get_bridge_spans())
	_ensure_bridge_plans()


func clear_bridge_plans() -> void:
	_bridge_plans_mutex.lock()
	_bridge_plans.clear()
	_bridge_excl.clear()
	_bridge_excl_raw.clear()
	_bridge_spans_starved.clear()
	_whole_roads_by_fid.clear()
	_bridge_plans_built = false
	_bridge_plans_mutex.unlock()


## Plan every span in one pass. Call it from the main thread at load time
## (PlanetTerrain does); a worker thread reaching it first still works, but pays
## the tile reads inside the mutex.
func _ensure_bridge_plans() -> void:
	if _bridge_plans_built:
		return
	_bridge_plans_mutex.lock()
	if not _bridge_plans_built:
		_build_bridge_plans()
		_bridge_plans_built = true
	_bridge_plans_mutex.unlock()


## Rapatrie, en bloquant mais sous budget, les tuiles d'élévation dont la planification des
## travées a besoin. Appelé au chargement, sur le thread principal, hors du chemin critique
## — c'est exactement l'usage prévu de RemoteTileSource.fetch_now().
##
## Le budget existe pour une raison précise : fetch_now attend jusqu'à request_timeout_ms
## (10 s) par tuile. Sans borne, un service de tuiles en panne transformerait 37 travées en
## six minutes de démarrage bloqué. Ce qui n'est pas arrivé à temps n'est pas perdu : la
## travée part dans _bridge_spans_starved et le rattrapage la reprendra.
func _prefetch_bridge_span_tiles(spans: Array) -> void:
	if remote_source == null or spans.is_empty():
		return
	var deadline := Time.get_ticks_msec() + BRIDGE_PREFETCH_BUDGET_MS
	var wanted := {}
	for s in spans:
		if s.get("truncated", false):
			continue
		var ipix: int = HEALPix.vec2pix_nest(export_nside, s["mid_dir"])
		wanted[ipix] = true
	var got := 0
	for ipix: int in wanted:
		if Time.get_ticks_msec() > deadline:
			break
		if remote_source.fetch_now(export_nside, ipix):
			got += 1
	print("[PlanetData] préchargement des travées de '%s' : %d/%d tuile(s) n%d en %d ms max"
			% [planet_name, got, wanted.size(), export_nside, BRIDGE_PREFETCH_BUDGET_MS])


## Planifie UNE travée. Rend true si un plan en est sorti.
##
## Une travée refusée faute de tuile est mémorisée pour rattrapage ; une travée dont
## BridgePlan dit non est un refus définitif et n'est pas mémorisée.
func _plan_one_span(s: Dictionary, profile: BridgeProfile) -> bool:
	if s.get("truncated", false):
		return true      # Hors sujet, pas un échec : ne pas la compter comme sautée.
	var fid: int = int(s.get("feature_id", -1))
	var road: Dictionary = _whole_roads_by_fid.get(fid, {})
	if road.is_empty():
		return true
	# The tile is pinned to the span's own midpoint at export_nside, so the
	# plan cannot depend on which chunk asked for it — that dependency is
	# what let the client and the server disagree about a deck's altitude.
	var ipix: int = HEALPix.vec2pix_nest(export_nside, s["mid_dir"])
	if load_chunk_heightmap(ipix, export_nside) == null:
		# No tile means sample_height_for_direction would silently fall back
		# to the global equirect map — a flatter, different surface, the one
		# that once put props kilometres above the terrain. Refusing here
		# keeps deck and ribbon consistent: no plan, no deck, and no cut.
		# Mais refuser DÉFINITIVEMENT laisserait le gouffre sans tablier, donc sans
		# collision : on met la travée de côté au lieu de l'abandonner — sauf si la tuile
		# n'existe pas non plus en amont, auquel cas attendre serait attendre pour rien et
		# la file de rattrapage ne se viderait jamais.
		if remote_source != null:
			if remote_source.presence_of(export_nside, ipix) == RemoteTileSource.PRESENCE_NO:
				return false
			remote_source.queue(export_nside, ipix)
		_bridge_spans_starved.append(s)
		return false
	var plan := BridgePlan.compute(profile, s, road, radius,
			bridge_height_sampler(ipix), terrain_vertex_spacing_m())
	if not bool(plan.get("ok", false)):
		return false
	_bridge_plans[bridge_span_key(s)] = plan
	if not _bridge_excl_raw.has(fid):
		_bridge_excl_raw[fid] = []
	(_bridge_excl_raw[fid] as Array).append(
			Vector2(float(plan["excl_lo_along"]), float(plan["excl_hi_along"])))
	return true


## Refusionne les intervalles d'exclusion de chaque route.
##
## Fusionnés avant que quiconque les voie : deux gorges assez proches pour que leurs rampes
## se recouvrent laisseraient sinon un ruban en écharpe entre deux tabliers, c'est-à-dire un
## trou dans lequel on roule.
func _remerge_bridge_exclusions() -> void:
	for fid: int in _bridge_excl_raw:
		_bridge_excl[fid] = RoadCut.merge_intervals(_bridge_excl_raw[fid])


## Y a-t-il des travées en attente de leur tuile ?
func bridge_plans_incomplete() -> bool:
	return not _bridge_spans_starved.is_empty()


## Rejoue les travées affamées, et elles seules. Rend la liste des clés de travées dont un
## plan vient de naître — vide si rien n'a bougé.
##
## Appelé périodiquement par PlanetTerrain tant que bridge_plans_incomplete() : ne parcourt
## que la poignée en attente, jamais les 37, donc le tick n'en souffre pas.
func retry_starved_bridge_plans() -> PackedStringArray:
	var born := PackedStringArray()
	if _bridge_spans_starved.is_empty():
		return born
	_bridge_plans_mutex.lock()
	var pending := _bridge_spans_starved.duplicate()
	_bridge_spans_starved.clear()
	var profile := get_bridge_profile()
	for s: Dictionary in pending:
		if _plan_one_span(s, profile):
			born.append(bridge_span_key(s))
	if not born.is_empty():
		_remerge_bridge_exclusions()
	_bridge_plans_mutex.unlock()
	if not born.is_empty():
		print("[PlanetData] %d pont(s) planifié(s) en rattrapage sur '%s' — %d travée(s) encore en attente de tuile"
				% [born.size(), planet_name, _bridge_spans_starved.size()])
	return born


func _build_bridge_plans() -> void:
	var spans := get_bridge_spans()
	for r in get_whole_roads():
		_whole_roads_by_fid[int(r.get("feature_id", -1))] = r
	if spans.is_empty():
		return
	var profile := get_bridge_profile()
	var skipped := 0
	for s in spans:
		if not _plan_one_span(s, profile):
			skipped += 1
	_remerge_bridge_exclusions()
	var stranded: PackedStringArray = []
	var steepened := 0
	for k in _bridge_plans:
		var pl: Dictionary = _bridge_plans[k]
		if bool(pl.get("clamped", false)):
			stranded.append("%s (rims differ by %.0f m)"
					% [k, absf(float(pl["start_alt_m"]) - float(pl["end_alt_m"]))])
		if bool(pl.get("steepened", false)):
			steepened += 1
	print("[PlanetData] %d bridge plan(s) on '%s'" % [_bridge_plans.size(), planet_name]
			+ (" — %d skipped" % skipped if skipped else "")
			+ (" — %d ramp(s) steepened to reach falling ground" % steepened if steepened else "")
			+ (" — %d abutment(s) left on a step" % stranded.size() if stranded.size() else ""))
	if stranded.size() > 0:
		# Named, not counted: these crossings need re-routing in QGIS, and a
		# bare number gives nobody anything to act on.
		push_warning("[PlanetData] '%s': no ramp can reach the ground at %s. "
				% [planet_name, ", ".join(stranded)]
				+ "Even sloping the deck to its cap leaves more height than a "
				+ "ramp can make up — the road crosses a cliff rather than a "
				+ "gorge, or ends at one. Re-route it or move the crossing.")


# ── Grade-limited lines (railways, graded roads) ──────────────────────────

## Does this planet's modifier pack carry at least one railway? Cheap and
## available before the profiles are built: the pack's string table lists
## every road_type it interns. Gates the RAIL-only work (modules, rail
## collision); the profile machinery asks has_profiled_lines() instead.
func has_railways() -> bool:
	if _has_railways >= 0:
		return _has_railways == 1
	var pack = _ensure_modifier_pack()
	if pack == null:
		# Not memoised: the pack may simply not be configured yet.
		return false
	var strings: Array = pack.get_manifest().get("strings", [])
	var found := strings.has("railway")
	_has_railways = 1 if found else 0
	return found


## Does this planet carry a region of a biome with a relief noise
## (BiomeDefinition.relief_*)? The pack's string table interns every zone's
## biome_type, so this is known before any tile is read. Gates the fine server
## collision: the relief exists in the mesh only where the grid can carry it,
## and the collision must be on that same grid.
func has_relief_biomes() -> bool:
	if _has_relief_biomes >= 0:
		return _has_relief_biomes == 1
	var pack = _ensure_modifier_pack()
	if pack == null:
		return false
	var strings: Array = pack.get_manifest().get("strings", [])
	var found := false
	_auto_load_all_biomes()
	for bd in _all_biomes:
		if bd != null and bd.has_relief() and strings.has(bd.biome_type):
			found = true
			break
	_has_relief_biomes = 1 if found else 0
	return found


## Fingerprint of the biome regions part (parts/biomes.dsmpart) as echoed into
## the pack manifest, "" when the pack has no regions. PlanetTerrain folds it
## into the chunk cache key.
func populate_fingerprint() -> String:
	var pack = _ensure_modifier_pack()
	if pack == null:
		return ""
	var parts: Dictionary = pack.get_manifest().get("parts", {})
	return str((parts.get("populate", {}) as Dictionary).get("fingerprint", ""))


## Does this planet carry procedural mountains — a mountain or ridge part in
## the pack, or the debug / test injection? Gates the fine server collision
## like the relief biomes: the mountains exist in the mesh only where the
## grid carries their octaves, and the collision must be on that same grid.
func has_mountains() -> bool:
	if _has_mountains >= 0:
		return _has_mountains == 1
	warm_mountains()
	return _has_mountains == 1


## [method has_mountains] without the resolve: true only once warm_mountains
## has run (main thread) and found features. What a chunk worker may ask —
## resolving from a worker would warm the mountains under the profiles and
## bridge plans already built without them.
func mountains_active() -> bool:
	return _has_mountains == 1


## Resolve has_mountains() and the finest pitch, and build the debug features.
## MAIN THREAD, before the first chunk task (PlanetTerrain.initialize does it
## before the bridge spans, whose profiles must already see the relief).
func warm_mountains() -> void:
	_mtn_finest_spacing = terrain_vertex_spacing_m()
	var found := false
	var pack = _ensure_modifier_pack()
	if pack != null:
		var parts: Dictionary = pack.get_manifest().get("parts", {})
		for kind in ["mountain", "ridge"]:
			var counts: Dictionary = (parts.get(kind, {}) as Dictionary).get("counts", {})
			if int(counts.get("features", 0)) > 0:
				found = true
	if not found and debug_mountain_enabled and _mtn_override_zones.is_empty() \
			and _mtn_override_ridges.is_empty():
		_build_debug_mountains()
	if not _mtn_override_zones.is_empty() or not _mtn_override_ridges.is_empty():
		found = true
	_has_mountains = 1 if found else 0


## Tests / tools: stand-in features for the whole planet (every tile returns
## them). [param zones] / [param ridges] are record Dictionaries in the pack's
## decoded shape (see ModifierPack._decode_populate + MountainRelief.prepare_*).
## Main thread only; call before any chunk is built.
func set_mountain_overrides(zones: Array, ridges: Array) -> void:
	_mtn_override_zones.clear()
	_mtn_override_ridges.clear()
	var mpd := radius * PI / 180.0
	for z in zones:
		_mtn_override_zones.append(MountainRelief.prepare_zone(z))
	for r in ridges:
		_mtn_override_ridges.append(MountainRelief.prepare_ridge(r, mpd))
	_mtn_override_set = MountainRelief.build_set(_mtn_override_zones, _mtn_override_ridges)
	_has_mountains = -1
	warm_mountains()


func _build_debug_mountains() -> void:
	var zones: Array = []
	var ridges: Array = []
	if debug_mountain_radius_km > 0.0:
		var mpd := radius * PI / 180.0
		var r_deg := debug_mountain_radius_km * 1000.0 / mpd
		var lat_c := cos(deg_to_rad(clampf(debug_mountain_lonlat.y, -89.5, 89.5)))
		var poly := PackedVector2Array()
		for i in 32:
			var a := TAU * float(i) / 32.0
			poly.append(debug_mountain_lonlat + Vector2(cos(a) * r_deg / maxf(lat_c, 0.05), sin(a) * r_deg))
		var z := debug_mountain_style.duplicate()
		z["coverage"] = "partial"
		z["polygon"] = poly
		z["name"] = "debug"
		zones.append(z)
	if debug_ridge_points.size() >= 2:
		var rd := debug_ridge_style.duplicate()
		rd["polygon"] = debug_ridge_points
		rd["name"] = "debug"
		ridges.append(rd)
	set_mountain_overrides(zones, ridges)


## Fingerprint of the mountain and ridge parts as echoed into the pack
## manifest ("" without them) — PlanetTerrain folds it into the cache key.
func mountain_fingerprint() -> String:
	var pack = _ensure_modifier_pack()
	if pack == null:
		return ""
	var parts: Dictionary = pack.get_manifest().get("parts", {})
	var a := str((parts.get("mountain", {}) as Dictionary).get("fingerprint", ""))
	var b := str((parts.get("ridge", {}) as Dictionary).get("fingerprint", ""))
	if a == "" and b == "":
		return ""
	return (a + "-" + b).sha1_text().substr(0, 12)


## Prepared mountain_range zones for the pack tile ([param level], [param ipix])
## — `level` ≤ export_nside, the kind is baked n1..export_nside. Overrides
## replace the pack wholesale (debug / tests).
func get_chunk_mountain_zones(level: int, ipix: int) -> Array:
	if not _mtn_override_zones.is_empty() or not _mtn_override_ridges.is_empty():
		return _mtn_override_zones
	return get_chunk_modifiers(level, ipix).get("mountain_zones", [])


func get_chunk_ridges(level: int, ipix: int) -> Array:
	if not _mtn_override_zones.is_empty() or not _mtn_override_ridges.is_empty():
		return _mtn_override_ridges
	return get_chunk_modifiers(level, ipix).get("ridge_lines", [])


## The MountainSetNative of that tile (null → GDScript path over the lists).
func get_chunk_mountain_set(level: int, ipix: int) -> RefCounted:
	if not _mtn_override_zones.is_empty() or not _mtn_override_ridges.is_empty():
		return _mtn_override_set
	return get_chunk_modifiers(level, ipix).get("mountain_set", null)


## Give [param frame] the mountain features of chunk (hp_nside, hp_ipix): the
## records of its export-level tile — or, for a chunk coarser than that, of
## its own level (a 3 km massif must show from LOD 3). Called right after
## make_tile_frame() by both chunk builders; the stitch shares the frame.
func prepare_mountain_frame(frame: TileFrame, hp_nside: int, hp_ipix: int) -> void:
	if frame == null:
		return
	if _has_mountains != 1 or hp_nside <= 0 or hp_ipix < 0:
		frame.mtn_ready = true
		return
	var level := hp_nside
	var ip := hp_ipix
	while level > export_nside:
		ip >>= 2
		level >>= 1
	frame.mtn = get_chunk_mountain_zones(level, ip)
	frame.rdg = get_chunk_ridges(level, ip)
	frame.mtn_set = get_chunk_mountain_set(level, ip)
	frame.mtn_ready = true


## The mountain offset (m) at [param dir] — see sample_height_for_direction.
## Worker-thread safe: the frame is the caller's own, get_chunk_modifiers has
## its mutex, and MountainRelief is pure.
func _mountain_offset(dir: Vector3, frame: TileFrame, vtx_spacing_m: float) -> float:
	var zones: Array
	var ridges: Array
	var mset: RefCounted
	if frame != null and frame.mtn_ready:
		zones = frame.mtn
		ridges = frame.rdg
		mset = frame.mtn_set
	else:
		var ip := HEALPix.vec2pix_nest(export_nside, dir)
		mset = get_chunk_mountain_set(export_nside, ip)
		if mset == null:
			zones = get_chunk_mountain_zones(export_nside, ip)
			ridges = get_chunk_ridges(export_nside, ip)
	var eff := maxf(vtx_spacing_m, _mtn_finest_spacing)
	if mset != null:
		return mset.Offset(dir, radius, eff)
	if zones.is_empty() and ridges.is_empty():
		return 0.0
	return MountainRelief.offset(dir, radius, zones, ridges, eff)


## How deep inside a massif [param dir] is — MountainRelief.core over the
## same features [method _mountain_offset] sums, 0 without mountains. Feeds
## the rock impurity fields (RockImpurity): the chunk builders bake it into
## the vertex colours, the server reads it at a mined point. Worker-thread
## safe for the same reasons as the offset.
func mountain_core(dir: Vector3, frame: TileFrame = null) -> float:
	if _has_mountains != 1:
		return 0.0
	var zones: Array
	var ridges: Array
	var mset: RefCounted
	if frame != null and frame.mtn_ready:
		zones = frame.mtn
		ridges = frame.rdg
		mset = frame.mtn_set
	else:
		var ip := HEALPix.vec2pix_nest(export_nside, dir)
		mset = get_chunk_mountain_set(export_nside, ip)
		if mset == null:
			zones = get_chunk_mountain_zones(export_nside, ip)
			ridges = get_chunk_ridges(export_nside, ip)
	if mset != null:
		return mset.Core(dir, radius)
	if zones.is_empty() and ridges.is_empty():
		return 0.0
	return MountainRelief.core(dir, radius, zones, ridges)


## How much the ground along [param dir] belongs to a mountain feature
## (MountainRelief.mask over crack_mountain_fade_m, in [0, 1]) — 0 without
## mountains. Same frame / tile resolution as [method mountain_core].
func mountain_mask(dir: Vector3, frame: TileFrame = null) -> float:
	if _has_mountains != 1:
		return 0.0
	var zones: Array
	var ridges: Array
	var mset: RefCounted
	if frame != null and frame.mtn_ready:
		zones = frame.mtn
		ridges = frame.rdg
		mset = frame.mtn_set
	else:
		var ip := HEALPix.vec2pix_nest(export_nside, dir)
		mset = get_chunk_mountain_set(export_nside, ip)
		if mset == null:
			zones = get_chunk_mountain_zones(export_nside, ip)
			ridges = get_chunk_ridges(export_nside, ip)
	if mset != null:
		return mset.Mask(dir, radius, crack_mountain_fade_m)
	if zones.is_empty() and ridges.is_empty():
		return 0.0
	return MountainRelief.mask(dir, radius, zones, ridges, crack_mountain_fade_m)


## Does this planet carry any road at all (the pack's road part has features)?
## Gates the fine server collision: a road is an 8 cm slab with its own
## collision (RoadRibbon), which only makes sense on the grid the mesh uses.
func has_roads() -> bool:
	if _has_roads >= 0:
		return _has_roads == 1
	var pack = _ensure_modifier_pack()
	if pack == null:
		return false
	var parts: Dictionary = pack.get_manifest().get("parts", {})
	var road_part: Dictionary = parts.get("road", {})
	var counts: Dictionary = road_part.get("counts", {})
	var found := int(counts.get("features", 0)) > 0
	_has_roads = 1 if found else 0
	return found


## Does this planet carry any line that rides a grade-limited profile — a
## railway, or a highway / road exported with a max slope? The road part
## manifest counts the latter ("profiled_roads", written by export_roads.py),
## so the answer is known before any tile is read.
func has_profiled_lines() -> bool:
	if _has_profiled_lines >= 0:
		return _has_profiled_lines == 1
	var pack = _ensure_modifier_pack()
	if pack == null:
		return false
	var found := has_railways()
	if not found:
		var parts: Dictionary = pack.get_manifest().get("parts", {})
		var road_part: Dictionary = parts.get("road", {})
		found = int(road_part.get("profiled_roads", 0)) > 0
	_has_profiled_lines = 1 if found else 0
	return found


## Build every profile now, on the calling thread. Call it on the MAIN
## thread at load time, right after warm_bridge_plans(): the bed builders on
## the mesh workers read these tables, and PlanetData's lazy caches are not
## thread-safe to populate.
func warm_grade_profiles() -> void:
	if not has_profiled_lines():
		return
	# Outside the lock, like the bridge prefetch: fetch_now blocks.
	_prefetch_grade_tiles()
	_ensure_grade_profiles()


func clear_grade_profiles() -> void:
	# A task in flight cannot be cancelled: let it finish, then forget it.
	for fid: int in _grade_pending.keys():
		WorkerThreadPool.wait_for_task_completion(int((_grade_pending[fid] as Dictionary)["task_id"]))
	_grade_pending.clear()
	_grade_mutex.lock()
	_grade_profiles.clear()
	_grade_spans.clear()
	_grade_plans.clear()
	_grade_excl.clear()
	_grade_starved.clear()
	_grade_starved_tiles.clear()
	_grade_tiles_by_fid.clear()
	_carve_pieces_cache.clear()
	_grade_built = false
	_has_railways = -1
	_has_profiled_lines = -1
	_has_relief_biomes = -1
	_grade_mutex.unlock()


## The profile of line [param fid], or {} when it has none (not profiled, or
## its terrain tiles were not available when the profiles were built).
func get_grade_profile(fid: int) -> Dictionary:
	if not has_profiled_lines():
		return {}
	_ensure_grade_profiles()
	return _grade_profiles.get(fid, {})


## Every viaduct span of every profiled line (kind railway / profiled_road),
## in RoadBridge's shape.
func get_grade_spans() -> Array:
	if not has_profiled_lines():
		return []
	_ensure_grade_profiles()
	return _grade_spans


## The deck plan of a viaduct [param span], or {} when it has none.
func get_grade_plan(span: Dictionary) -> Dictionary:
	if not has_profiled_lines():
		return {}
	_ensure_grade_profiles()
	return _grade_plans.get(bridge_span_key(span), {})


## Stretches of line [param fid] a viaduct deck occupies, as merged, sorted
## [lo, hi] along-intervals. The bed must not be built there.
func get_grade_exclusions_for_feature(fid: int) -> Array:
	if not has_profiled_lines():
		return []
	_ensure_grade_profiles()
	return _grade_excl.get(fid, [])


func _ensure_grade_profiles() -> void:
	if _grade_built:
		return
	_grade_mutex.lock()
	if not _grade_built:
		_build_grade_profiles()
		_grade_built = true
	_grade_mutex.unlock()


## The whole profiled-line records, from the pack's coarsest level.
func _whole_profiled_lines() -> Array:
	var out: Array = []
	for r in get_whole_roads():
		if GradeSettings.is_profiled(r):
			out.append(r)
	return out


## Export tiles under the stations of [param road], every STATION_STEP_M —
## exactly the directions GradeProfile.compute samples. Memoised per feature.
func _grade_tiles(road: Dictionary) -> Dictionary:
	var fid := int(road.get("feature_id", -1))
	if _grade_tiles_by_fid.has(fid):
		return _grade_tiles_by_fid[fid]
	var cl: PackedVector2Array = road.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	var tiles := {}
	if cl.size() < 2 or cum.size() != cl.size():
		return tiles
	var s: float = cum[0]
	var last: float = cum[cum.size() - 1]
	while s <= last:
		tiles[HEALPix.vec2pix_nest(export_nside, GradeGeom.dir_at(cl, cum, s))] = true
		s += GradeSettings.STATION_STEP_M
	tiles[HEALPix.vec2pix_nest(export_nside, GradeGeom.dir_at(cl, cum, last))] = true
	_grade_tiles_by_fid[fid] = tiles
	return tiles


## The export tiles under line [param fid] AND their eight neighbours: the
## bed's skirts and a cutting's walls reach a few tens of metres past the
## centreline, so a chunk in the tile next door can carry them too. This is
## the set of chunks whose geometry depends on the line's profile.
func grade_line_export_tiles(fid: int) -> Dictionary:
	var out := {}
	var tiles: Dictionary = _grade_tiles_by_fid.get(fid, {})
	for ipix: int in tiles:
		out[ipix] = true
		for nb: int in HEALPix.get_neighbors_nest(export_nside, ipix).values():
			if nb >= 0:
				out[nb] = true
	return out


## Are the tiles of a line all readable? Returns
## { missing: int, hopeless: bool } — hopeless when at least one missing tile
## can never arrive (no streaming source, or the service publishes no tile
## there and the pack has nothing to climb to), so waiting would be for
## nothing. Queues every missing tile on the streaming source otherwise.
func _grade_tiles_missing(tiles: Dictionary) -> Dictionary:
	var missing := 0
	var hopeless := false
	for ipix: int in tiles:
		if _grade_tile_available(ipix):
			continue
		missing += 1
		if remote_source == null:
			hopeless = true
			continue
		# The finest PUBLISHED ancestor is what the profile must read (see
		# TileResidency.tile_available): ask for it; nothing published at
		# all down the chain is the hopeless case.
		if TileResidency.finest_published_ancestor_state(self, ipix, export_nside, true) \
				== TileResidency.PUBLISHED_NONE:
			hopeless = true
	return {"missing": missing, "hopeless": hopeless}


## Is the export tile [param ipix] readable for the profile sampler — stored,
## or pruned from a sparse pack with its finest PUBLISHED ancestor here to
## climb to? The same rule as the chunk builders (TileResidency), so the
## profile and the terrain it lays the bed on come from the same tiles —
## on the client AND on the server.
func _grade_tile_available(ipix: int) -> bool:
	return TileResidency.tile_available(self, ipix, export_nside)


## Blocking, budgeted fetch of the tiles under every profiled line (remote packs).
func _prefetch_grade_tiles() -> void:
	if remote_source == null:
		return
	var wanted := {}
	for r in _whole_profiled_lines():
		wanted.merge(_grade_tiles(r))
	if wanted.is_empty():
		return
	var deadline := Time.get_ticks_msec() + GRADE_PREFETCH_BUDGET_MS
	var got := 0
	for ipix: int in wanted:
		if Time.get_ticks_msec() > deadline:
			break
		if remote_source.fetch_now(export_nside, ipix):
			got += 1
	print("[PlanetData] préchargement des voies ferrées de '%s' : %d/%d tuile(s) n%d en %d ms max"
			% [planet_name, got, wanted.size(), export_nside, GRADE_PREFETCH_BUDGET_MS])


## The profile sampler: the finest tile under each direction, resolved per
## call (a line crosses hundreds of export tiles, unlike a bridge span).
## Identical on the client and the server, which is the whole point.
func grade_height_sampler() -> Callable:
	var ns := export_nside
	# One frame for the whole walk: the per-tile precomputations (floats,
	# face, neighbours) are then paid once per tile crossed, not per station.
	var frame := make_tile_frame()
	return func(dir: Vector3) -> float:
		return sample_height_for_direction(dir, -1, -1, Vector2i(-1, -1), null, ns, frame)


func _build_grade_profiles() -> void:
	var lines := _whole_profiled_lines()
	if lines.is_empty():
		return
	var skipped := 0
	var t0 := Time.get_ticks_msec()
	for road in lines:
		# Every tile under the line must be readable: one missing tile would
		# make sample_height_for_direction fall back to the flat global map
		# for that stretch, and the client and the server would then lay the
		# track at different altitudes. No profile, no bed on the profile —
		# the chunk falls back to the terrain-hugging ribbon instead. A line
		# whose tiles are merely not downloaded yet is set aside for the
		# catch-up, not abandoned (see retry_starved_grade_profiles); one
		# whose tiles are all here is profiled on a worker thread.
		var tiles := _grade_tiles(road)
		var state := _grade_tiles_missing(tiles)
		if int(state["missing"]) > 0:
			if not bool(state["hopeless"]):
				_grade_starve(road, tiles)
			else:
				skipped += 1
			continue
		_grade_submit(road, tiles)
	print("[PlanetData] %s — %d ms" % [_grade_summary(), Time.get_ticks_msec() - t0]
			+ (" — %d skipped (terrain tiles not available)" % skipped if skipped else "")
			+ (" — %d awaiting tiles" % _grade_starved.size() if not _grade_starved.is_empty() else "")
			+ (" — %d profiling in the background" % _grade_pending.size() if not _grade_pending.is_empty() else ""))
	if skipped:
		push_warning("[PlanetData] '%s': %d line(s) left without a profile; their bed "
				% [planet_name, skipped]
				+ "follows the terrain until the elevation tiles under them are available.")


## Set [param road] aside until its [param tiles] are all on disk.
func _grade_starve(road: Dictionary, tiles: Dictionary) -> void:
	_grade_starved.append({"road": road, "tiles": tiles})
	_grade_starve_tiles_only(tiles)


## Profile [param road] on a worker thread; its chunks stay provisional
## until retry_starved_grade_profiles() collects the result. The sampler and
## its TileFrame are created INSIDE the task: a frame is a per-thread cache,
## like the one every mesh task makes for itself.
func _grade_submit(road: Dictionary, tiles: Dictionary) -> void:
	var fid := int(road.get("feature_id", -1))
	if _grade_pending.has(fid):
		return
	var result_ref: Array = [null]
	var task_id := WorkerThreadPool.add_task(
		func():
			result_ref[0] = GradeProfile.compute(road, grade_height_sampler()),
		false, "grade profile %s fid %d" % [planet_name, fid])
	_grade_pending[fid] = {"task_id": task_id, "result_ref": result_ref,
			"road": road, "tiles": tiles}
	_grade_starve_tiles_only(tiles)


## Register a computed profile: the profile itself, its viaduct spans and
## deck plans, and the bed exclusions under the decks. Returns false when
## GradeProfile itself said no (a definitive refusal).
func _grade_register(road: Dictionary, profile: Dictionary) -> bool:
	if not bool(profile.get("ok", false)):
		return false
	var fid := int(road.get("feature_id", -1))
	_grade_profiles[fid] = profile
	var plans: Array = []
	for span in GradeProfile.spans_of(profile, road):
		var plan := GradeProfile.plan_of(profile, span, road, radius)
		if not bool(plan.get("ok", false)):
			continue
		_grade_spans.append(span)
		_grade_plans[bridge_span_key(span)] = plan
		plans.append(plan)
	_grade_excl[fid] = GradeProfile.exclusions_of(plans)
	return true


func _grade_summary() -> String:
	var n_gorge := 0
	var n_tunnel := 0
	var n_bridge := 0
	for fid: int in _grade_profiles:
		for seg in (_grade_profiles[fid] as Dictionary)["segments"]:
			match int(seg["kind"]):
				GradeSettings.Kind.GORGE: n_gorge += 1
				GradeSettings.Kind.TUNNEL: n_tunnel += 1
				GradeSettings.Kind.BRIDGE: n_bridge += 1
	return "%d line profile(s) on '%s' — %d cutting(s), %d tunnel(s), %d viaduct(s)" % [
			_grade_profiles.size(), planet_name, n_gorge, n_tunnel, n_bridge]


## Is at least one profiled line still without its profile — waiting for
## its tiles, or being computed?
func grade_profiles_incomplete() -> bool:
	return not _grade_starved.is_empty() or not _grade_pending.is_empty()


## Does the geometry of chunk (nside, ipix) depend on a profile that is not
## born yet? True inside the tiles of a starved or pending line (and their
## neighbours): such a chunk carries the terrain-hugging ribbon now and the
## bed, the cutting or the tunnel later, so PlanetTerrain must not persist it.
func grade_chunk_provisional(nside: int, ipix: int) -> bool:
	if _grade_starved_tiles.is_empty() or nside <= 0 or ipix < 0:
		return false
	if nside >= export_nside:
		var e := ipix
		var ns := nside
		while ns > export_nside:
			e >>= 2
			ns >>= 1
		return _grade_starved_tiles.has(e)
	# A chunk coarser than the export level covers several export tiles:
	# provisional if any starved tile descends from it.
	var shift := 0
	var ns := nside
	while ns < export_nside:
		shift += 2
		ns <<= 1
	for t: int in _grade_starved_tiles:
		if (t >> shift) == ipix:
			return true
	return false


## Collect the profiles whose computation has finished, and submit the
## starved lines whose tiles have all arrived. Returns the feature ids whose
## profile was just born — empty when nothing moved. Called periodically by
## PlanetTerrain while grade_profiles_incomplete(); the tile walk is
## memoised, so a retry costs one availability check per tile.
## [param block] waits for the computations instead of skipping the ones
## still running — tools only; a task once waited for is gone from the pool,
## so is_task_completed() cannot be asked about it afterwards.
func retry_starved_grade_profiles(block: bool = false) -> PackedInt32Array:
	var born := PackedInt32Array()
	if _grade_starved.is_empty() and _grade_pending.is_empty():
		return born
	_grade_mutex.lock()
	for fid: int in _grade_pending.keys():
		var entry: Dictionary = _grade_pending[fid]
		if not block and not WorkerThreadPool.is_task_completed(int(entry["task_id"])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(entry["task_id"]))
		_grade_pending.erase(fid)
		var profile: Dictionary = entry["result_ref"][0] if entry["result_ref"][0] != null else {}
		if _grade_register(entry["road"], profile):
			born.append(fid)
	var pending := _grade_starved.duplicate()
	_grade_starved.clear()
	for entry: Dictionary in pending:
		var tiles: Dictionary = entry["tiles"]
		var state := _grade_tiles_missing(tiles)
		if int(state["missing"]) > 0:
			if not bool(state["hopeless"]):
				_grade_starved.append(entry)
			continue
		_grade_submit(entry["road"], tiles)
	# The provisional set shrinks to what is still waiting or computing.
	_grade_starved_tiles.clear()
	for entry: Dictionary in _grade_starved:
		_grade_starve_tiles_only(entry["tiles"])
	for fid: int in _grade_pending:
		_grade_starve_tiles_only((_grade_pending[fid] as Dictionary)["tiles"])
	_grade_mutex.unlock()
	if not born.is_empty():
		print("[PlanetData] %d profil(s) de ligne né(s) sur '%s' — %s — %d ligne(s) en attente de tuile, %d en calcul"
				% [born.size(), planet_name, _grade_summary(), _grade_starved.size(), _grade_pending.size()])
	return born


## BLOCKING: bring every profile to birth now — fetch the tiles of the
## starved lines (streaming source), wait for the worker tasks, register.
## For tools and tests (the railway probe); the game never waits, it polls.
## Returns the feature ids born. [param max_rounds] bounds the fetch loops.
func flush_grade_profiles(max_rounds: int = 3) -> PackedInt32Array:
	var born := PackedInt32Array()
	if not has_profiled_lines():
		return born
	_ensure_grade_profiles()
	for _round in max_rounds:
		if not grade_profiles_incomplete():
			break
		if remote_source != null:
			for entry: Dictionary in _grade_starved:
				for ipix: int in (entry["tiles"] as Dictionary):
					remote_source.fetch_now(export_nside, ipix)
		born.append_array(retry_starved_grade_profiles(true))
	# Tasks submitted by the last retry.
	born.append_array(retry_starved_grade_profiles(true))
	return born


func _grade_starve_tiles_only(tiles: Dictionary) -> void:
	for ipix: int in tiles:
		_grade_starved_tiles[ipix] = true
		for nb: int in HEALPix.get_neighbors_nest(export_nside, ipix).values():
			if nb >= 0:
				_grade_starved_tiles[nb] = true


## Vertex spacing, in metres, of the FINEST terrain mesh this planet builds.
##
## Mirrors PlanetChunk's own `_crack_vtx_spacing` (HEALPix pixel side over the
## chunk resolution), because that grid is what decides where the rendered and
## collided chasm rim actually is: the mesh samples crack_offset at its
## vertices, so the last solid vertex can be a whole spacing outside the
## analytic rim. Bridge abutments are sized on this.
func terrain_vertex_spacing_m() -> float:
	var finest_nside: int = 1 << maxi(max_quadtree_depth, 0)
	var res: int = maxi(chunk_resolution, 1)
	return HEALPix.pixel_side_length(finest_nside, radius) / float(res)


## Terrain sampler for the bridge builders: altitude for a direction, read from
## ONE pinned export tile so every sample of one bridge comes off the same
## bilinear surface with no seam inside the deck.
func bridge_height_sampler(ipix: int) -> Callable:
	var ns := export_nside
	return func(dir: Vector3) -> float:
		return sample_height_for_direction(dir, ipix, -1, Vector2i(-1, -1), null, ns)


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
	while _cache_bytes > MAX_CACHE_BYTES and _cache_tick.size() > 0:
		# Le rang le plus bas est la tuile la moins récemment lue. Le balayage est linéaire,
		# mais il ne tourne qu'ici — pas sur le chemin d'échantillonnage.
		var oldest_id: int = -1
		var oldest_tick: int = 0
		for id in _cache_tick:
			var t: int = _cache_tick[id]
			if oldest_id < 0 or t < oldest_tick:
				oldest_id = id
				oldest_tick = t
		_cache_tick.erase(oldest_id)
		var old_img: Image = _chunk_images.get(oldest_id)
		if old_img != null:
			_cache_bytes -= old_img.get_width() * old_img.get_height() * 4
		_chunk_images.erase(oldest_id)
		_chunk_floats.erase(oldest_id)
	_cache_mutex.unlock()


## Sample height from the chunk heightmap tile for a given direction vector.
## dir: unit direction on the sphere
## The function finds which export-level HEALPix pixel contains this direction,
## loads it, then samples bilinearly at the correct local UV position.
## When [param known_export_ipix] >= 0 it is used directly instead of calling
## vec2pix_nest, avoiding mis-classification at the polar/equatorial cap boundary.
## [param frame] — cadre du chunk appelant ([method make_tile_frame]). Quand il est fourni,
## il rend les trois paramètres précédents inutiles : c'est LUI qui donne face, position et
## voisines, pour la tuile réellement lue — après remontée de niveau comprise, ce que des
## précalculs passés à la main ne peuvent pas suivre.
## [param vtx_spacing_m] — vertex pitch of the grid being built, the LOD gate
## of the procedural mountains (MountainRelief): 0 = "full detail", what every
## gameplay query wants, and what the finest chunk gets too (the gate is
## floored at the finest pitch). Chunk builders, normal probes and the LOD
## stitch pass their own pitch. Without mountains the value is never read.
func sample_height_for_direction(dir: Vector3, known_export_ipix: int = -1,
		_precomp_face: int = -1, _precomp_xy: Vector2i = Vector2i(-1, -1),
		_cached_neighbors = null, nside: int = -1, frame: TileFrame = null,
		vtx_spacing_m: float = 0.0) -> float:
	var h := _base_height_for_direction(dir, known_export_ipix,
			_precomp_face, _precomp_xy, _cached_neighbors, nside, frame)
	if _has_mountains != 1:
		return h
	# Hot path of every mountain chunk (5 samples a vertex): the frame's C#
	# set is answered right here, one call; everything else goes through
	# _mountain_offset.
	if frame != null and frame.mtn_ready and frame.mtn_set != null:
		return h + frame.mtn_set.Offset(dir, radius, maxf(vtx_spacing_m, _mtn_finest_spacing))
	return h + _mountain_offset(dir, frame, vtx_spacing_m)


## The heightmap alone (pack tiles, pyramid climb, equirect fallback) — the
## body sample_height_for_direction wraps. Both fallback returns live here, so
## the mountain offset applies to every path.
func _base_height_for_direction(dir: Vector3, known_export_ipix: int = -1,
		_precomp_face: int = -1, _precomp_xy: Vector2i = Vector2i(-1, -1),
		_cached_neighbors = null, nside: int = -1, frame: TileFrame = null) -> float:
	if PropNet.prof_on:
		# Les constructeurs de chunks passent TOUJOURS known_export_ipix (ils savent dans
		# quelle tuile ils travaillent) ; une requête de gameplay ne le connaît pas et le
		# fait déduire de la direction. Ce seul bit sépare "génération de terrain" de
		# "quelqu'un demande l'altitude du sol", et ne coûte rien.
		_prof_count_sampler("dir_chunk" if known_export_ipix >= 0 else "dir_query")
	# nside <= 0 → finest level (export_nside). Chunk builders pass the chunk's
	# own pyramid level so a coarse chunk reads its coarse tile, not many fine ones.
	var ns := nside if nside > 0 else export_nside
	var ipix: int
	if known_export_ipix >= 0:
		ipix = known_export_ipix
	else:
		ipix = HEALPix.vec2pix_nest(ns, dir)
	var floats := frame.floats(ipix, ns) if frame != null else load_chunk_floats(ipix, ns)
	if floats.is_empty() and pack_is_sparse():
		# Pack creux : cette tuile n'a pas été stockée parce que l'upsample de son parent
		# la reproduit à epsilon près. On remonte donc au plus fin ancêtre présent — et
		# l'UV doit être recalculé pour LUI, ce qui est la raison pour laquelle la
		# remontée vit ici et non dans le chargement de tuile.
		var up := _finest_present_ancestor(ipix, ns)
		if up.y > 0:
			# Élaguée pour de bon, ou simplement pas encore arrivée ? La carte de présence
			# tranche, et sans jamais bloquer. Dans le doute (carte du shard pas encore
			# là), on compte la remontée comme provisoire : la géométrie reste utilisable
			# tout de suite, elle n'est simplement pas persistée.
			if _climb_is_guess(ns, ipix):
				climb_mark()
			ipix = up.x
			ns = up.y
			floats = frame.floats(ipix, ns) if frame != null else load_chunk_floats(ipix, ns)
			# Tout ce que l'appelant a précalculé décrit la tuile DEMANDÉE et ne décrit
			# plus celle qu'on vient de choisir. Les voisins désigneraient un autre pixel
			# dans la marge de mélange ; et _precomp_xy, surtout, est la position ENTIÈRE
			# du pixel à son niveau — elle est divisée par deux à chaque remontée, donc la
			# garder décale l'UV local et lit le terrain ailleurs. (La face, elle, est
			# invariante par la remontée : le parent d'un pixel est sur la même face.)
			# Le constructeur de collision remplit ces deux paramètres depuis longtemps :
			# sur un pack creux — celui de tarsis_3 l'est à 69,5 % — la collision
			# échantillonnait donc un autre endroit que le rendu partout où la tuile fine
			# est élaguée.
			_cached_neighbors = null
			_precomp_face = -1
			_precomp_xy = Vector2i(-1, -1)
	# Le cadre, lui, est indexé par tuile : il donne les précalculs de celle qu'on lit
	# vraiment, y compris après la remontée ci-dessus. C'est pour ça qu'il est renseigné
	# ICI et non chez l'appelant.
	if frame != null:
		var pc: Array = frame.entry(ipix, ns)
		_precomp_face = pc[1]
		_precomp_xy = pc[2]
		_cached_neighbors = pc[3]
	if floats.is_empty():
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
	# Côté de la tuile déduit du tableau, PAS de chunk_heightmap_res : les deux coïncident
	# pour les tuiles du pack, mais le chemin recipe et les tuiles synthétiques des tests
	# stockent d'autres tailles — les supposer égales lisait hors des bornes.
	var res := _tile_side(floats)
	if res <= 0:
		return sample_height_at(dir)
	var h := _sample_image_bilinear_healpix(floats, res,
			local_uv.x, local_uv.y, ipix, _cached_neighbors, ns, frame)
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
## [param frame] — voir [method sample_height_for_direction]. Il vaut surtout ici : un
## sommet de bord qui bascule sur la tuile voisine repartait sans aucun précalcul.
func sample_height_boundary(dir: Vector3, chain_ipix: int,
		_precomp_face: int = -1, _precomp_xy: Vector2i = Vector2i(-1, -1),
		_cached_neighbors = null, nside: int = -1, frame: TileFrame = null,
		vtx_spacing_m: float = 0.0) -> float:
	if PropNet.prof_on:
		_prof_count_sampler("boundary")
	var ns := nside if nside > 0 else export_nside
	var vec_ipix := HEALPix.vec2pix_nest(ns, dir)
	if vec_ipix == chain_ipix:
		return sample_height_for_direction(dir, chain_ipix,
				_precomp_face, _precomp_xy, _cached_neighbors, ns, frame, vtx_spacing_m)
	# Prefer the canonical tile (vec_ipix) when loaded — it is symmetric:
	# both sides of the boundary resolve to the same tile via vec2pix_nest.
	if load_chunk_heightmap(vec_ipix, ns) != null:
		return sample_height_for_direction(dir, vec_ipix, -1, Vector2i(-1, -1), null, ns, frame,
				vtx_spacing_m)
	# Canonical tile not loaded — fall back to chain_ipix's tile (known-loaded).
	# UV is clamped to [0,1] by _direction_to_pixel_uv, so the edge pixels are
	# used rather than the catastrophic 0.0m from a missing global heightmap.
	return sample_height_for_direction(dir, chain_ipix,
			_precomp_face, _precomp_xy, _cached_neighbors, ns, frame, vtx_spacing_m)


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
## Jumeau de [method _sample_image_bilinear] lisant un PackedFloat32Array. Mêmes bornes,
## mêmes poids, mêmes opérations dans le même ordre : la tuile étant en FORMAT_RF, indexer
## les floats rend exactement ce que get_pixel().r rendait, sans construire de Color.
static func _sample_floats_bilinear(floats: PackedFloat32Array, w: int, h: int,
		u_norm: float, v_norm: float) -> float:
	var fpx := u_norm * w - 0.5
	var fpy := v_norm * h - 0.5
	var x0 := clampi(int(floorf(fpx)), 0, w - 1)
	var y0 := clampi(int(floorf(fpy)), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var fx := clampf(fpx - floorf(fpx), 0.0, 1.0)
	var fy := clampf(fpy - floorf(fpy), 0.0, 1.0)
	var v00 := floats[y0 * w + x0]
	var v10 := floats[y0 * w + x1]
	var v01 := floats[y1 * w + x0]
	var v11 := floats[y1 * w + x1]
	return (v00 * (1.0 - fx) * (1.0 - fy)
			+ v10 * fx * (1.0 - fy)
			+ v01 * (1.0 - fx) * fy
			+ v11 * fx * fy)


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


## Cross-tile bilinear sampling for HEALPix tiles.
##
## When the 2×2 bilinear kernel extends past the tile edge, out-of-bounds
## texels are fetched from the neighbour tile (_get_pixel_healpix) — edge
## AND diagonal ones. That alone makes the surface continuous across the
## tile mosaic: the pack's tiles are samples of ONE relief at their texel
## centres, so the interpolation between the last texel of a tile and the
## first of its neighbour is the same from either side.
##
## There used to be a BLEND zone on top (4 texels wide, the sample faded
## towards the W/E then the S/N neighbour's own sample). It was asymmetric
## at tile CORNERS: two tiles sharing an edge faded towards DIFFERENT south
## neighbours, so their values along that edge disagreed — by 300 m within
## 800 m of a corner where tarsis_3's mesa cliff runs along the tile row
## (n1024 3358752/3358753 over 3358730/3358731). A chunk edge lying on that
## tile boundary picks tile A or B per vertex (vec2pix rounding), so its
## border row stepped away from its interior: the "landslide" wall along a
## chunk edge. Off the corners it still bent every slope within 4 texels of
## every tile edge by up to half a texel of relief. Gone — bilinear only.
func _sample_image_bilinear_healpix(
		floats: PackedFloat32Array, res: int, u_norm: float, v_norm: float,
		ipix: int, _cached_neighbors = null, nside: int = -1,
		frame: TileFrame = null) -> float:
	# Les tuiles sont carrées (tile_res × tile_res) et déjà validées à la lecture du pack.
	var w := res
	var h := res

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

	if x0 >= 0 and x1 < w and y0 >= 0 and y1 < h:
		var a00 := floats[y0 * w + x0]
		var a10 := floats[y0 * w + x1]
		var a01 := floats[y1 * w + x0]
		var a11 := floats[y1 * w + x1]
		return (a00 * (1.0 - fx) * (1.0 - fy)
				+ a10 * fx * (1.0 - fy)
				+ a01 * (1.0 - fx) * fy
				+ a11 * fx * fy)
	# Out-of-bounds kernel pixel — fetch from the neighbour tile(s)
	var ns := nside if nside > 0 else export_nside
	var v00 := _get_pixel_healpix(floats, x0, y0, w, h, ipix, _cached_neighbors, ns, frame)
	var v10 := _get_pixel_healpix(floats, x1, y0, w, h, ipix, _cached_neighbors, ns, frame)
	var v01 := _get_pixel_healpix(floats, x0, y1, w, h, ipix, _cached_neighbors, ns, frame)
	var v11 := _get_pixel_healpix(floats, x1, y1, w, h, ipix, _cached_neighbors, ns, frame)
	return (v00 * (1.0 - fx) * (1.0 - fy)
			+ v10 * fx * (1.0 - fy)
			+ v01 * (1.0 - fx) * fy
			+ v11 * fx * fy)


## Tuile voisine, prise dans le cadre du chunk quand il y en a un — le mélange de bord la
## redemandait au cache à CHAQUE échantillon, et elle est la même pour tout le chunk.
func _neighbor_floats(nb_ipix: int, ns: int, frame: TileFrame) -> PackedFloat32Array:
	if frame != null:
		return frame.floats(nb_ipix, ns)
	return load_chunk_floats(nb_ipix, ns)


## Read a single heightmap pixel, fetching from the neighbour HEALPix tile
## when (px, py) falls outside the current tile [0, w) × [0, h) — the
## DIAGONAL tile when it is out on both axes: a corner kernel texel used to
## be read from the W/E tile's far row, i.e. one tile off, which left the
## sampled surface discontinuous within a texel of every tile corner.
func _get_pixel_healpix(floats: PackedFloat32Array, px: int, py: int,
		w: int, h: int, ipix: int, _cached_neighbors = null, nside: int = -1,
		frame: TileFrame = null) -> float:
	if px >= 0 and px < w and py >= 0 and py < h:
		return floats[py * w + px]

	var ns := nside if nside > 0 else export_nside
	# Out of bounds — try neighbor tile
	var neighbors: Dictionary
	if _cached_neighbors != null:
		neighbors = _cached_neighbors
	else:
		neighbors = HEALPix.get_neighbors_nest(ns, ipix)
	var nb_px := px
	var nb_py := py
	var ew := ""
	var sn := ""
	if px < 0:
		ew = "W"
		nb_px = w + px
	elif px >= w:
		ew = "E"
		nb_px = px - w
	if py < 0:
		sn = "S"
		nb_py = h + py
	elif py >= h:
		sn = "N"
		nb_py = py - h
	var nb_ipix: int = neighbors.get(sn + ew, -1)

	if nb_ipix >= 0:
		var nb := _neighbor_floats(nb_ipix, ns, frame)
		if nb.size() == w * h:
			nb_px = clampi(nb_px, 0, w - 1)
			nb_py = clampi(nb_py, 0, h - 1)
			return nb[nb_py * w + nb_px]

	return floats[clampi(py, 0, h - 1) * w + clampi(px, 0, w - 1)]


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
## The biome relief (BiomeRelief, ≤ a couple of metres) is deliberately NOT
## added: it stays under the 3 m anti-tunnel margin and far under the cache
## validator's tolerance. The crack, at up to crack_depth_m, is not in that
## league, so it follows the same zone rule as the chunks (cracks_apply_at):
## no crack is added where another rock's zone has left the ground uncarved.
## The procedural mountains (hundreds of metres) come with the sampler itself;
## [param vtx_spacing_m] picks their LOD (0 = full detail, the finest chunk).
func crack_aware_surface_dist(dir: Vector3, nside: int = -1, vtx_spacing_m: float = 0.0) -> float:
	var alt := sample_height_for_direction(dir, -1, -1, Vector2i(-1, -1), null, nside, null, vtx_spacing_m)
	if cracks_apply_at(dir):
		alt += ArideDesertCorundumPlateauTerrain.crack_offset(
			dir, radius, crack_spacing_m, crack_width_m, crack_depth_m, 0.0) * crack_factor(dir)
	return radius + alt


## The distance from the planet centre of the ground a body can STAND on
## along [param dir]: [method crack_aware_surface_dist] lowered to what a
## profiled line (railway, graded road) carved out of it — the floor of a
## cutting, the bed inside a tunnel — where the point lies within the line's
## band. Cracks and cuttings both remove ground; the raw relief knows neither.
##
## For the server's below-surface catch (PlayerServer): measured against the
## raw relief, a player driving into a 10 m cutting or a tunnel was "3 m under
## the ground" and thrown back onto the mountain every physics tick — the
## body hopping in the air before the tarsis_3 highway tunnel (2026-09-16).
## Costs the finest chunk's pieces and a nearest-segment walk: call it only
## once the cheap raw test has said "below".
var _carve_pieces_cache: Dictionary = {}
func carved_surface_dist(dir: Vector3) -> float:
	var raw := crack_aware_surface_dist(dir)
	if not has_profiled_lines():
		return raw
	var nside: int = 1 << max_quadtree_depth
	var ipix := HEALPix.vec2pix_nest(nside, dir)
	# The pieces of the finest chunk and its neighbours, kept per chunk: a
	# body in a tunnel asks every physics tick, and gathering them is the
	# bulk of the 0.5 ms this costs.
	var pieces: Array
	if _carve_pieces_cache.has(ipix):
		pieces = _carve_pieces_cache[ipix]
	else:
		pieces = GradeBed.gather_pieces(self, nside, ipix)
		if _carve_pieces_cache.size() >= 64:
			_carve_pieces_cache.clear()
		_carve_pieces_cache[ipix] = pieces
	if pieces.is_empty():
		return raw
	var lonlat := HEALPix.vec2lonlat(dir)
	var q := GradeGeom.nearest_on_pieces(pieces, lonlat, radius * PI / 180.0)
	if not q["hit"]:
		return raw
	var prof := get_grade_profile(int(q["fid"]))
	if prof.is_empty():
		return raw
	var along := float(q["along"])
	var lat_m := absf(float(q["lat_m"]))
	var seg := GradeProfile.segment_at(prof, along)
	if seg.is_empty():
		return raw
	var h := raw - radius
	match int(seg["kind"]):
		GradeSettings.Kind.GROUND, GradeSettings.Kind.GORGE:
			h = GradeBed.carved_height(h, prof, along, lat_m)
		GradeSettings.Kind.TUNNEL:
			if lat_m <= GradeTunnel.bore_half_width(float(prof["hw_m"])):
				h = minf(h, GradeProfile.z_track_at(prof, along))
	return radius + h


## Whether the corundum default biome is what the ground is made of along
## [param dir]: the flag is on and no populate zone naming a KNOWN biome covers
## the point. This is the single rule PlanetChunk applies per vertex, in the
## visual mesh and in the collision shape — see [method corundum_applies_to_zone]
## for the zone half, which the chunks call with the zone they already looked up.
func corundum_applies_at(dir: Vector3) -> bool:
	if not corundum_default_biome:
		return false
	return biome_at(dir) == null


## The zone half of [method corundum_applies_at]: given the FIRST populate zone
## containing a vertex (empty when none does), does corundum still apply there?
## Only a zone whose biome_type resolves to a BiomeDefinition displaces it.
func corundum_applies_to_zone(first_zone: Dictionary) -> bool:
	if not corundum_default_biome:
		return false
	if first_zone.is_empty():
		return true
	return get_biome_by_type(String(first_zone.get("biome_type", ""))) == null


## The sand-covered corundum biome: the crystal is under the dunes, the
## cracks do not show.
const CORUNDUM_SAND_DESERT_BIOME := "aride_desert-corundum_sand_desert"


## Does the crack network carve the ground under [param first_zone]? Where
## the ground IS corundum: the corundum default ([method corundum_applies_to_zone])
## — and any zone whose ground is a corundum rock (rock_type corundum_* or
## emery, or the corundum plateau biome itself), because an outcrop of blue
## corundum is one block of the same crystal and fractures like the rest of
## the planet. A zone of another rock, or the sand desert, stays uncarved.
## Needs the planet's network (corundum_default_biome, which owns the crack
## parameters). The single rule of the mesh, the collision, the server's
## surface catch and the bridges — see [method cracks_apply_at].
func cracks_apply_to_zone(first_zone: Dictionary) -> bool:
	if not corundum_default_biome:
		return false
	if corundum_applies_to_zone(first_zone):
		return true
	var biome_type := String(first_zone.get("biome_type", ""))
	if biome_type == CORUNDUM_SAND_DESERT_BIOME:
		return false
	if biome_type == ArideDesertCorundumPlateauTerrain.BIOME_TYPE:
		return true
	var rock_type := String(first_zone.get("rock_type", ""))
	return rock_type.begins_with("corundum") or rock_type == "emery"


## The direction half of [method cracks_apply_to_zone]: is the ground along
## [param dir] carved by the crack network?
func cracks_apply_at(dir: Vector3) -> bool:
	if not corundum_default_biome:
		return false
	return cracks_apply_to_zone(first_zone_at(dir))


## The POI spheres the crack network keeps whole, planet-local:
## [{dir: Vector3, radius: float}], see [method set_crack_exclusions].
var _crack_pois: Array = []


## Give the crack network the POIs to keep whole — MAIN THREAD, before the
## first chunk task and before the bridge spans (which walk the chasms).
## [param pois]: [{dir: Vector3 (planet-local unit), radius: float (m)}].
func set_crack_exclusions(pois: Array) -> void:
	_crack_pois = []
	for p in pois:
		var d: Vector3 = (p as Dictionary).get("dir", Vector3.ZERO)
		var r := float((p as Dictionary).get("radius", 0.0))
		if d.length_squared() < 0.5 or r <= 0.0:
			continue
		_crack_pois.append({"dir": d.normalized(), "radius": r})


## The exclusions a chunk around [param center_dir] can meet: those whose
## sphere plus the margin reaches within [param reach_m] of its centre. The
## per-vertex test then loops over a handful instead of the planet's list.
func crack_pois_near(center_dir: Vector3, reach_m: float) -> Array:
	if _crack_pois.is_empty():
		return []
	var out: Array = []
	for p in _crack_pois:
		var d_m: float = (center_dir - (p["dir"] as Vector3)).length() * radius
		if d_m < reach_m + float(p["radius"]) + crack_poi_margin_m:
			out.append(p)
	return out


## Depth factor of the crack network at [param dir] in [0, 1]: 0 inside a
## POI's sphere, 1 past the sphere plus crack_poi_margin_m, smooth between.
## [param pois] defaults to the planet's list; a chunk passes its
## [method crack_pois_near] subset. Pure — the mesh, the collision, the
## server's surface catch and the bridges multiply the same carve by it.
func crack_clearance(dir: Vector3, pois: Array = _crack_pois) -> float:
	var w := 1.0
	for p in pois:
		var d_m: float = (dir - (p["dir"] as Vector3)).length() * radius
		var r := float(p["radius"])
		if d_m <= r:
			return 0.0
		w = minf(w, smoothstep(r, r + crack_poi_margin_m, d_m))
	return w


## Depth factor of the crack network at [param dir] in [0, 1] — everything
## that keeps the ground whole, multiplied: the POI spheres
## ([method crack_clearance]) and the mountains (1 − [method mountain_mask]:
## a massif is not cut by the plateau's canyons, the network fades out over
## its feather). [param pois] / [param frame] as in the two halves; the four
## carve paths and the normal probes all multiply the same carve by it.
func crack_factor(dir: Vector3, pois: Array = _crack_pois, frame: TileFrame = null) -> float:
	var w := crack_clearance(dir, pois)
	if w <= 0.0 or _has_mountains != 1:
		return w
	return w * (1.0 - mountain_mask(dir, frame))


## Re-keys the chunk cache: the exclusions are baked geometry.
func crack_exclusion_fingerprint() -> String:
	if _crack_pois.is_empty():
		return ""
	var parts := PackedStringArray()
	for p in _crack_pois:
		var d: Vector3 = p["dir"]
		parts.append("%.5f,%.5f,%.5f,%.0f" % [d.x, d.y, d.z, float(p["radius"])])
	return ("%s|%.0f" % [",".join(parts), crack_poi_margin_m]).sha1_text().substr(0, 10)


## HEALPix nside for server COLLISION chunks pinned under active bodies.
## Normally the export nside, but for planets whose visual mesh carries fine
## sub-features (the corundum crack network) it uses the client's FINEST LOD
## nside (max_quadtree_nside).  Paired with [method collision_col_res_for]
## returning chunk_resolution, the collision is then built on the EXACT same
## HEALPix grid (same nside AND res) the client renders at its finest LOD — so
## the collision surface is bit-identical to the visual mesh and the player
## can't stand above/below the rendered cracks.
##
## A road is another: its 8 cm slab (RoadRibbon) is part of the collision
## shape, and only makes sense on the grid the mesh uses.
## A profiled line (railway, graded road) is the other case: its cuttings are
## carved only into the finest grid (GradeBed.carve_enabled) and its bed's
## collision is part of the
## chunk shape, so a coarse collision would leave a player standing inside a
## cutting's coarse faces.
##
## Only applied in file (chunk-heightmap) mode, whose shape task re-resolves
## the export tiles per vertex.
func collision_detail_nside() -> int:
	if chunk_heightmaps_dir == "" \
			or not (corundum_default_biome or has_profiled_lines()
					or has_relief_biomes() or has_roads() or has_mountains()):
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
	var zone := first_zone_at(dir)
	if zone.is_empty():
		return null
	return get_biome_by_type(String(zone.get("biome_type", "")))


## The FIRST populate zone containing [param dir] — the one the chunk builders
## colour and detail a vertex from — or an empty Dictionary when none does.
## Main thread only (loads the export pixel's zones).
func first_zone_at(dir: Vector3) -> Dictionary:
	if export_nside <= 0:
		return {}
	var eipix := HEALPix.vec2pix_nest(export_nside, dir)
	var pz := get_chunk_populate_zones(eipix)
	if pz.is_empty():
		return {}
	var matched := PlanetChunk._query_zones_at_direction(dir, pz)
	if matched.is_empty():
		return {}
	return matched[0]


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
	"regolith-dust.tres", "regolith-sand.tres", "regolith-gravel.tres",
	"regolith-cobble.tres", "regolith-crystal.tres",
	"outcrop-plateau.tres", "outcrop-volcanic.tres",
	"volcanic_geothermal-fumarole_field.tres",
]


## Scan the biomes directory and load every .tres file as a BiomeDefinition.
## Called once; the result is cached in the static _all_biomes array — for the
## whole editor process: a .tres added while the editor runs is only seen after
## a restart (symptom: get_biome_by_type() returns null for the new biome).
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
	# regolith / outcrop: the rock is a per-zone attribute (rock_type), the
	# detail layer only says how fine the ground is.
	"regolith-dust": 1, "regolith-sand": 1,                          # sand
	"regolith-gravel": 8,                                            # lunar ground (grainy)
	"regolith-cobble": 2, "regolith-crystal": 2,                     # rock
	"outcrop-plateau": 2, "outcrop-volcanic": 2,                     # rock
	"volcanic_geothermal-fumarole_field": 2,                         # rock
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
