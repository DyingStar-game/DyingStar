@tool
class_name MiningZone
extends Node3D

# Mining Zone — a designer-placed trigger. When a player enters its detection Area3D AND
# the zone currently holds no mining rocks, the SERVER seed-generates a field of rocks
# (positions, sizes, ore richness) over a flat square region. The rocks are ordinary
# "miningrock" props, so they replicate + persist like any other rock. A fully-depleted
# zone re-generates on the next entry (renewable, no persisted marker needed).
#
# Place an instance of Mining_Zone.tscn in the world (e.g. sandbox_capital.tscn) and tune
# the @export values per zone (mineral, richness, density, size mix).
#
# Generation runs from _physics_process, NOT from the body_entered callback: the ground
# raycast needs direct_space_state, which is only valid during the physics step (the space
# is locked while area signals are flushed).

## This scene's own path, sent as `scenename` when the placeholder spawns the networked zone.
const SCENE_PATH := "scenes/_universe/structures/industrial/mines/Mining_Zone.tscn"

const SCENE_SMALL := "scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn"
const SCENE_MEDIUM := "scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn"
const SCENE_LARGE := "scenes/_universe/environment/terrain/rocks/rock_mining_lg.tscn"
# One rock is spawned every SPAWN_INTERVAL_FRAMES physics frames while draining the queue, to
# spread the create_object burst so Horizon's message channel never overflows (a flood of
# create_object messages gets dropped -> the rocks exist server-side but never reach clients).
const SPAWN_INTERVAL_FRAMES := 10
# Rocks are PLACED on the surface, not dropped. Dropping them fought the server's settle-culler:
# it freezes any body further than Server.ACTIVE_RADIUS (60 m) from a player the instant it is
# created, and a 500 m field is almost entirely outside that — so every rock was frozen mid-fall and
# hung 2 m in the air until someone walked up to it. Placing them exactly also spares the server
# ~300 falling bodies per zone, which is the cheaper answer anyway.
#
# Clearance (m) left between the ground hit and the rock's origin. The rock mesh's origin sits at
# its BASE (aabb.position.y = -0.03), so the hit point IS where the origin goes; the few cm on top
# only keep a body the culler later wakes from starting out interpenetrating the terrain.
const SPAWN_CLEARANCE := 0.05

# Server-side player detection runs in script (a throttled distance check), NOT a physics Area3D.
# A monitoring Area3D scans every body inside its radius every physics step; with hundreds of
# zones each covering a rock field, that broadphase scan alone dropped the dedicated server to a
# few fps (the rocks are layer 1, but Jolt still enumerates them before the mask filter). The
# distance check is O(zones x players) — a handful of players — so it costs effectively nothing.
const DETECT_INTERVAL_FRAMES := 30   # re-check ~once per second at 30 Hz physics
const DETECT_MARGIN := 210.0          # metres beyond the field half-size at which a player triggers

@export_group("Identity")
## Designer-placed zone: tick this on the instance you drop in a world scene. On the server it
## spawns the REAL networked zone (same scene, PropSync-backed, deterministic uuid) and frees
## itself, exactly like mining_depot's placeholder. Without it the zone still generates rocks but
## has no uuid, so `generated` is never persisted and it re-populates on every server restart.
@export var placeholder: bool = false
## Seed for the deterministic rock UUIDs, so regenerating the SAME zone never duplicates
## rocks in the DB. Leave EMPTY to derive it from the zone's world position.
@export var stable_id: String = ""

@export_group("Field")
## Side length (m) of the square region rocks are scattered over, centered on the zone.
@export_range(10.0, 1000.0) var zone_size: float = 500.0
## How many rocks to generate when the zone is (re)populated.
@export var rock_count: int = 30
## Minimum spacing (m) between two rocks, to avoid overlaps.
@export var min_spacing: float = 8.0
## Relative share of each size in the mix (small, medium, large). Any positive ratio works.
@export_range(0.0, 1.0) var weight_small: float = 0.6
@export_range(0.0, 1.0) var weight_medium: float = 0.3
@export_range(0.0, 1.0) var weight_large: float = 0.1

@export_group("Ore")
## Zone ore richness 0..1 (poor..rich). Picks each rock's ore_seed so its derived richness
## sits near this target — works WITHOUT any extra replication (ore_seed is already synced).
@export_range(0.0, 1.0) var richness: float = 0.5
## How tightly rock richness hugs the target (smaller = tighter spread around `richness`).
@export_range(0.0, 0.5) var richness_spread: float = 0.12
## Which mineral this zone yields. Picked from a dropdown fed by MineralRegistry (see
## _validate_property), listing the ore-bearing minerals only. Replicated per rock via the ore
## channel and applied on every client.
@export var mineral_id: String = "gold"
## The BARREN rock the ore sits in — the local geology (basalt, granite, corundum...). Its density
## is replicated per rock as `inert_density` and mixed with the mineral's own according to each
## rock's purity, so a gold vein in sandstone weighs less than the same vein in basalt.
##
## LEAVE EMPTY (the default) to inherit the planet's own geology, PlanetData.mining_zone_host_rock —
## which is what every zone the planner seeds does, and the only way a whole planet can read as one
## rock type. Fill it only to override a single hand-placed zone. Suggestion list fed by
## MineralRegistry, restricted to the inert minerals (see _validate_property).
@export var host_rock_id: String = ""

@export_group("Detection")
## The Area3D (the ~1 km trigger) that detects players. Assign the child Area3D.
@export var trigger_area: Area3D

@export_group("State")
@export var generated: bool = false
@export var last_generation_datetime: int = 946724400  # 2000-01-01 00:00:00 UTC (epoch)

@export_group("Editor")
## EDITOR PREVIEW: toggle ON to populate the field with rock instances right in the editor
## (flat ground, no networking) so you can see size mix / density / spread. OFF clears it.
## These preview nodes are transient — they are NOT saved into the scene.
@export var preview_in_editor: bool = false:
	set(value):
		preview_in_editor = value
		if Engine.is_editor_hint():
			if value:
				_build_preview()
			else:
				_clear_preview()

var _spawn_queue: Array[Dictionary] = []
var _spawn_tick: int = 0
var _detect_tick: int = 0
var _ground_wait_logged: bool = false
var _last_poi_culled: int = 0

var preload_scenes = {
	SCENE_SMALL: preload("res://scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn"),
	SCENE_MEDIUM: preload("res://scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn"),
	SCENE_LARGE: preload("res://scenes/_universe/environment/terrain/rocks/rock_mining_lg.tscn"),
}

var generate_queue: bool = false

# Networking lives in the PropSync child (type_name "miningzone", see Mining_Zone.tscn); the zone
# keeps only the thin facade below. The channel is declared server-side in horizonserver
# ds_genericprops/props/miningzone_def.json and carries the whole field config + `generated`.
var _sync: PropSync

## Cached PropSync child, resolved lazily so an access before _ready still works.
func _prop_sync() -> PropSync:
	if _sync == null:
		_sync = PropSync.of(self)
	return _sync

var uuid: String:
	get:
		var s := _prop_sync()
		return s.uuid if s != null else ""
	set(value):
		var s := _prop_sync()
		if s != null:
			s.uuid = value

## Server-side state update, forwarded to the PropSync component which stamps the zone's uuid /
## type_name. No-op while the zone has no uuid (a hand-placed, non-networked zone).
func server_prop_update(data: Dictionary) -> void:
	var s := _prop_sync()
	if s != null:
		s.server_prop_update(data)

## Inspector: turn the two mineral ids into dropdowns fed by MineralRegistry, so a designer picks
## from what is actually registered instead of typing an id whose only symptom is a runtime warning
## and a silent fallback to gold. `mineral_id` offers the ore-bearing minerals, `host_rock_id` the
## barren ones, so the two fields can never be swapped by accident.
##
## They stay `String` rather than becoming a real enum on purpose: the id is what travels on the
## wire (`mineral_id` in the miningzone / miningrock channels) and what sits in the DB, so an int
## index would silently repoint every stored zone the day a mineral is inserted mid-registry.
## PROPERTY_HINT_ENUM on a String stores the chosen TEXT, which gives the dropdown for free.
func _validate_property(property: Dictionary) -> void:
	match property["name"]:
		"mineral_id":
			property["hint"] = PROPERTY_HINT_ENUM
			property["hint_string"] = MineralRegistry.enum_hint(MineralRegistry.Kind.ORE)
		"host_rock_id":
			# SUGGESTION, not ENUM: the empty value is meaningful here ("inherit the planet"), and a
			# strict enum has no way to express it.
			property["hint"] = PROPERTY_HINT_ENUM_SUGGESTION
			property["hint_string"] = MineralRegistry.enum_hint(MineralRegistry.Kind.INERT)


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)  # the editor runs @tool scripts; no server logic there
		$EditorZone/CollisionShape3D.shape.size.x = zone_size
		$EditorZone/CollisionShape3D.shape.size.z = zone_size
		return
	# Hide the zone in the game because it's only used in the editor
	$EditorZone.hide()
	if placeholder:
		set_physics_process(false)  # a placeholder never detects nor spawns rocks itself
		if OS.has_feature("dedicated_server"):
			await _spawn_networked_zone()  # awaits a timer inside; free only once it is done
		queue_free()
		return
	if not OS.has_feature("dedicated_server"):
		set_physics_process(false)  # only the server detects players and spawns rocks
		return
	# A NETWORKED zone (uuid assigned by server.create_generic_object before add_child) is driven by
	# MiningZonePlanner, which arms the one under a player and disarms it on the way out. Ticking
	# here as well would put every zone Horizon replays at boot back on the physics step — the very
	# O(zones) cost the planner exists to remove. A hand-placed zone has no uuid and keeps ticking.
	if uuid != "":
		set_physics_process(false)


## Server: replace this editor placeholder with the real networked zone. Same handshake as
## mining_depot: a deterministic uuid (so the DB upserts instead of piling duplicates across
## restarts), a parent_id pointing at the nearest networked frame (the planet/city the zone sits
## on — a root-parented prop is pinned in world space while the planet moves and drifts away), and
## spawn_prop_authoritative so the object exists BOTH in Horizon and on this game server (Horizon
## does not echo create_object back).
func _spawn_networked_zone() -> void:
	await get_tree().create_timer(1).timeout
	if not is_inside_tree():
		return
	var net_parent: Node = PropSpawn.find_net_parent(self)
	var parent_uuid: String = PropSpawn.net_parent_uuid(net_parent)
	# Express the placement in that parent's frame, so the zone lands at the same spot whatever the
	# scene grouping — and so the uuid seed is stable across restarts (global_position is not: the
	# parent frame itself moves).
	var place_xform: Transform3D = global_transform
	if net_parent is Node3D:
		place_xform = (net_parent as Node3D).global_transform.affine_inverse() * global_transform
	var place_pos: Vector3 = place_xform.origin
	var place_rot: Vector3 = place_xform.basis.get_euler()
	var uuid_seed: String = stable_id if stable_id != "" \
		else "%s|%.3f,%.3f,%.3f" % [parent_uuid, place_pos.x, place_pos.y, place_pos.z]
	var zone_uuid: String = PropSpawn.stable_uuid(uuid_seed)
	# Designer-placed zone = world infrastructure: shield it from the admin cleanup tool.
	NetworkOrchestrator.protected_prop_uuids[zone_uuid] = true
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": "miningzone",
		"uuid": zone_uuid,
		"position": {"x": place_pos.x, "y": place_pos.y, "z": place_pos.z},
		"rotation": {"x": place_rot.x, "y": place_rot.y, "z": place_rot.z},
		"scenename": SCENE_PATH,
		"parent_id": parent_uuid,
		"zone_size": zone_size,
		"rock_count": rock_count,
		"min_spacing": min_spacing,
		"weight_small": weight_small,
		"weight_medium": weight_medium,
		"weight_large": weight_large,
		"richness": richness,
		"richness_spread": richness_spread,
		"mineral_id": mineral_id,
		"generated": generated,
		"last_generation_datetime": last_generation_datetime,
	})


## Server: any player within the field (plus a margin)? Cheap script check over the few players
## in the world, replacing the old per-zone physics Area3D (see DETECT_INTERVAL_FRAMES note).
func _player_in_range() -> bool:
	var r: float = zone_size * 0.5 + DETECT_MARGIN
	for p in get_tree().get_nodes_in_group("player"):
		if p is Node3D and global_position.distance_to((p as Node3D).global_position) <= r:
			return true
	return false



# Server only (physics process is disabled on clients). Throttled, we look for a nearby player and,
# if the field is currently empty, (re)generate — so an entry into a populated zone does nothing,
# and a fully-mined zone repopulates on the next entry. The ground raycasts happen here
# (direct_space_state is only valid during the physics step). Then drain the spawn queue a few
# rocks per frame to spread the burst.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not generated:
		_detect_tick += 1
		if _detect_tick >= DETECT_INTERVAL_FRAMES:
			_detect_tick = 0
			if _player_in_range() and not _has_rocks_in_field():
				generate_queue = true
	if generate_queue:
		generate_queue = false
		if _spawn_queue.is_empty() and not _has_rocks_in_field() and not _ground_is_loaded():
			# Not an error: the chunk's collision is still being built on a worker thread. Say it
			# once, so a zone that never populates is never a mystery.
			if not _ground_wait_logged:
				_ground_wait_logged = true
				print("[MiningZone] %s waiting: terrain collision under it is not loaded yet." % name)
		elif _spawn_queue.is_empty() and not _has_rocks_in_field():
			# Stamp the time BEFORE building: it seeds the field, so the rocks and the persisted
			# timestamp have to describe the same draw.
			last_generation_datetime = int(Time.get_unix_time_from_system())
			_build_spawn_queue()
			# Only NOW is the zone "generated". Flagging it before checking would brick the zone
			# for good: every raycast in _build_spawn_queue misses while the chunk's collision is
			# still loading (it is built asynchronously on WorkerThreadPool), the queue comes back
			# empty, and a persisted generated = true means nothing ever retries.
			print("[MiningZone] %s generating: %d rocks queued (%s in %s @ %.0f kg/m3, richness %.2f)%s" % [
				name, _spawn_queue.size(), mineral_id,
				_resolved_host_rock_id() if _resolved_host_rock_id() != "" else "<none>",
				_host_rock_density(), richness,
				"" if _last_poi_culled == 0 else " — %d dropped inside a POI" % _last_poi_culled])
			if not _spawn_queue.is_empty():
				generated = true
				# Persist it: without this the zone re-populates on every server restart (Horizon
				# replays the stored object_data, which would still say generated = false).
				server_prop_update({
					"generated": generated,
					"last_generation_datetime": last_generation_datetime,
				})
	if not _spawn_queue.is_empty():
		_spawn_tick += 1
		if _spawn_tick >= SPAWN_INTERVAL_FRAMES:
			_spawn_tick = 0
			NetworkOrchestrator.spawn_prop_authoritative(_spawn_queue.pop_back())
	elif generated:
		# Field fully spawned: nothing left to detect, so stop running _physics_process entirely
		# (guard on `generated` so we don't stop while merely idle-waiting for the first player).
		disable_server_detection()


## The PlanetTerrain of the planet this zone sits on, or null (a zone on a station / in a city).
func _planet_terrain() -> PlanetTerrain:
	var n: Node = get_parent()
	while n != null and not (n is Planet):
		n = n.get_parent()
	return (n as Planet).planet_terrain if n != null else null


## True when the terrain under the zone centre already carries its collision body — i.e. the ground
## raycasts in _build_spawn_queue have something to hit.
##
## The server builds terrain collision chunk by chunk, around the bodies that need it, on worker
## threads. A zone created the moment a player steps onto its chunk therefore races that load, and
## losing the race means a field of zero rocks. Same gate, and same reason, as
## PlanetServer._hold_until_ground. A zone with no planet ancestor (a station) has nothing to wait
## for and is always ready.
func _ground_is_loaded() -> bool:
	var terrain := _planet_terrain()
	return terrain == null or terrain.has_collision_under(global_position)


## True if any mining rock currently sits inside this zone's square field.
func _has_rocks_in_field() -> bool:
	var half: float = zone_size * 0.5
	for r in get_tree().get_nodes_in_group("miningrock"):
		if r is Node3D:
			var local: Vector3 = to_local((r as Node3D).global_position)
			if absf(local.x) <= half and absf(local.z) <= half:
				return true
	return false

## Seed the RNG and fill _spawn_queue with ready-to-send rock spawn data. All ground
## raycasts are done here (called from _physics_process) so the physics space is available.
func _build_spawn_queue() -> void:
	var seed_str: String = stable_id if stable_id != "" \
		else "%.2f,%.2f,%.2f" % [global_position.x, global_position.y, global_position.z]

	# ONE seeded stream for the whole field, so re-running this after a crash re-draws the SAME
	# rocks at the SAME uuids and the database upserts instead of piling a second, offset field on
	# top of the first. The global randf() this used to call made every run different.
	# last_generation_datetime is part of the seed so a renewable zone still re-rolls a fresh field
	# on its next cycle rather than resurrecting the one the players just mined out.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d" % [seed_str, last_generation_datetime])

	var half: float = zone_size * 0.5
	var points = poisson_disk_fast(
		Rect2(-half, -half, zone_size, zone_size), min_spacing, rock_count, rng)
	# Parent the rocks to the nearest networked frame (the planet/city the zone lives under), NOT
	# the zone itself: the rocks must survive the zone and ride the frame that actually MOVES.
	# Positions are then expressed in that parent's local frame instead of fixed world space, where
	# a planet moving at ~3e10 would leave them behind (mirror mining_depot).
	var net_parent: Node = PropSpawn.find_net_parent(self)
	var parent_uuid: String = PropSpawn.net_parent_uuid(net_parent)
	var to_parent_local: Transform3D = Transform3D.IDENTITY
	if net_parent is Node3D:
		to_parent_local = (net_parent as Node3D).global_transform.affine_inverse()
	# POIs to keep clear of, resolved once for the whole field. MiningZonePlanner only guarantees
	# the zone's CENTRE clears them, so a field next to a village legitimately overhangs it; the
	# rocks in that overhang are dropped here. Same PlanetTerrain.first_blocking_poi the siting used,
	# so a rock can never be judged by a different rule than the zone it belongs to.
	var terrain := _planet_terrain()
	var poi_spheres: Array = terrain.poi_spheres() if terrain != null else []
	var poi_margin: float = terrain.planet_data.mining_zone_poi_margin \
		if terrain != null and terrain.planet_data != null else 0.0
	var culled: int = 0

	var index: int = 0
	for point in points:
		# Find the surface under this XZ: raycast along the zone's up axis. MUST run here (called
		# from _physics_process) because direct_space_state is only valid during the physics step.
		# Skip points with no ground under them rather than spawning a rock floating at the zone's
		# flat y.
		var hit: Dictionary = _ground_hit(to_global(Vector3(point.x, 0.0, point.y)))
		if hit.is_empty():
			continue
		# Sit the rock ON the surface and orient it TO the surface, so it needs no settling at all.
		var ground: Vector3 = hit["position"]
		if not PlanetTerrain.first_blocking_poi(ground, poi_spheres, poi_margin).is_empty():
			culled += 1
			continue
		var normal: Vector3 = hit["normal"]
		var spawn_world: Vector3 = ground + normal.normalized() * SPAWN_CLEARANCE
		var local_pos: Vector3 = to_parent_local * spawn_world
		var local_rot: Vector3 = PropSpawn.surface_euler(
			normal, rng.randf_range(0.0, TAU), to_parent_local)
		_spawn_queue.append({
			"type": "miningrock",
			"uuid": PropSpawn.stable_uuid("%s|%d#%d" % [seed_str, last_generation_datetime, index]),
			"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
			"rotation": {"x": local_rot.x, "y": local_rot.y, "z": local_rot.z},
			"scenename": _pick_scene(rng),
			"parent_id": parent_uuid,
			"ore_seed": _ore_seed_for_richness(seed_str, index),
			"mineral_id": mineral_id,
			# Both: the id paints the rock (exterior texture / relief / finish) and the density
			# weighs it. They come from the same resolved host rock, so they cannot disagree —
			# `inert_density` stays because rocks persisted before host_rock_id existed only have
			# that, and because it is what real_mass() reads on every tick.
			"host_rock_id": _resolved_host_rock_id(),
			"inert_density": _host_rock_density(),
		})
		index += 1
	_last_poi_culled = culled








	# Old code.....

	# var seed_str: String = stable_id if stable_id != "" \
	# 	else "%.2f,%.2f,%.2f" % [global_position.x, global_position.y, global_position.z]
	# var rng := RandomNumberGenerator.new()
	# rng.seed = hash(seed_str)
	# # Parent the rocks to the same networked frame the zone lives under (the planet/city that
	# # MOVES in world space), exactly like mining_depot — otherwise root-level (parent_id="")
	# # rocks are fixed in world space and instantly drift off the rotating planet, so the client
	# # renders them flying into space (invisible). Positions are thus expressed parent-local.
	# var net_parent: Node = _find_net_parent()
	# var parent_uuid: String = str(net_parent.uuid) if net_parent != null and "uuid" in net_parent else ""
	# var to_parent_local: Transform3D = Transform3D.IDENTITY
	# if net_parent is Node3D:
	# 	to_parent_local = (net_parent as Node3D).global_transform.affine_inverse()
	# var half: float = zone_size * 0.5
	# var placed: Array[Vector2] = []
	# var made: int = 0
	# var attempts: int = 0
	# var max_attempts: int = rock_count * 40
	# while made < rock_count and attempts < max_attempts:
	# 	attempts += 1
	# 	var lx: float = rng.randf_range(-half, half)
	# 	var lz: float = rng.randf_range(-half, half)
	# 	if _too_close(placed, lx, lz):
	# 		continue
	# 	var ground: Variant = _ground_point(to_global(Vector3(lx, 0.0, lz)))
	# 	if ground == null:
	# 		continue
	# 	placed.append(Vector2(lx, lz))
	# 	# Drop from a bit above the ground (along the zone's up) so it settles cleanly.
	# 	var spawn_world: Vector3 = (ground as Vector3) + global_transform.basis.y.normalized() * SPAWN_DROP
	# 	var local_pos: Vector3 = to_parent_local * spawn_world
	# 	_spawn_queue.append({
	# 		"type": "miningrock",
	# 		"uuid": PropSpawn.stable_uuid("%s#%d" % [seed_str, made]),
	# 		"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
	# 		"rotation": {"x": 0.0, "y": rng.randf_range(0.0, TAU), "z": 0.0},
	# 		"scenename": _pick_scene(rng),
	# 		"parent_id": parent_uuid,
	# 		"ore_seed": _ore_seed_for_richness(seed_str, made),
	# 		"mineral_id": mineral_id,
	# 	})
	# 	made += 1

func _too_close(placed: Array[Vector2], lx: float, lz: float) -> bool:
	for p in placed:
		if p.distance_to(Vector2(lx, lz)) < min_spacing:
			return true
	return false

## Raycast down along the zone's up axis to find the terrain / structure surface under a point.
## Returns the raw hit ({position, normal, ...}), or {} if nothing was hit there — the NORMAL is
## what lets a rock be laid flat on a slope instead of dropped. MUST be called from the physics step
## (direct_space_state is null outside it).
func _ground_hit(world_xz: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	var up: Vector3 = global_transform.basis.y.normalized()
	const SEARCH := 300.0
	var query := PhysicsRayQueryParameters3D.create(
		world_xz + up * SEARCH, world_xz - up * SEARCH, Globals.MASK_OBSTACLE)
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return {}
	# Validate the hit in DOUBLE precision, as PropSpawn.ground_point does: at this project's
	# astronomic coordinates the ray's own origin is imprecise in Jolt's float32 narrowphase, so a
	# ray can "catch" a collider far away and report a hit metres off. Anything beyond the search
	# span is an artefact — dropping the point beats burying a rock inside a hillside.
	if (hit["position"] as Vector3).distance_to(world_xz) > SEARCH * 1.5:
		return {}
	return hit

func _pick_scene(rng: RandomNumberGenerator) -> String:
	var total: float = weight_small + weight_medium + weight_large
	if total <= 0.0:
		return SCENE_SMALL
	var r: float = rng.randf() * total
	if r < weight_small:
		return SCENE_SMALL
	if r < weight_small + weight_medium:
		return SCENE_MEDIUM
	return SCENE_LARGE

## Density (kg/m3) of the zone's barren host rock, sent with every rock as `inert_density`.
##
## Resolution order: this zone's own override, then the planet's geology, then granite. The planet
## step is what carries a planner-seeded zone: `host_rock_id` is NOT part of the miningzone channel
## (see the networking note above), so a zone Horizon replays at boot has whatever the export
## defaults to and nothing else — but it always knows which planet it sits on. Reading the geology
## from PlanetData also keeps a whole planet consistent from ONE field instead of hundreds of zones.
##
## The DENSITY travels as `inert_density`, and the id itself as `host_rock_id` — both in the
## miningrock channel, because the client needs the id to PAINT the rock (exterior texture, relief,
## finish; see RockMining._make_rock_material). `host_rock_id` was sent by _build_spawn_queue long
## before it existed in miningrock_def.json, and Horizon silently drops any property missing from
## that file (ObjectDefinition::order_data), so every rock rendered with the fallback Rock029
## texture. Adding a field here means adding it there too, or it goes nowhere.
func _host_rock_density() -> float:
	var id: String = _resolved_host_rock_id()
	if not MineralRegistry.has_mineral(StringName(id)):
		return RockMining.INERT_DENSITY_DEFAULT
	return MineralRegistry.get_mineral(StringName(id)).density_kg_m3


## This zone's host rock id after the override -> planet fallback, or "" when neither answers.
func _resolved_host_rock_id() -> String:
	if host_rock_id != "":
		return host_rock_id
	var terrain := _planet_terrain()
	if terrain != null and terrain.planet_data != null:
		return terrain.planet_data.mining_zone_host_rock
	return ""

## Pick an ore_seed whose DERIVED richness (the same hash the rock uses) lands closest to the
## zone target. ore_seed is replicated, so this controls ore amount with no extra plumbing.
func _ore_seed_for_richness(seed_str: String, index: int) -> String:
	var best_seed: String = "%s|ore%d" % [seed_str, index]
	var best_err: float = 1.0
	for k in 48:
		var candidate: String = "%s|ore%d|%d" % [seed_str, index, k]
		var rich: float = float(absi(candidate.hash()) % 1000) / 1000.0
		var err: float = absf(rich - richness)
		if err < best_err:
			best_err = err
			best_seed = candidate
		if err <= richness_spread:
			return candidate
	return best_seed

# ── Editor preview (transient, not networked, not saved) ───────────────────────

## Populate a transient "PreviewRocks" child with rock instances laid out like _generate
## would (flat y=0 — no physics raycast in the editor) so the field can be eyeballed.
func _build_preview() -> void:
	_clear_preview()

	var holder := Node3D.new()
	holder.name = "PreviewRocks"
	add_child(holder)  # no owner set -> not saved into the scene



	var rng := RandomNumberGenerator.new()
	rng.seed = hash(stable_id if stable_id != "" else "preview")
	var half: float = zone_size * 0.5
	var points = poisson_disk_fast(
		Rect2(-half, -half, zone_size, zone_size), min_spacing, rock_count, rng)
	for point in points:
		var inst: Node3D = preload_scenes[SCENE_SMALL].instantiate()
		holder.add_child(inst)
		inst.position = Vector3(point.x, 0.0, point.y)
		inst.rotation.y = rng.randf_range(0.0, TAU)

	# var holder := Node3D.new()
	# holder.name = "PreviewRocks"
	# add_child(holder)  # no owner set -> not saved into the scene
	# var rng := RandomNumberGenerator.new()
	# rng.seed = hash(stable_id if stable_id != "" else "preview")
	# var half: float = zone_size * 0.5
	# var placed: Array[Vector2] = []
	# var made: int = 0
	# var attempts: int = 0
	# while made < rock_count and attempts < rock_count * 40:
	# 	attempts += 1
	# 	var lx: float = rng.randf_range(-half, half)
	# 	var lz: float = rng.randf_range(-half, half)
	# 	if _too_close(placed, lx, lz):
	# 		continue
	# 	placed.append(Vector2(lx, lz))
	# 	var scene: PackedScene = load("res://" + _pick_scene(rng))
	# 	var inst: Node3D = scene.instantiate()
	# 	holder.add_child(inst)
	# 	inst.position = Vector3(lx, 0.0, lz)
	# 	inst.rotation.y = rng.randf_range(0.0, TAU)
	# 	made += 1

func _clear_preview() -> void:
	var holder := get_node_or_null("PreviewRocks")
	if holder != null:
		holder.free()


## [param rng] is REQUIRED, not optional: the layout must be reproducible from the zone's seed so a
## regenerated field lands on the rocks it already has. Callers pass their own seeded stream.
func poisson_disk_fast(region: Rect2, min_dist: float, num_points: int,
		rng: RandomNumberGenerator) -> Array[Vector2]:
	var points: Array[Vector2] = []
	var grid := {}  # Dictionary[Vector2i, Vector2]
	var cell_size := min_dist / sqrt(2.0)
	var attempts := 30

	for _i in range(num_points):
		for _attempt in range(attempts):
			var candidate := Vector2(
				rng.randf_range(region.position.x, region.end.x),
				rng.randf_range(region.position.y, region.end.y)
			)
			if _is_valid(candidate, region, cell_size, grid, min_dist):
				points.append(candidate)
				grid[_to_cell(candidate, region, cell_size)] = candidate
				break

	return points

func _to_cell(p: Vector2, region: Rect2, cell_size) -> Vector2i:
	return Vector2i(
		int((p.x - region.position.x) / cell_size),
		int((p.y - region.position.y) / cell_size)
	)

func _is_valid(candidate: Vector2, region, cell_size, grid: Dictionary, min_dist: float) -> bool:
	var cell := _to_cell(candidate, region, cell_size)
	# On vérifie uniquement les 25 cellules voisines (5x5)
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var neighbor := cell + Vector2i(dx, dy)
			if grid.has(neighbor):
				if candidate.distance_to(grid[neighbor]) < min_dist:
					return false
	return true

## PropSync applies the replicated transform, then hands us the rest of the "miningzone" channel:
## the whole field config plus the persisted generation state. Note this runs BEFORE _ready() for a
## network-created zone (server.gd calls client_channel_data_update on the instance before adding it
## to the tree), which is why it — and not _ready() — is what arms the server detection loop.
func apply_prop_data(data: Dictionary) -> void:
	if "zone_size" in data:
		zone_size = data["zone_size"]
	if "rock_count" in data:
		rock_count = data["rock_count"]
	if "min_spacing" in data:
		min_spacing = data["min_spacing"]
	if "weight_small" in data:
		weight_small = data["weight_small"]
	if "weight_medium" in data:
		weight_medium = data["weight_medium"]
	if "weight_large" in data:
		weight_large = data["weight_large"]
	if "richness" in data:
		richness = data["richness"]
	if "richness_spread" in data:
		richness_spread = data["richness_spread"]
	if "mineral_id" in data:
		mineral_id = data["mineral_id"]
	if "generated" in data:
		generated = data["generated"]
	if "last_generation_datetime" in data:
		last_generation_datetime = data["last_generation_datetime"]
	
	# Deliberately NOT arming detection here. Horizon replays every stored zone at boot, and on a
	# planet seeded by MiningZonePlanner that is hundreds of them — each would then run its own
	# _physics_process forever. MiningZonePlanner arms only the zone under a player and disarms it
	# on the way out, which is the same detection at O(players) instead of O(zones).

## Server: start looking for nearby players (in _physics_process). Detection is a script distance
## check, so we make sure the legacy physics TriggerArea stays OFF — a monitoring Area3D here scans
## every body in its radius each physics step, and with hundreds of zones over a rock field that
## broadphase scan alone crushes the server to a few fps.
func enable_server_detection() -> void:
	var own_trigger: Area3D = get_node_or_null("TriggerArea") as Area3D
	if own_trigger != null:
		own_trigger.monitoring = false
	set_physics_process(true)

func disable_server_detection() -> void:
	set_physics_process(false)
