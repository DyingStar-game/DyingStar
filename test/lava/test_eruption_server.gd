extends Node
## LavaEruptions (the game server's lava authority) end to end on Tarsis III, without network: a dated
## 20 s eruption of a real volcano near a viewer is sampled, caught up, published as a LavaFlow prop (grid +
## summary, no checkpoint); a client replica draws it from the prop data alone, covering exactly the
## authority's cells; summaries keep flowing; the prop is deleted once the deposit is gone. Hooks stand for
## server.gd (registry, spawn, update, delete).
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
	if "--remote-tiles" in OS.get_cmdline_user_args():
		# As a game server: elevation from the tile service, POIs spared by the cracks (PlanetTerrain.initialize).
		data.remote_source = RemoteTileSource.for_planet(data.planet_name)
		data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(data.planet_name))
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

	# In the tree, so a player node under it goes through LavaEruptions.viewer_positions as on the server.
	# Added before its data: Planet._ready then prepares nothing.
	var planet := Planet.new()
	planet.uuid = PLANET_UUID
	add_child(planet)
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
	var player := Node3D.new()
	player.name = "Player"
	planet.add_child(player)
	player.position = summit
	lava.viewers = func() -> Dictionary: return LavaEruptions.viewer_positions([player])
	var seen: Dictionary = LavaEruptions.viewer_positions([player])
	check(seen.has(PLANET_UUID) and (seen[PLANET_UUID] as PackedVector3Array).size() == 1,
		"viewer_positions finds the player on its planet")
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
	var first_tick := int(prop.summary_tick)  # prop is the registry's dictionary: later updates change it
	check(first_tick >= 99, "published once caught up (tick %d)" % first_tick)
	check(not prop.has("checkpoint") and str(prop.summary).length() < 8000 and str(prop.grid).length() < 60000,
		"no checkpoint on the wire: summary %d B, grid %d B (base64)" % [str(prop.summary).length(),
			str(prop.grid).length()])

	# The replica: the prop's data through JSON (what Horizon carries), nothing else. It draws, never simulates.
	var wire: Dictionary = JSON.parse_string(JSON.stringify(prop))
	var description := LavaFlow.description_from(wire)
	check(not description.is_empty(), "the prop data describes the patch")
	var replica: Node3D = Runtime.new()
	replica.setup(data, false)
	replica.clock_ms = func() -> int: return _clock[0]
	add_child(replica)
	var patch_key := str(description.key)
	check(replica.install_summary(description, description.grid), "the replica installs it")
	replica.apply_summary(patch_key, LavaFlow.decode_bytes(wire.summary))
	await _frames_until(func() -> bool: return _shown(replica, patch_key) > 0, 600)
	var shown: Dictionary = replica.patches[patch_key]
	check(_shown(replica, patch_key) > 0 and not shown.surface.has_prepared(),
		"the client uploads the textures its worker rebuilt (%d)" % _shown(replica, patch_key))
	check(shown.smoke != null and shown.smoke.edge_count > 0, "the client's smoke edges come from the summary (%d)" % (
		shown.smoke.edge_count if shown.smoke else 0))

	# 15 more seconds: summaries flow, the replica follows. A fresh one, at the authority's own tick, is compared.
	for n in 150:
		_clock[0] += 100
		_wall[0] += 100
		await get_tree().process_frame
	await _frames_until(_caught_up.bind([authority], patch_key), 600)
	check(_updates > 0 and int((_registry[uuid] as Dictionary).summary_tick) > first_tick,
		"summaries are published (tick %d)" % int((_registry[uuid] as Dictionary).summary_tick))
	authority.request_summary(patch_key)
	_clock[0] += 100
	await _frames_until(_fresh_summary.bind(authority, patch_key), 600)
	var latest: Array = authority.latest_summary(patch_key)
	var before := int(shown.surface.publications)
	replica.apply_summary(patch_key, latest[1])
	await _frames_until(func() -> bool: return int(shown.surface.publications) > before, 600)
	var truth = authority.patches[patch_key].solver
	var view = shown.solver
	var mask_diff := 0
	var depth_err := 0.0
	var depth_sum := 0.0
	for i: int in truth.volume_q.size():
		var wet: bool = truth.volume_q[i] > 0
		if wet != (view.volume_q[i] > 0):
			mask_diff += 1
		if wet:
			depth_err += absf(truth.volume_q[i] * 1000.0 / truth.areas_q[i] - view.depth[i])
			depth_sum += truth.volume_q[i] * 1000.0 / truth.areas_q[i]
	check(int(latest[0]) == truth.tick and mask_diff == 0, "the replica's lava covers exactly the authority's cells")
	check(depth_err <= depth_sum * 0.1, "the replica's depths are within 10 %% of the authority's (%.1f %%)" % (
		100.0 * depth_err / maxf(depth_sum, 0.001)))

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


## True once [param runtime] has encoded a summary at its patch's own tick, the clock reached.
func _fresh_summary(runtime: Node3D, key: String) -> bool:
	var latest: Array = runtime.latest_summary(key)
	return not latest.is_empty() and int(latest[0]) == runtime.patch_tick(key) \
		and runtime.patch_tick(key) >= runtime.target_tick(key)


## Textures a replica's summary patch has uploaded (0 before the first summary is drawn).
func _shown(runtime: Node3D, key: String) -> int:
	var entry: Dictionary = runtime.patches.get(key, {})
	return int(entry.surface.publications) if entry.get("surface") != null else 0


func _quit() -> void:
	print("LAVA_SERVER failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)
