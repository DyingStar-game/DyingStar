extends GutTest
## Suite GUT pour [TileResidency] — le garde qui empêche une tâche de mesh de rencontrer
## une tuile manquante.
##
## C'est le point d'accroche de la phase 3 : plutôt que de propager un état « pending » à
## travers l'échantillonneur — appelé des milliers de fois par chunk depuis
## WorkerThreadPool — on garantit la résidence AVANT de soumettre la tâche, et on diffère
## le chunk sinon. Deux propriétés doivent tenir, et elles sont vérifiées ici :
##
##   1. Sans source distante, RIEN ne change. C'est ce qui protège les 20 planètes qui ne
##      streament pas.
##   2. Le jeu de tuiles couvre les VOISINES, pas seulement celle du chunk : le sampler
##      mélange dans une marge de bord et le noyau bilinéaire déborde d'un texel. Ne
##      précharger que la tuile centrale laisserait les bords se rabattre sur la carte
##      globale — la surface plate qui a déjà valu le bug du terrain « des kilomètres sous
##      les props ».
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_tile_residency.gd -gexit

const CACHE := "user://test_tres/"


func _data() -> PlanetData:
	var pd := PlanetData.new()
	pd.export_nside = 64
	pd.export_nside_min = 1
	pd.chunk_heightmap_res = 8
	pd.chunk_is_pyramid = true
	pd.radius = 1000000.0
	return pd


func after_all() -> void:
	RemoteTileSource._remove_tree(CACHE)


# ===================================================================
# 1. Le jeu de tuiles
# ===================================================================

func test_tile_set_includes_the_neighbours_not_just_the_chunk_tile() -> void:
	var pd := _data()
	var tiles := TileResidency.chunk_tile_set(pd, 64, 100)
	assert_gt(tiles.size(), 1, "les voisines doivent en faire partie")
	assert_eq(tiles[0], Vector2i(100, 64), "la tuile du chunk vient en premier")
	var seen := {}
	for t in tiles:
		assert_false(seen.has(t), "aucun doublon dans le jeu : %s" % t)
		seen[t] = true


func test_tile_set_climbs_to_the_sampling_level() -> void:
	# Un chunk plus fin que nside_max lit la tuile de SON niveau d'échantillonnage, pas
	# une tuile inexistante à son propre niveau.
	var pd := _data()
	var tiles := TileResidency.chunk_tile_set(pd, 8192, 100 * 16384)
	for t in tiles:
		assert_eq(t.y, 64, "toutes les tuiles au niveau d'échantillonnage n64")
	assert_eq(tiles[0].x, 100, "ipix remonté par >> 2 à chaque niveau")


func test_tile_set_of_a_coarse_chunk_stays_at_its_own_level() -> void:
	var pd := _data()
	var tiles := TileResidency.chunk_tile_set(pd, 16, 7)
	assert_eq(tiles[0], Vector2i(7, 16), "un chunk plus grossier lit sa propre tuile")


# ===================================================================
# 2. Le garde
# ===================================================================

func test_without_a_remote_source_nothing_changes() -> void:
	# La propriété qui protège les planètes non streamées : le garde doit rendre true
	# sans rien inspecter, donc sans coût et sans changer de comportement.
	var pd := _data()
	assert_null(pd.remote_source)
	assert_true(TileResidency.request_chunk_tiles(pd, 64, 12),
			"sans source distante, un chunk est toujours prêt")


func test_missing_tiles_are_queued_and_the_chunk_is_deferred() -> void:
	var pd := _data()
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	rts.planet = "p"
	rts.version = "v"
	rts.base_url = "http://h"
	rts.tile_res = 8
	rts.shard_tiles = 4096
	# Le service annonce toutes les tuiles présentes, mais aucune n'est téléchargée.
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	rts.fetcher = func(url: String) -> Array:
		return [200, bits] if url.ends_with("present.bin") else [404, PackedByteArray()]
	pd.remote_source = rts

	assert_false(TileResidency.request_chunk_tiles(pd, 64, 12),
			"des tuiles manquantes doivent différer le chunk")
	assert_gt(rts.stat_requested, 1,
			"la tuile ET ses voisines doivent être demandées, pas seulement la première")


func test_queueing_is_idempotent() -> void:
	# Le backlog est réexaminé à chaque frame : redemander à chaque passage saturerait la
	# file de doublons.
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	for _i in 5:
		rts.queue(64, 3)
	assert_eq(rts.stat_requested, 1, "une seule demande pour la même tuile")
