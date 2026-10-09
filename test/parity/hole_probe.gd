extends Node
## Bench: is the ground CLOSED where the game builds it? The real tarsis_3 pack,
## the POI spheres of its scene and a village's building pads, at the finest
## LOD — the two ground faults found on 2026-09-30, which no synthetic unit test
## saw because they only happen on the real data.
##
## For each site, the chunk under it and its eight neighbours are built (mesh
## AND collision), then:
##
##   1. SEAMS — every direction two chunks both carry a vertex at has ONE radius
##      (1 cm tolerance), in the mesh and in the collision. A disagreement is a
##      step between two chunks: the 24.5 cm one along an export-tile border
##      whose tile across was pruned (PlanetData._pruned_tile_climbs).
##   2. HOLES — rays straight down on a 64 × 64 grid over the CENTRE chunk hit
##      the UNION of the nine collision shapes. The union and not the centre
##      chunk alone: the crack rim snap slides a chunk's border vertices into it
##      and the neighbour, moving the same vertices, closes the strip — a chunk
##      tested alone shows "holes" all along every snapped rim. A physics miss is
##      confirmed against the triangles themselves (a ray grazing an edge misses
##      in Jolt and is not a hole). This is the open cell where a flat crack rim
##      crossed the village's pads (PlanetChunk._snap_lands_on_wall).
##
## Default sites: the village by the teleporter, with its pads
## (hole_probe_village_pads.txt, yaw 0 — the log has no yaw, 0 reproduced the
## hole), and the pruned-tile border at 39.519 W 24.736 N.
##
## Run with:
##   godot --headless --path . res://test/parity/hole_probe.tscn
## HOLE_PROBE_LONLAT="lon,lat" to probe one site of your own instead,
## HOLE_PADS=<file> (same format as the village file) to register pads there,
## HOLE_YAW=<rad> for their yaw.
## Output: user://hole_probe.txt, last line "PASS" or "FAIL: …".
## The elevation is streamed: the first run fetches the tiles (RemoteTileSource),
## later runs read them from the local cache. A few minutes per site.

const PLANET := "tarsis_3"
const SCENE := "res://scenes/systems/tarsis/tarsis_3.tscn"
const VILLAGE_PADS := "res://test/parity/hole_probe_village_pads.txt"
## Border vertices closer than this are one vertex.
const SEAM_TOLERANCE_M := 0.01
## Rays per side of the centre chunk.
const RAY_GRID := 64

var _out: FileAccess = null
var _failures: PackedStringArray = []


func say(t: String) -> void:
	if _out == null:
		_out = FileAccess.open("user://hole_probe.txt", FileAccess.WRITE)
	_out.store_line(t)
	_out.flush()
	print(t)


func _ready() -> void:
	# The physics space answers rays only once it has stepped.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var scene: PackedScene = load(SCENE)
	var inst := scene.instantiate()
	var data: PlanetData = inst.get("planet_data")
	inst.free()
	if data == null:
		say("FAIL: pas de PlanetData sur la racine de %s" % SCENE)
		get_tree().quit()
		return
	data.apply_chunk_manifest()
	# The POI spheres the game gives the crack network: without them the village
	# would be cut by a 180 m canyon it does not have in game.
	data.set_crack_exclusions(PlanetTerrain.poi_crack_exclusions(PLANET))
	data.remote_source = RemoteTileSource.for_planet(PLANET)
	say("PROBE %s : rayon %.0f m, export n%d, grille la plus fine n%d, %d POI"
			% [PLANET, data.radius, data.export_nside, 1 << data.max_quadtree_depth,
			data._crack_pois.size()])

	var sites: Array = []
	var forced := OS.get_environment("HOLE_PROBE_LONLAT")
	if forced != "":
		var sp := forced.split(",")
		sites.append({"name": "site imposé", "lonlat": Vector2(float(sp[0]), float(sp[1])),
				"pads": OS.get_environment("HOLE_PADS")})
	else:
		sites.append({"name": "village du téléporteur (pads, lèvre de fissure sous POI)",
				"lonlat": Vector2(-39.5524, 24.8577), "pads": VILLAGE_PADS})
		sites.append({"name": "frontière de tuile élaguée",
				"lonlat": Vector2(-39.5190, 24.7361), "pads": ""})
	var yaw := float(OS.get_environment("HOLE_YAW"))

	for site: Dictionary in sites:
		var ll: Vector2 = site["lonlat"]
		say("PROBE ── %s : lon %.4f lat %.4f" % [site["name"], ll.x, ll.y])
		_fetch_tiles(data, HEALPix.lonlat2vec(ll.x, ll.y))
		if str(site["pads"]) != "":
			_register_pads(data, str(site["pads"]), yaw)
		await _check_site(data, HEALPix.lonlat2vec(ll.x, ll.y))

	if _failures.is_empty():
		say("PASS")
	else:
		say("FAIL: " + "; ".join(_failures))
	get_tree().quit()


## The export tiles under the site and around it, fetched once so every
## direction resolves to real elevation.
func _fetch_tiles(data: PlanetData, dir: Vector3) -> void:
	var et := HEALPix.vec2pix_nest(data.export_nside, dir)
	var want := {et: true}
	for v in HEALPix.get_neighbors_nest(data.export_nside, et).values():
		if int(v) >= 0:
			want[int(v)] = true
	for t: int in want:
		if not TileResidency.tile_available(data, t, data.export_nside) \
				and data.remote_source != null:
			data.remote_source.fetch_now(data.export_nside, t)


## Register the pads of [param path]: one per line, "uuid width length apron
## lon lat", '#' comments.
func _register_pads(data: PlanetData, path: String, yaw: float) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_failures.append("fichier de pads illisible : %s" % path)
		return
	var n := 0
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var a := line.split(" ", false)
		data.register_pad(PadBed.record(a[0], float(a[4]), float(a[5]), yaw,
				0.5 * float(a[1]), 0.5 * float(a[2]), float(a[3]), 0.0))
		n += 1
	say("PROBE   %d pad(s) lus, %d enregistré(s), %d en attente de tuiles"
			% [n, data._pads.size() if data._pads != null else 0, data._pads_starved.size()])


func _check_site(data: PlanetData, dir: Vector3) -> void:
	var ns: int = 1 << data.max_quadtree_depth
	var centre := HEALPix.vec2pix_nest(ns, dir)
	var ips: Array = [centre]
	for v in HEALPix.get_neighbors_nest(ns, centre).values():
		if int(v) >= 0 and not ips.has(int(v)):
			ips.append(int(v))
	var col_res: int = data.collision_col_res_for(ns)
	# Every vertex of every chunk, keyed by direction, with its radius; and the
	# collision faces moved into one frame (the centre chunk's) for the rays.
	var origin: Vector3 = PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(ns, centre) * data.radius)
	var mesh_by := {}
	var col_by := {}
	var faces_by := {}
	for c: int in ips:
		var cc: Vector3 = PlanetChunk.snap_to_f32(HEALPix.pix2vec_nest(ns, c) * data.radius)
		var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(data, ns, c, data.chunk_resolution, cc)
		var m := {}
		for si in mesh.get_surface_count():
			for v in (mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				var w: Vector3 = v + cc
				m[_key(w)] = w.length()
		mesh_by[c] = m
		var shape: ConcavePolygonShape3D = PlanetChunk.generate_collision_shape_healpix(
				data, ns, c, col_res)
		var faces := shape.get_faces()
		var cm := {}
		var moved := PackedVector3Array()
		moved.resize(faces.size())
		for i in faces.size():
			var w: Vector3 = faces[i] + cc
			cm[_key(w)] = w.length()
			moved[i] = w - origin
		col_by[c] = cm
		faces_by[c] = moved
	_seams("mesh", ips, mesh_by)
	_seams("collision", ips, col_by)
	await _holes(data, ns, centre, origin, ips, faces_by)


func _seams(kind: String, ips: Array, by: Dictionary) -> void:
	var pairs := 0
	var bad_pairs := 0
	var worst := 0.0
	var worst_at := ""
	for i in ips.size():
		for j in range(i + 1, ips.size()):
			var a: Dictionary = by[ips[i]]
			var b: Dictionary = by[ips[j]]
			var shared := 0
			var bad := 0
			for k in a:
				if not b.has(k):
					continue
				shared += 1
				var d := absf(float(a[k]) - float(b[k]))
				if d > SEAM_TOLERANCE_M:
					bad += 1
					if d > worst:
						worst = d
						worst_at = "p%d↔p%d à %s" % [ips[i], ips[j], k]
			if shared == 0:
				continue
			pairs += 1
			if bad > 0:
				bad_pairs += 1
				say("PROBE   raccord %s p%d↔p%d : %d sommet(s) partagé(s), %d en désaccord"
						% [kind, ips[i], ips[j], shared, bad])
	say("PROBE   raccords %s : %d paire(s) de voisins, %d en désaccord%s" % [kind, pairs, bad_pairs,
			(" — pire %.3f m, %s" % [worst, worst_at]) if bad_pairs > 0 else ""])
	if bad_pairs > 0:
		_failures.append("marche de %.3f m entre chunks (%s, %s)" % [worst, kind, worst_at])


func _holes(data: PlanetData, ns: int, centre: int, origin: Vector3, ips: Array,
		faces_by: Dictionary) -> void:
	var space := get_viewport().world_3d.direct_space_state
	var rids: Array = []
	var shapes: Array = []
	for c: int in ips:
		var sh := ConcavePolygonShape3D.new()
		sh.backface_collision = true
		sh.set_faces(faces_by[c])
		shapes.append(sh)
		var rid := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_space(rid, get_viewport().world_3d.space)
		PhysicsServer3D.body_add_shape(rid, sh.get_rid())
		rids.append(rid)
	await get_tree().physics_frame
	# Sub-pixels of the centre chunk: its nested children RAY_GRID levels down.
	var sub := ns * RAY_GRID
	var per := RAY_GRID * RAY_GRID
	var holes := 0
	for k in per:
		var d := HEALPix.pix2vec_nest(sub, centre * per + k)
		var h := data.sample_height_for_direction(d, -1, -1, Vector2i(-1, -1), null, -1, null, 0.0,
				CrackCarve.NONE)
		var from: Vector3 = d * (data.radius + h + 300.0) - origin
		var to: Vector3 = d * (data.radius + h - 400.0) - origin
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.hit_back_faces = true
		if not space.intersect_ray(q).is_empty() or _hits_any(from, to, faces_by):
			continue
		holes += 1
		if holes <= 5:
			say("PROBE     pas de sol à %s" % str(HEALPix.vec2lonlat(d)))
	for rid in rids:
		PhysicsServer3D.free_rid(rid)
	say("PROBE   trous : %d rayon(s) sur %d sans sol sous p%d (union des %d chunks)"
			% [holes, per, centre, ips.size()])
	if holes > 0:
		_failures.append("%d trou(s) sous p%d" % [holes, centre])


## The exact test behind a physics miss.
func _hits_any(from: Vector3, to: Vector3, faces_by: Dictionary) -> bool:
	for c in faces_by:
		var f: PackedVector3Array = faces_by[c]
		for t in range(0, f.size(), 3):
			if Geometry3D.segment_intersects_triangle(from, to, f[t], f[t + 1], f[t + 2]) != null:
				return true
	return false


## A vertex's identity across chunks: its direction to ~10 cm — coarse enough
## that the float32 vertex offsets of two chunks round to one key, fine enough
## that two vertices of the grid (≥ 3 m apart even refined) never share one.
func _key(w: Vector3) -> String:
	var ll := HEALPix.vec2lonlat(w.normalized())
	return "%.6f,%.6f" % [ll.x, ll.y]
