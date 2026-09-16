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


func test_the_gate_never_touches_the_network() -> void:
	# LA régression : request_chunk_tiles tournait avec has_tile(), qui va chercher la
	# carte d'un shard en HTTP SYNCHRONE quand elle manque. Appelé pour chaque chunk en
	# attente à chaque frame, cela a fait tomber le jeu à 0,2 FPS. Le garde tourne sur le
	# thread principal : il ne doit émettre aucune requête, jamais.
	var pd := _data()
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	rts.planet = "p"
	rts.version = "v"
	rts.base_url = "http://h"
	rts.tile_res = 8
	rts.nside_max = 64
	var calls := [0]
	rts.fetcher = func(_url: String) -> Array:
		calls[0] += 1
		return [404, PackedByteArray()]
	pd.remote_source = rts

	assert_false(TileResidency.request_chunk_tiles(pd, 64, 12),
			"cartes de présence inconnues : le chunk doit être différé")
	assert_eq(calls[0], 0, "aucune requête ne doit partir du thread principal")


func test_unknown_presence_defers_then_resolves() -> void:
	# Deux temps : la carte manque, le chunk est différé ; le fil de téléchargement la
	# rapatrie ; la frame suivante, les tuiles sont demandées.
	var pd := _data()
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	rts.planet = "p"
	rts.version = "v"
	rts.base_url = "http://h"
	rts.tile_res = 8
	rts.nside_max = 64
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	rts.fetcher = func(url: String) -> Array:
		return [200, bits] if url.ends_with("present.bin") else [404, PackedByteArray()]
	pd.remote_source = rts

	assert_eq(rts.presence_of(64, 12), RemoteTileSource.PRESENCE_UNKNOWN,
			"première consultation : inconnue, et la carte est mise en file")
	assert_false(TileResidency.request_chunk_tiles(pd, 64, 12))
	assert_eq(rts.stat_requested, 0, "aucune TUILE demandée tant que la présence est inconnue")

	# Ce que fait le fil de téléchargement pour un travail JOB_PRESENCE.
	rts.has_tile(64, 12)
	assert_eq(rts.presence_of(64, 12), RemoteTileSource.PRESENCE_YES, "carte arrivée")

	assert_false(TileResidency.request_chunk_tiles(pd, 64, 12),
			"les tuiles ne sont toujours pas téléchargées")
	assert_gt(rts.stat_requested, 1,
			"la tuile ET ses voisines doivent maintenant être demandées")


func test_a_pruned_tile_needs_its_finest_published_ancestor_not_any_local_one() -> void:
	# n64 élaguée (présence NON), n32 publiée (OUI) mais pas téléchargée, n1 (plancher)
	# sur disque. L'ancien garde voyait « élaguée + un ancêtre présent » et laissait
	# bâtir sur le plancher — terrasses de centaines de mètres, profils de ligne
	# différents d'une machine à l'autre. La tuile n'est disponible que quand n32 est là.
	var pd := _data()
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	rts.planet = "p"
	rts.version = "v"
	rts.base_url = "http://h"
	rts.tile_res = 8
	rts.nside_max = 64
	var none := PackedByteArray()
	none.resize(512)
	none.fill(0x00)
	var all := PackedByteArray()
	all.resize(512)
	all.fill(0xFF)
	rts._present["n64/f0"] = none
	rts._present["n32/f0"] = all
	rts._present["n16/f0"] = none
	rts._present["n8/f0"] = none
	rts._present["n4/f0"] = none
	rts._present["n2/f0"] = none
	rts._present["n1/f0"] = all
	pd.remote_source = rts
	# The floor tile is on disk (a real 8×8 tile), nothing finer.
	var img := Image.create_empty(8, 8, false, Image.FORMAT_RF)
	img.fill(Color(0.5, 0.0, 0.0))
	pd.store_chunk_image("hp_n1_p0", img, [])
	assert_gt(pd._finest_present_ancestor(0, 64).y, 0, "un ancêtre local existe bien (n1)")
	assert_eq(TileResidency.finest_published_ancestor_state(pd, 0, 64),
			TileResidency.PUBLISHED_ABSENT, "le plus fin niveau publié est n32, absent")
	assert_false(TileResidency.tile_available(pd, 0, 64),
			"pas disponible : bâtir sur n1 n'a rien d'une reconstruction au mètre")
	assert_true(pd._climb_is_guess(64, 0), "et la remontée du sampler serait une supposition")
	assert_false(TileResidency.request_chunk_tiles(pd, 64, 0))
	# n32 arrives.
	pd.store_chunk_image("hp_n32_p0", img, [])
	assert_eq(TileResidency.finest_published_ancestor_state(pd, 0, 64),
			TileResidency.PUBLISHED_PRESENT)
	assert_true(TileResidency.tile_available(pd, 0, 64), "n32 là : la tuile élaguée se lit dessus")
	assert_false(pd._climb_is_guess(64, 0), "remontée légitime, persistable")


func test_a_level_the_service_does_not_publish_costs_nothing() -> void:
	# LE cas des lunes : le manifeste de chunks LOCAL est partagé avec tarsis_3 et annonce
	# n1024, mais le service ne publie la lune que jusqu'à n64. Le garde doit redescendre
	# jusqu'au niveau publié sans émettre une seule requête pour les quatre niveaux
	# intermédiaires — sinon chaque chunk en attente les redemande à chaque frame, et le
	# journal du service se remplit de 404 sur `n1024/.../present.bin`.
	var pd := _data()
	pd.export_nside = 1024
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	rts.planet = "p"
	rts.version = "v"
	rts.base_url = "http://h"
	rts.tile_res = 8
	rts.nside_min = 1
	rts.nside_max = 64          # la lune s'arrête là
	var asked: Array[String] = []
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	rts.fetcher = func(url: String) -> Array:
		asked.append(url)
		return [200, bits] if url.ends_with("present.bin") else [404, PackedByteArray()]
	pd.remote_source = rts

	assert_false(TileResidency.request_chunk_tiles(pd, 1024, 2911 * 4096),
			"les tuiles ne sont pas encore là : le chunk est différé")
	assert_eq(asked.size(), 0, "le garde ne parle jamais au réseau depuis le thread principal")
	for ns in [1024, 512, 256, 128]:
		assert_eq(rts.presence_of(ns, 2911 * 4096), RemoteTileSource.PRESENCE_NO,
				"n%d n'est pas publié : NON, sans requête" % ns)
	assert_eq(asked.size(), 0, "et toujours rien sur le fil")
	assert_eq(rts.presence_of(64, 2911 * 16), RemoteTileSource.PRESENCE_UNKNOWN,
			"au niveau publié, en revanche, la carte du shard vaut la peine d'être lue")


func test_queueing_is_idempotent() -> void:
	# Le backlog est réexaminé à chaque frame : redemander à chaque passage saturerait la
	# file de doublons.
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	rts.nside_max = 64
	for _i in 5:
		rts.queue(64, 3)
	assert_eq(rts.stat_requested, 1, "une seule demande pour la même tuile")


# ===================================================================
# 3. Le prefetch en anneau
# ===================================================================

func _ring_source() -> RemoteTileSource:
	var rts := RemoteTileSource.new()
	rts.cache_root = CACHE
	rts.planet = "p"
	rts.version = "v"
	rts.base_url = "http://h"
	rts.tile_res = 8
	# Ce que le service publie pour ce corps, aussi large que _data() : rien au-delà de
	# nside_max ne part sur le fil — voir
	# test_a_level_the_service_does_not_publish_costs_nothing. Les pyramides n1..n4 des
	# tests d'anneau tiennent dedans.
	rts.nside_min = 1
	rts.nside_max = 64
	return rts


func _ring_data(rts: RemoteTileSource) -> PlanetData:
	# Une petite pyramide n1..n4 : trois niveaux suffisent à montrer que la boucle les
	# parcourt tous, et chaque niveau tient dans un seul shard.
	var pd := _data()
	pd.export_nside = 4
	pd.export_nside_min = 1
	pd.remote_source = rts
	return pd


## Amène les cartes de présence en cache, comme le ferait le fil de téléchargement.
func _prime(rts: RemoteTileSource, present: bool) -> void:
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF if present else 0x00)
	rts.fetcher = func(url: String) -> Array:
		return [200, bits] if url.ends_with("present.bin") else [404, PackedByteArray()]
	for ns in [1, 2, 4]:
		rts.has_tile(ns, 0)


func test_prefetch_without_a_remote_source_does_nothing() -> void:
	# Même protection que le garde : les planètes qui ne streament pas ne paient rien.
	var pd := _data()
	assert_eq(TileResidency.prefetch(pd, Vector3.UP, PackedVector3Array()), 0)


func test_prefetch_never_touches_the_network() -> void:
	# La même régression que pour le garde, et elle serait pire ici : le prefetch tourne à
	# chaque mise à jour du terrain et vise une dizaine de tuiles par niveau. Un seul
	# has_tile() bloquant sur le thread principal et le jeu retombe à 1 FPS.
	var rts := _ring_source()
	var calls := [0]
	rts.fetcher = func(_url: String) -> Array:
		calls[0] += 1
		return [404, PackedByteArray()]
	var pd := _ring_data(rts)

	assert_eq(TileResidency.prefetch(pd, Vector3.UP, PackedVector3Array()), 0,
			"présences inconnues : rien n'est mis en file")
	assert_eq(calls[0], 0, "aucune requête ne doit partir du thread principal")
	assert_eq(rts.stat_requested, 0, "aucune TUILE demandée tant que la présence est inconnue")


func test_prefetch_queues_the_centre_and_its_ring_at_every_level() -> void:
	var rts := _ring_source()
	var pd := _ring_data(rts)
	_prime(rts, true)

	var queued := TileResidency.prefetch(pd, Vector3.UP, PackedVector3Array())
	assert_eq(queued, rts.stat_requested, "tout ce qui est compté est réellement mis en file")
	# Ce qui compte n'est pas le total — un pixel HEALPix a 7 ou 8 voisins, et moins encore
	# aux coins de n1 — mais que CHAQUE niveau soit couvert, centre compris. C'est la
	# propriété qui fait qu'un chunk lointain trouve sa tuile grossière déjà là.
	var by_level := {}
	for job: Vector3i in rts._queue:
		if job.z == RemoteTileSource.JOB_TILE:
			by_level[job.y] = by_level.get(job.y, 0) + 1
	for ns in [1, 2, 4]:
		assert_true(by_level.has(ns), "le niveau n%d doit être préchargé" % ns)
		assert_gt(int(by_level.get(ns, 0)), 1,
				"n%d : le centre seul ne suffit pas, il faut l'anneau" % ns)
		assert_true(rts._queue.has(Vector3i(HEALPix.vec2pix_nest(ns, Vector3.UP), ns,
				RemoteTileSource.JOB_TILE)), "n%d : la tuile sous le joueur en fait partie" % ns)


func test_prefetch_skips_tiles_the_server_does_not_have() -> void:
	# Un pack creux ne publie pas tout : demander une tuile absente ne coûterait qu'un 404.
	var rts := _ring_source()
	var pd := _ring_data(rts)
	_prime(rts, false)
	assert_eq(TileResidency.prefetch(pd, Vector3.UP, PackedVector3Array()), 0,
			"aucune tuile publiée, aucune demande")


func test_prefetch_aims_ahead_of_a_moving_player() -> void:
	# La raison d'être du biais : à l'arrêt on ne couvre que l'anneau courant, en
	# mouvement on demande aussi là où le joueur arrive — donc strictement plus de tuiles.
	var still := _ring_source()
	var pd_still := _ring_data(still)
	_prime(still, true)
	var n_still := TileResidency.prefetch(pd_still, Vector3.UP * 1000.0, PackedVector3Array())

	var moving := _ring_source()
	var pd_moving := _ring_data(moving)
	_prime(moving, true)
	var hist := PackedVector3Array([Vector3(0, 1000, 0), Vector3(300, 1000, 0)])
	var n_moving := TileResidency.prefetch(pd_moving, Vector3.UP * 1000.0, hist)

	assert_gt(n_moving, n_still, "une seconde direction, donc davantage de tuiles")


func test_prefetch_ignores_a_history_that_shows_no_movement() -> void:
	# Caméra immobile : la direction « en avant » vaudrait la direction courante, et
	# l'anneau serait recalculé pour rien.
	var rts := _ring_source()
	var pd := _ring_data(rts)
	_prime(rts, true)
	var hist := PackedVector3Array([Vector3.UP * 1000.0, Vector3.UP * 1000.0])
	var n := TileResidency.prefetch(pd, Vector3.UP * 1000.0, hist)

	var ref := _ring_source()
	var pd_ref := _ring_data(ref)
	_prime(ref, true)
	assert_eq(n, TileResidency.prefetch(pd_ref, Vector3.UP * 1000.0, PackedVector3Array()),
			"un historique statique ne change rien")


func test_prefetch_terminates_before_the_manifest_is_read() -> void:
	# export_nside_min vaut 0 tant que le manifeste n'est pas chargé, et « ns *= 2 »
	# tournerait indéfiniment. Ce test se contente de rendre la main.
	var rts := _ring_source()
	var pd := _ring_data(rts)
	pd.export_nside_min = 0
	_prime(rts, true)
	assert_gt(TileResidency.prefetch(pd, Vector3.UP, PackedVector3Array()), 0,
			"la boucle démarre à n1 et se termine")


func test_prefetch_at_the_planet_centre_is_a_no_op() -> void:
	# normalized() d'un vecteur nul rend zéro, et vec2pix_nest en tirerait un pixel arbitraire.
	var rts := _ring_source()
	var pd := _ring_data(rts)
	_prime(rts, true)
	assert_eq(TileResidency.prefetch(pd, Vector3.ZERO, PackedVector3Array()), 0)


# ===================================================================
# 4. Le prefetch de zone (serveur)
# ===================================================================

func test_prefetch_chunks_without_a_remote_source_does_nothing() -> void:
	var pd := _data()
	assert_eq(TileResidency.prefetch_chunks(pd, [Vector2i(64, 12)]), 0,
			"une planète qui ne streame pas ne paie rien")


func test_prefetch_chunks_never_touches_the_network() -> void:
	# La même propriété que le garde, et pour la même raison : cette passe tourne sur le
	# thread principal du SERVEUR, à l'arrivée d'une zone, sur des centaines de chunks.
	# Un seul has_tile() bloquant et le tick s'effondre.
	var pd := _data()
	var rts := _ring_source()
	var calls := [0]
	rts.fetcher = func(_url: String) -> Array:
		calls[0] += 1
		return [404, PackedByteArray()]
	pd.remote_source = rts

	var chunks: Array = []
	for i in 50:
		chunks.append(Vector2i(64, i))
	assert_eq(TileResidency.prefetch_chunks(pd, chunks), 50)
	assert_eq(calls[0], 0, "aucune requête ne doit partir du thread principal")


func test_prefetch_chunks_asks_for_the_whole_zone_at_once() -> void:
	# La raison d'être de cette passe : le garde n'examine que quatre chunks par frame,
	# donc sans elle une zone neuve demanderait ses tuiles au compte-gouttes.
	var pd := _data()
	var rts := _ring_source()
	pd.remote_source = rts
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	rts.fetcher = func(url: String) -> Array:
		return [200, bits] if url.ends_with("present.bin") else [404, PackedByteArray()]
	rts.has_tile(64, 0)  # amène la carte, comme le ferait le fil

	var chunks: Array = []
	for i in 20:
		chunks.append(Vector2i(64, i))
	TileResidency.prefetch_chunks(pd, chunks)
	assert_gt(rts.stat_requested, 20,
			"bien plus d'une tuile par chunk : les voisines en font partie")


func test_prefetch_chunks_does_not_ask_twice_for_a_shared_tile() -> void:
	# Des chunks voisins partagent leurs tuiles de bord. Sans dédoublonnage, une zone de
	# plusieurs centaines de chunks demanderait neuf fois chaque tuile.
	var pd := _data()
	var rts := _ring_source()
	pd.remote_source = rts
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	rts.fetcher = func(url: String) -> Array:
		return [200, bits] if url.ends_with("present.bin") else [404, PackedByteArray()]
	rts.has_tile(64, 0)

	TileResidency.prefetch_chunks(pd, [Vector2i(64, 5)])
	var once := rts.stat_requested
	TileResidency.prefetch_chunks(pd, [Vector2i(64, 5), Vector2i(64, 5), Vector2i(64, 5)])
	assert_eq(rts.stat_requested, once, "rien de neuf à demander")


func test_prefetch_chunks_leaves_the_gate_counters_alone() -> void:
	# Ce n'est pas une décision de résidence mais une anticipation : la compter comme un
	# refus du garde rendrait le diagnostic illisible.
	var pd := _data()
	var rts := _ring_source()
	pd.remote_source = rts
	rts.fetcher = func(_url: String) -> Array: return [404, PackedByteArray()]
	PropNet.prof_gate_defer = 0
	TileResidency.prefetch_chunks(pd, [Vector2i(64, 1), Vector2i(64, 2)])
	assert_eq(PropNet.prof_gate_defer, 0)
