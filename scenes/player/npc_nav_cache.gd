class_name NpcNavCache
extends Node3D
## Server-side registry of SHARED navigation-mesh boxes for NPCs — one cache per world root (planet).
##
## Before this existed every NPC baked its own private navmesh (map + region + frame), re-baked it every
## 18 m of travel, and each bake parsed the WHOLE planet subtree synchronously on the main thread. Fifty
## walking NPCs spawned on one spot meant fifty parses, fifty giant 0.1 m Recast bakes, and ~5 re-bakes a
## second for ever: the worker pool never caught up and the server sat at 5 TPS.
##
## Here a bake is a TILE of a lattice (LATTICE_XZ m square cells in a sector frame), NOT placed around any
## NPC or goal — that is what makes it shareable: every NPC standing in a cell paths on that cell's tile.
## Fifty NPCs on one spot = one bake. The tiles of a BLOCK of cells (BLOCK_CELLS x BLOCK_CELLS) live on ONE
## navigation map, cut flush at the cell boundaries (`border_size`) so the server connects neighbouring
## tiles through `edge_connection_margin`: a route can then go AROUND a building through the next cells —
## with one map per tile, `map_get_path` stopped at the tile edge and 26 of 93 NPCs ended "6 detours
## without reaching goal" against the depot's spawn building. Tiles expire (TTL), can be invalidated by
## world events (a truck parking), and are freed once nobody has used them for a while.
##
## Frames and nav space. The navigation server cannot work at this game's coordinates: it connects
## polygons by quantising each vertex into a PointKey — floor(pos / cell_size) packed into a 21-bit signed
## bitfield — which saturates around ±104 km at cell_size 0.1. The planet sits ~1e10 out, so every key
## would overflow, no two polygons would ever share an edge, and the mesh would degenerate into
## disconnected islands. Each box therefore has its own FRAME (a Node3D child of this cache, so it follows
## the planet): origin at the box centre on the ground, +Y along the local up (radial on a planet, because
## Recast hard-codes +Y as up in whatever frame it bakes in — the planet's own +Y is its axis and would
## rasterise flat ground as a slope past agent_max_slope). The mesh is baked in that frame, the region is
## registered at IDENTITY so it LIVES near the origin, and every query converts world <-> frame.
##
## Source geometry. NavigationServer3D.parse_source_geometry_data is locked to the main thread by the
## engine (the SceneTree is not thread-safe) and walks the whole planet. The default `query` collector
## replaces it: one physics broadphase query (intersect_shape over the box, cheap) selects the colliders
## that actually touch the box, and their faces are extracted on a WorkerThreadPool task straight into a
## NavigationMeshSourceGeometryData3D (RWLock-guarded, thread-safe). Recast then only ever sees the box.
## `[npc] nav_parse_mode=tree` in server.ini switches back to the engine parser for A/B measurement.
##
## Bake parameters. cell_size / cell_height / agent_radius decide whether DOORWAYS bake open, and standard
## apartment doors are 1.0 m wide x 2.0 m tall, so the margins are thin: Recast erodes
## ceil(agent_radius / cell_size) voxels of walkable space off EACH side of a door; 0.3 / 0.1 erodes 0.3 m
## per side and leaves a 0.4 m = 4-cell strip, which survives any sub-voxel grid phase (apartment units
## tile every 3.16 m, a non-integer number of voxels). The mesh floats ~2*cell_height above the floor and
## that headroom is taken off every opening: at cell_height 0.1 a door only needs to be 1.9 m tall.
## agent_radius 0.3 still covers the real capsule (0.265 m) — do NOT shrink it to widen doors.

signal box_baked(box: NavBox)

const _G := preload("res://scenes/globals/globals.gd")

## XZ half-extent (m) of a tile: 72 x 72 m of ground per bake, a fraction of a second of Recast.
const HALF: float = 36.0
## Tiles on one map are jointive, so a point anywhere in its cell is usable: no inner margin. Kept as a
## named constant because the NPC side reads it for its fast-path test.
const INNER: float = 0.0
## Baked margin (m) around a tile, cut away by Recast's `border_size` so the published mesh stops EXACTLY
## at the cell boundary instead of agent_radius short of it (which would leave a 0.6 m gap between two
## tiles, wider than edge_connection_margin). Must be a multiple of CELL.
const BORDER: float = 1.0
## Free edges of neighbouring tiles closer than this (m) are connected by the map (>= 2 * CELL).
const EDGE_CONNECTION_MARGIN: float = 0.3
## Tiles sit on a LATTICE: cell centres every LATTICE_XZ m horizontally (= a tile's width, so tiles are
## jointive and any point maps to ONE cell). One tile per cell at most: a depot of 220 m is ~16 tiles
## whatever the walkers do — boxes centred "ahead of the requester" instead overlapped at random and
## never stopped multiplying (70+ for 47 NPCs). There is NO vertical lattice: a tile spans ±VHALF around
## the ground height of its first requester. Recast is insensitive to empty air (spans exist only where
## there is geometry), and a slope cannot be sliced into connected layers — Recast erodes agent_radius
## at a heightfield's bounds, so tiles stacked vertically met with a 0.6 m gap and every NPC walking
## down the depot's hillside was stopped at the layer boundary.
const LATTICE_XZ: float = 2.0 * HALF
const VHALF: float = 64.0
## Cells per side of a BLOCK — the tiles of one block share one navigation map, so this bounds both how
## far a route can plan (5 cells = 360 m, several buildings) and the map's sync cost (edge connection
## is quadratic in free edges: keep blocks small).
const BLOCK_CELLS: int = 5
## The lattice lives in a SECTOR frame (+Y radial at the sector origin). A request further than this
## (m) from every sector origin opens a new sector: at 3 km the ground drops 0.7 m below the sector's
## plane, still well inside a cell's vertical slack; further out the lattice would float off the hill.
const SECTOR_RADIUS: float = 3000.0
## When an NPC is this close (m) to its cell's edge AND heading out through it, the neighbour cell's
## tile is created and queued in advance, so the bake has usually landed by the time it crosses. The
## cells along the straight line to the goal (within the block) are prefetched the same way, so the map
## holds the whole corridor a route may need.
const PREFETCH_MARGIN: float = 10.0
const PREFETCH_MAX_CELLS: int = 6
## Vertical slack (m) inside ±VHALF a point must keep to count as covered by a tile.
const V_MARGIN: float = 2.0
const CELL: float = 0.1
const AGENT_RADIUS: float = 0.3
const AGENT_HEIGHT: float = 1.8
const AGENT_MAX_CLIMB: float = 0.4
const AGENT_MAX_SLOPE: float = 45.0
## Group the `tree` parser traverses for source geometry. The root is added to it by for_root().
const SOURCE_GROUP: StringName = &"npc_nav_source"
## Physics layers a bake sees: world | vehicle | prop — everything solid EXCEPT the player layer, which
## must stay out or every NPC (and every player standing nearby) would bake its own capsule in as an
## obstacle. Same set the line-of-sight rays treat as solid.
const COLLISION_MASK: int = _G.MASK_OBSTACLE
## A box is never re-baked more often than this (s): the stuck-recovery ladder and a fleet of trucks
## parking must not turn into a bake storm.
const REBAKE_MIN_INTERVAL_S: float = 5.0
## A bake that produced NO polygons is retried after this (s) instead of the full TTL: the first box
## of a session is typically requested before the terrain chunks under the spawn are resident, and
## an NPC would otherwise stand on an empty mesh for two minutes.
const EMPTY_RETRY_S: float = 5.0
const CACHE_NODE_NAME: String = "NpcNavCache"
## intersect_shape hard-caps its result count and silently DROPS the rest. One shape = one hit, and
## the depot box holds thousands (1022 props — RigidBody hits are filtered out later but still take
## a slot — 429 apartment bodies, 193 shelves, terrain chunks): at 2048 the apartments came back
## incomplete and NPCs spawned on floors that had no navmesh ("wedged 2.6 m off the navmesh").
const QUERY_MAX_RESULTS: int = 32768
## Registered obstacles further than this (m) from a box's edge are not projected into its bake.
const OBSTACLE_REACH: float = 10.0

# ── Tunables: defaults here, overridden by `[npc]` in server.ini (same file and `srvini=` override as
# PropNet / NetworkOrchestrator.load_server_config). Read once at class load, before any autoload. ──
## Age (s) past which a box is re-baked the next time an NPC asks for it. Lazy: an idle box never bakes.
static var box_ttl_s: float = 120.0
## Age (s) past which a box's collected source geometry is re-collected before a re-bake.
static var parse_ttl_s: float = 30.0
## Concurrent bakes (worker tasks) across all caches. They share the worker pool with terrain chunks.
static var max_bakes_in_flight: int = 2
## A box nobody has used for this long (s) is freed (map + region + frame).
static var box_evict_s: float = 600.0
## "query" = physics query + worker extraction (default); "tree" = engine parse_source_geometry_data.
static var parse_mode: String = "query"

static func _static_init() -> void:
	var ini: String = "server.ini"
	for a: String in OS.get_cmdline_args():
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) != OK:
		return
	box_ttl_s = _ini_float(cfg, "nav_box_ttl", box_ttl_s)
	parse_ttl_s = _ini_float(cfg, "nav_parse_ttl", parse_ttl_s)
	max_bakes_in_flight = maxi(1, int(_ini_float(cfg, "nav_max_bakes", float(max_bakes_in_flight))))
	box_evict_s = _ini_float(cfg, "nav_box_evict", box_evict_s)
	var mode: Variant = cfg.get_value("npc", "nav_parse_mode", parse_mode)
	if mode is String and String(mode).strip_edges().to_lower() in ["query", "tree"]:
		parse_mode = String(mode).strip_edges().to_lower()

## A numeric `[npc]` key; a hand-edited ini hands numbers back as String, int or float.
static func _ini_float(cfg: ConfigFile, key: String, fallback: float) -> float:
	var v: Variant = cfg.get_value("npc", key, fallback)
	if v is float or v is int:
		return float(v)
	if v is String and String(v).strip_edges().is_valid_float():
		return String(v).strip_edges().to_float()
	return fallback

# ── Perf counters (server.gd _perf_tick prints and resets them via perf_snapshot) ──
static var prof_parses: int = 0       # source-geometry collections started
static var prof_parse_usec: int = 0   # MAIN-THREAD time spent collecting (query or tree parse)
static var prof_bakes: int = 0        # bakes landed
static var prof_bake_usec: int = 0    # wall time from job start (collection) to the mesh being published

## Physics frame of the last main-thread geometry collection ANY cache ran: one per frame server-wide,
## so several boxes falling due together never stack their collections into one spike.
static var _parse_frame: int = -1

## Every live cache (one per world root), for the static invalidation / perf entry points.
static var _live: Array = []

## Registered projected obstacles (parked vehicles): instance_id -> {node, verts, bottom_y, height, carve}.
## Injected by the cache itself in BOX-FRAME space at collection time. A NavigationObstacle3D would not
## do: the engine's obstacle parser takes its elevation from the node's WORLD y and only rotates around
## world Y, which is meaningless on a tilted planet a long way from the universe origin.
static var _obstacles: Dictionary = {}


## One shared tile. A plain RefCounted: the cache alone frees the RIDs (see _free_box); NPCs may keep a
## reference to a `freed` box and must check the flag. NAV SPACE for every query and path point is the
## SECTOR frame (to_local / from_local): the block's map lives there, and the tile's region is placed in
## it at the cell centre. The BAKE frame (`frame`, to_bake) is the tile-local frame Recast works in.
class NavBox extends RefCounted:
	## Bake frame (child of the cache): origin at the cell centre, basis = the sector's (+Y = local up).
	var frame: Node3D = null
	## The BLOCK's navigation map (shared by every tile of the block) — never the world map, where the
	## designer-authored city / depot regions overlap ours and win closest-point lookups.
	var map: RID = RID()
	var region: RID = RID()
	## Bake parameters + filter_baking_aabb; duplicated for every bake (a mesh already baking errors).
	var mesh_template: NavigationMesh = null
	## Last PUBLISHED mesh (null until the first bake lands).
	var mesh: NavigationMesh = null
	## At least one bake has landed on the region: queries are meaningful.
	var published: bool = false
	## Job state: extracting = a collection / worker extraction is running; baking = Recast is running.
	var extracting: bool = false
	var baking: bool = false
	var queued: bool = false
	## Needs a re-bake (world changed / TTL); parse_dirty additionally forces a fresh collection.
	var dirty: bool = false
	var parse_dirty: bool = false
	var baked_at: float = -INF
	var bake_started_at: float = -INF
	## Earliest time a queued re-bake may start (REBAKE_MIN_INTERVAL_S after the last one).
	var not_before: float = -INF
	var last_used: float = 0.0
	## NPCs currently holding this box (acquire / release). Unused boxes are evicted after box_evict_s.
	var users: int = 0
	var freed: bool = false
	## Collected source geometry, kept only while a re-bake may reuse it (see parse_ttl_s).
	var parse: NavigationMeshSourceGeometryData3D = null
	var parse_at: float = -INF
	## Lattice cell (sector-local) this tile occupies, its centre in sector space, its sector and block.
	var cell: Vector3i = Vector3i.ZERO
	var centre: Vector3 = Vector3.ZERO
	var sector: Sector = null
	var block: Block = null

	## World -> NAV SPACE (the sector frame: the map's own coordinates), and back.
	func to_local(world: Vector3) -> Vector3:
		return sector.node.global_transform.affine_inverse() * world

	func from_local(local: Vector3) -> Vector3:
		return sector.node.global_transform * local

	## World -> BAKE frame (tile-local, origin at the cell centre): what Recast and the obstacles use.
	func to_bake(world: Vector3) -> Vector3:
		return frame.global_transform.affine_inverse() * world

	## True if `world` lies inside this tile's cell with `margin` m of XZ slack from the edge.
	func covers(world: Vector3, margin: float) -> bool:
		return covers_local(to_local(world), margin)

	## `l` in NAV SPACE (sector frame).
	func covers_local(l: Vector3, margin: float) -> bool:
		return absf(l.x - centre.x) <= HALF - margin and absf(l.z - centre.z) <= HALF - margin \
				and absf(l.y - centre.y) <= VHALF - V_MARGIN

	func expired(now: float, ttl: float) -> bool:
		return published and now - baked_at > ttl

	## Live (published, not stale) — the NPC fast path.
	func is_fresh(now: float, ttl: float) -> bool:
		return published and not dirty and not freed and not expired(now, ttl)


## A lattice frame: cache-local transform (+Y radial at its origin), a Node3D carrying it (so nav space
## follows the planet), and the blocks of tiles keyed by block index.
class Sector extends RefCounted:
	var xform: Transform3D = Transform3D.IDENTITY
	var inverse: Transform3D = Transform3D.IDENTITY
	var node: Node3D = null
	var blocks: Dictionary = {}  # Vector3i block -> Block


## BLOCK_CELLS x BLOCK_CELLS cells (one vertical level) sharing one navigation map.
class Block extends RefCounted:
	var key: Vector3i = Vector3i.ZERO
	var map: RID = RID()
	var tiles: Dictionary = {}  # Vector3i cell -> NavBox


# ── Test seams: real implementations by default, swapped by the GUT suite ──
## () -> float seconds.
var clock: Callable = func() -> float: return Time.get_ticks_msec() / 1000.0
## (box) -> {src: NavigationMeshSourceGeometryData3D, task_id: int} — task_id -1 when already complete.
var parse_backend: Callable
## (box, mesh, src) -> void; must end with _on_bake_done(mesh, box).
var bake_backend: Callable

var _boxes: Array = []
var _sectors: Array = []
var _queue: Array = []
## Jobs in flight: collection / extraction + bakes.
var _in_flight: int = 0
## Extractions waiting on their worker task: [{box, src, task_id}].
var _extracting: Array = []


func _init() -> void:
	parse_backend = _collect_tree if parse_mode == "tree" else _collect_query
	bake_backend = _bake_async


func _enter_tree() -> void:
	_live.append(self)


func _exit_tree() -> void:
	_live.erase(self)
	for box in _boxes.duplicate():
		_free_box(box, false)  # the frames die with this node


func _physics_process(_delta: float) -> void:
	_pump()


# ── Static entry points ─────────────────────────────────────────────────────────────────────────────

## The cache for a world root, created on first use as a child of the root (so its frames follow the
## planet). Idempotent.
static func for_root(root: Node3D) -> NpcNavCache:
	var existing := root.get_node_or_null(CACHE_NODE_NAME)
	if existing is NpcNavCache:
		return existing
	var cache := NpcNavCache.new()
	cache.name = CACHE_NODE_NAME
	root.add_child(cache)
	root.add_to_group(SOURCE_GROUP)
	return cache


## Mark every box of every cache within `radius` m of `world_pos` for a lazy re-bake.
static func invalidate_around_all(world_pos: Vector3, radius: float, min_age_s: float = 0.0) -> void:
	for cache in _live:
		if is_instance_valid(cache):
			cache.invalidate_around(world_pos, radius, min_age_s)


## Register (or update) a projected obstacle: a convex footprint `verts` (node-local XZ, y ignored)
## standing on `bottom_y` (node-local) and `height` m tall. Carved obstacles are not widened by
## agent_radius. Callers must invalidate the boxes around the node themselves.
static func set_static_obstacle(node: Node3D, verts: PackedVector3Array, bottom_y: float,
		height: float, carve: bool = true) -> void:
	_obstacles[node.get_instance_id()] = {
		"node": node, "verts": verts, "bottom_y": bottom_y, "height": height, "carve": carve,
	}


static func clear_static_obstacle(node: Node3D) -> void:
	_obstacles.erase(node.get_instance_id())


static func obstacle_count() -> int:
	return _obstacles.size()


## Counters for the [Perf] line, summed over all caches; `reset` zeroes the windowed ones.
static func perf_snapshot(reset: bool) -> Dictionary:
	var boxes := 0
	var queued := 0
	var inflight := 0
	for cache in _live:
		if is_instance_valid(cache):
			boxes += cache._boxes.size()
			queued += cache._queue.size()
			inflight += cache._in_flight
	var snap := {
		"boxes": boxes, "queued": queued, "inflight": inflight,
		"parses": prof_parses, "parse_usec": prof_parse_usec,
		"bakes": prof_bakes, "bake_usec": prof_bake_usec,
		"obstacles": _obstacles.size(),
	}
	if reset:
		prof_parses = 0
		prof_parse_usec = 0
		prof_bakes = 0
		prof_bake_usec = 0
	return snap


# ── Public API ──────────────────────────────────────────────────────────────────────────────────────

## The box an NPC at `pos_world` heading for `goal_world` should path on: the box of the lattice cell
## holding the position, created (and its bake queued) on first use — a crowd in one cell shares ONE
## bake, baking-but-unpublished included. A stale (dirty / expired) box is re-queued. When the NPC is
## about to leave its cell toward the goal, the neighbour cell's box is prefetched. The returned box may
## still be baking: check `published`.
func request_box(pos_world: Vector3, goal_world: Vector3, up_world: Vector3) -> NavBox:
	var now: float = clock.call()
	var pos_c: Vector3 = global_transform.affine_inverse() * pos_world
	var sector: Sector = _sector_for(pos_c, up_world)
	var pl: Vector3 = sector.inverse * pos_c
	var cell: Vector3i = _cell_of(pl)
	var box: NavBox = _cell_box(sector, cell, now, pl.y)
	# Prefetch the corridor: the cells along the straight line to the goal, within this block (the map
	# cannot route into another block anyway), plus the neighbour cell we are about to step into.
	var gl: Vector3 = sector.inverse * (global_transform.affine_inverse() * goal_world)
	var d: Vector3 = gl - pl
	d.y = 0.0
	var length: float = d.length()
	if length > 1.0:
		var dir: Vector3 = d / length
		var wanted: Array = []
		var t: float = minf(PREFETCH_MARGIN, length)
		while t <= length + 0.001 and wanted.size() < PREFETCH_MAX_CELLS:
			var c: Vector3i = _cell_of(pl + dir * t)
			# The cell we are about to step into is always prefetched, even across a block boundary
			# (the NPC switches map there and needs ground on the other side); the corridor beyond
			# it stays within this block, the only map a route can use.
			if c != cell and not wanted.has(c) and (wanted.is_empty() or _block_key(c) == box.block.key):
				wanted.append(c)
			if t >= length:
				break
			t = minf(t + HALF, length)
		for c in wanted:
			_cell_box(sector, c, now, pl.y)
	return box


## The lattice cell holding a sector-local point (y is always 0: no vertical lattice).
static func _cell_of(pl: Vector3) -> Vector3i:
	return Vector3i(roundi(pl.x / LATTICE_XZ), 0, roundi(pl.z / LATTICE_XZ))


## The XZ centre of a cell at height `y` (the tile's own reference height).
static func cell_centre(cell: Vector3i, y: float = 0.0) -> Vector3:
	return Vector3(float(cell.x) * LATTICE_XZ, y, float(cell.z) * LATTICE_XZ)


## The block a cell belongs to: BLOCK_CELLS x BLOCK_CELLS cells, block 0 CENTRED on cell 0 — the sector
## opens at the first requester, who must sit in the middle of a block, not on its edge with half of
## its surroundings on another map.
static func _block_key(cell: Vector3i) -> Vector3i:
	var h: int = BLOCK_CELLS / 2
	return Vector3i(floori(float(cell.x + h) / float(BLOCK_CELLS)), 0,
			floori(float(cell.z + h) / float(BLOCK_CELLS)))


## The tile of a cell, created (centred vertically on `y`, the requester's ground height in sector
## space) and queued if missing; touched and re-queued if stale.
func _cell_box(sector: Sector, cell: Vector3i, now: float, y: float) -> NavBox:
	var block: Block = _block_for(sector, _block_key(cell))
	var box: NavBox = block.tiles.get(cell)
	if box != null and box.freed:
		block.tiles.erase(cell)
		box = null
	if box == null:
		box = _create_box(sector, block, cell, now, y)
		_enqueue(box, now)
		if PropNet.prof_on:
			print("[NpcNav] %s: tile #%d for cell %s (block %s, sector %d, %d tiles on its map)" % [
					get_path(), _boxes.size(), cell, block.key, _sectors.find(sector), block.tiles.size()])
		return box
	box.last_used = now
	if box.dirty or box.expired(now, box_ttl_s):
		_enqueue(box, now)
	return box


func _block_for(sector: Sector, key: Vector3i) -> Block:
	var block: Block = sector.blocks.get(key)
	if block != null:
		return block
	block = Block.new()
	block.key = key
	block.map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(block.map, CELL)
	NavigationServer3D.map_set_cell_height(block.map, CELL)
	NavigationServer3D.map_set_edge_connection_margin(block.map, EDGE_CONNECTION_MARGIN)
	NavigationServer3D.map_set_use_async_iterations(block.map, true)
	NavigationServer3D.map_set_active(block.map, true)
	sector.blocks[key] = block
	return block


## The sector whose origin is nearest `pos_c` (cache-local) within SECTOR_RADIUS, else a new one there.
func _sector_for(pos_c: Vector3, up_world: Vector3) -> Sector:
	var best: Sector = null
	var best_d: float = SECTOR_RADIUS
	for sector: Sector in _sectors:
		var dist: float = sector.xform.origin.distance_to(pos_c)
		if dist < best_d:
			best = sector
			best_d = dist
	if best != null:
		return best
	var sector := Sector.new()
	sector.xform = _surface_frame(global_transform * pos_c, up_world)
	sector.inverse = sector.xform.affine_inverse()
	sector.node = Node3D.new()
	sector.node.name = "NavSector%d" % (_sectors.size() + 1)
	add_child(sector.node)
	sector.node.transform = sector.xform
	_sectors.append(sector)
	return sector


## Where a route toward `goal_l` can aim from `pos_l` inside `box` (frame space): the goal itself when
## the box holds it, else the point HALF - INNER along the way — the NPC walks there and the next box
## carries it further. Height comes from the goal, so a goal on another floor still fails `covers`.
static func clamped_goal_local(_box: NavBox, pos_l: Vector3, goal_l: Vector3) -> Vector3:
	var d: Vector3 = goal_l - pos_l
	d.y = 0.0
	var reach: float = HALF - INNER
	if d.length() > reach:
		d = d.normalized() * reach
	return Vector3(pos_l.x + d.x, goal_l.y, pos_l.z + d.z)


func acquire(box: NavBox) -> void:
	box.users += 1
	box.last_used = clock.call()


func release(box: NavBox) -> void:
	box.users = maxi(0, box.users - 1)
	box.last_used = clock.call()


## Mark every box whose XZ extent comes within `radius` m of `world_pos` for a lazy re-bake (with a
## fresh geometry collection). Boxes baked less than `min_age_s` ago are left alone.
func invalidate_around(world_pos: Vector3, radius: float, min_age_s: float = 0.0) -> void:
	var now: float = clock.call()
	for box: NavBox in _boxes:
		if box.freed:
			continue
		var l: Vector3 = box.to_bake(world_pos)
		var cx: float = clampf(l.x, -HALF, HALF)
		var cz: float = clampf(l.z, -HALF, HALF)
		if Vector2(cx - l.x, cz - l.z).length() > radius:
			continue
		if box.published and now - box.baked_at < min_age_s:
			continue
		box.dirty = true
		box.parse_dirty = true


func box_count() -> int:
	return _boxes.size()


func sector_count() -> int:
	return _sectors.size()


func queued_count() -> int:
	return _queue.size()


func in_flight_count() -> int:
	return _in_flight


# ── Scheduler ───────────────────────────────────────────────────────────────────────────────────────

## One scheduler step: evict idle boxes, land finished extractions as bakes, start due jobs.
func _pump() -> void:
	var now: float = clock.call()
	_evict(now)
	_poll_extractions(now)
	var i: int = 0
	while i < _queue.size() and _in_flight < max_bakes_in_flight:
		var box: NavBox = _queue[i]
		if box.freed:
			_queue.remove_at(i)
			box.queued = false
			continue
		if now < box.not_before:
			i += 1
			continue
		var need_parse: bool = box.parse == null or box.parse_dirty or now - box.parse_at > parse_ttl_s
		if need_parse and Engine.get_physics_frames() == _parse_frame:
			break  # one main-thread collection per physics frame, server-wide; retry next tick
		_queue.remove_at(i)
		box.queued = false
		box.dirty = false
		box.bake_started_at = now
		_in_flight += 1
		if need_parse:
			_parse_frame = Engine.get_physics_frames()
			box.parse_dirty = false
			box.extracting = true
			var t0: int = Time.get_ticks_usec()
			var job: Dictionary = parse_backend.call(box)
			prof_parses += 1
			prof_parse_usec += Time.get_ticks_usec() - t0
			_extracting.append({"box": box, "src": job["src"], "task_id": job["task_id"]})
		else:
			_start_bake(box)
	# A collection that completed synchronously (tree parser, empty box, test seams) bakes THIS tick.
	_poll_extractions(now)


## Land worker extractions whose task is done: adopt the source geometry and start the bake.
func _poll_extractions(now: float) -> void:
	var i: int = 0
	while i < _extracting.size():
		var e: Dictionary = _extracting[i]
		var task_id: int = e["task_id"]
		if task_id >= 0:
			if not WorkerThreadPool.is_task_completed(task_id):
				i += 1
				continue
			WorkerThreadPool.wait_for_task_completion(task_id)  # releases the task; it is already done
		_extracting.remove_at(i)
		var box: NavBox = e["box"]
		box.extracting = false
		if box.freed:
			_in_flight -= 1
			continue
		var src: NavigationMeshSourceGeometryData3D = e["src"]
		_add_obstacles(box, src)
		box.parse = src
		box.parse_at = now
		_start_bake(box)


func _start_bake(box: NavBox) -> void:
	var mesh: NavigationMesh = box.mesh_template.duplicate()
	box.baking = true
	if box.parse == null or not box.parse.has_data():
		# Nothing solid in the box (open space). The engine refuses to bake empty data and would never
		# call back, so publish the empty mesh directly: an honest "no walkable ground here".
		_on_bake_done(mesh, box)
		return
	bake_backend.call(box, mesh, box.parse)


func _bake_async(box: NavBox, mesh: NavigationMesh, src: NavigationMeshSourceGeometryData3D) -> void:
	NavigationServer3D.bake_from_source_geometry_data_async(mesh, src, _on_bake_done.bind(mesh, box))


## Bake landed (main thread, from the NavigationServer sync): publish, notify, re-queue if re-dirtied.
func _on_bake_done(mesh: NavigationMesh, box: NavBox) -> void:
	var now: float = clock.call()
	_in_flight -= 1
	box.baking = false
	if box.freed:
		return
	NavigationServer3D.region_set_navigation_mesh(box.region, mesh)
	box.mesh = mesh
	box.published = true
	box.baked_at = now
	if mesh.get_polygon_count() == 0:
		box.baked_at = now - box_ttl_s + EMPTY_RETRY_S  # expires on the next request after EMPTY_RETRY_S
	box.not_before = now + REBAKE_MIN_INTERVAL_S
	prof_bakes += 1
	prof_bake_usec += int((now - box.bake_started_at) * 1000000.0)
	if not box.dirty:
		box.parse = null  # a collection can weigh tens of MB; keep it only for an imminent re-bake
	box_baked.emit(box)
	if box.dirty:
		_enqueue(box, now)


func _enqueue(box: NavBox, _now: float) -> void:
	if box.freed or box.queued or box.extracting or box.baking:
		return  # a running job re-queues itself on landing if the box is still dirty
	box.queued = true
	_queue.append(box)


func _evict(now: float) -> void:
	for box in _boxes.duplicate():
		if box.users > 0 or box.extracting or box.baking:
			continue
		if now - box.last_used > box_evict_s:
			_free_box(box)


func _create_box(sector: Sector, block: Block, cell: Vector3i, now: float, y: float) -> NavBox:
	var box := NavBox.new()
	box.sector = sector
	box.block = block
	box.cell = cell
	box.centre = cell_centre(cell, y)
	box.frame = Node3D.new()
	box.frame.name = "NavBox%d" % (_boxes.size() + 1)
	add_child(box.frame)
	# Same basis as the sector (so neighbouring tiles agree on "up"), origin at the cell centre.
	box.frame.transform = Transform3D(sector.xform.basis, sector.xform * box.centre)
	block.tiles[cell] = box
	box.map = block.map
	# The mesh is baked tile-local (near the origin, where the server's 21-bit PointKeys resolve) and
	# the region is placed in the block's map at the cell centre: map space = sector space.
	box.region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(box.region, box.map)
	NavigationServer3D.region_set_transform(box.region, Transform3D(Basis.IDENTITY, box.centre))
	NavigationServer3D.region_set_enabled(box.region, true)
	box.mesh_template = _make_mesh_template()
	box.last_used = now
	_boxes.append(box)
	return box


## Release a box: server RIDs (nothing else frees them), the frame node, and every reference that could
## keep a collection alive. Called from the scheduler (main thread, outside any tree traversal), so the
## frame is freed on the spot rather than queued — GUT's orphan counter would otherwise flag it.
func _free_box(box: NavBox, free_frame: bool = true) -> void:
	if box.freed:
		return
	box.freed = true
	if box.region != RID():
		NavigationServer3D.free_rid(box.region)
		box.region = RID()
	box.map = RID()
	if box.block != null and box.block.tiles.get(box.cell) == box:
		box.block.tiles.erase(box.cell)
		if box.block.tiles.is_empty():
			# Last tile of the block: its map goes with it.
			if box.block.map != RID():
				NavigationServer3D.free_rid(box.block.map)
				box.block.map = RID()
			if box.sector != null:
				box.sector.blocks.erase(box.block.key)
	if free_frame and is_instance_valid(box.frame):
		if box.frame.get_parent() == self:
			remove_child(box.frame)
		box.frame.free()
	box.parse = null
	box.mesh = null
	_boxes.erase(box)
	if box.queued:
		_queue.erase(box)
		box.queued = false


## The frame a box is baked in, in this cache's (= the root's) space: origin at `centre_world`, +Y along
## `up_world`. Any two axes perpendicular to up will do — the navmesh only cares which way is up.
func _surface_frame(centre_world: Vector3, up_world: Vector3) -> Transform3D:
	var up: Vector3 = (global_transform.basis.inverse() * up_world).normalized()
	if not up.is_normalized():
		up = Vector3.UP  # no gravity frame yet
	var fwd: Vector3 = Vector3.FORWARD
	if absf(up.dot(fwd)) > 0.9:
		fwd = Vector3.RIGHT  # degenerate: up is (anti)parallel to the reference axis
	var x: Vector3 = fwd.cross(up).normalized()
	var z: Vector3 = x.cross(up).normalized()
	return Transform3D(Basis(x, up, z), global_transform.affine_inverse() * centre_world)


func _make_mesh_template() -> NavigationMesh:
	var mesh := NavigationMesh.new()
	mesh.cell_size = CELL
	mesh.cell_height = CELL
	mesh.agent_radius = AGENT_RADIUS
	mesh.agent_height = AGENT_HEIGHT
	mesh.agent_max_climb = AGENT_MAX_CLIMB
	mesh.agent_max_slope = AGENT_MAX_SLOPE
	# Only used by the `tree` parser: static colliders (exactly what the NPC body hits, never
	# decorative meshes), traversed from the group, emitted in the parse root's (= frame's) space.
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = COLLISION_MASK
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	mesh.geometry_source_group_name = SOURCE_GROUP
	# Tile-aligned baking: the volume overshoots the cell by BORDER on every side and Recast discards
	# that border again, so the mesh ends flush with the cell (edge_max_error <= 1.0 is required for
	# the cut to be exact, see NavigationMesh.border_size).
	mesh.filter_baking_aabb = box_aabb()
	mesh.border_size = BORDER
	mesh.edge_max_error = 1.0
	return mesh


## The bake volume in the BAKE frame (tile-local): the cell plus the discarded border.
static func box_aabb() -> AABB:
	return AABB(Vector3(-(HALF + BORDER), -VHALF, -(HALF + BORDER)),
			Vector3(2.0 * (HALF + BORDER), 2.0 * VHALF, 2.0 * (HALF + BORDER)))


# ── Source geometry collection ──────────────────────────────────────────────────────────────────────

## Engine parser (main thread, whole planet). Kept for A/B measurement: `[npc] nav_parse_mode=tree`.
func _collect_tree(box: NavBox) -> Dictionary:
	var src := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(box.mesh_template, src, box.frame)
	return {"src": src, "task_id": -1}


## Default collector. Main thread: one broadphase query for the solid bodies touching the box, and a
## list of (shape resource, frame-relative transform) pairs. Worker: faces extracted from those shapes
## into `src`. The Shape3D / face arrays are refcounted, so a chunk unloaded mid-extraction is harmless.
func _collect_query(box: NavBox) -> Dictionary:
	var src := NavigationMeshSourceGeometryData3D.new()
	var entries: Array = collect_entries(box)
	if entries.is_empty():
		return {"src": src, "task_id": -1}
	var task_id: int = WorkerThreadPool.add_task(_extract.bind(entries, src), false, "npc nav extract")
	return {"src": src, "task_id": task_id}


## The (shape, xform) pairs of every StaticBody3D / CSG collider intersecting `box`, xform expressed in
## the box frame. Main thread only (reads nodes and the physics space).
func collect_entries(box: NavBox) -> Array:
	var world := get_world_3d()
	if world == null:
		return []
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return []
	var aabb: AABB = box_aabb()
	var probe := BoxShape3D.new()
	probe.size = aabb.size
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = probe
	params.transform = box.frame.global_transform * Transform3D(Basis.IDENTITY, aabb.get_center())
	params.collision_mask = COLLISION_MASK
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var hits: Array = space.intersect_shape(params, QUERY_MAX_RESULTS)
	if hits.size() >= QUERY_MAX_RESULTS:
		push_warning("NpcNavCache: %d colliders in one box hit QUERY_MAX_RESULTS; the bake is INCOMPLETE" % hits.size())
	var entries: Array = entries_from_hits(hits, box.frame.global_transform.affine_inverse())
	if PropNet.prof_on:
		print("[NpcNav] %s collected %d hits -> %d static entries" % [box.frame.name, hits.size(), entries.size()])
	return entries


## Turn intersect_shape hits into extraction entries: {shape, xform} for a StaticBody3D's shape (the
## Shape3D resource is refcounted, so a chunk unloaded mid-extraction is harmless), {faces, xform} for a
## use_collision CSG root (its faces are read HERE — Mesh.get_faces() goes through the RenderingServer,
## main thread only). RigidBody3D / CharacterBody3D hits are dropped: a bake sees static solids only,
## exactly like the engine parser. Public for the tests.
static func entries_from_hits(hits: Array, frame_inv: Transform3D) -> Array:
	var entries: Array = []
	var seen: Dictionary = {}
	for hit: Dictionary in hits:
		var collider: Object = hit.get("collider")
		if collider == null:
			continue
		var key: String = "%d:%d" % [hit.get("collider_id", 0), hit.get("shape", 0)]
		if seen.has(key):
			continue
		seen[key] = true
		if collider is StaticBody3D:
			# AnimatableBody3D included (doors, platforms) — it is a StaticBody3D, as in the engine parser.
			var body := collider as StaticBody3D
			var owner_id: int = body.shape_find_owner(int(hit.get("shape", 0)))
			var owner: Object = body.shape_owner_get_owner(owner_id)
			if owner is CollisionShape3D and (owner as CollisionShape3D).shape != null:
				var cs := owner as CollisionShape3D
				entries.append({"shape": cs.shape, "xform": frame_inv * cs.global_transform})
		elif collider is CSGShape3D:
			# A use_collision CSG root owns a concave shape of its own mesh; get_meshes() is that mesh.
			var meshes: Array = (collider as CSGShape3D).get_meshes()
			if meshes.size() == 2 and meshes[1] is Mesh:
				entries.append({"faces": (meshes[1] as Mesh).get_faces(),
						"xform": frame_inv * (collider as CSGShape3D).global_transform * meshes[0]})
	return entries


## Worker task: turn every entry into triangles and add them to `src`. Pure data, no node access.
static func _extract(entries: Array, src: NavigationMeshSourceGeometryData3D) -> void:
	for e: Dictionary in entries:
		var faces: PackedVector3Array = shape_faces(e["shape"]) if e.has("shape") else e["faces"]
		if faces.size() >= 3:
			src.add_faces(faces, e["xform"])


## Triangles (CW-front, Godot's convention) of a collision shape in shape-local space. Trimeshes and
## boxes are exact; every other primitive is its BOUNDING BOX — conservative for pathing (an NPC walks
## around a slightly fatter rock) and the only option without a convex-hull builder in GDScript.
static func shape_faces(shape: Shape3D) -> PackedVector3Array:
	if shape is ConcavePolygonShape3D:
		return (shape as ConcavePolygonShape3D).get_faces()
	if shape is BoxShape3D:
		var s: Vector3 = (shape as BoxShape3D).size
		return box_faces(AABB(-s * 0.5, s))
	if shape is ConvexPolygonShape3D:
		var pts: PackedVector3Array = (shape as ConvexPolygonShape3D).points
		if pts.is_empty():
			return PackedVector3Array()
		var bb := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			bb = bb.expand(p)
		return box_faces(bb)
	if shape is SphereShape3D:
		var r: float = (shape as SphereShape3D).radius
		return box_faces(AABB(Vector3(-r, -r, -r), Vector3(2.0 * r, 2.0 * r, 2.0 * r)))
	if shape is CapsuleShape3D:
		var c := shape as CapsuleShape3D
		return box_faces(AABB(Vector3(-c.radius, -c.height * 0.5, -c.radius),
				Vector3(2.0 * c.radius, c.height, 2.0 * c.radius)))
	if shape is CylinderShape3D:
		var cy := shape as CylinderShape3D
		return box_faces(AABB(Vector3(-cy.radius, -cy.height * 0.5, -cy.radius),
				Vector3(2.0 * cy.radius, cy.height, 2.0 * cy.radius)))
	return PackedVector3Array()  # HeightMap / World boundary / separation ray: not used for NPC ground


## The 12 triangles of a box, wound CW-front (geometric normal (b-a)x(c-a) pointing INWARD), which is
## what the navmesh face pipeline expects — outward-wound faces bake ZERO polygons.
static func box_faces(bb: AABB) -> PackedVector3Array:
	var lo: Vector3 = bb.position
	var hi: Vector3 = bb.end
	var v: Array = [
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
	]
	# Each quad is listed so that (b-a)x(c-a) of its two triangles points INTO the box (checked by
	# test_box_faces_are_wound_clockwise_front against the same rule the chunk bodies use).
	var quads: Array = [
		[0, 3, 2, 1],  # bottom (-Y)
		[4, 5, 6, 7],  # top (+Y)
		[0, 1, 5, 4],  # -Z
		[3, 7, 6, 2],  # +Z
		[0, 4, 7, 3],  # -X
		[1, 2, 6, 5],  # +X
	]
	var out := PackedVector3Array()
	for q: Array in quads:
		out.append(v[q[0]])
		out.append(v[q[1]])
		out.append(v[q[2]])
		out.append(v[q[0]])
		out.append(v[q[2]])
		out.append(v[q[3]])
	return out


## Project the registered obstacles that reach into `box` onto its source geometry (frame space).
func _add_obstacles(box: NavBox, src: NavigationMeshSourceGeometryData3D) -> void:
	if _obstacles.is_empty():
		return
	for id in _obstacles.keys():
		var o: Dictionary = _obstacles[id]
		var node: Node3D = o["node"]
		if not is_instance_valid(node) or not node.is_inside_tree():
			_obstacles.erase(id)
			continue
		var centre_l: Vector3 = box.to_bake(node.global_position)
		if absf(centre_l.x) > HALF + OBSTACLE_REACH or absf(centre_l.z) > HALF + OBSTACLE_REACH:
			continue
		var verts_l := PackedVector3Array()
		var floor_y: float = INF
		for v: Vector3 in o["verts"]:
			var w: Vector3 = node.global_transform * Vector3(v.x, o["bottom_y"], v.z)
			var l: Vector3 = box.to_bake(w)
			floor_y = minf(floor_y, l.y)
			verts_l.append(Vector3(l.x, 0.0, l.z))
		if verts_l.size() < 3:
			continue
		# Half a metre under the lowest corner, a metre over the top: a tilted truck on a slope still
		# cuts the mesh across its whole footprint.
		src.add_projected_obstruction(verts_l, floor_y - 0.5, float(o["height"]) + 1.0, bool(o["carve"]))
