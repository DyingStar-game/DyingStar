extends Node
## Probe: the notch of a vehicle lift on the real tarsis_3 ground, end to end.
##
## Takes a lift from horizonserver's startup_items.json (NOTCH_PROBE_NAME, default "Vehicle Lift
## Cliff 3"), states its notch the way the server does for a sleeping lift
## (VehicleLift.notch_record_from_data), registers it, rebuilds every finest chunk it touches and
## checks:
##   1. every collision vertex is a mesh vertex (the ground walked is the ground seen);
##   2. inside the box (3 m from its walls) the mesh and carved_surface_dist stand at the floor;
##   3. 20 m outside it, carved_surface_dist is the untouched relief;
##   4. two chunks sharing a border put each shared vertex at the same height (no seam);
##   5. how far the wall leans: the widest run, across the wall, between floor and natural ground.
##
## Run with:
##   godot --headless --path . res://test/parity/notch_probe.tscn
## Output: user://notch_probe.txt

const PLANET_SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
const STARTUP_ITEMS := "../horizonserver/ds_genericprops/startup_items.json"

static var _out: FileAccess = null
var data: PlanetData
var mpd := 0.0


func say(t: String) -> void:
	if _out == null:
		_out = FileAccess.open("user://notch_probe.txt", FileAccess.WRITE)
	_out.store_line(t)
	_out.flush()
	print(t)


func _ready() -> void:
	var want := OS.get_environment("NOTCH_PROBE_NAME")
	if want == "":
		want = "Vehicle Lift Cliff 3"
	var items = JSON.parse_string(FileAccess.get_file_as_string(
			ProjectSettings.globalize_path("res://").path_join(STARTUP_ITEMS)))
	var item: Dictionary = {}
	for it in items:
		if str(it["object_data"].get("name", "")) == want:
			item = it
	if item.is_empty():
		say("PROBE pas de '%s' dans %s" % [want, STARTUP_ITEMS])
		get_tree().quit()
		return
	var body: Node = (load(PLANET_SCENE) as PackedScene).instantiate()
	data = body.get("planet_data")
	data.apply_chunk_manifest()
	data.remote_source = RemoteTileSource.for_planet(data.planet_name)
	data.warm_mountains()
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(data.planet_name))
	mpd = data.radius * PI / 180.0

	var od: Dictionary = item["object_data"]
	var p: Dictionary = od["position"]
	var r: Dictionary = od["rotation"]
	var rel := Transform3D(Basis.from_euler(Vector3(r["x"], r["y"], r["z"])), Vector3(p["x"], p["y"], p["z"]))
	var rec := VehicleLift.notch_record_from_data(data, rel, od, "notch|prop:" + str(item["object_uuid"]))
	say("PROBE %s : entaille %.0f × %.0f m, fond à %.1f m, portée %.0f m (limite %.0f m)" % [want,
			2.0 * float(rec["hx"]), 2.0 * float(rec["hy"]), float(rec["z"]), PadBed.reach_m(rec),
			0.5 * HEALPix.pixel_side_length(1 << data.max_quadtree_depth, data.radius)])
	var nside: int = 1 << data.max_quadtree_depth
	# The same chunks WITHOUT the notch first: what the mesh/collision check reports there is the
	# ground's own, not the notch's.
	for ipix: int in data.pad_pixels(rec):
		_build(ipix, nside, rec, "sans entaille")
	var dirty: Dictionary = data.register_pad(rec)
	say("PROBE %d chunk(s) fins touchés (n%d), pas %.1f m" % [dirty.size(), nside, data.terrain_vertex_spacing_m()])

	var chunks: Array = []
	for ipix: int in dirty:
		chunks.append(_build(ipix, nside, rec, "avec entaille"))
	_seams(chunks)
	_gameplay(rec)
	_wall(rec)
	body.free()
	get_tree().quit()


func _build(ipix: int, nside: int, rec: Dictionary, tag: String) -> Dictionary:
	var center: Vector3 = PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(nside, ipix) * data.radius)
	var t0 := Time.get_ticks_usec()
	var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, nside, ipix, data.chunk_resolution, center)
	var t1 := Time.get_ticks_usec()
	var col_res: int = data.collision_col_res_for(nside) if data.has_method("collision_col_res_for") \
			else data.chunk_resolution
	var shape: ConcavePolygonShape3D = PlanetChunk.generate_collision_shape_healpix(data, nside, ipix, col_res)
	var t2 := Time.get_ticks_usec()
	var verts := PackedVector3Array()
	var keys := {}
	for si in mesh.get_surface_count():
		for v: Vector3 in mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
			var w := v + center
			verts.append(w)
			keys["%.3f_%.3f_%.3f" % [w.x, w.y, w.z]] = true
	var faces := shape.get_faces()
	var missing := 0
	for f in faces:
		var w: Vector3 = f + center
		if not keys.has("%.3f_%.3f_%.3f" % [w.x, w.y, w.z]):
			missing += 1
	# Floor: mesh vertices well inside the box.
	var inside := 0
	var off_floor := 0
	var worst := 0.0
	for w in verts:
		var ll := HEALPix.vec2lonlat(w.normalized())
		if PadBed.sdf_m(rec, ll, mpd) > -3.0:
			continue
		inside += 1
		var dz: float = w.length() - data.radius - float(rec["z"])  # > 0: rock left above the floor
		if dz > 0.05:
			off_floor += 1
			worst = maxf(worst, dz)
	say(("PROBE chunk %d (%s) : mesh %d ms / %d sommets, collision %d ms / %d tris, collision hors "
			+ "mesh : %d | dans l'entaille : %d sommets, %d AU-DESSUS du fond (pire %.2f m)") % [
			ipix, tag, (t1 - t0) / 1000, verts.size(), (t2 - t1) / 1000, faces.size() / 3, missing,
			inside, off_floor, worst])
	return {"ipix": ipix, "verts": verts}


## Same direction in two chunks → same height. Keyed on the direction rounded far below a sub-cell.
func _seams(chunks: Array) -> void:
	var by_dir := {}
	for c: Dictionary in chunks:
		for w: Vector3 in c["verts"]:
			var d := w.normalized()
			var k := "%.8f_%.8f_%.8f" % [d.x, d.y, d.z]
			if not by_dir.has(k):
				by_dir[k] = {}
			(by_dir[k] as Dictionary)[c["ipix"]] = w.length()
	var shared := 0
	var torn := 0
	var worst := 0.0
	for k in by_dir:
		var per: Dictionary = by_dir[k]
		if per.size() < 2:
			continue
		shared += 1
		var lo := INF
		var hi := -INF
		for ip in per:
			lo = minf(lo, float(per[ip]))
			hi = maxf(hi, float(per[ip]))
		if hi - lo > 0.01:
			torn += 1
			worst = maxf(worst, hi - lo)
	say("PROBE coutures : %d sommet(s) partagés entre chunks, %d en désaccord (pire %.3f m)" % [shared, torn, worst])


func _gameplay(rec: Dictionary) -> void:
	var z: float = float(rec["z"])
	var worst := 0.0
	var n := 0
	var out_worst := 0.0
	for i in 21:
		for j in 41:
			var x := lerpf(-float(rec["hx"]) + 3.0, float(rec["hx"]) - 3.0, i / 20.0)
			var y := lerpf(-float(rec["hy"]) + 3.0, float(rec["hy"]) - 3.0, j / 40.0)
			var d := _dir(rec, x, y)
			worst = maxf(worst, data.carved_surface_dist(d) - data.radius - z)  # rock above the floor
			n += 1
	for y in [-float(rec["hy"]) - 20.0, 0.0, float(rec["hy"]) + 20.0]:
		for x in [-float(rec["hx"]) - 20.0, float(rec["hx"]) + 20.0]:
			var d := _dir(rec, x, y)
			out_worst = maxf(out_worst, absf(data.carved_surface_dist(d) - data.crack_aware_surface_dist(d)))
	say(("PROBE carved_surface_dist : %d points dans l'entaille, roche au-dessus du fond %.4f m ; "
			+ "à 20 m dehors, écart au relief brut max %.4f m") % [n, worst, out_worst])


## Walk across the wall at mid-length, from 30 m inside to 30 m outside: where does the built ground
## leave the floor, and where does it reach the natural relief?
func _wall(rec: Dictionary) -> void:
	var z: float = float(rec["z"])
	var hx: float = float(rec["hx"])
	var leave := NAN
	var reach := NAN
	var x := 0.0
	while x <= hx + 30.0:
		var d := _dir(rec, x, 0.0)
		var h := data.carved_surface_dist(d) - data.radius
		var raw := data.crack_aware_surface_dist(d) - data.radius
		if is_nan(leave) and h > z + 0.05:
			leave = x
		if is_nan(reach) and absf(h - raw) < 0.05 and raw > z + 1.0:
			reach = x
		x += 0.25
	say("PROBE paroi (carved_surface_dist, mi-longueur) : quitte le fond à %+.2f m du bord, rejoint le relief à %+.2f m"
			% [leave - hx, reach - hx])


## The direction (x, y) metres from the notch centre in its own frame (x across, y along).
func _dir(rec: Dictionary, x: float, y: float) -> Vector3:
	var lat0: float = float(rec["lat"])
	var ls := maxf(cos(deg_to_rad(lat0)), 1e-6)
	var yaw: float = float(rec["yaw"])
	var e := x * cos(yaw) - y * sin(yaw)
	var nn := x * sin(yaw) + y * cos(yaw)
	return HEALPix.lonlat2vec(float(rec["lon"]) + e / (ls * mpd), lat0 + nn / mpd)
