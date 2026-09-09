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
	_report("avec les précalculs du chunk", t, n)

	# Un banc qui mesurerait deux surfaces différentes ne mesurerait rien : les deux formes
	# d'appel doivent rendre la même hauteur, bit pour bit.
	print("   hauteurs identiques au bit près : %s" % (plain == fast))


func _report(label: String, t0: int, n: int) -> void:
	var spent := Time.get_ticks_usec() - t0
	print("   %-32s %8.1f ms/chunk %7.2f µs/échantillon" % [
		label, float(spent) / 1000.0 / float(REPS), float(spent) / float(REPS * n)])
