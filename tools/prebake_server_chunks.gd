extends MainLoop
## Headless prebake tool: generates ConcavePolygonShape3D collision shapes
## for every export-level HEALPix chunk and saves them to the disk cache.
##
## Usage (from the project root):
##   godot --headless --script res://tools/prebake_server_chunks.gd
##
## Reads the planet list from server.ini [prebake] planets="p1,p2,...".
## For each planet, loads the chunk_manifest.json, generates all collision
## shapes at the export nside, and stores them via ChunkDiskCache.

const CONFIG_PATH := "res://server.ini"
## Number of parallel WorkerThreadPool tasks for collision generation.
## Uses all available CPU cores.
var _parallel_tasks: int = maxi(OS.get_processor_count(), 1)


func _initialize() -> void:
	print("[Prebake] Starting server chunk prebake …")

	var planets := _read_planet_list()
	if planets.is_empty():
		printerr("[Prebake] No planets configured in server.ini [prebake] section.")
		return

	print("[Prebake] Planets to prebake: %s" % [", ".join(planets)])

	for planet_name in planets:
		_prebake_planet(planet_name)

	print("[Prebake] All planets done.")


func _process(_delta: float) -> bool:
	# Return true to quit on next iteration (we do everything in _initialize).
	return true


# ------------------------------------------------------------------
# Read server.ini
# ------------------------------------------------------------------

func _read_planet_list() -> PackedStringArray:
	var cfg := ConfigFile.new()
	var err := cfg.load(CONFIG_PATH)
	if err != OK:
		printerr("[Prebake] Failed to load %s: %d" % [CONFIG_PATH, err])
		return PackedStringArray()

	var raw: String = cfg.get_value("prebake", "planets", "")
	if raw.is_empty():
		return PackedStringArray()

	var result := PackedStringArray()
	for part in raw.split(","):
		var trimmed := part.strip_edges()
		if not trimmed.is_empty():
			result.append(trimmed)
	return result


# ------------------------------------------------------------------
# Prebake one planet
# ------------------------------------------------------------------

func _prebake_planet(planet_name: String) -> void:
	print("[Prebake] === %s ===" % planet_name)

	# ── Load planet JSON to populate PlanetData ──────────────────
	var pd := PlanetData.new()
	pd.planet_name = planet_name
	pd.set_server_mode(true)
	if not pd.load_from_planet_json():
		printerr("[Prebake] Could not load planet JSON for '%s' — skipping." % planet_name)
		return

	# ── Early skip: if the planet cache folder already exists with
	# a matching version hash, skip the entire planet to save time. ─
	var early_version := "%s_%d_%.0f_%.0f_%.1f_v7" % [
		pd.planet_name, pd.export_nside, pd.radius,
		pd.max_height, pd.height_offset]
	var early_planet_dir := ChunkDiskCache.SERVER_COLLISION_BASE_DIR + planet_name + "/"
	var early_version_path := early_planet_dir + "version.txt"
	if FileAccess.file_exists(early_version_path):
		var vf := FileAccess.open(early_version_path, FileAccess.READ)
		if vf:
			var stored := vf.get_as_text().strip_edges()
			vf.close()
			if stored == early_version:
				# Verify at least one collision file exists (not just an empty dir).
				var nside_check: int = pd.export_nside
				var expected_chunks: int = 12 * nside_check * nside_check
				var sample_key := "hp_n%d_p0" % nside_check
				var sample_path := early_planet_dir + sample_key + "_lod0_col.res"
				if FileAccess.file_exists(sample_path):
					print("[Prebake] %s: cache folder valid (version match + chunks present) — skipping." % planet_name)
					return

	# Ensure runtime paths derived from planet_name are correct.
	pd.biomes_geojson = "assets/qgis/export/%s/biomes.json" % planet_name
	pd.ensure_queries_loaded()

	# ── Read manifest to detect crater-free planets ──────────────
	# Read from the .planetpack; if the pack is unavailable the planet
	# cannot be prebaked (recipes live inside the pack).
	var total_craters := -1
	var pack = pd._get_pack()
	if pack != null and pack.has_entry("manifest.json"):
		var mf_data = pack.read_entry_json("manifest.json")
		if mf_data is Dictionary:
			total_craters = int(mf_data.get("total_craters", -1))
	if total_craters == 0:
		pd.skip_neighbor_crater_merge = true
		print("[Prebake] %s: 0 craters — skipping neighbor recipe merge." % planet_name)

	var nside: int = pd.export_nside
	var total_pixels: int = 12 * nside * nside

	print("[Prebake] %s: radius=%.0f  export_nside=%d  total_chunks=%d" % [
		planet_name, pd.radius, nside, total_pixels])

	# ── Init disk cache with same version hash as planet_terrain.gd ─
	# MUST stay in sync with the _cache_version literal in
	# scenes/planet/planet_terrain.gd::initialize().  When the runtime version
	# bumps, bump this one too — otherwise prebaked shapes are written under a
	# version the server never reads, defeating the whole prebake step.
	var cache_version := "%s_%d_%.0f_%.0f_%.1f_v13" % [
		pd.planet_name, pd.export_nside, pd.radius,
		pd.max_height, pd.height_offset]
	var cache := ChunkDiskCache.new(planet_name, cache_version, ChunkDiskCache.SERVER_COLLISION_BASE_DIR)
	var col_res := maxi(pd._recipe_resolution, pd.chunk_resolution)

	# ── Recipe heightmap resolution for collision prebake ─────────
	# MUST equal the runtime default (PlanetData._recipe_resolution = 256) so
	# that prebaked collision sampled at this resolution matches the runtime
	# bilinear sampling exactly.  Lowering it here (a previous optimisation)
	# made the prebaked shapes diverge from the lazy-built ones, causing the
	# server collision to sit several metres off the visible mesh.
	print("[Prebake] %s: using runtime _recipe_resolution=%d  col_res=%d" % [
		planet_name, pd._recipe_resolution, col_res])

	# ── Count already-cached chunks to skip redundant work ───────
	var cached_count := 0
	var to_generate: Array[int] = []  # ipix values needing generation
	for ipix in total_pixels:
		var key := "hp_n%d_p%d" % [nside, ipix]
		if cache.has_collision(key, 0):
			cached_count += 1
		else:
			to_generate.append(ipix)

	print("[Prebake] %s: %d already cached, %d to generate (col_res=%d)" % [
		planet_name, cached_count, to_generate.size(), col_res])

	if to_generate.is_empty():
		print("[Prebake] %s: all chunks already cached — nothing to do." % planet_name)
		return

	# ── Pre-load recipes in parallel via WorkerThreadPool ────────
	# _load_recipe_heightmap is thread-safe (file I/O + static
	# ChunkRecipeGenerator.generate_heightmap).  Results are stored
	# back into the PlanetData cache from the main thread after each
	# batch completes.
	var recipes_loaded := 0
	var recipes_failed := 0
	var recipe_batch_start := 0
	var next_recipe_log := 1000
	var recipe_phase_start := Time.get_ticks_usec()
	var total_wait_us: int = 0
	var total_store_us: int = 0
	var batch_count := 0

	while recipe_batch_start < to_generate.size():
		var batch_t0 := Time.get_ticks_usec()
		var recipe_batch_end := mini(recipe_batch_start + _parallel_tasks, to_generate.size())
		var recipe_tasks: Array[Dictionary] = []

		for i in range(recipe_batch_start, recipe_batch_end):
			var ipix: int = to_generate[i]
			var export_key := "hp_n%d_p%d" % [nside, ipix]
			if pd.is_chunk_cached(export_key):
				recipes_loaded += 1
				continue
			var entry := {"key": export_key, "task_id": -1, "result": [] as Array}
			var task_id := WorkerThreadPool.add_task(
				func():
					entry["result"] = pd._load_recipe_heightmap(ipix, export_key)
			)
			entry["task_id"] = task_id
			recipe_tasks.append(entry)

		# Wait for batch completion and store results from main thread.
		var wait_t0 := Time.get_ticks_usec()
		for rt in recipe_tasks:
			if rt.task_id >= 0:
				WorkerThreadPool.wait_for_task_completion(rt.task_id)
		total_wait_us += Time.get_ticks_usec() - wait_t0

		var store_t0 := Time.get_ticks_usec()
		for rt in recipe_tasks:
			var result: Array = rt.result
			if result.is_empty() or result[0] == null:
				push_warning("[Prebake] %s: recipe for %s returned null — skipping chunk." % [
					planet_name, rt.key])
				recipes_failed += 1
				continue
			var img: Image = result[0] as Image
			if img == null:
				recipes_failed += 1
				continue
			var craters: Array = result[1] if result.size() > 1 else []
			var populate_zones: Array = result[2] if result.size() > 2 else []
			var linear_feats: Array = result[3] if result.size() > 3 else []
			var radial_feats: Array = result[4] if result.size() > 4 else []
			pd.store_chunk_image(rt.key, img, craters,
				populate_zones, linear_feats, radial_feats)
			recipes_loaded += 1
		total_store_us += Time.get_ticks_usec() - store_t0

		batch_count += 1
		recipe_batch_start = recipe_batch_end

		# Log every 10 batches or every 1000 recipes
		if batch_count % 10 == 0 or recipes_loaded >= next_recipe_log:
			var elapsed_s := (Time.get_ticks_usec() - recipe_phase_start) / 1_000_000.0
			var avg_ms := (Time.get_ticks_usec() - recipe_phase_start) / 1000.0 / maxi(recipes_loaded, 1)
			print("[Prebake] %s: loaded %d / %d recipes  elapsed=%.1fs  avg=%.1fms/recipe  wait=%.1fs  store=%.1fs" % [
				planet_name, recipes_loaded, to_generate.size(), elapsed_s, avg_ms,
				total_wait_us / 1_000_000.0, total_store_us / 1_000_000.0])
			if recipes_loaded >= next_recipe_log:
				next_recipe_log += 1000

	var recipe_phase_s := (Time.get_ticks_usec() - recipe_phase_start) / 1_000_000.0
	print("[Prebake] %s: %d recipes loaded (%d failed) in %.1fs  (wait=%.1fs  store=%.1fs)" % [
		planet_name, recipes_loaded, recipes_failed, recipe_phase_s,
		total_wait_us / 1_000_000.0, total_store_us / 1_000_000.0])

	# ── Generate collision shapes (parallel via WorkerThreadPool) ─
	var generated := 0
	var failed := 0
	var batch_start := 0

	while batch_start < to_generate.size():
		var batch_end := mini(batch_start + _parallel_tasks, to_generate.size())
		var tasks: Array[Dictionary] = []

		for i in range(batch_start, batch_end):
			var ipix: int = to_generate[i]
			var export_key := "hp_n%d_p%d" % [nside, ipix]
			# Skip if recipe was unavailable.
			if not pd.is_chunk_cached(export_key):
				failed += 1
				continue
			var entry := {"ipix": ipix, "task_id": -1, "shape": null as Variant}
			var task_id := WorkerThreadPool.add_task(
				func():
					entry["shape"] = PlanetChunk.generate_collision_shape_healpix(
						pd, nside, ipix, col_res)
			)
			entry["task_id"] = task_id
			tasks.append(entry)

		# Wait for batch completion and save results.
		for t in tasks:
			if t.task_id >= 0:
				WorkerThreadPool.wait_for_task_completion(t.task_id)
			var shape: ConcavePolygonShape3D = t.get("shape") as ConcavePolygonShape3D
			if shape:
				var key := "hp_n%d_p%d" % [nside, t.ipix]
				cache.save_collision(key, 0, shape)
				generated += 1
			else:
				failed += 1

		batch_start = batch_end
		if generated % 500 == 0 and generated > 0:
			print("[Prebake] %s: generated %d / %d  (failed=%d) …" % [
				planet_name, generated, to_generate.size(), failed])

	print("[Prebake] %s: DONE — generated=%d  cached_before=%d  failed=%d  total=%d" % [
		planet_name, generated, cached_count, failed, total_pixels])
