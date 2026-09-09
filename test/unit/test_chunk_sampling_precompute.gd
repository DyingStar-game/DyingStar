extends GutTest
## Les précalculs par chunk passés aux échantillonneurs de hauteur ne changent pas le terrain.
##
## PlanetChunk résout la tuile d'élévation UNE fois par chunk (sa face, sa position entière
## dans la face, ses huit voisines) et passe le résultat à chaque échantillon, au lieu de le
## laisser recalculer 5 445 fois par chunk. Mesuré sur un chunk de tarsis_3 : 99 → 45 µs par
## échantillon (docs/PLANET_CHUNK_STREAMING.md, « Suite du chantier CPU »).
##
## Une optimisation qui déplacerait le terrain d'un demi-texel ne serait pas une
## optimisation : les meshes en cache, les collisions et les props resteraient sur l'ancienne
## surface. Ce fichier vérifie donc l'égalité EXACTE des deux formes d'appel, dans les deux
## cas où elles peuvent diverger :
##
##   1. cache dense — la marge de mélange va chercher des texels chez les voisines, donc les
##      voisines précalculées doivent être celles de la tuile réellement lue ;
##   2. pack creux — la tuile demandée est absente, l'échantillonnage remonte à un ancêtre,
##      et les précalculs de l'appelant décrivent alors une AUTRE tuile. _precomp_xy est la
##      position entière du pixel à son niveau : elle est divisée par deux à chaque remontée.
##      La garder décale l'UV local, donc lit le terrain ailleurs — c'est le chemin que le
##      constructeur de collision emprunte depuis longtemps, sur un pack (celui de tarsis_3)
##      élagué à 69,5 %.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_chunk_sampling_precompute.gd -gexit

const TILE_RES := 16
const NSIDE := 8
## Le chunk le plus fin est bien plus fin que la tuile, comme en jeu (n8192 sur des tuiles
## n1024) : ses sommets tombent tous dans quelques texels, souvent dans la marge de mélange.
const CHUNK_NSIDE := 64
const CHUNK_RES := 8

const DIR := "user://test_chunk_sampling_precompute/"
const SPARSE_NSIDE_MIN := 1
const SPARSE_NSIDE_MAX := 8

var _pd_dense: PlanetData = null
var _pd_sparse: PlanetData = null


func before_all() -> void:
	_pd_dense = _dense_planet()
	DirAccess.make_dir_recursive_absolute(DIR)
	_pd_sparse = _sparse_planet()
	# Ouvrir le pack imprime une ligne, et tout print traverse le pont OpenTelemetry dont
	# l'erreur est comptée par GUT comme un échec du test en cours. Hors test, personne ne
	# tombe. (Même précaution que test_height_pack_v2.gd.)
	_pd_sparse.load_chunk_floats(0, SPARSE_NSIDE_MIN)


func after_all() -> void:
	var d := DirAccess.open(DIR)
	if d:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			d.remove(f)
			f = d.get_next()
		d.list_dir_end()


# ===================================================================
# Fixtures
# ===================================================================

## Tuile à contenu VARIABLE dans la tuile : une tuile uniforme rendrait le test aveugle à un
## UV faux, qui est précisément ce qu'on veut détecter.
func _tile_image(ipix: int) -> Image:
	var img := Image.create_empty(TILE_RES, TILE_RES, false, Image.FORMAT_RF)
	for y in TILE_RES:
		for x in TILE_RES:
			img.set_pixel(x, y, Color(_texel(ipix, x, y), 0.0, 0.0))
	return img


func _texel(ipix: int, x: int, y: int) -> float:
	# Exactement représentable en uint16 : le pack creux stocke en u16, le cache dense en
	# float32, et les deux fixtures doivent porter la même valeur.
	return float((x * 3571 + y * 271 + ipix * 37) % 65535) / 65535.0


func _planet(nside: int) -> PlanetData:
	var pd := PlanetData.new()
	pd.planet_name = "precomp"
	pd.radius = 1000000.0
	pd.max_height = 1.0
	pd.height_offset = 0.0
	pd.terrain_exaggeration = 1.0
	pd.chunk_heightmap_res = TILE_RES
	pd.export_nside = nside
	pd.export_nside_min = 1
	pd.chunk_is_pyramid = true
	return pd


func _dense_planet() -> PlanetData:
	var pd := _planet(NSIDE)
	pd.chunk_heightmaps_dir = ""
	for ipix in 12 * NSIDE * NSIDE:
		pd.store_chunk_image("hp_n%d_p%d" % [NSIDE, ipix], _tile_image(ipix), [])
	return pd


func _sparse_planet() -> PlanetData:
	_write_sparse_pack(DIR + "heights.pack")
	var mf := FileAccess.open(DIR + "manifest.json", FileAccess.WRITE)
	mf.store_string(JSON.stringify({
		"planet_name": "precomp", "tile_res": TILE_RES, "nside": SPARSE_NSIDE_MAX,
		"nside_min": SPARSE_NSIDE_MIN, "nside_max": SPARSE_NSIDE_MAX, "pyramid": true,
		"radius": 1000000.0, "height_offset": 0.0, "max_height": 1.0,
		"packed": true, "pack_file": "heights.pack",
	}))
	mf.close()
	# Champs posés à la main : apply_chunk_manifest() imprime un récapitulatif (voir
	# before_all). Son parsing est couvert par test_height_pack_v2.gd.
	var pd := _planet(SPARSE_NSIDE_MAX)
	pd.chunk_heightmaps_dir = DIR
	return pd


func _present(nside: int, ipix: int) -> bool:
	return nside == SPARSE_NSIDE_MIN or (ipix + nside) % 3 != 0


func _levels() -> Array[int]:
	var out: Array[int] = []
	var ns := SPARSE_NSIDE_MIN
	while ns <= SPARSE_NSIDE_MAX:
		out.append(ns)
		ns *= 2
	return out


## DSHP v2 creux, même format que test_height_pack_v2.gd — mais des tuiles à contenu
## variable, sans quoi la remontée de niveau ne serait pas observable.
func _write_sparse_pack(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(f, "impossible d'écrire %s" % path)
	var manifest := JSON.stringify({
		"planet_name": "precomp", "tile_res": TILE_RES, "nside": SPARSE_NSIDE_MAX,
		"nside_min": SPARSE_NSIDE_MIN, "nside_max": SPARSE_NSIDE_MAX, "pyramid": true,
		"radius": 1000000.0, "height_offset": 0.0, "max_height": 1.0,
	}).to_utf8_buffer()
	var bitmap_bytes := 0
	for nside in _levels():
		bitmap_bytes += (12 * nside * nside + 7) >> 3

	f.store_buffer("DSHP".to_ascii_buffer())
	f.store_32(2)
	f.store_32(TILE_RES)
	f.store_32(SPARSE_NSIDE_MIN)
	f.store_32(SPARSE_NSIDE_MAX)
	f.store_32(1 | 2)  # uint16 + creux
	f.store_32(32 + manifest.size() + bitmap_bytes)
	f.store_32(manifest.size())
	f.store_buffer(manifest)

	for nside in _levels():
		var npix := 12 * nside * nside
		var bits := PackedByteArray()
		bits.resize((npix + 7) >> 3)
		bits.fill(0)
		for ipix in npix:
			if _present(nside, ipix):
				bits[ipix >> 3] = bits[ipix >> 3] | (1 << (ipix & 7))
		f.store_buffer(bits)

	for nside in _levels():
		for ipix in 12 * nside * nside:
			if not _present(nside, ipix):
				continue
			for y in TILE_RES:
				for x in TILE_RES:
					f.store_16(int(round(_texel(ipix, x, y) * 65535.0)))
	f.close()


# ===================================================================
# 1. Cache dense : la forme d'appel ne change pas une hauteur
# ===================================================================

func test_precomputed_tile_position_matches_the_resolved_one() -> void:
	# Les précalculs du chunk ne sont qu'un cache : face et position entière doivent être
	# exactement ce que _direction_to_pixel_uv aurait déduit de l'ipix.
	for ipix: int in [0, 1, 12 * NSIDE * NSIDE - 1, NSIDE * NSIDE * 5 + 17]:
		@warning_ignore("integer_division")
		var face: int = ipix / (NSIDE * NSIDE)
		var xy: Vector2i = HEALPix.nest2xy(ipix % (NSIDE * NSIDE))
		var dir := HEALPix.pix2vec_nest(NSIDE, ipix)
		assert_eq(
				_pd_dense._direction_to_pixel_uv(dir, ipix, NSIDE, face, xy),
				_pd_dense._direction_to_pixel_uv(dir, ipix, NSIDE, -1, Vector2i(-1, -1)),
				"ipix %d : l'UV local ne doit pas dépendre de la forme d'appel" % ipix)


func test_a_whole_chunk_samples_identically_with_and_without_precompute() -> void:
	# Le vrai garde : une grille de chunk entière, comme generate_mesh la parcourt, bords
	# compris — c'est là que sample_height_boundary et la marge de mélange s'arment.
	var export_ipix := NSIDE * NSIDE * 4 + 23
	var hp_ipix := export_ipix
	var ns := NSIDE
	while ns < CHUNK_NSIDE:
		hp_ipix <<= 2
		ns *= 2
	@warning_ignore("integer_division")
	var face := export_ipix / (NSIDE * NSIDE)
	var xy: Vector2i = HEALPix.nest2xy(export_ipix % (NSIDE * NSIDE))
	var neighbors := HEALPix.get_neighbors_nest(NSIDE, export_ipix)

	var frame: PlanetData.TileFrame = _pd_dense.make_tile_frame()
	var grid: Array[PackedVector3Array] = HEALPix.get_pixel_grid(CHUNK_NSIDE, hp_ipix, CHUNK_RES)
	var eps := HEALPix.pixel_side_length(CHUNK_NSIDE, 1.0) * (0.25 / float(CHUNK_RES))
	var checked := 0
	var varied := false
	var first := 0.0
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
				var plain: float
				var fast: float
				var framed: float
				if edge:
					plain = _pd_dense.sample_height_boundary(
							d, export_ipix, -1, Vector2i(-1, -1), null, NSIDE)
					fast = _pd_dense.sample_height_boundary(
							d, export_ipix, face, xy, neighbors, NSIDE)
					framed = _pd_dense.sample_height_boundary(
							d, export_ipix, -1, Vector2i(-1, -1), null, NSIDE, frame)
				else:
					plain = _pd_dense.sample_height_for_direction(
							d, export_ipix, -1, Vector2i(-1, -1), null, NSIDE)
					fast = _pd_dense.sample_height_for_direction(
							d, export_ipix, face, xy, neighbors, NSIDE)
					framed = _pd_dense.sample_height_for_direction(
							d, export_ipix, -1, Vector2i(-1, -1), null, NSIDE, frame)
				if checked == 0:
					first = plain
				elif not is_equal_approx(plain, first):
					varied = true
				checked += 1
				if plain != fast:
					assert_eq(fast, plain,
							"sommet (%d, %d) : les précalculs changent la hauteur" % [xi, yi])
					return
				if plain != framed:
					assert_eq(framed, plain,
							"sommet (%d, %d) : le cadre change la hauteur" % [xi, yi])
					return
	assert_gt(checked, 0, "la grille doit avoir été parcourue")
	assert_true(varied,
			"les hauteurs doivent varier sur le chunk, sinon l'égalité ne prouve rien")
	pass_test("%d échantillons identiques au bit près" % checked)


# ===================================================================
# 2. Pack creux : la remontée de niveau lâche les précalculs de l'appelant
# ===================================================================

func test_level_up_ignores_the_callers_precomputed_tile_position() -> void:
	var absent := -1
	for ipix in 12 * SPARSE_NSIDE_MAX * SPARSE_NSIDE_MAX:
		if not _present(SPARSE_NSIDE_MAX, ipix):
			absent = ipix
			break
	assert_gt(absent, -1, "le motif doit omettre au moins une tuile fine")

	@warning_ignore("integer_division")
	var face := absent / (SPARSE_NSIDE_MAX * SPARSE_NSIDE_MAX)
	var xy: Vector2i = HEALPix.nest2xy(absent % (SPARSE_NSIDE_MAX * SPARSE_NSIDE_MAX))
	var anc_xy: Vector2i = HEALPix.nest2xy(
			(absent >> 2) % ((SPARSE_NSIDE_MAX >> 1) * (SPARSE_NSIDE_MAX >> 1)))
	assert_ne(xy, anc_xy,
			"la position entière doit changer d'un niveau à l'autre, sinon le test est vide")
	var neighbors := HEALPix.get_neighbors_nest(SPARSE_NSIDE_MAX, absent)

	# Un point franchement à l'intérieur de la tuile : hors de la marge de mélange, la
	# hauteur ne dépend que de la tuile lue et de l'UV, donc un UV décalé se voit.
	var dir := HEALPix.pix2vec_nest(SPARSE_NSIDE_MAX, absent)
	var plain := _pd_sparse.sample_height_for_direction(
			dir, absent, -1, Vector2i(-1, -1), null, SPARSE_NSIDE_MAX)
	var fast := _pd_sparse.sample_height_for_direction(
			dir, absent, face, xy, neighbors, SPARSE_NSIDE_MAX)
	assert_eq(fast, plain,
			"après remontée, les précalculs décrivent la tuile absente, pas celle qui est lue")

	# Le cadre, lui, est indexé par tuile : il ne PEUT pas décrire la mauvaise. C'est la
	# raison de fond de le préférer aux trois paramètres passés à la main.
	var framed := _pd_sparse.sample_height_for_direction(
			dir, absent, -1, Vector2i(-1, -1), null, SPARSE_NSIDE_MAX,
			_pd_sparse.make_tile_frame())
	assert_eq(framed, plain, "le cadre doit rendre la hauteur de l'ancêtre")
