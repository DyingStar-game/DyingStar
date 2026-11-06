class_name OreProcessor
extends NetStaticBody  # the uuid facade (see NetStaticBody)

## Base of every ore-processing machine (Crusher, Refinery, and the ones to come): an input belt that
## feeds a collector, a stock, an EXTRACT button and an output belt that spits a hauling crate.
## Everything a machine shares lives here — the networked self-spawn of a designer placeholder, the
## belts, the server-only detectors, the throttled replication, the 3D screen contract and the crate
## spawn. What a machine ACCEPTS, what it does with it and what crate it makes is its subclass's job
## (the virtual _accepts / _consume / _next_crate / _client_ui below).
##
## Networking lives in the PropSync child (type_name "mining_depot" for every machine: the type is
## only Horizon's whitelist of `data`, the scene tells the machines apart). Machine state is applied
## via apply_prop_data(); server-side updates go out via server_prop_update().

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## The crate every machine packs into. It replicates as the "crate_container" TYPE (that def is the one
## whose channels carry `content`) — only the scene differs. Its physical size is what crate_volume()
## reads to decide how much matter fills one crate.
const CRATE_SCENE = preload("res://scenes/_universe/props/containers/hauling_box.tscn")
const CRATE_SCENENAME = "scenes/_universe/props/containers/hauling_box.tscn"
## How long the output belt runs after a crate is spawned (s): feedback only, the crate spawns at
## the belt end.
const EXTRACT_RUN_S := 2.5
## The screen's pictograms (white on transparent, tinted): what each message is about, at a glance.
const ICON_ORE := preload("res://assets/ui/icons/mining/icon_plate_ore.png")
const ICON_INGOT := preload("res://assets/ui/icons/mining/icon_plate_ingot.png")
const ICON_ROCKS := preload("res://assets/ui/icons/mining/icon_plate_content.png")
const ICON_CRATE := preload("res://assets/textures/mission_categories/delivery.png")
## Picto tints: the screen's own light grey for a message, its orange for a refusal.
const SCREEN_INK := Color(0.81, 0.81, 0.81)
const WARNING_INK := Color(1.0, 0.52, 0.27)
const PICTO_PX := 150
## How long a machine works on a crate (s): crushing at the Crusher, refining at the Refinery. The
## screen counts it down on a ring, the machine sounds run meanwhile.
const PROCESS_S := 10.0
const RING_PX := 220
## How often the server runs a machine's logic (s): belts, collection, replication (see _process).
const SERVER_TICK_S := 0.2

## Designer-placed machine: tick it on the instance dropped in a world scene. On the server it spawns
## the REAL networked machine at the same spot (deterministic uuid) and frees itself.
@export var placeholder = false
## Optional explicit network id for a designer-placed machine. Leave EMPTY and it is derived
## automatically from the machine's fixed position (stable across restarts, no setup needed).
## Set a unique string only if you want a readable id or to keep identity when moving it.
@export var stable_id: String = ""

@export_group("Sounds")
## The belts running (input or output), looped while they move.
@export var sfx_belt: AudioStream = preload("res://assets/_universe/audio/sfx/machine/conveyor-belt-loop.ogg")
## Volume of the belts (dB at the falloff distance).
@export_range(-40.0, 12.0, 0.5) var sfx_belt_db: float = -8.0
## The machine at work (crushing / refining), looped for PROCESS_S.
@export var sfx_process: AudioStream = preload("res://assets/_universe/audio/sfx/machine/generator-loop.ogg")
## Volume of the machine at work (dB at the falloff distance).
@export_range(-40.0, 12.0, 0.5) var sfx_process_db: float = -4.0
## Stones rattling inside the machine at work, layered with sfx_process (the gravel a truck throws
## against its underbody).
@export var sfx_rattle: AudioStream = preload("res://assets/_universe/audio/sfx/vehicles/ground/wheel_struck_constant.mp3")
## Volume of the rattling stones (dB at the falloff distance).
@export_range(-40.0, 12.0, 0.5) var sfx_rattle_db: float = -8.0
## Distance (m) at which the machine's sounds play at their set volume.
@export_range(0.5, 50.0, 0.5) var sfx_falloff: float = 6.0
## Distance (m) beyond which the machine is not heard at all.
@export_range(1.0, 300.0, 1.0) var sfx_distance: float = 60.0
@export_group("")

var type_name = "mining_depot"  # kept for the placeholder self-spawn; PropSync carries the networked copy
## "idle", "collect" (input belt running), "extract" (output belt running) or "blocked" (the input
## belt holds something the machine refuses — see _belt_blocked).
var state := "idle"
## Accepted items on the input belt.
var belt_count := 0
## Whether a whole crate is ready: what the EXTRACT button is gated on. A SERVER fact (see
## _can_pack), replicated.
var packable := false
## The machine-specific part of the replicated state (see _extra_state / _apply_extra_state).
var extra: Dictionary = {}
## Who is using the screen right now (server). Set through set_screen_actor.
var active_player: Player

# Throttle: only replicate when the state actually changes.
var _last_sent: Dictionary = {}
# The messages' pictograms on the splash screen (client): one or two side by side.
var _pictos: HBoxContainer = null
# The countdown ring while the machine works (client).
var _ring: ItemDispenserUI.DeliveryRing = null
# SERVER: when the work in progress ends (Time.get_ticks_msec()).
var _process_end_ms := 0
# SERVER: time left before the next _server_tick.
var _server_wait_s := 0.0
# The looping sounds (client): belts, machine at work, its rattling stones.
var _belt_player: AudioStreamPlayer3D = null
var _process_player: AudioStreamPlayer3D = null
var _rattle_player: AudioStreamPlayer3D = null

@onready var rock_depot_ui: Panel = %RockDepotUI
@onready var danger_light_collect: Node3D = $DangerLightCollect
@onready var rock_conveyor: MeshInstance3D = $miningdepot/conveyorbelt_001
@onready var rock_detector: Area3D = $RockDetector
@onready var rock_collector: Area3D = $RockCollector
@onready var box_spawn_origin: Marker3D = $BoxSpawnOrigin
@onready var box_conveyorbelt: MeshInstance3D = $miningdepot/conveyorbelt_003
@onready var danger_light_box: Node3D = $DangerLightBox
@onready var box_detector: Area3D = $BoxDetector


# ── Virtuals: what makes one machine differ from another ───────────────────────────────────────────

## Whether [param body] on the input belt is something this machine takes.
func _accepts(_body: Node) -> bool:
	return false

## Whether the belt as a whole must be refused (e.g. the Refinery takes one crate at a time).
## [param bodies] = every body on the input belt, accepted or not.
func _belt_blocked(_bodies: Array) -> bool:
	return false

## SERVER: take [param body] into the stock (it is freed by the caller afterwards).
func _consume(_body: Node) -> void:
	pass

## SERVER: whether a whole crate can be packed now.
func _can_pack() -> bool:
	return false

## SERVER: take one crate's worth out of the stock and return its `content` (see CrateContent), or {}
## when nothing can be packed. [param miner_id] / [param miner_name] = the player extracting (service
## identity / login, the plate's owner).
func _next_crate(_miner_id: String, _miner_name: String) -> Dictionary:
	return {}

## SERVER: whether the machine packs on its own as soon as it can (no EXTRACT press).
func _auto_extract() -> bool:
	return false

## The machine's name, the screen's title.
func _title_key() -> String:
	return ""

## The caption of the small figure at the top right of the screen.
func _corner_caption_key() -> String:
	return "%%HUD_CURRENT_STOCK"

## What the screen says while the machine works (PROCESS_S), over the countdown ring.
func _processing_key() -> String:
	return ""

## SERVER: machine-specific replicated state, merged into the `data` envelope.
func _extra_state() -> Dictionary:
	return {}

## CLIENT: drive the screen from the replicated state.
func _client_ui() -> void:
	pass


# ── Lifecycle ─────────────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	if placeholder:
		if GameOrchestrator.is_server():
			await get_tree().create_timer(1).timeout
			_spawn_networked_copy()
		queue_free()
		return  # placeholder is done; don't wire detectors on the node we just freed

	if GameOrchestrator.is_server():
		box_detector.body_exited.connect(_on_box_exited)
		rock_detector.body_exited.connect(_on_belt_exited)
	else:
		(_ui("VB/Title") as Label).text = _title_key()
		(_ui("RockTotalLabel") as Label).text = _corner_caption_key()
		# A machine's messages run longer than the old depot's two lines: wrap them inside the screen,
		# under the message's picto (which takes the room the old label kept empty).
		var message := _ui("VB/Splashscreen/Label3") as Label
		message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		message.custom_minimum_size.y = 230
		_pictos = HBoxContainer.new()
		_pictos.alignment = BoxContainer.ALIGNMENT_CENTER
		_pictos.add_theme_constant_override("separation", 30)
		_ring = ItemDispenserUI.DeliveryRing.new()
		_ring.custom_minimum_size = Vector2(RING_PX, RING_PX)
		_ring.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_ring.colour = SCREEN_INK
		_ring.font = AresBrand.font()
		_ring.font_size = 90
		_ring.visible = false
		var splash := _ui("VB/Splashscreen")
		for node: Control in [_ring, _pictos]:
			splash.add_child(node)
			splash.move_child(node, 0)
		if not Sfx3D.muted():
			_belt_player = _loop_player(sfx_belt, sfx_belt_db)
			_process_player = _loop_player(sfx_process, sfx_process_db)
			_rattle_player = _loop_player(sfx_rattle, sfx_rattle_db)
		# The belt and collector detectors only feed server logic (_process / _physics_process return
		# at once on a client), and each monitoring area costs a physics query every step: see the same
		# note in cargo_depot.gd.
		for area: Area3D in [rock_detector, rock_collector, box_detector]:
			area.set_deferred(&"monitoring", false)


## SERVER: replace this editor placeholder by the real networked machine. spawn_prop_authoritative
## registers it in Horizon AND creates it locally (the server copy holds the collision and the
## detectors; Horizon does not echo create_object back).
func _spawn_networked_copy() -> void:
	# Find the real networked parent up the tree (skip grouping / test-zone folder nodes that have
	# no uuid), so grouping the placeholder under a folder doesn't break placement.
	var net_parent: Node = get_parent()
	while net_parent != null and not ("uuid" in net_parent):
		net_parent = net_parent.get_parent()
	var parent_uuid: String = str(net_parent.uuid) if net_parent != null else ""
	# Express the placement in that parent's frame (global if there is no networked parent), so the
	# machine lands at the SAME world spot whatever the scene grouping.
	var place_xform: Transform3D = global_transform
	if net_parent is Node3D:
		place_xform = (net_parent as Node3D).global_transform.affine_inverse() * global_transform
	var place_pos: Vector3 = place_xform.origin
	var place_rot: Vector3 = place_xform.basis.get_euler()
	# Deterministic uuid seeded from the STABLE local placement (parent frame) + parent uuid, NOT
	# global_position: the parent is a moving world frame, so global_position differs every restart
	# -> a new uuid each time -> the DB (upsert by uuid) never dedups -> machines pile up.
	var uuid_seed: String = stable_id if stable_id != "" \
		else "%s|%.3f,%.3f,%.3f" % [parent_uuid, place_pos.x, place_pos.y, place_pos.z]
	var machine_uuid: String = PropSpawn.stable_uuid(uuid_seed)
	# Designer-placed machine = world infrastructure: protect it from the admin cleanup tool.
	NetworkOrchestrator.protected_prop_uuids[machine_uuid] = true
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": type_name,
		"uuid": machine_uuid,
		"position": {"x": place_pos.x, "y": place_pos.y, "z": place_pos.z},
		"rotation": {"x": place_rot.x, "y": place_rot.y, "z": place_rot.z},
		"data": {"state": "idle"},
		"scenename": scene_file_path.trim_prefix("res://"),
		"parent_id": parent_uuid,
	})


## In collect mode, an item that slides off the belt end (leaves the detector) is collected. Skip
## items a player just picked up (carried) so grabbing one off the belt doesn't count it.
func _on_belt_exited(body: Node3D) -> void:
	if state != "collect" or not _accepts(body):
		return
	if "carried" in body and body.carried:
		return
	_collect(body)


## Server: the machine's logic runs SERVER_TICK_S apart, not every frame — three area queries and a
## replication check per machine per frame bought nothing (the state replicates on change only).
## Client: the screen and the belts' look follow the replicated state every frame.
func _process(delta: float) -> void:
	if not GameOrchestrator.is_server():
		_client_tick()
		return
	_server_wait_s -= delta
	if _server_wait_s <= 0.0:
		_server_wait_s = SERVER_TICK_S
		_server_tick()


func _server_tick() -> void:
	var on_belt: Array = rock_detector.get_overlapping_bodies()
	var accepted: Array = filter_accepted(on_belt)
	var blocked := _belt_blocked(on_belt)
	if not blocked:
		for body in filter_accepted(rock_collector.get_overlapping_bodies()):
			if not ("carried" in body and body.carried):
				_collect(body)
	if blocked and state in ["idle", "collect"]:
		state = "blocked"
	elif not blocked and state == "blocked":
		state = "idle"
	if state == "collect" and accepted.is_empty():
		state = "idle"
	packable = _can_pack()
	if packable and state == "idle" and _auto_extract():
		state = "extract"
		handle_extract()
	belt_count = accepted.size()
	var payload := {"belt_count": belt_count, "state": state, "packable": packable}
	if state == "processing":
		payload["process_left"] = ceili(maxf(0.0, (_process_end_ms - Time.get_ticks_msec()) / 1000.0))
	payload.merge(_extra_state(), true)
	if payload != _last_sent:
		_last_sent = payload
		server_prop_update(payload)


func _client_tick() -> void:
	var processing := state == "processing"
	_ring.visible = processing
	if processing:
		_show_screen(true, _processing_key(), false)
		_ring.show_left(float(extra.get("process_left", PROCESS_S)), PROCESS_S)
	else:
		_client_ui()
	var running_in := state == "collect"
	var running_out := state == "extract"
	danger_light_collect.enabled = running_in
	danger_light_box.enabled = running_out
	rock_conveyor.set_instance_shader_parameter("animation_speed", 1.0 if running_in else 0.0)
	box_conveyorbelt.set_instance_shader_parameter("animation_speed", -1.0 if running_out else 0.0)
	_keep_playing(_belt_player, running_in or running_out)
	_keep_playing(_process_player, processing)
	_keep_playing(_rattle_player, processing)


## A looping positional sound of the machine, stopped until _keep_playing starts it.
func _loop_player(stream: AudioStream, db: float) -> AudioStreamPlayer3D:
	if stream == null:
		return null
	var player := AudioStreamPlayer3D.new()
	Sfx3D.configure(player, Sfx3D.as_looping(stream), db, sfx_falloff, sfx_distance, Sfx3D.Attenuation.REALISTIC)
	add_child(player)
	return player


static func _keep_playing(player: AudioStreamPlayer3D, on: bool) -> void:
	if player != null and player.playing != on:
		player.playing = on


## Server: drive the belts. In _physics_process, never _process: a force lasts ONE physics step (Jolt
## clears it after each), so pushed from _process it only acts on the first of the steps a slow frame
## catches up — the other steps are pure friction. With 2 steps per frame (any server frame over
## 16.7 ms) a rock crept 0.29 m in 4 s instead of reaching the collector: "the belt sometimes works".
func _physics_process(_delta: float) -> void:
	if not GameOrchestrator.is_server():
		return
	if state == "collect":
		_push_belt(filter_accepted(rock_detector.get_overlapping_bodies()), -rock_detector.global_basis.z * 2)
	elif state == "extract":
		_push_belt(box_detector.get_overlapping_bodies(), box_detector.global_basis.z * 2)


## Pull every body on a belt towards [param desired_velocity] (m/s, world space).
func _push_belt(bodies: Array, desired_velocity: Vector3) -> void:
	for body in bodies:
		if body is RigidBody3D:
			var rb: RigidBody3D = body
			rb.apply_central_force((desired_velocity - rb.linear_velocity) * rb.mass * 10.0)


## The bodies of [param bodies] this machine takes (see _accepts).
func filter_accepted(bodies: Array) -> Array:
	return bodies.filter(func(b: Node) -> bool: return _accepts(b))


## SERVER: the output belt is empty again: the machine goes back to idle.
func _on_box_exited(_body: Node3D) -> void:
	if state == "extract" and box_detector.get_overlapping_bodies().is_empty():
		state = "idle"


## SERVER: take [param body] in (see _consume) and remove it from the world.
func _collect(body: Node) -> void:
	if body.is_queued_for_deletion():
		return
	_consume(body)
	body.queue_free()


## Fillable volume of one crate (m3) — see CrateContent.crate_volume.
func crate_volume() -> float:
	return CrateContent.crate_volume()


# ── Replication ───────────────────────────────────────────────────────────────────────────────────

# Server-side state update: forward to the PropSync component, preserving the {"data": ...} envelope
# that the client half (apply_prop_data) expects. PropSync emits it with the machine's uuid/type_name.
func server_prop_update(data):
	var s := _prop_sync()
	if s != null:
		s.server_prop_update({"data": data})


# PropSync applies the replicated transform, then calls this with the full payload so the machine can
# apply its own state.
func apply_prop_data(_data: Dictionary) -> void:
	if not _data.has("data"):  # a generic spawn may omit "data"
		return
	var metadata: Dictionary = _data["data"]
	state = metadata.get("state", state)
	belt_count = int(metadata.get("belt_count", belt_count))
	packable = bool(metadata.get("packable", packable))
	extra.merge(metadata, true)


# ── Output ────────────────────────────────────────────────────────────────────────────────────────

## SERVER: work PROCESS_S on one crate's worth, then spit the crate out on the output belt and credit
## its goods. The stock is taken AFTER the work: a machine streamed out meanwhile loses nothing.
func handle_extract() -> void:
	# Who is extracting, captured BEFORE the awaits below: active_player is whoever stands at the
	# screen when they end, which is not the player being credited.
	var miner_id: String = active_player.client_uuid if active_player != null else ""
	# The player node is named after the login Horizon read from the token (preferred_username).
	var miner_name: String = str(active_player.name) if active_player != null else ""
	if not _can_pack():
		state = "idle"
		return
	# The machine works on it first: the screen counts PROCESS_S down, then the crate comes out.
	state = "processing"
	_process_end_ms = Time.get_ticks_msec() + int(PROCESS_S * 1000.0)
	await get_tree().create_timer(PROCESS_S).timeout
	if not is_inside_tree():
		return
	var content := _next_crate(miner_id, miner_name)
	if content.is_empty():
		state = "idle"
		return
	state = "extract"
	# Spawn the crate both in Horizon (other clients) and locally on this game server (so it has a
	# physics body that falls onto the belt and replicates). See NetworkOrchestrator.spawn_prop_authoritative.
	NetworkOrchestrator.spawn_prop_authoritative({
		"type": "crate_container",
		"uuid": UUID_UTIL.new().as_string(),
		"position": {"x": box_spawn_origin.position.x, "y": box_spawn_origin.position.y,
			"z": box_spawn_origin.position.z},
		"rotation": {"x": 0, "y": 0, "z": 0},
		"content": content,
		"scenename": CRATE_SCENENAME,
		"parent_id": uuid,
	})
	# The crate is the world object; the inventory is where the GOODS live. Crediting here, on the
	# server, under the player's service identity is what makes the goods count for an objective —
	# a client route would be a minting bug (see MissionHeartbeat.credit_mined).
	_credit(content)
	# One-shot delivery: the crate spawns at the belt end, so it never transits BoxDetector. Run the
	# belt briefly for feedback, then return to idle.
	await get_tree().create_timer(EXTRACT_RUN_S).timeout
	if state == "extract":
		state = "idle"


## Hand the packed crate to service-inventory as goods its miner now carries. Detached on purpose: the
## crate is already in the world, and a service that is down must not also cost the player their
## belt run — the warning on the failure already says the goods are not accounted for.
func _credit(content: Dictionary) -> void:
	var holder := CrateContent.holder_of(content)
	var good_type := CrateContent.good_type(content)
	var units := int(content.get("units", 0))
	if holder == "" or good_type == "" or units <= 0:
		return
	MissionHeartbeat.credit_mined(holder, good_type, units)
	print("[%s] packed %d x %s for %s" % [name, units, good_type, holder])


# ── 3D screen contract (ScreenTarget) ─────────────────────────────────────────────────────────────

func _on_rock_depot_ui_action_triggered(type: String) -> void:
	if GameOrchestrator.is_server():
		return
	# on client trigger the screen state update for the current player if pressed on ui element
	ScreenTarget.send(self, {"state": type})


## SERVER, 3D-screen contract (ScreenTarget): a validated button press — SEND starts the input belt,
## EXTRACT the work on a crate.
func update_screen(data: Dictionary) -> void:
	var target_state: String = data["state"]
	if state == "idle" and target_state == "collect":
		state = target_state
	elif state == "idle" and target_state == "extract":
		state = target_state
		handle_extract()


## SERVER, 3D-screen contract (ScreenTarget): the player whose action is about to be handled — who is
## using the machine.
func set_screen_actor(player: Player) -> void:
	active_player = player


# ── Screen helpers shared by the subclasses ───────────────────────────────────────────────────────

func _ui(path: String) -> Node:
	return rock_depot_ui.get_node(path)

## Show the splash (pictos + message + optional EXTRACT) or the belt counter (big number + caption +
## SEND). [param icons]: the message's pictos, side by side; [param warning] tints them in the screen's
## orange: something on the belt is refused.
func _show_screen(splash: bool, message: String, extract_ready: bool, icons: Array = [],
		warning: bool = false) -> void:
	_ui("VB/Splashscreen").visible = splash
	_ui("VB/RockCounter").visible = not splash
	_ui("VB/Splashscreen/TriggerExtract").visible = extract_ready
	(_ui("VB/Splashscreen/Label3") as Label).text = message
	if _pictos == null:
		return
	_pictos.visible = not icons.is_empty()
	_pictos.modulate = WARNING_INK if warning else SCREEN_INK
	while _pictos.get_child_count() < icons.size():
		var picto := TextureRect.new()
		picto.custom_minimum_size = Vector2(PICTO_PX, PICTO_PX)
		picto.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picto.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_pictos.add_child(picto)
	for i in _pictos.get_child_count():
		var picto := _pictos.get_child(i) as TextureRect
		picto.visible = i < icons.size()
		if picto.visible:
			picto.texture = icons[i]
