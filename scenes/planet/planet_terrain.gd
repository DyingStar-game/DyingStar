@tool
class_name PlanetTerrain
extends Node3D
## Quadtree-based terrain manager for a planet.
##
## Uses **HEALPix NESTED** projection: 12 root base pixels, each recursively
## subdivided into a quadtree (4 children per pixel).  Leaf nodes are rendered
## as mesh chunks whose vertex density is driven by the LOD tier.
##
## **Multiplayer split**
##   • Client — visual MeshInstance3D chunks, no collision.
##   • Server — collision ConcavePolygonShape3D on a StaticBody3D for
##              LOD 0-1 chunks only.  A base SphereShape3D provides rough
##              collision at all distances.

## Emitted once when the first full set of visible chunks has been assembled.
signal initial_chunks_ready

const BASE_PIXEL_COUNT := 12
## Seconds between full LOD-tree updates.
const UPDATE_INTERVAL := 0.25
## Factor: subdivide when camera distance < chunk_diagonal * SUBDIVIDE_FACTOR.
const SUBDIVIDE_FACTOR := 1.5
## Back-face culling dot threshold (client only, skip chunks behind planet).
const BACKFACE_DOT := -0.3
## Extra angular margin (radians) added to the geometric horizon angle so
## chunks poking above the horizon (mountains, trees) aren't culled too early.
## ~0.02 rad ≈ 1.1° — covers ≈40 km at the planet surface.
const HORIZON_MARGIN_RAD := 0.02
## Seconds between editor camera tracking updates.
const EDITOR_TRACK_INTERVAL := 0.5
## Maximum concurrent recipe worker tasks (avoid flooding the thread pool).
const MAX_CONCURRENT_RECIPES := 8
## Maximum chunks assembled (MeshInstance3D + vegetation) per physics frame.
## 4 matches the number of HEALPix children so a full split assembles in one frame.
const MAX_ASSEMBLE_PER_FRAME := 8
## Maximum concurrent server collision-chunk loading tasks (heightmap or shape phase).
const MAX_SERVER_CHUNK_TASKS := 4
## Ring-buffer size for camera history (look-ahead prefetch).
const CAM_HISTORY_SIZE := 10
## Tolerance (m) for validating cached chunk geometry against the live surface
## (see _cached_geom_valid). Generous: cracks are ~200 m deep, the failure mode
## is 3000-6000 m off.
const _CACHE_GEOM_TOLERANCE_M := 1500.0

## ── Editor preview settings ───────────────────────────────────────
## Quadtree depth for editor preview chunks. Higher = smaller chunks,
## more detail. Depth 6 → ~52 km, depth 12 → ~800 m, depth 14 → ~200 m.
## The game's quadtree goes up to max_quadtree_depth (14) near the surface.
@export_range(0, 14) var editor_preview_depth: int = 3:
	set(value):
		editor_preview_depth = value
		if Engine.is_editor_hint() and _initialized:
			_editor_goto_cooldown = 0.0
			_generate_editor_preview()

## Number of chunk rings displayed around the centre chunk in the editor
## preview. 0 = only the centre chunk, 1 = 3×3, 2 = 5×5, N = (2N+1)×(2N+1).
## Higher values give a larger contiguous surface for placing items, at the
## cost of more mesh generation. Rings are grown by HEALPix neighbour walk.
@export_range(0, 8) var editor_preview_rings: int = 1:
	set(value):
		editor_preview_rings = value
		if Engine.is_editor_hint() and _initialized:
			_editor_goto_cooldown = 0.0
			_generate_editor_preview()

## When enabled, the editor preview also scatters vegetation (trees,
## grass) on the visible chunks — gives a near-runtime WYSIWYG view.
@export var editor_preview_vegetation: bool = false:
	set(value):
		editor_preview_vegetation = value
		if Engine.is_editor_hint() and _initialized:
			_editor_goto_cooldown = 0.0
			_generate_editor_preview()

## Maximum concurrent mesh-generation worker tasks.
## Set to 4 so all 4 HEALPix children of a split pixel compute in parallel.
@export_range(1, 8) var max_mesh_tasks: int = 4

## ── Editor navigation ─────────────────────────────────────────────
## Longitude (degrees) used by the "Go to lon/lat" button below.
@export var editor_goto_lon: float = 0.0
## Latitude (degrees) used by the "Go to lon/lat" button below.
@export var editor_goto_lat: float = 0.0
## Inspector button: recenter the editor preview on the lon/lat above,
## update the x/y/z fields to match, and drop a focus marker (press F in the
## viewport to fly to it).
@export_tool_button("Go to lon/lat") var _goto_lonlat_action = _goto_lonlat
## Planet-local X/Y/Z used by the "Go to coordinates" button below. Any point
## in space is projected onto the surface along its direction from the centre.
@export var editor_goto_x: float = 0.0
@export var editor_goto_y: float = 0.0
@export var editor_goto_z: float = 0.0
## Inspector button: recenter the editor preview on the x/y/z above, update
## the lon/lat fields to match, and drop a focus marker.
@export_tool_button("Go to coordinates") var _goto_coords_action = _goto_coordinates
## When enabled, the editor camera fly speed and near/far clip planes are
## auto-tuned to the planet radius on load — essential for large planets,
## where the default 4 km far plane clips the whole surface.
@export var editor_auto_tune_camera: bool = true
## Inspector button: re-apply the camera auto-tune to the current planet now.
@export_tool_button("Tune camera to planet scale") var _tune_camera_action = _auto_tune_editor_camera

## ── Editor placement (used by the "Planet Tools" editor plugin) ───
## When snapping selected objects to the surface, also rotate them so their
## +Y axis points along the surface normal (radially outward). Disable to snap
## position only and keep the current rotation.
@export var editor_snap_align_to_normal: bool = true
## Extra height (metres) above the sampled surface for snapped objects — raise
## it if the object's origin sits above its base, lower it if it sits below.
## Read by the "Planet Tools" editor plugin's "Snap to surface" action.
@export var editor_snap_height_offset: float = 0.0

var planet_data: PlanetData
var is_server: bool = false

var _editor_track_timer: float = 0.0
## Cached editor camera position (planet-local) to detect movement.
var _editor_last_cam_local: Vector3 = Vector3.INF
## Grace period (seconds) after a "Go to biome" to prevent camera tracking
## from immediately overwriting the biome-centred preview.
var _editor_goto_cooldown: float = 0.0

## ── Editor biome navigator ────────────────────────────────────────
## Populated from BiomeQuery on initialize; drives the dynamic dropdown.
var _editor_biome_entries: Array[Dictionary] = []
## Currently selected biome index in the dropdown (-1 = none).
var _editor_selected_biome_idx: int = -1
## Marker node placed at the selected biome so the user can press F to frame it.
var _editor_biome_focus: Node3D = null

## Camera altitude above the ACTUAL (crack-aware) terrain surface, sampled
## once per LOD update in _update_terrain and reused by every _traverse call.
## Metrics measured against sea level are wrong on high terrain: tarsis_4's
## plateau sits ~5.6 km above the sea-level radius, which inflated every
## distance by that much and stopped the quadtree from ever reaching its
## finest depth (so the render could never match the always-finest collision).
var _cam_alt_above_surface: float = 0.0

var _chunks_node: Node3D
var _collision_body: StaticBody3D
var _chunk_cache: ChunkDiskCache

# chunk_key → { key, nside, ipix, depth, center, lod,
#               mesh_instance?, collision_shape? }
var _active_chunks: Dictionary = {}
var _update_timer: float = 0.0
var _initialized: bool = false

## Server fixed-collision mode: all export-nside chunks loaded at startup.
## Maps chunk_key → per-chunk StaticBody3D (see _make_chunk_collision_body).
var _server_collision_chunks: Dictionary = {}
## True once _server_load_prebaked_collision() has finished.
var _server_collision_loaded: bool = false

## Pinned chunks that must never be evicted while pinned (e.g. an active
## RigidBody3D resting on them).  key → true.  Pinned chunks are loaded
## on the next set_resident_chunks() / set_pinned_chunks() and outlive
## the zone-driven desired set until the pin is released.
var _pinned_chunks: Dictionary = {}
## Last desired set received from server.gd (zone residency).  Cached so
## set_pinned_chunks() can recompute the effective resident set without
## requiring server.gd to re-push the zone keys every tick.
var _last_desired_keys: PackedStringArray = PackedStringArray()

## ── Async recipe generation ──────────────────────────────────────
## Tracks WorkerThreadPool tasks for recipe heightmap generation.
## export_key → { task_id: int, result: Variant, done: bool, export_ipix: int }
var _pending_recipes: Dictionary = {}
## Chunks waiting for a specific recipe to finish before their mesh can be generated.
## export_key → Dictionary (chunk_key → chunk_info dict)
var _recipe_waiters: Dictionary = {}
## Recipes that need submission but couldn't because MAX_CONCURRENT_RECIPES was
## reached.  export_key → { export_ipix: int }
var _deferred_recipe_queue: Dictionary = {}

## ── Async mesh generation ─────────────────────────────────────────
## In-flight mesh generation WorkerThreadPool tasks.
## chunk_key → { task_id: int, result_ref: Array, info: Dictionary }
## result_ref is a single-element Array so the lambda can write into it.
var _mesh_tasks: Dictionary = {}
## Mesh-data computed and ready to be assembled into scene objects (main thread).
## Each entry: { info: Dictionary, mesh: ArrayMesh }
var _assemble_queue: Array[Dictionary] = []
## Overflow queue when max_mesh_tasks is reached.
var _mesh_task_backlog: Array[Dictionary] = []

## ── Initial-load tracking ─────────────────────────────────────────
var _initial_ready_emitted: bool = false

## True while this planet's chunks are on the CELESTIAL render layer (whole-planet LOD >= 3 = a distant
## body) rather than the LOCAL layer (near = lit by the per-player sun). Tracked so the switch only
## re-tags chunks on a transition.
var _chunks_on_celestial: bool = false

## World-space direction from THIS planet to the system star, computed in double precision (exact at
## ~3e10, unlike a float32 world_pos). Fed per-chunk to the terrain shader so distant chunks — which get
## no Godot light on the celestial layer — light themselves from the REAL star direction. Refreshed each
## terrain update; ~static while the planet does not orbit.
var _star_dir_world: Vector3 = Vector3.UP

## ── Look-ahead prefetch ───────────────────────────────────────────
## Ring-buffer of recent camera positions (planet-local) for velocity estimation.
var _cam_history: PackedVector3Array = PackedVector3Array()
## Last known camera position in planet-local space (for distance priority).
var _last_local_cam: Vector3 = Vector3.ZERO

## Cache of feature nodes (caves, fumaroles, volcanoes) attached per chunk
## so we can free them when the chunk is unloaded.  key → Array[Node3D].
var _server_feature_nodes: Dictionary = {}

## Buffered desired set when set_resident_chunks() is called before
## the planet finishes initializing (rare race during Horizon boot).
var _pending_desired_keys: PackedStringArray = PackedStringArray()

## ── Async server collision loading ───────────────────────────────
## In-flight chunk loading tasks, keyed by chunk_key.  Each entry passes
## through two phases: phase 0 = heightmap generation, phase 1 = collision
## shape generation.  Assembled on the main thread once phase 1 is done.
## key → { phase: int, task_id: int, result_ref: Array,
##          ipix: int, col_res: int, cached_shape: Variant, evicted: bool }
var _server_chunk_tasks: Dictionary = {}
## Chunks waiting for a free task slot (bounded by MAX_SERVER_CHUNK_TASKS).
## Each entry: { key: String, ipix: int, col_res: int }
var _server_chunk_queue: Array[Dictionary] = []


# ------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------

func initialize(data: PlanetData, server_mode: bool) -> void:
	planet_data = data
	is_server = server_mode

	# File mode: apply the chunk manifest (radius / export nside / tile res /
	# height range) before anything reads these values below.
	if data.chunk_heightmaps_dir != "":
		data.apply_chunk_manifest()

	# Initialize chunk disk cache (skipped in editor mode)
	if not Engine.is_editor_hint():
		# v13: collision col_res raised to _recipe_resolution to match the
		# heightmap that sample_height_for_direction returns; older caches
		# (v12 and earlier) stored coarse 16x16 grids that were tens to
		# hundreds of metres off from the visual mesh.
		# v14: skirt depth now derives from per-chunk relief (was global
		# max_height) — invalidates meshes baked with kilometre-tall skirts.
		# v15: relief-based skirt finalised.
		# v16: terrain_exaggeration added to the key so changing it re-bakes.
		# v17: skirt depth now from steepest cell step (was whole-chunk relief).
		# v18: corundum crack override + params in the key so toggling/tuning
		#      the crack network re-bakes both visual meshes and collision.
		# v19: corundum iron-impurity vertex colouring baked into the mesh.
		# v20: crack carve LOD-fades by vertex spacing (kills the LOD1 alias band).
		# v21: stronger LOD fade (gone by 0.5·width) + capped corundum skirt drop.
		# v24: crack GEOMETRY now gated on the corundum override flag (not the
		#      biome definition), so runtime client meshes carve cracks even
		#      when biome defs are unavailable — invalidates flat-baked meshes.
		# v25: crack depth no longer LOD-ramped (full depth wherever drawn) so
		#      the visual crack floor matches the full-depth physics floor.
		var _cor := "_cor%d_%.0f_%.0f_%.0f_dbg%d" % [
			int(data.corundum_override_whole_planet), data.crack_spacing_m,
			data.crack_width_m, data.crack_depth_m,
			int(data.debug_color_skirts)] if data.corundum_override_whole_planet else ""
		var _cache_version := "%s_%d_%.0f_%.0f_%.1f_%.2f_v25%s" % [
			data.planet_name, data.export_nside, data.radius,
			data.max_height, data.height_offset, data.terrain_exaggeration, _cor]
		# Server collision shapes live in a dedicated folder so they don't
		# mix with client visual-mesh cache entries.  Server-only suffix:
		# "_colrel1" = chunk-local (float32-safe) faces; "_colbf2" = double-
		# sided (backface_collision) so bodies can't fall through the surface.
		# Bumping it invalidates stale shapes without a client visual re-bake.
		var _cache_base := ChunkDiskCache.BASE_DIR
		if server_mode:
			_cache_base = ChunkDiskCache.SERVER_COLLISION_BASE_DIR
			_cache_version += "_colrel1_colbf2_grid8k"
		_chunk_cache = ChunkDiskCache.new(data.planet_name, _cache_version, _cache_base)

	print("[PlanetTerrain] initialize: planet=%s radius=%.0f export_nside=%d server=%s" % [
		data.planet_name, data.radius, data.export_nside, server_mode])

	# Chunks container
	if has_node("Chunks"):
		_chunks_node = $Chunks
	else:
		_chunks_node = Node3D.new()
		_chunks_node.name = "Chunks"
		add_child(_chunks_node)

	# Editor: generate a static 6-face preview at full chunk resolution
	if Engine.is_editor_hint():
		_initialized = true
		_populate_biome_entries()
		_print_biome_locations()
		if editor_auto_tune_camera:
			_auto_tune_editor_camera()
		_generate_editor_preview()
		return

	# Server FALLBACK collision body (BaseSphere + SafetyNet only).
	# Terrain chunks each get their OWN small StaticBody3D at the chunk origin
	# (see _make_chunk_collision_body) — required for Jolt float32 narrowphase.
	# The two planet-wide fallback shapes stay here: they sit 100-200 m BELOW
	# the playable surface and only catch bodies that already fell through
	# everything, so contact noise on them is harmless.
	if is_server:
		planet_data.set_server_mode(true)
		_collision_body = StaticBody3D.new()
		_collision_body.name = "PlanetCollision"
		# Terrain IS the `world` layer (layer 1) and scans world | player |
		# vehicle | prop (masks 1–4 = Globals.MASK_SOLID).
		_collision_body.collision_layer = Globals.LAYER_WORLD
		_collision_body.set_collision_layer_value(Globals.LAYER_WORLD, true)
		_collision_body.collision_mask = Globals.MASK_SOLID
		add_child(_collision_body)

		var base_sphere := SphereShape3D.new()
		# IMPORTANT: terrain triangles range from (radius + height_offset) up
		# to (radius + height_offset + max_height).  A base sphere at exactly
		# `radius` would float ABOVE the lowest valleys and BELOW peaks —
		# stopping the player at altitude 0 while the actual terrain mesh is
		# tens to hundreds of metres higher (causing "I'm under the surface"
		# bugs).  Inset the sphere well below the deepest valley so it only
		# catches bodies that fell past every other collision layer.
		var _inset_below_valleys: float = 100.0
		base_sphere.radius = planet_data.radius + planet_data.height_offset - _inset_below_valleys
		if base_sphere.radius <= 0.0:
			base_sphere.radius = planet_data.radius * 0.5
		var base_col := CollisionShape3D.new()
		base_col.shape = base_sphere
		base_col.name = "BaseSphere"
		_collision_body.add_child(base_col)

		# Safety-net: coarse triangulated shell sitting just below the
		# deepest valley.  Always resident so nothing can fall through
		# when its export-nside chunk is not loaded.  ~384 triangles per
		# planet, generated from safety_mesh.json inside the planetpack.
		var safety_faces := planet_data.load_safety_mesh_faces()
		if safety_faces.size() >= 3:
			var safety_shape := ConcavePolygonShape3D.new()
			safety_shape.backface_collision = true  # solid from both sides (see chunk shape)
			safety_shape.set_faces(safety_faces)
			var safety_col := CollisionShape3D.new()
			safety_col.shape = safety_shape
			safety_col.name = "SafetyNet"
			_collision_body.add_child(safety_col)
			@warning_ignore("integer_division")
			var _safety_tris := safety_faces.size() / 3
			print("[PlanetTerrain] safety-net collision attached (%d tris)" % _safety_tris)
		else:
			push_warning("[PlanetTerrain] no safety-net mesh available for '%s'" % planet_data.planet_name)

	# Pre-load biome/road queries on the main thread so that background mesh
	# generation tasks see them as purely read-only (no lazy-init side-effects).
	planet_data.ensure_queries_loaded()

	_initialized = true

	# Server: zone-driven collision residency.  No chunks are loaded at boot;
	# the safety-net mesh attached above keeps the planet "solid" everywhere
	# until server.gd::manage_zone() pushes a desired chunk set via
	# set_resident_chunks().  This replaces the previous eager 49,152-chunk
	# loop that exhausted memory across 17 planets.
	if is_server and not Engine.is_editor_hint():
		_server_init_collision_root()


# ------------------------------------------------------------------
# Server fixed-collision grid
# ------------------------------------------------------------------

## Initialise the server collision tracking and emit initial_chunks_ready.
## Per-chunk shapes are loaded lazily by set_resident_chunks() when the
## owning server's authoritative zone is established.  The base sphere and
## safety-net coarse mesh are already attached in initialize().
func _server_init_collision_root() -> void:
	_server_collision_loaded = true
	_initial_ready_emitted = true
	initial_chunks_ready.emit()
	print("[PlanetTerrain] server collision root ready (lazy residency, planet=%s)" % planet_data.planet_name)
	# Apply any zone request that arrived before initialise completed.
	if not _pending_desired_keys.is_empty():
		var pending := _pending_desired_keys
		_pending_desired_keys = PackedStringArray()
		set_resident_chunks(pending)


## Diff [param desired_keys] against the currently-resident chunk set and
## load/unload as needed.  Idempotent: callers can push the full desired set
## every tick.  Safe before the planet's first set_resident_chunks call —
## treats missing keys as "no resident chunks yet".
func set_resident_chunks(desired_keys: PackedStringArray) -> void:
	if not _server_collision_loaded:
		# Initialisation hasn't run yet (e.g. zone arrived before _ready).
		# Buffer the request — re-applied once initialise completes.
		_pending_desired_keys = desired_keys
		return

	_last_desired_keys = desired_keys
	_apply_residency()


## Replace the pinned-chunk set and re-apply residency.  Pinned chunks
## are forcibly resident regardless of the zone's desired set, and are
## NEVER evicted by set_resident_chunks().  Use this for active-body
## pinning (RigidBody3D on a chunk → pin until it sleeps).
func set_pinned_chunks(pin_keys: PackedStringArray) -> void:
	if not _server_collision_loaded:
		# Without a loaded root we can't materialise anything; just remember
		# the pin set so it gets applied after init.
		_pinned_chunks.clear()
		for k in pin_keys:
			_pinned_chunks[k as String] = true
		return

	_pinned_chunks.clear()
	for k in pin_keys:
		_pinned_chunks[k as String] = true
	_apply_residency()


## Compute the effective resident set as (desired ∪ pinned) and load /
## unload chunks accordingly.  Pinned chunks override eviction.
func _apply_residency() -> void:
	var effective: Dictionary = {}
	for k in _last_desired_keys:
		effective[k as String] = true
	for k in _pinned_chunks.keys():
		effective[k as String] = true

	# Fine collision chunks (deeper nside, pinned under active bodies) carve
	# the cracks the coarse export chunks flatten.  Drop the coarse export
	# chunk beneath each fine pin so its flat plateau doesn't overlay — and
	# block — the carved canyon underneath it.
	var export_nside := planet_data.export_nside
	for k in _pinned_chunks.keys():
		var kn := _parse_nside_from_key(k as String)
		if kn > export_nside:
			var kip := _parse_ipix_from_key(k as String)
			if kip >= 0:
				# NESTED ipix: parent export tile = ipix >> 2·log2(nside/export).
				var parent := kip
				var ns := kn
				while ns > export_nside:
					parent >>= 2
					ns >>= 1
				effective.erase("hp_n%d_p%d" % [export_nside, parent])

	# Unload chunks no longer in effective set (and not pinned).
	for k in _server_collision_chunks.keys().duplicate():
		if not effective.has(k):
			_unload_chunk(k as String)

	# Mark in-flight tasks for evicted chunks so the poll discards their result.
	for k in _server_chunk_tasks.keys():
		if not effective.has(k as String):
			_server_chunk_tasks[k as String]["evicted"] = true

	# Prune the backlog queue for chunks that are no longer wanted.
	var pruned: Array[Dictionary] = []
	for entry in _server_chunk_queue:
		if effective.has((entry as Dictionary)["key"]):
			pruned.append(entry)
	_server_chunk_queue = pruned

	# Load missing chunks (not resident and not already loading / queued).
	for k in effective.keys():
		var key := k as String
		if not _server_collision_chunks.has(key) and not _server_chunk_tasks.has(key):
			_load_chunk(key)


## Enqueue a HEALPix chunk for async collision loading.  Returns immediately;
## the heavy work (heightmap + shape generation) runs in WorkerThreadPool tasks
## and the resulting CollisionShape3D is attached on the main thread by
## _server_poll_chunk_tasks() once both phases complete.
func _load_chunk(key: String) -> void:
	# Skip if already resident or already loading.
	if _server_collision_chunks.has(key) or _server_chunk_tasks.has(key):
		return

	var ipix := _parse_ipix_from_key(key)
	if ipix < 0:
		push_warning("[PlanetTerrain] _load_chunk: invalid key '%s'" % key)
		return
	var _nside := _parse_nside_from_key(key)
	if _nside <= 0:
		_nside = planet_data.export_nside
	# Fine (crack) chunks match the visual's finest LOD grid (chunk_resolution);
	# coarse export chunks keep the denser recipe resolution.
	var col_res := planet_data.collision_col_res_for(_nside)

	# Dedup against the backlog queue.
	for entry in _server_chunk_queue:
		if (entry as Dictionary).get("key", "") == key:
			return
	_server_chunk_queue.append({ "key": key, "ipix": ipix, "col_res": col_res })
	_server_drain_chunk_queue()


## Free the collision shape and any spawned feature nodes for [param key].
## Also marks any in-flight async loading task as evicted so its result is
## discarded when the task completes.
func _unload_chunk(key: String) -> void:
	if _server_collision_chunks.has(key):
		var body: Node = _server_collision_chunks[key]
		body.queue_free()
		_server_collision_chunks.erase(key)
	if _server_feature_nodes.has(key):
		for n in _server_feature_nodes[key]:
			if is_instance_valid(n):
				(n as Node).queue_free()
		_server_feature_nodes.erase(key)
	if _server_chunk_tasks.has(key):
		_server_chunk_tasks[key]["evicted"] = true


# ------------------------------------------------------------------
# Async server collision loading
# ------------------------------------------------------------------

## Promote entries from _server_chunk_queue into active tasks up to
## MAX_SERVER_CHUNK_TASKS.  Called after every task completion and after
## every _load_chunk() enqueue so the pipeline self-drains each frame.
func _server_drain_chunk_queue() -> void:
	while _server_chunk_tasks.size() < MAX_SERVER_CHUNK_TASKS \
			and not _server_chunk_queue.is_empty():
		var entry: Dictionary = _server_chunk_queue[0]
		_server_chunk_queue.remove_at(0)
		var key: String = entry["key"]
		if _server_collision_chunks.has(key) or _server_chunk_tasks.has(key):
			continue  # Loaded or started since it was queued.
		_server_start_chunk_load(key, entry["ipix"], entry["col_res"])


## Begin async loading for one chunk.  Loads the collision shape from the disk
## cache (fast), pre-loads recipe data on the main thread (~0.5 ms), then
## submits generate_heightmap to a worker thread (phase 0).  When that
## completes, _server_poll_chunk_tasks() stores the image and submits
## generate_collision_shape_healpix (phase 1).
func _server_start_chunk_load(key: String, ipix: int, col_res: int) -> void:
	# Try the disk-cached collision shape (cheap main-thread I/O).
	var cached_shape: ConcavePolygonShape3D = null
	if _chunk_cache and _chunk_cache.has_collision(key, 0):
		cached_shape = _chunk_cache.load_collision(key, 0)

	# File mode: skip recipe phase-0. The shape task lazily loads the .r32 tile
	# via load_chunk_heightmap() while sampling collision heights.
	var key_nside := _parse_nside_from_key(key)
	if key_nside <= 0:
		key_nside = planet_data.export_nside

	# Discard a cached shape that was baked from fallback heights (see
	# _cached_geom_valid) — regenerating is far cheaper than a player
	# bouncing forever between a wrong collision floor and the real surface.
	if cached_shape != null and not _cached_shape_valid(cached_shape, key_nside, ipix, key):
		cached_shape = null

	if planet_data.chunk_heightmaps_dir != "":
		if cached_shape != null:
			_server_assemble_chunk(key, key_nside, ipix, cached_shape)
		else:
			_server_submit_shape_task(key, ipix, col_res)
		return

	# Fast-path: both image and shape already available — assemble now.
	if planet_data.is_chunk_cached(key):
		if cached_shape != null:
			_server_assemble_chunk(key, key_nside, ipix, cached_shape)
		else:
			_server_submit_shape_task(key, ipix, col_res)
		return

	# Phase 0: pre-load recipe data sync on the main thread (~0.5 ms),
	# then submit the CPU-heavy generate_heightmap to a worker thread.
	var preloaded := planet_data._load_recipe_data_sync(ipix, key)
	if preloaded.is_empty():
		push_warning("[PlanetTerrain] _load_chunk: recipe '%s' not found — skipping." % key)
		return

	var recipe_data: Dictionary = preloaded["recipe"]
	var resolution: int = planet_data._recipe_resolution
	var planet_radius: float = planet_data.radius
	var elev_min: float = planet_data.height_offset
	var elev_range: float = planet_data.max_height

	var result_ref: Array = [null]
	var task_entry := {
		"phase": 0, "task_id": -1, "result_ref": result_ref,
		"ipix": ipix, "col_res": col_res,
		"cached_shape": cached_shape, "evicted": false,
	}
	_server_chunk_tasks[key] = task_entry

	var task_id := WorkerThreadPool.add_task(func():
		var gen_result := ChunkRecipeGenerator.generate_heightmap(
			recipe_data, resolution, planet_radius, elev_min, elev_range)
		var populate_zones := ChunkRecipeGenerator.get_populate_zones(recipe_data)
		var linear_feats: Array = recipe_data.get("linear_features", [])
		var radial_feats: Array = recipe_data.get("radial_features", [])
		var img: Image = gen_result[0] as Image if gen_result.size() > 0 else null
		var craters: Array = gen_result[1] if gen_result.size() > 1 else []
		result_ref[0] = [img, craters, populate_zones, linear_feats, radial_feats]
	)
	task_entry["task_id"] = task_id


## Submit a phase-1 WorkerThreadPool task that generates the collision shape.
## The heightmap image MUST already be stored in planet_data before calling.
func _server_submit_shape_task(key: String, ipix: int, col_res: int) -> void:
	var pd := planet_data
	var nside := _parse_nside_from_key(key)
	if nside <= 0:
		nside = planet_data.export_nside
	var result_ref: Array = [null]
	var task_entry := {
		"phase": 1, "task_id": -1, "result_ref": result_ref,
		"ipix": ipix, "col_res": col_res,
		"cached_shape": null, "evicted": false,
	}
	_server_chunk_tasks[key] = task_entry
	var task_id := WorkerThreadPool.add_task(func():
		result_ref[0] = PlanetChunk.generate_collision_shape_healpix(pd, nside, ipix, col_res)
	)
	task_entry["task_id"] = task_id


## Poll all in-flight server collision tasks.  Called every frame by
## _physics_process when is_server.  Stores heightmap results, promotes
## phase-0 completions to phase-1, and assembles finished shapes.
func _server_poll_chunk_tasks() -> void:
	if _server_chunk_tasks.is_empty():
		_server_drain_chunk_queue()
		return

	var completed_keys: Array[String] = []
	for key: String in _server_chunk_tasks:
		var entry: Dictionary = _server_chunk_tasks[key]
		var tid: int = entry["task_id"]
		if tid >= 0 and WorkerThreadPool.is_task_completed(tid):
			completed_keys.append(key)

	for key in completed_keys:
		var entry: Dictionary = _server_chunk_tasks[key]
		WorkerThreadPool.wait_for_task_completion(entry["task_id"])
		_server_chunk_tasks.erase(key)

		if entry.get("evicted", false):
			continue

		var phase: int = entry["phase"]
		var ipix: int = entry["ipix"]
		var col_res: int = entry["col_res"]
		var nside := _parse_nside_from_key(key)
		if nside <= 0:
			nside = planet_data.export_nside

		if phase == 0:
			var arr: Array = entry["result_ref"][0] as Array \
					if entry["result_ref"][0] != null else []
			var img: Image = arr[0] as Image if arr.size() > 0 else null
			if img:
				var craters: Array = arr[1] if arr.size() > 1 else []
				var pz: Array = arr[2] if arr.size() > 2 else []
				var lf: Array = arr[3] if arr.size() > 3 else []
				var rf: Array = arr[4] if arr.size() > 4 else []
				planet_data.store_chunk_image(key, img, craters, pz, lf, rf)
			var cs: ConcavePolygonShape3D = \
					entry.get("cached_shape") as ConcavePolygonShape3D
			if cs != null:
				_server_assemble_chunk(key, nside, ipix, cs)
			elif img != null:
				_server_submit_shape_task(key, ipix, col_res)
			else:
				push_warning("[PlanetTerrain] async _load_chunk: recipe '%s' null — skipping." % key)

		elif phase == 1:
			var shape: ConcavePolygonShape3D = \
					entry["result_ref"][0] as ConcavePolygonShape3D
			if shape:
				if _chunk_cache:
					_chunk_cache.save_collision(key, 0, shape)
				_server_assemble_chunk(key, nside, ipix, shape)
			else:
				push_warning("[PlanetTerrain] async _load_chunk: shape '%s' null — skipping." % key)

	_server_drain_chunk_queue()


## Chunk-local origin that server collision faces are rebased against
## (see [method PlanetChunk.generate_collision_shape]).  The CollisionShape3D
## is offset by exactly this value — applied in double precision by the node
## transform — so the small float32 faces land back on the visual surface.
func _chunk_collision_origin(nside: int, ipix: int) -> Vector3:
	return PlanetChunk.snap_to_f32(
		HEALPix.pix2vec_nest(nside, ipix) * planet_data.radius)


## Create a dedicated StaticBody3D for one chunk, positioned AT the chunk
## origin, with the shape at ZERO local offset.
##
## One small body per chunk instead of offset shapes on a single planet-wide
## body is REQUIRED for Jolt: Jolt's narrowphase runs in float32 relative to a
## body's origin (its double-precision mode only covers body POSITIONS).
## Shapes offset 6,356 km inside one planet-sized body put the contact math at
## float32 ULP ≈ 0.5 m — standing players/vehicles perpetually "danced" on
## centimetre-scale contact noise and vehicles never slept.  With the body
## origin at the chunk centre the narrowphase only ever sees ±~400 m values
## (ULP ≈ 60 µm).  A/B proof: scratchpad per_chunk_body_test.gd (2026-07-07).
## Also helps GodotPhysics' broadphase (many small AABBs vs one planet-sized).
func _make_chunk_collision_body(key: String, nside: int, ipix: int,
		shape: ConcavePolygonShape3D) -> StaticBody3D:
	shape.backface_collision = true  # solid from both sides (cached shapes too)
	var body := StaticBody3D.new()
	body.name = key + "_body"
	# Same identity as the legacy shared PlanetCollision body.
	body.collision_layer = Globals.LAYER_WORLD
	body.set_collision_layer_value(Globals.LAYER_WORLD, true)
	body.collision_mask = Globals.MASK_SOLID
	var col := CollisionShape3D.new()
	col.shape = shape
	col.name = key + "_col"
	body.add_child(col)
	body.position = _chunk_collision_origin(nside, ipix)
	return body


## Attach [param shape] to its own chunk collision body and spawn chunk
## features.  Must be called on the main thread only.  No-op if already
## assembled.
func _server_assemble_chunk(key: String, nside: int, ipix: int,
		shape: ConcavePolygonShape3D) -> void:
	if _server_collision_chunks.has(key):
		return  # Race guard: assembled by another path.
	var body := _make_chunk_collision_body(key, nside, ipix, shape)
	add_child(body)
	_server_collision_chunks[key] = body
	var faces: PackedVector3Array = shape.get_faces()
	if faces.size() > 0:
		var col_origin := _chunk_collision_origin(nside, ipix)
		var dmin: float = INF
		var dmax: float = -INF
		for v in faces:
			var d := (v + col_origin).length()
			if d < dmin: dmin = d
			if d > dmax: dmax = d
		@warning_ignore("integer_division")
		var tri_count: int = faces.size() / 3
		print("[PlanetTerrain] loaded chunk ", key, " tris=", tri_count,
			" alt_min=", dmin - planet_data.radius, " alt_max=", dmax - planet_data.radius,
			" body_global=", body.global_position,
			" body_layer=", body.collision_layer,
			" body_mask=", body.collision_mask)
	# Chunk features (caves/fumaroles/etc.) are keyed at export granularity;
	# only spawn them for coarse export-nside chunks so fine collision
	# sub-chunks pinned under bodies don't duplicate them.
	if nside == planet_data.export_nside:
		_spawn_chunk_features(key, nside, ipix)


## Parse the trailing ipix from a chunk key "hp_nN_pP".  Returns -1 on error.
static func _parse_ipix_from_key(key: String) -> int:
	var parts := key.split("_")
	if parts.size() < 3:
		return -1
	var p_part: String = parts[2]
	if not p_part.begins_with("p"):
		return -1
	return int(p_part.substr(1))


## Parse the nside from a chunk key "hp_nN_pP".  Returns 0 on error so callers
## can fall back to export_nside.  Lets fine (deeper-nside) collision chunks
## pinned under active bodies coexist with the coarse export-nside residency.
static func _parse_nside_from_key(key: String) -> int:
	var parts := key.split("_")
	if parts.size() < 2:
		return 0
	var n_part: String = parts[1]
	if not n_part.begins_with("n"):
		return 0
	return int(n_part.substr(1))


## Spawn cave/fumarole/volcano collision nodes from this chunk's populate
## zones.  Tracked in _server_feature_nodes so _unload_chunk can clean up.
func _spawn_chunk_features(key: String, nside: int, ipix: int) -> void:
	var info := {
		"key": key, "nside": nside, "ipix": ipix, "lod": 0,
		"center": HEALPix.pix2vec_nest(nside, ipix) * planet_data.radius,
	}
	var pz := _get_chunk_populate_zones(info)
	if pz.is_empty():
		return
	var spawned: Array = []
	for zone in pz:
		var bt: String = zone.get("biome_type", "")
		var bd = planet_data.get_biome_by_type(bt)
		if bd == null:
			continue
		var zone_dup: Dictionary = zone.duplicate()
		if not zone_dup.has("biome_index") and bd:
			zone_dup["biome_index"] = bd.biome_index
		if zone.get("coverage", "") == "point":
			if not zone_dup.has("polygon") and zone_dup.has("lon") and zone_dup.has("lat"):
				zone_dup["polygon"] = PackedVector2Array(
					[Vector2(zone_dup["lon"], zone_dup["lat"])])
		if CaveTerrain.is_cave_biome(bd):
			var cave_node := CaveSpawner.spawn(planet_data, info, zone_dup)
			if cave_node:
				_chunks_node.add_child(cave_node)
				spawned.append(cave_node)
		elif VolcanicGeothermalFumaroleTerrain.is_fumarole_biome(bd):
			var fum_node := VolcanicGeothermalFumaroleSpawner.spawn(
				planet_data, info, zone_dup)
			if fum_node:
				_chunks_node.add_child(fum_node)
				spawned.append(fum_node)
		elif VolcanicGeothermalActiveVolcanoTerrain.is_active_volcano_biome(bd):
			var volc_node := VolcanicSpawner.spawn(planet_data, info, zone_dup)
			if volc_node:
				_chunks_node.add_child(volc_node)
				spawned.append(volc_node)
	if not spawned.is_empty():
		_server_feature_nodes[key] = spawned


## Rebuild specific collision chunks after a biome update from Horizon.
## [param chunk_keys] — Array of chunk keys ("hp_nN_pP") to rebuild.
## [param biome_update] — Dictionary with biome data to inject before
##   regenerating the collision shape.  Keys:
##     biome_type: String (e.g. "cave", "road")
##     action: String ("add" or "remove")
##     geometry: Dictionary with type, vertices, width, depth
func rebuild_chunks(chunk_keys: Array, biome_update: Dictionary) -> void:
	if not _server_collision_loaded:
		push_warning("[PlanetTerrain] rebuild_chunks called before collision loaded.")
		return

	for key in chunk_keys:
		# Parse ipix/nside from key "hp_nN_pP".
		var parts := (key as String).split("_")
		if parts.size() < 3:
			push_warning("[PlanetTerrain] rebuild_chunks: invalid key '%s'" % key)
			continue
		var ipix := int(parts[2].substr(1))
		var nside := _parse_nside_from_key(key)
		if nside <= 0:
			nside = planet_data.export_nside
		var col_res := planet_data.collision_col_res_for(nside)

		# Inject biome modification into PlanetData.
		planet_data.inject_biome_feature(nside, ipix, biome_update)

		# Invalidate cached recipe so collision picks up the new data.
		planet_data.invalidate_chunk_cache(key)

		# If the chunk isn't currently resident (zone-scoped residency),
		# don't materialise it just for the rebuild — the recipe cache is
		# now invalidated, so the next set_resident_chunks(...) load will
		# pick up the new biome data automatically.  Also drop any stale
		# disk cache entry so the next load regenerates from the recipe.
		if not _server_collision_chunks.has(key):
			if _chunk_cache and _chunk_cache.has_collision(key, 0):
				# Save an empty placeholder is overkill; instead, force the
				# next load to regenerate by deleting the cached file via
				# DirAccess (cheap) — but for now we simply leave it: the
				# next physical load sees the updated recipe and overwrites.
				pass
			print("[PlanetTerrain] rebuild_chunks: '%s' not resident, recipe invalidated" % key)
			continue

		# Reload recipe.
		var result: Array = planet_data._load_recipe_heightmap(ipix, key)
		var img: Image = result[0] as Image if result.size() > 0 else null
		if img:
			var craters: Array = result[1] if result.size() > 1 else []
			var pz: Array = result[2] if result.size() > 2 else []
			var lf: Array = result[3] if result.size() > 3 else []
			var rf: Array = result[4] if result.size() > 4 else []
			planet_data.store_chunk_image(key, img, craters, pz, lf, rf)

		# Remove old chunk collision body.
		if _server_collision_chunks.has(key):
			var old_body: Node = _server_collision_chunks[key]
			old_body.queue_free()
			_server_collision_chunks.erase(key)

		# Regenerate collision shape on its own chunk body.
		var shape := PlanetChunk.generate_collision_shape_healpix(
			planet_data, nside, ipix, col_res)
		if shape:
			var body := _make_chunk_collision_body(key, nside, ipix, shape)
			add_child(body)
			_server_collision_chunks[key] = body
			# Update disk cache.
			if _chunk_cache:
				_chunk_cache.save_collision(key, 0, shape)

		print("[PlanetTerrain] rebuild_chunks: rebuilt '%s'" % key)


# ------------------------------------------------------------------
# Frame update
# ------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _initialized:
		return

	# ── Server: poll async collision chunk loading ────────────────
	if is_server:
		_server_poll_chunk_tasks()
		return

	# ── Editor: track camera and regenerate nearby chunks ────────
	if Engine.is_editor_hint():
		# Grace period after "Go to biome" — don't override the preview.
		if _editor_goto_cooldown > 0.0:
			_editor_goto_cooldown -= delta
			return
		_editor_track_timer += delta
		if _editor_track_timer < EDITOR_TRACK_INTERVAL:
			return
		_editor_track_timer = 0.0
		var cam_local := _get_editor_camera_local()
		if cam_local == Vector3.INF:
			return
		# Only regenerate when camera moved significantly (>5% of planet radius).
		if _editor_last_cam_local != Vector3.INF:
			var move_dist := cam_local.distance_to(_editor_last_cam_local)
			if move_dist < planet_data.radius * 0.05:
				return
		_editor_last_cam_local = cam_local
		_generate_editor_preview()
		return

	# ── Poll completed async work EVERY frame (not rate-limited) ───────
	# This minimises the latency between a task finishing and its result
	# appearing on screen.  The actual heavy work runs on worker threads;
	# these polls are cheap (flag checks + bounded assembly).
	_poll_pending_recipes()
	_poll_mesh_tasks()
	_process_assemble_queue()

	# ── Emit initial_chunks_ready once the pipeline drains ───────────
	if not _initial_ready_emitted and not _active_chunks.is_empty() \
			and _recipe_waiters.is_empty() and _mesh_tasks.is_empty() \
			and _assemble_queue.is_empty() and _mesh_task_backlog.is_empty() \
			and _pending_recipes.is_empty():
		_initial_ready_emitted = true
		initial_chunks_ready.emit()
		print("[PlanetTerrain] initial_chunks_ready emitted (active=%d)" % _active_chunks.size())

	# ── Rate-limited LOD update ──────────────────────────────────────
	_update_timer += delta
	if _update_timer < UPDATE_INTERVAL:
		return
	_update_timer = 0.0
	_update_terrain()


## World-space unit direction from this planet's centre to the system star, in DOUBLE precision (exact
## at ~3e10). Fed to the terrain shader for the celestial-layer star lighting. Falls back to the last
## value if the star node is not resolvable yet.
func _compute_star_dir() -> Vector3:
	var scene: Node = NetworkOrchestrator.universe_scene
	if scene == null:
		return _star_dir_world
	var star: Node = scene.get_node_or_null("Star")
	if not (star is Node3D):
		return _star_dir_world
	var to_star: Vector3 = (star as Node3D).global_position - global_position
	if to_star.length_squared() < 1.0:
		return _star_dir_world
	return to_star.normalized()


func _update_terrain() -> void:
	var camera_pos := _get_reference_position()
	if camera_pos == Vector3.INF:
		if _active_chunks.is_empty() and not is_server:
			print("[PlanetTerrain] _update_terrain: camera not available yet")
		return

	# Camera position in planet-local space.
	# global_transform.basis holds the planet's world rotation; inverting it
	# converts the world-space offset into the planet's local coordinate frame,
	# which is the space where HEALPix directions (pix2vec_nest) live.
	# Without this, any planet rotation causes the LOD tree to compare camera
	# directions in world space against chunk centers in local space → wrong
	# chunks selected (visible as thin radial slices far from the player).
	var local_cam := global_transform.basis.inverse() * (camera_pos - global_position)
	_last_local_cam = local_cam
	var cam_dist := local_cam.length()

	# Altitude above the real terrain surface (crack-aware), NOT sea level —
	# see _cam_alt_above_surface. One heightmap sample per update (0.25 s).
	if cam_dist > 0.0:
		var _cam_surf_r: float = planet_data.crack_aware_surface_dist(local_cam / cam_dist)
		_cam_alt_above_surface = maxf(cam_dist - _cam_surf_r, 0.0)
	else:
		_cam_alt_above_surface = 0.0

	# Skip terrain entirely when the camera is deep inside the planet body.
	# This avoids rendering useless LOD4 shells for a gas-giant parent while
	# the player stands on a moon far inside that giant's radius.
	if cam_dist < planet_data.radius * 0.9:
		_clear_all_chunks()
		return

	# Altitude above the actual terrain (not sea level — high plateaus would
	# otherwise inflate this by their elevation). Already clamped ≥ 0, which
	# also treats "under surface" as "on surface" to avoid degenerate
	# quadtree subdivision when the player spawns slightly below ground.
	var surface_distance := _cam_alt_above_surface
	var planet_lod := planet_data.get_lod_level(surface_distance)

	# Distant bodies (whole-planet LOD >= 3) render their coarse chunks on the CELESTIAL layer, where the
	# LOCAL per-player sun (aimed at YOU, wrong for a distant body) is masked off. They light THEMSELVES
	# in the terrain shader from _star_dir_world (the real star direction, correct per-body day/night with
	# a clean terminator via the radial normal). Near (you are on/at the planet, LOD < 3) stays local so
	# the player's sun + shadows drive the surface. A per-planet switch, so your whole planet (horizon too)
	# stays local while other planets go celestial. Re-tag existing chunks only on a transition.
	if not is_server:
		_star_dir_world = _compute_star_dir()
		var want_celestial: bool = planet_lod >= 3
		if want_celestial != _chunks_on_celestial:
			_chunks_on_celestial = want_celestial
			var layer: int = Globals.RENDER_MASK_CELESTIAL if want_celestial else Globals.RENDER_MASK_LOCAL
			for ck in _active_chunks:
				var cmi: MeshInstance3D = _active_chunks[ck].get("mesh_instance")
				if is_instance_valid(cmi):
					cmi.layers = layer

	# Update camera history ring-buffer for look-ahead prefetch.
	_cam_history.append(local_cam)
	if _cam_history.size() > CAM_HISTORY_SIZE:
		_cam_history.remove_at(0)

	# One-shot debug on first valid update
	# if _active_chunks.is_empty():
	# 	print("[PlanetTerrain] first update: cam=%s  surface_dist=%.0f  lod=%d  chunk_count=%d" % [
	# 		camera_pos, surface_distance, planet_lod, _active_chunks.size()])

	# Build the desired set of leaf chunks across all 12 HEALPix base pixels
	# ── Horizon culling: precompute the cosine threshold ──────────
	# A chunk whose center-direction dot with the camera-direction is
	# below this value is beyond the geometric horizon and invisible.
	#   horizon_angle = acos(R / cam_dist)  (tangent line from camera to sphere)
	# We add a margin for mountains/trees and the chunk's own angular radius.
	var horizon_dot := -1.0  # default: no culling (camera inside planet or very far)
	if cam_dist > planet_data.radius:
		var horizon_angle := acos(planet_data.radius / cam_dist) + HORIZON_MARGIN_RAD
		# cos(PI - horizon_angle) = -cos(horizon_angle)
		# But we compare dot(cam_dir, chunk_dir) — both point from planet center.
		# Chunk is visible when angle between cam_dir and chunk_dir < horizon_angle.
		# dot = cos(angle), so visible when dot > cos(horizon_angle).
		horizon_dot = cos(horizon_angle)

	var desired: Dictionary = {}
	for base_pix in BASE_PIXEL_COUNT:
		_traverse(1, base_pix, 0, local_cam, horizon_dot, desired)

	# One-shot: log chunk count breakdown by LOD
	if _active_chunks.is_empty() and not desired.is_empty():
		var lod_counts := [0, 0, 0, 0, 0]
		for key in desired:
			var l: int = desired[key].lod
			if l < lod_counts.size():
				lod_counts[l] += 1
		print("[PlanetTerrain] desired %d chunks: LOD0=%d LOD1=%d LOD2=%d LOD3=%d LOD4=%d" % [
			desired.size(), lod_counts[0], lod_counts[1], lod_counts[2], lod_counts[3], lod_counts[4]])

	# Step 1 — Queue new chunks FIRST so children/parents are in the pipeline
	# before we decide whether to remove their counterparts.
	# This ensures _has_pending_replacement / _has_pending_coarser can see them.
	# Sort by distance to camera so nearby (LOD0) chunks get pipeline priority
	# over distant (LOD2/LOD3) chunks — avoids far chunks starving the recipe
	# and mesh-task slots while the player sees no terrain underfoot.
	var _sorted_keys := desired.keys()
	_sorted_keys.sort_custom(func(a: String, b: String) -> bool:
		return desired[a].center.distance_squared_to(local_cam) < desired[b].center.distance_squared_to(local_cam))
	for key in _sorted_keys:
		if not _active_chunks.has(key) and not _is_chunk_in_pipeline(key):
			_try_create_or_defer(desired[key])

	# Step 2 — Remove chunks no longer desired, but only after their
	# replacements (finer children or coarser parent) are queued above.
	# This guarantees the old chunk stays visible until the new one arrives.
	var to_remove: Array = []
	for key in _active_chunks:
		if not desired.has(key):
			# A stale chunk whose area is already fully covered by ACTIVE finer
			# chunks must go NOW, regardless of pipeline state: its replacement
			# is on screen, so no hole is possible. Without this, the constant
			# pipeline churn near the player (per-chunk LOD re-queues) keeps
			# _has_pending_replacement() true forever and the coarse parent
			# lingers as a second, uncarved surface stacked over the fine one.
			var st_nside := _parse_nside_from_key(key)
			var st_ipix := _parse_ipix_from_key(key)
			if st_nside > 0 and st_ipix >= 0 \
					and _covered_by_active_descendants(st_nside, st_ipix):
				to_remove.append(key)
			elif not _has_pending_replacement(key) and not _has_pending_coarser(key):
				to_remove.append(key)
	for key in to_remove:
		_remove_chunk(key)

	# Step 3 — Re-queue chunks whose LOD quality changed (same key, different lod).
	for key in desired:
		if _active_chunks.has(key) and _active_chunks[key].lod != desired[key].lod:
			if not _is_chunk_in_pipeline(key):
				_remove_chunk(key)
				_try_create_or_defer(desired[key])

	# Look-ahead: prefetch chunks along the predicted camera trajectory so
	# they're ready before the player reaches them.
	_prefetch_look_ahead(local_cam, horizon_dot)


# ------------------------------------------------------------------
# Editor preview
# ------------------------------------------------------------------

## Get the editor 3D viewport camera position in planet-local space.
func _get_editor_camera_local() -> Vector3:
	if not Engine.is_editor_hint():
		return Vector3.INF
	var ei = Engine.get_singleton("EditorInterface")
	if ei == null:
		return Vector3.INF
	var viewport = ei.get_editor_viewport_3d(0)
	if viewport == null:
		return Vector3.INF
	var cam = viewport.get_camera_3d()
	if cam == null:
		return Vector3.INF
	return cam.global_position - global_position


## Generate an editor preview centred on the editor camera.
## Spawns the centre HEALPix pixel plus [member editor_preview_rings] rings of
## neighbours at the configured [member editor_preview_depth].
## When [member editor_preview_vegetation] is enabled, tree and grass
## MultiMeshes are also generated on those chunks.
## Called only in the Godot editor (@tool mode).
## [param center_local]: if not [constant Vector3.INF], use this planet-local
## position as the preview centre instead of the editor camera.
func _generate_editor_preview(center_local: Vector3 = Vector3.INF) -> void:
	var depth := editor_preview_depth
	var nside := HEALPix.depth_to_nside(depth)
	var res := planet_data.chunk_resolution

	# ── Determine reference pixel ─────────────────────────────────
	var ref_local := center_local
	if ref_local == Vector3.INF:
		ref_local = _get_editor_camera_local()
	if ref_local == Vector3.INF:
		return

	var cam_dir := ref_local.normalized()
	var center_ipix := HEALPix.vec2pix_nest(nside, cam_dir)

	# ── Build pixel set: centre + N rings of neighbours ───────────
	# BFS outward: each ring adds the 8-neighbourhood of the previous
	# frontier, producing a roughly (2N+1)×(2N+1) patch of chunks.
	var pixel_set := {center_ipix: true}
	var frontier := [center_ipix]
	for _ring in editor_preview_rings:
		var next_frontier: Array = []
		for p in frontier:
			var nbrs := HEALPix.get_neighbors_nest(nside, p)
			for dir_name in nbrs:
				var nb: int = nbrs[dir_name]
				if nb >= 0 and not pixel_set.has(nb):
					pixel_set[nb] = true
					next_frontier.append(nb)
		frontier = next_frontier
	var pixels := pixel_set.keys()

	# ── Reuse: keep chunks already built, free the rest ───────────
	# Chunk keys are deterministic per (nside, ipix), so a chunk that
	# stays in the patch — or a preview that just re-centres a chunk or
	# two away — is reused as-is instead of being recomputed. Changing the
	# depth changes nside → new keys → full rebuild, which is correct.
	var want_veg := editor_preview_vegetation
	var desired := {}
	for ipix in pixels:
		desired["editor_hp_n%d_p%d" % [nside, ipix]] = ipix

	for old_key in _active_chunks.keys():
		var old: Dictionary = _active_chunks[old_key]
		# Drop chunks no longer in the patch, or whose vegetation state
		# no longer matches the current toggle.
		if not desired.has(old_key) or old.get("veg", false) != want_veg:
			_free_editor_chunk(old)
			_active_chunks.erase(old_key)

	var reused := _active_chunks.size()
	var built := 0

	for key in desired:
		if _active_chunks.has(key):
			continue  # already built and still valid — skip recompute
		var ipix: int = desired[key]
		built += 1
		var chunk_center := PlanetChunk.snap_to_f32(
			HEALPix.pix2vec_nest(nside, ipix) * planet_data.radius)

		# ── Terrain mesh ──────────────────────────────────────
		var mesh := PlanetChunk.generate_mesh_healpix(
			planet_data, nside, ipix, res, chunk_center)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.name = key
		mi.position = chunk_center
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var _wrap := 8192.0
		mi.set_instance_shader_parameter("chunk_origin_mod", Vector3(
			fposmod(chunk_center.x, _wrap),
			fposmod(chunk_center.y, _wrap),
			fposmod(chunk_center.z, _wrap)))
		# Full planet-local chunk centre for the terrain shader's true-radial normal (far terminator fix).
		mi.set_instance_shader_parameter("chunk_center_local", chunk_center)
		mi.set_instance_shader_parameter("star_dir_world", _star_dir_world)
		_chunks_node.add_child(mi)
		var info: Dictionary = {"key": key, "mesh_instance": mi, "veg": want_veg}

		# ── Vegetation (trees + grass) ────────────────────────
		if want_veg:
			var _ed_info := {"nside": nside, "ipix": ipix}
			var _ed_pz := _get_chunk_populate_zones(_ed_info)
			var _ed_has_forest := _zones_have_biome(_ed_pz, ForestTemperateForestTerrain.BIOME_TYPE)
			var _ed_has_meadow := _zones_have_biome(_ed_pz, MeadowSteppeMeadowTerrain.BIOME_TYPE)
			# Forest temperate trees
			if _ed_has_forest:
				var _ed_lf := planet_data.get_chunk_linear_features(
					_get_export_ipix(_ed_info))
				var tree_mm := ForestTemperateForestSpawner.scatter_trees_hp(
					planet_data, null, nside, ipix,
					chunk_center, 0, _ed_pz, _ed_lf)
				if tree_mm:
					var tree_mmi := MultiMeshInstance3D.new()
					tree_mmi.multimesh = tree_mm
					tree_mmi.name = key + "_forest_trees"
					tree_mmi.position = chunk_center
					tree_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					_chunks_node.add_child(tree_mmi)
					info["forest"] = tree_mmi

			# Meadow grass
			if _ed_has_meadow:
				var grass_mm := MeadowSteppeMeadowSpawner.scatter_grass_hp(
					planet_data, null, nside, ipix,
					chunk_center, 0, _ed_pz)
				if grass_mm:
					var grass_mmi := MultiMeshInstance3D.new()
					grass_mmi.multimesh = grass_mm
					grass_mmi.name = key + "_grass"
					grass_mmi.position = chunk_center
					grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					_chunks_node.add_child(grass_mmi)
					info["meadow"] = grass_mmi

		_active_chunks[key] = info

	print("[PlanetTerrain] Editor preview: HEALPix nside=%d center_ipix=%d chunks=%d (built=%d reused=%d) veg=%s" % [
		nside, center_ipix, _active_chunks.size(), built, reused, editor_preview_vegetation])


## Remove and free the nodes of a single editor-preview chunk (terrain mesh
## plus any vegetation MultiMeshInstances). Used by the reuse diff in
## [method _generate_editor_preview].
func _free_editor_chunk(info: Dictionary) -> void:
	for node_key in ["mesh_instance", "forest", "meadow"]:
		var n = info.get(node_key)
		if n and is_instance_valid(n):
			_chunks_node.remove_child(n)
			n.free()


## Print the 3D world positions of all biome zone centroids so you know
## where to point the editor camera.  Called once on initialize().
func _print_biome_locations() -> void:
	var all_zones := planet_data.get_all_populate_zones()
	if all_zones.is_empty():
		print("[PlanetTerrain] No populate zones loaded — cannot print biome locations.")
		return
	print("[PlanetTerrain] ── Biome locations (move editor camera here) ──")
	for zone in all_zones:
		var bt: String = zone.get("biome_type", "")
		var centroid := Vector2.ZERO
		var cov: String = zone.get("coverage", "")
		if cov == "point":
			centroid = Vector2(zone.get("lon", 0.0), zone.get("lat", 0.0))
		elif cov == "partial":
			var verts: Array = zone.get("vertices", [])
			if verts.size() > 0:
				for v in verts:
					centroid += Vector2(v[0], v[1])
				centroid /= float(verts.size())
		else:
			continue  # "full" zones have no geometry — skip
		var lon_rad := deg_to_rad(centroid.x)
		var lat_rad := deg_to_rad(centroid.y)
		var dir := Vector3(
			cos(lat_rad) * cos(lon_rad),
			sin(lat_rad),
			cos(lat_rad) * sin(lon_rad)).normalized()
		var world_pos := dir * (planet_data.radius + 50.0)
		var lonlat := HEALPix.vec2lonlat(dir)
		print("  %-25s  lon=%.4f  lat=%.4f  world_pos=(%d, %d, %d)" % [
			bt, lonlat.x, lonlat.y,
			int(world_pos.x), int(world_pos.y), int(world_pos.z)])
	print("[PlanetTerrain] ── Tip: select a biome from the dropdown in the Inspector ──")


# ------------------------------------------------------------------
# Editor biome navigator (dynamic dropdown + goto)
# ------------------------------------------------------------------

## Build the list of biome entries from populate zones for the dropdown.
func _populate_biome_entries() -> void:
	_editor_biome_entries.clear()
	var all_zones := planet_data.get_all_populate_zones()
	if all_zones.is_empty():
		return
	var counts: Dictionary = {}
	for zone in all_zones:
		var bt: String = zone.get("biome_type", "")
		var cov: String = zone.get("coverage", "")
		var centroid := Vector2.ZERO
		if cov == "point":
			centroid = Vector2(zone.get("lon", 0.0), zone.get("lat", 0.0))
		elif cov == "partial":
			var verts: Array = zone.get("vertices", [])
			if verts.size() > 0:
				for v in verts:
					centroid += Vector2(v[0], v[1])
				centroid /= float(verts.size())
		else:
			continue  # "full" zones have no geometry — skip
		counts[bt] = counts.get(bt, 0) + 1
		var label := "%s #%d" % [bt, counts[bt]]
		var lon_rad := deg_to_rad(centroid.x)
		var lat_rad := deg_to_rad(centroid.y)
		var dir := Vector3(
			cos(lat_rad) * cos(lon_rad),
			sin(lat_rad),
			cos(lat_rad) * sin(lon_rad)).normalized()
		_editor_biome_entries.append({
			"label": label,
			"dir": dir,
			"world_pos": dir * (planet_data.radius + 200.0),
		})
	notify_property_list_changed()


## Expose a dynamic dropdown in the Inspector listing all loaded biomes.
func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	if Engine.is_editor_hint() and not _editor_biome_entries.is_empty():
		var names := ""
		for i in _editor_biome_entries.size():
			if i > 0:
				names += ","
			names += _editor_biome_entries[i].label
		props.append({
			"name": "editor_goto_biome",
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": names,
			"usage": PROPERTY_USAGE_EDITOR,
		})
	return props


func _set(property: StringName, value: Variant) -> bool:
	if property == &"editor_goto_biome":
		_editor_selected_biome_idx = int(value)
		if _initialized:
			_goto_selected_biome()
		return true
	return false


func _get(property: StringName) -> Variant:
	if property == &"editor_goto_biome":
		return _editor_selected_biome_idx
	return null


## Teleport the editor preview to the selected biome and place a focus marker.
func _goto_selected_biome() -> void:
	if _editor_selected_biome_idx < 0 \
			or _editor_selected_biome_idx >= _editor_biome_entries.size():
		return
	var entry: Dictionary = _editor_biome_entries[_editor_selected_biome_idx]
	_editor_goto_surface_point(entry.dir, "biome: %s" % entry.label)


## Teleport the editor preview to the [member editor_goto_lon] /
## [member editor_goto_lat] surface point, and update the x/y/z fields to the
## matching surface coordinates. Bound to the "Go to lon/lat" inspector button.
func _goto_lonlat() -> void:
	if not _initialized:
		return
	var dir := HEALPix.lonlat2vec(editor_goto_lon, editor_goto_lat)
	# Sync x/y/z to the surface point in that direction.
	var surface: Vector3 = dir * planet_data.radius
	editor_goto_x = surface.x
	editor_goto_y = surface.y
	editor_goto_z = surface.z
	notify_property_list_changed()
	_editor_goto_surface_point(
		dir, "lon=%.4f lat=%.4f" % [editor_goto_lon, editor_goto_lat])


## Teleport the editor preview to the [member editor_goto_x] /
## [member editor_goto_y] / [member editor_goto_z] point (projected onto the
## surface along its direction from the planet centre), and update the lon/lat
## fields to match. Bound to the "Go to coordinates" inspector button.
func _goto_coordinates() -> void:
	if not _initialized:
		return
	var pos := Vector3(editor_goto_x, editor_goto_y, editor_goto_z)
	if pos.length_squared() < 1.0:
		push_warning("[PlanetTerrain] Go to coordinates: x/y/z is at the "
			+ "planet centre — cannot derive a direction.")
		return
	var dir := pos.normalized()
	# Sync lon/lat to this direction.
	var lonlat := HEALPix.vec2lonlat(dir)
	editor_goto_lon = lonlat.x
	editor_goto_lat = lonlat.y
	notify_property_list_changed()
	_editor_goto_surface_point(
		dir, "x=%.0f y=%.0f z=%.0f (lon=%.4f lat=%.4f)" % [
			editor_goto_x, editor_goto_y, editor_goto_z, lonlat.x, lonlat.y])


## Recenter the editor preview on a surface point (unit [param dir]) and drop
## a focus marker the user can frame with F. Shared by the biome dropdown and
## the "Go to lon/lat" button.
func _editor_goto_surface_point(dir: Vector3, label: String) -> void:
	var surface_local: Vector3 = dir * planet_data.radius
	var world_pos: Vector3 = dir * (planet_data.radius + 200.0)

	# Create or move the focus marker so the user can press F to frame it.
	if not _editor_biome_focus or not is_instance_valid(_editor_biome_focus):
		_editor_biome_focus = Node3D.new()
		_editor_biome_focus.name = "BiomeFocus"
		add_child(_editor_biome_focus)
		# Ensure the marker is not saved with the scene.
		_editor_biome_focus.owner = null
	_editor_biome_focus.position = world_pos

	# Generate preview centred on this point (not on the camera).
	_generate_editor_preview(surface_local)

	# Prevent camera tracking from overwriting the preview for 3 seconds,
	# giving the user time to press F to fly to it.
	_editor_goto_cooldown = 3.0
	_editor_last_cam_local = surface_local

	# Select the marker so the user can press F to frame it.
	var ei = Engine.get_singleton("EditorInterface")
	if ei:
		ei.get_selection().clear()
		ei.get_selection().add_node(_editor_biome_focus)

	print("[PlanetTerrain] Go to %s — world=(%d, %d, %d) — press F to frame" % [
		label, int(world_pos.x), int(world_pos.y), int(world_pos.z)])


## Auto-tune the editor 3D viewport camera to the planet's scale: a far clip
## plane that clears the whole planet, a small near plane for surface detail,
## and a freelook fly speed proportional to the radius. Applied on load (when
## [member editor_auto_tune_camera] is set) and via the inspector button.
func _auto_tune_editor_camera() -> void:
	if not Engine.is_editor_hint():
		return
	var ei = Engine.get_singleton("EditorInterface")
	if ei == null:
		return
	var es = ei.get_editor_settings()
	if es == null:
		return
	var r: float = planet_data.radius if planet_data else 1000.0
	# Far plane must clear the far side of the planet plus atmosphere; near
	# plane stays small so surface geometry doesn't clip when flying low.
	var z_far: float = maxf(r * 4.0, 100000.0)
	var fly_speed: float = maxf(r * 0.02, 100.0)
	es.set_setting("editors/3d/default_z_near", 0.5)
	es.set_setting("editors/3d/default_z_far", z_far)
	es.set_setting("editors/3d/freelook/freelook_base_speed", fly_speed)
	print("[PlanetTerrain] Camera tuned to radius=%.0f — z_far=%.0f, fly_speed=%.0f" % [
		r, z_far, fly_speed])


## Compute the global transform that places [param n3] on the planet surface
## directly below it (radially, toward the planet centre). Samples the terrain
## heightmap along the object's own direction from the centre — no physics
## raycast needed, so it works even though the editor preview chunks have no
## collision, and it follows the sphere's true "down" instead of global −Y.
## When [member editor_snap_align_to_normal] is set, the object is also
## rotated so its +Y points along the surface normal (heading preserved).
## Returns the object's current transform unchanged if it sits at the planet
## centre (no direction to snap along). Pure — does not mutate [param n3];
## the "Planet Tools" editor plugin applies the result through UndoRedo.
func compute_surface_transform(n3: Node3D) -> Transform3D:
	var xform := n3.global_transform
	if planet_data == null:
		return xform
	var planet_center := global_position
	var local_pos := n3.global_position - planet_center
	if local_pos.length_squared() < 1.0:
		return xform  # at the planet centre — no radial direction
	var dir := local_pos.normalized()
	var h := planet_data.sample_height_for_direction(dir)
	var surface_pos := planet_center \
		+ dir * (planet_data.radius + h + editor_snap_height_offset)

	if not editor_snap_align_to_normal:
		# Position only — preserve the current rotation and scale.
		xform.origin = surface_pos
		return xform

	# Rotate so +Y points along the surface normal, keeping the object's
	# current heading (its −Z) projected onto the tangent plane so it doesn't
	# spin unpredictably. Preserve the object's global scale.
	var gscale := n3.global_transform.basis.get_scale()
	var y_axis := dir
	var z_axis := n3.global_transform.basis.z
	z_axis = z_axis - y_axis * z_axis.dot(y_axis)
	if z_axis.length_squared() < 1e-6:
		z_axis = y_axis.cross(Vector3.RIGHT)
		if z_axis.length_squared() < 1e-6:
			z_axis = y_axis.cross(Vector3.BACK)
	z_axis = z_axis.normalized()
	var x_axis := y_axis.cross(z_axis).normalized()
	z_axis = x_axis.cross(y_axis).normalized()
	var basis := Basis(x_axis, y_axis, z_axis).scaled(gscale)
	return Transform3D(basis, surface_pos)


# ------------------------------------------------------------------
# Quadtree traversal
# ------------------------------------------------------------------

func _traverse(nside: int, ipix: int, depth: int,
		local_cam: Vector3, horizon_dot: float, out: Dictionary) -> void:

	var center_dir := HEALPix.pix2vec_nest(nside, ipix)
	var center_pos := center_dir * planet_data.radius

	# Approximate chunk diagonal using two diagonal corners
	var corners: Array = HEALPix.get_pixel_corners(nside, ipix)
	var corner_a: Vector3 = corners[0] * planet_data.radius  # SW
	var corner_b: Vector3 = corners[2] * planet_data.radius  # NE
	var chunk_diag: float = corner_a.distance_to(corner_b)

	# LOD distance = max(surface distance to the chunk, camera altitude above
	# the ACTUAL terrain surface).  Straight-line distance to the sea-level
	# chunk centre is wrong twice over: cracks/valleys put the camera below
	# the centres, and high terrain (tarsis_4's plateau is ~5.6 km above the
	# sea-level radius) inflates EVERY distance by its elevation — so the
	# quadtree never reached its finest depth and the render sat coarser than
	# the always-finest collision (player under the displayed floor).  The
	# surface (horizontal) distance ignores the radial gap entirely; the
	# terrain-relative altitude still coarsens the view from high up / space.
	var _cam_r := local_cam.length()
	var _cam_dir_l: Vector3 = local_cam / _cam_r if _cam_r > 0.0 else center_dir
	var _surface_dist := (_cam_dir_l - center_dir).length() * planet_data.radius
	var dist := maxf(_surface_dist, _cam_alt_above_surface)

	# Client-side back-face culling (skip chunks behind the planet)
	if not is_server:
		if center_dir.dot(local_cam.normalized()) < BACKFACE_DOT:
			return

	# ── Horizon culling ──────────────────────────────────────────
	# Skip chunks whose centre is beyond the geometric horizon.
	# Add the chunk's angular half-size so partially-visible chunks
	# at the horizon edge are kept.
	if not is_server and horizon_dot > -1.0:
		var chunk_angular_radius := 0.0
		if planet_data.radius > 0.0:
			chunk_angular_radius = (chunk_diag * 0.5) / planet_data.radius
		var cam_dir := local_cam.normalized()
		var dot_val := center_dir.dot(cam_dir)
		# visible when dot_val > horizon_dot - chunk_angular_radius
		if dot_val < horizon_dot - chunk_angular_radius:
			return

	# Decide whether to subdivide
	var should_subdivide := false
	if depth < planet_data.max_quadtree_depth:
		if dist < chunk_diag * SUBDIVIDE_FACTOR:
			should_subdivide = true

	if should_subdivide:
		var child_nside := nside * 2
		var children := HEALPix.child_pixels(ipix)
		for child_ipix in children:
			_traverse(child_nside, child_ipix, depth + 1, local_cam, horizon_dot, out)
	else:
		# Leaf — record desired chunk
		# Per-chunk LOD: use camera-to-chunk distance (not altitude-based).
		var lod := planet_data.get_lod_level(dist)
		var key := _chunk_key_hp(nside, ipix)
		# Snap centre to float32 so mi.position matches the cc_f32 used
		# inside generate_mesh.  Without this, the float64→float32 delta
		# (~0.12 m per component at planet radius) shifts adjacent chunks'
		# shared-edge vertices apart, creating visible seams.
		out[key] = {
			"key": key,
			"nside": nside,
			"ipix": ipix,
			"depth": depth,
			"center": PlanetChunk.snap_to_f32(center_pos),
			"lod": lod,
		}


# ------------------------------------------------------------------
# Async pipeline helpers
# ------------------------------------------------------------------

## Returns true if the chunk key is anywhere in the async pipeline:
## recipe_waiters, mesh_tasks, mesh_task_backlog, or assemble_queue.
func _is_chunk_in_pipeline(key: String) -> bool:
	if _mesh_tasks.has(key):
		return true
	for item in _assemble_queue:
		if item.info.key == key:
			return true
	for item in _mesh_task_backlog:
		if item.key == key:
			return true
	for ek in _recipe_waiters:
		if _recipe_waiters[ek].has(key):
			return true
	return false


## Returns true when the area of chunk (nside, ipix) is FULLY covered by
## active finer chunks: every direct child is either active itself or
## (recursively) covered by its own children. Used by the desired-set diff to
## drop a stale coarse chunk the moment its finer replacements are all on
## screen — pipeline churn must not keep both surfaces stacked.
## [param max_depth] bounds the recursion (LOD split is 1 level at a time in
## practice; 4 covers any transient mixed state).
func _covered_by_active_descendants(nside: int, ipix: int, max_depth: int = 4) -> bool:
	if max_depth <= 0:
		return false
	var child_nside := nside * 2
	# No chunks exist finer than the quadtree's max depth — stop descending
	# (also keeps child ipix values inside int32 for HEALPix.child_pixels).
	if child_nside > (1 << planet_data.max_quadtree_depth):
		return false
	for child_ipix: int in HEALPix.child_pixels(ipix):
		if _active_chunks.has(_chunk_key_hp(child_nside, child_ipix)):
			continue
		if not _covered_by_active_descendants(child_nside, child_ipix, max_depth - 1):
			return false
	return true


## Returns true if any chunk in the async pipeline is a HEALPix descendant
## (finer subdivision) of [param key], so the active chunk should stay visible
## while its children are loading.  Key format: "hp_nN_pP".
func _has_pending_replacement(key: String) -> bool:
	var parts := key.split("_")
	if parts.size() < 3:
		return false
	var a_nside := int(parts[1].substr(1))  # "nN" -> N
	var a_ipix  := int(parts[2].substr(1))  # "pP" -> P

	# Check mesh_tasks
	for mk: String in _mesh_tasks:
		var ci: Dictionary = _mesh_tasks[mk].info
		if _hp_is_descendant(a_nside, a_ipix, ci.nside, ci.ipix):
			return true
	# Check backlog
	for ci: Dictionary in _mesh_task_backlog:
		if _hp_is_descendant(a_nside, a_ipix, ci.nside, ci.ipix):
			return true
	# Check assemble_queue
	for item: Dictionary in _assemble_queue:
		var ci: Dictionary = item.info
		if _hp_is_descendant(a_nside, a_ipix, ci.nside, ci.ipix):
			return true
	# Check recipe_waiters
	for ek: String in _recipe_waiters:
		for ck: String in _recipe_waiters[ek]:
			var ci: Dictionary = _recipe_waiters[ek][ck]
			if _hp_is_descendant(a_nside, a_ipix, ci.nside, ci.ipix):
				return true
	return false


## Returns true if any chunk in the async pipeline is a HEALPix ANCESTOR
## (coarser subdivision) of [param key], so the active chunk should stay
## visible while its coarser replacement is still loading.
## Prevents holes when the player moves away and 4 fine children merge into 1.
func _has_pending_coarser(key: String) -> bool:
	var parts := key.split("_")
	if parts.size() < 3:
		return false
	var a_nside := int(parts[1].substr(1))
	var a_ipix  := int(parts[2].substr(1))

	# ci is an ancestor of (a_nside, a_ipix) when (a_nside, a_ipix) is a
	# descendant of ci — i.e. _hp_is_descendant(ci, a) is true.
	for mk: String in _mesh_tasks:
		var ci: Dictionary = _mesh_tasks[mk].info
		if _hp_is_descendant(ci.nside, ci.ipix, a_nside, a_ipix):
			return true
	for ci: Dictionary in _mesh_task_backlog:
		if _hp_is_descendant(ci.nside, ci.ipix, a_nside, a_ipix):
			return true
	for item: Dictionary in _assemble_queue:
		var ci: Dictionary = item.info
		if _hp_is_descendant(ci.nside, ci.ipix, a_nside, a_ipix):
			return true
	for ek: String in _recipe_waiters:
		for ck: String in _recipe_waiters[ek]:
			var ci: Dictionary = _recipe_waiters[ek][ck]
			if _hp_is_descendant(ci.nside, ci.ipix, a_nside, a_ipix):
				return true
	return false


## Returns true if (b_nside, b_ipix) is a strict descendant of (a_nside, a_ipix)
## in HEALPix NESTED ordering.  In NESTED, each parent contains exactly 4
## children, so: parent(b) at nside a_nside == a_ipix iff
##   b_ipix >> (2 * log2(b_nside / a_nside)) == a_ipix.
static func _hp_is_descendant(a_nside: int, a_ipix: int, b_nside: int, b_ipix: int) -> bool:
	if b_nside <= a_nside:
		return false
	@warning_ignore("integer_division")
	var ratio: int = b_nside / a_nside
	# ratio must be a power of 2
	var shift := 0
	var r := ratio
	while r > 1:
		if r % 2 != 0:
			return false
		r /= 2
		shift += 2  # 2 bits per level in NESTED
	return (b_ipix >> shift) == a_ipix


# ------------------------------------------------------------------
# Async recipe pre-warming
# ------------------------------------------------------------------

## Queue a chunk for async generation.
## If the recipe heightmap is already cached, the mesh task is submitted
## immediately.  Otherwise the chunk is registered as a recipe waiter and
## won't be created until the recipe arrives.
## This replaces the old _try_create_or_defer which always created chunks
## synchronously with fallback heights.
func _try_create_or_defer(info: Dictionary) -> void:
	# Find the export-level pixel that covers this chunk.
	var runtime_nside: int = info.nside
	var runtime_ipix: int = info.ipix
	var epd_nside := planet_data.export_nside

	var export_ipix := runtime_ipix
	var cur_nside := runtime_nside

	# Walk UP the tree: chunk is finer than export → find ancestor pixel.
	while cur_nside > epd_nside:
		export_ipix = HEALPix.parent_pixel(export_ipix)
		cur_nside /= 2

	# Walk DOWN the tree: chunk is coarser than export → first descendant.
	while cur_nside < epd_nside:
		export_ipix = export_ipix * 4
		cur_nside *= 2

	var export_key := "hp_n%d_p%d" % [epd_nside, export_ipix]
	var chunk_center: Vector3 = info.center
	var cam_dist_sq: float = chunk_center.distance_squared_to(_last_local_cam)

	# ── File mode: per-chunk .r32 elevation tiles, no recipe pipeline ──
	# load_chunk_heightmap() lazily loads the exported tile (on the worker
	# thread for client meshes, on the calling thread for server collision)
	# while sampling heights, so we create the chunk directly instead of
	# waiting on a recipe-generation task.
	if planet_data.chunk_heightmaps_dir != "":
		if is_server:
			_create_chunk(info)
			return
		# Client: respect the mesh disk cache, otherwise mesh asynchronously.
		if _chunk_cache and _chunk_cache.has_mesh(info.key, info.lod):
			var cached_mesh := _chunk_cache.load_mesh(info.key, info.lod)
			if cached_mesh and _cached_mesh_valid(cached_mesh, info):
				info["_from_disk_cache"] = true
				_assemble_queue.append({"info": info, "mesh": cached_mesh})
				return
		_queue_mesh_task(info)
		return

	if is_server:
		# Server: keep old immediate + rebuild behavior (no visual concern).
		if planet_data.is_chunk_cached(export_key):
			_create_chunk(info)
			return
		# Register waiter so _poll_pending_recipes can rebuild with real heights.
		if not _recipe_waiters.has(export_key):
			_recipe_waiters[export_key] = {}
		_recipe_waiters[export_key][info.key] = info
		# Create now with fallback heights (server needs collision ASAP).
		_create_chunk(info)
		_submit_recipe_if_needed(export_key, export_ipix, cam_dist_sq)
		return

	# ── Client: check disk cache first ──────────────────────────────
	if _chunk_cache and _chunk_cache.has_mesh(info.key, info.lod):
		var cached_mesh := _chunk_cache.load_mesh(info.key, info.lod)
		if cached_mesh and _cached_mesh_valid(cached_mesh, info):
			info["_from_disk_cache"] = true
			# Still trigger recipe generation for vegetation height sampling
			if not planet_data.is_chunk_cached(export_key):
				_submit_recipe_if_needed(export_key, export_ipix, cam_dist_sq)
			_assemble_queue.append({"info": info, "mesh": cached_mesh})
			return

	# ── Client: fully async ─────────────────────────────────────────
	if planet_data.is_chunk_cached(export_key):
		# Recipe ready — submit mesh generation to WorkerThreadPool.
		_queue_mesh_task(info)
		return

	# Recipe not yet cached — register as a waiter.
	if not _recipe_waiters.has(export_key):
		_recipe_waiters[export_key] = {}
	_recipe_waiters[export_key][info.key] = info
	_submit_recipe_if_needed(export_key, export_ipix, cam_dist_sq)


## Sanity-check cached chunk geometry against the live analytic surface.
## A chunk baked while the per-chunk .r32 elevation tiles were unreadable was
## built from the flat equirect fallback — its surface sits kilometres away
## from the real one (the tarsis_4 "3-6 km" bug). The cache version hash can't
## capture that failure, so validate at LOAD time: reconstruct one vertex's
## planet-local radial distance and compare it to the crack-aware surface in
## that direction. Tolerance is generous (cracks are ~200 m deep; the failure
## mode is 3000-6000 m), so legitimate geometry never trips it.
## [param first_vertex] is a vertex in chunk-local space, [param origin] the
## chunk origin in planet-local space (mesh: info.center / collision:
## _chunk_collision_origin).
## [param sample_nside] is the pyramid level this chunk baked its heights from
## (PlanetData.sample_nside_for(hp_nside)); the live surface is sampled at the
## same level so a coarse chunk isn't compared against the finest tile.
func _cached_geom_valid(first_vertex: Vector3, origin: Vector3, key: String,
		sample_nside: int = -1) -> bool:
	var p := origin + first_vertex
	var r := p.length()
	if r <= 0.0:
		return false
	var surf: float = planet_data.crack_aware_surface_dist(p / r, sample_nside)
	if absf(r - surf) <= _CACHE_GEOM_TOLERANCE_M:
		return true
	print("[PlanetTerrain] cache STALE for '%s': cached radial=%.0fm vs live surface=%.0fm — discarding, will regenerate" % [
		key, r, surf])
	return false


## Mesh variant of _cached_geom_valid: pulls the first vertex out of the mesh.
func _cached_mesh_valid(mesh: ArrayMesh, info: Dictionary) -> bool:
	if mesh.get_surface_count() == 0:
		return false
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return false
	return _cached_geom_valid(Vector3(verts[0]), info.center, info.key,
			planet_data.sample_nside_for(info.get("nside", 0)))


## Collision variant of _cached_geom_valid: pulls the first face vertex.
func _cached_shape_valid(shape: ConcavePolygonShape3D, nside: int, ipix: int, key: String) -> bool:
	var faces := shape.get_faces()
	if faces.is_empty():
		return false
	return _cached_geom_valid(Vector3(faces[0]), _chunk_collision_origin(nside, ipix), key,
			planet_data.sample_nside_for(nside))


## Submit a recipe task if one isn't already in-flight or deferred.
## [param min_dist_sq] is the squared distance from the camera to the nearest
## chunk that needs this recipe — used to prioritize the deferred queue so
## nearby terrain loads before distant chunks.
func _submit_recipe_if_needed(export_key: String, export_ipix: int,
		min_dist_sq: float = INF) -> void:
	if _pending_recipes.has(export_key):
		return  # already in-flight
	if _pending_recipes.size() < MAX_CONCURRENT_RECIPES:
		_submit_recipe_task(export_key, export_ipix)
	else:
		if _deferred_recipe_queue.has(export_key):
			# Update distance if this chunk is closer.
			var existing: Dictionary = _deferred_recipe_queue[export_key]
			existing["min_dist_sq"] = minf(existing.get("min_dist_sq", INF), min_dist_sq)
		else:
			_deferred_recipe_queue[export_key] = {
				"export_ipix": export_ipix,
				"min_dist_sq": min_dist_sq,
			}


## Submit a single recipe generation task to the WorkerThreadPool.
## Strategy: pre-load the recipe data (file I/O, ~2 ms) synchronously on
## the main thread, then submit ONLY the CPU-heavy
## [method ChunkRecipeGenerator.generate_heightmap] call to the thread pool.
## Because generate_heightmap is a static func it acquires no GDScript object
## lock, so all MAX_CONCURRENT_RECIPES tasks truly run in parallel.
## Without this split, calling pd._load_recipe_heightmap() from the lambda
## would acquire pd's GDScript instance lock and serialize every task.
func _submit_recipe_task(export_key: String, export_ipix: int) -> void:
	var pending_entry := {
		"task_id": -1,
		"result": null as Variant,
		"done": false,
		"export_key": export_key,
		"export_ipix": export_ipix,
	}
	_pending_recipes[export_key] = pending_entry

	# ── Fast sync part (main thread): load recipe dict + merge craters ──
	var preloaded := planet_data._load_recipe_data_sync(export_ipix, export_key)
	if preloaded.is_empty():
		pending_entry["result"] = [null, []]
		pending_entry["done"] = true
		pending_entry["task_id"] = 0
		return

	# Capture scalars so the lambda holds no reference to planet_data.
	var recipe_data: Dictionary = preloaded["recipe"]
	var fmt: String = preloaded["format"]
	var file_size: int = preloaded["size"]
	var resolution: int = planet_data._recipe_resolution
	var planet_radius: float = planet_data.radius
	var elev_min: float = planet_data.height_offset
	var elev_range: float = planet_data.max_height

	# ── Slow async part (worker thread): pure CPU — no object lock ──
	var task_id := WorkerThreadPool.add_task(
		func():
			var t0 := Time.get_ticks_usec()
			var gen_result := ChunkRecipeGenerator.generate_heightmap(
				recipe_data, resolution, planet_radius, elev_min, elev_range)
			var t_generate := Time.get_ticks_usec() - t0
			if t_generate > 500_000:
				print("[RecipeTiming] %s [%s]: generate=%.1fms  file_size=%d" % [
					export_key, fmt, t_generate / 1000.0, file_size])
			var populate_zones := ChunkRecipeGenerator.get_populate_zones(recipe_data)
			var linear_feats: Array = recipe_data.get("linear_features", [])
			var radial_feats: Array = recipe_data.get("radial_features", [])
			var result: Array
			if gen_result.size() >= 2:
				result = [gen_result[0], gen_result[1], populate_zones, linear_feats, radial_feats]
			else:
				result = [gen_result[0] if gen_result.size() > 0 else null, [], populate_zones, linear_feats, radial_feats]
			pending_entry["result"] = result
			pending_entry["done"] = true
	)
	pending_entry["task_id"] = task_id


## Poll all pending recipe tasks.  On completion: stores the Image via the
## thread-safe store_chunk_image() accessor, then promotes waiting chunks:
##   Client → queues mesh generation (WorkerThreadPool).
##   Server → synchronous remove+recreate with correct heights.
func _poll_pending_recipes() -> void:
	if _pending_recipes.is_empty() and _deferred_recipe_queue.is_empty():
		return

	var completed_keys: Array[String] = []
	for export_key: String in _pending_recipes:
		var entry: Dictionary = _pending_recipes[export_key]
		var task_id: int = entry.task_id
		if task_id < 0 or not entry.get("done", false):
			continue

		if WorkerThreadPool.is_task_completed(task_id):
			WorkerThreadPool.wait_for_task_completion(task_id)
		completed_keys.append(export_key)

		var result: Array = entry.get("result", [null, []]) as Array
		var img: Image = result[0] as Image if result.size() > 0 else null
		var craters: Array = result[1] if result.size() > 1 else []
		var populate_zones: Array = result[2] if result.size() > 2 else []
		var linear_feats: Array = result[3] if result.size() > 3 else []
		var radial_feats: Array = result[4] if result.size() > 4 else []

		if img != null:
			print("[PlanetTerrain] recipe '%s' ready (%dx%d)" % [
				export_key, img.get_width(), img.get_height()])
			planet_data.store_chunk_image(export_key, img, craters,
				populate_zones, linear_feats, radial_feats)
		else:
			push_warning("[PlanetTerrain] recipe '%s' returned null — chunks will retry" % export_key)

		# Promote waiting chunks now that their heightmap is available.
		if _recipe_waiters.has(export_key):
			for ck: String in _recipe_waiters[export_key]:
				var ci: Dictionary = _recipe_waiters[export_key][ck]
				if is_server:
					# Server: rebuild with real heights synchronously.
					if _active_chunks.has(ci.key):
						_remove_chunk(ci.key)
					if img != null:
						_create_chunk(ci)
				else:
					# Client: queue background mesh generation.
					if img != null:
						_queue_mesh_task(ci)
					# If img is null, ci is not in _active_chunks and will be
					# retried by _update_terrain on the next cycle.
			_recipe_waiters.erase(export_key)

	for k in completed_keys:
		_pending_recipes.erase(k)

	# Submit deferred recipes now that slots freed up — nearest first.
	if not _deferred_recipe_queue.is_empty():
		var _dk_sorted := _deferred_recipe_queue.keys()
		_dk_sorted.sort_custom(func(a: String, b: String) -> bool:
			return _deferred_recipe_queue[a].get("min_dist_sq", INF) < _deferred_recipe_queue[b].get("min_dist_sq", INF))
		var submitted: Array[String] = []
		for dk: String in _dk_sorted:
			if _pending_recipes.size() >= MAX_CONCURRENT_RECIPES:
				break
			var deferred: Dictionary = _deferred_recipe_queue[dk]
			if planet_data.is_chunk_cached(dk):
				# Recipe sneaked in via another path — promote waiters immediately.
				if _recipe_waiters.has(dk):
					for ck: String in _recipe_waiters[dk]:
						var ci: Dictionary = _recipe_waiters[dk][ck]
						if is_server:
							if _active_chunks.has(ci.key):
								_remove_chunk(ci.key)
							_create_chunk(ci)
						else:
							_queue_mesh_task(ci)
					_recipe_waiters.erase(dk)
				submitted.append(dk)
				continue
			_submit_recipe_task(dk, deferred.export_ipix)
			submitted.append(dk)
		for dk2 in submitted:
			_deferred_recipe_queue.erase(dk2)


# ------------------------------------------------------------------
# Async mesh generation (client only)
# ------------------------------------------------------------------

## Submit a mesh generation task to WorkerThreadPool for [param info].
## When the task completes, the resulting ArrayMesh is placed in
## _assemble_queue for assembly on the main thread.
func _queue_mesh_task(info: Dictionary) -> void:
	var key: String = info.key
	# Avoid duplicates.
	if _mesh_tasks.has(key):
		return
	for item in _assemble_queue:
		if item.info.key == key:
			return

	if _mesh_tasks.size() >= max_mesh_tasks:
		# Backlog — insert sorted so nearest chunks are processed first.
		for item in _mesh_task_backlog:
			if item.key == key:
				return
		_mesh_task_backlog.append(info)
		_mesh_task_backlog.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.center.distance_squared_to(_last_local_cam) < b.center.distance_squared_to(_last_local_cam))
		return

	var lod: int = info.lod
	var res := planet_data.get_resolution_for_lod(lod)
	var chunk_center: Vector3 = info.center
	var pd := planet_data
	var nside: int = info.nside
	var ipix: int = info.ipix

	# Pre-load road tile files on the main thread so that worker threads
	# do not trigger ResourceLoader.load() inside BiomeQuery
	# (which re-enters the WorkerThreadPool and causes heap corruption).
	if nside > 0:
		var _tile_bb := BiomeQuery._healpix_lonlat_bbox(nside, ipix)
		var _rq = pd.get_road_query()
		if _rq and _rq.is_loaded():
			_rq.preload_region(_tile_bb[0], _tile_bb[1])

	# result_ref[0] will be set to the ArrayMesh (or null on failure).
	var result_ref: Array = [null]
	var task_entry := {
		"task_id": -1,
		"result_ref": result_ref,
		"info": info,
	}
	_mesh_tasks[key] = task_entry

	var task_id := WorkerThreadPool.add_task(
		func():
			var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(
				pd, nside, ipix, res, chunk_center)
			result_ref[0] = mesh
	)
	task_entry["task_id"] = task_id


## Poll completed mesh tasks and move them to _assemble_queue.
func _poll_mesh_tasks() -> void:
	if _mesh_tasks.is_empty():
		# Drain backlog into mesh slots when available.
		while _mesh_task_backlog.size() > 0 and _mesh_tasks.size() < max_mesh_tasks:
			_queue_mesh_task(_mesh_task_backlog[0])
			_mesh_task_backlog.remove_at(0)
		return

	var completed_keys: Array[String] = []
	for key: String in _mesh_tasks:
		var entry: Dictionary = _mesh_tasks[key]
		var task_id: int = entry.task_id
		if task_id < 0:
			continue
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		completed_keys.append(key)
		var mesh: ArrayMesh = entry.result_ref[0] as ArrayMesh
		if mesh != null:
			_assemble_queue.append({"info": entry.info, "mesh": mesh})
		else:
			push_warning("[PlanetTerrain] mesh task for '%s' returned null" % key)

	for k in completed_keys:
		_mesh_tasks.erase(k)

	# Drain backlog into the freed slots.
	while _mesh_task_backlog.size() > 0 and _mesh_tasks.size() < max_mesh_tasks:
		_queue_mesh_task(_mesh_task_backlog[0])
		_mesh_task_backlog.remove_at(0)


## Assemble up to MAX_ASSEMBLE_PER_FRAME chunks from _assemble_queue per call.
## Assembly creates the MeshInstance3D, MultiMeshes, and point-biome nodes
## on the main thread — none of those can be created from worker threads.
## Nearest chunks are assembled first so the player sees terrain underfoot
## before distant LODs.
func _process_assemble_queue() -> void:
	# Sort nearest-first so close terrain appears before distant shells.
	if _assemble_queue.size() > 1:
		_assemble_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a.info.center.distance_squared_to(_last_local_cam) < b.info.center.distance_squared_to(_last_local_cam))
	var assembled := 0
	while assembled < MAX_ASSEMBLE_PER_FRAME and not _assemble_queue.is_empty():
		var item: Dictionary = _assemble_queue[0]
		_assemble_queue.remove_at(0)
		var info: Dictionary = item.info
		var mesh: ArrayMesh = item.mesh
		# Guard against stale entries (chunk was removed while mesh was computing).
		if _active_chunks.has(info.key):
			assembled += 1
			continue
		_assemble_visual_chunk(info, mesh)
		assembled += 1


## Look-ahead prefetch: estimate camera velocity from history and submit
## recipe + mesh tasks for chunks the camera is moving towards.
func _prefetch_look_ahead(local_cam: Vector3, horizon_dot: float) -> void:
	if _cam_history.size() < 2:
		return
	# Velocity = average of recent frame deltas (planet-local space).
	var vel := Vector3.ZERO
	for i in range(1, _cam_history.size()):
		vel += _cam_history[i] - _cam_history[i - 1]
	vel /= float(_cam_history.size() - 1)
	# Predict two seconds ahead (UPDATE_INTERVAL * frames / interval).
	const LOOKAHEAD_S := 2.0
	var predicted_cam := local_cam + vel * (LOOKAHEAD_S / UPDATE_INTERVAL)

	# Traverse from predicted position — only register chunks not already
	# active or in pipeline (don't duplicate work already queued).
	var prefetch_desired: Dictionary = {}
	for base_pix in BASE_PIXEL_COUNT:
		_traverse(1, base_pix, 0, predicted_cam, horizon_dot, prefetch_desired)

	for key in prefetch_desired:
		if _active_chunks.has(key) or _is_chunk_in_pipeline(key):
			continue
		var info: Dictionary = prefetch_desired[key]
		# File/pyramid mode has no recipe pipeline — chunks lazy-load their .r32
		# tiles on the worker thread. Warm the exact pyramid tile the mesh will
		# sample so that task doesn't stall on disk I/O, then skip the recipe path
		# (submitting recipes without a pack is what spams "Invalid Task ID").
		if planet_data.chunk_heightmaps_dir != "":
			var _ht := _chunk_height_tile(info)
			if _ht[0] >= 0:
				planet_data.load_chunk_heightmap(_ht[0], _ht[1])
			continue
		# Only prefetch recipes (light I/O), not mesh tasks (CPU-heavy) to
		# avoid starving the current-frame mesh pipeline.
		var epd_nside := planet_data.export_nside
		var export_ipix: int = info["ipix"]
		var cur_nside: int = info["nside"]
		while cur_nside > epd_nside:
			export_ipix = HEALPix.parent_pixel(export_ipix)
			cur_nside /= 2
		while cur_nside < epd_nside:
			export_ipix = export_ipix * 4
			cur_nside *= 2
		var export_key := "hp_n%d_p%d" % [epd_nside, export_ipix]
		if not planet_data.is_chunk_cached(export_key):
			if not _recipe_waiters.has(export_key):
				_recipe_waiters[export_key] = {}
			_recipe_waiters[export_key][key] = info
			_submit_recipe_if_needed(export_key, export_ipix)


# ------------------------------------------------------------------
# Chunk lifecycle
# ------------------------------------------------------------------

## Assemble a client-side visual chunk from a pre-computed [param mesh].
## Called on the main thread from _process_assemble_queue() after the mesh
## was generated on a WorkerThreadPool task.
## Handles MeshInstance3D creation, vegetation MultiMeshes, and point biomes.
func _assemble_visual_chunk(info: Dictionary, mesh: ArrayMesh) -> void:
	var _t0 := Time.get_ticks_usec()
	var key: String = info.key
	var lod: int = info.lod
	var chunk_center: Vector3 = info.center

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = key
	mi.position = chunk_center
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var _wrap := 8192.0
	mi.set_instance_shader_parameter("chunk_origin_mod", Vector3(
		fposmod(chunk_center.x, _wrap),
		fposmod(chunk_center.y, _wrap),
		fposmod(chunk_center.z, _wrap)))
	# Full planet-local chunk centre for the terrain shader's true-radial normal (far terminator fix).
	mi.set_instance_shader_parameter("chunk_center_local", chunk_center)
	# Star direction for the shader's celestial-layer star lighting (see _star_dir_world).
	mi.set_instance_shader_parameter("star_dir_world", _star_dir_world)
	# Born on the celestial layer when this planet is currently a distant body (star-lit), else local.
	mi.layers = Globals.RENDER_MASK_CELESTIAL if _chunks_on_celestial else Globals.RENDER_MASK_LOCAL
	_chunks_node.add_child(mi)
	info["mesh_instance"] = mi

	# ---------- Vegetation MultiMesh ----------
	var res := planet_data.get_resolution_for_lod(lod)
	if not planet_data.vegetation_rules.is_empty():
		var dominated_lods: Array[int] = []
		for rule: VegetationRule in planet_data.vegetation_rules:
			print("[VEG] rule '%s' spawn_lod_levels=%s (size=%d)" % [
				rule.rule_name, rule.spawn_lod_levels, rule.spawn_lod_levels.size()])
			for l in rule.spawn_lod_levels:
				if not dominated_lods.has(l):
					dominated_lods.append(l)
		if not (lod in dominated_lods):
			if _active_chunks.size() < 10:
				print("[VEG] chunk %s: LOD %d not in dominated_lods %s — skipping vegetation" % [key, lod, dominated_lods])
		var _pz_veg := _get_chunk_populate_zones(info)
		if lod in dominated_lods and not _pz_veg.is_empty():
			var mm := PlanetVegetation.scatter_chunk_hp(
				planet_data,
				planet_data.vegetation_rules,
				info.nside, info.ipix,
				chunk_center,
				_pz_veg
			)
			if mm:
				var mmi := MultiMeshInstance3D.new()
				mmi.multimesh = mm
				mmi.name = key + "_veg"
				mmi.position = chunk_center
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				_chunks_node.add_child(mmi)
				info["vegetation"] = mmi

				# --- DEBUG: vegetation diagnostics ---
				var mesh_ref: Mesh = mm.mesh
				var aabb := mesh_ref.get_aabb() if mesh_ref else AABB()
				var t0 := mm.get_instance_transform(0) if mm.instance_count > 0 else Transform3D()
				print("[VEG_DEBUG] key=%s lod=%d instances=%d" % [key, lod, mm.instance_count])
				print("[VEG_DEBUG]   mmi.position=%s  mmi.global_pos=%s" % [mmi.position, mmi.global_position])
				print("[VEG_DEBUG]   mesh_aabb=%s  surfaces=%d" % [aabb, mesh_ref.get_surface_count() if mesh_ref else 0])
				print("[VEG_DEBUG]   instance[0].origin=%s  basis_scale=%s" % [t0.origin, t0.basis.get_scale()])
				if mesh_ref and mesh_ref.get_surface_count() > 0:
					var arr := mesh_ref.surface_get_arrays(0)
					var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX] if arr[Mesh.ARRAY_VERTEX] else PackedVector3Array()
					var norms = arr[Mesh.ARRAY_NORMAL]
					print("[VEG_DEBUG]   surface[0]: %d verts, has_normals=%s" % [verts.size(), norms != null])
					if verts.size() > 0:
						print("[VEG_DEBUG]   vert[0]=%s vert[-1]=%s" % [verts[0], verts[verts.size()-1]])
					var mat := mesh_ref.surface_get_material(0)
					print("[VEG_DEBUG]   material[0]=%s" % [mat])
				# --- END DEBUG ---

	# ---------- Meadow grass scatter ----------
	if lod <= MeadowSteppeMeadowTerrain.GRASS_MAX_LOD:
		var _pz_grass := _get_chunk_populate_zones(info)
		var _has_meadow := _zones_have_biome(_pz_grass, MeadowSteppeMeadowTerrain.BIOME_TYPE)
		if _has_meadow:
			var grass_mm := MeadowSteppeMeadowSpawner.scatter_grass_hp(
				planet_data, null, info.nside, info.ipix,
				chunk_center, lod, _pz_grass)
			if grass_mm:
				var grass_mmi := MultiMeshInstance3D.new()
				grass_mmi.multimesh = grass_mm
				grass_mmi.name = key + "_grass"
				grass_mmi.position = chunk_center
				if lod == 0:
					grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				else:
					grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				var corners_grass: Array = HEALPix.get_pixel_corners(info.nside, info.ipix)
				var chunk_diag: float = (corners_grass[0] * planet_data.radius).distance_to(corners_grass[2] * planet_data.radius)
				grass_mmi.visibility_range_end = chunk_diag * 2.0
				grass_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				_chunks_node.add_child(grass_mmi)
				info["meadow"] = grass_mmi

	# ---------- Forest tree scatter ----------
	if lod <= ForestTemperateForestSpawner.get_max_lod():
		var _pz_forest := _get_chunk_populate_zones(info)
		var _has_forest := _zones_have_biome(_pz_forest, ForestTemperateForestTerrain.BIOME_TYPE)
		if _has_forest:
			var _lf_forest := planet_data.get_chunk_linear_features(
				_get_export_ipix(info))
			var tree_mm := ForestTemperateForestSpawner.scatter_trees_hp(
				planet_data, null, info.nside, info.ipix,
				chunk_center, lod, _pz_forest, _lf_forest)
			if tree_mm:
				var tree_mmi := MultiMeshInstance3D.new()
				tree_mmi.multimesh = tree_mm
				tree_mmi.name = key + "_forest_trees"
				tree_mmi.position = chunk_center
				tree_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				var corners_tree: Array = HEALPix.get_pixel_corners(info.nside, info.ipix)
				var chunk_diag: float = (corners_tree[0] * planet_data.radius).distance_to(corners_tree[2] * planet_data.radius)
				tree_mmi.visibility_range_end = chunk_diag * 3.0
				tree_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				_chunks_node.add_child(tree_mmi)
				info["forest"] = tree_mmi

	# ---------- Point-biome 3D instances at close LODs ----------
	if lod <= 2:
		var _pz_point := _get_chunk_populate_zones(info)
		var _spawned_from_pz := false
		if not _pz_point.is_empty():
			_spawned_from_pz = true
			for pz in _pz_point:
				var bt: String = pz.get("biome_type", "")
				var zbd := planet_data.get_biome_by_type(bt)
				if zbd == null:
					continue
				var is_cave := CaveTerrain.is_cave_biome(zbd)
				var is_fum  := VolcanicGeothermalFumaroleTerrain.is_fumarole_biome(zbd)
				var is_volc := VolcanicGeothermalActiveVolcanoTerrain.is_active_volcano_biome(zbd)
				if not is_cave and not is_fum and not is_volc:
					continue
				# Build a compatible zone dict for spawners.
				var zone: Dictionary = pz.duplicate()
				if not zone.has("biome_index") and zbd:
					zone["biome_index"] = zbd.biome_index
				# For point coverage, use lon/lat directly.
				if pz.get("coverage", "") == "point":
					if not zone.has("polygon") and zone.has("lon") and zone.has("lat"):
						zone["polygon"] = PackedVector2Array([Vector2(zone["lon"], zone["lat"])])
				if is_cave:
					var cave_node := CaveSpawner.spawn(planet_data, info, zone)
					if cave_node:
						_chunks_node.add_child(cave_node)
						info["cave"] = cave_node
				elif is_fum:
					var fum_node := VolcanicGeothermalFumaroleSpawner.spawn(planet_data, info, zone)
					if fum_node:
						_chunks_node.add_child(fum_node)
						info["fumarole"] = fum_node
				elif is_volc:
					var volc_node := VolcanicSpawner.spawn(planet_data, info, zone)
					if volc_node:
						_chunks_node.add_child(volc_node)
						info["volcanic"] = volc_node

	# Save terrain mesh to disk cache for future restarts — but ONLY if the
	# chunk's export elevation tile is actually available. If the .r32 tile was
	# missing/unreadable when the mesh was built, generate_mesh sampled the flat
	# equirect fallback, collapsing high plateaus toward sea level (the tarsis_4
	# "terrain 3-6 km below the props" bug). Persisting such a mesh makes the bad
	# bake "valid" forever, while the editor (fresh regen) and server collision
	# (already guarded in _create_chunk) stay correct. Skip the write so the
	# chunk regenerates once the tile is resident. Mirrors the server guard.
	if _chunk_cache and mesh and not info.get("_from_disk_cache", false):
		# Gate on the SAME pyramid tile the mesh sampled (coarse chunks read a
		# coarse tile, not the finest), so a good coarse bake isn't rejected.
		var _ht := _chunk_height_tile(info)
		if _ht[0] >= 0 and planet_data.load_chunk_heightmap(_ht[0], _ht[1]) != null:
			_chunk_cache.save_mesh(key, lod, mesh)

	_active_chunks[key] = info
	var _elapsed_ms := (Time.get_ticks_usec() - _t0) / 1000.0
	var _cache_tag := " [from cache]" if info.get("_from_disk_cache", false) else ""
	# print("[PlanetTerrain] _assemble_visual_chunk '%s' lod=%d res=%d took %.1f ms (active=%d)%s" % [
	# 	key, lod, res, _elapsed_ms, _active_chunks.size(), _cache_tag])


## Create a server-side collision chunk.  No visual mesh is generated.
## Still synchronous — servers don't have visual freeze concerns.
func _create_chunk(info: Dictionary) -> void:
	var _t0 := Time.get_ticks_usec()
	var key: String = info.key
	var lod: int = info.lod
	var res := planet_data.get_resolution_for_lod(lod)

	# ---------- Server: collision shape for LOD 0–1 ----------
	if is_server and lod <= 1:
		var shape: ConcavePolygonShape3D = null
		var _col_from_cache := false
		# Check disk cache first
		if _chunk_cache:
			shape = _chunk_cache.load_collision(key, lod)
			# Reject shapes baked from fallback heights (see _cached_geom_valid).
			if shape != null and not _cached_shape_valid(shape, info.nside, info.ipix, key):
				shape = null
			_col_from_cache = shape != null
		if shape == null:
			@warning_ignore("integer_division")
			var col_res := maxi(res / 2, 4)
			shape = PlanetChunk.generate_collision_shape_healpix(
				planet_data,
				info.nside, info.ipix,
				col_res
			)
		if shape:
			var body := _make_chunk_collision_body(key, info.nside, info.ipix, shape)
			add_child(body)
			info["collision_shape"] = body  # freed by _remove_chunk
			# Save to disk if generated with real recipe heights
			if not _col_from_cache and _chunk_cache:
				var _epd := planet_data.export_nside
				var _eip := info.ipix as int
				var _cns := info.nside as int
				while _cns > _epd:
					_eip = HEALPix.parent_pixel(_eip)
					_cns /= 2
				while _cns < _epd:
					_eip *= 4
					_cns *= 2
				if planet_data.is_chunk_cached("hp_n%d_p%d" % [_epd, _eip]):
					_chunk_cache.save_collision(key, lod, shape)

		# Server also needs cave/fumarole collision so players don't fall through.
		var _pz_srv := _get_chunk_populate_zones(info)
		var _srv_spawned_from_pz := false
		if not _pz_srv.is_empty():
			_srv_spawned_from_pz = true
			for pz_s in _pz_srv:
				var bt_s: String = pz_s.get("biome_type", "")
				var zbd_s := planet_data.get_biome_by_type(bt_s)
				if zbd_s == null:
					continue
				var is_cave_s := CaveTerrain.is_cave_biome(zbd_s)
				var is_fum_s  := VolcanicGeothermalFumaroleTerrain.is_fumarole_biome(zbd_s)
				var is_volc_s := VolcanicGeothermalActiveVolcanoTerrain.is_active_volcano_biome(zbd_s)
				if not is_cave_s and not is_fum_s and not is_volc_s:
					continue
				var zone_s: Dictionary = pz_s.duplicate()
				if not zone_s.has("biome_index") and zbd_s:
					zone_s["biome_index"] = zbd_s.biome_index
				if pz_s.get("coverage", "") == "point":
					if not zone_s.has("polygon") and zone_s.has("lon") and zone_s.has("lat"):
						zone_s["polygon"] = PackedVector2Array([Vector2(zone_s["lon"], zone_s["lat"])])
				if is_cave_s:
					var cave_node := CaveSpawner.spawn(planet_data, info, zone_s)
					if cave_node:
						_chunks_node.add_child(cave_node)
						info["cave"] = cave_node
				elif is_fum_s:
					var fum_node := VolcanicGeothermalFumaroleSpawner.spawn(planet_data, info, zone_s)
					if fum_node:
						_chunks_node.add_child(fum_node)
						info["fumarole"] = fum_node
				elif is_volc_s:
					var volc_node := VolcanicSpawner.spawn(planet_data, info, zone_s)
					if volc_node:
						_chunks_node.add_child(volc_node)
						info["volcanic"] = volc_node

	_active_chunks[key] = info
	var _elapsed_ms := (Time.get_ticks_usec() - _t0) / 1000.0
	print("[PlanetTerrain] _create_chunk (server) '%s' lod=%d res=%d took %.1f ms (total_active=%d)" % [
		key, lod, res, _elapsed_ms, _active_chunks.size()])


func _remove_chunk(key: String) -> void:
	if not _active_chunks.has(key):
		return
	var info: Dictionary = _active_chunks[key]
	if info.has("mesh_instance") and info.mesh_instance:
		info.mesh_instance.queue_free()
	if info.has("vegetation") and info.vegetation:
		info.vegetation.queue_free()
	if info.has("cave") and info.cave:
		info.cave.queue_free()
	if info.has("fumarole") and info.fumarole:
		info.fumarole.queue_free()
	if info.has("volcanic") and info.volcanic:
		info.volcanic.queue_free()
	if info.has("meadow") and info.meadow:
		info.meadow.queue_free()
	if info.has("forest") and info.forest:
		info.forest.queue_free()
	if info.has("collision_shape") and info.collision_shape:
		info.collision_shape.queue_free()
	_active_chunks.erase(key)


func _clear_all_chunks() -> void:
	for key in _active_chunks.keys():
		_remove_chunk(key)


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

func _chunk_key_hp(nside: int, ipix: int) -> String:
	return "hp_n%d_p%d" % [nside, ipix]


## Resolve the export-level ipix for a given chunk nside/ipix and return
## the populate zones cached from the recipe (v7+).
## Returns an empty Array if zones are not available (pre-v7 recipes or
## recipe not yet loaded).
func _get_chunk_populate_zones(info: Dictionary) -> Array:
	var nside: int = info.get("nside", 0)
	var ipix: int = info.get("ipix", -1)
	if nside <= 0 or ipix < 0:
		return []
	var export_ipix := ipix
	var cur_nside := nside
	while cur_nside > planet_data.export_nside:
		export_ipix = HEALPix.parent_pixel(export_ipix)
		cur_nside /= 2
	return planet_data.get_chunk_populate_zones(export_ipix)


## Map a chunk's runtime ipix to the export-level ipix by walking up the
## HEALPix quadtree until nside matches planet_data.export_nside.
func _get_export_ipix(info: Dictionary) -> int:
	var eipix: int = info.get("ipix", -1)
	var ns: int = info.get("nside", 0)
	while ns > planet_data.export_nside:
		eipix = HEALPix.parent_pixel(eipix)
		ns /= 2
	return eipix


## Pyramid tile [ipix, nside] a chunk actually samples its heights from — mirrors
## the logic in PlanetChunk (finer→walk up to nside_max; own level if baked).
## Returns ipix == -1 when the chunk is coarser than the coarsest baked level
## (per-vertex resolution, no single tile to gate a cache write on).
func _chunk_height_tile(info: Dictionary) -> Array:
	var hp_nside: int = info.get("nside", 0)
	var hp_ipix: int = info.get("ipix", -1)
	var ns: int = planet_data.sample_nside_for(hp_nside)
	if hp_nside >= planet_data.export_nside:
		var eipix := hp_ipix
		var cur := hp_nside
		while cur > planet_data.export_nside:
			eipix = HEALPix.parent_pixel(eipix)
			cur /= 2
		return [eipix, planet_data.export_nside]
	return [hp_ipix, ns]


## Check if populate zones contain a specific biome type.
static func _zones_have_biome(zones: Array, biome_type: String) -> bool:
	for z in zones:
		if z.get("biome_type", "") == biome_type:
			return true
	return false


## Get zones matching a specific biome type from populate zones.
static func _zones_for_biome(zones: Array, biome_type: String) -> Array:
	var result: Array = []
	for z in zones:
		if z.get("biome_type", "") == biome_type:
			result.append(z)
	return result


## Compute the centroid of a biome zone polygon (in lon/lat degrees) and
## return it as a unit sphere direction vector.
static func _zone_centroid_dir(zone: Dictionary) -> Vector3:
	var poly: PackedVector2Array = zone.get("polygon", PackedVector2Array())
	var centroid := Vector2.ZERO
	if poly.size() > 0:
		for pt in poly:
			centroid += pt
		centroid /= float(poly.size())
	else:
		# Fallback: use bbox center.
		centroid = (zone.bbox_min + zone.bbox_max) * 0.5
	var lon_rad := deg_to_rad(centroid.x)
	var lat_rad := deg_to_rad(centroid.y)
	return Vector3(
		cos(lat_rad) * cos(lon_rad),
		sin(lat_rad),
		cos(lat_rad) * sin(lon_rad)
	).normalized()


## Returns the world position used as the LOD reference point.
##   Client → active camera.
##   Server → closest connected player.
func _get_reference_position() -> Vector3:
	if is_server:
		var closest_dist := INF
		var closest_pos := Vector3.INF
		if NetworkOrchestrator and NetworkOrchestrator.players:
			for player in NetworkOrchestrator.players.values():
				if player and player is Node3D:
					var d := global_position.distance_to(player.global_position)
					if d < closest_dist:
						closest_dist = d
						closest_pos = player.global_position
		return closest_pos
	var vp := get_viewport()
	if vp:
		var cam := vp.get_camera_3d()
		if cam:
			return cam.global_position
		if _active_chunks.is_empty():
			print("[PlanetTerrain] _get_reference_position: viewport exists but NO active camera")
	else:
		if _active_chunks.is_empty():
				print("[PlanetTerrain] _get_reference_position: NO viewport")
	return Vector3.INF
