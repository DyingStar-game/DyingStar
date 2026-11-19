extends Node
## Publication check: every tile of a planet's local terrainmodifier.pack, read back through
## RemoteModifierPack from a tile service, must be byte-identical; a sample of unpublished tiles must
## come back ABSENT, and grade_profiles.pack (body <planet>.lines) must arrive whole. Prints PROBE lines.
##
##   python3 tools/planettech/publish/publish_tiles.py <chunks>/terrainmodifier.pack --out dist --compress
##   python3 tools/planettech/publish/publish_tiles.py <chunks>/grade_profiles.pack --out dist
##   (cd dist && python3 -m http.server 8765)
##   godot --headless --path . res://test/parity/modifier_stream_probe.tscn -- \
##       --tile-stream=http://127.0.0.1:8765 --planet=tarsis_8

var PLANET := "tarsis_8"


func _wait_state(pack: RemoteModifierPack, ns: int, ip: int) -> int:
	var st := pack.tile_state(ns, ip)
	var t0 := Time.get_ticks_msec()
	while st == ModifierPack.TILE_PENDING and Time.get_ticks_msec() - t0 < 15000:
		OS.delay_msec(5)
		st = pack.tile_state(ns, ip)
	return st


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--planet="):
			PLANET = a.split("=", true, 1)[1]
	var local := ModifierPack.new()
	if not local.open("res://assets/qgis/export/%s_chunks/terrainmodifier.pack" % PLANET):
		print("PROBE FAIL no local pack")
		get_tree().quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var remote := RemoteModifierPack.shared_for(PLANET)
	if remote == null:
		print("PROBE FAIL no remote pack")
		get_tree().quit(1)
		return
	print("PROBE opened in %d ms, levels %s" % [Time.get_ticks_msec() - t0, str(remote.get_levels())])
	var checked := 0
	var bad := 0
	var absent_ok := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for ns: int in local.get_levels():
		for ip: int in local.get_tile_ipix(ns):
			if _wait_state(remote, ns, ip) != ModifierPack.TILE_READY:
				bad += 1
				print("PROBE MISSING n%d/%d" % [ns, ip])
				continue
			if remote.read_tile(ns, ip) != local.read_tile(ns, ip):
				bad += 1
				print("PROBE DIFF n%d/%d" % [ns, ip])
				continue
			checked += 1
		for _k in range(20):
			var ip := rng.randi_range(0, 12 * ns * ns - 1)
			if local.has_tile(ns, ip):
				continue
			var st := _wait_state(remote, ns, ip)
			if st == ModifierPack.TILE_ABSENT:
				absent_ok += 1
			else:
				bad += 1
				print("PROBE NOT-ABSENT n%d/%d state=%d" % [ns, ip, st])
	var grade := RemoteTileSource.fetch_file(PLANET + ".lines", "grade_profiles.pack")
	var grade_ok := grade != "" and FileAccess.get_file_as_bytes(grade) == FileAccess.get_file_as_bytes(
			"res://assets/qgis/export/%s_chunks/grade_profiles.pack" % PLANET)
	print("PROBE checked=%d absent_ok=%d bad=%d grade_extra=%s total_ms=%d"
			% [checked, absent_ok, bad, grade_ok, Time.get_ticks_msec() - t0])
	# The game's own path: a PlanetData hooked to the service reads the STREAMED pack even though a
	# terrainmodifier.pack sits in its chunk directory.
	var pd := PlanetData.new()
	pd.planet_name = PLANET
	pd.chunk_heightmaps_dir = "res://assets/qgis/export/%s_chunks" % PLANET
	pd.apply_chunk_manifest()
	pd.connect_tile_service()
	var used = pd.get_modifier_pack()
	var streamed: bool = used != null and used.is_streamed()
	print("PROBE planet_data_streamed=%s (local pack present=%s)" % [streamed,
			FileAccess.file_exists(pd.chunk_heightmaps_dir + "/terrainmodifier.pack")])
	remote.source.stop()
	get_tree().quit(0 if bad == 0 and grade_ok and streamed else 1)
