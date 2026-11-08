extends Node
## LavaEruptions (the game server's lava authority) end to end on Tarsis III, without network: a dated
## 20 s eruption of a real volcano near a viewer is sampled, caught up, published as a LavaFlow prop; a
## replica installs it from the prop data alone and reaches the same state; the digests agree; the prop is
## deleted once the deposit is gone. Hooks stand for server.gd (registry, spawn, update, delete).
##
##   godot --headless --path . res://test/lava/test_eruption_server.tscn -- --volcano-view

const Runtime = preload("res://scenes/planet/lava/lava_planet_runtime.gd")
const START_S := 1800000000.0
const PLANET_UUID := "planet-test"
var failures := 0
var _clock := [0]
var _wall := [0]
var _registry := {}
var _spawned: Array = []
var _deleted: Array = []
var _updates := 0


func check(ok: bool, text: String) -> void:
	print("LAVA_SERVER ", "PASS " if ok else "FAIL ", text)
	if not ok:
		failures += 1


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.ensure_queries_loaded()
	data.warm_mountains()
	var volcano: VolcanoRelief.Volcano = null
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			if volcano == null and v.activity == "active" and v.rc >= 24.0:
				volcano = v
	if volcano == null:
		check(false, "Tarsis III has an active volcano with a crater")
		_quit()
		return
	var key := VolcanoFeatures.key_of(volcano)
	var profile := VolcanoActivityProfile.new()
	profile.random_enabled = false
	var event := VolcanoEvent.new()
	event.start_unix = START_S
	event.duration_s = 20.0
	event.strength = 1.0
	event.ramp_up_s = 2.0
	event.ramp_down_s = 2.0
	event.volcano_key = key
	profile.events.append(event)
	VolcanoActivityProfile._profiles[data.planet_name] = profile

	var planet := Planet.new()
	planet.uuid = PLANET_UUID
	planet.planet_data = data
	var terrain := PlanetTerrain.new()
	planet.planet_terrain = terrain
	var authority: Node3D = Runtime.new()
	authority.setup(data, true)
	authority.clock_ms = func() -> int: return _clock[0]
	add_child(authority)
	terrain.lava_runtime = authority
	var summit := volcano.c.normalized() * data.radius

	var lava := LavaEruptions.new()
	lava.planets = func() -> Dictionary: return {PLANET_UUID: planet}
	lava.viewers = func() -> Dictionary: return {PLANET_UUID: PackedVector3Array([summit])}
	lava.registry_data = func(uuid: String) -> Dictionary: return _registry.get(uuid, {})
	lava.spawn_prop = func(d: Dictionary) -> void:
		_registry[d.uuid] = d.duplicate(true)
		_spawned.append(d.uuid)
	lava.update_prop = func(uuid: String, props: Dictionary, _type: String) -> void:
		(_registry[uuid] as Dictionary).merge(props, true)
		_updates += 1
	lava.delete_prop = func(uuid: String, _type: String) -> void:
		_registry.erase(uuid)
		_deleted.append(uuid)
	lava.now_ms = func() -> int: return _wall[0]
	lava.clock_ms = func() -> int: return _clock[0]
	add_child(lava)
	lava._settled_at = 0

	# 10 s into the eruption: the server samples the crater, catches 100 ticks up, then publishes.
	_clock[0] = int(START_S * 1000.0) + 10000
	await _frames_until(func() -> bool: return not _spawned.is_empty(), 3000)
	var uuid := LavaFlow.uuid_for(data.planet_name, key)
	check(_spawned == [uuid], "the eruption is published once, under the volcano's stable uuid")
	if _spawned.is_empty():
		_quit()
		return
	var prop: Dictionary = _registry[uuid]
	check(prop.type == LavaFlow.TYPE and prop.parent_id == PLANET_UUID and prop.scenename == LavaFlow.SCENE,
		"prop type, scene and planet")
	check(int(prop.checkpoint_tick) >= 99, "published once caught up (tick %d)" % int(prop.checkpoint_tick))

	# The replica: the prop's data through JSON (what Horizon carries), nothing else.
	var wire: Dictionary = JSON.parse_string(JSON.stringify(prop))
	var description := LavaFlow.description_from(wire)
	check(not description.is_empty(), "the prop data describes the patch")
	var replica: Node3D = Runtime.new()
	replica.setup(data, true)
	replica.clock_ms = func() -> int: return _clock[0]
	add_child(replica)
	check(replica.install_patch(description), "the replica installs it")
	var patch_key := str(description.key)
	await _frames_until(_caught_up.bind([authority, replica], patch_key), 600)
	check(replica.patch_checkpoint(patch_key) == authority.patch_checkpoint(patch_key),
		"replica and authority hold the same state at tick %d" % replica.patch_tick(patch_key))

	# 15 more seconds: digests flow and agree.
	for n in 150:
		_clock[0] += 100
		_wall[0] += 100
		await get_tree().process_frame
	await _frames_until(_caught_up.bind([authority, replica], patch_key), 600)
	var digest: Array = authority.latest_digest(patch_key)
	check(not digest.is_empty(), "the authority records digests")
	if not digest.is_empty():
		replica.expect_digest(patch_key, digest[0], digest[1])
	check(not replica.is_diverged(patch_key), "the replica's digest matches")
	check(_updates > 0 and (_registry[uuid] as Dictionary).has("digest"), "digests are published")

	# Past the eruption and its ~302 s cleanup: the prop is deleted, the patch removed.
	_clock[0] += 420000
	await _frames_until(func() -> bool: return not _deleted.is_empty(), 4000)
	check(_deleted == [uuid], "the prop is deleted once the deposit is gone")
	check(not authority.patches.has(patch_key), "the authority's patch is removed")
	_quit()


## Advances the wall clock frame by frame until [param done] or [param frames] frames.
func _frames_until(done: Callable, frames: int) -> void:
	for n in frames:
		if done.call():
			return
		_wall[0] += 100
		await get_tree().process_frame


## True when every runtime of [param runtimes] has brought patch [param key] to the clock.
func _caught_up(runtimes: Array, key: String) -> bool:
	for runtime: Node3D in runtimes:
		if runtime.patch_tick(key) < runtime.target_tick(key):
			return false
	return true


func _quit() -> void:
	print("LAVA_SERVER failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)
