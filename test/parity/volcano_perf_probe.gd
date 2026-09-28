extends Node
## Throwaway bench: what the volcanoes, lava flows and fumaroles cost a chunk.
##
## Loads the real planet (its scene's PlanetData: cracks, corundum, pack), warms
## it like PlanetTerrain.initialize does — timing each step — then builds the
## mesh and the collision of chunks on the features, with the generate_mesh
## phase profile (PropNet.prof_on), next to a plain chunk of the same body.
##
## Run with:
##   godot --headless --path . res://test/parity/volcano_perf_probe.tscn
## VOLC_PROBE_PLANET=tarsis_3 (default) — VOLC_PROBE_REPS=2
## Output: user://volcano_perf_probe.txt

static var OUT: FileAccess = null
var _data: PlanetData
var _nside := 8192
var _res := 32
var _col_res := 32


func say(t: String) -> void:
	if OUT == null:
		OUT = FileAccess.open("user://volcano_perf_probe.txt", FileAccess.WRITE)
	OUT.store_line(t)
	OUT.flush()
	print(t)


func _ms(t0: int) -> float:
	return float(Time.get_ticks_usec() - t0) / 1000.0


func _ready() -> void:
	var planet := OS.get_environment("VOLC_PROBE_PLANET")
	if planet == "":
		planet = "tarsis_3"
	var reps_env := OS.get_environment("VOLC_PROBE_REPS")
	var reps := int(reps_env) if reps_env != "" else 2
	var scene: PackedScene = load("res://scenes/systems/tarsis/%s.tscn" % planet)
	var root: Node = scene.instantiate()
	_data = root.get("planet_data")
	say("PROBE %s — chunk_resolution %d, depth %d" % [planet, _data.chunk_resolution,
			_data.max_quadtree_depth])
	var t := Time.get_ticks_usec()
	_data.apply_chunk_manifest()
	_data.remote_source = RemoteTileSource.for_planet(planet)
	_nside = 1 << _data.max_quadtree_depth
	_res = _data.chunk_resolution
	_col_res = _data.collision_col_res_for(_nside)
	say("PROBE manifest %.0f ms — radius %.0f export n%d finest n%d res %d col_res %d source %s"
			% [_ms(t), _data.radius, _data.export_nside, _nside, _res, _col_res,
			"none" if _data.remote_source == null else _data.remote_source.base_url])

	# VOLC_PROBE_TILT=1: the pack's volcanoes rebuilt with the rim tilted toward
	# the flow leaving their lake (what a re-export with lake_breach writes).
	if OS.get_environment("VOLC_PROBE_TILT") == "1":
		var flows: Array = []
		for lv in _data.get_whole_lava():
			flows.append(lv["centerline"])
		var recs: Array = []
		var seen_t := {}
		for ip in 12:
			for vv in _data.get_chunk_volcanoes(1, ip):
				var v: VolcanoRelief.Volcano = vv
				if seen_t.has(VolcanoFeatures.key_of(v)):
					continue
				seen_t[VolcanoFeatures.key_of(v)] = true
				var rec := {"type": v.type, "name": v.name, "coverage": "point", "lon": v.lon,
						"lat": v.lat, "cx": v.c.x, "cy": v.c.y, "cz": v.c.z,
						"base_diameter_m": 2.0 * v.rb, "height_m": v.h,
						"crater_diameter_m": 2.0 * v.rc, "crater_depth_m": v.dc,
						"floor_frac": v.floor_frac, "flank_exponent": v.e, "roughness": v.rough,
						"gullies": v.gullies, "irregularity": v.irr,
						"has_lava_lake": 1 if v.lake else 0, "lake_fill_m": v.fill,
						"activity": v.activity, "seed": v.seed, "impurity_intensity": v.impurity}
				var br := VolcanoRelief.lake_breach(rec, flows, _data.radius)
				rec.merge(br, true)
				say("PROBE tilt '%s': %s" % [v.name, str(br)])
				recs.append(rec)
		_data.set_mountain_overrides([], [], recs)

	# ── Warm-up, the PlanetTerrain.initialize order ──
	for step in ["ensure_queries_loaded", "warm_mountains", "warm_fumaroles", "has_lava",
			"get_bridge_spans", "warm_bridge_plans", "warm_grade_profiles"]:
		t = Time.get_ticks_usec()
		_data.call(step)
		say("WARM %-24s %8.0f ms" % [step, _ms(t)])
	# Every tile under the starved lines, fetched with no budget: the probe
	# must measure the flow WITH its profile (the game gets there eventually).
	t = Time.get_ticks_usec()
	var n_fetch := 0
	for entry in _data._grade_starved:
		for tile: int in (entry["tiles"] as Dictionary):
			if not TileResidency.tile_available(_data, tile, _data.export_nside) \
					and _data.remote_source != null:
				if _data.remote_source.fetch_now(_data.export_nside, tile):
					n_fetch += 1
	say("WARM %-24s %8.0f ms (%d tiles)" % ["fetch starved tiles", _ms(t), n_fetch])
	t = Time.get_ticks_usec()
	var born := _data.flush_grade_profiles(10)
	say("WARM %-24s %8.0f ms (%d born)" % ["flush_grade_profiles", _ms(t), born.size()])
	say("PROBE incomplete %s" % _data.grade_profiles_incomplete())
	say("PROBE has_mountains %s has_lava %s has_fumaroles %s profiled %s"
			% [_data.has_mountains(), _data.has_lava(), _data.has_fumaroles(),
			_data.has_profiled_lines()])

	# ── The features ──
	var sites: Array = []   # [label, dir]
	var seen := {}
	for ip in 12:
		for v in _data.get_chunk_volcanoes(1, ip):
			var vol: VolcanoRelief.Volcano = v
			var key := VolcanoFeatures.key_of(vol)
			if seen.has(key):
				continue
			seen[key] = true
			say("FEAT volcano '%s' %s lon %.4f lat %.4f rb %.0f h %.0f rc %.0f lake %s shore %.0f"
					% [vol.name, vol.type, vol.lon, vol.lat, vol.rb, vol.h, vol.rc, vol.lake,
					VolcanoRelief.lake_shore_radius(vol)])
			sites.append(["volcan '%s' sommet" % vol.name, vol.c])
			sites.append(["volcan '%s' flanc" % vol.name, _offset(vol.c, 0.5 * vol.rb)])
			sites.append(["témoin (2.5 rb de '%s')" % vol.name, _offset(vol.c, 2.5 * vol.rb)])
	for lv in _data.get_whole_lava():
		var cl: PackedVector2Array = lv["centerline"]
		var cum: PackedFloat64Array = lv["_cum_lengths"]
		var prof := _data.get_grade_profile(int(lv["feature_id"]))
		var n_gorge := 0
		var deepest := 0.0
		for seg in prof.get("segments", []):
			if int(seg["kind"]) == GradeSettings.Kind.GORGE:
				n_gorge += 1
				deepest = maxf(deepest, float(seg["max_depth"]))
		say("FEAT lava '%s' %s %.0f m, %d pts, profile %s, %d gorge(s) deepest %.0f m, uphill %.0f m"
				% [str(lv.get("name", "")), str(lv.get("state", "")), cum[cum.size() - 1],
				cl.size(), "ok" if not prof.is_empty() else "MISSING", n_gorge, deepest,
				float(prof.get("uphill_m", 0.0))])
		for f in [0.1, 0.5, 0.9]:
			var a: float = cum[0] + f * (cum[cum.size() - 1] - cum[0])
			sites.append(["lave '%s' @%d%%" % [str(lv.get("name", "")), int(f * 100.0)],
					GradeGeom.dir_at(cl, cum, a)])
	var fum_seen := {}
	for ip in 12:
		for fv in _data.fumaroles_for_chunk(1, ip):
			var fm: FumaroleField.Field = fv
			if fm.is_vent or fum_seen.has(fm.index):
				continue
			fum_seen[fm.index] = true
			var c := fm.bbox.get_center() if not fm.full else Vector2.ZERO
			say("FEAT fumarole field #%d gas %s density %.1f" % [fm.index, fm.gas, fm.density])
			sites.append(["fumerolles #%d" % fm.index, HEALPix.lonlat2vec(c.x, c.y)])
	if sites.is_empty():
		say("PROBE no feature on %s" % planet)
		say("FIN")
		get_tree().quit()
		return

	# ── The tiles under the sites (streamed) ──
	t = Time.get_ticks_usec()
	var fetched := 0
	for s in sites:
		var e := HEALPix.vec2pix_nest(_data.export_nside, s[1])
		var want := [e]
		for nb in HEALPix.get_neighbors_nest(_data.export_nside, e).values():
			if int(nb) >= 0:
				want.append(int(nb))
		for w in want:
			if not TileResidency.tile_available(_data, w, _data.export_nside) \
					and _data.remote_source != null:
				if _data.remote_source.fetch_now(_data.export_nside, w):
					fetched += 1
	say("PROBE tiles fetched %d in %.0f ms" % [fetched, _ms(t)])

	# ── Unit costs of a refined sub-vertex, on the summit chunk ──
	var sip := HEALPix.vec2pix_nest(_nside, sites[0][1])
	var pitch := HEALPix.pixel_side_length(_nside, _data.radius) / float(_res)
	var ctx := GradeBed.make_ctx(_data, _nside, sip, pitch)
	var frame := _data.make_tile_frame()
	_data.prepare_mountain_frame(frame, _nside, sip)
	CrackCarve.prepare_frame(_data, frame, _nside, sip)
	var pieces: Array = ctx.get("pieces", [])
	var nseg := 0
	for pc in pieces:
		nseg += (pc["centerline"] as PackedVector2Array).size() - 1
	var cdir := HEALPix.pix2vec_nest(_nside, sip)
	var pts := PackedVector3Array()
	for i in 4000:
		pts.append((cdir + Vector3(fmod(i * 0.61803, 1.0) - 0.5, fmod(i * 0.41421, 1.0) - 0.5,
				fmod(i * 0.73205, 1.0) - 0.5) * 1.2e-4).normalized())
	var acc := 0.0
	t = Time.get_ticks_usec()
	for d in pts:
		acc += _data.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null,
				_nside, frame, pitch / 8.0, CrackCarve.NONE)
	var us_sample := float(Time.get_ticks_usec() - t) / 4000.0
	t = Time.get_ticks_usec()
	for d in pts:
		acc += GradeBed.apply(100.0, HEALPix.vec2lonlat(d), ctx)
	var us_apply := float(Time.get_ticks_usec() - t) / 4000.0
	t = Time.get_ticks_usec()
	for d in pts:
		acc += float(GradeGeom.nearest_on_pieces(pieces, HEALPix.vec2lonlat(d),
				_data.radius * PI / 180.0)["along"])
	var us_near := float(Time.get_ticks_usec() - t) / 4000.0
	say("UNIT summit chunk: %d piece(s), %d segment(s) — sample %.1f µs, GradeBed.apply %.1f µs (nearest_on_pieces %.1f µs) [%s]"
			% [pieces.size(), nseg, us_sample, us_apply, us_near, "ok" if acc != 0.0 else "0"])

	# ── Build ──
	# Timings with the profile OFF: prof_on forces the GDScript sampler (the
	# C# TileFrameNative path is skipped under the rig), so the phase split is
	# taken on a separate, last build.
	for s in sites:
		var ipix := HEALPix.vec2pix_nest(_nside, s[1])
		for lod_shift in [0, 2]:
			var ns: int = _nside >> int(lod_shift)
			var ip: int = ipix >> (2 * int(lod_shift))
			var real_mesh := 0.0
			var real_col := 0.0
			for r in reps + 1:
				var center := PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(ns, ip) * _data.radius)
				var prof := {}
				PropNet.prof_on = r == reps
				t = Time.get_ticks_usec()
				var mesh := PlanetChunk.generate_mesh_healpix(_data, ns, ip, _res, center, prof)
				var mesh_ms := _ms(t)
				var col_ms := -1.0
				if lod_shift == 0:
					t = Time.get_ticks_usec()
					PlanetChunk.generate_collision_shape_healpix(_data, ns, ip, _col_res)
					col_ms = _ms(t)
				if r == reps - 1:
					real_mesh = mesh_ms
					real_col = col_ms
				if r < reps:
					continue
				var phases := PackedStringArray()
				var keys := prof.keys()
				keys.sort()
				for k in keys:
					if k in ["total", "tile"]:
						continue
					var v: float = float(prof[k]) / 1000.0
					if v >= 1.0:
						phases.append("%s %.0f" % [k, v])
				say("CHUNK %-34s n%-5d mesh %5.0f ms  col %5.0f ms (C#) | profil GDScript %5.0f ms: %s"
						% [s[0], ns, real_mesh, real_col, mesh_ms, ", ".join(phases)])
	PropNet.prof_on = false
	root.free()
	say("FIN")
	get_tree().quit()


## The direction [param metres] east of [param c] on the surface.
func _offset(c: Vector3, metres: float) -> Vector3:
	var ll := HEALPix.vec2lonlat(c)
	var mpd := _data.radius * PI / 180.0
	return HEALPix.lonlat2vec(ll.x + metres / mpd / maxf(cos(deg_to_rad(ll.y)), 0.05), ll.y)
