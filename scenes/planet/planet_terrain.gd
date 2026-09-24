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
## _prefetch_look_ahead re-traverses only once its prediction has moved this far.
const PREFETCH_MIN_MOVE_M := 200.0
var _last_prefetch_cam := Vector3.INF
## Factor: subdivide when camera distance < chunk_diagonal * SUBDIVIDE_FACTOR.
const SUBDIVIDE_FACTOR := 1.5
## Back-face culling dot threshold (client only, skip chunks behind planet).
const BACKFACE_DOT := -0.3
## Extra angular margin (radians) added to the geometric horizon angle so
## chunks poking above the horizon (mountains, trees) aren't culled too early.
## ~0.02 rad ≈ 1.1° — covers ≈40 km at the planet surface.
const HORIZON_MARGIN_RAD := 0.02
## Seconds between editor camera tracking updates.
## Maximum concurrent recipe worker tasks (avoid flooding the thread pool).
const MAX_CONCURRENT_RECIPES := 8
## Maximum chunks assembled (MeshInstance3D + vegetation) per physics frame.
## 4 matches the number of HEALPix children so a full split assembles in one frame.
const MAX_ASSEMBLE_PER_FRAME := 8
## Wall-clock budget of one assembly batch. A count alone let a warm-cache
## world entry sit at 5-20 fps for 25 s: eight chunks a frame at 5-20 ms each
## (`terrain_assemble=35-170ms` on every hitch line of the 2026-09-16 log), a
## rail chunk costing 400 ms on its own. The batch now stops once it has spent
## this long, and always assembles at least one chunk so the queue drains.
const ASSEMBLE_BUDGET_MS := 6.0
## Maximum concurrent server collision-chunk loading tasks (heightmap or shape phase).
const MAX_SERVER_CHUNK_TASKS := 4
## Ring-buffer size for camera history (look-ahead prefetch).
const CAM_HISTORY_SIZE := 10

## Tolerance (m) for validating cached chunk geometry against the live surface
## (see _cached_geom_valid). Generous: cracks are ~200 m deep, the failure mode
## is 3000-6000 m off.
const _CACHE_GEOM_TOLERANCE_M := 1500.0

## Couches et masques, lus sur le SCRIPT et non sur le nœud autoload.
##
## L'autoload Globals n'est pas @tool : dans l'éditeur ses membres — constantes comprises —
## ne sont pas accessibles depuis le nœud, et chaque chunk assemblé y lèverait. Passer par
## le script résout les constantes à la compilation, dans l'éditeur comme en jeu, sans
## dupliquer les valeurs.
const GlobalsDefs := preload("res://scenes/globals/globals.gd")

## ── Editor ────────────────────────────────────────────────────────
## L'éditeur affiche EXACTEMENT les mêmes chunks que le jeu : même quadtree, mêmes LOD,
## même pipeline asynchrone, même streaming de tuiles — simplement autour de la caméra
## d'édition au lieu du joueur. Il n'y a donc plus de réglages de chunks propres à
## l'éditeur : une profondeur et un nombre d'anneaux fixés à la main ne montraient pas ce
## que le joueur verrait, et leur génération synchrone sur le fil de l'éditeur gelait
## celui-ci dès que les tuiles devaient être téléchargées.

## Maximum concurrent mesh-generation worker tasks.
## Set to 4 so all 4 HEALPix children of a split pixel compute in parallel.
@export_range(1, 8) var max_mesh_tasks: int = 4

## ── Editor navigation ─────────────────────────────────────────────
## Longitude (degrees) used by the "Go to lon/lat" button below.
@export var editor_goto_lon: float = 0.0
## Latitude (degrees) used by the "Go to lon/lat" button below.
@export var editor_goto_lat: float = 0.0
## Inspector button: put the viewport 200 m above the lon/lat above, upright,
## and update the x/y/z fields to match. Nothing else to press.
@export_tool_button("Go to lon/lat") var _goto_lonlat_action = _goto_lonlat
## Planet-local X/Y/Z used by the "Go to coordinates" button below. Any point
## in space is projected onto the surface along its direction from the centre.
@export var editor_goto_x: float = 0.0
@export var editor_goto_y: float = 0.0
@export var editor_goto_z: float = 0.0
## Inspector button: put the viewport 200 m above the x/y/z above, upright,
## and update the lon/lat fields to match.
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

## ── POI import (QGIS) ─────────────────────────────────────────────
## JSON produced by tools/planettech/qgis/export_poi.py. Empty → derived from the planet
## name: res://assets/qgis/export/<planet_name>_poi.json
@export_file("*.json") var poi_json_path: String = ""
## Collision layer/mask applied to the generated POI Area3Ds. 0/0 by default:
## the POIs are inert zone markers until gameplay code wires them up, so they
## can't perturb the player controller or the interaction rays.
@export_flags_3d_physics var poi_collision_layer: int = 0
@export_flags_3d_physics var poi_collision_mask: int = 0
# Resolved through a getter, not an initializer, so the editor can never read
# the button callback back as Nil ("value is Nil, but Callable was expected").
@export_tool_button("Import POI from JSON")
var _import_poi_action: Callable:
	get: return import_poi_from_json

var planet_data: PlanetData
var is_server: bool = false

## Cached editor camera position (planet-local) to detect movement.
## Grace period (seconds) after a "Go to biome" to prevent camera tracking
## from immediately overwriting the biome-centred preview.

## ── Editor biome navigator ────────────────────────────────────────
## Populated from BiomeQuery on initialize; drives the dynamic dropdown.
var _editor_biome_entries: Array[Dictionary] = []
## Currently selected biome index in the dropdown (-1 = none).
var _editor_selected_biome_idx: int = -1
## Marker node dropped at the last "Go to" point (not saved, not selected).
var _editor_biome_focus: Node3D = null

## Camera altitude above the ACTUAL (crack-aware) terrain surface, sampled
## once per LOD update in _update_terrain and reused by every _traverse call.
## Metrics measured against sea level are wrong on high terrain: tarsis_3's
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

## Bridges, keyed by SPAN — not by chunk. A deck must outlive the chunk that
## happened to trigger it: ownership used to be the quadtree LEAF, which is
## distance-driven, so the same span was owned by a coarse parent and its finer
## child at the same time (two exactly coincident StaticBody3Ds under the
## wheels) and was freed then rebuilt at every LOD flip (a hole in the deck a
## vehicle drives into). Keyed at export_nside instead, a bridge is built once
## and freed only when the LAST chunk that references it goes away.
var _bridge_nodes: Dictionary = {}        # span_key → Node3D
var _bridge_owners: Dictionary = {}       # span_key → { chunk_key: true }
var _bridge_orphan_since: Dictionary = {} # span_key → msec it lost its last owner

## Prochain rattrapage des travées affamées, en ms depuis le boot. Voir
## [method _poll_starved_bridge_plans].
var _next_bridge_retry_ms: int = 0
## Intervalle entre deux tentatives de rattrapage. Assez court pour que le pont existe bien
## avant qu'un joueur n'atteigne le gouffre, assez long pour ne rien peser.
const BRIDGE_RETRY_INTERVAL_MS := 2000
## Same catch-up for the profiled lines (railways, graded roads), whose tiles
## are far more numerous than a bridge's: see [method _poll_starved_grade_profiles].
var _next_grade_retry_ms: int = 0
## Same catch-up for the terrain pads waiting on an elevation tile.
var _next_pad_retry_ms: int = 0
## Bumped every time a profile is born late. A mesh task stamped with an
## older generation was built without that profile: its result is dropped if
## the chunk stands on the line, so the chunk is queued again with the bed.
var _grade_generation: int = 0
## Export tiles (and neighbours) of every line whose profile was born late.
var _grade_reborn_tiles: Dictionary = {}
## Finest-level pixels reached by a terrain pad that appeared, moved or went
## since. A mesh task stamped with an older _pad_generation was built without
## that pad, and its result is dropped rather than drawn as the slope the pad
## replaced.
var _pad_dirty_pixels: Dictionary = {}
## Its own counter, NOT _grade_generation: every building entering GORC range
## registers a pad, and a shared counter made each of those registrations drop
## every mesh in flight along the whole railway (hundreds of tiles) as well.
var _pad_generation: int = 0

## Grace period before an unreferenced bridge is actually freed.
##
## A chunk whose LOD merely changed is REMOVED and re-queued under the SAME key
## (_update_terrain step 3), and the rebuild is asynchronous. Freeing on the
## last release would therefore still take the deck's collision away for as long
## as the rebuild takes — on the server, a hole in the bridge. Waiting a few
## seconds costs one idle mesh and makes that impossible.
const BRIDGE_GRACE_MS := 5000
## Client: a deck is 35-80 ms of geometry (ClientPerf asm:bridge_spawn,
## 2026-09-24), and a chunk streaming wave asks for up to twenty at once —
## 700 ms frames when built in line, still 6 fps when built one per frame.
## Decks further than this from the camera go to _bridge_spawn_queue and their
## geometry is built on a worker (BridgeSpawner.build_geo), nearest first, at
## most BRIDGE_MAX_TASKS at a time; closer ones are built at once, so a
## vehicle never reaches a gorge before its deck.
const BRIDGE_SPAWN_NOW_M := 400.0
const BRIDGE_MAX_TASKS := 2
## span key → span, waiting for a worker (client only).
var _bridge_spawn_queue: Dictionary = {}
## span key → {task_id, prep, result: [geo]}, geometry being built.
var _bridge_tasks: Dictionary = {}
## Last rendered frame the client pipeline ran in, and the wall-clock stamp of
## the last LOD update (see _physics_process).
var _last_poll_frame: int = -1
var _last_update_msec: int = 0
## _balance_and_stitch memo: the last traversal's leaves (key → lod) and what
## the pass answered for it (leaves it split in, masks it set).
var _bal_prev_trav: Dictionary = {}
var _bal_prev_out: Dictionary = {}
var _bal_prev_removed: Array[String] = []
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

## POIs resolved from the "POIs" child, built on first use (see poi_spheres). Only a re-import
## changes them, and that needs an editor restart, so it is never invalidated at runtime.
var _poi_cache: Array = []

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
		# corundum_default_rock is baked colour: a planet switched from the
		# milky rock to a red one must not serve milky meshes.
		# The POI spheres the crack network keeps whole: given to the sampler
		# here, before the key (they are baked geometry), before the bridge
		# spans walk the chasms and before any chunk carves.
		data.set_crack_exclusions(crack_exclusion_pois())
		var _cor := "_cor%d_%.0f_%.0f_%.0f_dbg%d_%s_poi%s" % [
			int(data.corundum_default_biome), data.crack_spacing_m,
			data.crack_width_m, data.crack_depth_m,
			int(data.debug_color_skirts), data.corundum_default_rock,
			data.crack_exclusion_fingerprint()] \
			if data.corundum_default_biome else ""
		# tile_res belongs in the key: it sets the pyramid's sample spacing, so a
		# mesh or shape cached at another tile_res describes a DIFFERENT surface.
		# data.chunk_data_version is the exporter's own fingerprint of the baked
		# elevations (manifest "data_version"). It closes the hole that forced the
		# v26 bump below: moving the QGIS exporter to spherical-TIN sampling changed
		# every elevation while radius / max_height / height_offset / tile_res all
		# stayed identical, so the old key kept reporting "Cache valid" and served
		# pre-change terrain. Any re-export now changes this suffix by itself.
		# Empty for manifests baked before the field existed → the key is byte-for-
		# byte the one those planets already cached under, so they are not re-baked.
		var _dv := "_dv%s" % data.chunk_data_version if data.chunk_data_version != "" else ""
		# The vNN literal now only covers RUNTIME-side changes that no field
		# captures (mesh/skirt/crack logic below) — exporter changes no longer need
		# a manual bump, _dv handles them.
		# Bridges change the ribbon itself: it is CUT where a deck and its ramps
		# stand, so a ramp slope is baked geometry and a designer tweaking one
		# must invalidate the meshes. Materials are deliberately NOT in that
		# signature — they change how a bridge looks, not where the road stops.
		var _brg := ""
		if data.corundum_default_biome:
			_brg = "_brg%s" % data.get_bridge_profile().signature()
		# A profiled line (railway, graded road) is baked geometry too: the bed
		# sits on its own profile, the cuttings displace the grid and the fine
		# collision carries both. Every constant those depend on is folded into
		# the key by GradeSettings; a road's own max slope comes from the pack.
		var _rw := ""
		if data.has_profiled_lines():
			_rw = "_rw%s" % GradeSettings.signature()
		# Biome regions bake the vertex colours (rock tints) and the surface
		# split (outcrop material): the populate part's fingerprint, written by
		# export_biomes.py and echoed into the pack manifest, re-keys the cache
		# on every re-export of the regions.
		var _pz := ""
		var _pz_fp := data.populate_fingerprint()
		if _pz_fp != "":
			_pz = "_pz%s" % _pz_fp.substr(0, 12)
		# Procedural mountains (MountainRelief) displace the ground inside the
		# sampler: the mountain + ridge parts' fingerprint re-keys every chunk
		# on a re-export of the features; the debug injection keys on its own
		# fields. No part and no debug → empty, byte-identical key.
		var _mt := ""
		var _mt_fp := data.mountain_fingerprint()
		if _mt_fp != "":
			_mt = "_mt%s" % _mt_fp
		elif data.debug_mountain_enabled:
			_mt = "_mtdbg%08x" % (hash(str([data.debug_mountain_lonlat,
					data.debug_mountain_radius_km, data.debug_mountain_style,
					data.debug_ridge_points, data.debug_ridge_style])) & 0xFFFFFFFF)
		# v26 → v27: the road ribbon's perpendicular is now taken in metric
		# space. That widens every road that is not east-west, on EVERY planet
		# with roads, so it is a runtime change no data field captures.
		# v27 → v28: biome zones with a terrain_material_override are emitted as
		# their own mesh surface (outcrop rock), and rock_type zones bake the
		# rock tint — a runtime change no data field captures.
		# v28 → v29: biomes with relief_* displace the ground (BiomeRelief),
		# flattened under roads; mesh and collision shapes alike.
		# v29 → v30: the flat band under roads scales with the vertex pitch
		# (the interpolated surface pierced ribbons and beds).
		# v30 → v31: coarse LODs shave the terrain to the bed top around a
		# profiled line (GradeBed.make_coarse_ctx) instead of leaving it uncut.
		# v31 → v32: the cutting's refinement patch is built on surface-override
		# cells too (it skipped them as "overlay" — buried roads on outcrops).
		# v32 → v33: corundum is a DEFAULT biome, not an override: a zone naming
		# a known biome keeps its own colour / detail and is left uncarved, in
		# the mesh and in the collision — meshes baked with cracks and iron
		# tint under every zone are stale.
		# v33 → v34: a highway is lanes × 3.5 m + a 0.5 m median (two
		# carriageways, structure strip on a bed), every road is an 8 cm slab
		# with its own collision (RoadRibbon, in the chunk's shape too), and a
		# corundum highway bakes the ground tint into its vertex colour.
		# v34 → v35: the corundum highway surface also covers outcrop zones of
		# a corundum rock (corundum_white, emery — tarsis_3's), tinted like
		# that ground; v34 baked them as asphalt.
		# v35 → v36: the gaufrage tile faces each carriageway's own traffic
		# (rotated 180° on the +along side); v35 had the logo upside down there.
		# v36 → v37: the marking's left/right was mirrored — the planet frame
		# (east, north, up) is left-handed, +perp is the +along driver's RIGHT.
		# v37 → v38: the corundum highway's tint is resolved per VERTEX from
		# the chunk's zones (a coarse piece's midpoint missed the outcrop it
		# crossed: far road milky, near deck emery).
		# v38 → v39: road_corundum_melted.tres is less glossy (0.45, no
		# clearcoat) — the road materials are DUPLICATED INTO the cached mesh,
		# so a material tweak needs a bump too.
		# v39 → v40: road tops (ribbon, bed, median, skirts) are wound
		# FRONT-facing (RoadRibbon.quad_indices) — they were back faces, lit
		# with a flipped normal by the cull-disabled road materials: black.
		# v40 → v41: the corundum road's flanks / skirts get the plain melted
		# corundum (no engraving), the top 0.3 roughness + clearcoat again.
		# v41 → v42: (a) LOD-seam stitch — a chunk's edges facing a one-level-
		# coarser neighbour are baked on the parent grid (PlanetChunk
		# STITCH_*), one cached file per mask; (b) the tile sampler lost its
		# 4-texel edge blend and reads corner texels from the diagonal tile
		# (PlanetData._sample_image_bilinear_healpix): every vertex within
		# 800 m of a tile edge moves, cliffs at tile corners by hundreds of
		# metres. Collision shapes share this version and re-bake too.
		# v42 → v43: GradeRefine also refines every cell the bed's floor
		# reaches into (not only cells with a carved corner) and re-samples
		# the chunk-border edge when both chunks refine that cell — the
		# coarse triangles no longer run above the rails on ground runs.
		# v43 → v44: the stitch waits for the parent tiles and refuses an
		# edge over a cliff (STITCH_MAX_SLOPE); v43 caches hold stitched
		# borders built on floor-level ancestors, hundreds of metres off.
		# v44 → v45: meshes carry the "road_surfaces" meta the assembler
		# splits the road slabs off with (_split_road_surfaces); a v44 mesh
		# without it would keep its roads drawn under a finer chunk.
		# v45 → v46: a pruned tile now waits for its finest PUBLISHED
		# ancestor (TileResidency.tile_available); v45 caches may hold
		# chunks built on the floor levels and counted as legitimate climbs.
		# v46 → v47: no road overlay on LOD 2-3 meshes (RoadTerrain.
		# OVERLAY_MIN_RES); cached far meshes still carried theirs.
		# v47 → v48: tunnel tubes get a floor slab (GradeTunnel.FLOOR_M), in
		# the mesh and in the collision faces.
		# v48 → v49: rock vertex colours come from RockImpurity (mountain core,
		# carve depth, strata, dust) and the corundum default ground is the
		# catalogue rock corundum_default_rock — a v48 mesh holds the old
		# iron_tint / flat rock mottling.
		# v49 → v50: the crack network carves every corundum ground
		# (PlanetData.cracks_apply_to_zone) — an outcrop of blue corundum was
		# left whole in v49 meshes and collision shapes — and keeps the POI
		# spheres and the mountains whole (PlanetData.crack_factor).
		# v50 → v51: the vertices nearest a crack rim are slid onto it
		# (crack_rim_snap — no more crenellated canyon tops, the rim stays a
		# sharp edge) and the mountain mask fades over crack_mountain_fade_m
		# from the outline, not over the feather.
		# The chunk skirt build switch (Globals.ENABLED_DEV_TOOLS) is baked
		# geometry too: a mesh cached with skirts must not be served without.
		var _sk := "_sk%d" % int(Globals.is_dev_tool_enabled(&"build_chunk_skirts"))
		# The rock catalogue (rocks.json) is baked colour too: a tint retouched
		# in rocks.py and re-exported must not be served from old meshes.
		var _rk := ""
		if FileAccess.file_exists(RockCatalogue.PATH):
			_rk = "_rk%s" % FileAccess.get_md5(RockCatalogue.PATH).substr(0, 8)
		var _cache_version := "%s_%d_%.0f_%.0f_%.1f_%.2f_tr%d_v51%s%s%s%s%s%s%s%s" % [
			data.planet_name, data.export_nside, data.radius,
			data.max_height, data.height_offset, data.terrain_exaggeration,
			data.chunk_heightmap_res, _cor, _brg, _rw, _dv, _pz, _mt, _sk, _rk]
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

	# Streaming : null si aucun service n'est configuré — la planète lit son pack local.
	planet_data.remote_source = RemoteTileSource.for_planet(planet_data.planet_name)

	# The geometry version is what a client and a server must SHARE for their
	# terrains to agree (the sampler, the carve, the stitch are all in it):
	# grep it in both logs before hunting a client/server height mismatch.
	print("[PlanetTerrain] initialize: planet=%s radius=%.0f export_nside=%d server=%s geometry=%s" % [
		data.planet_name, data.radius, data.export_nside, server_mode,
		_chunk_cache.version if _chunk_cache else "no-cache"])

	# Chunks container
	if has_node("Chunks"):
		_chunks_node = $Chunks
	else:
		_chunks_node = Node3D.new()
		_chunks_node.name = "Chunks"
		add_child(_chunks_node)

	# Éditeur : seuls ces trois points lui sont propres. Tout le reste — préchauffage des
	# requêtes, quadtree, tâches de mesh, streaming — est le chemin commun, et c'est
	# précisément ce qu'on veut voir dans l'éditeur.
	if Engine.is_editor_hint():
		_populate_biome_entries()
		_print_biome_locations()
		if editor_auto_tune_camera:
			_auto_tune_editor_camera()

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
		# vehicle | prop (masks 1–4 = GlobalsDefs.MASK_SOLID).
		_collision_body.collision_layer = GlobalsDefs.LAYER_WORLD
		_collision_body.set_collision_layer_value(GlobalsDefs.LAYER_WORLD, true)
		_collision_body.collision_mask = GlobalsDefs.MASK_SOLID
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
	# Procedural mountains: resolve the planet gate and the debug features on
	# THIS thread, before the bridge spans and grade profiles below read the
	# sampler — they must stand on the mountains too.
	planet_data.warm_mountains()

	# Find the road/chasm crossings now rather than on the first chunk that
	# needs a bridge: the walk costs ~200 ms on tarsis_3 and would otherwise
	# land as a visible stall in the middle of flight. Memoised afterwards.
	planet_data.get_bridge_spans()
	# Plan the decks and ramps in the same breath, on THIS thread. The mesh
	# workers cut the road ribbon out from under those ramps, so they must read
	# a table that is already complete; building it lazily would let a worker
	# and the main thread disagree about where a bridge starts, and the ribbon
	# would be cut open where nothing spans it.
	planet_data.warm_bridge_plans()
	# Same reason, same place: the railway profiles feed the bed builders on
	# the mesh workers and the viaduct spawner on the main thread.
	planet_data.warm_grade_profiles()
	# Same reason again, one step further: a building placed in the editor
	# carries a TerrainPad that levels the ground under it, and the pad has to
	# be in the index BEFORE the first mesh task reads it — a chunk built
	# without it would draw the untouched slope and be thrown away a frame
	# later. Buildings that arrive afterwards (spawned by the server, received
	# by the client on entering GORC range) register themselves.
	warm_terrain_pads()

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


## The collision chunk covering [param world_pos], as the key used throughout the residency system,
## or "" when this terrain cannot answer (no data, or the point sits on the centre).
##
## THE single definition of "which chunk covers this point". The pin sweep and anyone asking whether
## the ground exists must agree, or a body would wait on a chunk nobody ever requested.
##
## The direction is taken in the planet's OWN frame: vec2pix_nest expects it there, and the planet
## turns, so a world-frame direction resolves to the wrong tile.
func collision_chunk_key(world_pos: Vector3) -> String:
	if planet_data == null:
		return ""
	# Through the planet's own conversion, which the chunk pinning also uses — the two MUST agree on
	# which tile covers a point, or a body waits on a chunk nobody requested.
	var planet: Planet = get_parent() as Planet
	if planet == null:
		return ""
	var dir: Vector3 = planet.local_dir_of(world_pos)
	if dir.is_zero_approx():
		return ""
	# The client's FINEST LOD nside on crack planets, so collision is built on the same grid the
	# visual renders; the export nside otherwise (see PlanetData.collision_detail_nside).
	var nside: int = planet_data.collision_detail_nside()
	return "hp_n%d_p%d" % [nside, HEALPix.vec2pix_nest(nside, dir)]


## True when the chunk covering [param world_pos] already carries its collision body.
##
## The server builds terrain collision chunk by chunk, around the bodies that need it, and the
## generation runs on worker threads — so there is a window after a body is created where there is
## simply NOTHING under it. During that window the only shapes in reach are the planet-wide fallbacks,
## which sit 100-200 m below the playable surface: a body released into it falls straight through.
## Anything that would let a body fall must ask this first.
##
## NB: `initial_chunks_ready` cannot serve here — server-side it is emitted BEFORE any chunk loads.
func has_collision_under(world_pos: Vector3) -> bool:
	if not _server_collision_loaded:
		return false
	var key: String = collision_chunk_key(world_pos)
	return key != "" and _server_collision_chunks.has(key)


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
	var missing: Array = []
	for k in effective.keys():
		var key := k as String
		if not _server_collision_chunks.has(key) and not _server_chunk_tasks.has(key):
			var _mn := _parse_nside_from_key(key)
			var _mi := _parse_ipix_from_key(key)
			if _mn > 0 and _mi >= 0:
				missing.append(Vector2i(_mn, _mi))
			_load_chunk(key)

	# Toutes les tuiles de la zone d'un coup, maintenant que le jeu désiré est connu.
	# Le garde n'examine que quatre chunks par frame : sans cette passe, une zone neuve
	# demanderait ses tuiles au compte-gouttes et mettrait des minutes à devenir solide.
	# Non bloquant, et sans effet sur une planète qui ne streame pas.
	TileResidency.prefetch_chunks(planet_data, missing)

	# Bridges outlive the chunks that reference them; collect the ones nothing
	# has claimed back, after the load pass has had its chance to.
	_sweep_orphan_bridges()


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
		if PropNet.prof_on:
			PropNet.prof_chunk_unloads += 1  # TEMPORARY (étape 0d): measure the churn under the player
		body.queue_free()
		_server_collision_chunks.erase(key)
	_release_bridges(key)
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
	# Un chunk différé retourne en fin de file. Sans borne, le drain le ressortirait
	# aussitôt et tournerait sur la file entière à chaque appel — c'est ce motif exact
	# qui avait fait tomber le CLIENT à 0,2 FPS. Chaque entrée est donc examinée au plus
	# une fois par passage.
	# Deux fois les créneaux de tâche, comme le backlog du client : de quoi remplacer ce
	# qui vient de finir sans réexaminer une zone de plusieurs centaines de chunks à
	# chaque tick. La passe de prefetch ci-dessus a déjà demandé toutes les tuiles, donc
	# les différés ne le restent pas longtemps.
	var budget: int = mini(_server_chunk_queue.size(), MAX_SERVER_CHUNK_TASKS * 2)
	var deferred: Array[Dictionary] = []
	while budget > 0 and _server_chunk_tasks.size() < MAX_SERVER_CHUNK_TASKS \
			and not _server_chunk_queue.is_empty():
		budget -= 1
		var entry: Dictionary = _server_chunk_queue[0]
		_server_chunk_queue.remove_at(0)
		var key: String = entry["key"]
		if _server_collision_chunks.has(key) or _server_chunk_tasks.has(key):
			continue  # Loaded or started since it was queued.
		if not _server_start_chunk_load(key, entry["ipix"], entry["col_res"]):
			deferred.append(entry)
	_server_chunk_queue.append_array(deferred)


## Begin async loading for one chunk.  Loads the collision shape from the disk
## cache (fast), pre-loads recipe data on the main thread (~0.5 ms), then
## submits generate_heightmap to a worker thread (phase 0).  When that
## completes, _server_poll_chunk_tasks() stores the image and submits
## generate_collision_shape_healpix (phase 1).
## Rend false quand le chunk est DIFFÉRÉ faute de tuiles : l'appelant le remet en file.
func _server_start_chunk_load(key: String, ipix: int, col_res: int) -> bool:
	# Try the disk-cached collision shape (cheap main-thread I/O).
	var cached_shape: ConcavePolygonShape3D = null
	if _chunk_cache and _chunk_cache.has_collision(key, 0) \
			and not planet_data.chunk_cache_ineligible(_parse_nside_from_key(key), ipix):
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

	# La MÊME garantie que côté client, et elle vaut davantage ici. Sans elle, une tuile
	# absente ne fait pas échouer l'échantillonnage : il retombe sur la carte
	# équirectangulaire globale, une surface plus plate de plusieurs centaines de mètres
	# (voir PlanetData.sample_height_for_direction). La forme est alors bâtie sur ce
	# repli, ÉCRITE DANS LE CACHE DISQUE, puis attachée — et le joueur traverse le sol
	# pour atterrir sur le filet de sécurité. _cached_shape_valid ne l'attrape pas : il ne
	# contrôle que les formes RELUES du cache, et il les compare à une surface vive qui,
	# tant que les tuiles manquent, est ce même repli. Les deux sont d'accord, à tort.
	#
	# Une forme déjà en cache et jugée valide n'a rien à attendre : elle porte du vrai
	# relief, c'est ce que _cached_shape_valid vient de vérifier.
	if cached_shape == null \
			and not TileResidency.request_chunk_tiles(planet_data, key_nside, ipix):
		return false

	if planet_data.chunk_heightmaps_dir != "":
		if cached_shape != null:
			_server_assemble_chunk(key, key_nside, ipix, cached_shape)
		else:
			_server_submit_shape_task(key, ipix, col_res)
		return true

	# Fast-path: both image and shape already available — assemble now.
	if planet_data.is_chunk_cached(key):
		if cached_shape != null:
			_server_assemble_chunk(key, key_nside, ipix, cached_shape)
		else:
			_server_submit_shape_task(key, ipix, col_res)
		return true

	# Phase 0: pre-load recipe data sync on the main thread (~0.5 ms),
	# then submit the CPU-heavy generate_heightmap to a worker thread.
	var preloaded := planet_data._load_recipe_data_sync(ipix, key)
	if preloaded.is_empty():
		push_warning("[PlanetTerrain] _load_chunk: recipe '%s' not found — skipping." % key)
		return true

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
	return true


## Submit a phase-1 WorkerThreadPool task that generates the collision shape.
## The heightmap image MUST already be stored in planet_data before calling.
func _server_submit_shape_task(key: String, ipix: int, col_res: int) -> void:
	var pd := planet_data
	var nside := _parse_nside_from_key(key)
	if nside <= 0:
		nside = planet_data.export_nside
	# result_ref[1] porte la durée de génération : écrit par le worker sur un index qui
	# existe déjà, lu par le thread principal seulement après is_task_completed().
	var result_ref: Array = [null, 0]
	var task_entry := {
		"phase": 1, "task_id": -1, "result_ref": result_ref,
		"ipix": ipix, "col_res": col_res,
		"cached_shape": null, "evicted": false,
	}
	_server_chunk_tasks[key] = task_entry
	var task_id := WorkerThreadPool.add_task(func():
		var _t0 := Time.get_ticks_usec() if PropNet.prof_on else 0
		result_ref[0] = PlanetChunk.generate_collision_shape_healpix(pd, nside, ipix, col_res)
		if _t0 != 0:
			result_ref[1] = Time.get_ticks_usec() - _t0
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
			# Evicted to be rebuilt (a profile born under it), not dropped.
			if entry.get("reload", false):
				_load_chunk(key)
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
			var _cu: int = entry["result_ref"][1] if entry["result_ref"].size() > 1 else 0
			if _cu > 0:
				PropNet.prof_col_calls += 1
				PropNet.prof_col_usec += _cu
			if shape:
				if _chunk_cache and _persistable(shape) \
						and not planet_data.chunk_cache_ineligible(nside, ipix):
					_chunk_cache.save_collision(key, 0, shape)
				_server_assemble_chunk(key, nside, ipix, shape)
			else:
				push_warning("[PlanetTerrain] async _load_chunk: shape '%s' null — skipping." % key)

	_server_drain_chunk_queue()


## Chunk-local origin that server collision faces are rebased against
## (see [method PlanetChunk.generate_collision_shape]).  The CollisionShape3D
## is offset by exactly this value — applied in double precision by the node
## transform — so the small float32 faces land back on the visual surface.
## Cette géométrie a-t-elle le droit d'aller dans le cache disque ?
##
## Non si un seul de ses sommets a lu un ANCÊTRE faute d'avoir sa propre tuile alors que
## celle-ci est publiée : la surface obtenue est un parent plus lisse, dont l'écart n'est
## borné par rien (35,4 m mesurés sur tarsis_3), et une fois persistée plus rien ne la
## distingue d'une surface correcte — le validateur de version ne regarde que les
## paramètres de la planète, pas la provenance des hauteurs. La géométrie reste utilisée
## tout de suite : on refuse seulement de la graver. Voir PlanetData.climb_mark().
static func _persistable(geom: Resource) -> bool:
	return geom != null and int(geom.get_meta("provisional_climbs", 0)) == 0


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
	# Wind the faces in Godot's CLOCKWISE-front convention, i.e. geometric normal
	# (e1-e0)x(e2-e0) pointing INTO the ground. backface_collision keeps physics solid either
	# way, but the NPC navmesh bake parses these bodies through the same face pipeline as
	# mesh/CSG sources, which expects CW-front input (it flips for Recast internally): faces
	# whose geometric normal points OUTWARD bake ZERO navmesh while raycasts hit them fine,
	# sealing NPCs inside any building placed on terrain. Proven empirically on the real
	# cached chunk hp_n8192_p214960184 (scratchpad navbake_chunk_test.gd, 2026-08-14):
	# as-cached outward winding -> 0 polygons, flipped -> polygons. Winding is uniform within
	# a chunk (HEALPix grid orientation varies per base face), so one detection on the first
	# non-degenerate triangle suffices. Done HERE, not in the generator, so shapes reloaded
	# from the prebaked disk cache are corrected too.
	var _faces := shape.get_faces()
	var _outward := HEALPix.pix2vec_nest(nside, ipix)
	var _probe := 0
	while _probe + 2 < _faces.size():
		var _n := (_faces[_probe + 1] - _faces[_probe]).cross(_faces[_probe + 2] - _faces[_probe])
		if _n.length_squared() > 0.000001:
			if _n.dot(_outward) > 0.0:
				for _j in range(0, _faces.size() - 2, 3):
					var _tmp := _faces[_j + 1]
					_faces[_j + 1] = _faces[_j + 2]
					_faces[_j + 2] = _tmp
				shape.set_faces(_faces)
			break
		_probe += 3
	var body := StaticBody3D.new()
	body.name = key + "_body"
	# Same identity as the legacy shared PlanetCollision body.
	body.collision_layer = GlobalsDefs.LAYER_WORLD
	body.set_collision_layer_value(GlobalsDefs.LAYER_WORLD, true)
	body.collision_mask = GlobalsDefs.MASK_SOLID
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
	# A shape that read an ANCESTOR tile for some vertex (its own not resident
	# yet) is a smoother parent surface — off by nothing on a plain, by
	# hundreds of metres on tarsis_3's mesa cliffs — and it stays attached
	# until the chunk unloads. Say so: it is the first thing to look for when
	# a player stands in the air or under the ground he sees.
	var _climbs := int(shape.get_meta("provisional_climbs", 0))
	if _climbs > 0:
		push_warning("[PlanetTerrain] SERVER collision %s built with %d vertex(es) on ancestor tiles"
				% [key, _climbs] + " — its surface may differ from the clients' by the parent/child gap")
	if PropNet.prof_on:
		PropNet.prof_chunk_loads += 1  # TEMPORARY (étape 0d): measure the churn under the player
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
	# Rail modules stand on their own box colliders (RailwayTrack): the bed is
	# in the chunk shape, the rails are not. Built at the collision level, where
	# the chunk's pieces partition the track exactly once.
	if nside == planet_data.collision_detail_nside() and planet_data.has_railways():
		var rail_body := RailwayTrack.make_collision_body(
			planet_data, nside, ipix, _chunk_collision_origin(nside, ipix), key)
		if rail_body:
			_chunks_node.add_child(rail_body)
			if not _server_feature_nodes.has(key):
				_server_feature_nodes[key] = []
			(_server_feature_nodes[key] as Array).append(rail_body)
	# Bridges. This path — not _create_chunk — is the live server residency, and
	# it did not build them: the deck existed on the client and nowhere else, so
	# a vehicle drove along the visible ribbon and fell through the gorge. The
	# deck carries the ONLY collision over a chasm, so the server needs it as
	# much as the terrain it replaces. Deduplicated by span, so a fine
	# sub-chunk pinned under a body cannot build a second one.
	_spawn_bridges({"key": key, "nside": nside, "ipix": ipix, "lod": 0})


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
			if _chunk_cache and _persistable(shape) \
					and not planet_data.chunk_cache_ineligible(nside, ipix):
				_chunk_cache.save_collision(key, 0, shape)

		print("[PlanetTerrain] rebuild_chunks: rebuilt '%s'" % key)


func _exit_tree() -> void:
	# Joindre le fil de téléchargement avant que la planète disparaisse.
	if planet_data != null and planet_data.remote_source != null:
		planet_data.remote_source.stop()
		planet_data.remote_source = null


# ------------------------------------------------------------------
# Frame update
# ------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not _initialized:
		return
	# Editor flight: drive the body under the viewport camera BEFORE anything reads a
	# transform this frame, so the LOD and the camera agree on where the body is.
	if Engine.is_editor_hint():
		_editor_flight_step()
	TerrainProfiler.maybe_report(_mesh_task_backlog.size(), _mesh_tasks.size())

	# A line profile born late changes the chunks under it, on both sides.
	_poll_starved_grade_profiles()
	# So does a pad whose elevation tiles have only just arrived.
	_poll_starved_pads()

	# ── Server: poll async collision chunk loading ────────────────
	if is_server:
		_poll_starved_bridge_plans()
		if PropNet.prof_on:
			var _t0: int = Time.get_ticks_usec()
			_server_poll_chunk_tasks()
			PropNet.prof_terrain_usec += Time.get_ticks_usec() - _t0
			return
		_server_poll_chunk_tasks()
		return

	# ── Once per RENDERED frame, whatever the physics clock does ──────
	# This runs in the physics step, and a slow frame makes the engine run up
	# to max_physics_steps_per_frame (8) catch-up steps in a row. Everything
	# below used to run in each of them: eight assembly batches, and the LOD
	# update — 100-250 ms of traversal, balance and diff — every 8/60 s of
	# SIMULATED time, i.e. every second frame instead of every 0.25 s. A slow
	# frame made the next one slower: the 1.4-3.1 s frames of the 2026-09-14
	# heartbeat (`gap<=3062 phys<=959`). Wall clock and frame count decide now.
	var frame := Engine.get_process_frames()
	if frame == _last_poll_frame:
		return
	_last_poll_frame = frame

	# ── Poll completed async work every frame (not rate-limited) ───────
	# This minimises the latency between a task finishing and its result
	# appearing on screen.  The actual heavy work runs on worker threads;
	# these polls are cheap (flag checks + bounded assembly).
	# Timed by ClientPerf (client.ini debug_perf): the heartbeat's hitch lines
	# then say whether a long frame sat in the assembly of finished meshes
	# (main-thread node creation + cache write) or in the LOD update below.
	var _tk := _perf_begin()
	_poll_pending_recipes()
	_poll_mesh_tasks()
	_process_assemble_queue()
	_perf_end("terrain_assemble", _tk)
	_tk = _perf_begin()
	_drain_bridge_spawn_queue()
	_perf_end("bridge_queue", _tk)

	# ── Emit initial_chunks_ready once the pipeline drains ───────────
	if not _initial_ready_emitted and not _active_chunks.is_empty() \
			and _recipe_waiters.is_empty() and _mesh_tasks.is_empty() \
			and _assemble_queue.is_empty() and _mesh_task_backlog.is_empty() \
			and _pending_recipes.is_empty():
		_initial_ready_emitted = true
		initial_chunks_ready.emit()
		print("[PlanetTerrain] initial_chunks_ready emitted (active=%d)" % _active_chunks.size())

	# ── Rate-limited LOD update, on the wall clock ───────────────────
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_update_msec < int(UPDATE_INTERVAL * 1000.0):
		return
	_last_update_msec = now_msec
	_tk = _perf_begin()
	_update_terrain()
	_perf_end("terrain_update", _tk)


## ClientPerf scopes, editor-safe: the autoload is not @tool, so its members
## do not exist under the editor preview (see _compute_star_dir), and the
## terrain's physics step runs there too. 0 = no timing, like scope_begin.
func _perf_begin() -> int:
	if Engine.is_editor_hint():
		return 0
	return ClientPerf.scope_begin()


func _perf_end(scope_name: String, token: int) -> void:
	if token != 0:
		ClientPerf.scope_end(scope_name, token)


## World-space unit direction from this planet's centre to the system star, in DOUBLE precision (exact
## at ~3e10). Fed to the terrain shader for the celestial-layer star lighting. Falls back to the last
## value if the star node is not resolvable yet.
func _compute_star_dir() -> Vector3:
	# Les autoloads ne sont pas @tool : dans l'éditeur leur script est bien nommé mais ses
	# membres n'existent pas, et lire universe_scene y lève à chaque frame. Il n'y a de
	# toute façon pas de scène d'univers dans l'éditeur — le terrain garde la direction
	# par défaut, comme le faisait l'ancien aperçu.
	if Engine.is_editor_hint():
		return _star_dir_world
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
			var layer: int = GlobalsDefs.RENDER_MASK_CELESTIAL if want_celestial else GlobalsDefs.RENDER_MASK_LOCAL
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
	var _tk := _perf_begin()
	for base_pix in BASE_PIXEL_COUNT:
		_traverse(1, base_pix, 0, local_cam, horizon_dot, desired)
	_perf_end("terrain_traverse", _tk)
	_tk = _perf_begin()
	_balance_and_stitch(desired, local_cam)
	_perf_end("terrain_balance", _tk)
	_tk = _perf_begin()

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
	# One snapshot of the pipeline's keys for the whole pass: the per-key
	# query scanned the backlog, the assembly queue and the recipe waiters
	# linearly — 570 keys × a 500-entry backlog at world entry, four times
	# per second, inside the physics step. Keys this pass queues are added
	# as it goes, so the snapshot stays exact.
	var pipeline := _pipeline_keys()
	# Only what is neither on screen nor in flight gets sorted: in steady
	# state that is a handful of keys, where sorting all ~480 with a distance
	# lambda cost 4 ms of every update.
	var _new_keys: Array = []
	for key in desired:
		if not _active_chunks.has(key) and not pipeline.has(key):
			_new_keys.append(key)
	if _new_keys.size() > 1:
		_new_keys.sort_custom(func(a: String, b: String) -> bool:
			return desired[a].center.distance_squared_to(local_cam) < desired[b].center.distance_squared_to(local_cam))
	for key in _new_keys:
		_try_create_or_defer(desired[key])
		pipeline[key] = true

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
		if not _active_chunks.has(key) or pipeline.has(key):
			continue
		var _act: Dictionary = _active_chunks[key]
		var _want: Dictionary = desired[key]
		if _act.lod != _want.lod:
			_remove_chunk(key)
			_try_create_or_defer(_want)
			pipeline[key] = true
		elif int(_act.get("stitch", 0)) != int(_want.get("stitch", 0)):
			# Only the seam edges change: keep the old mesh on screen (its
			# skirt still covers the seam) until the re-baked one is assembled.
			_want["_swap"] = true
			_try_create_or_defer(_want)
			pipeline[key] = true

	_perf_end("terrain_steps", _tk)

	# Bridges outlive the chunks that ask for them, so they are collected here
	# rather than in _remove_chunk — after steps 1-3 have had their chance to
	# claim them back.
	_sweep_orphan_bridges()

	# Look-ahead: prefetch chunks along the predicted camera trajectory so
	# they're ready before the player reaches them.
	_tk = _perf_begin()
	_prefetch_look_ahead(local_cam, horizon_dot)
	TileResidency.prefetch(planet_data, local_cam, _cam_history)
	_perf_end("terrain_prefetch", _tk)


# ------------------------------------------------------------------
# Editor camera
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
	var surface: Vector3 = surface_point_for_direction(dir)
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


## Put the editor viewport 200 m above the ground at unit [param dir], upright.
## Shared by the biome dropdown and the two "Go to" buttons.
##
## The camera cannot be driven (see the editor-flight section), so the BODY is
## brought under it — the same trick as flight, applied once: the camera keeps
## its world position and the body is placed so that this ground point sits
## straight below it, at GOTO_ALTITUDE. That replaces the old "select a marker,
## then press F" dance, which also placed the camera wrongly: F only moves the
## orbit target and keeps the current orbit DISTANCE, so after zooming out over
## a planet the camera landed tens of kilometres behind the marker along the
## view direction — underground unless you happened to be looking down.
##
## With flight on, the flight state is re-seeded so the next step carries on
## from here instead of dragging the body back. With flight off the body is
## left where it was put (never saved: see Planet.editor_set_flight_transform),
## and switching flight on later seeds from it.
##
## A focus marker is still dropped as a child, for whoever wants to find the
## point again in the scene tree — it is NOT selected, so the inspector stays
## on this node.
func _editor_goto_surface_point(dir: Vector3, label: String) -> void:
	if planet_data == null:
		return
	var altitude: float = planet_data.sample_height_for_direction(dir) + GOTO_ALTITUDE
	# Above the GROUND, not above sea level — planet-local.
	var local_pos: Vector3 = dir * (planet_data.radius + altitude)

	if not _editor_biome_focus or not is_instance_valid(_editor_biome_focus):
		_editor_biome_focus = Node3D.new()
		_editor_biome_focus.name = "BiomeFocus"
		add_child(_editor_biome_focus)
		# Ensure the marker is not saved with the scene.
		_editor_biome_focus.owner = null
	_editor_biome_focus.position = local_pos

	var placed := _editor_bring_under_camera(dir, altitude)
	print("[PlanetTerrain] Go to %s — local=(%d, %d, %d)%s" % [
		label, int(local_pos.x), int(local_pos.y), int(local_pos.z),
		"" if placed else " — no editor camera: select BiomeFocus and press F"])


## Place the body so that ground point [param dir] (unit, body frame) sits
## straight below the editor camera, [param altitude] metres above the
## reference sphere. Returns false when there is no editor camera to read.
func _editor_bring_under_camera(dir: Vector3, altitude: float) -> bool:
	var planet := get_parent() as Planet
	if planet == null or planet_data == null:
		return false
	var cam := _editor_camera_world()
	if cam == Vector3.INF:
		return false
	_flight_dir = dir
	_flight_alt = altitude
	# The camera has not moved: the next flight step must see no delta and no jump.
	_flight_last_cam = cam
	if editor_planet_flight:
		_flight_was_on = true
	_editor_flight_place(planet, cam, planet_data.radius)
	return true


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


## Planet-local position of the terrain surface along unit [param dir]: sea
## level plus the elevation sampled from the heightmap pyramid.
##
## Sea level alone ([code]dir * radius[/code]) is NOT the surface — tarsis_3
## spans −1700 m to +9000 m, so a point built that way sits kilometres below
## the ground on any highland. Every lon/lat → position conversion in the
## editor goes through here for that reason.
##
## Samples at the finest pyramid level, which is the surface the runtime
## collision mesh is built from; a coarse editor preview may render a slightly
## smoother shape, but the finest level is the authoritative ground.
func surface_point_for_direction(dir: Vector3) -> Vector3:
	if planet_data == null:
		return dir
	return dir * (planet_data.radius
		+ planet_data.sample_height_for_direction(dir))


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
	# Sample in the PLANET frame, not the world frame. The heightmap is
	# indexed by body-local direction (HEALPix lon/lat), and the body is
	# rotated whenever "Fly in planet frame" is on (Planet.editor_set_flight_
	# transform), when the system scene places it with a tilt, or by the spin
	# at runtime. Feeding the world-space direction to the sampler then reads
	# the altitude of some OTHER point of the planet — on a mountain that put
	# the snapped object hundreds of metres under the ground.
	var planet_xform := global_transform
	var local_pos := planet_xform.affine_inverse() * n3.global_position
	if local_pos.length_squared() < 1.0:
		return xform  # at the planet centre — no radial direction
	var local_dir := local_pos.normalized()
	var h := planet_data.sample_height_for_direction(local_dir)
	# A building that levels the ground under it must be snapped to the LEVELLED
	# altitude, not to the raw relief it replaces — otherwise the snap puts it
	# on the slope and the terrain then flattens out from under it. The pad node
	# can sit anywhere in the building, so its radial offset from the object's
	# own origin is preserved.
	var pad := _terrain_pad_of(n3)
	if pad != null:
		var z := pad.pad_altitude()
		if not is_nan(z):
			# Measured at the pad's ground reference (the box's underside), the
			# same point the server re-seats a networked building on.
			var pad_local := planet_xform.affine_inverse() * pad.ground_reference_global()
			h = z + (local_pos.length() - pad_local.length())
	var surface_pos: Vector3 = planet_xform \
		* (local_dir * (planet_data.radius + h + editor_snap_height_offset))
	# Radial "up" in world space, for the alignment below.
	var dir := (planet_xform.basis * local_dir).normalized()

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


## The TerrainPad [param n3] carries, if any: itself, or the first one below
## it. A building declares exactly one; the first found is that one.
func _terrain_pad_of(n3: Node) -> TerrainPad:
	if n3 is TerrainPad:
		return n3 as TerrainPad
	for child: Node in n3.get_children():
		var found := _terrain_pad_of(child)
		if found != null:
			return found
	return null


# ------------------------------------------------------------------
# POI import (QGIS)
# ------------------------------------------------------------------

## Inspector button: rebuild the "POIs" child from the JSON exported by
## tools/planettech/qgis/export_poi.py. Each POI becomes an Area3D named after it, holding
## a SphereShape3D of its influence radius, sitting on the terrain surface at
## its longitude/latitude. The nodes are owned by the edited scene, so they are
## saved into the planet's .tscn and can be tweaked by hand afterwards; the
## QGIS attributes ride along as node metadata.
##
## Re-running replaces the whole "POIs" subtree — it never appends.
func import_poi_from_json() -> void:
	if not Engine.is_editor_hint():
		return

	var data := _resolve_planet_data()
	if data == null:
		push_warning("[PlanetTerrain] Import POI: no PlanetData on this node or "
			+ "its parent Planet.")
		return
	if data.radius <= 0.0:
		push_warning("[PlanetTerrain] Import POI: PlanetData.radius is not set "
			+ "yet (it comes from the chunk manifest) — reopen the scene first.")
		return
	# compute_surface_transform() reads the *member*, and silently returns the
	# node untouched when it is null — which would drop every POI to sea level.
	# Adopt the resolved resource, exactly as initialize() would have.
	if planet_data == null:
		planet_data = data

	var path := poi_json_path
	if path.is_empty():
		path = "res://assets/qgis/export/%s_poi.json" % data.planet_name
	if not FileAccess.file_exists(path):
		push_warning("[PlanetTerrain] Import POI: '%s' not found — run "
			% path + "tools/planettech/qgis/export_poi.py from the QGIS Python console first.")
		return

	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("pois")) != TYPE_ARRAY:
		push_warning("[PlanetTerrain] Import POI: '%s' is not a POI export " % path
			+ "(expected an object with a \"pois\" array).")
		return

	# Resolved through Engine.get_singleton (as elsewhere in this file) rather
	# than the EditorInterface global: this script also ships in the exported
	# game, where that global does not exist.
	var ei = Engine.get_singleton("EditorInterface")
	if ei == null:
		return
	var scene_root: Node = ei.get_edited_scene_root()
	if scene_root == null:
		push_warning("[PlanetTerrain] Import POI: no scene is open in the editor.")
		return

	var imported := build_poi_nodes(parsed["pois"], data, scene_root)
	ei.mark_scene_as_unsaved()
	print("[PlanetTerrain] Imported %d POI from %s" % [imported, path])


## (Re)build the "POIs" child from [param pois] (the parsed JSON array) and
## return how many were placed. Split out of [method import_poi_from_json] so
## it carries no editor dependency and can be driven from a test harness;
## [param owner_node] is what the created nodes are owned by (the edited scene
## root in the editor) — pass null to leave them unowned.
func build_poi_nodes(pois: Array, data: PlanetData, owner_node: Node) -> int:
	# Replace, never append: drop any previous import before rebuilding.
	var previous := get_node_or_null("POIs")
	if previous:
		remove_child(previous)
		previous.queue_free()

	var container := Node3D.new()
	container.name = "POIs"
	add_child(container)
	if owner_node != null:
		container.owner = owner_node

	var imported := 0
	for entry in pois:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if _add_poi_node(container, owner_node, data, entry):
			imported += 1
	return imported


## Build one Area3D for [param entry] under [param container]. Returns false
## when the entry carries no usable position.
func _add_poi_node(container: Node3D, owner_node: Node, data: PlanetData,
		entry: Dictionary) -> bool:
	if not (entry.has("lon") and entry.has("lat")):
		push_warning("[PlanetTerrain] Import POI: entry without lon/lat skipped.")
		return false

	var dir := HEALPix.lonlat2vec(float(entry["lon"]), float(entry["lat"]))

	var area := Area3D.new()
	# Fall back to the id when the POI has no name — a node name can't be empty.
	var poi_name := _poi_str(entry, "name").validate_node_name()
	area.name = poi_name if not poi_name.is_empty() \
		else "POI_%d" % _poi_int(entry, "id")
	# force_readable_name so two POIs sharing a name become "Foo"/"Foo2", not
	# "@Area3D@42" — the whole point is to recognise them in the Scene dock.
	container.add_child(area, true)
	if owner_node != null:
		area.owner = owner_node

	area.monitoring = false
	area.monitorable = false
	area.collision_layer = poi_collision_layer
	area.collision_mask = poi_collision_mask

	var sphere := SphereShape3D.new()
	var radius = entry.get("radius")
	sphere.radius = maxf(0.1 if radius == null else float(radius), 0.1)
	var shape := CollisionShape3D.new()
	shape.shape = sphere
	shape.name = "Zone"
	area.add_child(shape)
	# A child without an owner is not serialised into the .tscn.
	if owner_node != null:
		shape.owner = owner_node

	# QGIS may carry an explicit ground elevation; otherwise sample the terrain
	# heightmap through compute_surface_transform(), which also stands the node
	# up along the surface normal.
	var elevation = entry.get("elevation")
	if elevation != null:
		area.position = dir * (data.radius + float(elevation))
	else:
		area.position = dir * data.radius
		area.global_transform = compute_surface_transform(area)

	# Metadata is serialised with the node, so the QGIS attributes survive the
	# save without needing a dedicated POI class or resource.
	area.set_meta("poi_id", _poi_int(entry, "id"))
	area.set_meta("poi_type", _poi_str(entry, "poi_type"))
	area.set_meta("population", _poi_int(entry, "population"))
	area.set_meta("description", _poi_str(entry, "description"))
	area.set_meta("lon", float(entry["lon"]))
	area.set_meta("lat", float(entry["lat"]))
	return true


## The POIs of this planet as [code]{name, position (world), radius}[/code], read once and cached.
##
## The radius is NOT in the node metadata — it exists only as the child "Zone" CollisionShape3D's
## SphereShape3D radius, which is why this accessor exists rather than every caller walking the
## tree. The POI Area3Ds are inert markers (collision_layer 0, monitoring off), so consumers do a
## distance test against this list instead of a physics query.
func poi_spheres() -> Array:
	if not _poi_cache.is_empty():
		return _poi_cache
	var container: Node = get_node_or_null("POIs")
	if container == null:
		return _poi_cache
	for child in container.get_children():
		if not (child is Node3D):
			continue
		var shape_node := child.get_node_or_null("Zone") as CollisionShape3D
		if shape_node == null or not (shape_node.shape is SphereShape3D):
			continue
		_poi_cache.append({
			"name": String(child.name),
			"position": (child as Node3D).global_position,
			"radius": (shape_node.shape as SphereShape3D).radius,
		})
	return _poi_cache


## The POIs as the crack network wants them (PlanetData.set_crack_exclusions): planet-LOCAL unit
## directions and radii, so the pure carve can test them without the scene tree. Body-fixed like
## every direction the sampler reads — the POI nodes spin with the planet.
func crack_exclusion_pois() -> Array:
	var planet := get_parent() as Planet
	var out: Array = []
	for poi in poi_spheres():
		var d: Vector3 = planet.local_dir_of(poi["position"] as Vector3) if planet != null \
				else (poi["position"] as Vector3).normalized()
		out.append({"dir": d, "radius": float(poi["radius"])})
	return out


## The first POI in [param spheres] whose influence sphere, grown by [param margin], contains
## [param world_pos] — as {name, position, radius, distance}. Empty when the point is clear.
##
## Static and taking the list explicitly so the geometry can be exercised without a scene tree, and
## so every consumer (MiningZonePlanner picking a site, MiningZone placing a rock) shares ONE
## definition of "inside a POI". Two definitions would let a zone be sited legally while its rocks
## are culled by a different rule, or worse, the reverse.
static func first_blocking_poi(world_pos: Vector3, spheres: Array, margin: float) -> Dictionary:
	for poi in spheres:
		var d: float = world_pos.distance_to(poi["position"] as Vector3)
		if d < float(poi["radius"]) + margin:
			var hit: Dictionary = (poi as Dictionary).duplicate()
			hit["distance"] = d
			return hit
	return {}


## JSON field readers that tolerate a missing key *and* an explicit null — a
## hand-edited export shouldn't abort the import on a cast error.
func _poi_str(entry: Dictionary, key: String) -> String:
	var value = entry.get(key)
	return "" if value == null else str(value)


func _poi_int(entry: Dictionary, key: String) -> int:
	var value = entry.get(key)
	return 0 if value == null else int(value)


## The terrain's own PlanetData, or the parent Planet's when initialize() has
## not run yet (the button can be clicked on a freshly opened scene).
func _resolve_planet_data() -> PlanetData:
	if planet_data != null:
		return planet_data
	var parent := get_parent()
	if parent != null and parent.get("planet_data") != null:
		return parent.planet_data
	return null


# ------------------------------------------------------------------
# Quadtree traversal
# ------------------------------------------------------------------

## Per-node geometry of the quadtree, memoised: (nside << 32) | ipix →
## [center_dir, chunk_diag]. The traversal visits the same ~800 nodes every
## 0.25 s and each visit cost three pix2vec and the corner trigonometry —
## 20 ms of the update, i.e. of the physics step. Bounded by the nodes ever
## visited on this planet (a few thousand); cleared with the chunks.
var _node_geom: Dictionary = {}


func _traverse(nside: int, ipix: int, depth: int,
		local_cam: Vector3, horizon_dot: float, out: Dictionary) -> void:

	var node_id := (nside << 32) | ipix
	var geom: Array = _node_geom.get(node_id, [])
	if geom.is_empty():
		var cd := HEALPix.pix2vec_nest(nside, ipix)
		# Approximate chunk diagonal using two diagonal corners
		var corners: Array = HEALPix.get_pixel_corners(nside, ipix)
		var corner_a: Vector3 = corners[0] * planet_data.radius  # SW
		var corner_b: Vector3 = corners[2] * planet_data.radius  # NE
		geom = [cd, corner_a.distance_to(corner_b)]
		_node_geom[node_id] = geom
	var center_dir: Vector3 = geom[0]
	var center_pos := center_dir * planet_data.radius
	var chunk_diag: float = geom[1]

	# LOD distance = max(surface distance to the chunk, camera altitude above
	# the ACTUAL terrain surface).  Straight-line distance to the sea-level
	# chunk centre is wrong twice over: cracks/valleys put the camera below
	# the centres, and high terrain (tarsis_3's plateau is ~5.6 km above the
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


## The leaf record _traverse would have written for (nside, ipix) — for the
## chunks the 2:1 balance pass adds after the traversal.
func _leaf_info(nside: int, ipix: int, depth: int, local_cam: Vector3) -> Dictionary:
	var center_dir := HEALPix.pix2vec_nest(nside, ipix)
	var _cam_r := local_cam.length()
	var _cam_dir_l: Vector3 = local_cam / _cam_r if _cam_r > 0.0 else center_dir
	var _surface_dist := (_cam_dir_l - center_dir).length() * planet_data.radius
	var dist := maxf(_surface_dist, _cam_alt_above_surface)
	var key := _chunk_key_hp(nside, ipix)
	return {
		"key": key,
		"nside": nside,
		"ipix": ipix,
		"depth": depth,
		"center": PlanetChunk.snap_to_f32(center_dir * planet_data.radius),
		"lod": planet_data.get_lod_level(dist),
	}


## 2:1 balance of the leaf set, then the LOD-seam stitch mask of every leaf.
##
## Balance: no leaf may share an edge with a leaf more than ONE quadtree level
## coarser — the stitch (PlanetChunk._stitch_edge_heights) bakes a chunk's
## border on its PARENT grid, which is only the neighbour's grid at exactly
## one level of difference. The split factor makes deeper jumps rare, not
## impossible (HEALPix pixels distort near the poles); a too-coarse neighbour
## is split until it is one level away. A culled neighbour (horizon / back
## face, absent from the set) constrains nothing.
##
## Mask (client only — the server's finest-grid collision never stitches):
## bit per edge whose same-level neighbour is absent while its parent is a
## leaf. Left to 0 on the levels PlanetChunk.edge_stitch_applies rules out,
## so those chunks keep one cache file and never re-bake for a neighbour.
func _balance_and_stitch(desired: Dictionary, local_cam: Vector3) -> void:
	if desired.is_empty():
		_bal_prev_trav.clear()
		_bal_prev_out.clear()
		_bal_prev_removed.clear()
		return
	# Same leaf set as last time (the common case: the camera has not crossed
	# a split threshold since 0.25 s ago) → same splits and masks. The pass
	# costs 60 ms on tarsis_3's ~570 leaves, three times the traversal; the
	# cached answer is a dictionary copy. LODs are part of the answer (a mask
	# needs same-quality neighbours), so a changed lod invalidates it.
	var same := desired.size() == _bal_prev_trav.size()
	if same:
		for key in desired:
			var prev: Variant = _bal_prev_trav.get(key)
			if prev == null or int(prev) != int(desired[key].lod):
				same = false
				break
	if same:
		for key in _bal_prev_removed:
			desired.erase(key)  # a leaf the balance split away
		for key in _bal_prev_out:
			var cached: Dictionary = _bal_prev_out[key]
			if desired.has(key):
				if cached.has("stitch"):
					desired[key]["stitch"] = cached["stitch"]
			else:
				desired[key] = cached  # a leaf the balance split in
		return
	_bal_prev_trav.clear()
	for key in desired:
		_bal_prev_trav[key] = int(desired[key].lod)

	# Integer leaf ids: (nside << 32) | ipix — the traversal walks thousands
	# of neighbours here, no string keys on that path. Neighbours are looked
	# up once per leaf and kept for the mask pass.
	var leaves: Dictionary = {}
	for key in desired:
		var d: Dictionary = desired[key]
		leaves[(int(d.nside) << 32) | int(d.ipix)] = key
	var nbs_of: Dictionary = {}
	var edge_dirs := ["W", "E", "S", "N"]

	# ── 2:1 balance ─────────────────────────────────────────────
	var changed := true
	var guard := 0
	while changed and guard < 16:
		changed = false
		guard += 1
		for id in leaves.keys():
			if not leaves.has(id):
				continue  # split away earlier in this pass
			var nside: int = id >> 32
			var ipix: int = id & 0xFFFFFFFF
			if nside < 4:
				continue
			var nb: Dictionary
			if nbs_of.has(id):
				nb = nbs_of[id]
			else:
				nb = HEALPix.get_neighbors_nest(nside, ipix)
				nbs_of[id] = nb
			for dname in edge_dirs:
				var nip: int = nb[dname]
				if nip < 0:
					continue
				if leaves.has((nside << 32) | nip) \
						or leaves.has(((nside >> 1) << 32) | (nip >> 2)):
					continue
				# Same level and parent absent: is an older ancestor the leaf?
				var a_nside: int = nside >> 2
				var a_ipix: int = nip >> 4
				while a_nside >= 1:
					var aid := (a_nside << 32) | a_ipix
					if leaves.has(aid):
						_split_leaf(desired, leaves, aid, local_cam)
						changed = true
						break
					a_nside >>= 1
					a_ipix >>= 2

	# ── Stitch mask ─────────────────────────────────────────────
	if not is_server:
		var edge_bits := [PlanetChunk.STITCH_LEFT, PlanetChunk.STITCH_RIGHT,
				PlanetChunk.STITCH_BOTTOM, PlanetChunk.STITCH_TOP]
		for id in leaves:
			var nside: int = id >> 32
			if not PlanetChunk.edge_stitch_applies(planet_data, nside):
				continue
			var ipix: int = id & 0xFFFFFFFF
			var mine: Dictionary = desired[leaves[id]]
			var nb: Dictionary
			if nbs_of.has(id):
				nb = nbs_of[id]
			else:
				nb = HEALPix.get_neighbors_nest(nside, ipix)
			var mask := 0
			for i in edge_dirs.size():
				var nip: int = nb[edge_dirs[i]]
				if nip < 0 or leaves.has((nside << 32) | nip):
					continue
				var pid := ((nside >> 1) << 32) | (nip >> 2)
				if not leaves.has(pid):
					continue
				# The stitch bakes the parent grid at THIS chunk's resolution: it
				# only meets a neighbour drawn at that same resolution. A coarser-
				# quality neighbour (distance LOD) keeps the skirt, as before.
				if int(desired[leaves[pid]].lod) == int(mine.lod):
					mask |= edge_bits[i]
			if mask != 0:
				mine["stitch"] = mask

	# Remember the answer for the next identical traversal: masks, the leaves
	# the balance added and the ones it split away.
	_bal_prev_out.clear()
	_bal_prev_removed.clear()
	for key in desired:
		var d: Dictionary = desired[key]
		if d.has("stitch") or not _bal_prev_trav.has(key):
			_bal_prev_out[key] = d
	for key in _bal_prev_trav:
		if not desired.has(key):
			_bal_prev_removed.append(key)


## Replace leaf [param id] by its four children in both [param desired] and
## the integer index [param leaves].
func _split_leaf(desired: Dictionary, leaves: Dictionary, id: int, local_cam: Vector3) -> void:
	var key: String = leaves[id]
	var depth: int = int(desired[key].depth)
	desired.erase(key)
	leaves.erase(id)
	var nside: int = (id >> 32) << 1
	for cip in HEALPix.child_pixels(id & 0xFFFFFFFF):
		var info := _leaf_info(nside, cip, depth + 1, local_cam)
		desired[info.key] = info
		leaves[(nside << 32) | cip] = info.key


# ------------------------------------------------------------------
# Async pipeline helpers
# ------------------------------------------------------------------

## Every chunk key currently in the async pipeline — recipe_waiters,
## mesh_tasks, mesh_task_backlog, assemble_queue — as one Dictionary, built
## once for a pass that tests hundreds of keys.
func _pipeline_keys() -> Dictionary:
	var out := {}
	for mk: String in _mesh_tasks:
		out[mk] = true
	for item in _assemble_queue:
		out[String(item.info.key)] = true
	for item in _mesh_task_backlog:
		out[String(item.key)] = true
	for ek in _recipe_waiters:
		for ck in _recipe_waiters[ek]:
			out[String(ck)] = true
	return out


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
		var _st: int = int(info.get("stitch", 0))
		if _chunk_cache and _chunk_cache.has_mesh(info.key, info.lod, _st) \
				and not planet_data.chunk_cache_ineligible(info.nside, info.ipix):
			var cached_mesh := _chunk_cache.load_mesh(info.key, info.lod, _st)
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
	var _st_r: int = int(info.get("stitch", 0))
	if _chunk_cache and _chunk_cache.has_mesh(info.key, info.lod, _st_r) \
			and not planet_data.chunk_cache_ineligible(info.nside, info.ipix):
		var cached_mesh := _chunk_cache.load_mesh(info.key, info.lod, _st_r)
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
## from the real one (the tarsis_3 "3-6 km" bug). The cache version hash can't
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
		sample_nside: int = -1, vtx_spacing_m: float = 0.0) -> bool:
	var p := origin + first_vertex
	var r := p.length()
	if r <= 0.0:
		return false
	var surf: float = planet_data.crack_aware_surface_dist(p / r, sample_nside, vtx_spacing_m)
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
	var _ns: int = info.get("nside", 0)
	var _res: int = planet_data.get_resolution_for_lod(info.get("lod", 0))
	var _pitch := 0.0
	if _ns > 0 and _res > 0:
		_pitch = HEALPix.pixel_side_length(_ns, planet_data.radius) / float(_res)
	return _cached_geom_valid(Vector3(verts[0]), info.center, info.key,
			planet_data.sample_nside_for(_ns), _pitch)


## Collision variant of _cached_geom_valid: pulls the first face vertex.
func _cached_shape_valid(shape: ConcavePolygonShape3D, nside: int, ipix: int, key: String) -> bool:
	var faces := shape.get_faces()
	if faces.is_empty():
		return false
	var _pitch := 0.0
	var _cres := planet_data.collision_col_res_for(nside)
	if nside > 0 and _cres > 0:
		_pitch = HEALPix.pixel_side_length(nside, planet_data.radius) / float(_cres)
	return _cached_geom_valid(Vector3(faces[0]), _chunk_collision_origin(nside, ipix), key,
			planet_data.sample_nside_for(nside), _pitch)


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

	# Streaming : une tâche mesh ne peut pas attendre une socket, donc le chunk repart au
	# backlog tant que ses tuiles manquent. Sans source distante, toujours true.
	if not TileResidency.request_chunk_tiles(planet_data, info.nside, info.ipix,
			int(info.get("stitch", 0)) != 0):
		# any() plutôt qu'un helper : évite d'empiler deux fois le même chunk en attente.
		if not _mesh_task_backlog.any(func(it: Dictionary) -> bool: return it.key == key):
			_mesh_task_backlog.append(info)
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
	# Découpage par phase du coût de génération (phase 0 de PLANET_CHUNK_STREAMING).
	# Un Dictionary PAR TÂCHE : seul le thread de cette tâche y écrit, et le thread
	# principal ne le lit qu'après is_task_completed(). Aucun verrou nécessaire.
	var prof: Dictionary = {}
	info["grade_gen"] = _grade_generation
	info["pad_gen"] = _pad_generation
	var task_entry := {
		"task_id": -1,
		"result_ref": result_ref,
		"info": info,
		"prof": prof,
	}
	_mesh_tasks[key] = task_entry

	var stitch: int = int(info.get("stitch", 0))
	var task_id := WorkerThreadPool.add_task(
		func():
			var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(
				pd, nside, ipix, res, chunk_center, prof, stitch)
			result_ref[0] = mesh
	)
	task_entry["task_id"] = task_id


## Vide le backlog, en BORNANT les tentatives à son contenu initial : sinon un chunk remis
## en attente d'un téléchargement relancerait la boucle sans fin (phase 3 du doc).
func _drain_backlog() -> void:
	# Plafonné : évaluer la résidence d'un chunk coûte une passe sur sa tuile et ses huit
	# voisines, et le backlog peut contenir des centaines d'entrées. Il est trié du plus
	# proche au plus lointain, donc s'arrêter tôt sert d'abord ce qui est sous le joueur.
	var tries := mini(_mesh_task_backlog.size(), max_mesh_tasks * 2)
	while tries > 0 and _mesh_tasks.size() < max_mesh_tasks:
		var info: Dictionary = _mesh_task_backlog[0]
		_mesh_task_backlog.remove_at(0)
		_queue_mesh_task(info)
		tries -= 1


## Poll completed mesh tasks and move them to _assemble_queue.
func _poll_mesh_tasks() -> void:
	if _mesh_tasks.is_empty():
		# Drain backlog into mesh slots when available.
		_drain_backlog()
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
		if PropNet.prof_on:
			TerrainProfiler.commit_mesh(entry.get("prof", {}))
		var mesh: ArrayMesh = entry.result_ref[0] as ArrayMesh
		if mesh != null:
			_assemble_queue.append({"info": entry.info, "mesh": mesh})
		else:
			push_warning("[PlanetTerrain] mesh task for '%s' returned null" % key)

	for k in completed_keys:
		_mesh_tasks.erase(k)

	# Drain backlog into the freed slots.
	_drain_backlog()


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
	var _batch_t0 := Time.get_ticks_usec()
	while assembled < MAX_ASSEMBLE_PER_FRAME and not _assemble_queue.is_empty():
		if assembled > 0 and (Time.get_ticks_usec() - _batch_t0) / 1000.0 >= ASSEMBLE_BUDGET_MS:
			break
		var item: Dictionary = _assemble_queue[0]
		_assemble_queue.remove_at(0)
		var info: Dictionary = item.info
		var mesh: ArrayMesh = item.mesh
		# Built before a line profile was born under it (the mesh has the
		# terrain-hugging ribbon where the bed now goes), or before a pad
		# levelled its ground: dropped. Checked BEFORE the swap below, which
		# would otherwise take the old mesh off screen for a result we throw
		# away. A chunk still on screen is queued again right here, as a swap —
		# nothing else would: _update_terrain only builds what is not active.
		if (int(info.get("grade_gen", _grade_generation)) != _grade_generation
					and _chunk_touches_tiles(info.nside, info.ipix, _grade_reborn_tiles)) \
				or (int(info.get("pad_gen", _pad_generation)) != _pad_generation
					and _chunk_touches_tiles(info.nside, info.ipix, _pad_dirty_pixels,
						1 << planet_data.max_quadtree_depth)):
			if _active_chunks.has(info.key):
				_requeue_as_swap(_active_chunks[info.key])
			assembled += 1
			continue
		# Guard against stale entries (chunk was removed while mesh was computing).
		if _active_chunks.has(info.key):
			if not info.get("_swap", false):
				assembled += 1
				continue
			# Swap (stitch mask changed, or ground rebuilt under a new line or
			# pad): the replacement is ready, the old mesh can go.
			_remove_chunk(info.key)
			info.erase("_swap")
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
	var lead: Vector3 = vel * (LOOKAHEAD_S / UPDATE_INTERVAL)
	# A camera that has not moved a chunk's worth predicts the leaf set the
	# main traversal just built: a second full traversal for nothing (20 ms
	# in the physics step, every 0.25 s, standing still).
	if lead.length() < 50.0:
		return
	var predicted_cam := local_cam + lead
	# Nor does a prediction that has barely moved since the last one: a
	# finest chunk is ~800 m across on tarsis_3, and redoing the traversal
	# for a point a few tens of metres on cost 7-12 ms every update in a
	# moving vehicle (ClientPerf terrain_prefetch, 2026-09-24).
	if predicted_cam.distance_to(_last_prefetch_cam) < PREFETCH_MIN_MOVE_M:
		return
	_last_prefetch_cam = predicted_cam

	# Traverse from predicted position — only register chunks not already
	# active or in pipeline (don't duplicate work already queued).
	var prefetch_desired: Dictionary = {}
	for base_pix in BASE_PIXEL_COUNT:
		_traverse(1, base_pix, 0, predicted_cam, horizon_dot, prefetch_desired)

	# One snapshot, not one linear scan of the backlog per predicted key.
	var pipeline := _pipeline_keys()
	for key in prefetch_desired:
		if _active_chunks.has(key) or pipeline.has(key):
			continue
		var info: Dictionary = prefetch_desired[key]
		# File/pyramid mode has no recipe pipeline — chunks lazy-load their .r32
		# tiles on the worker thread. Warm the exact pyramid tile the mesh will
		# sample so that task doesn't stall on disk I/O, then skip the recipe path
		# (submitting recipes without a pack is what spams "Invalid Task ID").
		if planet_data.chunk_heightmaps_dir != "":
			var _ht := TileResidency.chunk_tile(planet_data, info.nside, info.ipix)
			if _ht.x >= 0:
				planet_data.load_chunk_heightmap(_ht.x, _ht.y)
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
	# Same warning as the server's collision (see _server_assemble_chunk): a
	# visual built on an ancestor tile is not persisted, but it IS shown.
	var _climbs := int(mesh.get_meta("provisional_climbs", 0))
	if _climbs > 0 and not info.get("_from_disk_cache", false):
		push_warning("[PlanetTerrain] CLIENT mesh %s lod%d built with %d vertex(es) on ancestor tiles"
				% [key, lod, _climbs] + " — the surface shown may differ from the server's collision")

	# Phased ClientPerf scopes: the heartbeat's `asm:*` totals say which part
	# of a chunk's assembly the main thread pays for.
	var _tk := _perf_begin()
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
	mi.layers = GlobalsDefs.RENDER_MASK_CELESTIAL if _chunks_on_celestial else GlobalsDefs.RENDER_MASK_LOCAL
	_chunks_node.add_child(mi)
	info["mesh_instance"] = mi
	_perf_end("asm:mesh", _tk)
	_tk = _perf_begin()

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

	_perf_end("asm:flora", _tk)
	_tk = _perf_begin()
	# ---------- Railway: rail modules + their collision boxes ----------
	# The bed itself is part of the chunk mesh/shape; the modules are instanced
	# here, one MultiMesh per stretch of track (see RailwayTrack), and stand on
	# box colliders in their own body. The transforms are computed once and
	# shared by both.
	if lod <= RailwaySettings.RAIL_MAX_LOD and planet_data.has_railways():
		var rail_xforms := RailwayTrack.module_transforms(
			planet_data, info.nside, info.ipix, chunk_center)
		if not rail_xforms.is_empty():
			var rails := Node3D.new()
			rails.name = key + "_rails"
			rails.position = chunk_center
			var corners_rail: Array = HEALPix.get_pixel_corners(info.nside, info.ipix)
			var rail_diag: float = (corners_rail[0] * planet_data.radius).distance_to(
				corners_rail[2] * planet_data.radius)
			var rail_far: float = minf(rail_diag * RailwaySettings.RAIL_VISIBILITY_DIAG,
					RailwaySettings.RAIL_FAR_VISIBILITY_M)
			for grp in RailwayTrack.build_multimeshes(rail_xforms, lod):
				var rail_mmi := MultiMeshInstance3D.new()
				rail_mmi.multimesh = grp["mm"]
				rail_mmi.position = grp["center"]
				rail_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				# One node per module tier, each visible in its own distance
				# band (see RailwayTrack.build_multimeshes): the renderer
				# picks the tier per group, the coarsest one up to the chunk's
				# own limit.
				var r_end: float = float(grp["range_end"])
				rail_mmi.visibility_range_begin = float(grp["range_begin"])
				rail_mmi.visibility_range_end = rail_far if r_end <= 0.0 else minf(r_end, rail_far)
				rail_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
				rail_mmi.layers = mi.layers
				rails.add_child(rail_mmi)
			_chunks_node.add_child(rails)
			info["railway_rails"] = rails
			if lod == 0:
				var rail_body := RailwayTrack.make_collision_body(
					planet_data, info.nside, info.ipix, chunk_center, key)
				if rail_body:
					_chunks_node.add_child(rail_body)
					info["railway_rails_col"] = rail_body

	_perf_end("asm:rails", _tk)
	_tk = _perf_begin()
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

	_perf_end("asm:zones", _tk)
	# Its own scope: road bridges AND railway viaducts are built here, on the
	# main thread, and asm:zones alone could not tell them from the point-biome
	# spawners above (2026-09-24: 100-130 ms per chunk while travelling).
	_tk = _perf_begin()
	_spawn_bridges(info)
	_perf_end("asm:bridges", _tk)
	_tk = _perf_begin()
	# Save terrain mesh to disk cache for future restarts — but ONLY if the
	# chunk's export elevation tile is actually available. If the .r32 tile was
	# missing/unreadable when the mesh was built, generate_mesh sampled the flat
	# equirect fallback, collapsing high plateaus toward sea level (the tarsis_3
	# "terrain 3-6 km below the props" bug). Persisting such a mesh makes the bad
	# bake "valid" forever, while the editor (fresh regen) and server collision
	# (already guarded in _create_chunk) stay correct. Skip the write so the
	# chunk regenerates once the tile is resident. Mirrors the server guard.
	# The ready-made road mesh (meta "roads_mesh", built by the worker) is
	# written to the cache file WITH the chunk mesh, on purpose: a cache load
	# then finds it too, and _split_road_surfaces skips the RenderingServer
	# readback for those chunks as well (~15 ms a chunk when a wave of cached
	# chunks came back at once, 2026-09-25). Cache files written before it
	# existed have no meta and take the readback path.
	var _roads_mesh: ArrayMesh = null
	if mesh and mesh.has_meta("roads_mesh"):
		_roads_mesh = mesh.get_meta("roads_mesh")
	if _chunk_cache and mesh and not info.get("_from_disk_cache", false):
		# Gate on the SAME pyramid tile the mesh sampled (coarse chunks read a
		# coarse tile, not the finest), so a good coarse bake isn't rejected.
		var _ht := TileResidency.chunk_tile(planet_data, info.nside, info.ipix)
		# has_usable_tile : sur un pack creux une tuile absente est normale, et refuser
		# d'y cacher le mesh empêcherait le cache de se remplir.
		# Nor a chunk on a line whose profile is still waiting for its tiles:
		# it carries the terrain-hugging ribbon now and the bed later.
		if _ht.x >= 0 and planet_data.has_usable_tile(_ht.x, _ht.y) \
				and _persistable(mesh) \
				and not planet_data.chunk_cache_ineligible(info.nside, info.ipix):
			_chunk_cache.save_mesh(key, lod, mesh, int(info.get("stitch", 0)))

	# The road slabs and beds on their own node (after the cache write: the
	# cached mesh keeps every surface), so they can be hidden on a coarse
	# chunk the moment a finer one covers part of its area — the coarse
	# ribbon rides the coarse relief, metres to tens of metres from the fine
	# one, and a coarse chunk lingers while its other children load.
	_perf_end("asm:cache", _tk)
	_tk = _perf_begin()
	_split_road_surfaces(info, mi, mesh, _roads_mesh)
	_active_chunks[key] = info
	_count_active_descendant(info.nside, info.ipix, 1)
	_refresh_road_visibility_around(info.nside, info.ipix)
	_perf_end("asm:roads", _tk)
	var _elapsed_ms := (Time.get_ticks_usec() - _t0) / 1000.0
	if PropNet.prof_on:
		PropNet.prof_asm_calls += 1
		PropNet.prof_asm_usec += int(_elapsed_ms * 1000.0)
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
		if _chunk_cache and not planet_data.chunk_cache_ineligible(info.nside, info.ipix):
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
				if planet_data.is_chunk_cached("hp_n%d_p%d" % [_epd, _eip]) \
						and _persistable(shape) \
						and not planet_data.chunk_cache_ineligible(info.nside, info.ipix):
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

	# The server needs bridges too: the deck carries the ONLY collision over a
	# chasm. Without it a vehicle drives along the road ribbon — which flies over
	# the gorge at rim altitude — and falls straight through.
	_spawn_bridges(info)

	_active_chunks[key] = info
	# Ce print sortait une ligne PAR CHUNK : chaque print traverse le pont OpenTelemetry
	# et coûte des millisecondes, donc il mesurait surtout son propre coût.
	if PropNet.prof_on:
		var _elapsed_ms := (Time.get_ticks_usec() - _t0) / 1000.0
		PropNet.prof_col_calls += 1
		PropNet.prof_col_usec += int(_elapsed_ms * 1000.0)


## Rattrape les travées que la planification avait dû refuser faute de tuile d'élévation.
##
## Pourquoi cela existe : warm_bridge_plans() tourne dans initialize(), et un serveur qui
## vient de redémarrer a un cache de tuiles VIDE. Sans rattrapage il imprimait
## "0 bridge plan(s) — 37 skipped" et gardait ce verdict toute la session, alors que le
## tablier porte la SEULE collision au-dessus d'un gouffre : le joueur traversait un pont
## que son client, cache chaud, lui affichait normalement.
##
## Cadencé, pas par frame : la planification lit des tuiles, et rien ne presse à 60 Hz.
func _poll_starved_bridge_plans() -> void:
	if planet_data == null or not planet_data.bridge_plans_incomplete():
		return
	var now := Time.get_ticks_msec()
	if now < _next_bridge_retry_ms:
		return
	_next_bridge_retry_ms = now + BRIDGE_RETRY_INTERVAL_MS
	if planet_data.retry_starved_bridge_plans().is_empty():
		return
	# Un plan né en retard ne se pose pas tout seul : les chunks qui le possèdent sont déjà
	# résidents et ne rappelleront pas _spawn_bridges. On repasse dessus — l'appel est
	# idempotent (il saute les travées dont le tablier existe déjà).
	for key: String in _server_collision_chunks.keys():
		var ipix := _parse_ipix_from_key(key)
		if ipix < 0:
			continue
		var nside := _parse_nside_from_key(key)
		if nside <= 0:
			nside = planet_data.export_nside
		_spawn_bridges({"key": key, "nside": nside, "ipix": ipix, "lod": 0})


## Rattrape les lignes profilées (voies ferrées, routes à pente bornée) que warm_grade_profiles()
## avait dû laisser sans profil faute de tuiles.
##
## Pourquoi cela existe : une voie de 600 km (tarsis_3) traverse ~190 tuiles d'export, à
## ~150 ms la tuile sur le réseau — le préchargement de 5 s n'en ramène qu'un tiers, et
## le verdict « 0 profil » tenait toute la session : le lit suivait le terrain et la
## voie s'enfonçait dans la colline là où le profil aurait creusé un tunnel. Ici, une
## fois les tuiles arrivées (elles sont en file sur le fil de streaming), le profil naît
## et les chunks déjà bâtis sur la ligne sont refaits : leur lit, leurs tranchées et
## leurs tunnels sont cuits DANS le mesh et la collision, pas posés à côté.
##
## Cadencé comme les ponts, des deux côtés : le client cuit le lit dans ses meshes, le
## serveur dans sa collision.
func _poll_starved_grade_profiles() -> void:
	if planet_data == null or not planet_data.grade_profiles_incomplete():
		return
	var now := Time.get_ticks_msec()
	if now < _next_grade_retry_ms:
		return
	_next_grade_retry_ms = now + BRIDGE_RETRY_INTERVAL_MS
	var born := planet_data.retry_starved_grade_profiles()
	if born.is_empty():
		return
	var tiles := {}
	for fid: int in born:
		tiles.merge(planet_data.grade_line_export_tiles(fid))
	_grade_reborn_tiles.merge(tiles)
	_grade_generation += 1
	_rebuild_chunks_on_tiles(tiles)


## Does chunk (nside, ipix) stand on one of [param tiles]?
##
## [param tiles_nside] is the level the keys of [param tiles] are stated at —
## the export level by default (a line's tiles), or the finest level for the
## pixels a terrain pad reaches.
func _chunk_touches_tiles(nside: int, ipix: int, tiles: Dictionary,
		tiles_nside: int = -1) -> bool:
	if tiles.is_empty() or nside <= 0 or ipix < 0:
		return false
	var export_nside: int = tiles_nside if tiles_nside > 0 else planet_data.export_nside
	if nside >= export_nside:
		var e := ipix
		var ns := nside
		while ns > export_nside:
			e >>= 2
			ns >>= 1
		return tiles.has(e)
	var shift := 0
	var ns := nside
	while ns < export_nside:
		shift += 2
		ns <<= 1
	for t: int in tiles:
		if (t >> shift) == ipix:
			return true
	return false


## Throw away and rebuild every resident chunk standing on [param tiles]:
## the client's visual chunks (removed; _update_terrain queues them again),
## the server's collision chunks (unloaded; the residency reloads them) and
## the tasks in flight on either side (their result is dropped, then
## queued again). Idempotent for anything not on the tiles.
func _rebuild_chunks_on_tiles(tiles: Dictionary, tiles_nside: int = -1,
		why: String = "d'une ligne profilée née en rattrapage") -> void:
	if tiles.is_empty():
		return
	var n := 0
	# Which grids the rebuilt chunks were on. A pad is only CARVED on
	# hp_nside == 1 << max_quadtree_depth (GradeBed.carve_enabled); anything
	# coarser only gets the clamp, so this line is what tells a "the ground is
	# still in my building" report apart: LOD and nside are independent here
	# (lod comes from camera distance, nside from the quadtree depth), so
	# being on LOD 0 does not mean being on the grid the pad is cut into.
	var by_nside := {}
	if is_server:
		for key: String in _server_collision_chunks.keys().duplicate():
			if _chunk_touches_tiles(_parse_nside_from_key(key), _parse_ipix_from_key(key),
					tiles, tiles_nside):
				by_nside[_parse_nside_from_key(key)] = int(by_nside.get(_parse_nside_from_key(key), 0)) + 1
				_unload_chunk(key)
				n += 1
		for key: String in _server_chunk_tasks.keys():
			if _chunk_touches_tiles(_parse_nside_from_key(key), _parse_ipix_from_key(key),
					tiles, tiles_nside):
				_server_chunk_tasks[key]["evicted"] = true
				_server_chunk_tasks[key]["reload"] = true
				n += 1
		_apply_residency()
	else:
		# Rebuilt as a SWAP, not removed: removing took the mesh, the
		# vegetation, the rails and the collision off screen at once, and the
		# ground under the player stayed a hole until the rebuild came back —
		# seconds on a rail chunk. The old chunk stays until its replacement
		# is assembled.
		for key: String in _active_chunks.keys().duplicate():
			var info: Dictionary = _active_chunks[key]
			if _chunk_touches_tiles(int(info.get("nside", 0)), int(info.get("ipix", -1)),
					tiles, tiles_nside):
				var k := "n%d/lod%d" % [int(info.get("nside", 0)), int(info.get("lod", -1))]
				by_nside[k] = int(by_nside.get(k, 0)) + 1
				_requeue_as_swap(info)
				n += 1
		# Tasks already running were stamped with the old generation and are
		# dropped at assembly; the backlog is stamped when it is submitted.
	print("[PlanetTerrain] %d chunk(s) de '%s' refait(s) sur les %d tuile(s) %s %s — grille la plus fine : n%d"
			% [n, planet_data.planet_name, tiles.size(), why, str(by_nside),
			1 << planet_data.max_quadtree_depth])


## Queue a rebuild of the visual chunk [param info] that keeps it on screen
## until the new mesh is assembled (see the swap in the assembly loop).
func _requeue_as_swap(info: Dictionary) -> void:
	var key: String = info.key
	# A build of this key already waiting was queued as a plain one: at
	# assembly it would be skipped as a duplicate of the chunk on screen, and
	# the chunk would keep its old ground for good.
	for item: Dictionary in _mesh_task_backlog:
		if item.key == key:
			item["_swap"] = true
	for ek in _recipe_waiters:
		if _recipe_waiters[ek].has(key):
			_recipe_waiters[ek][key]["_swap"] = true
	_try_create_or_defer({
		"key": key,
		"nside": int(info.nside),
		"ipix": int(info.ipix),
		"depth": int(info.get("depth", 0)),
		"center": info.center,
		"lod": int(info.lod),
		"stitch": int(info.get("stitch", 0)),
		"_swap": true,
	})


# ------------------------------------------------------------------
# Terrain pads (levelled platforms under buildings)
# ------------------------------------------------------------------

## Register or move the pad [param rec] and rebuild the chunks it reaches.
## Called by TerrainPad, which is the only thing that builds a record.
func register_terrain_pad(rec: Dictionary) -> void:
	if planet_data == null:
		return
	_pads_changed(planet_data.register_pad(rec))


## Drop the pad [param uuid] and give its ground back its natural relief.
func unregister_terrain_pad(uuid: String) -> void:
	if planet_data == null:
		return
	_pads_changed(planet_data.unregister_pad(uuid))


## The altitude a pad levels the ground to, NAN while its tiles are unreadable.
func terrain_pad_altitude(rec: Dictionary) -> float:
	return planet_data.pad_altitude(rec) if planet_data != null else NAN


## How much height that pad's talus has to absorb.
func terrain_pad_height_span(rec: Dictionary) -> float:
	return planet_data.pad_height_span(rec) if planet_data != null else NAN


## Register every TerrainPad already standing on this body. The buildings are
## siblings of this node under the Planet root, so the walk starts there.
func warm_terrain_pads() -> void:
	if planet_data == null:
		return
	var root: Node = get_parent() if get_parent() != null else self
	var n := _register_pads_under(root)
	if n > 0:
		print("[PlanetTerrain] %d pad(s) de bâtiment enregistré(s) sur '%s'"
				% [n, planet_data.planet_name])


func _register_pads_under(node: Node) -> int:
	var n := 0
	for child: Node in node.get_children():
		if child is PlanetTerrain:
			continue  # the chunk tree, never a building
		if child is TerrainPad:
			(child as TerrainPad).register_now()
			n += 1
		n += _register_pads_under(child)
	return n


## Rattrape les pads laissés de côté faute de tuile d'élévation lisible.
##
## Même raison que pour les lignes profilées : échantillonner le relief à
## travers une tuile absente retombe sur la carte globale plate, et le client
## et le serveur aplaniraient le sol à deux altitudes différentes — le bâtiment
## se retrouverait posé sur l'une des deux. Le pad attend donc, et le terrain
## sous lui reste naturel jusqu'à ce que ses tuiles soient là.
func _poll_starved_pads() -> void:
	if planet_data == null or not planet_data.pads_incomplete():
		return
	var now := Time.get_ticks_msec()
	if now < _next_pad_retry_ms:
		return
	_next_pad_retry_ms = now + BRIDGE_RETRY_INTERVAL_MS
	_pads_changed(planet_data.retry_starved_pads())


## A pad appeared, moved or went: [param dirty] holds the finest-level pixels
## whose chunks no longer describe the ground. Throw them away on whichever
## side we are — the client's meshes, the server's collision — and tell the NPC
## navigation its baked boxes over that ground are stale.
func _pads_changed(dirty: Dictionary) -> void:
	if dirty.is_empty() or planet_data == null:
		return
	_pad_dirty_pixels.merge(dirty)
	# Tasks already in flight were started on the old ground; stamping a new
	# generation is what drops their result instead of drawing it.
	_pad_generation += 1
	if not _initialized:
		return  # warm-up: no chunk has been built yet
	var nside: int = 1 << planet_data.max_quadtree_depth
	_rebuild_chunks_on_tiles(dirty, nside, "d'un pad de bâtiment")
	_invalidate_nav_over(dirty, nside)


## The NPC navigation bakes its boxes from the terrain collision, so ground
## that just moved leaves stale boxes behind — an NPC would walk the slope the
## pad replaced. One invalidation over the whole dirty area, not one per pixel.
func _invalidate_nav_over(dirty: Dictionary, nside: int) -> void:
	if not is_server or dirty.is_empty():
		return
	var c := Vector3.ZERO
	for ip: int in dirty:
		c += HEALPix.pix2vec_nest(nside, ip)
	if c.length_squared() < 1e-12:
		return
	var centre := global_transform * (c.normalized() * planet_data.radius)
	var side := HEALPix.pixel_side_length(nside, planet_data.radius)
	# Half the diagonal of the dirty block, plus a pixel of slack.
	var reach := side * (0.5 * sqrt(float(dirty.size())) + 1.0)
	NpcNavCache.invalidate_around_all(centre, reach)


## Spawn a bridge for every road/chasm crossing this chunk owns.
##
## Ownership is by span MIDPOINT, resolved at EXPORT_NSIDE — deliberately not at
## the chunk's own leaf nside.
##
## The leaf nside is distance-driven, and that made a bridge a function of where
## the camera stood, with two failures a driver actually feels:
##   · _update_terrain keeps a stale coarse parent alive while its finer
##     children are still in the pipeline, so the same span was owned by BOTH
##     for a while — two exactly coincident deck colliders under the wheels,
##     which is contact chatter and lost grip, not a cosmetic double;
##   · a chunk whose LOD merely changed is removed and re-queued, which freed
##     the deck's collision for as long as the rebuild took. On the server that
##     is a hole in the bridge.
## export_nside is fixed, so a span has ONE owning pixel forever, the client and
## the server agree on it without replicating anything, and the deck is built
## once. The chunk only REFERENCES it: the node is freed when the last chunk
## resolving to that pixel goes away.
func _spawn_bridges(info: Dictionary) -> void:
	if planet_data == null or int(info.get("lod", 99)) > BridgeSpawner.MAX_LOD:
		return
	# Road bridges over the crack field, plus railway viaducts over valleys:
	# same span shape, same ownership rule, same spawner.
	var eipix := _get_export_ipix(info)
	if eipix < 0:
		return
	var mine := planet_data.spans_owned_by_export_pixel(eipix)
	if mine.is_empty():
		return
	var chunk_key: String = info.get("key", "")
	for s in mine:
		var sk: String = _bridge_span_key(s)
		if not _bridge_owners.has(sk):
			_bridge_owners[sk] = {}
		(_bridge_owners[sk] as Dictionary)[chunk_key] = true
		_bridge_orphan_since.erase(sk)
		if _bridge_nodes.has(sk):
			continue
		# The server builds at once: the deck is its collision. So does the
		# client for a deck near the camera.
		if not is_server and _bridge_far_from_camera(s):
			if not _bridge_tasks.has(sk):
				_bridge_spawn_queue[sk] = s
			continue
		_build_bridge(sk, s)


## Build the deck of span [param s] under key [param sk].
func _build_bridge(sk: String, s: Dictionary) -> void:
	_bridge_spawn_queue.erase(sk)
	# No height tile is passed: the deck resolves its own at export_nside
	# from the span midpoint, so its altitude cannot depend on which chunk
	# happened to ask for it (see BridgeSpawner.spawn).
	var _tk := _perf_begin()
	var b := BridgeSpawner.spawn(planet_data, s)
	if b:
		_chunks_node.add_child(b)
		_bridge_nodes[sk] = b
	_perf_end("asm:bridge_spawn", _tk)


func _bridge_far_from_camera(s: Dictionary) -> bool:
	var mid: Vector3 = (s["mid_dir"] as Vector3) * planet_data.radius
	return mid.distance_to(_last_local_cam) > BRIDGE_SPAWN_NOW_M


## Collect the decks whose geometry is ready, then hand the nearest queued
## spans to the workers. A deck whose chunks all went away meanwhile, or that
## was built in line in the meantime, is dropped.
func _drain_bridge_spawn_queue() -> void:
	for sk: String in _bridge_tasks.keys():
		var t: Dictionary = _bridge_tasks[sk]
		if not WorkerThreadPool.is_task_completed(int(t["task_id"])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(t["task_id"]))
		_bridge_tasks.erase(sk)
		if (_bridge_owners.get(sk, {}) as Dictionary).is_empty() or _bridge_nodes.has(sk):
			continue
		var _tk := _perf_begin()
		var b := BridgeSpawner.instantiate(t["prep"], t["result"][0])
		if b:
			_chunks_node.add_child(b)
			_bridge_nodes[sk] = b
		_perf_end("asm:bridge_instantiate", _tk)
	if _bridge_spawn_queue.is_empty() or _bridge_tasks.size() >= BRIDGE_MAX_TASKS:
		return
	var cam_dir := _last_local_cam.normalized()
	var keys := _bridge_spawn_queue.keys()
	keys.sort_custom(func(a: String, b: String) -> bool:
		return (_bridge_spawn_queue[a]["mid_dir"] as Vector3).distance_squared_to(cam_dir) \
				< (_bridge_spawn_queue[b]["mid_dir"] as Vector3).distance_squared_to(cam_dir))
	for sk: String in keys:
		if _bridge_tasks.size() >= BRIDGE_MAX_TASKS:
			break
		var s: Dictionary = _bridge_spawn_queue[sk]
		_bridge_spawn_queue.erase(sk)
		if (_bridge_owners.get(sk, {}) as Dictionary).is_empty() or _bridge_nodes.has(sk):
			continue
		var _tk := _perf_begin()
		var prep := BridgeSpawner.prepare(planet_data, s)
		_perf_end("asm:bridge_prepare", _tk)
		if prep.is_empty():
			continue
		var result: Array = [{}]
		var pd := planet_data
		var tid := WorkerThreadPool.add_task(func() -> void:
			result[0] = BridgeSpawner.build_geo(pd, prep))
		_bridge_tasks[sk] = {"task_id": tid, "prep": prep, "result": result}


## Stable identity of a span, independent of the chunk that reported it.
static func _bridge_span_key(span: Dictionary) -> String:
	return PlanetData.bridge_span_key(span)


## Drop [param chunk_key]'s claim on every bridge. Nothing is freed here — a
## bridge that loses its last owner is only MARKED, and _sweep_orphan_bridges
## frees it once the grace period has passed without anyone claiming it back.
func _release_bridges(chunk_key: String) -> void:
	if _bridge_owners.is_empty():
		return
	var now := Time.get_ticks_msec()
	for sk in _bridge_owners:
		var owners: Dictionary = _bridge_owners[sk]
		if not owners.has(chunk_key):
			continue
		owners.erase(chunk_key)
		if owners.is_empty() and not _bridge_orphan_since.has(sk):
			_bridge_orphan_since[sk] = now


## Free the bridges nothing has referenced for BRIDGE_GRACE_MS.
func _sweep_orphan_bridges() -> void:
	if _bridge_orphan_since.is_empty():
		return
	var now := Time.get_ticks_msec()
	for sk in _bridge_orphan_since.keys():
		if now - int(_bridge_orphan_since[sk]) < BRIDGE_GRACE_MS:
			continue
		_bridge_orphan_since.erase(sk)
		_bridge_owners.erase(sk)
		_bridge_spawn_queue.erase(sk)
		var node: Node3D = _bridge_nodes.get(sk, null)
		if node:
			node.queue_free()
		_bridge_nodes.erase(sk)


## Move the road surfaces of [param mesh] (meta "road_surfaces", set by
## PlanetChunk.generate_mesh) to a MeshInstance3D of their own under
## [param mi], kept in info["roads_mi"]. The chunk mesh itself is left whole.
func _split_road_surfaces(info: Dictionary, mi: MeshInstance3D, mesh: ArrayMesh,
		prebuilt: ArrayMesh = null) -> void:
	assert(mi.mesh == mesh)
	var road_surfaces: PackedInt32Array = mesh.get_meta("road_surfaces", PackedInt32Array())
	if road_surfaces.is_empty():
		return
	var sorted := Array(road_surfaces)
	sorted.sort()
	# [param prebuilt]: the same surfaces, already committed to their own mesh
	# by the worker (PlanetChunk, meta "roads_mesh"). Only a mesh loaded from
	# the disk cache still has to be read back and re-uploaded here.
	var roads_mesh := prebuilt
	if roads_mesh == null or roads_mesh.get_surface_count() != sorted.size():
		roads_mesh = ArrayMesh.new()
		for si: int in sorted:
			if si < 0 or si >= mesh.get_surface_count():
				continue
			var arrays := mesh.surface_get_arrays(si)
			var out_si := roads_mesh.get_surface_count()
			roads_mesh.add_surface_from_arrays(mesh.surface_get_primitive_type(si), arrays)
			roads_mesh.surface_set_material(out_si, mesh.surface_get_material(si))
	# Then out of the chunk mesh, highest index first. This mesh is ours: the
	# worker's fresh result, or a cache load with CACHE_MODE_IGNORE — and the
	# cache file was written with every surface, just above.
	sorted.reverse()
	for si: int in sorted:
		if si >= 0 and si < mesh.get_surface_count():
			mesh.surface_remove(si)
	mesh.remove_meta("road_surfaces")
	if mesh.has_meta("roads_mesh"):
		mesh.remove_meta("roads_mesh")
	var roads_mi := MeshInstance3D.new()
	roads_mi.name = String(info.key) + "_roads"
	roads_mi.mesh = roads_mesh
	roads_mi.layers = mi.layers
	roads_mi.cast_shadow = mi.cast_shadow
	# Not drawn past RoadTerrain.FAR_VISIBILITY_M from the chunk's centre,
	# like the rail modules. A flat cap, not a chunk-diagonal multiple: a
	# LOD-0 chunk lives up to 5 km away and its road must not vanish before
	# the chunk itself changes LOD.
	roads_mi.visibility_range_end = RoadTerrain.FAR_VISIBILITY_M
	roads_mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	mi.add_child(roads_mi)
	info["roads_mi"] = roads_mi


## Number of ACTIVE chunks strictly finer than each ancestor pixel, keyed
## (nside << 32) | ipix, maintained by _assemble_visual_chunk / _remove_chunk
## — so "does a finer chunk cover part of this one" is one lookup, not a
## walk of 340 descendant keys per chunk event.
var _active_desc_count: Dictionary = {}


## Add [param delta] to the finer-active count of every ancestor of (nside, ipix).
func _count_active_descendant(nside: int, ipix: int, delta: int) -> void:
	var ns := nside >> 1
	var ip := ipix >> 2
	while ns >= 1:
		var id := (ns << 32) | ip
		var n := int(_active_desc_count.get(id, 0)) + delta
		if n <= 0:
			_active_desc_count.erase(id)
		else:
			_active_desc_count[id] = n
		if ns == 1:
			break
		ns >>= 1
		ip >>= 2


## Show the roads (slabs, beds, rail modules) of an active chunk only while no
## finer active chunk covers part of it: the fine chunk's roads ride the fine
## relief, the coarse chunk's ride the coarse one, and both drawn at once is
## the "road floating above / sunk under the ground" of a lingering coarse
## chunk. Called for (nside, ipix) and every ancestor whenever a chunk is
## assembled or removed there.
func _refresh_road_visibility_around(nside: int, ipix: int) -> void:
	var ns := nside
	var ip := ipix
	while ns >= 1:
		var key := _chunk_key_hp(ns, ip)
		if _active_chunks.has(key):
			var info: Dictionary = _active_chunks[key]
			var show := int(_active_desc_count.get((ns << 32) | ip, 0)) == 0
			var roads_mi: Variant = info.get("roads_mi")
			if roads_mi != null and is_instance_valid(roads_mi):
				(roads_mi as MeshInstance3D).visible = show
			var rails: Variant = info.get("railway_rails")
			if rails != null and is_instance_valid(rails):
				(rails as Node3D).visible = show
		if ns == 1:
			break
		ns >>= 1
		ip >>= 2


func _remove_chunk(key: String) -> void:
	if not _active_chunks.has(key):
		return
	var info: Dictionary = _active_chunks[key]
	_release_bridges(key)
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
	if info.has("railway_rails") and info.railway_rails:
		info.railway_rails.queue_free()
	if info.has("railway_rails_col") and info.railway_rails_col:
		info.railway_rails_col.queue_free()
	if info.has("collision_shape") and info.collision_shape:
		info.collision_shape.queue_free()
	_active_chunks.erase(key)
	# A coarser chunk over this area may be showing again (its finer cover is
	# gone): give it its roads back — or keep them hidden if another finer
	# chunk remains. The roads node dies with mesh_instance (its child).
	if not is_server and int(info.get("nside", 0)) > 0 and info.has("mesh_instance"):
		_count_active_descendant(int(info.nside), int(info.ipix), -1)
		_refresh_road_visibility_around(int(info.nside), int(info.ipix))


func _clear_all_chunks() -> void:
	for key in _active_chunks.keys():
		_remove_chunk(key)
	_node_geom.clear()


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


## Map a chunk's runtime ipix to the export-level ipix by walking the HEALPix
## quadtree until nside matches planet_data.export_nside.
##
## Walks DOWN as well as up: a chunk coarser than export_nside covers four (or
## more) export pixels, and taking its FIRST child is what _try_create_or_defer
## already does to pick a recipe. Callers that only need "one export pixel this
## chunk belongs to" — bridge ownership does — get a stable answer either way.
func _get_export_ipix(info: Dictionary) -> int:
	var eipix: int = info.get("ipix", -1)
	var ns: int = info.get("nside", 0)
	if eipix < 0 or ns <= 0:
		return -1
	while ns > planet_data.export_nside:
		eipix = HEALPix.parent_pixel(eipix)
		ns /= 2
	while ns < planet_data.export_nside:
		eipix *= 4
		ns *= 2
	return eipix


## Pyramid tile [ipix, nside] a chunk actually samples its heights from — mirrors
## the logic in PlanetChunk (finer→walk up to nside_max; own level if baked).
## Returns ipix == -1 when the chunk is coarser than the coarsest baked level
## (per-vertex resolution, no single tile to gate a cache write on).
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
	# Dans l'éditeur, get_viewport().get_camera_3d() ne rend pas la caméra de la vue 3D :
	# c'est EditorInterface qui la porte. Sans cela le quadtree n'aurait aucune référence
	# et l'éditeur n'afficherait rien.
	if Engine.is_editor_hint():
		var ed_local := _get_editor_camera_local()
		return Vector3.INF if ed_local == Vector3.INF else global_position + ed_local
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


# -- Editor flight ---------------------------------------------------------------------------------
#
# Fly the editor viewport as if it were over the body: local up always world up, forward following
# the curvature. The camera cannot be driven (see Planet's editor-flight section), so the BODY is
# moved under it instead — and the trick is that only the camera's DELTA matters, so it works whatever
# the editor does with the camera.
#
# Each frame:
#   * the body centre goes on the world -Y axis under the camera, at radius + altitude. The local up
#     where the camera stands is then world +Y BY CONSTRUCTION, wherever the editor put it;
#   * the body is turned so the tracked ground point sits under the camera;
#   * the camera's movement since the last frame is split: its vertical part changes the altitude, its
#     horizontal part ROLLS the tracked point across the surface by distance / (radius + altitude).

## Fly the editor camera in this body's frame instead of the world's. EDITOR ONLY: the body's
## transform is driven while this is on, and never saved (see Planet.editor_set_flight_transform).
##
## Normally toggled from the "Fly in planet frame" button in the 3D viewport toolbar rather than
## here — the toolbar keeps it reachable while you have the object you are PLACING selected, which
## is the whole point. This export is the state the button reads and writes.
@export var editor_planet_flight: bool = false

## Ground point under the camera, as a unit direction in the BODY's own frame.
var _flight_dir: Vector3 = Vector3.UP
## Height of the camera above the reference sphere, in metres.
var _flight_alt: float = 0.0
## Camera world position last frame; INF means "not seeded yet".
var _flight_last_cam: Vector3 = Vector3.INF
var _flight_was_on: bool = false

## A camera move larger than this fraction of (radius + altitude) is a TELEPORT, not flying — pressing
## F to frame a node, or typing coordinates. Rolling the surface by it would fling you across the
## globe, so the tracked point is re-seeded from where the camera actually is instead.
const FLIGHT_JUMP_FRACTION: float = 0.05

## Height above the GROUND at which the "Go to" buttons put the camera, in metres.
const GOTO_ALTITUDE: float = 200.0

## Drive the body under the editor camera. Called every frame from _physics_process, editor only.
func _editor_flight_step() -> void:
	var planet := get_parent() as Planet
	if planet == null or planet_data == null:
		return
	if not editor_planet_flight:
		if _flight_was_on:
			_flight_was_on = false
			_flight_last_cam = Vector3.INF
			planet.editor_end_flight()
		return

	var cam := _editor_camera_world()
	if cam == Vector3.INF:
		return
	var radius: float = planet_data.radius

	# Seeding, and re-seeding after a teleport: keep the camera exactly where it is and read the
	# ground point and altitude from the body as it stands right now, so switching the mode on (or
	# pressing F) never moves the view.
	var jumped: bool = _flight_last_cam != Vector3.INF 		and _flight_last_cam.distance_to(cam) > (radius + _flight_alt) * FLIGHT_JUMP_FRACTION
	if not _flight_was_on or _flight_last_cam == Vector3.INF or jumped:
		var to_cam: Vector3 = cam - planet.global_position
		var dist: float = to_cam.length()
		if dist < 1.0:
			return  # inside the centre: no direction to read
		_flight_alt = dist - radius
		_flight_dir = (planet.global_transform.basis.inverse() * (to_cam / dist)).normalized()
		_flight_was_on = true
		_flight_last_cam = cam
		_editor_flight_place(planet, cam, radius)
		return

	var move: Vector3 = cam - _flight_last_cam
	_flight_last_cam = cam

	# Vertical: straight onto the altitude. Clamped well above the centre so radius + altitude can
	# never reach zero, which would make the roll angle explode.
	_flight_alt = maxf(_flight_alt + move.y, -radius * 0.5)

	# Horizontal: roll the tracked point along the surface by the arc the camera just covered.
	var flat := Vector3(move.x, 0.0, move.z)
	var span: float = flat.length()
	if span > 0.0:
		var angle: float = span / maxf(radius + _flight_alt, 1.0)
		# Done in WORLD space and converted back, rather than reasoning about local axes: the tracked
		# point is at world +Y by construction, so rotating THAT is unambiguous.
		var axis: Vector3 = Vector3.UP.cross(flat / span)
		if axis.length_squared() > 0.000001:
			var moved: Vector3 = Basis(axis.normalized(), angle) * Vector3.UP
			_flight_dir = (planet.global_transform.basis.inverse() * moved).normalized()

	_editor_flight_place(planet, cam, radius)

## Put the body where the camera stands over `_flight_dir` at `_flight_alt`.
func _editor_flight_place(planet: Planet, cam: Vector3, radius: float) -> void:
	# Rotation taking the tracked ground point to world +Y, then the centre straight down from the
	# camera by radius + altitude. Both together put the camera over that point, upright.
	var basis := Basis(Quaternion(_flight_dir, Vector3.UP))
	var origin: Vector3 = cam - Vector3.UP * (radius + _flight_alt)
	planet.editor_set_flight_transform(Transform3D(basis, origin))

## The editor viewport camera in WORLD space. _get_editor_camera_local() answers relative to this
## body, which is no use here — flight is what moves the body.
func _editor_camera_world() -> Vector3:
	var local := _get_editor_camera_local()
	return Vector3.INF if local == Vector3.INF else global_position + local

