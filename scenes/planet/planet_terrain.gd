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

var _chunks_node: Node3D
var _collision_body: StaticBody3D
var _chunk_cache: ChunkDiskCache

# chunk_key → { key, nside, ipix, depth, center, lod,
#               mesh_instance?, collision_shape? }
var _active_chunks: Dictionary = {}
var _update_timer: float = 0.0
var _initialized: bool = false

## Server fixed-collision mode: all export-nside chunks loaded at startup.
## Maps chunk_key → CollisionShape3D for rebuild support.
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

	# Initialize chunk disk cache (skipped in editor mode)
	if not Engine.is_editor_hint():
		# v13: collision col_res raised to _recipe_resolution to match the
		# heightmap that sample_height_for_direction returns; older caches
		# (v12 and earlier) stored coarse 16x16 grids that were tens to
		# hundreds of metres off from the visual mesh.
		var _cache_version := "%s_%d_%.0f_%.0f_%.1f_v13" % [
			data.planet_name, data.export_nside, data.radius,
			data.max_height, data.height_offset]
		# Server collision shapes live in a dedicated folder so they don't
		# mix with client visual-mesh cache entries.
		var _cache_base := ChunkDiskCache.SERVER_COLLISION_BASE_DIR \
				if server_mode else ChunkDiskCache.BASE_DIR
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
		_generate_editor_preview()
		return

	# Server collision body with a base sphere for rough physics
	if is_server:
		planet_data.set_server_mode(true)
		_collision_body = StaticBody3D.new()
		_collision_body.name = "PlanetCollision"
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
	var col_res := maxi(planet_data._recipe_resolution, planet_data.chunk_resolution)

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
		var col: CollisionShape3D = _server_collision_chunks[key]
		col.queue_free()
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

	# Fast-path: both image and shape already available — assemble now.
	if planet_data.is_chunk_cached(key):
		if cached_shape != null:
			_server_assemble_chunk(key, planet_data.export_nside, ipix, cached_shape)
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
	var nside := planet_data.export_nside
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
		var nside := planet_data.export_nside

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


## Attach [param shape] to the collision body and spawn chunk features.
## Must be called on the main thread only.  No-op if already assembled.
func _server_assemble_chunk(key: String, nside: int, ipix: int,
		shape: ConcavePolygonShape3D) -> void:
	if _server_collision_chunks.has(key):
		return  # Race guard: assembled by another path.
	var col := CollisionShape3D.new()
	col.shape = shape
	col.name = key + "_col"
	_collision_body.add_child(col)
	_server_collision_chunks[key] = col
	var faces: PackedVector3Array = shape.get_faces()
	if faces.size() > 0:
		var dmin: float = INF
		var dmax: float = -INF
		for v in faces:
			var d := v.length()
			if d < dmin: dmin = d
			if d > dmax: dmax = d
		@warning_ignore("integer_division")
		var tri_count: int = faces.size() / 3
		print("[PlanetTerrain] loaded chunk ", key, " tris=", tri_count,
			" alt_min=", dmin - planet_data.radius, " alt_max=", dmax - planet_data.radius,
			" body_global=", _collision_body.global_position,
			" body_layer=", _collision_body.collision_layer,
			" body_mask=", _collision_body.collision_mask)
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

	var col_res := maxi(planet_data._recipe_resolution, planet_data.chunk_resolution)
	var nside: int = planet_data.export_nside

	for key in chunk_keys:
		# Parse ipix from key "hp_nN_pP".
		var parts := (key as String).split("_")
		if parts.size() < 3:
			push_warning("[PlanetTerrain] rebuild_chunks: invalid key '%s'" % key)
			continue
		var ipix := int(parts[2].substr(1))

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

		# Remove old collision shape.
		if _server_collision_chunks.has(key):
			var old_col: CollisionShape3D = _server_collision_chunks[key]
			old_col.queue_free()
			_server_collision_chunks.erase(key)

		# Regenerate collision shape.
		var shape := PlanetChunk.generate_collision_shape_healpix(
			planet_data, nside, ipix, col_res)
		if shape:
			var col := CollisionShape3D.new()
			col.shape = shape
			col.name = key + "_col"
			_collision_body.add_child(col)
			_server_collision_chunks[key] = col
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

	# Skip terrain entirely when the camera is deep inside the planet body.
	# This avoids rendering useless LOD4 shells for a gas-giant parent while
	# the player stands on a moon far inside that giant's radius.
	if cam_dist < planet_data.radius * 0.9:
		_clear_all_chunks()
		# Hide the far-LOD sphere too — otherwise an unmaterialised white
		# sphere of a parent body (e.g. a gas giant the player is inside)
		# engulfs the view and looks like a giant flat surface.
		var inside_planet_body: Planet = get_parent() as Planet
		if inside_planet_body and inside_planet_body.far_lod_sphere:
			inside_planet_body.far_lod_sphere.visible = false
		return

	# Clamp: treat "under surface" as "on surface" to avoid degenerate
	# quadtree subdivision when the player spawns slightly below ground.
	var surface_distance := maxf(cam_dist - planet_data.radius, 0.0)
	var planet_lod := planet_data.get_lod_level(surface_distance)

	# Update camera history ring-buffer for look-ahead prefetch.
	_cam_history.append(local_cam)
	if _cam_history.size() > CAM_HISTORY_SIZE:
		_cam_history.remove_at(0)

	# One-shot debug on first valid update
	# if _active_chunks.is_empty():
	# 	print("[PlanetTerrain] first update: cam=%s  surface_dist=%.0f  lod=%d  chunk_count=%d" % [
	# 		camera_pos, surface_distance, planet_lod, _active_chunks.size()])

	# Toggle far-LOD sphere visibility
	var planet_body: Planet = get_parent() as Planet
	if planet_body and planet_body.far_lod_sphere:
		# Show the simple sphere only at LOD 4+ where no terrain chunks exist.
		# At LOD 3 the 64 coarse chunks already cover the sphere and the far
		# sphere (at exact radius) would occlude terrain that sits below radius
		# due to a negative height_offset.
		planet_body.far_lod_sphere.visible = (planet_lod >= 4) and not is_server

	# At LOD 4 there is no terrain — just the far sphere
	if planet_lod >= 4:
		_clear_all_chunks()
		return

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
			if not _has_pending_replacement(key) and not _has_pending_coarser(key):
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
## Spawns the centre HEALPix pixel + up to 8 neighbours at the configured
## [member editor_preview_depth].
## When [member editor_preview_vegetation] is enabled, tree and grass
## MultiMeshes are also generated on those chunks.
## Called only in the Godot editor (@tool mode).
## [param center_local]: if not [constant Vector3.INF], use this planet-local
## position as the preview centre instead of the editor camera.
func _generate_editor_preview(center_local: Vector3 = Vector3.INF) -> void:
	# Synchronously remove previous preview meshes.
	for child in _chunks_node.get_children():
		_chunks_node.remove_child(child)
		child.free()
	_active_chunks.clear()

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

	# ── Build pixel set: centre + 8 neighbours ────────────────────
	var pixels := [center_ipix]
	var neighbors := HEALPix.get_neighbors_nest(nside, center_ipix)
	for dir_name in neighbors:
		var nb: int = neighbors[dir_name]
		if nb >= 0 and not pixels.has(nb):
			pixels.append(nb)

	for ipix in pixels:
		var chunk_center := PlanetChunk.snap_to_f32(
			HEALPix.pix2vec_nest(nside, ipix) * planet_data.radius)
		var key := "editor_hp_n%d_p%d" % [nside, ipix]

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
		_chunks_node.add_child(mi)
		var info: Dictionary = {"key": key, "mesh_instance": mi}

		# ── Vegetation (trees + grass) ────────────────────────
		if editor_preview_vegetation:
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

	print("[PlanetTerrain] Editor preview: HEALPix nside=%d center_ipix=%d chunks=%d veg=%s" % [
		nside, center_ipix, _active_chunks.size(), editor_preview_vegetation])


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
	var biome_local: Vector3 = entry.dir * planet_data.radius
	var world_pos: Vector3 = entry.world_pos

	# Create or move the focus marker so the user can press F to frame it.
	if not _editor_biome_focus or not is_instance_valid(_editor_biome_focus):
		_editor_biome_focus = Node3D.new()
		_editor_biome_focus.name = "BiomeFocus"
		add_child(_editor_biome_focus)
		# Ensure the marker is not saved with the scene.
		_editor_biome_focus.owner = null
	_editor_biome_focus.position = world_pos

	# Generate preview centred on this biome (not on the camera).
	_generate_editor_preview(biome_local)

	# Prevent camera tracking from overwriting the preview for 3 seconds,
	# giving the user time to press F to fly to it.
	_editor_goto_cooldown = 3.0
	_editor_last_cam_local = biome_local

	# Select the marker so the user can press F to frame it.
	var ei = Engine.get_singleton("EditorInterface")
	if ei:
		ei.get_selection().clear()
		ei.get_selection().add_node(_editor_biome_focus)

	print("[PlanetTerrain] Go to biome: %s — world=(%d, %d, %d) — press F to frame" % [
		entry.label, int(world_pos.x), int(world_pos.y), int(world_pos.z)])


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

	var dist := local_cam.distance_to(center_pos)

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
		if cached_mesh:
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

	# Save terrain mesh to disk cache for future restarts
	if _chunk_cache and mesh and not info.get("_from_disk_cache", false):
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
			var col := CollisionShape3D.new()
			col.shape = shape
			col.name = key + "_col"
			_collision_body.add_child(col)
			info["collision_shape"] = col
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
