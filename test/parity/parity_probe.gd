extends Node

static var OUT: FileAccess = null

func say(t: String) -> void:
	if OUT == null:
		OUT = FileAccess.open("user://parity_out.txt", FileAccess.WRITE)
	OUT.store_line(t)
	OUT.flush()

## Banc jetable : compare la surface de COLLISION serveur au sampler de référence
## (celui qui place les props / les ponts) sur les chunks que le serveur a réellement
## chargés (cf. godotserver.log). Sortie : distribution de (collision - reference).

const CRACK = preload("res://scenes/planet/aride_desert_corundum_plateau/aride_desert_corundum_plateau_terrain.gd")

const NSIDE := 8192
const IPIXS := [214960188, 214960190, 214960191, 214960182, 214960179]

func _ready() -> void:
	var PD = load("res://scenes/planet/planet_data.gd")
	var data = PD.new()
	data.planet_name = "tarsis_3"
	data.chunk_export_depth = 10
	data.chunk_resolution = 32
	data.max_quadtree_depth = 13
	data.corundum_default_biome = true
	data.crack_spacing_m = 4000.0
	data.crack_width_m = 250.0
	data.crack_depth_m = 180.0
	data.chunk_heightmaps_dir = "assets/qgis/export/tarsis_3_chunks"
	data.chunk_heightmap_res = 32
	data.roads_geojson = "assets/qgis/export/tarsis_3_roads_buffered.json"

	var rts := RemoteTileSource.new()
	rts.planet = "tarsis_3"
	rts.version = "ee59ef5f423a73da"
	rts.tile_res = 32
	rts.nside_min = 1
	rts.nside_max = 1024
	rts.cache_root = "user://tile_cache/"
	data.remote_source = rts

	data.apply_chunk_manifest()
	say("PROBE manifest: radius=%.0f export_nside=%d nside_min=%d tile_res=%d off=%.1f maxh=%.1f exag=%s" % [
		data.radius, data.export_nside, data.export_nside_min, data.chunk_heightmap_res,
		data.height_offset, data.max_height, str(data.terrain_exaggeration)])

	var col_res: int = data.collision_col_res_for(NSIDE)
	var vis_res: int = data.chunk_resolution
	say("PROBE res: collision=%d visuel_LOD0=%d  crack_vtx_spacing=%.2f m" % [
		col_res, vis_res,
		HEALPix.pixel_side_length(NSIDE, 1.0) * data.radius / float(col_res)])

	for ipix in IPIXS:
		_pyramid(data, ipix)
	for ipix in IPIXS:
		_probe(data, ipix, col_res)
		for lod in [0, 1, 2, 3]:
			_probe_mesh(data, ipix, data.get_resolution_for_lod(lod), lod)
	say("FIN")
	get_tree().quit()


## Même mesure, mais sur le maillage VISUEL, au LOD demandé.
func _probe_mesh(data, ipix: int, res: int, lod: int) -> void:
	var center: Vector3 = PlanetChunk.snap_to_f32(
			HEALPix.pix2vec_nest(NSIDE, ipix) * data.radius)
	var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(
			data, NSIDE, ipix, res, center)
	if mesh == null or mesh.get_surface_count() == 0:
		say("PROBE mesh n%d/%d LOD%d : PAS DE MESH" % [NSIDE, ipix, lod])
		return
	var all: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	# Les (res+1)^2 premiers sommets sont la grille ; le reste est la jupe de bord.
	var grid_n: int = (res + 1) * (res + 1)
	var verts := all.slice(0, mini(grid_n, all.size()))
	var d_min := INF
	var d_max := -INF
	var d_sum := 0.0
	var n := 0
	var n_crack := 0
	var worst_crack := 0.0
	for v in verts:
		var w: Vector3 = v + center
		var dir: Vector3 = w.normalized()
		var ref: float = data.crack_aware_surface_dist(dir)
		var d: float = w.length() - ref
		d_sum += d
		n += 1
		if d < d_min: d_min = d
		if d > d_max: d_max = d
		if CRACK.crack_offset(dir, data.radius, data.crack_spacing_m,
				data.crack_width_m, data.crack_depth_m, 0.0) < -1.0:
			n_crack += 1
			if absf(d) > absf(worst_crack): worst_crack = d
	if n == 0:
		return
	if lod == 0:
		_explain(data, ipix, verts, center)
	say("PROBE mesh n%d/%d LOD%d res=%2d  sommets=%4d dans_crack=%4d  delta(visuel-ref): moy=%+.2f m  min=%+.2f  max=%+.2f  pire_en_crack=%+.2f" % [
		NSIDE, ipix, lod, res, n, n_crack, d_sum / n, d_min, d_max, worst_crack])


func _probe(data, ipix: int, res: int) -> void:
	var shape: ConcavePolygonShape3D = PlanetChunk.generate_collision_shape_healpix(
			data, NSIDE, ipix, res)
	if shape == null:
		say("PROBE n%d/%d : PAS DE SHAPE" % [NSIDE, ipix])
		return
	var origin: Vector3 = PlanetChunk.snap_to_f32(
			HEALPix.pix2vec_nest(NSIDE, ipix) * data.radius)
	var faces: PackedVector3Array = shape.get_faces()

	# Sommets uniques du maillage de collision, en rayon absolu.
	var seen := {}
	var deltas := PackedFloat64Array()
	var d_min := INF
	var d_max := -INF
	var d_sum := 0.0
	var n_crack := 0
	for v in faces:
		var w: Vector3 = v + origin
		var k := "%.1f_%.1f_%.1f" % [w.x, w.y, w.z]
		if seen.has(k):
			continue
		seen[k] = true
		var dir: Vector3 = w.normalized()
		# Référence = ce que voient les props / les ponts / le HUD.
		var ref: float = data.crack_aware_surface_dist(dir)
		var d: float = w.length() - ref
		deltas.append(d)
		d_sum += d
		if d < d_min: d_min = d
		if d > d_max: d_max = d
		if CRACK.crack_offset(dir, data.radius, data.crack_spacing_m,
				data.crack_width_m, data.crack_depth_m, 0.0) < -1.0:
			n_crack += 1
	var n := deltas.size()
	if n == 0:
		return
	var sorted := Array(deltas)
	sorted.sort()
	say("PROBE n%d/%d  sommets=%d  dans_crack=%d  delta(collision-ref): moy=%+.2f m  med=%+.2f m  min=%+.2f  max=%+.2f" % [
		NSIDE, ipix, n, n_crack, d_sum / n, sorted[n / 2], d_min, d_max])


## Pour les sommets visuels qui s'écartent de la référence, dire QUI les déplace.
func _explain(data, ipix: int, verts: PackedVector3Array, center: Vector3) -> void:
	var shown := 0
	for i in verts.size():
		var w: Vector3 = verts[i] + center
		var dir: Vector3 = w.normalized()
		var ref: float = data.crack_aware_surface_dist(dir)
		var d: float = w.length() - ref
		if absf(d) < 1.0:
			continue
		shown += 1
		if shown > 6:
			break
		var eip: int = ipix >> 6
		var ll: Vector2 = BiomeQuery._dir_to_lonlat(dir)
		var pz: Array = data.get_chunk_populate_zones(eip)
		var lf: Array = data.get_chunk_linear_features(eip)
		var cr: Array = data.get_chunk_craters(eip)
		var types := PackedStringArray()
		for z in pz:
			types.append("pz:" + str(z.get("biome_type", "?")))
		for z in lf:
			types.append("lf:" + str(z.get("type", "?")))
		say("   ECART sommet[%d] delta=%+.2f m  lonlat=(%.5f, %.5f)  craters=%d  zones=[%s]" % [
			i, d, ll.x, ll.y, cr.size(), ", ".join(types)])


## Combien coûte, en mètres, un échantillonnage un cran plus grossier dans la pyramide ?
## C'est l'écart que prend un client qui n'a pas encore la tuile fine et remonte à
## l'ancêtre, alors que le serveur épingle la tuile fine et attend.
func _pyramid(data, ipix: int) -> void:
	var dirs: Array = HEALPix.get_pixel_grid(NSIDE, ipix, 16)
	for ns in [512, 256, 128]:
		var d_sum := 0.0
		var d_abs := 0.0
		var d_max := 0.0
		var n := 0
		for row in dirs:
			for dir in row:
				var fine: float = data.sample_height_for_direction(
						dir, -1, -1, Vector2i(-1, -1), null, 1024)
				var coarse: float = data.sample_height_for_direction(
						dir, -1, -1, Vector2i(-1, -1), null, ns)
				var d: float = coarse - fine
				d_sum += d
				d_abs += absf(d)
				if absf(d) > absf(d_max): d_max = d
				n += 1
		if ns == 512 and d_max != 0.0 and absf(d_max) > 5.0:
			_locate(data, dirs)
		if n > 0:
			say("PYRAMIDE n%d/%d  n1024 -> n%-4d : biais moy=%+.2f m  ecart abs moy=%.2f m  pire=%+.2f m" % [
				NSIDE, ipix, ns, d_sum / n, d_abs / n, d_max])


## Où, exactement, la pyramide se contredit — et la tuile fine est-elle seulement là ?
func _locate(data, dirs: Array) -> void:
	var shown := 0
	for row in dirs:
		for dir in row:
			var fine: float = data.sample_height_for_direction(
					dir, -1, -1, Vector2i(-1, -1), null, 1024)
			var coarse: float = data.sample_height_for_direction(
					dir, -1, -1, Vector2i(-1, -1), null, 512)
			if absf(coarse - fine) < 5.0:
				continue
			shown += 1
			if shown > 5:
				return
			var ip1024: int = HEALPix.vec2pix_nest(1024, dir)
			var ip512: int = HEALPix.vec2pix_nest(512, dir)
			var ll: Vector2 = BiomeQuery._dir_to_lonlat(dir)
			var t1024: PackedFloat32Array = data.load_chunk_floats(ip1024, 1024)
			var t512: PackedFloat32Array = data.load_chunk_floats(ip512, 512)
			say("   OU  lonlat=(%.5f, %.5f)  delta=%+.2f m  n1024=%d(%s, %d flottants)  n512=%d(%s)  parent(n1024>>2)=%d" % [
				ll.x, ll.y, coarse - fine, ip1024,
				"presente" if not t1024.is_empty() else "ABSENTE", t1024.size(),
				ip512, "presente" if not t512.is_empty() else "ABSENTE",
				ip1024 >> 2])
