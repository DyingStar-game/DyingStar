extends Node
const Builder = preload("res://scenes/planet/lava/lava_planet_patch.gd")
const Runtime = preload("res://scenes/planet/lava/lava_planet_runtime.gd")
var failures := 0


func check(ok: bool, text: String) -> void:
	print("LAVA_PLANET ", "PASS " if ok else "FAIL ", text)
	if not ok:
		failures += 1


func _ready() -> void:
	var data: PlanetData = SystemScenes.root_properties("res://scenes/systems/tarsis/tarsis_3.tscn").planet_data.duplicate(true)
	data.apply_chunk_manifest()
	data.ensure_queries_loaded()
	data.warm_mountains()
	data.has_lava()
	data.warm_grade_profiles()
	check_native_equivalence()
	var cache_rules = preload("res://scenes/planet/lava/lava_terrain_cache.gd")
	var wanted := data.grade_bake_key()
	var legacy := wanted.replace(LavaSettings.RUNTIME_POLICY, "")
	check(cache_rules.legacy_matches(legacy, wanted) and not cache_rules.legacy_matches(legacy + "changed", wanted),
		"cache compatibility accepts only the explicit lava policy migration")
	check(not data._grade_baked.is_empty(), "unaffected infrastructure profiles survive the removal of QGIS spillways")
	var excluded: Dictionary = data._lava_cache_exclusions().lines
	var safe := true
	for fid: int in excluded:
		safe = safe and not data._grade_baked.has(fid)
	check(safe, "infrastructure profiles near changed volcanoes are invalidated")
	check(not data.has_lava() and data.get_whole_lava().is_empty()
		and data.get_chunk_lava(1, 0).is_empty() and data.lava_fingerprint().is_empty(),
		"QGIS lava ribbons, carving and grading are disabled")
	var authority := Runtime.new()
	authority.setup(data, true)
	add_child(authority)
	var replica := Runtime.new()
	replica.setup(data, true) # A headless replica loads no renderer/particles.
	add_child(replica)
	var seen := {}
	var packet := {}
	for ip in 12:
		for volcano: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			var key := VolcanoFeatures.key_of(volcano)
			if seen.has(key) or volcano.activity != "active" or volcano.rc <= 0.0:
				continue
			seen[key] = true
			check(volcano.tilt == 0.0, "QGIS spillway tilt is removed from decoded volcano")
			var candidate := Builder.build(data, volcano) if packet.is_empty() else {}
			print("LAVA_SITE ", key, " crater=", volcano.rc, " tilt=", volcano.tilt,
				" result=", "ok" if not candidate.is_empty() else "not sampled")
			if packet.is_empty() and not candidate.is_empty():
				packet = candidate
	check(not packet.is_empty(), "a shipped active Tarsis III volcano yields a real-terrain patch")
	if not packet.is_empty():
		check(authority.install_patch(packet) and replica.install_patch(packet), "canonical terrain installed on both peers")
		var key: String = packet.key
		var server = authority.patches[key].solver
		var client = replica.patches[key].solver
		check(server.injected_q == 0 and server.wet_indices.is_empty(), "no initial deposit exists before the eruption")
		check(packet.source_radius_from_summit_m == 0.0 and packet.source_radius_mm < packet.crater_radius_m * 1000.0,
			"source is inside the crater, with all 360 degrees represented")
		check(server.gravity_milli == 7770 and client.gravity_milli == 7770, "shared gravity is Tarsis III 7.77 m/s²")
		check(authority.get_child_count() == 0 and replica.get_child_count() == 0, "headless runtimes instantiate no visual nodes")
		var same := true
		for tick in range(1, 301):
			var commands: PackedInt64Array = server.disc_commands(packet.source_x_mm, packet.source_z_mm,
				packet.source_radius_mm, packet.source_rate_q if tick < 200 else 0, packet.source_temperature_t)
			same = authority.advance_patch(key, tick, commands) and same
			same = replica.advance_patch(key, tick, commands) and same
			if tick % 50 == 0:
				same = server.state_digest() == client.state_digest() and same
		check(same, "300 ticks on actual terrain remain bit-identical, including emission shutdown")
		if "--lava-long-test" in OS.get_cmdline_user_args():
			await long_eruption(authority, replica, packet)
			server = authority.patches[key].solver
			client = replica.patches[key].solver
		var before: String = server.state_digest()
		check(not authority.advance_patch(key, server.tick + 2, PackedInt64Array()) and server.state_digest() == before, "missing tick is rejected by the game runtime")
		var frame: Transform3D = packet.frame
		check(frame.basis.y.dot(frame.origin.normalized()) > 0.99999, "patch up follows the planet's spherical up")
		check_terrain_overlay_lifecycle(data, packet)
		var other := packet.duplicate(true)
		other.key = key + "/2"
		var third := packet.duplicate(true)
		third.key = key + "/3"
		check(authority.install_patch(other) and not authority.install_patch(third), "authority enforces the two-patch budget")
		authority.remove_patch(key)
		check(authority.install_patch(third) and authority.patches.size() == 2, "retiring a patch makes its slot reusable")
		authority.clear_patches()
		replica.clear_patches()
		check(authority.patches.is_empty() and replica.patches.is_empty(), "unload clears both physics registries")
		var metadata := packet.duplicate()
		metadata.erase("checkpoint")
		metadata.frame = str(metadata.frame)
		var report := {"site": metadata, "tick": server.tick, "sha256": server.state_digest(),
			"failures": failures, "gravity_milli": server.gravity_milli}
		FileAccess.open("user://lava-planet-integration.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	authority.queue_free()
	replica.queue_free()
	print("LAVA_PLANET_RESULT failures=", failures)
	get_tree().quit(0 if failures == 0 else 1)


func check_terrain_overlay_lifecycle(data: PlanetData, packet: Dictionary) -> void:
	var visual := Runtime.new()
	visual.setup(data, false)
	add_child(visual)
	visual.install_patch(packet)
	var solver = visual.patches[packet.key].solver
	var source: int = (packet.source_z_mm / solver.cell_mm) * solver.width + packet.source_x_mm / solver.cell_mm
	var ground := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(16, 1, 16)
	ground.mesh = box
	ground.transform = packet.frame * Transform3D(Basis.IDENTITY, Vector3(
		packet.source_x_mm / 1000.0, solver.bed[source] + 10000.0, packet.source_z_mm / 1000.0))
	visual.add_child(ground)
	visual.register_terrain_mesh(ground)
	check(ground.material_overlay != null, "coarse terrain above the physical height range still receives lava coverage")
	var far_ground := MeshInstance3D.new()
	far_ground.mesh = box
	far_ground.transform = packet.frame * Transform3D(Basis.IDENTITY, Vector3(50000, 0, 50000))
	visual.add_child(far_ground)
	visual.register_terrain_mesh(far_ground)
	check(far_ground.material_overlay == null and visual._overlay_targets.size() == 1,
		"terrain coverage is limited to the horizontal field footprint")
	visual.remove_patch(packet.key)
	check(ground.material_overlay == null and visual._overlay_targets.is_empty(),
		"retiring lava removes its terrain pass and weak mesh registry")
	var tiny = load("res://scenes/planet/lava/lava_fixed_core.gd").new()
	tiny.configure_q(3, 3, 1000, PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0]))
	tiny.cleanup_enabled = true
	tiny.inject_q(PackedInt64Array([4, 10000, 8000]))
	tiny.tick = 4000
	tiny.fade_ticks_q[4] = 1
	tiny.fade_start_q[4] = 10000
	var ending := packet.duplicate()
	ending.checkpoint = tiny.checkpoint()
	visual.install_patch(ending)
	visual.advance_patch(packet.key, 4001, PackedInt64Array())
	check(visual.patches[packet.key].retired and visual.get_child_count() == 2,
		"completed cleanup despawns lava mesh, textures and smoke holder")
	# Only the two synthetic terrain fixtures remain.
	visual.advance_patch(packet.key, 4002, PackedInt64Array([4, 20000, 12000]))
	check(not visual.patches[packet.key].retired and visual.patches[packet.key].holder != null,
		"a fresh eruption recreates visuals after complete despawn")
	visual.queue_free()


func check_native_equivalence() -> void:
	var core = load("res://scenes/planet/lava/lava_fixed_core.gd")
	var native = core.new()
	var edges := PackedInt64Array()
	for r in 13: edges.append(r * 1000)
	var bed := PackedInt64Array()
	for r in 12:
		for x in 32: bed.append(0 if r < 4 else 2000 - (r - 4) * 500 + x * 2)
	native.configure_polar_q(32, edges, bed)
	native.cleanup_enabled = true
	native.crater_rows = 4
	native.eruption_head_mm = 64000
	native.rim_heights_q.resize(32); native.rim_heights_q.fill(2000)
	native.viscosity_q = 400
	check(native.has_native_backend(), "compiled integer accelerator matches the model version")
	core.use_native = false
	var reference = core.new()
	reference.restore(native.checkpoint())
	core.use_native = true
	var same := true
	for tick in range(1, 5101):
		var emitting := tick < 100 or (tick >= 1950 and tick < 2000)
		var commands: PackedInt64Array = native.disc_commands(0, 0, 3900, 6400, 12000) if emitting else PackedInt64Array()
		same = native.advance_tick(tick, commands) and reference.advance_tick(tick, commands) and same
		if tick % 10 == 0: same = native.checkpoint() == reference.checkpoint() and same
	check(same and native.cleanup_complete(), "native and reference states stay byte-identical through pressure, overflow, reheating and complete cleanup")


func long_eruption(authority: Node3D, replica: Node3D, packet: Dictionary) -> void:
	authority.install_patch(packet)
	replica.install_patch(packet)
	var key: String = packet.key
	var server = authority.patches[key].solver
	var client = replica.patches[key].solver
	var same := true
	var expected_q := 0
	var timings: Array[float] = []
	var sides := PackedByteArray(); sides.resize(server.width); sides.fill(0)
	var max_distance := 0
	var peak_cells := 0
	var peak_volume := 0
	var black_before_fade := false
	var started := Time.get_ticks_usec()
	for tick in range(1, 12301):
		var strength := VolcanoEvent.emission_envelope(tick / 10.0, 900.0, 2.0, 10.0, true)
		var commands: PackedInt64Array = Builder.source_commands(server, packet, tick, strength)
		for p in range(1, commands.size(), 3): expected_q += commands[p]
		var before := Time.get_ticks_usec()
		same = authority.advance_patch(key, tick, commands) and same
		same = replica.advance_patch(key, tick, commands) and same
		timings.append((Time.get_ticks_usec() - before) / 1000.0)
		if tick % 300 == 0:
			same = server.checkpoint() == client.checkpoint() and same
			var volume := 0
			for i: int in server.wet_indices:
				volume += server.volume_q[i]
				var row: int = i / server.width
				if row > packet.crater_rows and server.volume_q[i] >= 1000:
					sides[i % server.width] = 1
					max_distance = maxi(max_distance, server.radial_edges_mm[row + 1])
			peak_volume = maxi(peak_volume, volume)
			peak_cells = maxi(peak_cells, server.wet_indices.size())
			check(volume + server.removed_q + server.escaped_q == expected_q, "mass ledger at tick %d" % tick)
		if tick == 10100:
			black_before_fade = true
			for i: int in server.wet_indices:
				black_before_fade = black_before_fade and server.AMBIENT_T + server.energy_q[i] / server.volume_q[i] <= server.BLACK_T
		if tick % 300 == 0:
			print("LAVA_LONG tick=", tick, " wet=", server.wet_indices.size(), " removed_m3=", server.removed_q / 1000.0)
			await get_tree().process_frame
	check(same, "15min eruption and complete cleanup remain bit-identical")
	var count := 0
	for seen in sides: count += seen
	check(count == server.width, "lava overflows and travels down every angular sector")
	check(black_before_fade, "lava is black before its disappearance phase")
	check(server.cleanup_complete() and server.removed_q == server.injected_q and server.wet_indices.is_empty(), "all lava despawns with a complete removal ledger")
	var resume = load("res://scenes/planet/lava/lava_fixed_core.gd").new()
	check(resume.restore(server.checkpoint()) and resume.checkpoint() == server.checkpoint(), "a cleaned-up field can be restored without recreating a deposit")
	timings.sort()
	var report := {"simulated_seconds": 1230, "eruption_seconds": 900, "ticks_per_peer": 12300,
		"native_backend": server.has_native_backend() and client.has_native_backend(),
		"bit_identical": same, "grid": [server.width, server.height], "geometry": "polar",
		"injected_m3": server.injected_q / 1000.0, "removed_m3": server.removed_q / 1000.0,
		"remaining_m3": 0 if server.wet_indices.is_empty() else -1, "sides_reached": count,
		"peak_wet_cells": peak_cells, "peak_active_m3": peak_volume / 1000.0,
		"front_distance_m": max_distance / 1000.0, "black_before_fade": black_before_fade,
		"both_peers_tick_ms_p50": timings[timings.size() / 2],
		"both_peers_tick_ms_p95": timings[int(timings.size() * 0.95)],
		"wall_seconds": (Time.get_ticks_usec() - started) / 1000000.0,
		"sha256": server.state_digest(), "failures": failures}
	FileAccess.open("user://lava-long-eruption.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("LAVA_LONG_RESULT ", JSON.stringify(report))
