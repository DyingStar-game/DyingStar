class_name LavaEruptions
extends Node
## SERVER: the lava of the volcanoes' eruptions. The authority of the deterministic lava simulation
## (LavaPlanetPatch, lava_fixed_core.gd), published to the clients as LavaFlow props.
##
## Once a second, for every planet a player of this server stands on: each volcano that can erupt (not dormant,
## with a crater) within [member activation_radius_m] of one of them is asked whether it erupts now
## (VolcanoActivityProfile.eruption_window, the same schedule the clients use for plumes and stones).
## An eruption under way gets a patch:
##   1. its crater and flanks are sampled once, a few rows per frame (LavaPlanetPatch.start_build): the empty
##      field is kept per volcano, the relief does not change between eruptions;
##   2. the integer plan of the eruption is set and the patch installed in the planet's lava runtime, which
##      runs its ticks on the shared clock, catching up when the eruption started before anyone came near;
##   3. once caught up, the LavaFlow prop is created (or updated: one per volcano), then every
##      [constant DIGEST_MS] its tick and state digest, every [constant CHECKPOINT_MS] its checkpoint;
##   4. when the eruption is over and its deposit has cooled and gone, the prop is deleted.
## A LavaFlow already known for that eruption (another server, or this one before a restart) is adopted from
## its checkpoint instead of sampled again; one left over from a finished eruption is deleted.
##
## Every peer runs the same integer simulation from the same checkpoint and plan: two servers adopting the same
## eruption publish the same states.

const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
const Core = preload("res://scenes/planet/lava/lava_fixed_core.gd")
const SWEEP_MS := 1000
const DIGEST_MS := 5000
const CHECKPOINT_MS := 60000
## How long after receiving zones (or booting) the objects of those zones may still be on their way (ms): a
## persisted LavaFlow must be found before a new one is made.
const SETTLE_MS := 20000
## Main-thread time (µs) the crater sampling may take per frame.
const BUILD_BUDGET_USEC := 3000
## Empty fields kept (one per volcano sampled).
const EMPTY_KEEP := 16
## How often (ms) an eruption still waiting for its terrain tiles says so.
const WAIT_LOG_MS := 30000
## How often (ms) an eruption still catching up on its start says how far it is.
const CATCH_UP_LOG_MS := 10000
## How often (ms) a planet with players reports its nearest volcano (clock, distance, eruption or calm).
const REPORT_MS := 300000

## Distance (m) from a player within which a volcano's eruption is simulated: larger = lava already flowing
## when a fast traveller arrives, more volcanoes simulated at once.
var activation_radius_m := 50000.0
## Patches simulated at once per planet: a further eruption waits for a free one.
var max_patches := 8
## Ticks one worker job may run per frame while catching up: higher = faster catch-up, longer jobs.
var catch_up_ticks := 40

## Hooks into the server, bound by server.gd (tests pass their own).
## func() -> Dictionary: planet uuid -> Planet.
var planets: Callable
## func() -> Dictionary: planet uuid -> PackedVector3Array of its players' positions in its frame
## (see [method viewer_positions]).
var viewers: Callable
## func(uuid: String) -> Dictionary: the object data the server holds for that prop, {} when it has none.
var registry_data: Callable
## func(data: Dictionary): create a prop (see NetworkOrchestrator.spawn_prop_authoritative).
var spawn_prop: Callable
## func(uuid: String, props: Dictionary, type: String): change a prop's fields, replicated and persisted.
var update_prop: Callable
## func(uuid: String, type: String): delete a prop.
var delete_prop: Callable
var now_ms: Callable = func() -> int: return Time.get_ticks_msec()
var clock_ms: Callable = func() -> int: return int(Globals.reference_time() * 1000.0)

## prop uuid -> {planet, volcano, window, packet, plan, key, state ("tiles" | "build" | "run"), job,
## published, next_digest_ms, next_checkpoint_ms}
var _eruptions: Dictionary = {}
## planet uuid -> Array of the volcanoes that can erupt.
var _volcanoes: Dictionary = {}
## "planet/volcano key" -> empty-field packet (LavaPlanetPatch.build).
var _empty: Dictionary = {}
var _settled_at := 0
var _next_sweep := 0
var _next_report: Dictionary = {}  # planet uuid -> now_ms of its next nearest-volcano report


func _ready() -> void:
	_settled_at = int(now_ms.call()) + SETTLE_MS
	_load_config()


## The server was given zones: Horizon sends their objects again, LavaFlows among them.
func zones_assigned() -> void:
	_settled_at = int(now_ms.call()) + SETTLE_MS


func _process(_delta: float) -> void:
	if not LavaSettings.simulated_craters:
		return
	var now := int(now_ms.call())
	if now >= _next_sweep and now >= _settled_at:
		_next_sweep = now + SWEEP_MS
		_sweep()
	var build_spent := false
	for uuid: String in _eruptions.keys():
		var e: Dictionary = _eruptions[uuid]
		if not is_instance_valid(e.planet):
			_eruptions.erase(uuid)
			continue
		match str(e.state):
			"tiles":
				var job = Builder.start_build(e.planet.planet_data, e.volcano)
				if job != null:
					e.job = job
					e.state = "build"
					print("[LAVA] %s: terrain tiles resident after %.1f s, sampling the crater" % [
						_base_key(e.planet, e.volcano), (now - int(e.since_ms)) / 1000.0])
				elif now >= int(e.next_wait_log_ms):
					e.next_wait_log_ms = now + WAIT_LOG_MS
					var source: Variant = e.planet.planet_data.remote_source
					print("[LAVA] %s: still waiting for the terrain tiles of the crater (%.0f s): %d/%d pixels missing, download queue %s" % [
						_base_key(e.planet, e.volcano), (now - int(e.since_ms)) / 1000.0, Builder.last_missing,
						Builder.last_required, str(source.queue_stats()) if source != null else "none"])
			"build":
				if not build_spent:  # one crater at a time
					build_spent = true
					if e.job.step(BUILD_BUDGET_USEC):
						_built(e, e.job.result)
			"run":
				_publish(uuid, e, now)


## Starts the eruptions under way near the players, and forgets the LavaFlows of eruptions long over.
func _sweep() -> void:
	var near: Dictionary = viewers.call()
	var clock_s := int(clock_ms.call()) / 1000.0
	for planet_uuid: String in near:
		var planet: Planet = (planets.call() as Dictionary).get(planet_uuid)
		var runtime := _runtime_of(planet)
		if runtime == null:
			continue
		var profile := VolcanoActivityProfile.for_planet(planet.planet_data.planet_name)
		var radius_m: float = planet.planet_data.radius
		if int(now_ms.call()) >= int(_next_report.get(planet_uuid, 0)):
			_next_report[planet_uuid] = int(now_ms.call()) + REPORT_MS
			_report_nearest(planet, near[planet_uuid], profile, clock_s)
		for v: VolcanoRelief.Volcano in _volcanoes_of(planet):
			var summit := v.c.normalized() * radius_m
			if not _any_within(near[planet_uuid], summit, activation_radius_m):
				continue
			var key := VolcanoFeatures.key_of(v)
			var uuid := LavaFlow.uuid_for(planet.planet_data.planet_name, key)
			var window := profile.eruption_window(clock_s, v.seed ^ int(key.hash()), key, v.activity == "dormant")
			var start_ms := -1 if window.is_empty() else roundi(float(window.start_unix) * 10.0) * 100
			if _eruptions.has(uuid):
				if start_ms < 0 or int(_eruptions[uuid].plan.get("start_unix_ms", start_ms)) == start_ms:
					continue
				_finish(uuid, false)  # a new eruption replaces the previous patch
			var known: Dictionary = registry_data.call(uuid)
			if start_ms < 0:
				if not known.is_empty() and _over(known):
					delete_prop.call(uuid, LavaFlow.TYPE)
					print("[LAVA] %s: leftover lava of a finished eruption deleted" % key)
				continue
			if _count_on(planet) >= max_patches:
				continue
			_begin(uuid, planet, v, window, start_ms, known)


## One line: the server's clock, the volcano nearest to a player of [param planet], how far, and whether it
## erupts now or when next. Tells a wrong clock, a wrong distance and a calm volcano apart.
func _report_nearest(planet: Planet, points: PackedVector3Array, profile: VolcanoActivityProfile, clock_s: float) -> void:
	var best: VolcanoRelief.Volcano = null
	var best_m := INF
	for v: VolcanoRelief.Volcano in _volcanoes_of(planet):
		var summit := v.c.normalized() * planet.planet_data.radius
		for p in points:
			if p.distance_to(summit) < best_m:
				best_m = p.distance_to(summit)
				best = v
	if best == null:
		print("[LAVA] %s: %d player position(s), no volcano to report" % [planet.planet_data.planet_name, points.size()])
		return
	var key := VolcanoFeatures.key_of(best)
	var vseed := best.seed ^ int(key.hash())
	var state := "calm"
	var window := profile.eruption_window(clock_s, vseed, key)
	if not window.is_empty():
		state = "erupting since %s" % Time.get_datetime_string_from_unix_time(int(window.start_unix))
	else:
		for minutes in range(1, 121):
			var ahead := profile.eruption_window(clock_s + minutes * 60.0, vseed, key)
			if not ahead.is_empty():
				state = "calm, next eruption %s" % Time.get_datetime_string_from_unix_time(int(ahead.start_unix))
				break
	var uuid := LavaFlow.uuid_for(planet.planet_data.planet_name, key)
	print("[LAVA] %s: clock %s, %d player(s), nearest volcano %s at %.1f km (activation %.0f km): %s; %s" % [
		planet.planet_data.planet_name, Time.get_datetime_string_from_unix_time(int(clock_s)), points.size(), key,
		best_m / 1000.0, activation_radius_m / 1000.0, state,
		"tracked (%s)" % str(_eruptions[uuid].state) if _eruptions.has(uuid) else "not tracked"])


func _begin(uuid: String, planet: Planet, v: VolcanoRelief.Volcano, window: Dictionary, start_ms: int,
		known: Dictionary) -> void:
	var e := {"planet": planet, "volcano": v, "window": window, "packet": {}, "plan": {"start_unix_ms": start_ms},
		"key": "", "state": "tiles", "job": null, "published": false, "next_digest_ms": 0, "next_checkpoint_ms": 0,
		"since_ms": int(now_ms.call()), "next_wait_log_ms": int(now_ms.call()) + WAIT_LOG_MS}
	_eruptions[uuid] = e
	print("[LAVA] %s: eruption under way since %s (%d min, strength %.2f), a player within %.0f km" % [
		_base_key(planet, v), Time.get_datetime_string_from_unix_time(int(start_ms / 1000)),
		roundi(float(window.length_s) / 60.0), float(window.strength), activation_radius_m / 1000.0])
	var plan: Variant = known.get("plan")
	if plan is Dictionary and int((plan as Dictionary).get("start_unix_ms", -1)) == start_ms:
		var description := LavaFlow.description_from(known)
		if not description.is_empty() and _runtime_of(planet).install_patch(description):
			e.key = description.key
			e.plan = description.plan
			e.state = "run"
			e.published = true
			print("[LAVA] %s: eruption adopted from its LavaFlow at tick %d" % [
				description.volcano_key, int(known.get("checkpoint_tick", 0))])
			return
	var cached: Dictionary = _empty.get(_base_key(planet, v), {})
	if not cached.is_empty():
		_built(e, cached)


## The empty field of [param e]'s volcano is sampled: install it with the eruption's plan.
func _built(e: Dictionary, packet: Dictionary) -> void:
	e.job = null
	var base := _base_key(e.planet, e.volcano)
	if packet.is_empty() or packet.get("rejected", false):
		if not _empty.has(base):
			push_warning("[LAVA] %s: crater cannot be simulated (relief too steep or invalid volcano)" % base)
			_empty[base] = {"rejected": true}
		e.state = "rejected"
		return
	if not _empty.has(base):
		if _empty.size() >= EMPTY_KEEP:
			_empty.erase(_empty.keys()[0])
		_empty[base] = packet
		print("[LAVA] %s sampled in %.0f ms (field %.0f m)" % [base, float(packet.build_ms), float(packet.field_radius_m)])
	var description: Dictionary = packet.duplicate()
	description.key = base
	description.plan = Builder.eruption_plan(e.window, packet)
	var runtime := _runtime_of(e.planet)
	if runtime == null or not runtime.install_patch(description):
		push_warning("[LAVA] %s: patch refused by the lava runtime" % base)
		e.state = "rejected"
		return
	e.packet = description
	e.plan = description.plan
	e.key = base
	e.state = "run"


## Prop, digests and checkpoints of a running eruption; its end once the deposit is gone.
func _publish(uuid: String, e: Dictionary, now: int) -> void:
	var runtime := _runtime_of(e.planet)
	if runtime == null or not runtime.patches.has(e.key):
		_eruptions.erase(uuid)
		return
	var tick: int = runtime.patch_tick(e.key)
	var target: int = runtime.target_tick(e.key)
	if runtime.is_cleaned_up(e.key) and tick > int(e.plan.eruption_ticks):
		_finish(uuid, true)
		return
	if not e.published:
		if tick < target - 1:
			# Still catching up: clients would start from an old state.
			if now >= int(e.get("next_catch_up_log_ms", 0)):
				var rate := 0.0
				if e.has("catch_up_from"):
					rate = (tick - int(e.catch_up_from)) * 1000.0 / maxf(1.0, now - int(e.catch_up_since))
				else:
					e.catch_up_from = tick
					e.catch_up_since = now
				e.next_catch_up_log_ms = now + CATCH_UP_LOG_MS
				print("[LAVA] %s: catching up the eruption, tick %d/%d (%.0f ticks/s, ~%.0f s left)" % [
					e.key, tick, target, rate, (target - tick) / rate if rate > 0.0 else -1.0])
			return
		var data := LavaFlow.description_fields(e.packet, e.plan)
		data.merge(_state_fields(runtime, e.key))
		data.merge({"type": LavaFlow.TYPE, "uuid": uuid, "scenename": LavaFlow.SCENE, "parent_id": e.planet.uuid,
			"position": _vec(e.packet.frame.origin), "rotation": _vec(Vector3.ZERO)})
		if (registry_data.call(uuid) as Dictionary).is_empty():
			spawn_prop.call(data)
		else:
			update_prop.call(uuid, _flat(data), LavaFlow.TYPE)
		e.published = true
		e.next_digest_ms = now + DIGEST_MS
		e.next_checkpoint_ms = now + CHECKPOINT_MS
		print("[LAVA] %s: eruption published at tick %d (%d s, strength %.2f)" % [
			e.key, tick, int(e.plan.eruption_ticks) / 10, int(e.plan.strength_milli) / 1000.0])
		return
	if now >= e.next_checkpoint_ms:
		e.next_checkpoint_ms = now + CHECKPOINT_MS
		update_prop.call(uuid, _state_fields(runtime, e.key), LavaFlow.TYPE)
	elif now >= e.next_digest_ms:
		e.next_digest_ms = now + DIGEST_MS
		var digest: Array = runtime.latest_digest(e.key)
		if not digest.is_empty():
			update_prop.call(uuid, {"tick": digest[0], "digest": digest[1]}, LavaFlow.TYPE)


## Checkpoint, its tick and the latest digest of a patch: what a client starts from.
func _state_fields(runtime: Node3D, key: String) -> Dictionary:
	var checkpoint: PackedByteArray = runtime.patch_checkpoint(key)
	var fields := {"checkpoint": LavaFlow.encode_checkpoint(checkpoint), "checkpoint_tick": runtime.patch_tick(key),
		"schema": Core.SCHEMA}
	var digest: Array = runtime.latest_digest(key)
	if not digest.is_empty():
		fields.merge({"tick": digest[0], "digest": digest[1]})
	return fields


## Ends the eruption [param uuid]: its patch goes, and its prop too when [param delete] is set.
func _finish(uuid: String, delete: bool) -> void:
	var e: Dictionary = _eruptions.get(uuid, {})
	_eruptions.erase(uuid)
	var runtime := _runtime_of(e.get("planet"))
	if runtime != null and not str(e.get("key", "")).is_empty():
		runtime.remove_patch(e.key)
	if delete and e.get("published", false):
		delete_prop.call(uuid, LavaFlow.TYPE)
		print("[LAVA] %s: eruption over, deposit gone" % str(e.get("key", uuid)))


## Is the eruption of prop data [param data] over, its deposit gone for sure?
func _over(data: Dictionary) -> bool:
	var plan: Variant = data.get("plan")
	if not plan is Dictionary:
		return true
	return LavaFlow.ticks_at(plan, int(clock_ms.call())) > int(plan.get("eruption_ticks", 0)) + LavaFlow.STALE_AFTER_END_TICKS


## Planet uuid -> PackedVector3Array of the positions of [param players] (nodes) in their planet's frame.
static func viewer_positions(players: Array) -> Dictionary:
	var out := {}
	for p: Variant in players:
		if not is_instance_valid(p) or not p is Node3D:
			continue
		var planet := Planet.of(p as Node3D)
		if planet == null or planet.uuid.is_empty():
			continue
		# A packed array read from a Dictionary is a copy: append to a local one and store it back
		# (appending to out[uuid] in place left every planet with no player, 2026-11-09).
		var points: PackedVector3Array = out.get(planet.uuid, PackedVector3Array())
		points.append(planet.to_local((p as Node3D).global_position))
		out[planet.uuid] = points
	return out


## The volcanoes of [param planet] that can erupt: not dormant, with a crater large enough for a field.
func _volcanoes_of(planet: Planet) -> Array:
	if not _volcanoes.has(planet.uuid):
		var seen := {}
		var list: Array = []
		var data: PlanetData = planet.planet_data
		if data.volcano_fingerprint() != "" or data.debug_volcano_enabled:
			for ip in 12:
				for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
					var key := VolcanoFeatures.key_of(v)
					if not seen.has(key) and v.activity != "dormant" and v.rc >= 24.0:
						seen[key] = true
						list.append(v)
		_volcanoes[planet.uuid] = list
		print("[LAVA] %s: %d volcanoes can erupt" % [data.planet_name, list.size()])
	return _volcanoes[planet.uuid]


func _count_on(planet: Planet) -> int:
	var count := 0
	for e: Dictionary in _eruptions.values():
		if e.planet == planet:
			count += 1
	return count


func _runtime_of(planet: Variant) -> Node3D:
	if not is_instance_valid(planet) or not planet is Planet or (planet as Planet).planet_terrain == null:
		return null
	var runtime: Node3D = (planet as Planet).planet_terrain.lava_runtime
	if runtime != null:
		runtime.max_patches = max_patches
		runtime.catch_up_ticks = catch_up_ticks
	return runtime


static func _base_key(planet: Planet, v: VolcanoRelief.Volcano) -> String:
	return planet.planet_data.planet_name + "/" + VolcanoFeatures.key_of(v)


static func _any_within(points: PackedVector3Array, centre: Vector3, radius: float) -> bool:
	var r2 := radius * radius
	for p in points:
		if p.distance_squared_to(centre) < r2:
			return true
	return false


static func _vec(v: Vector3) -> Dictionary:
	return {"x": v.x, "y": v.y, "z": v.z}


## [param data] for update_prop, whose position/rotation are Vector3 (PropNet's shape), not {x, y, z}.
static func _flat(data: Dictionary) -> Dictionary:
	var out := data.duplicate()
	for field in ["position", "rotation"]:
		if out.get(field) is Dictionary:
			out[field] = Vector3(out[field].x, out[field].y, out[field].z)
	for field in ["uuid", "type"]:
		out.erase(field)
	return out


## `[lava]` keys of server.ini: activation_radius_m, max_patches, catch_up_ticks.
func _load_config() -> void:
	var ini := "server.ini"
	for a: String in OS.get_cmdline_args():
		if a.contains("srvini="):
			ini = a.split("=")[1]
	var cfg := ConfigFile.new()
	if cfg.load(ini) != OK:
		return
	activation_radius_m = maxf(1000.0, float(cfg.get_value("lava", "activation_radius_m", activation_radius_m)))
	max_patches = clampi(int(cfg.get_value("lava", "max_patches", max_patches)), 1, 64)
	catch_up_ticks = clampi(int(cfg.get_value("lava", "catch_up_ticks", catch_up_ticks)), 1, 600)
