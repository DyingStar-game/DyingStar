class_name LavaFlow
extends Node3D
## The lava of one volcano's eruption as a networked prop (Horizon type "lava_flow", items_def/lava_flow_def.json).
##
## The game server (server/lava_eruptions.gd) samples the crater once, then publishes here what every peer needs
## to run the same deterministic simulation (LavaPlanetPatch, lava_fixed_core.gd):
##   zone 6  the patch description (frame, source) and the integer eruption plan;
##   zone 2  the canonical checkpoint (deflate + base64) and its tick, refreshed every minute: what a client
##           arriving mid-eruption, or one that diverged, starts from;
##   zone 1  the authority's tick and the digest of its state, every 5 s: replicas compare theirs.
## A client never resamples the terrain: it restores the checkpoint, then derives the crater commands of every
## following tick from the plan (PlanetTerrain.lava_runtime drives the ticks on the shared clock).
##
## One prop per volcano (stable uuid), reused by each eruption: a new plan replaces the previous patch. The
## server deletes the prop once the deposit has cooled and gone. No geometry and nothing to do on the server.

## Horizon type and scene of the prop.
const TYPE := "lava_flow"
const SCENE := "scenes/planet/lava/lava_flow.tscn"
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
## Ticks after the end of the eruption past which a received state is stale: cooling and removal take ~302 s.
const STALE_AFTER_END_TICKS := 3600
## A checkpoint older than this (ticks) is not worth catching up from: the next one is awaited instead.
const MAX_CATCH_UP_TICKS := 12000
## Largest checkpoint accepted (bytes): a 256 x 256 polar grid with its crater.
const MAX_CHECKPOINT_BYTES := 144 + (2 * Core.MAX_SIDE + 1) * 8 + Core.MAX_SIDE * Core.MAX_SIDE * 72

## Every field received so far: an update only carries what changed.
var _data: Dictionary = {}
var _runtime: Node3D = null
var _key := ""
## Plan start and checkpoint tick of the patch installed from this prop (to reinstall only when they change).
var _installed_start := -1
var _installed_tick := -1


## The prop's uuid for the volcano [param volcano_key] of [param planet_name]: the same on every server and
## every boot, so a server finds a persisted one again.
static func uuid_for(planet_name: String, volcano_key: String) -> String:
	return PropSpawn.stable_uuid("lava_flow:%s:%s" % [planet_name, volcano_key])


## "<raw size>:<base64 of the deflated checkpoint>" (~100-200 KB for an active 96 x 96 field, 665 KB raw).
static func encode_checkpoint(bytes: PackedByteArray) -> String:
	return "%d:%s" % [bytes.size(), Marshalls.raw_to_base64(bytes.compress(FileAccess.COMPRESSION_DEFLATE))]


## The checkpoint of [method encode_checkpoint], or empty when malformed. Restoring validates it further.
static func decode_checkpoint(text: String) -> PackedByteArray:
	var colon := text.find(":")
	if colon <= 0 or not text.substr(0, colon).is_valid_int():
		return PackedByteArray()
	var size := text.substr(0, colon).to_int()
	if size < 144 or size > MAX_CHECKPOINT_BYTES:
		return PackedByteArray()
	var packed := Marshalls.base64_to_raw(text.substr(colon + 1))
	if packed.is_empty():
		return PackedByteArray()
	var bytes := packed.decompress(size, FileAccess.COMPRESSION_DEFLATE)
	return bytes if bytes.size() == size else PackedByteArray()


## A Transform3D as 12 numbers (basis columns, then origin): JSON carries no Transform3D.
static func frame_to_array(frame: Transform3D) -> Array:
	var b := frame.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, frame.origin.x, frame.origin.y, frame.origin.z]


## The frame of [method frame_to_array], orthonormalized again (JSON rounding), or null when malformed.
static func array_to_frame(values: Variant) -> Variant:
	if not values is Array or (values as Array).size() != 12:
		return null
	var v: Array = values
	for n in v:
		if typeof(n) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(n)):
			return null
	var basis := Basis(Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]), Vector3(v[6], v[7], v[8]))
	if absf(basis.determinant() - 1.0) > 0.001:
		return null
	return Transform3D(basis.orthonormalized(), Vector3(v[9], v[10], v[11]))


## The replicated fields describing a built patch [param packet] under [param plan] (zone 6), without its state.
static func description_fields(packet: Dictionary, plan: Dictionary) -> Dictionary:
	return {"planet_name": packet.planet, "volcano_key": packet.volcano_key, "patch_key": packet.key,
		"frame": frame_to_array(packet.frame), "source_radius_mm": int(packet.source_radius_mm),
		"source_temperature_t": int(packet.source_temperature_t), "source_rate_q": int(packet.source_rate_q),
		"crater_rows": int(packet.crater_rows), "field_radius_m": float(packet.field_radius_m), "plan": plan}


## The install_patch description carried by prop data [param data], or {} while incomplete or invalid.
static func description_from(data: Dictionary) -> Dictionary:
	var frame: Variant = array_to_frame(data.get("frame"))
	var plan: Variant = data.get("plan")
	if frame == null or not plan is Dictionary or not Builder.valid_plan(plan):
		return {}
	if str(data.get("patch_key", "")).is_empty() or not data.get("checkpoint") is String:
		return {}
	var checkpoint := decode_checkpoint(data.checkpoint)
	if checkpoint.is_empty():
		return {}
	var typed_plan := {}
	for field: String in (plan as Dictionary):
		typed_plan[field] = int(plan[field])
	return {"key": str(data.patch_key), "planet": str(data.get("planet_name", "")),
		"volcano_key": str(data.get("volcano_key", "")), "frame": frame,
		"source_x_mm": 0, "source_z_mm": 0, "source_radius_mm": int(data.get("source_radius_mm", 0)),
		"source_temperature_t": int(data.get("source_temperature_t", 12000)),
		"source_rate_q": int(data.get("source_rate_q", 0)), "crater_rows": int(data.get("crater_rows", 0)),
		"field_radius_m": float(data.get("field_radius_m", 0.0)), "plan": typed_plan, "checkpoint": checkpoint}


## Ticks of [param plan] elapsed at [param clock_ms].
static func ticks_at(plan: Dictionary, clock_ms: int) -> int:
	return maxi(0, (clock_ms - int(plan.get("start_unix_ms", 0))) / 100)


## PropSync: the replicated fields of this lava flow.
func apply_prop_data(data: Dictionary) -> void:
	_data.merge(data, true)
	if is_inside_tree():
		_refresh()


## Not _ready: a networked prop may be reparented (_exit_tree then _enter_tree, _ready only once).
func _enter_tree() -> void:
	if not _data.is_empty():
		_refresh()


func _exit_tree() -> void:
	if is_instance_valid(_runtime) and not _key.is_empty():
		_runtime.remove_patch(_key)
	_runtime = null
	_key = ""
	_installed_start = -1
	_installed_tick = -1


func _refresh() -> void:
	var runtime := _lava_runtime()
	if runtime == null or runtime.server_mode:
		return  # the server's patch belongs to LavaEruptions, not to this node
	_runtime = runtime
	var plan: Variant = _data.get("plan")
	var key := str(_data.get("patch_key", ""))
	if plan is Dictionary and not key.is_empty():
		var start := int((plan as Dictionary).get("start_unix_ms", -1))
		var checkpoint_tick := int(_data.get("checkpoint_tick", -1))
		var installed: bool = runtime.patches.has(key) and _key == key and _installed_start == start
		if not installed or (runtime.is_diverged(key) and checkpoint_tick != _installed_tick):
			_install(runtime, key, start, checkpoint_tick)
	if runtime.patches.has(_key) and _data.has("digest") and _data.has("tick"):
		runtime.expect_digest(_key, int(_data.tick), str(_data.digest))


func _install(runtime: Node3D, key: String, start: int, checkpoint_tick: int) -> void:
	var plan: Dictionary = _data.plan
	var now := int(runtime.clock_ms.call())
	var target := ticks_at(plan, now)
	if target > int(plan.get("eruption_ticks", 0)) + STALE_AFTER_END_TICKS:
		return  # a deposit long gone: nothing to show, the server deletes the prop
	if checkpoint_tick < 0 or target - checkpoint_tick > MAX_CATCH_UP_TICKS:
		return  # too old to catch up from: the next checkpoint comes within a minute
	var description := description_from(_data)
	if description.is_empty():
		return
	if not _key.is_empty() and _key != key:
		runtime.remove_patch(_key)
	if runtime.install_patch(description):
		_key = key
		_installed_start = start
		_installed_tick = checkpoint_tick
	else:
		push_warning("[LavaFlow] patch %s refused (budget, planet or checkpoint)" % key)


## The lava runtime of the planet this prop stands on, or null (no terrain, or lava not simulated).
func _lava_runtime() -> Node3D:
	if Engine.is_editor_hint():
		return null
	var planet := Planet.of(self)
	if planet == null or planet.planet_terrain == null:
		return null
	return planet.planet_terrain.lava_runtime
