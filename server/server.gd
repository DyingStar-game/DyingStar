class_name GameServer
extends Node

signal populated_universe

const UUID_UTIL = preload("res://addons/uuid/uuid.gd")
## Tick interval (frames) for the active-body chunk-pin sweep.
const PIN_TICK_INTERVAL: int = 6
## Prop type names in props_list that may contain RigidBody3D instances
## we want to pin chunks for.  "planets" intentionally excluded.
const PIN_PROP_TYPES: Array[String] = ["box50cm", "box4m", "ship"]
## Seeds mining zones under players as they walk the planet. Server-owned: it publishes zones
## through NetworkOrchestrator.spawn_prop_authoritative and arms/disarms their detection.
var _mining_planner := MiningZonePlanner.new()
## Max number of [Pin] log entries before suppressing further output.
const PIN_DEBUG_MAX: int = 200

## Physics activity freeze (Part A — server FPS): a body that has SETTLED (negligible drift, so it
## stops jittering) AND is far from every player is frozen, so Jolt stops simulating it. It unfreezes
## as soon as a player comes within ACTIVE_RADIUS, so it stays pushable/mineable. Only bodies WE froze
## are unfrozen (design-frozen props — storage boxes, carried, in a bed — are left alone).
const SETTLE_EPS: float = 0.05       # m of net drift below which a body counts as "not moving"
const SETTLE_TICKS: int = 15         # consecutive still ticks (~1.5 s at the pin cadence) before freezing
const ACTIVE_RADIUS: float = 60.0    # m: keep bodies dynamic within this of any player
## Edge (m) of a frozen-body index cell. Must stay > ACTIVE_RADIUS so a player's sphere never spans
## more than the 3x3x3 block the wake pass walks.
const CULL_CELL_SIZE: float = 64.0

var universe_scene: Node = null
var entities_spawn_node: Node = null
var datas_to_spawn_count: int = 0

var clients_peers_ids: Array[int] = []

var server_zone = {
	"x_start": -100000.0,
	"x_end": 100000.0,
	"y_start": -100000.0,
	"y_end": 100000.0,
	"z_start": -100000.0,
	"z_end": 100000.0
}

var max_players_allowed = 40
var players_list = {}
var players_list_last_movement = {}
var players_list_last_rotation = {}
## Last frame uuid DECLARED to Horizon per player. Never assigned by a caller: it is a memo of what
## PropSpawn.parent_frame_uuid() returned last time, so a change of scene parent can be detected and
## re-announced. Same role as PropSync.server_last_parent_id for props.
var players_list_last_parent: Dictionary = {}
var players_list_creationdate = {}
var players_list_temp_by_id = {}
var players_list_currently_in_transfert = {}
var changing_zone = false
var transfer_players = false
var props_list = {
	"planets": {},
	"box50cm": {},
	"box4m": {},
	"ship": {},
	"spawnbuilding": {},
}
var props_list_last_movement = {
	# "box50cm": {},
	# "box4m": {},
	# "ship": {},
}
var props_list_last_rotation = {
	# "box50cm": {},
	# "box4m": {},
	# "ship": {},
}

var servers_ticks_tasks = {
	"TooManyPlayersCurent": 3600,
	"TooManyPlayersReset": 3600, # all 1 minute
	"SendPlayersToMQTTCurrent": 15,
	"SendPlayersToMQTTReset": 15,
	"CheckPlayersOutOfZoneCurrent": 20,
	"CheckPlayersOutOfZoneReset": 20,
	"SendPropsToMQTTCurrent": 15,
	"SendPropsToMQTTReset": 15,
	"SendMetricsCurrent": 120,
	"SendMetricsReset": 120,
}

var players_newposition: Dictionary = {}
var props_update: Dictionary = {}

var player_scene_path: String = "res://scenes/player/player.tscn"

var player_scene: PackedScene = preload("res://scenes/player/player.tscn")
var box50cm_scene: PackedScene = preload("res://scenes/_universe/props/containers/box_50cm.tscn")
var props_scene: Dictionary = {
	'scenes/_universe/props/containers/container_benne_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_benne_1200x240x240.tscn'),
	'scenes/_universe/props/containers/container_liquid_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_liquid_1200x240x240.tscn'),
	'scenes/_universe/props/containers/container_plate_1200x240x30.tscn':
		preload('res://scenes/_universe/props/containers/container_plate_1200x240x30.tscn'),
	'scenes/_universe/props/containers/container_standard_a_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_standard_a_1200x240x240.tscn'),
	'scenes/_universe/props/containers/container_standard_b_1200x240x240.tscn':
		preload('res://scenes/_universe/props/containers/container_standard_b_1200x240x240.tscn'),
	'scenes/_universe/props/containers/pallet_benne_120x80x100.tscn':
		preload('res://scenes/_universe/props/containers/pallet_benne_120x80x100.tscn'),
	'scenes/_universe/props/containers/pallet_crate_120x80x100.tscn':
		preload('res://scenes/_universe/props/containers/pallet_crate_120x80x100.tscn'),
	'scenes/_universe/props/containers/pallet_liquid_120x80x100.tscn':
		preload('res://scenes/_universe/props/containers/pallet_liquid_120x80x100.tscn'),
	# 'scenes/_universe/props/containers/pallet_plate_120x80x100.tscn':
	# 	preload('res://scenes/_universe/props/containers/pallet_plate_120x80x100.tscn'),
	'scenes/_universe/props/containers/crate_container.tscn':
		preload('res://scenes/_universe/props/containers/crate_container.tscn'),
	'scenes/_universe/structures/industrial/mines/Mining_Zone.tscn':
		preload('res://scenes/_universe/structures/industrial/mines/Mining_Zone.tscn'),
	'scenes/_universe/props/containers/hauling_box.tscn':
		preload('res://scenes/_universe/props/containers/hauling_box.tscn'),
	'scenes/_universe/props/containers/pallet_crate.tscn':
		preload('res://scenes/_universe/props/containers/pallet_crate.tscn'),
	'scenes/_universe/props/containers/pallet_benne.tscn':
		preload('res://scenes/_universe/props/containers/pallet_benne.tscn'),
	'scenes/_universe/props/containers/pallet_liquid.tscn':
		preload('res://scenes/_universe/props/containers/pallet_liquid.tscn'),
	'scenes/_universe/props/containers/pallet_plate.tscn':
		preload('res://scenes/_universe/props/containers/pallet_plate.tscn'),
	'scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn':
		preload('res://scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn'),
	'scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn':
		preload('res://scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn'),
	'scenes/_universe/environment/terrain/rocks/rock_mining_lg.tscn':
		preload('res://scenes/_universe/environment/terrain/rocks/rock_mining_lg.tscn'),
	'scenes/_universe/props/containers/box_50cm.tscn':
		preload('res://scenes/_universe/props/containers/box_50cm.tscn'),
	'scenes/_universe/props/containers/box_4m.tscn':
		preload('res://scenes/_universe/props/containers/box_4m.tscn'),
	'scenes/_universe/structures/urban/cities/sandbox_capital.tscn':
		preload('res://scenes/_universe/structures/urban/cities/sandbox_capital.tscn'),
	'scenes/_universe/vehicles/ground/trucks/truck.tscn':
		preload('res://scenes/_universe/vehicles/ground/trucks/truck.tscn'),
	'scenes/_universe/structures/industrial/cargo_depot.tscn':
		preload('res://scenes/_universe/structures/industrial/cargo_depot.tscn'),
}

var debug_message_number: int = 0

var serverinfo_uuid: String = ""
var serverinfo_name: String = ""

# on server, Horizon messages can arrives in not right order when have parent_id for players
# so we store the message in this case in the goal to process them later
var pending_messages_player_parenting: Array[Dictionary] = []
# same for generic objects
var pending_messages_generic_objects_parenting: Array[Dictionary] = []
var pending_freeze_objects: Array[Dictionary] = []
var check_pending_objects_timer: int = 0
var check_out_of_zone_after_split: int = 0

# ── Settle-culler index ───────────────────────────────────────────────────────
# Scanning props_list every tick is O(all props). That was fine at a dozen networked objects; with
# the ~2100 rocks a planet now carries it dominated the server, and at 50k it is hopeless no matter
# how cheap each step is (staggering an O(N) sweep is still O(N) amortised). These structures make
# the per-tick cost depend on what is NEAR A PLAYER instead of on how many props exist:
#
#   _cull_active — cullable bodies that are NOT culled-frozen. Only a body that can still move needs
#                  the settle test, so this is the only set the freeze direction ever walks. Bodies
#                  far from every player are frozen and cost exactly nothing per tick.
#   _cull_frozen — culled-frozen bodies bucketed by coarse PLANET-LOCAL cell. A frozen body cannot
#                  move relative to its planet, so its bucket stays valid for as long as it is
#                  frozen, and waking bodies costs a lookup of the cells a player overlaps.
#
# Planet-local, never world: a planet orbits, so a world-space bucket would go stale every frame.
var _cull_active: Dictionary = {}       # instance_id -> RigidBody3D
var _cull_frozen: Dictionary = {}       # planet_id -> { Vector3i cell -> { instance_id -> body } }
var _cull_frozen_at: Dictionary = {}    # instance_id -> {planet, cell, local} (to unbucket + test)
var _cull_settle: Dictionary = {}       # instance_id -> {"ref": Vector3, "ticks": int}
## props_list population at the last adopt pass. Bodies are indexed when they freeze/unfreeze, but a
## newly spawned one has no such hook — rather than hook every creation site (and silently never cull
## whatever a future site forgets), notice that the population changed and adopt the newcomers. It
## runs while the world streams in, then never again.
var _cull_indexed_total: int = -1

## True once manage_zone() has received an authoritative zone assignment
## from Horizon.  Until then, planets keep zero resident chunks (only their
## safety-net coarse mesh) so a 17-planet boot doesn't load 836k shapes.
var _zone_initialized: bool = false

## Tick counter for the active-body chunk-pin sweep.  Runs every
## PIN_TICK_INTERVAL frames in _process to refresh which planet chunks
## must stay resident because an awake RigidBody3D is sitting on them.
var _pin_tick_counter: int = 0
## Number of debug lines printed by the pin sweep so far (capped to keep
## logs readable).  Reset/incremented in _pin_node_to_planet_chunk.
var _pin_debug_logged: int = 0

## Counter to throttle Horizon position/prop updates to every 2nd physics
## frame (30 messages/sec at 60 FPS physics).
var _horizon_update_counter: int = 0


func _enter_tree() -> void:
	NetworkOrchestrator.load_server_config()

func _ready() -> void:
	set_process(false)
	# props_list itself lives for the server's lifetime; only its per-type sub-dictionaries are
	# created lazily, which is why the planner re-reads it through .get() instead of caching one.
	_mining_planner.bind_props_list(props_list)
	_send_metrics()
	# Say it out loud at boot, both ways. A rig that is silently off looks exactly like a server with
	# nothing to report, and that ambiguity is what a low-TPS log must never contain.
	if _perf_report:
		print("[Perf] rig ARMED by %s — report every 2 s" % PropNet.prof_source)
		# A server started from the editor keeps a WINDOW and renders the whole system; preprod runs
		# headless and does not. That difference lands entirely in `fps` and not at all in `tps`, so
		# the log has to say which of the two it is or the numbers below cannot be compared.
		print("[Perf] display=%s | physics %d Hz max_steps/frame=%d separate_thread=%s | workers=%s" % [
			DisplayServer.get_name(),
			Engine.physics_ticks_per_second,
			int(ProjectSettings.get_setting("physics/common/max_physics_steps_per_frame", 8)),
			str(ProjectSettings.get_setting("physics/3d/run_on_separate_thread", false)),
			str(ProjectSettings.get_setting("threading/worker_pool/max_threads.dedicated_server",
					ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))),
		])
	else:
		print("[Perf] rig off — arm it with --perf, or DS_PERF=1, or [debug] perf=true in server.ini")

func _physics_process(_delta: float) -> void:
	var _t0: int = Time.get_ticks_usec() if PropNet.prof_on else 0
	if PropNet.prof_on and _perf_prev_exit_usec > 0:
		# Wall time since our previous callback returned: Jolt's step, every other node's
		# _physics_process, and (once per rendered frame) the whole main loop. Summed over a window it
		# turns the accounting into a closed budget — our instrumented scripts plus this gap IS the
		# wall clock — with no assumption about how many substeps a frame ran.
		_perf_gap_usec += _t0 - _perf_prev_exit_usec
	_perf_tick(_delta)
	_horizon_update_counter += 1
	if _horizon_update_counter >= 2:
		_horizon_update_counter = 0
		send_players_newposition_to_horizon()
		send_props_update_to_horizon()
	if PropNet.prof_on:
		# _perf_tick prints and resets INSIDE this window, so its own report frame lands in the next
		# window's bucket. Over a 2 s window that is noise; it keeps the accounting simple.
		_perf_prev_exit_usec = Time.get_ticks_usec()
		PropNet.prof_srv_usec += _perf_prev_exit_usec - _t0

## Perf rig: every 2 s, print where the frame goes — engine physics vs script — plus the counts that
## discriminate between the known suspects (awake bodies = Jolt load, chunk tasks/queue = terrain
## collision churn, nav maps = NPC bake load, update dict sizes = network flush volume). Built during
## the 2026-08 TPS investigation. One switch for the whole rig, resolved by PropNet (`--perf`, or
## `DS_PERF=1`, or `[debug] perf=true` in server.ini) — see the comment on PropNet.prof_on.
var _perf_report: bool = PropNet.prof_on
var _perf_timer: float = 0.0
var _perf_frames: int = 0
## Real time at the last report. `_perf_timer` accumulates the FIXED physics delta (1/60), so it
## measures game time, not wall time: when the tick falls behind, a "2 s" window takes longer than 2 s
## in the real world and every per-second figure derived from it is wrong by that ratio. The client
## rig learned this the hard way; the server rig never had the check at all.
var _perf_wall_usec: int = 0
## Wall clock at the end of our last _physics_process, and the summed gaps between callbacks.
var _perf_prev_exit_usec: int = 0
var _perf_gap_usec: int = 0

func _perf_tick(delta: float) -> void:
	if not _perf_report:
		return
	_perf_timer += delta
	_perf_frames += 1
	if _perf_timer < 2.0:
		return
	if _perf_wall_usec == 0:
		_perf_wall_usec = Time.get_ticks_usec()
	var _window_frames: int = maxi(_perf_frames, 1)
	var _now_usec: int = Time.get_ticks_usec()
	var _wall_s: float = float(_now_usec - _perf_wall_usec) / 1_000_000.0
	_perf_wall_usec = _now_usec
	# The two rates that "6 TPS" conflates, and which no server log has ever separated. `tps` is the
	# achieved PHYSICS rate — the one that decides whether the simulation keeps up. `fps` is the main
	# loop, which on a windowed run also carries rendering; Godot runs up to
	# physics/common/max_physics_steps_per_frame ticks per frame, so a low fps next to a healthy tps
	# means the frame is long for a reason the simulation has nothing to do with.
	var _tps: float = float(_window_frames) / _wall_s if _wall_s > 0.0 else 0.0
	_perf_timer = 0.0
	_perf_frames = 0
	var total := 0
	var unfrozen := 0
	var awake := 0
	for ptype in props_list.keys():
		if ptype == "planets" or not (props_list[ptype] is Dictionary):
			continue
		for body_uuid in props_list[ptype].keys():
			var b = props_list[ptype][body_uuid]
			if b is RigidBody3D and is_instance_valid(b):
				total += 1
				if not (b as RigidBody3D).freeze:
					unfrozen += 1
					if not (b as RigidBody3D).sleeping:
						awake += 1
	# SUM over every planet, never just the first: this universe holds 18 of them, and reading only
	# props_list["planets"].keys()[0] reported "chunks res=0" while the planet the player actually
	# stands on may have been fine — a measurement artefact that inverted the diagnosis.
	var chunks := 0
	var loading := 0
	var queued := 0
	var planets_with_chunks := 0
	for puuid in props_list["planets"].keys():
		var p = props_list["planets"][puuid]
		if p is Planet and (p as Planet).planet_terrain != null:
			var pt = (p as Planet).planet_terrain
			var c: int = pt._server_collision_chunks.size()
			chunks += c
			loading += pt._server_chunk_tasks.size()
			queued += pt._server_chunk_queue.size()
			if c > 0:
				planets_with_chunks += 1
	var npcs := 0
	for puuid in players_list.keys():
		var pl = players_list[puuid]
		if is_instance_valid(pl) and "is_npc" in pl and pl.is_npc:
			npcs += 1
	print(("[Perf] %s up=%.0fs win=%.1fs tps=%.0f/%d fps=%.0f"
			+ "  phys=%.1fms proc=%.1fms  active3d=%d pairs=%d islands=%d | props awake=%d unfrozen=%d total=%d"
			+ " | chunks res=%d (on %d/%d planets) loading=%d queued=%d"
			+ " | players=%d npcs=%d navmaps=%d | pending upd props=%d players=%d") % [
		Time.get_time_string_from_system(),
		float(Time.get_ticks_msec()) / 1000.0,
		_wall_s,
		_tps, Engine.physics_ticks_per_second,
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
		Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT),
		awake, unfrozen, total,
		chunks, planets_with_chunks, props_list["planets"].size(), loading, queued,
		players_list.size(), npcs, NavigationServer3D.get_maps().size(),
		props_update.size(), players_newposition.size(),
	])
	# Replication cost, split into the three layers the engine profiler conflates into one
	# "PropNet.server_tick" row. `tick` is INCLUSIVE (it contains `handler`), so the cost of the
	# function's own body + the signal dispatch is tick-handler. `flush` is the JSON + websocket
	# send, which happens every 2nd frame and is NOT part of tick.
	if PropNet.prof_on:
		var _fr: float = float(_window_frames)
		var _tick_ms: float = PropNet.prof_tick_usec / 1000.0 / _fr
		var _hand_ms: float = PropNet.prof_handler_usec / 1000.0 / _fr
		var _flush_ms: float = PropNet.prof_flush_usec / 1000.0 / _fr
		var _per_call_us: float = (
			float(PropNet.prof_tick_usec) / float(PropNet.prof_calls) if PropNet.prof_calls > 0 else 0.0)
		# Who the emitters ARE, busiest type first. A type sitting at exactly N emits per tick in a
		# world at rest is a prop re-sending itself unconditionally, not a prop that moved.
		var _types: Array = PropNet.prof_emit_types.keys()
		_types.sort_custom(func(a, b): return PropNet.prof_emit_types[a] > PropNet.prof_emit_types[b])
		var _type_parts: PackedStringArray = []
		for _t: String in _types.slice(0, 6):
			_type_parts.append("%s=%.1f/f" % [_t, float(PropNet.prof_emit_types[_t]) / float(_window_frames)])
		print(("[Perf/net] calls=%.0f/f emits=%.0f/f (%.0f%%)"
				+ " | per frame: tick=%.2fms (body+dispatch=%.2f handler=%.2f) flush=%.2fms"
				+ " | per call: %.1fus | flush avg entries=%.0f (%.1f KB/s of JSON)"
				+ " | emitters: %s | branches: carried=%.1f/f riding=%.1f/f world=%.1f/f (world mean move %.1f mm over %d)") % [
			PropNet.prof_calls / _fr,
			PropNet.prof_emits / _fr,
			(100.0 * PropNet.prof_emits / PropNet.prof_calls) if PropNet.prof_calls > 0 else 0.0,
			_tick_ms, _tick_ms - _hand_ms, _hand_ms, _flush_ms,
			_per_call_us,
			(float(PropNet.prof_flush_entries) / float(PropNet.prof_flushes)) if PropNet.prof_flushes > 0 else 0.0,
			(float(PropNet.prof_flush_bytes) / 1024.0) / _wall_s if _wall_s > 0.0 else 0.0,
			" ".join(_type_parts) if not _type_parts.is_empty() else "none",
			PropNet.prof_emit_carried / _fr, PropNet.prof_emit_riding / _fr, PropNet.prof_emit_world / _fr,
			(PropNet.prof_emit_dpos_mm / float(PropNet.prof_emit_dpos_n)) if PropNet.prof_emit_dpos_n > 0 else 0.0,
			PropNet.prof_emit_dpos_n,
		])
		# Physics accounting, in MILLISECONDS PER SECOND OF WALL CLOCK — the only unit in which these
		# figures can be added up. The previous version compared our per-TICK counters against
		# Performance.TIME_PHYSICS_PROCESS, which is per FRAME; with the tick starved to 8 substeps per
		# frame the two differ by ~8x, and the resulting "engine+rest=81%" was arithmetic, not a
		# measurement (our scripts alone already exceeded the supposed total). The engine's TIME_*
		# monitors are printed on their own, flagged, and never mixed into a subtraction again.
		var _player_ms: float = PropNet.prof_player_usec / 1000.0 / _fr
		var _terrain_ms: float = PropNet.prof_terrain_usec / 1000.0 / _fr
		var _srv_ms: float = PropNet.prof_srv_usec / 1000.0 / _fr
		var _vehicle_ms: float = PropNet.prof_vehicle_usec / 1000.0 / _fr
		var _scripts_ms: float = _tick_ms + _player_ms + _terrain_ms + _srv_ms + _vehicle_ms
		# The budget is NESTED, not flat, and getting that wrong printed 1245 ms inside one second on
		# the first run. `_perf_gap_usec` is the wall time between the END of our own _physics_process
		# and its next START — so props / player / terrain, which run in OTHER nodes' callbacks, are
		# INSIDE that gap and must not be added alongside it. Only server.gd's own body is outside.
		# Subtract what we know runs in there, and the remainder is the honest unknown.
		var _gap_ms_s: float = (float(_perf_gap_usec) / 1000.0) / _wall_s if _wall_s > 0.0 else 0.0
		_perf_gap_usec = 0
		var _in_gap_ms_s: float = (_tick_ms + _player_ms + _terrain_ms + _vehicle_ms) * _tps
		var _srv_ms_s: float = _srv_ms * _tps
		var _unknown_ms_s: float = _gap_ms_s - _in_gap_ms_s
		print(("[Perf/phys] per wall second (adds up to 1000): server.gd=%.0fms"
				+ " | instrumented in other callbacks=%.0fms (props=%.0f player=%.0f terrain=%.0f vehicles=%.0f[%.0f/tick])"
				+ " | UNATTRIBUTED=%.0fms (%.0f%%) = Jolt step + uninstrumented _physics_process + main loop"
				+ " | per tick: ours=%.2fms over %.0f ticks/s"
				+ " | engine monitors (per FRAME, never mix with the above): TIME_PHYSICS=%.1f TIME_PROCESS=%.1f") % [
			_srv_ms_s,
			_in_gap_ms_s, _tick_ms * _tps, _player_ms * _tps, _terrain_ms * _tps,
			_vehicle_ms * _tps, PropNet.prof_vehicle_calls / _fr,
			_unknown_ms_s, 100.0 * _unknown_ms_s / 1000.0,
			_scripts_ms, _tps,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		])
		var _p_pre: float = PropNet.prof_p_pre_usec / 1000.0 / _fr
		var _p_vault: float = PropNet.prof_p_vault_usec / 1000.0 / _fr
		var _p_step: float = PropNet.prof_p_step_usec / 1000.0 / _fr
		var _p_move: float = PropNet.prof_p_move_usec / 1000.0 / _fr
		var _p_emit: float = PropNet.prof_p_emit_usec / 1000.0 / _fr
		print("[Perf/player] total=%.2fms | pre=%.2f vault_probe=%.2f step_probe=%.2f move_and_slide=%.2f emit=%.2f | rest=%.2f" % [
			_player_ms, _p_pre, _p_vault, _p_step, _p_move, _p_emit,
			_player_ms - (_p_pre + _p_vault + _p_step + _p_move + _p_emit),
		])
		# The two candidate causes of the collision-query cost, side by side. `slides` above ~1 means
		# move_and_slide keeps re-casting against an unstable contact; chunk load/unload counts show
		# whether terrain colliders are being rebuilt under the walking player. Plus the gravity Area3D
		# the player stands in: with 2179 bodies inside it, its monitoring runs in flush_queries, which
		# lands in `engine` — that would explain the 3.7 ms already present at rest.
		var _grav_bodies := -1
		var _grav_name := ""
		for puuid in players_list.keys():
			var pl = players_list[puuid]
			if is_instance_valid(pl) and "gravity_parents" in pl and not pl.gravity_parents.is_empty():
				var a = pl.gravity_parents.back()
				if a is Area3D:
					_grav_name = (a as Area3D).name
					_grav_bodies = (a as Area3D).get_overlapping_bodies().size()
				break
		print(("[Perf/coll] slides=%.2f/tick (over %.0f moves/f)"
				+ " | chunks loaded=%d unloaded=%d per window"
				+ " | gravity area '%s' monitoring %d bodies") % [
			(float(PropNet.prof_slide_count) / float(PropNet.prof_slide_ticks)) if PropNet.prof_slide_ticks > 0 else 0.0,
			PropNet.prof_slide_ticks / _fr,
			PropNet.prof_chunk_loads, PropNet.prof_chunk_unloads,
			_grav_name, _grav_bodies,
		])
		PropNet.prof_reset()

func _process(_delta: float) -> void:
	if check_pending_objects_timer == 20:
		# every 20 frames, check pending players parenting
		for pending_message in pending_messages_player_parenting.duplicate():
			if _search_parent_node(pending_message["data"]["object_data"]["parent_id"]) != null:
				print(
					"Processing pending message for player %s now that parent_id %s is available" % [
						pending_message["data"]["object_data"]["parent_id"],
						pending_message["data"]["object_uuid"]
					]
				)
				create_player(pending_message)
				pending_messages_player_parenting.erase(pending_message)

		# generic object created, now process pending messages for generic objects waiting for this generic object as parent
		for pending_message in pending_messages_generic_objects_parenting.duplicate():
			if _search_parent_node(pending_message["data"]["object_data"]["parent_id"]) != null:
				print(
					"Processing pending message for generic object %s now that parent_id %s is available" % [
						pending_message["data"]["object_uuid"],
						pending_message["data"]["object_data"]["parent_id"]
					]
				)
				create_generic_object(pending_message)
				pending_messages_generic_objects_parenting.erase(pending_message)

		# process pending freeze objects
		for pending_message in pending_freeze_objects.duplicate():
			var ret = freeze_object(pending_message, false)
			if ret == true:
				pending_freeze_objects.erase(pending_message)

		check_pending_objects_timer = 0
	else:
		check_pending_objects_timer += 1

	# Active-body chunk pinning.  At ~60 fps this fires every ~100 ms,
	# refreshing which planet chunks must stay resident because an awake
	# RigidBody3D is sitting on them.  See _refresh_active_body_pins().
	_pin_tick_counter += 1
	if _pin_tick_counter >= PIN_TICK_INTERVAL:
		_pin_tick_counter = 0
		_refresh_active_body_pins()
		_cull_settled_bodies()


## Sweep all RigidBody3D-based props, identify the planet chunk under
## each awake body, and push the resulting per-planet pin set so those
## chunks stay resident regardless of the zone's desired residency.
##
## Every UNFROZEN body pins its chunk, sleeping or not — a sleeping body still rests on its
## contacts, and evicting the ground under it wakes it (see the loop below). Only frozen
## bodies (collision shapes disabled by the culler) may lose their chunk with the zone churn.
##
## Players (CharacterBody3D) are ALWAYS pinned regardless of
## _zone_initialized: in single-server / no-mesh deployments Horizon never
## sends a manage_zone() event, so without this fallback the per-chunk
## collision never loads and the player falls through onto the
## safety-net coarse mesh ~hundreds of metres below the visible surface.
func _refresh_active_body_pins() -> void:
	if props_list["planets"].is_empty():
		return
	if _zone_initialized == false and players_list.is_empty():
		return

	# planet_node → Dictionary[chunk_key, true]
	var pins_by_planet: Dictionary = {}
	for puuid in props_list["planets"].keys():
		pins_by_planet[puuid] = {}

	# Pin chunks under each connected player so their surroundings have
	# real collision even before (or without) a Horizon zone assignment.
	# The same walk feeds MiningZonePlanner: it needs exactly the chunk under each player, which
	# _pin_node_to_planet_chunk is already computing here, so seeding costs no extra sweep.
	_mining_planner.begin_sweep()
	for player_uuid in players_list.keys():
		var player_node = players_list[player_uuid]
		if not is_instance_valid(player_node):
			continue
		if not (player_node is Node3D):
			continue
		_pin_node_to_planet_chunk(player_node as Node3D, pins_by_planet)
		var player_planet: Planet = _planet_ancestor_of(player_node as Node3D)
		if player_planet != null:
			_mining_planner.plan_for_player(
				player_planet, player_node as Node3D, player_uuid as String)
	_mining_planner.end_sweep()

	if _zone_initialized:
		for ptype in PIN_PROP_TYPES:
			if not props_list.has(ptype):
				continue
			for body_uuid in props_list[ptype].keys():
				var body = props_list[ptype][body_uuid]
				if not is_instance_valid(body):
					continue
				if not (body is RigidBody3D):
					continue
				var rb: RigidBody3D = body
				if rb.freeze:
					continue  # shapes disabled by the culler: genuinely needs no ground
				# SLEEPING bodies still pin their chunk. Unloading the ground under a sleeping body
				# removes its contacts, which WAKES it: it falls (the reload is async), re-pins the
				# chunk, the chunk reloads, it lands and sleeps again, the pin drops... A player
				# walking across a chunk boundary next to a resting pile triggers that unload/wake
				# oscillation on every crossing (measured: server TPS 60 -> 10 from walking ~5 m
				# near the depot crates). Only FROZEN bodies can safely lose their ground.
				_pin_node_to_planet_chunk(rb, pins_by_planet)

	# Push pin set to each planet (empty array clears pins).
	for puuid in pins_by_planet.keys():
		var planet_node = props_list["planets"][puuid]
		if planet_node == null or not is_instance_valid(planet_node):
			continue
		if not (planet_node is Planet):
			continue
		var planet: Planet = planet_node as Planet
		if planet.planet_terrain == null:
			continue
		var keys := PackedStringArray()
		for k in pins_by_planet[puuid].keys():
			keys.append(k as String)
		planet.planet_terrain.set_pinned_chunks(keys)


## Physics activity freeze (Part A): freeze props that have SETTLED and are far from every player so
## Jolt stops simulating them (kills the resting-pile jitter cost); unfreeze them the moment a player
## comes within ACTIVE_RADIUS so they stay pushable/mineable. Only bodies WE froze are unfrozen —
## design-frozen props (storage boxes, carried, bed-loaded) and vehicles are left alone.
func _cull_settled_bodies() -> void:
	if not GameOrchestrator.is_server():
		return  # server-only: it owns the authoritative bodies
	_cull_adopt_new_bodies()
	# 1) WAKE: only the cells a player overlaps are visited, so this is independent of how many
	#    frozen bodies the planet holds — the 50k case costs the same as the 100 case.
	_cull_wake_near_players()
	# 2) SETTLE: only bodies that can still move. Their positions are read in world space here, which
	#    is fine precisely because the set is small (what is near a player, or still coming to rest).
	var player_positions: PackedVector3Array = _live_player_positions()
	for id in _cull_active.keys():
		var rb = _cull_active[id]
		if not _is_cullable_body(rb):
			_cull_forget(id)  # freed, carried or loaded into a bed — no longer ours to cull
			continue
		if _any_within(player_positions, _true_position(rb), ACTIVE_RADIUS):  # true coords, see _live_player_positions
			_cull_settle.erase(id)  # a player is here: it must stay dynamic, restart the settle count
			continue
		if rb.freeze:
			continue  # design-frozen (storage box, out-of-zone spawn), far → leave
		# Settle detection: drift from a reference point. Jitter oscillates within SETTLE_EPS so it
		# still counts as still; a real move pushes past it and resets the reference.
		# Measured in the PARENT's frame (the planet), never in world space: "settled" means "no
		# longer moving relative to the ground it rests on". A spinning planet sweeps a resting
		# prop through tens of metres of world space between refreshes, which would reset the
		# reference forever and stop the culler from ever freezing anything.
		var local_pos: Vector3 = (rb as RigidBody3D).position
		var st: Dictionary = _cull_settle.get(id, {"ref": local_pos, "ticks": 0})
		if local_pos.distance_to(st["ref"]) < SETTLE_EPS:
			st["ticks"] = int(st["ticks"]) + 1
		else:
			st["ticks"] = 0
			st["ref"] = local_pos
		_cull_settle[id] = st
		if int(st["ticks"]) >= SETTLE_TICKS:
			_freeze_culled_body(rb)

## Wake every culled-frozen body a player has come within ACTIVE_RADIUS of. Walks the 3x3x3 cells
## around each player (CULL_CELL_SIZE > ACTIVE_RADIUS guarantees the sphere fits) and tests the
## planet-local position recorded when the body froze — no transform work per candidate.
func _cull_wake_near_players() -> void:
	if _cull_frozen.is_empty():
		return
	var r2: float = ACTIVE_RADIUS * ACTIVE_RADIUS
	for puuid in players_list.keys():
		var p = players_list[puuid]
		if not (is_instance_valid(p) and p is Node3D):
			continue
		var frame := _cull_frame_of(p as Node3D)
		var planet_id: int = frame[0]
		if not _cull_frozen.has(planet_id):
			continue
		var cells: Dictionary = _cull_frozen[planet_id]
		var here: Vector3 = frame[1]
		var base: Vector3i = _cull_cell(here)
		var waking: Array = []
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var bucket = cells.get(Vector3i(base.x + dx, base.y + dy, base.z + dz))
					if bucket == null:
						continue
					for id in (bucket as Dictionary).keys():
						var at = _cull_frozen_at.get(id)
						if at != null and (at["local"] as Vector3).distance_squared_to(here) >= r2:
							continue  # inside the 3x3x3 cell block, outside the actual radius
						waking.append(id)
		# Unfreeze AFTER the walk: _unfreeze_culled_body re-buckets, and mutating the cells we are
		# iterating would skip bodies.
		for id in waking:
			var at = _cull_frozen_at.get(id)
			if at == null:
				continue  # already woken by another player in this same pass
			var rb = at.get("body")
			if rb is RigidBody3D and is_instance_valid(rb):
				_unfreeze_culled_body(rb)
			else:
				_cull_forget(id)

## The frame a node's cull position is expressed in: [planet instance_id, position in that planet's
## local space]. Planet-local so a planet's orbital motion never invalidates a recorded position.
## A node with no Planet ancestor falls back to planet_id 0 / world space (the universe root is
## fixed, so that is stable too).
func _cull_frame_of(node: Node3D) -> Array:
	var n: Node = node
	while n != null:
		if n is Planet:
			return [n.get_instance_id(), (n as Node3D).to_local(node.global_position)]
		n = n.get_parent()
	return [0, node.global_position]

func _cull_cell(local: Vector3) -> Vector3i:
	return Vector3i(
		int(floor(local.x / CULL_CELL_SIZE)),
		int(floor(local.y / CULL_CELL_SIZE)),
		int(floor(local.z / CULL_CELL_SIZE)))

## Put a just-frozen body in its cell bucket and out of the active set.
func _cull_index_frozen(rb: RigidBody3D) -> void:
	var id: int = rb.get_instance_id()
	_cull_active.erase(id)
	_cull_settle.erase(id)
	var frame := _cull_frame_of(rb)
	var planet_id: int = frame[0]
	var local: Vector3 = frame[1]
	var cell: Vector3i = _cull_cell(local)
	if not _cull_frozen.has(planet_id):
		_cull_frozen[planet_id] = {}
	var cells: Dictionary = _cull_frozen[planet_id]
	if not cells.has(cell):
		cells[cell] = {}
	(cells[cell] as Dictionary)[id] = rb
	_cull_frozen_at[id] = {"planet": planet_id, "cell": cell, "local": local, "body": rb}

## Take a body out of its cell bucket and back into the active set (or out of the index entirely).
func _cull_index_active(rb: RigidBody3D) -> void:
	var id: int = rb.get_instance_id()
	_cull_unbucket(id)
	_cull_active[id] = rb

func _cull_unbucket(id: int) -> void:
	var at = _cull_frozen_at.get(id)
	if at == null:
		return
	_cull_frozen_at.erase(id)
	var cells = _cull_frozen.get(at["planet"])
	if cells == null:
		return
	var bucket = (cells as Dictionary).get(at["cell"])
	if bucket == null:
		return
	(bucket as Dictionary).erase(id)
	if (bucket as Dictionary).is_empty():
		(cells as Dictionary).erase(at["cell"])

## Drop a body from every cull structure (freed, or now carried / bed-loaded).
func _cull_forget(id: int) -> void:
	_cull_active.erase(id)
	_cull_settle.erase(id)
	_cull_unbucket(id)

## Adopt bodies that entered props_list without going through freeze/unfreeze. Only runs when the
## prop population actually changed, i.e. while the world streams in — see _cull_indexed_total.
func _cull_adopt_new_bodies() -> void:
	var total: int = 0
	for ptype in props_list.keys():
		if ptype == "planets" or not (props_list[ptype] is Dictionary):
			continue
		total += (props_list[ptype] as Dictionary).size()
	if total == _cull_indexed_total:
		return
	_cull_indexed_total = total
	for ptype in props_list.keys():
		if ptype == "planets" or not (props_list[ptype] is Dictionary):
			continue
		for body_uuid in (props_list[ptype] as Dictionary).keys():
			var body = props_list[ptype][body_uuid]
			if not _is_cullable_body(body):
				continue
			var id: int = body.get_instance_id()
			if _cull_active.has(id) or _cull_frozen_at.has(id):
				continue
			if (body as RigidBody3D).get_meta("_culled_frozen", false):
				_cull_index_frozen(body)
			else:
				_cull_active[id] = body

## World positions of every connected, live player. Snapshotted once per culler sweep so the
## per-body proximity test costs a distance compare instead of a transform-chain walk per player.
func _live_player_positions() -> PackedVector3Array:
	# TRUE universe coordinates: with every planet at the origin of its own world, raw
	# global_position collides across worlds (a rock on planet A and a player on planet B would
	# both read near-origin and falsely count as "close").
	var out := PackedVector3Array()
	for puuid in players_list.keys():
		var p = players_list[puuid]
		if is_instance_valid(p) and p is Node3D:
			out.append(_true_position(p as Node3D))
	return out

## True if any of [param positions] is within [param radius] of [param pos].
func _any_within(positions: PackedVector3Array, pos: Vector3, radius: float) -> bool:
	var r2 := radius * radius
	for p in positions:
		if pos.distance_squared_to(p) < r2:
			return true
	return false

## True if any connected player is within [param radius] of [param pos]. One-shot form (spawn-time
## checks); the culler uses the snapshot pair above instead. [param pos] must be in TRUE universe
## coordinates (players are converted the same way, so the test is world-safe).
func _player_within(pos: Vector3, radius: float) -> bool:
	var r2 := radius * radius
	for puuid in players_list.keys():
		var p = players_list[puuid]
		if is_instance_valid(p) and p is Node3D and pos.distance_squared_to(_true_position(p as Node3D)) < r2:
			return true
	return false

## True if [param node] is a free physics prop the settle-culler may freeze/unfreeze: a live
## RigidBody3D that is not a Vehicle and not carried/bed-loaded (those must stay dynamic). Shared
## by _cull_settled_bodies (runtime) and create_generic_object (reload) so both agree.
func _is_cullable_body(node: Node) -> bool:
	if not is_instance_valid(node) or not (node is RigidBody3D) or node is Vehicle:
		return false
	var parent: Node = node.get_parent()
	return not (parent is Player or parent is Vehicle)

## True when [param body] sits over a planet whose terrain collision has NOT been built under it yet.
## False in open space — there is nothing to wait for — and false once the chunk is resident.
##
## The same question PlayerServer._hold_until_ground asks, through the same PlanetTerrain accessor, so
## a body and a player can never disagree about whether the ground beneath them exists.
func _ground_missing_under(body: Node3D) -> bool:
	if not is_instance_valid(body) or not body.is_inside_tree():
		return false
	var planet: Planet = null
	var node: Node = body
	while node != null:
		if node is Planet:
			planet = node as Planet
			break
		node = node.get_parent()
	if planet == null or planet.planet_terrain == null:
		return false
	return not planet.planet_terrain.has_collision_under(body.global_position)


func _freeze_culled_body(rb: RigidBody3D) -> void:
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO
	rb.freeze = true
	# OCS: drop the body out of Jolt's broadphase entirely. freeze=true alone keeps it registered
	# (residual per-step cost), so we also disable its own collision shapes and stop its script tick.
	rb.set_physics_process(false)
	_set_prop_sync_ticking(rb, false)
	_set_body_shapes_disabled(rb, true)
	rb.set_meta("_culled_frozen", true)
	_cull_index_frozen(rb)  # out of the per-tick active set, into its planet-local cell bucket

func _unfreeze_culled_body(rb: RigidBody3D) -> void:
	# On a spinning planet the physics pose went stale while the body was culled: Planet skips frozen
	# bodies (their shapes are off, so carrying them would be pure cost — and would wake them). Its
	# node transform followed the scene graph, so push that back before the shapes come back on.
	PhysicsServer3D.body_set_state(rb.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
			rb.global_transform)
	_set_body_shapes_disabled(rb, false)
	rb.set_physics_process(true)
	_set_prop_sync_ticking(rb, true)
	rb.freeze = false
	rb.linear_velocity = Vector3.ZERO
	rb.angular_velocity = Vector3.ZERO
	rb.remove_meta("_culled_frozen")
	_cull_index_active(rb)  # back into the per-tick active set, out of its cell bucket
	# Force a replication resend so it re-registers in Horizon/GORC for nearby clients after idling.
	# The replication state lives on the PropSync component when the prop has one, on the root for a
	# not-yet-migrated legacy prop — reading it off the root only would silently skip every PropSync
	# prop (i.e. all the rocks).
	var state: Object = PropSync.of(rb)
	if state == null:
		state = rb
	if "server_last_position" in state:
		state.server_last_position = Vector3.INF

## The PropSync component is a CHILD node, so it keeps ticking when we disable the host body's own
## _physics_process — and PropNet.server_tick then runs per frame for a body that cannot move. Every
## place that stops a body's script tick must silence its component too.
func _set_prop_sync_ticking(node: Node, on: bool) -> void:
	var sync := PropSync.of(node)
	if sync != null:
		sync.set_physics_process(on)

## Enable/disable the body's OWN collision shapes (direct CollisionShape3D/Polygon children) so it
## leaves/re-enters Jolt's broadphase. Child Area3D shapes (interaction zones) are left untouched.
func _set_body_shapes_disabled(rb: RigidBody3D, disabled: bool) -> void:
	for c in rb.get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).disabled = disabled
		elif c is CollisionPolygon3D:
			(c as CollisionPolygon3D).disabled = disabled


## Find the closest planet to [param body] and add the chunk key under
## the body's position to [param pins_by_planet][planet_uuid].  Skips when
## the body is far above any planet (>radius * 1.5 from any centre).
func _pin_node_to_planet_chunk(body: Node3D, pins_by_planet: Dictionary) -> void:
	# ORIGIN REBASE: the owning planet is the body's ANCESTOR — each planet lives at the origin of
	# its own physics world (see create_planet), so a distance scan against planet positions is
	# meaningless across worlds (every planet reads as "at the origin"). A root-world body (ship or
	# player in open space) has no planet ancestor and cannot touch terrain anyway (worlds are
	# isolated), so it pins nothing.
	var best_planet: Planet = _planet_ancestor_of(body)
	if best_planet == null:
		return
	var best_uuid: String = best_planet.uuid
	if not pins_by_planet.has(best_uuid):
		return  # planet not (yet) registered in props_list["planets"]
	if best_planet.planet_data == null:
		return
	var body_pos := body.global_position
	# Planet-LOCAL (body-frame) direction, through the planet's own conversion — the SAME one
	# PlanetTerrain.collision_chunk_key uses to answer "is the ground here loaded?". They must agree on
	# the tile, or a body waits on terrain nobody asked for. Since the origin rebase the planet sits at
	# its world's origin with identity basis, so this reduces to a plain subtraction — but it stays the
	# shared conversion, because the check on the other side does exactly the same thing.
	var dir: Vector3 = best_planet.local_dir_of(body_pos)
	if dir.is_zero_approx():
		return
	var pd = best_planet.planet_data
	# Collision detail nside: the client's FINEST LOD nside on crack planets, so
	# the pinned collision is built on the SAME grid the visual renders (see
	# PlanetData.collision_detail_nside); export nside otherwise.
	var nside: int = pd.collision_detail_nside()
	var ipix: int = HEALPix.vec2pix_nest(nside, dir)
	# Pin the chunk under the body. At the fine collision nside (crack planets)
	# each chunk is small (~sub-km), so pin 2 neighbour rings for a walkable
	# margin that streams as the body moves. Coarse export chunks are ~100 km —
	# one already covers the body amply, so no ring there.
	var pin_ipix := {ipix: true}
	if nside > pd.export_nside:
		# BFS outward 2 rings over the HEALPix neighbour graph.
		var frontier: Array = [ipix]
		for _ring in 2:
			var next_frontier: Array = []
			for p in frontier:
				var nbrs := HEALPix.get_neighbors_nest(nside, p)
				for _dn in nbrs:
					var nb: int = nbrs[_dn]
					if nb >= 0 and not pin_ipix.has(nb):
						pin_ipix[nb] = true
						next_frontier.append(nb)
			frontier = next_frontier
	for pi in pin_ipix:
		pins_by_planet[best_uuid]["hp_n%d_p%d" % [nside, pi]] = true


## Helper for debug log: list the N closest planets and their distances.
## [param pos] must be in TRUE universe coordinates (rebase: planet nodes all sit at their own
## world's origin, only orbital_position is comparable).
func _debug_closest_planets(pos: Vector3, n: int) -> String:
	var items: Array = []
	for puuid in props_list["planets"].keys():
		var pn = props_list["planets"][puuid]
		if not is_instance_valid(pn) or not (pn is Planet):
			continue
		var p: Planet = pn as Planet
		var d := pos.distance_to(_planet_orbital_abs(p))
		var r: float = p.planet_data.radius if p.planet_data else 0.0
		items.append([d, p.name, r])
	items.sort_custom(func(a, b): return a[0] < b[0])
	var out := ""
	for i in range(min(n, items.size())):
		out += "%s d=%.0f r=%.0f; " % [items[i][1], items[i][0], items[i][2]]
	return out

func start_server(receveid_universe_scene: Node) -> void:
	Engine.physics_ticks_per_second = 60
	Engine.max_fps = 60

	universe_scene = receveid_universe_scene
	# entities_spawn_node = receveid_player_spawn_node
	# var server_peer = ENetMultiplayerPeer.new()
	# if not server_peer:
	# 	printerr("creating server_peer failed!")
	# 	return

	# var res = server_peer.create_server(NetworkOrchestrator.server_port, 150)
	# if res != OK:
	# 	printerr("creating server failed: ", error_string(res))
	# 	return

	# universe_scene.multiplayer.multiplayer_peer = server_peer
	# NetworkOrchestrator.connect_chat_mqtt()
	# # load SDO mqtt in NetworkOrchestrator
	# NetworkOrchestrator.connect_mqtt_sdo()
	# if NetworkOrchestrator.metrics_enabled == true:
	# 	NetworkOrchestrator.connect_mqtt_metrics()
	print("server loaded... \\o/")

	if ServerNetwork.start_websocket_server():
		set_process(true)
	ServerNetwork._init_server_network_devmode()

# Instantiate server player
func instantiate_player(message: Dictionary):
	var playername = "Pigeon with no name"
	var spawn_position: Vector3 = Vector3(message["data"]["pos"]["x"], message["data"]["pos"]["y"], message["data"]["pos"]["z"])

	var player_to_add = NetworkOrchestrator.small_props_spawner_node.spawn({
		"entity": "player",
		"player_scene_path": NetworkOrchestrator.player_scene_path,
		"player_name": playername,
		"player_spawn_position": spawn_position,
		"player_spawn_up": Vector3.UP,
		"authority_peer_id": 1
	})
	# player_to_add.global_rotation = Vector3(float(player.xr), float(player.yr), float(player.zr))
	# player_to_add.set_physics_process(false)
	players_list[message.player_id] = player_to_add
	players_list_last_movement[message.player_id] = spawn_position
	# if server_id != null:
	# 	player_to_add.label_server_name.text = NetworkOrchestrator.servers_list[server_id].name

	# print("Remnote player spawned with position: ", player_to_add.global_position)

func player_move(message: Dictionary):
	if players_list.has(message["player_id"]):
		# Input sanity guard: genuine client input (movement/update_velocity,
		# see client.gd _on_client_action_move) is a 2D direction with
		# components in [-1, 1] and NO "z" key. Anything else (a malformed or
		# misrouted message carrying a 3D world position) would be NORMALIZED
		# by the walk code into a full-speed movement command — reject it.
		var pos_data: Dictionary = message["data"]["pos"]
		if pos_data.has("z"):
			return
		var input_x := float(pos_data["x"])
		var input_y := float(pos_data["y"])
		if absf(input_x) > 1.5 or absf(input_y) > 1.5:
			return
		var player = players_list[message["player_id"]]
		player.input_from_server.input_direction = Vector2(input_x, input_y)
		player.input_from_server.rotation = Vector3(
			float(message["data"]["rot"]["x"]), float(message["data"]["rot"]["y"]), float(message["data"]["rot"]["z"])
		)
		player.new_input_from_server = true
	else:
		print("Player move not found: " + str(message["player_id"]))


func player_action(message: Dictionary):
	if players_list.has(message["player_id"]):
		var player = players_list[message["player_id"]]
		if message.has("object_data"):
			player.server_action_received(message["object_data"])
		else:
			player.server_action_received(message["data"])


func _send_metrics():
	while true:
		await get_tree().create_timer(1.0).timeout
		if not serverinfo_uuid == "":
			var nb_scenes = 0
			for proptype in props_list.keys():
				nb_scenes += props_list[proptype].size()
			var message = {
				"namespace": "props",
				"event": "position",
				"amessagenb": 0,
				"data": [
					{
						"uuid": serverinfo_uuid,
						"type": "serverinfo",
						"fps": int(Performance.get_monitor(Performance.TIME_FPS)),
						"objects_number": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
						"players_number": players_list.size(),
						"scenes_number": nb_scenes,
					}
				]
			}
			# print("Send server metrics to horizon: ", message)
			ServerNetwork.send_message(message, "prop_update")

#########################
# Props                 #

func instantiate_props_remote_add(prop):
	_spawn_prop_remote_add(prop)

func instantiate_props_remote_update(prop):
	_spawn_prop_remote_update(prop)

func _spawn_prop_remote_add(prop):
	# print("Create prop: ", prop)
	# add prop
	if not props_list.has(prop.type):
		return
	var uuid = UUID_UTIL.v4()
	var prop_instance: RigidBody3D = NetworkOrchestrator.get_spawnable_props_newinstance(prop.type)
	NetworkOrchestrator.props_list[prop.type][uuid] = prop_instance
	prop_instance.spawn_position = Vector3(float(prop.x), float(prop.y), float(prop.z))
	prop_instance.set_physics_process(false)
	NetworkOrchestrator.small_props_spawner_node.get_node(
		NetworkOrchestrator.small_props_spawner_node.spawn_path
	).call_deferred("add_child", prop_instance, true)
	NetworkOrchestrator.props_list[prop.type][uuid] = prop_instance

func _spawn_prop_remote_update(prop):
	if not NetworkOrchestrator.props_list[prop.type].has(prop.uuid):
		return
	# update the position
	# NOT REBASED (dead path): server-to-server SDO replication. It writes a TRUE-universe position
	# straight into global_position, which since the origin rebase is a per-planet-world frame — so
	# this needs _owning_planet routing like create_generic_object before it can be revived. Nothing
	# runs it today: NetworkOrchestrator.small_props_spawner_node is never assigned (its every
	# initialisation is commented out), so _spawn_prop_remote_add null-crashes first.
	NetworkOrchestrator.props_list[prop.type][prop.uuid].global_position = Vector3(float(prop.x), float(prop.y), float(prop.z))
	NetworkOrchestrator.props_list[prop.type][prop.uuid].global_rotation = Vector3(float(prop.xr), float(prop.yr), float(prop.zr))

func set_server_inactive(_newserver_id: int):
	print("# Disable the server")
	NetworkOrchestrator.is_sdo_active = false
	# TODO send props to new server id
	# unload all
	print("Clean items")
	for uuid in NetworkOrchestrator.players_list.keys():
		NetworkOrchestrator.players_list[uuid].queue_free()
		NetworkOrchestrator.players_list.erase(uuid)
	for proptype in NetworkOrchestrator.props_list.keys():
		for uuid in NetworkOrchestrator.props_list[proptype].keys():
			NetworkOrchestrator.props_list[proptype][uuid].queue_free()
			NetworkOrchestrator.props_list[proptype].erase(uuid)
	for proptype in props_list.keys():
		for uuid in props_list[proptype].keys():
			props_list[proptype][uuid].queue_free()
			props_list[proptype].erase(uuid)
	_orbital_abs_cache.clear()  # planets are gone: their resolved centres must not outlive them









#####################################################
# Horizon server part                              #
#####################################################

## A server-authoritative move from a Player (see Player.emit_move). The FRAME is deliberately NOT a
## parameter: it is read from the scene tree HERE, from the very node whose position we just received.
## "The parent Horizon believes in" is therefore a pure function of "the parent in the tree", and the
## two can no longer be separate states that drift apart unnoticed. A caller cannot announce a frame
## it has not actually moved into, because a caller no longer gets to announce anything.
##
## A frame change is a first-class reason to send, exactly like a position change — the same rule
## PropNet.server_tick already applies to props. It used to ride along as an extra field on a
## position packet, so a reparent that happened not to move the body was silently swallowed.
func _on_player_move(client_uuid: String, position: Vector3, rotation: Vector3) -> void:
	var player = players_list.get(client_uuid)
	if not is_instance_valid(player):
		return

	var frame_uuid: String = PropSpawn.parent_frame_uuid(player)
	var last_frame: String = players_list_last_parent.get(client_uuid, "")
	var frame_changed: bool = last_frame != frame_uuid
	var moved: bool = players_list_last_movement.get(client_uuid) != position \
			or players_list_last_rotation.get(client_uuid) != rotation
	if not moved and not frame_changed:
		return

	if frame_changed:
		var parent_name: String = player.get_parent().name if player.get_parent() != null else "<none>"
		print("[Server] player %s frame '%s' -> '%s' (%s)" % [client_uuid, last_frame, frame_uuid, parent_name])
		if frame_uuid == "":
			# The body sits under a node Horizon knows nothing about, so its LOCAL position is about to
			# be published as WORLD coordinates. Harmless while every frame is motionless; a runaway the
			# day frames orbit. Loud on purpose — this is the one divergence deriving cannot prevent.
			push_warning("[Server] player %s is under '%s', which carries no uuid: its position will be sent as world coordinates"
					% [client_uuid, parent_name])
		players_list_last_parent[client_uuid] = frame_uuid

	var prep = {
		"player_id": client_uuid,
		"pos": {
			"x": position[0],
			"y": position[1],
			"z": position[2],
		},
		"rot": {
			"x": rotation[0],
			"y": rotation[1],
			"z": rotation[2]
		}
	}

	# players_newposition is one entry per player per flush, so a later move in the same window
	# overwrites this one. Carry a frame change already queued onto the newer pose instead of losing
	# it — both poses are expressed in the SAME (new) frame, so this is always safe. The old code
	# returned early here instead, which threw the fresher position away to save the parent.
	if frame_changed:
		prep["parent_id"] = frame_uuid
	elif players_newposition.has(client_uuid) and players_newposition[client_uuid].has("parent_id"):
		prep["parent_id"] = players_newposition[client_uuid]["parent_id"]

	players_list_last_movement[client_uuid] = position
	players_list_last_rotation[client_uuid] = rotation
	if _check_out_of_zone(client_uuid):
		prep["out_of_zone"] = serverinfo_uuid
		print("erase player (2): %s" % client_uuid)
		players_list.erase(client_uuid)
		player.queue_free()
	players_newposition[client_uuid] = prep

func send_players_newposition_to_horizon():
	if players_newposition.values().size() == 0:
		return
	debug_message_number = debug_message_number + 1
	# print("Send players to horizon: ", players_newposition.values().size())
	var message = {
		"namespace": "players",
		"event": "position",
		"amessagenb": debug_message_number,
		"data": players_newposition.values()
	}
	# print("[server] Send players newposition to horizon")
	ServerNetwork.send_message(message, "player_position")
	players_newposition.clear()

func _on_prop_update(
	uuid: String,
	properties: Dictionary,
	type: String,
	_is_parented = false
):
	if PropNet.prof_on:
		PropNet.prof_emits += 1
		PropNet.prof_emit_types[type] = int(PropNet.prof_emit_types.get(type, 0)) + 1
		var _t0: int = Time.get_ticks_usec()
		_on_prop_update_impl(uuid, properties, type)
		PropNet.prof_handler_usec += Time.get_ticks_usec() - _t0
		return
	_on_prop_update_impl(uuid, properties, type)

func _on_prop_update_impl(uuid: String, properties: Dictionary, type: String) -> void:
	if not props_update.has(uuid):
		props_update[uuid] = {
			"uuid": uuid,
			"type": type,
		}
	var prop_entry = props_update[uuid]
	for key in properties.keys():
		if key == "position":
			prop_entry['position'] = {
				"x": properties["position"][0],
				"y": properties["position"][1],
				"z": properties["position"][2]
			}
		elif key == "rotation":
			prop_entry['rotation'] = {
				"x": properties["rotation"][0],
				"y": properties["rotation"][1],
				"z": properties["rotation"][2]
			}
		else:
			# TEMPORARY (cut diagnosis): prove whether a rock's fracture update ever leaves the
			# server. A piece the server cut but the client shows whole is either a message we
			# never sent or one Horizon never delivered — and only this line tells the two apart.
			if key == "fractures":
				print("[cut] QUEUE %s fractures=%s" % [
					uuid.substr(0, 8),
					(properties[key] as Array).map(
						func(f): return (f as Dictionary).get("fractured", "<absent>"))])
			prop_entry[key] = properties[key]

func send_props_update_to_horizon():
	if props_update.values().size() == 0:
		return
	if PropNet.prof_on:
		PropNet.prof_flushes += 1
		PropNet.prof_flush_entries += props_update.size()
		PropNet.prof_flush_bytes += JSON.stringify(props_update.values()).length()
		var _t0: int = Time.get_ticks_usec()
		_send_props_update_impl()
		PropNet.prof_flush_usec += Time.get_ticks_usec() - _t0
		return
	_send_props_update_impl()

func _send_props_update_impl() -> void:
	debug_message_number = debug_message_number + 1
	var message = {
		"namespace": "props",
		"event": "update_object",
		"amessagenb": debug_message_number,
		"data": props_update.values()
	}
	# print("Send props update to horizon: ", message)
	# TEMPORARY (cut diagnosis): which uuids actually go out carrying a fracture list.
	for _e in props_update.values():
		if (_e as Dictionary).has("fractures"):
			print("[cut] FLUSH %s -> horizon" % str((_e as Dictionary)["uuid"]).substr(0, 8))
	ServerNetwork.send_message(message, "prop_update")
	props_update.clear()

func _on_prop_delete(
	uuid: String,
	type: String
):
	debug_message_number = debug_message_number + 1
	var message = {
		"namespace": "props",
		"event": "delete_object",
		"amessagenb": debug_message_number,
		"data": [
			{
				"uuid": uuid,
				"type": type,
			}
		]
	}
	ServerNetwork.send_message(message, "prop_delete")
	props_update.erase(uuid)
	if props_list.has(type):
		if props_list[type].has(uuid):
			props_list[type].erase(uuid)
	if props_list_last_movement.has(uuid):
		props_list_last_movement.erase(uuid)
	if props_list_last_rotation.has(uuid):
		props_list_last_rotation.erase(uuid)

func create_planet(event: Dictionary) -> void:
	# spawn planet
	var planet_data = event["data"]["object_data"]
	var planet_uuid: String = event["data"]["object_uuid"]

	# Guard: planet may already exist (Horizon re-sends initial_object for each
	# connecting player). Creating a duplicate would load thousands of collision
	# shapes again and exhaust Godot's physics RID pool.
	if props_list["planets"].has(planet_uuid):
		print("[server] create_planet: planet '%s' already spawned, skipping." % planet_uuid)
		return

	var spawnable_planet_instance = load("res://" + planet_data["scenename"]).instantiate()
	# ORIGIN REBASE: the planet's true universe position becomes DATA (orbital_position); the node
	# itself sits at the ORIGIN of its own physics world so Jolt's float32 broadphase keeps
	# metre-scale AABBs (at astronomic coords they quantise to ±2 km and every query near a dense
	# surface — the city — costs ~30x, collapsing the tick to 6 TPS while walking; measured, see
	# 2026-08 investigation). spawn_position deliberately stays ZERO so planet_body._ready leaves the node at
	# the origin. SubViewport.own_world_3d gives the planet a full private World3D (physics space,
	# gravity areas, get_world_3d() for every probe under it) — validated on this build: physics
	# steps and collides in a camera-less SubViewport world, isolated from the root world. The
	# client scene is untouched: it keeps astronomic planet positions, and replication
	# is parent-local on both sides, so poses agree as long as the parent CHAIN agrees.
	spawnable_planet_instance.orbital_position = Vector3(
		planet_data["positions"][0]["x"],
		planet_data["positions"][0]["y"],
		planet_data["positions"][0]["z"]
	)
	# A MOON's position is measured from the planet it orbits, not from the universe origin, and the
	# tie is parent_id (the client resolves it by parenting the moon under its planet). Remember it
	# so _planet_orbital_abs can sum the chain; resolution is lazy because a moon can arrive BEFORE
	# the planet it orbits.
	spawnable_planet_instance.orbital_parent_uuid = str(planet_data.get("parent_id", ""))
	spawnable_planet_instance.name = planet_data["name"]
	spawnable_planet_instance.uuid = planet_uuid
	spawnable_planet_instance.tree_entered.connect(func():
		spawnable_planet_instance.owner = get_tree().current_scene
	)
	var planet_world := SubViewport.new()
	planet_world.name = "PlanetWorld_" + str(planet_data["name"])
	planet_world.own_world_3d = true
	planet_world.size = Vector2i(2, 2)  # physics only — never rendered, no camera
	planet_world.render_target_update_mode = SubViewport.UPDATE_DISABLED
	universe_scene.add_child(planet_world)
	planet_world.add_child(spawnable_planet_instance)
	props_list_last_movement[planet_uuid] = Vector3.ZERO
	props_list_last_rotation[planet_uuid] = Vector3.ZERO
	props_list["planets"][planet_uuid] = spawnable_planet_instance

	# Once the planet's terrain reports its safety-net + collision root is
	# ready, push the current zone's chunk residency.  If the zone hasn't
	# been assigned yet, _push_zone_residency_to_planet is a no-op and the
	# upcoming manage_zone() call will fan out residency to every planet.
	var on_ready := func():
		_push_zone_residency_to_planet(spawnable_planet_instance)
	if spawnable_planet_instance.planet_terrain != null:
		spawnable_planet_instance.planet_terrain.initial_chunks_ready.connect(
			on_ready, CONNECT_ONE_SHOT)
	else:
		# Wait one frame for terrain to be assigned, then connect.
		spawnable_planet_instance.ready.connect(func():
			if spawnable_planet_instance.planet_terrain != null:
				spawnable_planet_instance.planet_terrain.initial_chunks_ready.connect(
					on_ready, CONNECT_ONE_SHOT))

## Apply a planet update from Horizon — today only its ORBITAL POSITION.
##
## Orbital motion is nearly free under the origin rebase: the planet ORBITS BY CHANGING THIS DATA
## ONLY, its node never moves, because it sits at the origin of its own physics world. Nothing on the
## surface is disturbed — no collider is teleported, no contact broken, no sleeping body woken. That
## is not a detail: moving a planet-sized collider in Jolt every refresh is precisely what caused the
## "everyone bobs" dance (see the spin note in planet_body._physics_process), which is why the server
## never spun its planets. Orbit costs a Vector3 assignment here.
##
## Only comparisons that CROSS worlds see the change — Horizon's zone bounds, the cull radius, spawn
## ownership — so the resolved-centre cache is dropped (a moon's centre depends on its planet's) and
## the zone's chunk residency is recomputed, since a fixed universe-space zone now maps onto a
## different patch of the planet.
func update_planet(event: Dictionary) -> void:
	# Horizon addresses planets with the nested shape everywhere else (see create_planet); accept the
	# flat one too rather than silently doing nothing if a caller uses it.
	var data: Dictionary = event.get("data", {})
	var planet_uuid: String = str(data.get("object_uuid", event.get("object_uuid", "")))
	if not props_list["planets"].has(planet_uuid):
		return
	var planet := props_list["planets"][planet_uuid] as Planet
	if planet == null or not is_instance_valid(planet):
		return
	var object_data: Dictionary = data.get("object_data", {})
	var positions = object_data.get("positions", [])
	if positions is Array and positions.size() > 0:
		planet.orbital_position = Vector3(
			positions[0]["x"], positions[0]["y"], positions[0]["z"])
		_orbital_abs_cache.clear()
		_push_zone_residency_to_planet(planet)


## Handle a biome update from Horizon.  Rebuilds collision shapes on the
## affected planet's chunks.
## Expected message format:
##   { "namespace": "server", "event": "update_biome",
##     "data": { "planet_uuid": "...",
##               "biome_type": "cave"/"road"/...,
##               "action": "add"/"remove",
##               "geometry": { "type": "linear"/"polygon"/"point",
##                             "vertices": [[lon,lat], ...],
##                             "width": 10.0, "depth": 5.0 },
##               "affected_chunks": ["hp_n64_p120", ...] (optional)
##     } }
func update_planet_biome(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var planet_uuid: String = data.get("planet_uuid", "")
	if planet_uuid.is_empty():
		push_warning("[server] update_planet_biome: missing planet_uuid")
		return

	if not props_list["planets"].has(planet_uuid):
		push_warning("[server] update_planet_biome: planet '%s' not found" % planet_uuid)
		return

	var planet_node: Node = props_list["planets"][planet_uuid]
	if not planet_node is Planet:
		push_warning("[server] update_planet_biome: node is not a Planet")
		return

	var planet: Planet = planet_node as Planet
	if planet.planet_terrain == null:
		push_warning("[server] update_planet_biome: planet has no PlanetTerrain")
		return

	var biome_update := {
		"biome_type": data.get("biome_type", ""),
		"action": data.get("action", "add"),
		"geometry": data.get("geometry", {}),
	}

	# Determine affected chunks: either provided by Horizon or computed via HEALPix.
	var chunk_keys: Array = []
	if data.has("affected_chunks") and not data["affected_chunks"].is_empty():
		chunk_keys = data["affected_chunks"]
	else:
		var geometry: Dictionary = data.get("geometry", {})
		var vertices: Array = geometry.get("vertices", [])
		if vertices.is_empty():
			push_warning("[server] update_planet_biome: no vertices and no affected_chunks")
			return
		var nside: int = planet.planet_data.export_nside
		var affected_ipix := HEALPix.query_polygon_pixels(nside, vertices)
		for ipix in affected_ipix:
			chunk_keys.append("hp_n%d_p%d" % [nside, ipix])

	print("[server] update_planet_biome: planet=%s chunks=%d biome=%s action=%s" % [
		planet.name, chunk_keys.size(), biome_update.biome_type, biome_update.action])
	planet.planet_terrain.rebuild_chunks(chunk_keys, biome_update)


func create_player(event: Dictionary) -> void:
	var player_uuid = ""
	if event["data"].has("object_uuid"):
		player_uuid = event["data"]["object_uuid"]
	else:
		prints("ERROR: No player UUID found in event: %s" % event)
		return

	if players_list.has(player_uuid):
		# Player reconnecting — clean up stale instance and respawn
		prints("Player reconnecting, removing stale instance: %s" % player_uuid)
		var old_player = players_list[player_uuid]
		players_list.erase(player_uuid)
		players_list_last_movement.erase(player_uuid)
		players_list_last_rotation.erase(player_uuid)
		players_list_last_parent.erase(player_uuid)
		players_list_creationdate.erase(player_uuid)
		if is_instance_valid(old_player):
			old_player.queue_free()
		# Clear any stale pending messages for this player
		for msg in pending_messages_player_parenting.duplicate():
			if msg["data"].get("object_uuid", "") == player_uuid:
				pending_messages_player_parenting.erase(msg)
		# Fall through to spawn the new instance

	prints("Creating player on server side: %s" % event)
	var player_data = event["data"]["object_data"]

	if player_data["parent_id"] != "" and _search_parent_node(player_data["parent_id"]) == null:
		# store pending message
		pending_messages_player_parenting.append(event)
		print("Pending message for player %s because parent_id %s not found yet" % [event["data"]["object_uuid"], player_data["parent_id"]])
		return

	# print("Player data received: %s" % player_data)
	players_list_creationdate[player_uuid] = Time.get_ticks_msec() + 5000

	var spawned_entity_instance = player_scene.instantiate()
	spawned_entity_instance.name = player_data["name"]

	if player_data.has("is_npc") and player_data["is_npc"] == true:
		spawned_entity_instance.is_npc = true

	var parented = false
	if player_data["parent_id"] != "":
		var parent = _search_parent_node(player_data["parent_id"])
		if parent != null:
			parented = true
			parent.add_child(spawned_entity_instance)

	if not parented:
		# ORIGIN REBASE: an unparented player arrives in TRUE universe coordinates. Inside a
		# planet's region they must live in that planet's physics world (terrain collision is
		# unreachable from the root world): parent to the planet and convert to planet-local.
		# Open space stays under universe_scene at true coords (empty space costs nothing).
		var abs_pos := Vector3(
			player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"])
		var owner_planet := _owning_planet(abs_pos)
		if owner_planet != null:
			# The physics parent becomes the planet, but the NETWORK contract stays exactly what
			# Horizon believes: parent "" and UNIVERSE-absolute positions. player_server's
			# _net_position() adds the orbital offset back at every emit. Replicating the reparent
			# instead was tried and is UNSAFE: the players-position channel and the parenting
			# events are not atomic across Horizon, so the client applied planet-local positions
			# in its old frame and teleported thousands of km onto empty terrain (measured).
			owner_planet.add_child(spawned_entity_instance)
			var local_pos: Vector3 = abs_pos - _planet_orbital_abs(owner_planet)
			player_data["position"] = {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z}
		else:
			universe_scene.add_child(spawned_entity_instance)

	spawned_entity_instance.position = Vector3(
		player_data["position"]["x"],
		player_data["position"]["y"],
		player_data["position"]["z"]
	)
	# Derive the surface-normal "up" from the spawn position so the player is
	# oriented correctly on the planet surface, not stuck with global Vector3.UP.
	# (In a planet world, global_position IS planet-centric — the planet sits at the origin — so
	# this normalized() finally points along the real surface normal instead of the universe axis.)
	if not spawned_entity_instance.position.is_zero_approx():
		spawned_entity_instance.spawn_up = spawned_entity_instance.global_position.normalized()

	spawned_entity_instance.set_uuid(player_uuid)
	players_list.set(player_uuid, spawned_entity_instance)
	# Ask for the collision under this player NOW rather than up to PIN_TICK_INTERVAL render frames from
	# now: the body is held still until that chunk lands (PlayerServer._hold_until_ground), so every
	# frame of pinning latency is a frame of frozen player. Idempotent — the sweep pushes the whole set,
	# so calling it early cannot drop another player's pins.
	_refresh_active_body_pins()
	prints("spawning player", player_uuid, "in world of",
		_planet_ancestor_of(spawned_entity_instance).name if _planet_ancestor_of(spawned_entity_instance) != null else "ROOT",
		"at local", spawned_entity_instance.position, "true", _true_position(spawned_entity_instance))

	# Seed the change-detection in the SAME frame _on_player_move compares against (the emitted,
	# parent-LOCAL pose). Seeding it from global_position instead only ever forced a redundant first
	# update, but since the rebase those two frames differ by a whole planet radius, which made the
	# mismatch look like a real move.
	players_list_last_movement[player_uuid] = spawned_entity_instance.position
	players_list_last_rotation[player_uuid] = spawned_entity_instance.rotation
	# Seed the frame memo with the parent we just attached to: Horizon asked for it, so it already
	# knows. Without this the very first tick would re-announce a frame nobody changed.
	players_list_last_parent[player_uuid] = PropSpawn.parent_frame_uuid(spawned_entity_instance)

	spawned_entity_instance.connect("hs_server_move", _on_player_move)
	spawned_entity_instance.connect("hs_server_player_update", _on_player_update)
	players_list_creationdate[player_uuid] = Time.get_ticks_msec() + 500

func set_serverinfo(uuid: String) -> void:
	serverinfo_uuid = uuid

func create_generic_object(event: Dictionary) -> void:
	# spawn genericprops
	var object_data = event["data"]["object_data"]

	# Idempotency guard: a prop can be requested twice for the SAME uuid — e.g. a designer-placed
	# mining_depot is both echoed from persistence (Horizon) AND self-spawned by its in-scene
	# placeholder with the same deterministic uuid. Creating it twice leaves two overlapping bodies at
	# the same (planet-scale) spot. Never create a uuid we already have.
	var _existing_uuid = event["data"].get("object_uuid", "")
	var _existing_type = event["data"].get("object_type", "")
	if _existing_uuid != "" and props_list.has(_existing_type) \
			and props_list[_existing_type].has(_existing_uuid) \
			and is_instance_valid(props_list[_existing_type][_existing_uuid]):
		push_warning("[Server] create_generic_object: skipping duplicate uuid=%s type=%s (already created)" % [_existing_uuid, _existing_type])
		return

	if object_data.has("parent_id"):
		if object_data["parent_id"] != "" and _search_parent_node(object_data["parent_id"]) == null:
			# store pending message
			pending_messages_generic_objects_parenting.append(event)
			print("Pending message for object %s because parent_id %s not found yet" % [event["data"]["object_uuid"], object_data["parent_id"]])
			return

	var prop_scene: PackedScene
	if props_scene.has(object_data["scenename"]):
		prop_scene = props_scene[object_data["scenename"]]
	else:
		prop_scene = load("res://" + object_data["scenename"])

	# A persisted prop can reference a scene that no longer exists at that path (e.g. moved or
	# renamed by the asset-taxonomy migration). Skip it instead of crashing the whole loader.
	if prop_scene == null:
		push_warning("create_generic_object: scene not found for scenename '%s' (uuid %s), skipping" \
			% [object_data["scenename"], event["data"]["object_uuid"]])
		return

	var spawnable_prop_instance = prop_scene.instantiate()
	# Address the networking through the PropSync component when the prop has one; fall back to the root
	# for props not yet migrated to the component (so migration is incremental). Body-level ops
	# (physics/freeze/transform/props_list) stay on the root; only the contract (uuid/signals/data) moves.
	var net = PropSync.of(spawnable_prop_instance)
	if net == null:
		net = spawnable_prop_instance
	spawnable_prop_instance.set_physics_process(false)
	# ORIGIN REBASE: an unparented ("" parent) spawn arrives in TRUE universe coordinates from
	# Horizon. If a planet owns that region, the prop must live INSIDE that planet's physics world
	# (it cannot touch terrain from the root world): parent it to the planet below, and convert the
	# payload position to planet-local BEFORE client_channel_data_update applies it. On the first
	# server_tick the parent-change detection replicates parent_id + the local pose to
	# Horizon/clients, so their astro-layout scenes converge to the same world pose.
	var owner_planet: Planet = null
	if str(object_data.get("parent_id", "")) == "" and object_data.has("position"):
		var abs_pos := Vector3(
			object_data["position"]["x"], object_data["position"]["y"], object_data["position"]["z"])
		owner_planet = _owning_planet(abs_pos)
		if owner_planet != null:
			var local_pos: Vector3 = abs_pos - _planet_orbital_abs(owner_planet)
			object_data["position"] = {"x": local_pos.x, "y": local_pos.y, "z": local_pos.z}
	net.client_channel_data_update(object_data)
	net.uuid = event["data"]["object_uuid"]
	spawnable_prop_instance.tree_entered.connect(func():
		spawnable_prop_instance.owner = get_tree().current_scene
	)

	# Connect BEFORE add_child: add_child runs the prop's _ready(), and a prop that publishes state
	# from there (RockMining generates its first crack plane in _server_ready) would emit into a
	# signal nobody listens to yet — the crack existed on the server and never reached any client.
	# uuid is already assigned above, so _on_prop_update can key the update correctly.
	if net.has_signal("hs_server_prop_update"):
		net.connect("hs_server_prop_update", _on_prop_update)
	else:
		push_warning("[Server] create_generic_object: scene '%s' root has no signal hs_server_prop_update (type=%s)" \
			% [object_data["scenename"], spawnable_prop_instance.get_class()])
	if net.has_signal("hs_server_prop_delete"):
		net.connect("hs_server_prop_delete", _on_prop_delete)
	else:
		push_warning("[Server] create_generic_object: scene '%s' root has no signal hs_server_prop_delete (type=%s)" \
			% [object_data["scenename"], spawnable_prop_instance.get_class()])

	if object_data.has("parent_id"):
		if object_data["parent_id"] != "":
			var parent = _search_parent_node(object_data["parent_id"])
			if parent != null:
				parent.add_child(spawnable_prop_instance)
				if parent.has_method("request_nav_rebake"):
					parent.request_nav_rebake()
			else:
				universe_scene.add_child(spawnable_prop_instance)
		elif owner_planet != null:
			owner_planet.add_child(spawnable_prop_instance)  # rebase: into the owning planet's world
		else:
			universe_scene.add_child(spawnable_prop_instance)
	elif owner_planet != null:
		owner_planet.add_child(spawnable_prop_instance)  # rebase: into the owning planet's world
	else:
		universe_scene.add_child(spawnable_prop_instance)

	# Must be after signals in case call signals if modifications done in client_channel_data_update
	net.client_channel_data_update(object_data)

	props_list_last_movement[event["data"]["object_uuid"]] = Vector3.ZERO
	props_list_last_rotation[event["data"]["object_uuid"]] = Vector3.ZERO
	if not props_list.has(event["data"]["object_type"]):
		props_list[event["data"]["object_type"]] = {}
	props_list[event["data"]["object_type"]][event["data"]["object_uuid"]] = spawnable_prop_instance

	# check if position in zone, if not, freeze it (TRUE universe coords: the zone comes from
	# Horizon in absolute coordinates, the prop may live in a planet world near its origin)
	var pos = _true_position(spawnable_prop_instance)
	if pos[0] < server_zone["x_start"] or pos[0] > server_zone["x_end"] \
			or pos[1] < server_zone["y_start"] or pos[1] > server_zone["y_end"] \
			or pos[2] < server_zone["z_start"] or pos[2] > server_zone["z_end"]:
		#  we are out of zone, keep it frozen
		spawnable_prop_instance.set_physics_process(false)
		_set_prop_sync_ticking(spawnable_prop_instance, false)
		if is_instance_of(spawnable_prop_instance, RigidBody3D):
			spawnable_prop_instance.freeze = true
	else:
		# At server boot there are NO players yet, so every reloaded body would spawn awake and re-run
		# collision for ~SETTLE_TICKS before the settle-culler freezes it — a startup CPU spike with
		# thousands of rocks. Freeze settled free bodies up front instead; the culler unfreezes them
		# (they carry the _culled_frozen flag) as soon as a player comes within ACTIVE_RADIUS. A body
		# already near a player (rare at boot, possible on later GORC streaming) stays awake.
		if _is_cullable_body(spawnable_prop_instance) and not _player_within(pos, ACTIVE_RADIUS):
			_freeze_culled_body(spawnable_prop_instance)
		elif spawnable_prop_instance is RigidBody3D and _ground_missing_under(spawnable_prop_instance):
			# Nothing under it YET. Terrain collision is built chunk by chunk on worker threads, and at
			# a cold start `user://prebaked_collision/` is empty, so a body created now would meet only
			# the safety shells 100-200 m below the playable surface and sink through them.
			#
			# This branch exists because the one above deliberately skips VEHICLES: a truck being
			# driven must never be frozen. But a truck being CREATED is driven by nobody, and sixteen
			# trucks seeded into the world fell 7.4 km — measured, ending 1.8 km under the reference
			# radius, far outside every player's replication range, which is why none of them ever
			# appeared. Rocks were spared only because the branch above already froze them.
			#
			# ⚠️ Freezing a VehicleBody3D stops its suspension and lets the wheels sink into the body
			# (see the parking work). Harmless here and only here, because the hold is transient: the
			# culler unfreezes on approach, by which time the player is standing on loaded terrain, and
			# the suspension pushes the vehicle back up on the first step.
			_freeze_culled_body(spawnable_prop_instance)
		else:
			spawnable_prop_instance.set_physics_process(true)

	for pending_message in pending_messages_player_parenting.duplicate():
		if pending_message["data"]["object_data"]["parent_id"] == event["data"]["object_uuid"]:
			print(
				"Processing pending message for player %s now that parent_id %s is available" % [
					event["data"]["object_uuid"],
					pending_message["data"]["object_data"]["parent_id"]
				]
			)
			pending_messages_player_parenting.erase(pending_message)
			create_player(pending_message)

	# generic object created, now process pending messages for generic objects waiting for this generic object as parent
	for pending_message in pending_messages_generic_objects_parenting.duplicate():
		if pending_message["data"]["object_data"]["parent_id"] == event["data"]["object_uuid"]:
			print(
				"Processing pending message for generic object %s now that parent_id %s is available" % [
					pending_message["data"]["object_uuid"],
					pending_message["data"]["object_data"]["parent_id"]
				]
			)
			pending_messages_generic_objects_parenting.erase(pending_message)
			create_generic_object(pending_message)

func update_generic_object(event: Dictionary) -> void:
	var type = event["data"]["object_type"]
	if props_list[type].has(event["data"]["object_uuid"]):
		var object = props_list[type][event["data"]["object_uuid"]]
		var net = PropSync.of(object)
		if net == null:
			net = object
		net.client_channel_data_update(event["data"]["object_data"])


# ── Origin-rebase frame helpers ──────────────────────────────────────────────────────────────────
# Server-side, every planet lives at the ORIGIN of its own physics world (see create_planet); its
# true universe position is planet.orbital_position (data). Any comparison that crosses worlds — or
# faces Horizon, which always speaks TRUE universe coordinates — must go through these.

## Resolved universe-absolute centre per planet uuid, see _planet_orbital_abs. Only filled once the
## whole orbital chain is spawned, so a moon that arrives before its planet resolves on a later call.
var _orbital_abs_cache: Dictionary = {}

## TRUE universe position of [param p]'s centre. NOT the same as p.orbital_position for a moon:
## Horizon sends a moon's position RELATIVE to the planet it orbits (P3_M1 arrives at ~3e7 m while
## Tarsis 3 sits at ~3.3e10 m), so the chain has to be summed. Everything that compares positions
## ACROSS worlds — the settle-culler radius, the Horizon zone bounds, spawn ownership — must go
## through this, or a body on a moon reads as ~3.3e10 m away from where it really is.
##
## Lazy + cached: message order is not guaranteed, so an unresolved parent returns the best-effort
## sum WITHOUT caching it, and the next call retries once the parent has spawned.
func _planet_orbital_abs(p: Planet) -> Vector3:
	if _orbital_abs_cache.has(p.uuid):
		return _orbital_abs_cache[p.uuid]
	var acc: Vector3 = p.orbital_position
	var cur: Planet = p
	var guard: int = 0
	while cur.orbital_parent_uuid != "" and guard < 8:  # guard: never loop on a cyclic record
		guard += 1
		var pn = props_list["planets"].get(cur.orbital_parent_uuid)
		if not (pn is Planet) or not is_instance_valid(pn):
			return acc  # parent not spawned yet — retry on the next call, don't cache
		cur = pn as Planet
		acc += cur.orbital_position
	_orbital_abs_cache[p.uuid] = acc
	return acc


## The Planet whose world [param node] lives in (nearest Planet ancestor), or null for a root-world
## node (ship or player in open space).
func _planet_ancestor_of(node: Node) -> Planet:
	var n: Node = node
	while n != null:
		if n is Planet:
			return n as Planet
		n = n.get_parent()
	return null

## Radius out to which a planet OWNS space: the reference sphere, the tallest terrain rising above
## it, and the atmosphere shell on top. This is the planet/space FRONTIER — inside it a body belongs
## in the planet's physics world, outside it in the root world (open space). Terrain height matters:
## with no atmosphere at all (a bare moon) the bare radius would leave anyone standing on a mountain
## outside their own planet.
func _planet_domain_radius(p: Planet) -> float:
	if p.planet_data == null:
		return 0.0
	return p.planet_data.radius + p.planet_data.max_height + p.planet_data.get_atmosphere_top()


## The planet owning TRUE-universe position [param abs_pos], or null for open space. Ties break on
## the closest centre, so a moon sitting inside its planet's domain still wins at its own surface.
func _owning_planet(abs_pos: Vector3) -> Planet:
	var best: Planet = null
	var best_d := INF
	for puuid in props_list["planets"].keys():
		var pn = props_list["planets"][puuid]
		if pn == null or not is_instance_valid(pn) or not (pn is Planet):
			continue
		var p: Planet = pn as Planet
		if p.planet_data == null:
			continue
		var d: float = abs_pos.distance_squared_to(_planet_orbital_abs(p))
		var max_r: float = _planet_domain_radius(p)
		if d <= max_r * max_r and d < best_d:
			best_d = d
			best = p
	return best

## [param node]'s position in TRUE universe coordinates: orbital + world-local for planet-world
## residents (the planet sits at its world's origin with identity basis — the server never spins),
## plain global for root-world nodes. Comparable across worlds and against Horizon data.
func _true_position(node: Node3D) -> Vector3:
	var planet := _planet_ancestor_of(node)
	if planet == null:
		return node.global_position
	return _planet_orbital_abs(planet) + node.global_position


func _search_parent_node(parent_id: String) -> Node:
	for proptype in props_list.keys():
		if props_list[proptype].has(parent_id):
			return props_list[proptype][parent_id]
	for player_id in players_list.keys():
		if player_id == parent_id:
			return players_list[player_id]
	return null

func _on_player_update(
	client_uuid: String,
	properties: Dictionary,
):
	# Unified object-property replication: a player is sent as one prop-style entry
	# {type, uuid, <properties>} on the shared "props/update_object" channel, exactly
	# like a generic prop update. Horizon merges the whitelisted properties and
	# broadcasts them to nearby clients.
	var entry := {
		"type": "player",
		"uuid": client_uuid,
	}
	for key in properties.keys():
		entry[key] = properties[key]
	var message = {
		"namespace": "props",
		"event": "update_object",
		"data": [entry]
	}
	# TEMP DEBUG (dialog): prove whether the line reaches the websocket, i.e. whether the gap is
	# server-side or Horizon-side. Remove once the conversation replication is settled.
	if entry.has("conversation"):
		print("[dialog] -> wire: ", JSON.stringify(message))
	ServerNetwork.send_message(message, "player_update")

func remove_player(event: Dictionary) -> void:
	var player_uuid = event["data"]["object_uuid"]
	# Self-healing backstop: if this (PNJ) player owned a depot's reception role, free it so the
	# role never stays stuck on a gone owner. The depots register in the "cargo_depots" group.
	for depot in get_tree().get_nodes_in_group("cargo_depots"):
		if depot.has_method("clear_reception_owner_if"):
			depot.clear_reception_owner_if(player_uuid)
	if players_list.has(player_uuid):
		var player = players_list[player_uuid]
		print("player has quit the game: %s" % player_uuid)
		players_list.erase(player_uuid)
		player.queue_free()
	# Clear any pending spawn messages for this player
	for msg in pending_messages_player_parenting.duplicate():
		if msg["data"].get("object_uuid", "") == player_uuid:
			pending_messages_player_parenting.erase(msg)

func freeze_object(event: Dictionary, append = true) -> bool:
	# we will freeze scenes objects
	print("Freeze object: %s" % event)
	var object = event["data"]
	if object["object_type"] == "planet":
		if props_list["planets"].has(object["object_uuid"]):
			var planet = props_list["planets"][object["object_uuid"]]
			planet.set_physics_process(false)
			return true
		if append:
			pending_freeze_objects.append(event)
			return false
		return false
	if object["object_type"] == "player":
		if players_list.has(object["object_uuid"]):
			var player = players_list[object["object_uuid"]]
			print("erase player (1): %s" % object["object_uuid"])
			players_list.erase(object["object_uuid"])
			player.queue_free()
			return true
		return false
			# if append:
			# 	pending_freeze_objects.append(event)
			# else:
			# 	return false
	if object["object_type"] == "star":
		# TODO not yet managed
		return false
	# other props
	var found = false
	for proptype in props_list.keys():
		if props_list[proptype].has(object["object_uuid"]):
			var prop = props_list[proptype][object["object_uuid"]]
			prop.set_physics_process(false)
			_set_prop_sync_ticking(prop, false)
			if is_instance_of(prop, RigidBody3D):
				prop.freeze = true
			found = true
			break
	if not found:
		if append:
			pending_freeze_objects.append(event)
			return false
		return false
	return true

func manage_zone(event: Dictionary) -> void:
	var zone_data = event["data"]
	server_zone["x_start"] = zone_data["min_x"]
	server_zone["x_end"] = zone_data["max_x"]
	server_zone["y_start"] = zone_data["min_y"]
	server_zone["y_end"] = zone_data["max_y"]
	server_zone["z_start"] = zone_data["min_z"]
	server_zone["z_end"] = zone_data["max_z"]

	set_serverinfo(event["server_uuid"])
	serverinfo_name = event["server_name"]
	check_out_of_zone_after_split = Time.get_ticks_msec() + 5000

	# Push HEALPix chunk residency to every spawned planet so collision
	# memory tracks our authoritative zone.  See _push_zone_residency_*.
	_zone_initialized = true
	_push_zone_residency_to_all()


## The authoritative zone AABB, in TRUE UNIVERSE coordinates — Horizon speaks that frame and only
## that one. Server-side scene positions are per-planet-world since the origin rebase, so every
## comparison against this box goes through _true_position / _planet_orbital_abs.
func _server_zone_aabb_world() -> AABB:
	var pmin := Vector3(
		server_zone["x_start"], server_zone["y_start"], server_zone["z_start"])
	var pmax := Vector3(
		server_zone["x_end"], server_zone["y_end"], server_zone["z_end"])
	return AABB(pmin, pmax - pmin)


## Push the current zone-derived chunk residency to one planet.
## No-op when zone is not yet initialised or planet has no terrain.
func _push_zone_residency_to_planet(planet_node: Node) -> void:
	if not _zone_initialized:
		return
	if planet_node == null or not is_instance_valid(planet_node):
		return
	if not (planet_node is Planet):
		return
	var planet: Planet = planet_node as Planet
	if planet.planet_terrain == null or planet.planet_data == null:
		return
	# Fine-collision planets (file-mode crack planets like tarsis_3) get ALL
	# their collision from the per-body pin system at collision_detail_nside
	# (n8192). Do NOT also blanket the zone with coarse export-nside (n64)
	# chunks: both attach shapes to the SAME PlanetCollision body, and where a
	# coarse ~100 km facet crosses the fine surface the two floors sit within
	# capsule height — a body lands on the lower floor and is silently
	# depenetrated out of the upper one a few ticks later, forever. That was
	# the player/vehicle "dancing" around the base, and why the vehicle could
	# never fall asleep. An empty desired set also unloads any coarse chunks
	# attached earlier (pins are preserved — see _apply_residency).
	if planet.planet_data.collision_detail_nside() > planet.planet_data.export_nside:
		planet.planet_terrain.set_resident_chunks(PackedStringArray())
		return
	# Convert zone AABB from TRUE universe coords → planet-local by subtracting the ORBITAL
	# position (the node itself sits at the origin of its own world — rebase, see create_planet).
	var aabb_world := _server_zone_aabb_world()
	var aabb_local := AABB(
		aabb_world.position - _planet_orbital_abs(planet), aabb_world.size)
	var keys := planet.planet_data.chunks_in_aabb_world(aabb_local, 1)
	planet.planet_terrain.set_resident_chunks(keys)


## Push the current zone-derived chunk residency to every spawned planet.
func _push_zone_residency_to_all() -> void:
	if not _zone_initialized:
		return
	for planet_uuid in props_list["planets"].keys():
		_push_zone_residency_to_planet(props_list["planets"][planet_uuid])

func _check_out_of_zone(player_uuid: String = "") -> bool:
	if Time.get_ticks_msec() < check_out_of_zone_after_split:
		return false
	# check players position
	if players_list.has(player_uuid):
		if not players_list_creationdate.has(player_uuid):
			return false
		if Time.get_ticks_msec() < players_list_creationdate[player_uuid]:
			return false
		#print("go...")
		var pos = _true_position(players_list[player_uuid])  # zone bounds are TRUE universe coords
		var magicnumber = 0.400
		if pos[0] < (server_zone["x_start"] - magicnumber) or pos[0] > (server_zone["x_end"] + magicnumber) \
				or pos[1] < (server_zone["y_start"] - magicnumber) or pos[1] > (server_zone["y_end"] + magicnumber) \
				or pos[2] < (server_zone["z_start"] - magicnumber) or pos[2] > (server_zone["z_end"] + magicnumber):
			print("====== Player %s is out of zone at position %s" % [player_uuid, pos])
			print(server_zone)
			return true
	return false
