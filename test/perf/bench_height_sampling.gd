#!/usr/bin/env -S godot --headless --script
## Banc de mesure du chemin CHAUD d'échantillonnage de hauteur.
##
## Pourquoi : docs/PLANET_CHUNK_STREAMING.md (« Suite du chantier CPU ») a laissé
## l'échantillonnage de hauteur à 57 % du temps d'un chunk — le dernier gros poste de la
## génération. Ce banc le reproduit hors du jeu pour qu'on puisse l'attribuer.
##
## Ce qu'il fait : une grille de chunk complète, 5 échantillons par sommet (le sommet plus
## les 4 points du gradient analytique), exactement comme PlanetChunk.generate_mesh. Les
## tuiles sont synthétiques et en RAM — c'est le cas réel : le relevé en jeu compte
## 1,29 million de demandes pour 29 tuiles distinctes, donc ce qui est mesuré est la
## mécanique de lookup et le noyau bilinéaire, pas de l'entrée/sortie.
##
## Deux chunks, parce que le coût n'a pas le même régime :
##   · un chunk dont les texels tombent dans la marge de mélange de 4 px du noyau
##     (~60 % des chunks les plus fins : leur fenêtre de 4×4 texels sur une tuile 32²
##     touche la marge sauf si elle tient dans le carré central) ;
##   · un chunk au centre de sa tuile, qui prend le chemin rapide sans voisines.
##
## Run:
##   godot --headless --script test/perf/bench_height_sampling.gd
extends SceneTree

const PlanetDataScript := preload("res://scenes/planet/planet_data.gd")

const NSIDE := 1024        # tarsis_3 : export_nside
const TILE_RES := 32       # tarsis_3 : tile_res
const CHUNK_RES := 32      # chunk_resolution
const HP_NSIDE := 8192     # chunk le plus fin (max_quadtree_depth 13)
const REPS := 30


func _init() -> void:
	var pd = _make_data()
	# Deux tuiles d'export voisines dans la même face, pour que les deux chunks mesurés
	# soient dans des positions différentes de leur tuile.
	var base_ipix := NSIDE * NSIDE * 3 + 12345
	_fill_tiles(pd, base_ipix)

	print("=== échantillonnage de hauteur, %d sommets par chunk ===" % [
		(CHUNK_RES + 1) * (CHUNK_RES + 1)])
	# La fenêtre du chunk dans sa tuile est choisie par les bits BAS de hp_ipix : en NESTED,
	# descendre d'un niveau ajoute deux bits (x, y). On vise donc un coin (marge) et le
	# centre de la tuile.
	_measure(pd, base_ipix, _child_at(base_ipix, 0, 0), "chunk sur le bord de sa tuile")
	_measure(pd, base_ipix, _child_at(base_ipix, TILE_RES / 2, TILE_RES / 2),
			"chunk au centre de sa tuile")
	_measure_mountains(pd, base_ipix, _child_at(base_ipix, TILE_RES / 2, TILE_RES / 2))
	quit()


func _make_data() -> Resource:
	var pd = PlanetDataScript.new()
	pd.planet_name = "bench"
	pd.radius = 6356000.0
	pd.max_height = 10700.0
	pd.height_offset = -1700.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_resolution = CHUNK_RES
	pd.max_quadtree_depth = 13
	pd.chunk_heightmap_res = TILE_RES
	pd.chunk_heightmaps_dir = ""
	pd.export_nside = NSIDE
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	return pd


func _make_tile(seed_value: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for y in TILE_RES:
		for x in TILE_RES:
			img.set_pixel(x, y, Color(rng.randf(), 0.0, 0.0))
	return img


## La tuile du chunk et ses huit voisines : la marge de mélange va les lire.
func _fill_tiles(pd, export_ipix: int) -> void:
	pd.store_chunk_image("hp_n%d_p%d" % [NSIDE, export_ipix], _make_tile(1), [])
	var s := 2
	for k in HEALPix.get_neighbors_nest(NSIDE, export_ipix):
		var ip: int = HEALPix.get_neighbors_nest(NSIDE, export_ipix)[k]
		if ip >= 0:
			pd.store_chunk_image("hp_n%d_p%d" % [NSIDE, ip], _make_tile(s), [])
			s += 1


## ipix du chunk fin dont le coin bas-gauche tombe sur le texel (tx, ty) de la tuile.
func _child_at(export_ipix: int, tx: int, ty: int) -> int:
	var ip := export_ipix
	var ns := NSIDE
	var step := TILE_RES
	while ns < HP_NSIDE:
		step >>= 1
		# Deux bits par niveau : bit 0 = x, bit 1 = y (entrelacement NESTED).
		var bx := 1 if (tx & step) != 0 else 0
		var by := 1 if (ty & step) != 0 else 0
		ip = (ip << 2) | (by << 1) | bx
		ns <<= 1
	return ip


func _measure(pd, export_ipix: int, hp_ipix: int, label: String) -> void:
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(HP_NSIDE, hp_ipix, CHUNK_RES)
	var eps := HEALPix.pixel_side_length(HP_NSIDE, 1.0) * (0.25 / float(CHUNK_RES))
	var sample_nside: int = pd.sample_nside_for(HP_NSIDE)
	var dirs := PackedVector3Array()
	var interior := PackedInt32Array()
	for yi in CHUNK_RES + 1:
		for xi in CHUNK_RES + 1:
			var dir_c: Vector3 = grid[yi][xi]
			var arbitrary := Vector3.UP if absf(dir_c.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			var tan_u := dir_c.cross(arbitrary).normalized()
			var tan_v := dir_c.cross(tan_u).normalized()
			var edge := xi == 0 or xi == CHUNK_RES or yi == 0 or yi == CHUNK_RES
			for d in [dir_c,
					(dir_c - tan_u * eps).normalized(), (dir_c + tan_u * eps).normalized(),
					(dir_c - tan_v * eps).normalized(), (dir_c + tan_v * eps).normalized()]:
				dirs.append(d)
				interior.append(0 if edge else 1)

	var n := dirs.size()
	var in_margin := 0
	for i in n:
		var uv: Vector2 = pd._direction_to_pixel_uv(dirs[i], export_ipix, sample_nside,
				-1, Vector2i(-1, -1))
		var fpx := uv.x * float(TILE_RES) - 0.5
		var fpy := uv.y * float(TILE_RES) - 0.5
		if fpx < 4.0 or fpx > float(TILE_RES - 5) or fpy < 4.0 or fpy > float(TILE_RES - 5):
			in_margin += 1
	print("\n── %s : %d échantillons, %.0f %% dans la marge de mélange" % [
		label, n, 100.0 * in_margin / n])

	@warning_ignore("integer_division")
	var face: int = export_ipix / (sample_nside * sample_nside)
	var xy: Vector2i = HEALPix.nest2xy(export_ipix % (sample_nside * sample_nside))
	var nbrs := HEALPix.get_neighbors_nest(sample_nside, export_ipix)

	var t := Time.get_ticks_usec()
	var plain := 0.0
	for r in REPS:
		for i in n:
			if interior[i] == 1:
				plain += pd.sample_height_for_direction(dirs[i], export_ipix, -1,
						Vector2i(-1, -1), null, sample_nside)
			else:
				plain += pd.sample_height_boundary(dirs[i], export_ipix, -1,
						Vector2i(-1, -1), null, sample_nside)
	_report("sans précalculs (ancien appel)", t, n)

	t = Time.get_ticks_usec()
	var fast := 0.0
	for r in REPS:
		for i in n:
			if interior[i] == 1:
				fast += pd.sample_height_for_direction(dirs[i], export_ipix, face, xy,
						nbrs, sample_nside)
			else:
				fast += pd.sample_height_boundary(dirs[i], export_ipix, face, xy,
						nbrs, sample_nside)
	_report("précalculs passés à la main", t, n)

	# Le cadre est créé UNE fois par chunk, comme dans generate_mesh.
	t = Time.get_ticks_usec()
	var framed := 0.0
	for r in REPS:
		var frame: PlanetData.TileFrame = pd.make_tile_frame()
		for i in n:
			if interior[i] == 1:
				framed += pd.sample_height_for_direction(dirs[i], export_ipix, -1,
						Vector2i(-1, -1), null, sample_nside, frame)
			else:
				framed += pd.sample_height_boundary(dirs[i], export_ipix, -1,
						Vector2i(-1, -1), null, sample_nside, frame)
	_report("cadre de tuiles du chunk", t, n)

	# Un banc qui mesurerait deux surfaces différentes ne mesurerait rien : les deux formes
	# d'appel doivent rendre la même hauteur, bit pour bit.
	print("   hauteurs identiques au bit près : %s (cadre : %s)" % [
		plain == fast, plain == framed])

	# ── Décomposition du chemin rapide, pour savoir où va ce qui reste ────────────────
	var acc := 0.0
	t = Time.get_ticks_usec()
	for r in REPS:
		for i in n:
			acc += pd.load_chunk_floats(export_ipix, sample_nside).size()
	_report("  · lookup de tuile", t, n)

	t = Time.get_ticks_usec()
	for r in REPS:
		for i in n:
			acc += pd._direction_to_pixel_uv(dirs[i], export_ipix, sample_nside, face, xy).x
	_report("  · UV local (trigonométrie)", t, n)

	var floats: PackedFloat32Array = pd.load_chunk_floats(export_ipix, sample_nside)
	var uvs := PackedVector2Array()
	for i in n:
		uvs.append(pd._direction_to_pixel_uv(dirs[i], export_ipix, sample_nside, face, xy))
	t = Time.get_ticks_usec()
	for r in REPS:
		for i in n:
			acc += pd._sample_image_bilinear_healpix(floats, TILE_RES, uvs[i].x, uvs[i].y,
					export_ipix, nbrs, sample_nside)
	_report("  · noyau bilinéaire + mélange", t, n)
	# Intérieur et bord séparés : le bord passe par sample_height_boundary, qui commence par
	# un vec2pix_nest et peut basculer sur une AUTRE tuile que celle du chunk.
	var frame2: PlanetData.TileFrame = pd.make_tile_frame()
	var inner := PackedVector3Array()
	var edges := PackedVector3Array()
	for i in n:
		if interior[i] == 1:
			inner.append(dirs[i])
		else:
			edges.append(dirs[i])
	t = Time.get_ticks_usec()
	for r in REPS:
		for d in inner:
			acc += pd.sample_height_for_direction(d, export_ipix, -1, Vector2i(-1, -1),
					null, sample_nside, frame2)
	_report("  · sommets intérieurs (%d)" % inner.size(), t, inner.size())
	t = Time.get_ticks_usec()
	for r in REPS:
		for d in edges:
			acc += pd.sample_height_boundary(d, export_ipix, -1, Vector2i(-1, -1),
					null, sample_nside, frame2)
	_report("  · sommets de bord (%d)" % edges.size(), t, edges.size())

	t = Time.get_ticks_usec()
	for r in REPS:
		for d in inner:
			acc += HEALPix.vec2pix_nest(sample_nside, d)
	_report("  · dont HEALPix.vec2pix_nest", t, inner.size())

	if acc == 0.0:
		print("   (accumulateur nul — le banc n'a rien lu)")


## Surcoût des montagnes procédurales (MountainRelief) sur le même chunk, chemin du cadre
## comme generate_mesh, puis le chemin gameplay (sans cadre, pas 0 = plein détail). Cibles
## du plan : (b) ≤ +40 % du chemin de base, (c) ≤ +60 %, (d) ≤ +50 %, (e) ≤ 10 µs/appel.
func _measure_mountains(pd, export_ipix: int, hp_ipix: int) -> void:
	pd.max_quadtree_depth = 13
	pd.chunk_resolution = CHUNK_RES
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(HP_NSIDE, hp_ipix, CHUNK_RES)
	var eps := HEALPix.pixel_side_length(HP_NSIDE, 1.0) * (0.25 / float(CHUNK_RES))
	var sample_nside: int = pd.sample_nside_for(HP_NSIDE)
	var pitch: float = HEALPix.pixel_side_length(HP_NSIDE, pd.radius) / float(CHUNK_RES)
	var dirs := PackedVector3Array()
	var interior := PackedInt32Array()
	for yi in CHUNK_RES + 1:
		for xi in CHUNK_RES + 1:
			var dir_c: Vector3 = grid[yi][xi]
			var arbitrary := Vector3.UP if absf(dir_c.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			var tan_u := dir_c.cross(arbitrary).normalized()
			var tan_v := dir_c.cross(tan_u).normalized()
			var edge := xi == 0 or xi == CHUNK_RES or yi == 0 or yi == CHUNK_RES
			for d in [dir_c,
					(dir_c - tan_u * eps).normalized(), (dir_c + tan_u * eps).normalized(),
					(dir_c - tan_v * eps).normalized(), (dir_c + tan_v * eps).normalized()]:
				dirs.append(d)
				interior.append(0 if edge else 1)
	var n := dirs.size()
	print("\n── montagnes procédurales sur ce chunk (pas de sommet %.1f m)" % pitch)

	var c_ll: Vector2 = HEALPix.vec2lonlat(HEALPix.pix2vec_nest(HP_NSIDE, hp_ipix))
	var mpd: float = pd.radius * PI / 180.0
	var clat := cos(deg_to_rad(c_ll.y))
	var style := {"amplitude_m": 600.0, "wavelength_m": 6000.0, "octaves": 8, "ridge": 0.6,
			"exponent": 1.5, "seed": 3}
	# (b) zone pleine couverture.
	var full := style.duplicate()
	full["coverage"] = "full"
	# (c) anneau de 16 sommets, 600 m de rayon, décalé de 300 m : il coupe le chunk.
	var ring := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16.0
		ring.append(c_ll + Vector2((300.0 + 600.0 * cos(a)) / mpd / clat, 600.0 * sin(a) / mpd))
	var partial := style.duplicate()
	partial["coverage"] = "partial"
	partial["polygon"] = ring
	# (d) crête de 12 segments en travers du chunk.
	var crest := PackedVector2Array()
	for i in 13:
		crest.append(c_ll + Vector2((-1200.0 + 200.0 * i) / mpd / clat, (80.0 * sin(i * 0.9)) / mpd))
	var ridge := {"coverage": "partial", "polygon": crest, "height_m": 200.0, "width_m": 500.0,
			"roughness": 0.3, "warp_m": 40.0, "asymmetry": 0.4}

	var cases := [
		["(a) sans montagnes", [], []],
		["(b) zone pleine, 8 octaves", [full], []],
		["(c) zone partielle, anneau 16", [partial], []],
		["(d) crête 12 segments", [], [ridge]],
	]
	var acc := 0.0
	for cs in cases:
		pd.set_mountain_overrides(cs[1], cs[2])
		var t := Time.get_ticks_usec()
		for r in REPS:
			var frame: PlanetData.TileFrame = pd.make_tile_frame()
			pd.prepare_mountain_frame(frame, HP_NSIDE, hp_ipix)
			for i in n:
				if interior[i] == 1:
					acc += pd.sample_height_for_direction(dirs[i], export_ipix, -1,
							Vector2i(-1, -1), null, sample_nside, frame, pitch)
				else:
					acc += pd.sample_height_boundary(dirs[i], export_ipix, -1,
							Vector2i(-1, -1), null, sample_nside, frame, pitch)
		_report(cs[0], t, n)
	# (e) chemin gameplay : pas de cadre, plein détail, zone partielle + crête.
	pd.set_mountain_overrides([partial], [ridge])
	var t := Time.get_ticks_usec()
	for r in REPS:
		for i in n:
			acc += pd.sample_height_for_direction(dirs[i])
	_report("(e) gameplay sans cadre", t, n)
	pd.set_mountain_overrides([], [])
	if acc == 0.0:
		print("   (accumulateur nul)")


func _report(label: String, t0: int, n: int) -> void:
	var spent := Time.get_ticks_usec() - t0
	print("   %-32s %8.1f ms/chunk %7.2f µs/échantillon" % [
		label, float(spent) / 1000.0 / float(REPS), float(spent) / float(REPS * n)])
