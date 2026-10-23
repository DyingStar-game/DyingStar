extends Node
## Bench: does the ground a profiled line refines stay carved INSIDE a canyon?
## The real tarsis_3 pack, at the finest LOD, the chunk under the site and its
## eight neighbours: every vertex of the base surface is compared with the
## crack network at its direction. A vertex standing more than FILL_M above
## the raw relief + the crack's offset, where the crack is at least DEEP_M
## deep and RIM_M inside its edge, is ground filled into the canyon — the cutting floor GradeRefine laid
## under a railway bridge while its sub-vertices were read without the crack
## (tarsis_3, 39.519 W 24.738 N).
##
## Run with:
##   godot --headless --path . res://test/parity/canyon_fill_probe.tscn
## CANYON_PROBE_LONLAT="lon,lat" for another site (lon < 0 = west),
## CANYON_PROBE_VERBOSE=1 to list the first filled vertices of each chunk,
## CANYON_PROBE_IDENTITY=1 to rebuild each chunk without the C# sampler and compare (bit for bit).
## The chunk COLLISION too: a triangle wholly inside the canyon and half its depth tall is an
## invisible wall — the bed skirts that read the canyon floor while the visual ones read the
## plateau (tarsis_3, 39.561 W 24.842 N).
## Output: user://canyon_fill_probe.txt, last line "PASS" or "FAIL: …".

const PLANET := "tarsis_3"
const SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
## Only where the analytic crack is at least this deep (m): far from the
## rim, where the snap moves nothing.
const DEEP_M := 20.0
## A vertex closer than this (m) to the analytic edge is on the wall, not in the canyon.
const RIM_M := 1.0
## A vertex this far above the carved ground (m) is filled.
const FILL_M := 2.0

var _out: FileAccess = null


func say(t: String) -> void:
	if _out == null:
		_out = FileAccess.open("user://canyon_fill_probe.txt", FileAccess.WRITE)
	_out.store_line(t)
	_out.flush()
	print(t)


func _ready() -> void:
	var scene: PackedScene = load(SCENE)
	var inst := scene.instantiate()
	var data: PlanetData = inst.get("planet_data")
	inst.free()
	data.apply_chunk_manifest()
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(PLANET))
	data.remote_source = RemoteTileSource.for_planet(PLANET)
	var ll := Vector2(-39.5194, 24.7381)
	var forced := OS.get_environment("CANYON_PROBE_LONLAT")
	if forced != "":
		var sp := forced.split(",")
		ll = Vector2(float(sp[0]), float(sp[1]))
	var dir := HEALPix.lonlat2vec(ll.x, ll.y)
	_fetch_tiles(data, dir)
	data.get_bridge_spans()
	data.warm_bridge_plans()
	data.warm_grade_profiles()
	if data.grade_profiles_incomplete():
		data.flush_grade_profiles()
	say("PROBE %s lon %.4f lat %.4f, profiles incomplete: %s"
			% [PLANET, ll.x, ll.y, str(data.grade_profiles_incomplete())])

	var ns: int = 1 << data.max_quadtree_depth
	var centre := HEALPix.vec2pix_nest(ns, dir)
	var ips: Array = [centre]
	for v in HEALPix.get_neighbors_nest(ns, centre).values():
		if int(v) >= 0 and not ips.has(int(v)):
			ips.append(int(v))
	var spacing := HEALPix.pixel_side_length(ns, 1.0) * data.radius / float(data.chunk_resolution)
	var deep := 0
	var filled := 0
	var worst := 0.0
	var worst_at := ""
	var col_filled := 0
	for c: int in ips:
		var cc: Vector3 = PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(ns, c) * data.radius)
		var t0 := Time.get_ticks_msec()
		var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, ns, c, data.chunk_resolution, cc)
		var ms := Time.get_ticks_msec() - t0
		if OS.get_environment("CANYON_PROBE_IDENTITY") == "1":
			_identity(data, ns, c, cc, mesh)
		var chunk_filled := 0
		# Surface 0 is the ground; the others are road slabs, beds and overlays.
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var vi := -1
		for v in verts:
			vi += 1
			var w: Vector3 = v + cc
			var d := w.normalized()
			var off := CrackCarve.offset(data, d, null, spacing, CrackCarve.AUTO)
			if off > -DEEP_M:
				continue
			# A wall's rim vertex stands ON the edge (the rim snap's 5 cm): not inside.
			var ed := ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(d, data.radius,
					data.crack_spacing_m, data.crack_width_m, spacing, data.crack_noise())
			if ed > data.crack_width_m * 0.5 - RIM_M:
				continue
			deep += 1
			var raw: float = data.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null,
					data.sample_nside_for(ns), null, spacing, CrackCarve.NONE)
			var above := (w.length() - data.radius) - (raw + off)
			if above > FILL_M:
				filled += 1
				chunk_filled += 1
				if OS.get_environment("CANYON_PROBE_VERBOSE") == "1" and chunk_filled <= 12:
					var vl := HEALPix.vec2lonlat(d)
					say("PROBE   v%d %.5f %.5f above %.1f off %.1f edge %.2f"
							% [vi, vl.x, vl.y, above, off, ed])
				if above > worst:
					worst = above
					var dl := HEALPix.vec2lonlat(d)
					worst_at = "%.5f %.5f" % [dl.x, dl.y]
		say("PROBE chunk %d: %d vertices, %d filled, %d ms" % [c, verts.size(), chunk_filled, ms])
		col_filled += _collision_filled(data, ns, c, cc, spacing)
	say("PROBE %d vertices inside a canyon (>= %.0f m deep), %d filled, worst %.1f m at %s"
			% [deep, DEEP_M, filled, worst, worst_at])
	say("PROBE collision: %d wall triangles inside a canyon" % col_filled)
	if filled == 0 and col_filled == 0:
		say("PASS")
	else:
		say("FAIL: %d vertices filled into the canyon, %d collision walls standing in it"
				% [filled, col_filled])
	get_tree().quit()


## Collision triangles of chunk [param c] lying wholly inside a canyon and taller than half its
## depth (the floor's own relief reaches ~30 m on a coarse cell): walls nobody sees. A bed
## crossing the gorge under its deck stands there too, flat and inside the deck; only its skirts
## can be tall.
func _collision_filled(data: PlanetData, ns: int, c: int, cc: Vector3, spacing: float) -> int:
	var faces := PlanetChunk.generate_collision_shape_healpix(data, ns, c,
			data.collision_col_res_for(ns)).get_faces()
	var inside := {}
	var out := 0
	var worst := 0.0
	for t in range(0, faces.size(), 3):
		var lo := INF
		var hi := -INF
		var all_in := true
		for e in 3:
			var v: Vector3 = faces[t + e]
			if not inside.has(v):
				var d := (v + cc).normalized()
				var ok := CrackCarve.offset(data, d, null, spacing, CrackCarve.AUTO) <= -DEEP_M \
						and ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(d, data.radius,
						data.crack_spacing_m, data.crack_width_m, spacing, data.crack_noise()) \
						<= data.crack_width_m * 0.5 - RIM_M
				inside[v] = ok
			if not inside[v]:
				all_in = false
				break
			var h := (v + cc).length()
			lo = minf(lo, h)
			hi = maxf(hi, h)
		if not all_in or hi - lo <= 0.5 * data.crack_depth_m:
			continue
		out += 1
		worst = maxf(worst, hi - lo)
		if OS.get_environment("CANYON_PROBE_VERBOSE") == "1" and out <= 6:
			var vl := HEALPix.vec2lonlat((faces[t] + cc).normalized())
			say("PROBE   wall %.5f %.5f %.1f m tall" % [vl.x, vl.y, hi - lo])
	say("PROBE chunk %d collision: %d triangles, %d walls inside the canyon, tallest %.1f m"
			% [c, faces.size() / 3, out, worst])
	return out


## The export tiles under the site and around it (hole_probe's walk up to a
## pruned tile's published ancestor).
func _fetch_tiles(data: PlanetData, dir: Vector3) -> void:
	var et := HEALPix.vec2pix_nest(data.export_nside, dir)
	var want := {et: true}
	for v in HEALPix.get_neighbors_nest(data.export_nside, et).values():
		if int(v) >= 0:
			want[int(v)] = true
	for t: int in want:
		var ns: int = data.export_nside
		var ip := t
		while data.remote_source != null and ns >= data.export_nside_min \
				and not TileResidency.tile_available(data, t, data.export_nside):
			data.remote_source.fetch_now(ns, ip)
			ns >>= 1
			ip >>= 2



## The chunk [param mesh] against the same chunk built through the GDScript sampler only (and its
## collision too): the C# twin must not move one vertex.
func _identity(data: PlanetData, ns: int, c: int, cc: Vector3, mesh: ArrayMesh) -> void:
	var col_res: int = data.collision_col_res_for(ns)
	var col := PlanetChunk.generate_collision_shape_healpix(data, ns, c, col_res).get_faces()
	PlanetData.TileFrame.use_native = false
	var slow: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, ns, c, data.chunk_resolution, cc)
	var slow_col := PlanetChunk.generate_collision_shape_healpix(data, ns, c, col_res).get_faces()
	PlanetData.TileFrame.use_native = true
	var same := mesh.get_surface_count() == slow.get_surface_count() and col == slow_col
	for si in mini(mesh.get_surface_count(), slow.get_surface_count()):
		var a: Array = mesh.surface_get_arrays(si)
		var b: Array = slow.surface_get_arrays(si)
		if a[Mesh.ARRAY_VERTEX] != b[Mesh.ARRAY_VERTEX] or a[Mesh.ARRAY_INDEX] != b[Mesh.ARRAY_INDEX] \
				or a[Mesh.ARRAY_NORMAL] != b[Mesh.ARRAY_NORMAL]:
			same = false
	say("PROBE identity chunk %d: %s" % [c, "C# == GDScript (mesh + collision)" if same else "DIFFERENT"])
