@tool
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

const SCENE_SMALL := "scenes/props/rock/rock_mining_small.tscn"
const SCENE_MEDIUM := "scenes/props/rock/rock_mining_medium.tscn"
const SCENE_LARGE := "scenes/props/rock/rock_mining_large.tscn"
# One rock is spawned every SPAWN_INTERVAL_FRAMES physics frames while draining the queue, to
# spread the create_object burst so Horizon's message channel never overflows (a flood of
# create_object messages gets dropped -> the rocks exist server-side but never reach clients).
const SPAWN_INTERVAL_FRAMES := 6
# Height (m) above the detected ground a rock is dropped from, so it FALLS and settles
# cleanly (each frame replicated) instead of spawning half-buried in the surface — a buried
# spawn makes the server eject+sleep the body, leaving the frozen client mesh ~1 m off.
const SPAWN_DROP := 2.0

@export_group("Identity")
## Seed for the deterministic rock UUIDs, so regenerating the SAME zone never duplicates
## rocks in the DB. Leave EMPTY to derive it from the zone's world position.
@export var stable_id: String = ""

@export_group("Field")
## Side length (m) of the square region rocks are scattered over, centered on the zone.
@export var field_size: float = 500.0
## How many rocks to generate when the zone is (re)populated.
@export var rock_count: int = 30
## Minimum spacing (m) between two rocks, to avoid overlaps.
@export var min_spacing: float = 8.0
## Relative share of each size in the mix (small, medium, large). Any positive ratio works.
@export var weight_small: float = 0.6
@export var weight_medium: float = 0.3
@export var weight_large: float = 0.1

@export_group("Ore")
## Zone ore richness 0..1 (poor..rich). Picks each rock's ore_seed so its derived richness
## sits near this target — works WITHOUT any extra replication (ore_seed is already synced).
@export_range(0.0, 1.0) var richness: float = 0.5
## How tightly rock richness hugs the target (smaller = tighter spread around `richness`).
@export_range(0.0, 0.5) var richness_spread: float = 0.12
## Which mineral this zone yields (must match a key in rock_mining.gd MINERALS: gold, iron,
## cryptonite, ...). Replicated per rock via the ore channel and applied on every client.
@export var mineral_id: String = "gold"

@export_group("Detection")
## The Area3D (the ~1 km trigger) that detects players. Assign the child Area3D.
@export var trigger_area: Area3D

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

var _pending_generate: bool = false
var _spawn_queue: Array[Dictionary] = []
var _spawn_tick: int = 0

func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)  # the editor runs @tool scripts; no server logic there
		return
	# Always use our OWN TriggerArea child unless trigger_area is explicitly set to one of our
	# descendants. Prevents accidentally wiring a sibling area (e.g. the ambience Area3D), which
	# both mis-triggers the zone AND disables that area's monitoring on clients.
	var own_trigger: Area3D = get_node_or_null("TriggerArea") as Area3D
	if trigger_area == null or (own_trigger != null and not is_ancestor_of(trigger_area)):
		trigger_area = own_trigger
	if trigger_area == null:
		push_warning("MiningZone: no TriggerArea found, zone disabled.")
		set_physics_process(false)
		return
	# Only the server detects players, raycasts and spawns; clients do nothing.
	var is_srv: bool = GameOrchestrator.is_server()
	trigger_area.monitoring = is_srv
	set_physics_process(is_srv)
	if is_srv:
		trigger_area.body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		_pending_generate = true

# Server only (physics process is disabled on clients). On a pending request, (re)generate
# only if the field is currently empty AND we are not already mid-spawn — so an entry into a
# populated zone does nothing, and a fully-mined zone repopulates on the next entry. The
# ground raycasts happen here (direct_space_state is only valid during the physics step).
# Then drain the spawn queue a few rocks per frame to spread the burst.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _pending_generate:
		_pending_generate = false
		if _spawn_queue.is_empty() and not _has_rocks_in_field():
			_build_spawn_queue()
	if not _spawn_queue.is_empty():
		_spawn_tick += 1
		if _spawn_tick >= SPAWN_INTERVAL_FRAMES:
			_spawn_tick = 0
			NetworkOrchestrator.spawn_prop_authoritative(_spawn_queue.pop_back())

## True if any mining rock currently sits inside this zone's square field.
func _has_rocks_in_field() -> bool:
	var half: float = field_size * 0.5
	for r in get_tree().get_nodes_in_group("miningrock"):
		if r is Node3D:
			var local: Vector3 = to_local((r as Node3D).global_position)
			if absf(local.x) <= half and absf(local.z) <= half:
				return true
	return false

## Seed the RNG and fill _spawn_queue with ready-to-send rock spawn data. All ground
## raycasts are done here (called from _physics_process) so the physics space is available.
func _build_spawn_queue() -> void:
	# Parent the rocks to the same networked frame the zone lives under (the planet/city that
	# MOVES in world space), exactly like mining_depot — otherwise root-level (parent_id="")
	# rocks are fixed in world space and instantly drift off the rotating planet, so the client
	# renders them flying into space (invisible). Positions are thus expressed parent-local.
	var net_parent: Node = _find_net_parent()
	var parent_uuid: String = str(net_parent.uuid) if net_parent != null and "uuid" in net_parent else ""
	var to_parent_local: Transform3D = Transform3D.IDENTITY
	if net_parent is Node3D:
		to_parent_local = (net_parent as Node3D).global_transform.affine_inverse()
	# Seed from the STABLE placement in the PARENT's frame + parent uuid, NEVER from global_position:
	# the parent is a moving world frame — and now a SPINNING one — so global_position changes on
	# every restart and every spin step, yielding a new uuid each time. The DB upserts by uuid, so it
	# would never dedup and rocks would pile up forever. Same reasoning and shape as mining_depot.
	var place_pos: Vector3 = (to_parent_local * global_transform).origin
	var seed_str: String = stable_id if stable_id != "" \
		else "%s|%.2f,%.2f,%.2f" % [parent_uuid, place_pos.x, place_pos.y, place_pos.z]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_str)
	var half: float = field_size * 0.5
	var placed: Array[Vector2] = []
	var made: int = 0
	var attempts: int = 0
	var max_attempts: int = rock_count * 40
	while made < rock_count and attempts < max_attempts:
		attempts += 1
		var lx: float = rng.randf_range(-half, half)
		var lz: float = rng.randf_range(-half, half)
		if _too_close(placed, lx, lz):
			continue
		var ground: Variant = _ground_point(to_global(Vector3(lx, 0.0, lz)))
		if ground == null:
			continue
		placed.append(Vector2(lx, lz))
		# Drop from a bit above the ground (along the zone's up) so it settles cleanly.
		var spawn_world: Vector3 = (ground as Vector3) + global_transform.basis.y.normalized() * SPAWN_DROP
		var local_pos: Vector3 = to_parent_local * spawn_world
		_spawn_queue.append({
			"type": "miningrock",
			"uuid": _stable_uuid("%s#%d" % [seed_str, made]),
			"position": {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z},
			"rotation": {"x": 0.0, "y": rng.randf_range(0.0, TAU), "z": 0.0},
			"scenename": _pick_scene(rng),
			"parent_id": parent_uuid,
			"ore_seed": _ore_seed_for_richness(seed_str, made),
			"mineral_id": mineral_id,
		})
		made += 1

## Nearest ancestor that is a networked object (has a `uuid`) — the frame rocks are parented
## to so they move with the planet/city instead of staying fixed in world space. Mirrors
## mining_depot's net-parent walk.
func _find_net_parent() -> Node:
	var n: Node = get_parent()
	while n != null and not ("uuid" in n):
		n = n.get_parent()
	return n

func _too_close(placed: Array[Vector2], lx: float, lz: float) -> bool:
	for p in placed:
		if p.distance_to(Vector2(lx, lz)) < min_spacing:
			return true
	return false

## Raycast down along the zone's up axis to drop the rock onto the terrain / structures.
## Returns the world hit position, or null if nothing was hit there. MUST be called from
## the physics step (direct_space_state is null outside it).
func _ground_point(world_xz: Vector3) -> Variant:
	var space := get_world_3d().direct_space_state
	if space == null:
		return null
	var up: Vector3 = global_transform.basis.y.normalized()
	var query := PhysicsRayQueryParameters3D.create(world_xz + up * 300.0, world_xz - up * 300.0)
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.position

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

## Deterministic, valid-format uuid from a seed string (same seed -> same uuid across reboots,
## so the DB upserts instead of piling duplicates). Mirrors mining_depot._stable_uuid.
func _stable_uuid(seed_str: String) -> String:
	var h: String = seed_str.sha256_text()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]

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
	var half: float = field_size * 0.5
	var placed: Array[Vector2] = []
	var made: int = 0
	var attempts: int = 0
	while made < rock_count and attempts < rock_count * 40:
		attempts += 1
		var lx: float = rng.randf_range(-half, half)
		var lz: float = rng.randf_range(-half, half)
		if _too_close(placed, lx, lz):
			continue
		placed.append(Vector2(lx, lz))
		var scene: PackedScene = load("res://" + _pick_scene(rng))
		var inst: Node3D = scene.instantiate()
		holder.add_child(inst)
		inst.position = Vector3(lx, 0.0, lz)
		inst.rotation.y = rng.randf_range(0.0, TAU)
		made += 1

func _clear_preview() -> void:
	var holder := get_node_or_null("PreviewRocks")
	if holder != null:
		holder.free()
