extends Node
## Bench: what one Horizon message costs the game server when a zone is handed over, or a player
## (NPC) arrives — the two main-thread costs that took preprod to 9-14 TPS on 2026-10-16
## (initial_object/simple_building 17 ms, storage_area 53-75 ms, mining_depot ~100 ms;
## add_prop/player 15-17 ms; see [Perf/proc] of that day).
##
## Runs the REAL dedicated server (GameOrchestrator boots it as usual) and plays Horizon in-process:
## messages go through ServerNetwork.dispatch_horizon_message after a JSON round trip, exactly as
## ServerNetwork._read_packets does. Every measured message is ALSO replayed step by step (a copy of
## create_generic_object / create_player with a timer per step) on its own uuid, so the total of the
## real path and the sum of the steps can be compared.
##
## Two runs:
##   BENCH_MODE=capture  tarsis_3 + the mining village of startup_items.json (mining_village_xx, the
##                       depot the preprod NPCs walked to); the village spawns its items as on a real
##                       server, every building is woken once so its TerrainPad measures and publishes
##                       terrain_settled, and the registry's events are saved — the shape Horizon
##                       persists and sends back.
##   BENCH_MODE=ingest   a fresh server replays those events as a zone hand-over (initial_object), then
##                       BENCH_NPCS NPC arrivals (add_prop/player) and the same number asleep
##                       (initial_object dormant + activate_object).
##                       BENCH_SETTLED=0 strips terrain_settled (a server that never measured them);
##                       BENCH_FILL=N first registers N mining rocks far away (preprod's receiving
##                       server held 17 000-21 000 objects).
##
## Run with:
##   BENCH_MODE=capture DS_PERF=1 GODOT_EDITOR_CUSTOM_FEATURES=dedicated_server \
##     godot --headless --path . res://test/perf/server_ingest_bench.tscn
## Output: user://server_ingest_bench_<mode>.txt (lines starting with BENCH); the capture writes
## user://server_ingest_payloads.json.

const PLANET_SCENE := "scenes/systems/tarsis/tarsis_3.tscn"
## Somewhere astronomic, like the real planet (the server works in planet-local coordinates anyway).
const PLANET_ORBIT := Vector3(8.0e10, 0.0, 2.0e10)
## mining_village_xx of horizonserver/ds_genericprops/startup_items.json (planet-local).
const VILLAGE_POS := Vector3(4465613.947, 2669284.115, -3663506.259)
const VILLAGE_ROT := Vector3(-0.3, 0.545, -1.117)
const VILLAGE_SPAWN_SCENE := "scenes/_universe/structures/urban/villages/ares_village_mining.tscn"
const VILLAGE_UUID := "bench0000-0000-4000-8000-000000000001"
const PAYLOADS := "user://server_ingest_payloads.json"
## A real add_prop/player of the 2026-10-16 preprod log, made an NPC.
const PLAYER_DATA := {
	"action": "land:1", "carry_prompt": "", "carrying": false, "floating": false, "head": 0.3,
	"head_yaw": 0.0, "is_npc": true, "mining_tool": false, "name": "npc", "parent_id": "",
	"perforating": false, "position": {"x": 0.0, "y": 0.0, "z": 0.0}, "rotation": {"x": 0.0, "y": 1.708, "z": 0.0},
	"seat": "", "spawn_appartment_id": "", "stance": 0.0, "tools": "", "type": "player", "uuid": "",
}

static var out_file: FileAccess = null

var _server: Node = null
var _mode: String = "ingest"
var _planet: Node = null
## The planet's uuid: the bench's own for a capture, the one the saved payloads hang from for an ingest.
var _planet_uuid: String = "_planet_SandBox"
var _saved: Dictionary = {}
## Where the ground is pinned and the NPCs spawn (planet-local): the bench village, or a captured depot.
var _ground_pos: Vector3 = VILLAGE_POS
## section name -> Array of usec, per message type ("type|section").
var _samples: Dictionary = {}
## [pads already registered, usec of one registration, road features it cuts], in order.
var _pad_growth: Array = []
## The quantised records registered, for the road-query probe.
var _pad_recs: Array = []


func say(t: String) -> void:
	if out_file == null:
		out_file = FileAccess.open("user://server_ingest_bench_%s.txt" % _mode, FileAccess.WRITE)
	out_file.store_line(t)
	out_file.flush()
	print(t)


func _ready() -> void:
	_mode = OS.get_environment("BENCH_MODE") if OS.get_environment("BENCH_MODE") != "" else "ingest"
	# GameOrchestrator has already queued the switch to the server's universe scene: step out of the
	# current-scene slot so that switch does not free the bench with it.
	get_tree().current_scene = null
	say("BENCH start mode=%s dedicated_server=%s" % [_mode, str(OS.has_feature("dedicated_server"))])
	_run.call_deferred()


func _run() -> void:
	if _mode != "capture" and not _load_payloads():
		get_tree().quit(1)
		return
	if not await _wait_server():
		get_tree().quit(1)
		return
	if not await _make_planet():
		get_tree().quit(1)
		return
	if _mode == "capture":
		await _capture()
	else:
		await _ingest()
	say("BENCH done")
	get_tree().quit(0)


# --- helpers ------------------------------------------------------------------------------------

## What Horizon does with a message: send it as text; what ServerNetwork does: parse it and dispatch.
## Returns the usec of parse + dispatch, the figure [Perf/proc] reports.
func _horizon(message: Dictionary) -> int:
	var text: String = JSON.stringify(message)
	var t0: int = Time.get_ticks_usec()
	var parsed = JSON.parse_string(text)
	ServerNetwork.dispatch_horizon_message(parsed)
	return Time.get_ticks_usec() - t0


func _note(key: String, usec: int) -> void:
	if not _samples.has(key):
		_samples[key] = []
	_samples[key].append(usec)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait_until(cond: Callable, timeout_ms: int, what: String) -> bool:
	var t0: int = Time.get_ticks_msec()
	while not cond.call():
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > timeout_ms:
			say("BENCH timeout waiting for %s (%d ms)" % [what, timeout_ms])
			return false
	say("BENCH %s after %d ms" % [what, Time.get_ticks_msec() - t0])
	return true


func _wait_server() -> bool:
	return await _wait_until(func():
		_server = NetworkOrchestrator.network_agent
		return _server != null and is_instance_valid(_server) and _server.get("universe_scene") != null,
		60000, "server up")


func _make_planet() -> bool:
	var t: int = _horizon({"namespace": "server", "event": "initial_object", "data": {
		"object_uuid": _planet_uuid, "object_type": "planets", "object_data": {
			"scenename": PLANET_SCENE, "name": "SandBox", "parent_id": "",
			"positions": [{"x": PLANET_ORBIT.x, "y": PLANET_ORBIT.y, "z": PLANET_ORBIT.z}]}}})
	say("BENCH create_planet message %.1f ms" % (t / 1000.0))
	_planet = _server.props_list["planets"].get(_planet_uuid)
	if _planet == null:
		say("BENCH planet not created")
		return false
	if not await _wait_until(func(): return _planet.get("planet_terrain") != null, 60000, "planet terrain"):
		return false
	# What Horizon does next: give this server the planet as its zone (no bounds = all of it, what the
	# local Horizon gave the capture), then pin the ground where players are about to arrive.
	_horizon({"namespace": "server", "event": "zone", "server_uuid": "bench-server", "server_name": "bench",
		"data": {"zones": [{"id": "bench-zone", "world": "planet", "planet_uuid": _planet_uuid, "planet_name": "SandBox"}]}})
	_horizon({"namespace": "server", "event": "prewarm", "data": {"planet_uuid": _planet_uuid,
		"ttl_ms": 3600000, "positions": [{"x": _ground_pos.x, "y": _ground_pos.y, "z": _ground_pos.z}]}})
	var terrain = _planet.planet_terrain
	if not await _wait_until(func():
		return terrain.has_collision_under(_ground_pos),
		120000, "ground under the village"):
		return false
	await _frames(120)  # let the first chunk wave settle before anything is timed
	return true


# --- capture ------------------------------------------------------------------------------------

func _capture() -> void:
	_horizon({"namespace": "server", "event": "initial_object", "data": {
		"object_uuid": VILLAGE_UUID, "object_type": "poi_village", "object_data": {
			"parent_id": _planet_uuid, "scenename": "scenes/_universe/structures/urban/poi_villages.tscn",
			"position": {"x": VILLAGE_POS.x, "y": VILLAGE_POS.y, "z": VILLAGE_POS.z},
			"rotation": {"x": VILLAGE_ROT.x, "y": VILLAGE_ROT.y, "z": VILLAGE_ROT.z},
			"is_spawned": false, "spawn_scene": VILLAGE_SPAWN_SCENE, "radius_m": 1000, "population": 250,
			"type": "minning", "name": "mining_village_xx"}}})
	var reg = _server.prop_registry
	# The village lives once its chunk is resident, then spawns its items into the registry.
	if not await _wait_until(func(): return reg.entries.size() > 5, 120000, "village items in the registry"):
		return
	await _frames(60)
	var items: Array = []
	for uuid in reg.entries:
		if uuid != VILLAGE_UUID:
			items.append(uuid)
	say("BENCH village spawned %d items" % items.size())
	# Wake each item once: its TerrainPad measures the relief and publishes terrain_settled, which the
	# registry keeps (_on_prop_update -> merge_data) like Horizon persists it.
	for uuid in items:
		_server.wake_prop(uuid)
	await _wait_until(func():
		var missing: int = 0
		for uuid in items:
			var od: Dictionary = reg.get_entry(uuid).get("event", {}).get("data", {}).get("object_data", {})
			if _server._stream_pad_templates_for(str(od.get("scenename", ""))).size() > 0 \
					and not (od.get("terrain_settled") is Dictionary):
				missing += 1
		return missing == 0, 120000, "every pad measured")
	await _frames(30)
	var out: Array = []
	var by_type: Dictionary = {}
	for uuid in items:
		var ev: Dictionary = reg.get_entry(uuid).get("event", {})
		if ev.is_empty():
			continue
		var data: Dictionary = (ev["data"] as Dictionary).duplicate(true)
		data.erase("dormant")
		out.append(data)
		var t: String = str(data.get("object_type", ""))
		by_type[t] = int(by_type.get(t, 0)) + 1
	var f := FileAccess.open(PAYLOADS, FileAccess.WRITE)
	f.store_string(JSON.stringify({"village": VILLAGE_UUID, "items": out}))
	f.close()
	say("BENCH saved %d payloads %s -> %s" % [out.size(), str(by_type), ProjectSettings.globalize_path(PAYLOADS)])


# --- ingest -------------------------------------------------------------------------------------

## Read the capture, and take the planet uuid from it: the one parent that is not itself an item.
func _load_payloads() -> bool:
	var path: String = OS.get_environment("BENCH_PAYLOADS") if OS.get_environment("BENCH_PAYLOADS") != "" else PAYLOADS
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		say("BENCH no payloads at %s: run BENCH_MODE=capture first" % path)
		return false
	_saved = JSON.parse_string(f.get_as_text())
	f.close()
	var uuids: Dictionary = {}
	for it in _saved["items"]:
		uuids[str(it["object_uuid"])] = true
	for it in _saved["items"]:
		var pid: String = str(it["object_data"].get("parent_id", ""))
		if pid != "" and not uuids.has(pid):
			_planet_uuid = pid
			break
	_saved["items"] = _parents_first(_saved["items"], uuids)
	# The NPCs of 2026-10-16 walked to a cargo depot: pin the ground and spawn them at one.
	for it in _saved["items"]:
		var od: Dictionary = it["object_data"]
		if str(it["object_type"]) == "cargo_depot" and str(od.get("parent_id", "")) == _planet_uuid:
			_ground_pos = Vector3(od["position"]["x"], od["position"]["y"], od["position"]["z"])
			break
	say("BENCH payloads %s: %d items on planet %s" % [path, _saved["items"].size(), _planet_uuid])
	return true


## Items ordered so that a parent always comes before its children.
static func _parents_first(items: Array, uuids: Dictionary) -> Array:
	var depth: Dictionary = {}
	var by_uuid: Dictionary = {}
	for it in items:
		by_uuid[str(it["object_uuid"])] = it
	for it in items:
		var d: int = 0
		var cur: Dictionary = it
		while d < 16:
			var pid: String = str(cur["object_data"].get("parent_id", ""))
			if not uuids.has(pid):
				break
			d += 1
			cur = by_uuid[pid]
		depth[str(it["object_uuid"])] = d
	var out: Array = items.duplicate()
	out.sort_custom(func(a, b): return depth[str(a["object_uuid"])] < depth[str(b["object_uuid"])])
	return out


func _ingest() -> void:
	var saved: Dictionary = _saved
	var settled: bool = OS.get_environment("BENCH_SETTLED") != "0"
	var fill: int = int(OS.get_environment("BENCH_FILL")) if OS.get_environment("BENCH_FILL") != "" else 0
	var npcs: int = int(OS.get_environment("BENCH_NPCS")) if OS.get_environment("BENCH_NPCS") != "" else 60
	say("BENCH ingest: %d payloads, settled=%s fill=%d npcs=%d" % [saved["items"].size(), str(settled), fill, npcs])
	_settled_check(saved["items"])
	if fill > 0:
		await _fill_registry(fill)
	await _ingest_props(saved["items"], settled)
	await _frames(120)
	_report("props")
	_report_growth()
	_samples.clear()
	await _ingest_players(npcs)
	_report("player hand-over")


## Mining rocks far from the village (another continent): registered, never built — the bulk of what
## preprod's receiving server held while the buildings came in.
func _fill_registry(n: int) -> void:
	var t0: int = Time.get_ticks_usec()
	var far: Vector3 = -_ground_pos
	for i in n:
		var p: Vector3 = far + Vector3(float(i % 200) * 3.0, 0.0, float(i / 200) * 3.0)
		_horizon({"namespace": "server", "event": "initial_object", "data": {
			"object_uuid": "fill%08d-0000-4000-8000-000000000000" % i, "object_type": "miningrock",
			"object_data": {"parent_id": _planet_uuid, "scenename": "scenes/_universe/environment/terrain/rocks/rock_mining_md.tscn",
				"position": {"x": p.x, "y": p.y, "z": p.z}, "rotation": {"x": 0.0, "y": 0.0, "z": 0.0}}}})
		if i % 500 == 499:
			await get_tree().process_frame
	say("BENCH filled the registry with %d rocks in %.0f ms (registry=%d)" % [n,
			(Time.get_ticks_usec() - t0) / 1000.0, _server.prop_registry.entries.size()])


## Parents before children (the order Horizon's snapshot uses does not guarantee it; a child whose
## parent is unknown just waits, which is cheap and measured as such).
func _ingest_props(items: Array, settled: bool) -> void:
	var batch: int = 0
	for i in items.size():
		var data: Dictionary = (items[i] as Dictionary).duplicate(true)
		var type: String = str(data.get("object_type", ""))
		if not settled:
			(data["object_data"] as Dictionary).erase("terrain_settled")
		# The real path, through ServerNetwork, under the captured uuid.
		var t: int = _horizon({"namespace": "server", "event": "initial_object", "data": data})
		_note(type + "|TOTAL real", t)
		# The same message step by step, under a fresh uuid (children keep pointing at real parents).
		var copy: Dictionary = (items[i] as Dictionary).duplicate(true)
		if not settled:
			(copy["object_data"] as Dictionary).erase("terrain_settled")
		var cu: String = "copy" + str(copy["object_uuid"]).substr(4)
		copy["object_uuid"] = cu
		copy["object_data"]["uuid"] = cu
		_rekey_settled(copy["object_data"], str(items[i]["object_uuid"]), cu)
		_create_generic_object_steps({"namespace": "server", "event": "initial_object", "data": copy}, type)
		batch += 1
		if batch >= 8:  # ~ Horizon's 450 messages/s over a 60 Hz frame
			batch = 0
			await get_tree().process_frame


## terrain_settled.pads is keyed by the pad's uuid ("prop:<building uuid>"): a copy under a fresh uuid
## must carry its measure under the new key, or every lookup misses.
static func _rekey_settled(od: Dictionary, from_uuid: String, to_uuid: String) -> void:
	var st = od.get("terrain_settled")
	if not (st is Dictionary) or not ((st as Dictionary).get("pads") is Dictionary):
		return
	var pads: Dictionary = st["pads"]
	var out: Dictionary = {}
	for k in pads:
		out[str(k).replace(from_uuid, to_uuid)] = pads[k]
	st["pads"] = out


## Would the server reuse each captured measure? Same check as _stream_register_pads, on the
## captured uuid, before anything is registered.
func _settled_check(items: Array) -> void:
	var pd: PlanetData = (_planet as Planet).planet_data
	var hit: Dictionary = {}
	var miss: Dictionary = {}
	var reliefs: Dictionary = {}
	for it in items:
		var od: Dictionary = it["object_data"]
		if not (od.get("terrain_settled") is Dictionary):
			continue
		var type: String = str(it["object_type"])
		reliefs[str(od["terrain_settled"].get("relief", ""))] = true
		var uuid: String = str(it["object_uuid"])
		var e: Dictionary = {"pos": Vector3(od["position"]["x"], od["position"]["y"], od["position"]["z"])}
		var any_hit: bool = false
		for tp in _server._stream_pad_templates_for(str(od.get("scenename", ""))):
			var terrain: PlanetTerrain = (_planet as Planet).planet_terrain
			var to_terrain: Transform3D = terrain.global_transform.affine_inverse() * (_planet as Planet).global_transform
			var rot: Vector3 = _server._stream_vec(od.get("rotation", {}))
			var item := Transform3D(Basis.from_euler(rot).scaled(tp["root_scale"]), e["pos"])
			var box_size: Vector3 = tp["box_size"]
			var box_local: Transform3D = tp["box_local"]
			var fit: Dictionary = _server._stream_pad_box_from_data(tp.get("root_script"), od)
			if not fit.is_empty():
				box_size = fit["size"]
				box_local = fit["local"]
			var rec: Dictionary = TerrainPad.record_from(pd, to_terrain * item * (tp["rel"] as Transform3D),
					box_size, box_local, float(tp["apron"]), float(tp["h_offset"]), "prop:" + uuid)
			if not rec.has("_refusal") and not pd.pad_settled_stats(rec, od["terrain_settled"]).is_empty():
				any_hit = true
		if any_hit:
			hit[type] = int(hit.get(type, 0)) + 1
		else:
			miss[type] = int(miss.get(type, 0)) + 1
	say("BENCH settled check: planet relief=%s, captured reliefs=%s | reused=%s | NOT reused=%s" % [
			pd.relief_signature, str(reliefs.keys()), str(hit), str(miss)])


## create_generic_object (server.gd), the non-dormant initial_object path, one timer per step.
## KEEP IN STEP with server.gd when it changes; the TOTAL real row says when it drifted.
func _create_generic_object_steps(message: Dictionary, type: String) -> void:
	var s = _server
	var t: int = Time.get_ticks_usec()
	var event: Dictionary = JSON.parse_string(JSON.stringify(message))
	t = _lap(type, "json parse", t)
	var uuid: String = str(event["data"]["object_uuid"])
	s.prop_registry.upsert(event)
	t = _lap(type, "registry upsert", t)
	s._stream_place(uuid)
	t = _lap(type, "_stream_place", t)
	s._stream_register_poi_zone(uuid)
	t = _lap(type, "poi zone", t)
	var entry: Dictionary = s.prop_registry.get_entry(uuid)
	var in_zones: bool = s._stream_in_zones(entry)
	t = _lap(type, "in zones", t)
	if not in_zones:
		s.prop_registry.forget(uuid)
		return
	s._stream_adopt_waiting(uuid)
	t = _lap(type, "adopt waiting", t)
	_register_pads_steps(uuid, type)
	t = Time.get_ticks_usec()
	if s._stream_should_live(entry):
		s._stream_enqueue(uuid)
	t = _lap(type, "should live + enqueue", t)
	s._stream_wake_requested_village(uuid)
	t = _lap(type, "wake village", t)


## server.gd _stream_register_pads, one timer per step.
func _register_pads_steps(uuid: String, type: String) -> void:
	var s = _server
	var t: int = Time.get_ticks_usec()
	var e: Dictionary = s.prop_registry.get_entry(uuid)
	if e.is_empty() or int(e["kind"]) != PropRegistry.KIND_GROUND or s.prop_registry.live.has(uuid):
		_lap(type, "pads: not a ground item", t)
		return
	var od: Dictionary = e["event"]["data"].get("object_data", {})
	s._stream_register_notch(uuid, e, od)
	t = _lap(type, "pads: notch", t)
	var templates: Array = s._stream_pad_templates_for(str(od.get("scenename", "")))
	t = _lap(type, "pads: templates", t)
	if templates.is_empty():
		return
	var planet = s.props_list["planets"].get(e["world"])
	if not (planet is Planet) or (planet as Planet).planet_terrain == null:
		return
	var terrain: PlanetTerrain = (planet as Planet).planet_terrain
	var rot: Vector3 = s._stream_vec(od.get("rotation", {}))
	var to_terrain: Transform3D = terrain.global_transform.affine_inverse() * (planet as Planet).global_transform
	for tp in templates:
		var item := Transform3D(Basis.from_euler(rot).scaled(tp["root_scale"]), e["pos"])
		var box_size: Vector3 = tp["box_size"]
		var box_local: Transform3D = tp["box_local"]
		var fit: Dictionary = s._stream_pad_box_from_data(tp.get("root_script"), od)
		if not fit.is_empty():
			box_size = fit["size"]
			box_local = fit["local"]
		t = _lap(type, "pads: box", t)
		var rec: Dictionary = TerrainPad.record_from((planet as Planet).planet_data,
				to_terrain * item * (tp["rel"] as Transform3D), box_size, box_local,
				float(tp["apron"]), float(tp["h_offset"]), "prop:" + uuid)
		t = _lap(type, "pads: record_from", t)
		if rec.has("_refusal"):
			continue
		if od.get("terrain_settled") is Dictionary:
			var st: Dictionary = (planet as Planet).planet_data.pad_settled_stats(rec, od["terrain_settled"])
			if not st.is_empty():
				rec["settled"] = st
			t = _lap(type, "pads: settled stats" + ("" if not st.is_empty() else " (MISS)"), t)
		_register_terrain_pad_steps(terrain, rec, type)
		t = Time.get_ticks_usec()


## PlanetTerrain.register_terrain_pad -> PlanetData.register_pad, one timer per step. KEEP IN STEP.
func _register_terrain_pad_steps(terrain: PlanetTerrain, rec_in: Dictionary, type: String) -> void:
	var pd: PlanetData = terrain.planet_data
	var k: String = "pad " + type
	var t0: int = Time.get_ticks_usec()
	var t: int = t0
	var rec := PadBed.quantise(rec_in)
	var settled: Dictionary = rec.get("settled", {})
	rec.erase("settled")
	var uuid := str(rec.get("uuid", ""))
	t = _lap(k, "quantise", t)
	pd._pad_mutex.lock()
	var idx: PadIndex = pd._ensure_pads()
	var n_pads: int = pd._pad_alt.size()
	var old: Dictionary = idx.get_rec(uuid)
	var dirty: Dictionary = idx.pixels_of(old) if not old.is_empty() else {}
	t = _lap(k, "old rec + pixels", t)
	var stats: Dictionary
	if PadBed.is_notch(rec):
		stats = {"z": float(rec["z"]), "span": 0.0, "talus_m": 0.0}
	else:
		stats = settled if not settled.is_empty() else pd._pad_stats_if_readable(rec)
	t = _lap(k, "stats" + (" (settled)" if not settled.is_empty() else " (MEASURED)"), t)
	var next: PadIndex = idx.clone()
	t = _lap(k, "index clone", t)
	if stats.is_empty():
		pd._pads_starved[uuid] = rec
		pd._pad_mutex.unlock()
		_lap(k, "starved (no tile)", t)
		return
	pd._pads_starved.erase(uuid)
	rec["z"] = float(stats["z"])
	rec["talus_m"] = float(stats["talus_m"])
	pd._pad_alt[uuid] = stats
	next.register(rec)
	t = _lap(k, "index register", t)
	var changed: Array = pd._settle_pad_levels(next, idx, [old, rec])
	var settle_usec: int = Time.get_ticks_usec() - t
	t = _lap(k, "settle levels", t)
	if changed.is_empty():
		pd._pad_mutex.unlock()
		return
	for u: String in changed:
		if u != uuid:
			dirty.merge(idx.pixels_of(idx.get_rec(u)))
		dirty.merge(next.pixels_of(next.get_rec(u)))
	t = _lap(k, "dirty pixels (%d changed)" % mini(changed.size(), 3), t)
	pd._pads = next
	var cuts: Dictionary = pd._pad_cuts_of(rec)
	var cuts_usec: int = Time.get_ticks_usec() - t
	t = _lap(k, "road cuts of the pad", t)
	pd._set_pad_road_cuts(uuid, rec)  # recomputes the cuts (counted twice), then merges every pad's
	t = _lap(k, "road cuts merge (incl. cuts again)", t)
	pd._pad_mutex.unlock()
	var nside: int = 1 << pd.max_quadtree_depth
	terrain._pad_dirty_pixels.merge(dirty)
	terrain._pad_generation += 1
	if terrain._initialized:
		terrain._rebuild_chunks_on_tiles(dirty, nside, "d'un pad de bâtiment", {})
		t = _lap(k, "rebuild chunks on tiles", t)
		terrain._invalidate_nav_over(dirty, nside)
		t = _lap(k, "invalidate nav", t)
	terrain._announce_caught_up_pads()
	t = _lap(k, "announce caught up", t)
	_note(k + "|TOTAL steps", t - t0)
	_pad_growth.append([n_pads, t - t0, cuts.size(), cuts_usec, settle_usec])
	_pad_recs.append(rec)


func _lap(type: String, section: String, since: int) -> int:
	var now: int = Time.get_ticks_usec()
	_note(type + "|" + section, now - since)
	return now


func _player_message(i: int, event: String, dormant: bool) -> Dictionary:
	var od: Dictionary = PLAYER_DATA.duplicate(true)
	var uuid: String = "npc%05d-%s-4000-8000-000000000000" % [i, event.substr(0, 4)]
	od["uuid"] = uuid
	od["name"] = "npc_%s_%d" % [event.substr(0, 4), i]
	od["parent_id"] = ""
	# Around the depot, 2 m above the village origin, 3 m apart.
	var up: Vector3 = _ground_pos.normalized()
	var east: Vector3 = up.cross(Vector3.UP).normalized()
	var north: Vector3 = east.cross(up)
	var p: Vector3 = _ground_pos + up * 2.0 + east * float(i % 10) * 3.0 + north * float(i / 10) * 3.0
	p += PLANET_ORBIT  # unparented: Horizon sends true universe coordinates, the server adopts it into the planet
	od["position"] = {"x": p.x, "y": p.y, "z": p.z}
	var data: Dictionary = {"object_uuid": uuid, "object_type": "player", "object_data": od}
	if dormant:
		data["dormant"] = true
	return {"namespace": "server", "event": event, "data": data}


func _ingest_players(n: int) -> void:
	# 1) Arrivals, as the wave of 2026-10-16 (add_prop/player), half real path, half step by step.
	for i in n:
		var msg: Dictionary = _player_message(i, "add_prop", false)
		if i % 2 == 0:
			_note("player arrival|TOTAL real", _horizon(msg))
		else:
			_create_player_steps(msg)
		await get_tree().process_frame
	say("BENCH players live=%d pending parent=%d" % [_server.players_list.size(),
			_server.pending_messages_player_parenting.size()])
	var any_player = _server.players_list.values()[0] if not _server.players_list.is_empty() else null
	if any_player != null:
		say("BENCH one NPC = %d nodes (%s)" % [_count_nodes(any_player), _top_children(any_player)])
	_report("player arrivals")
	_samples.clear()
	await _npc_bisect(any_player)
	_report("NPC tree entry, by top-level child removed before add_child")
	_samples.clear()
	# 2) A hand-over: the same number sent asleep, then woken (initial_object dormant + activate_object).
	for i in n:
		_note("player hand-over|initial_object dormant", _horizon(_player_message(i, "initial_object", true)))
		await get_tree().process_frame
	for i in n:
		var awake: Dictionary = _player_message(i, "initial_object", false)
		awake["event"] = "activate_object"
		_note("player hand-over|activate_object", _horizon(awake))
		await get_tree().process_frame


## create_player (server.gd), one timer per step. KEEP IN STEP with server.gd.
func _create_player_steps(message: Dictionary) -> void:
	var s = _server
	var k: String = "player arrival"
	var t: int = Time.get_ticks_usec()
	var event: Dictionary = JSON.parse_string(JSON.stringify(message))
	t = _lap(k, "json parse", t)
	var player_uuid: String = event["data"]["object_uuid"]
	s._drop_dormant_player(player_uuid)
	t = _lap(k, "drop dormant", t)
	prints("Creating player on server side: %s" % event)
	t = _lap(k, "print(event)", t)
	var player_data = event["data"]["object_data"]
	if str(player_data.get("parent_id", "")) != "":
		s._stream_force_live(str(player_data["parent_id"]))
	t = _lap(k, "force live parent", t)
	var parent = s._search_parent_node(player_data["parent_id"]) if player_data["parent_id"] != "" else null
	t = _lap(k, "search parent", t)
	s.players_list_creationdate[player_uuid] = Time.get_ticks_msec() + 5000
	var p = s.player_scene.instantiate()
	t = _lap(k, "instantiate", t)
	p.name = player_data["name"]
	if player_data.get("is_npc", false):
		p.is_npc = true
	if parent != null:
		parent.add_child(p)
	else:
		s.universe_scene.add_child(p)
	t = _lap(k, "add_child (enter tree + _ready)", t)
	p.position = Vector3(player_data["position"]["x"], player_data["position"]["y"], player_data["position"]["z"])
	if not p.position.is_zero_approx():
		p.spawn_up = p.global_position.normalized()
	p.owns_mining_tool = bool(player_data.get(Player.MINING_TOOL_KEY, false))
	p.set_uuid(player_uuid)
	t = _lap(k, "pose + set_uuid", t)
	s._register_player(p, player_uuid, false)
	t = _lap(k, "_register_player", t)


## What each top-level child of the player scene costs to enter the tree (and _ready), NPC as on the
## server: add_child with that child removed, against add_child of the whole scene.
func _npc_bisect(sample: Node) -> void:
	if sample == null:
		return
	var parent: Node = sample.get_parent()
	var names: Array = [""]
	var probe = _server.player_scene.instantiate()
	for ch in probe.get_children():
		names.append(str(ch.name))
	probe.free()
	for rep in 6:
		for nm in names:
			var p = _server.player_scene.instantiate()
			p.is_npc = true
			p.name = "bisect_%d_%s" % [rep, nm]
			if nm != "":
				var c: Node = p.get_node_or_null(NodePath(nm))
				if c != null:
					p.remove_child(c)
					c.free()
			var t0: int = Time.get_ticks_usec()
			parent.add_child(p)
			_note("npc entry|" + ("WHOLE scene" if nm == "" else "without " + nm), Time.get_ticks_usec() - t0)
			p.position = sample.position + Vector3(0, 50.0 + rep, 0)
			p.process_mode = Node.PROCESS_MODE_DISABLED
			await get_tree().process_frame
			p.queue_free()
			await get_tree().process_frame


func _count_nodes(n: Node) -> int:
	var c: int = 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


func _top_children(n: Node) -> String:
	var parts: PackedStringArray = []
	for ch in n.get_children():
		parts.append("%s=%d" % [ch.name, _count_nodes(ch)])
	return " ".join(parts)


## Does one pad registration get dearer as pads pile up? Means by bucket of already-registered pads.
func _report_growth() -> void:
	var buckets: Dictionary = {}
	for g in _pad_growth:
		var b: int = int(g[0]) / 25 * 25
		if not buckets.has(b):
			buckets[b] = [0, 0, 0, 0, 0]
		buckets[b][0] += 1
		buckets[b][1] += int(g[1])
		buckets[b][2] += int(g[2])
		buckets[b][3] += int(g[3])
		buckets[b][4] += int(g[4])
	var keys: Array = buckets.keys()
	keys.sort()
	for b in keys:
		var nb: float = float(buckets[b][0])
		say("BENCH pad growth: %3d-%3d pads already: n=%3d mean=%6.2f ms (road cuts %.2f, settle %.2f), road features cut %.1f" % [
				b, b + 24, buckets[b][0], buckets[b][1] / 1000.0 / nb, buckets[b][3] / 1000.0 / nb,
				buckets[b][4] / 1000.0 / nb, float(buckets[b][2]) / nb])
	_road_query_probe()


## Where _pad_cuts_of's time goes: get_roads_for_chunk on the 9 finest pixels around a pad, each
## called twice (cold = what a registration pays, warm = a cache would give), and how many roads.
func _road_query_probe() -> void:
	var pd: PlanetData = (_planet as Planet).planet_data
	var nside: int = 1 << maxi(pd.max_quadtree_depth, 0)
	var cold: Array = []
	var warm: Array = []
	var roads: int = 0
	var cut_pads: int = 0
	var t_cuts: Array = []
	var excl_usec: Array = []
	var excl_len: Array = []
	for i in mini(40, _pad_recs.size()):
		var rec: Dictionary = _pad_recs[i]
		var ipix: int = HEALPix.vec2pix_nest(nside, HEALPix.lonlat2vec(float(rec["lon"]), float(rec["lat"])))
		var pix: Array = [ipix]
		for nb in HEALPix.get_neighbors_nest(nside, ipix).values():
			if int(nb) >= 0:
				pix.append(int(nb))
		for ip: int in pix:
			var t0: int = Time.get_ticks_usec()
			var r: Array = pd.get_roads_for_chunk(nside, ip)
			cold.append(Time.get_ticks_usec() - t0)
			t0 = Time.get_ticks_usec()
			pd.get_roads_for_chunk(nside, ip)
			warm.append(Time.get_ticks_usec() - t0)
			roads += r.size()
		for ip: int in pix:
			for r: Dictionary in pd.get_roads_for_chunk(nside, ip):
				var cl: PackedVector2Array = r.get("centerline", PackedVector2Array())
				var cum: PackedFloat64Array = r.get("_cum_lengths", PackedFloat64Array())
				if cl.size() < 2 or cum.size() != cl.size():
					continue
				var t2: int = Time.get_ticks_usec()
				PadBed.road_exclusion(rec, cl, cum, pd.radius * PI / 180.0,
						float(r.get("half_width_m", RoadTerrain.get_half_width_m(r))))
				excl_usec.append(Time.get_ticks_usec() - t2)
				excl_len.append(cum[cum.size() - 1])
		var t1: int = Time.get_ticks_usec()
		if not pd._pad_cuts_of(rec).is_empty():
			cut_pads += 1
		t_cuts.append(Time.get_ticks_usec() - t1)
	var mean := func(v: Array) -> float:
		var tot: float = 0.0
		for x in v:
			tot += x
		return tot / maxf(v.size(), 1) / 1000.0
	say(("BENCH road query probe (n%d, %d pads x 9 pixels): get_roads_for_chunk 1st call %.2f ms, 2nd call %.2f ms,"
			+ " %.2f roads/pixel; _pad_cuts_of again %.2f ms, %d/%d pads cut a road; has_roads=%s") % [
			nside, t_cuts.size(), mean.call(cold), mean.call(warm), float(roads) / maxf(cold.size(), 1),
			mean.call(t_cuts), cut_pads, t_cuts.size(), str(pd.has_roads())])
	var lens: Array = excl_len.duplicate()
	lens.sort()
	say(("BENCH road_exclusion: %d calls (pieces seen from the 9 pixels, duplicates included), %.2f ms each,"
			+ " piece length median %.0f m max %.0f m, step %.2f m") % [
			excl_usec.size(), mean.call(excl_usec), lens[lens.size() / 2] if not lens.is_empty() else 0.0,
			lens[-1] if not lens.is_empty() else 0.0, PadSettings.ROAD_CUT_STEP_M])


## Per message type, per step: count, mean, median, max (ms). Steps sorted by total time.
func _report(title: String) -> void:
	var by_type: Dictionary = {}
	for key in _samples:
		var parts: PackedStringArray = (key as String).split("|")
		if not by_type.has(parts[0]):
			by_type[parts[0]] = []
		by_type[parts[0]].append(parts[1])
	say("BENCH ===== %s =====" % title)
	for type in by_type:
		var rows: Array = []
		var steps_sum: float = 0.0
		for section in by_type[type]:
			var v: Array = (_samples[type + "|" + section] as Array).duplicate()
			v.sort()
			var total: float = 0.0
			for x in v:
				total += x
			rows.append([section, v.size(), total / v.size() / 1000.0, v[v.size() / 2] / 1000.0, v[-1] / 1000.0, total])
			if not (section as String).begins_with("TOTAL") and not (section as String).begins_with("player hand-over"):
				steps_sum += total / v.size() / 1000.0
		rows.sort_custom(func(a, b): return a[5] > b[5])
		say("BENCH -- %s (sum of step means %.2f ms)" % [type, steps_sum])
		for r in rows:
			say("BENCH    %-36s n=%4d mean=%8.2f med=%8.2f max=%8.2f ms" % [r[0], r[1], r[2], r[3], r[4]])
