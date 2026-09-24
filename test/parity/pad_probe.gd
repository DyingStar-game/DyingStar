extends Node
## Throwaway bench: a terrain pad on the real pack, end to end.
##
## Finds the steepest readable spot on the body, drops a building-sized pad
## ACROSS a chunk border there — the one placement that can tear — and checks
## the four things the pad has to get right:
##
##   1. the platform is dead flat: every mesh vertex inside the footprint sits
##      at the same radius, and so does every collision vertex;
##   2. the mesh and the collision describe ONE surface (every collision
##      vertex is a mesh vertex, the railway probe's own test);
##   3. the two chunks sharing the border agree to the millimetre on every
##      vertex they share — a disagreement is the crack GradeRefine exists to
##      prevent, and a pad straddling a border is what provokes it;
##   4. carved_surface_dist(), which is what the server catches a falling
##      player with, returns the platform the player can SEE.
##
## Plus what the pad costs: the same chunk built with it and without it.
##
## Run with:
##   godot --headless --path . res://test/parity/pad_probe.tscn
## PAD_PROBE_PLANET=tarsis_3 to bench another body.
## Output: user://pad_probe.txt

static var OUT: FileAccess = null

## Half extents of the pad under test. The default is the cargo depot's own
## Ground box (20.8 x 96.9 m), so the probe reproduces the building the game
## actually has rather than a convenient square. PAD_PROBE_SIZE="hx,hy" to vary.
static var HX := 10.39
static var HY := 48.46
const APRON := 8.0

var NSIDE := 8192
var MPD := 0.0


func say(t: String) -> void:
	if OUT == null:
		OUT = FileAccess.open("user://pad_probe.txt", FileAccess.WRITE)
	OUT.store_line(t)
	OUT.flush()
	print(t)


func _ready() -> void:
	var planet := OS.get_environment("PAD_PROBE_PLANET")
	if planet == "":
		planet = "tarsis_3"
	var size_env := OS.get_environment("PAD_PROBE_SIZE")
	if size_env != "":
		var sp := size_env.split(",")
		HX = float(sp[0])
		HY = float(sp[1]) if sp.size() > 1 else float(sp[0])
	say("PROBE début, planète %s — pad %.1f x %.1f m" % [planet, 2.0 * HX, 2.0 * HY])
	var data := PlanetData.new()
	data.planet_name = planet
	data.chunk_export_depth = 8
	data.chunk_resolution = 32
	# The GAME's value, not a guess: tarsis_3.tscn does not override it, so the
	# PlanetData default (13 → n8192, 24.8 m vertices) is what the player sees.
	# Probing at 14 tested a grid twice as fine as anything the game builds,
	# which is how a pad that looks perfect here can still be wrong in game.
	var depth := OS.get_environment("PAD_PROBE_DEPTH")
	data.max_quadtree_depth = int(depth) if depth != "" else 13
	data.chunk_heightmaps_dir = "assets/qgis/export/%s_chunks" % planet
	data.chunk_heightmap_res = 32
	say("PROBE avant apply_chunk_manifest (depth %d)" % data.max_quadtree_depth)
	data.apply_chunk_manifest()
	say("PROBE après apply_chunk_manifest : radius=%.0f export_nside=%d depth=%d"
			% [data.radius, data.export_nside, data.max_quadtree_depth])
	NSIDE = 1 << data.max_quadtree_depth
	MPD = data.radius * PI / 180.0
	var pitch := data.terrain_vertex_spacing_m()
	say("PROBE planet %s: radius=%.0f export_nside=%d finest n%d pitch=%.2f m" % [
			planet, data.radius, data.export_nside, NSIDE, pitch])
	say("PROBE carve gate: %.2f m <= %.1f m → %s" % [pitch,
			PadSettings.CARVE_MAX_VTX_SPACING_M,
			str(GradeBed.carve_enabled(data, NSIDE, pitch))])
	say("PROBE pad %.0f × %.0f m + %.0f m apron, talus slope %.2f (cap %.0f m), reach %.0f m"
			% [2.0 * HX, 2.0 * HY, APRON, PadSettings.TALUS_SLOPE,
			PadSettings.TALUS_MAX_M,
			PadBed.reach_m({"hx": HX, "hy": HY, "apron_m": APRON})])
	# The elevation is streamed, not shipped: without a tile source every
	# direction reads the flat global fallback and the pad has nothing to level.
	# Already-cached tiles answer offline, so a scan finds a site without asking
	# the service for anything.
	data.remote_source = RemoteTileSource.for_planet(planet)
	say("PROBE tile source: %s" % ("aucune — le relief sera plat"
			if data.remote_source == null else data.remote_source.base_url))
	var side := HEALPix.pixel_side_length(NSIDE, data.radius)
	say("PROBE finest pixel side %.0f m — the pad's reach must stay under half of it (%.0f m)"
			% [side, 0.5 * side])

	var site := {}
	var forced := OS.get_environment("PAD_PROBE_LONLAT")
	if forced != "":
		# Exactly where a pad the game logged actually stands, so the probe
		# reproduces the chunk the player is looking at rather than a random one.
		var parts := forced.split(",")
		var ll := Vector2(float(parts[0]), float(parts[1]) if parts.size() > 1 else 0.0)
		var dir := HEALPix.lonlat2vec(ll.x, ll.y)
		var ipix := HEALPix.vec2pix_nest(NSIDE, dir)
		var nb := ipix
		for v in HEALPix.get_neighbors_nest(NSIDE, ipix).values():
			if int(v) >= 0:
				nb = int(v)
				break
		# The export tiles under the site and around it, fetched so the pad can
		# actually be levelled (the elevation is streamed, not shipped).
		var want := {HEALPix.vec2pix_nest(data.export_nside, dir): true}
		for v in HEALPix.get_neighbors_nest(data.export_nside,
				HEALPix.vec2pix_nest(data.export_nside, dir)).values():
			if int(v) >= 0:
				want[int(v)] = true
		for t: int in want:
			if not TileResidency.tile_available(data, t, data.export_nside) \
					and data.remote_source != null:
				data.remote_source.fetch_now(data.export_nside, t)
		site = {"ipix_a": ipix, "ipix_b": nb, "lonlat": ll, "span": 0.0}
		say("PROBE site imposé : lon %.5f lat %.5f → n%d p%d" % [ll.x, ll.y, NSIDE, ipix])
	else:
		site = _steepest_border_site(data)
	if site.is_empty():
		say("PROBE no readable site found — is the pack present?")
		say("FIN")
		get_tree().quit()
		return
	var ipix_a: int = site["ipix_a"]
	var ipix_b: int = site["ipix_b"]
	var lonlat: Vector2 = site["lonlat"]
	say("PROBE site lon %.5f lat %.5f — relief varies %.1f m over the footprint"
			% [lonlat.x, lonlat.y, float(site["span"])])
	say("PROBE straddles chunks %d and %d" % [ipix_a, ipix_b])

	var col_res: int = data.collision_col_res_for(NSIDE)
	# ── The same two chunks, first WITHOUT the pad: the cost baseline ──
	var bare_a := _build(data, ipix_a, col_res, "sans pad")

	# The heightmap samples tarsis_3 every ~198 m, so over a 40 m footprint the
	# relief is nearly flat wherever you land — PAD_PROBE_Z_OFF forces the cut
	# and fill a mountainside would give, to exercise a wide talus on demand.
	var z_off := float(OS.get_environment("PAD_PROBE_Z_OFF"))
	var rec := PadBed.record("probe_pad", lonlat.x, lonlat.y, 0.7, HX, HY, APRON, z_off)
	if z_off != 0.0:
		say("PROBE plateau décalé de %+.1f m (PAD_PROBE_Z_OFF)" % z_off)
	var dirty := data.register_pad(rec)
	if not data.has_pads():
		say("PROBE the pad was refused — an elevation tile under it is unreadable.")
		say("FIN")
		get_tree().quit()
		return
	rec = data._pads.get_rec("probe_pad")
	say("PROBE pad registered: platform at %.2f m, %d finest pixel(s) to rebuild"
			% [float(rec["z"]), dirty.size()])
	say("PROBE has_roads=%s — coupes de route calculées : %s"
			% [str(data.has_roads()), str(data._pad_road_excl)])
	for r: Dictionary in data.get_roads_for_chunk(NSIDE, ipix_a):
		var _cl: PackedVector2Array = r.get("centerline", PackedVector2Array())
		var _cum: PackedFloat64Array = r.get("_cum_lengths", PackedFloat64Array())
		say("PROBE   route fid=%d type=%s %d pts, along %.0f..%.0f, exclusions %s" % [
				int(r.get("feature_id", -1)), str(r.get("road_type", "?")), _cl.size(),
				_cum[0] if _cum.size() > 0 else -1.0,
				_cum[_cum.size() - 1] if _cum.size() > 0 else -1.0,
				str(data.road_exclusions_for_feature(int(r.get("feature_id", -1))))])
	say("PROBE collision_detail_nside now %d (export %d)"
			% [data.collision_detail_nside(), data.export_nside])

	var a := _build(data, ipix_a, col_res, "avec pad")
	var b := _build(data, ipix_b, col_res, "avec pad")
	say("PROBE coût du pad sur le chunk %d : mesh %+d ms, collision %+d ms" % [ipix_a,
			int(a["mesh_ms"]) - int(bare_a["mesh_ms"]),
			int(a["col_ms"]) - int(bare_a["col_ms"])])

	_flatness(data, rec, a)
	_flatness(data, rec, b)
	_seam(a, b)
	_gameplay(data, rec)
	_coarse(data, rec, ipix_a)
	say("FIN")
	get_tree().quit()


## A spot on a chunk border where the relief actually moves — the pad has
## nothing to prove on a plain. Random directions, keeping the steepest whose
## elevation tiles are all readable.
## A spot on a chunk border where the relief actually moves — the pad has
## nothing to prove on a plain. The elevation is streamed, so each candidate's
## export tiles are fetched (or read from the local cache) before it can be
## judged; that bounds the scan to a few dozen sites rather than thousands.
func _steepest_border_site(data: PlanetData) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260923
	var best := {}
	var best_span := 0.0
	var readable := 0
	var tried := 0
	var probe := {"lon": 0.0, "lat": 0.0, "yaw": 0.0, "hx": HX, "hy": HY,
			"apron_m": APRON, "z_off": 0.0, "uuid": "scan"}
	var t0 := Time.get_ticks_msec()
	while readable < 24 and tried < 120 and Time.get_ticks_msec() - t0 < 120000:
		tried += 1
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
		if dir.length_squared() < 1e-6:
			continue
		dir = dir.normalized()
		var ipix := HEALPix.vec2pix_nest(NSIDE, dir)
		# Halfway to a neighbour's centre is ON the border between the two: the
		# pad then belongs to both chunks, which is the case that can tear.
		var nb := -1
		for v in HEALPix.get_neighbors_nest(NSIDE, ipix).values():
			if int(v) >= 0:
				nb = int(v)
				break
		if nb < 0:
			continue
		var edge := (HEALPix.pix2vec_nest(NSIDE, ipix)
				+ HEALPix.pix2vec_nest(NSIDE, nb)).normalized()
		var ll := HEALPix.vec2lonlat(edge)
		probe["lon"] = ll.x
		probe["lat"] = ll.y
		var dirs := PadBed.sample_dirs(probe, MPD)
		var ok := true
		var wanted := {}
		for d in dirs:
			wanted[HEALPix.vec2pix_nest(data.export_nside, d)] = true
		for tile: int in wanted:
			if TileResidency.tile_available(data, tile, data.export_nside):
				continue
			if data.remote_source == null or not data.remote_source.fetch_now(data.export_nside, tile):
				ok = false
				break
		if not ok:
			continue
		readable += 1
		var lo := INF
		var hi := -INF
		for d in dirs:
			var h := data.sample_height_for_direction(d)
			lo = minf(lo, h)
			hi = maxf(hi, h)
		if hi - lo <= best_span:
			continue
		best_span = hi - lo
		best = {"ipix_a": ipix, "ipix_b": nb, "lonlat": ll, "span": hi - lo}
	say("PROBE scan : %d site(s) lisible(s) sur %d essais en %d ms" % [
			readable, tried, Time.get_ticks_msec() - t0])
	return best


## Build both geometries of one chunk and time them.
func _build(data: PlanetData, ipix: int, col_res: int, tag: String) -> Dictionary:
	var center: Vector3 = PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(NSIDE, ipix) * data.radius)
	var t0 := Time.get_ticks_usec()
	var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(
			data, NSIDE, ipix, data.chunk_resolution, center)
	var t1 := Time.get_ticks_usec()
	var shape: ConcavePolygonShape3D = PlanetChunk.generate_collision_shape_healpix(
			data, NSIDE, ipix, col_res)
	var t2 := Time.get_ticks_usec()
	var faces := shape.get_faces()
	var col_origin: Vector3 = center
	var all_mesh := PackedVector3Array()
	var mesh_pos := {}
	for si in mesh.get_surface_count():
		var sv: PackedVector3Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
		all_mesh.append_array(sv)
		for v in sv:
			var w: Vector3 = v + center
			mesh_pos["%.3f_%.3f_%.3f" % [w.x, w.y, w.z]] = true
	# Every collision vertex must be a vertex of the visual mesh: same origin,
	# same double math, so the float32 positions match to the millimetre.
	var missing := 0
	var worst := 0.0
	for f in faces:
		var w: Vector3 = f + col_origin
		if mesh_pos.has("%.3f_%.3f_%.3f" % [w.x, w.y, w.z]):
			continue
		var best := INF
		for v in all_mesh:
			best = minf(best, (v + center).distance_to(w))
		if best > 1e-3:
			missing += 1
			worst = maxf(worst, best)
	say("PROBE chunk %d (%s): mesh %d ms / %d verts / %d surfaces | collision %d ms / %d tris | vertices de collision absents du mesh : %d (pire %.4f m)"
			% [ipix, tag, (t1 - t0) / 1000, all_mesh.size(), mesh.get_surface_count(),
			(t2 - t1) / 1000, faces.size() / 3, missing, worst])
	var surfaces: Array = []
	var mats: Array = []
	for si in mesh.get_surface_count():
		surfaces.append(mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX])
		var m := mesh.surface_get_material(si)
		mats.append(_describe(m))
	say("PROBE   surfaces du chunk %d : %s" % [ipix, str(mats)])
	return {"ipix": ipix, "center": center, "verts": all_mesh, "faces": faces,
			"surfaces": surfaces, "mats": mats, "col_origin": col_origin,
			"mesh_ms": (t1 - t0) / 1000, "col_ms": (t2 - t1) / 1000}


## Is the platform actually flat? Every vertex well inside the footprint must
## stand at the pad's altitude — in the mesh AND in the collision.
func _flatness(data: PlanetData, rec: Dictionary, c: Dictionary) -> void:
	var want: float = data.radius + float(rec["z"])
	var inside := 0
	var worst := 0.0
	for v in (c["verts"] as PackedVector3Array):
		var w: Vector3 = v + (c["center"] as Vector3)
		if PadBed.sdf_m(rec, HEALPix.vec2lonlat(w.normalized()), MPD) > float(rec["apron_m"]) - 1.0:
			continue
		inside += 1
		worst = maxf(worst, absf(w.length() - want))
	var c_inside := 0
	var c_worst := 0.0
	for f in (c["faces"] as PackedVector3Array):
		var w: Vector3 = f + (c["col_origin"] as Vector3)
		if PadBed.sdf_m(rec, HEALPix.vec2lonlat(w.normalized()), MPD) > float(rec["apron_m"]) - 1.0:
			continue
		c_inside += 1
		c_worst = maxf(c_worst, absf(w.length() - want))
	say("PROBE   plateau chunk %d : %d sommet(s) de mesh dedans, écart max %.4f m | %d sommet(s) de collision, écart max %.4f m"
			% [int(c["ipix"]), inside, worst, c_inside, c_worst])
	# Per SURFACE, because an overlay (lava, meadow…) draws its quads on the
	# COARSE grid: GradeRefine deliberately skips them (planet_chunk.gd,
	# "_rw_skip := _quad_has_overlay"), so a pad under an overlay is only
	# applied to the 24.8 m grid vertices and the triangles between them slope
	# straight through the building's floor.
	for si in (c["surfaces"] as Array).size():
		var sv: PackedVector3Array = (c["surfaces"] as Array)[si]
		var n := 0
		var w := 0.0
		var n_foot := 0
		var deepest := 0.0
		for v in sv:
			var p3: Vector3 = v + (c["center"] as Vector3)
			var d := PadBed.sdf_m(rec, HEALPix.vec2lonlat(p3.normalized()), MPD)
			if d <= 0.0:
				n_foot += 1
				deepest = minf(deepest, d)
			if d > float(rec["apron_m"]) - 1.0:
				continue
			n += 1
			w = maxf(w, absf(p3.length() - want))
		if n > 0 or n_foot > 0:
			say("PROBE     surface %d (%s) : %d sommet(s) sous le bâtiment (le plus enfoncé à %.2f m du bord), %d dans emprise+tablier, écart max %.4f m"
					% [si, str((c["mats"] as Array)[si]), n_foot, deepest, n, w])


## Do the two chunks agree on every vertex they share? Keyed by DIRECTION, so
## a tear shows up as two radii at one point on the sphere.
func _seam(a: Dictionary, b: Dictionary) -> void:
	var bdir := {}
	for v in (b["verts"] as PackedVector3Array):
		var w: Vector3 = v + (b["center"] as Vector3)
		bdir[_dir_key(w)] = w.length()
	var shared := 0
	var mism := 0
	var worst := 0.0
	for v in (a["verts"] as PackedVector3Array):
		var w: Vector3 = v + (a["center"] as Vector3)
		var k := _dir_key(w)
		if not bdir.has(k):
			continue
		shared += 1
		var d := absf(w.length() - float(bdir[k]))
		if d > 1e-3:
			mism += 1
			worst = maxf(worst, d)
	say("PROBE   couture %d↔%d : %d sommet(s) partagé(s), %d en désaccord (pire %.4f m)"
			% [int(a["ipix"]), int(b["ipix"]), shared, mism, worst])


func _dir_key(w: Vector3) -> String:
	var ll := HEALPix.vec2lonlat(w.normalized())
	return "%.7f_%.7f" % [ll.x, ll.y]


## What the server catches a falling player with must be the platform the
## player sees — that is the whole point of carved_surface_dist. Checked well
## inside the apron, where the answer is exactly the platform; the sample grid
## is a bounding box, so its four corners sit out in the talus and are not.
func _gameplay(data: PlanetData, rec: Dictionary) -> void:
	var want: float = data.radius + float(rec["z"])
	var worst := 0.0
	var tested := 0
	var lo := INF
	var hi := -INF
	for d in PadBed.sample_dirs(rec, MPD):
		var r := data.crack_aware_surface_dist(d)
		lo = minf(lo, r)
		hi = maxf(hi, r)
		if PadBed.sdf_m(rec, HEALPix.vec2lonlat(d), MPD) > float(rec["apron_m"]) - 1.0:
			continue
		tested += 1
		worst = maxf(worst, absf(data.carved_surface_dist(d) - want))
	say("PROBE   carved_surface_dist sur %d point(s) du plateau : écart max %.4f m (relief brut : %.1f m de dénivelé)"
			% [tested, worst, hi - lo])
	# Walk due east from the pad centre, out past the toe: the ground must ramp
	# at the promised slope and then hand the natural relief back untouched.
	var half: float = maxf(float(rec["hx"]), float(rec["hy"]))
	var toe: float = half + float(rec["apron_m"]) + PadBed.talus_cap(rec)
	var worst_slope := 0.0
	var prev := INF
	var step := 0.25
	var e := 0.0
	while e <= toe + 20.0:
		var dir := _east_of(rec, e)
		var h := data.carved_surface_dist(dir) - data.radius
		if prev != INF:
			var d := PadBed.sdf_m(rec, HEALPix.vec2lonlat(dir), MPD)
			if d > 0.0 and d <= PadBed.talus_cap(rec) + float(rec["apron_m"]):
				worst_slope = maxf(worst_slope, absf(h - prev) / step)
		prev = h
		e += step
	var out_dir := _east_of(rec, toe + 10.0)
	say("PROBE   talus mesuré %.1f m — pente max relevée sur le sol construit %.3f (promesse %.2f)"
			% [PadBed.talus_cap(rec), worst_slope, PadSettings.TALUS_SLOPE])
	say("PROBE   10 m au-delà du pied : carved %.3f m vs relief brut %.3f m (doit être identique)"
			% [data.carved_surface_dist(out_dir) - data.radius,
			data.crack_aware_surface_dist(out_dir) - data.radius])


func _east_of(rec: Dictionary, east_m: float) -> Vector3:
	var lat0: float = float(rec["lat"])
	var ls := maxf(cos(deg_to_rad(lat0)), 1e-6)
	return HEALPix.lonlat2vec(float(rec["lon"]) + east_m / (ls * MPD), lat0)


## What the pad looks like on the LODs that are NOT the finest grid.
##
## GradeBed.carve_enabled only opens on hp_nside == 1 << max_quadtree_depth, so
## every coarser chunk gets the "shave" instead (GradeBed.make_coarse_ctx): the
## ground inside the footprint and its apron is pulled to the platform and
## blended out over one and a half vertex pitches. The question this answers is
## whether that is enough to keep the ground out of the building at the LOD the
## player actually sees from a few dozen metres away — a 20 x 97 m footprint on
## a 25 m grid has very few vertices to be pulled by.
func _coarse(data: PlanetData, rec: Dictionary, ipix: int) -> void:
	var want: float = data.radius + float(rec["z"])
	var ns := NSIDE
	var ip := ipix
	for step in 3:
		ns >>= 1
		ip >>= 2
		if ns < 4:
			return
		var pitch := HEALPix.pixel_side_length(ns, data.radius) / float(data.chunk_resolution)
		var fine := GradeBed.carve_enabled(data, ns, pitch)
		var center: Vector3 = PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(ns, ip) * data.radius)
		var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(
				data, ns, ip, data.chunk_resolution, center)
		# What matters is not the vertices INSIDE the footprint but whether any
		# vertex the pad's band reaches ends up ABOVE the platform: that is the
		# one that pulls a triangle up through the building's floor.
		var band := 1.5 * pitch
		var near := 0
		var worst_above := -INF
		for si in mesh.get_surface_count():
			for v in (mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				var w: Vector3 = v + center
				if PadBed.sdf_m(rec, HEALPix.vec2lonlat(w.normalized()), MPD) \
						> float(rec["apron_m"]) + band:
					continue
				near += 1
				worst_above = maxf(worst_above, w.length() - want)
		if near == 0:
			say("PROBE   LOD n%d (pas %.0f m, carve=%s) : aucun sommet à portée du pad"
					% [ns, pitch, str(fine)])
			continue
		say("PROBE   LOD n%d (pas %.0f m, carve=%s) : %d sommet(s) à portée, le plus haut %+.2f m au-dessus du plateau %s"
				% [ns, pitch, str(fine), near, worst_above,
				"← PERCE LE BÂTIMENT" if worst_above > 0.01 else "(rien ne perce)"])


## What a surface's material actually IS — class, resource, albedo texture —
## because "an unnamed ORMMaterial3D" identifies nothing and guessing which
## overlay it belongs to is how a diagnosis goes wrong.
func _describe(m: Material) -> String:
	if m == null:
		return "null"
	var out := m.get_class()
	if m.resource_path != "":
		out += " " + m.resource_path.get_file()
	if m.resource_name != "":
		out += " name=" + m.resource_name
	if m is BaseMaterial3D:
		var tex := (m as BaseMaterial3D).albedo_texture
		if tex != null and tex.resource_path != "":
			out += " albedo=" + tex.resource_path.get_file()
		out += " albedo_color=%s" % str((m as BaseMaterial3D).albedo_color)
	return out
