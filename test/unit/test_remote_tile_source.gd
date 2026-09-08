extends GutTest
## Suite GUT pour [RemoteTileSource] — la moitié CLIENTE du format publié en phase 2.
##
## Un désaccord entre ce que tools/publish_tiles.py écrit et ce que cette classe lit ne
## lèverait aucune erreur : il rendrait du terrain faux. Les vecteurs de référence
## ci-dessous ont donc été PRODUITS PAR LE PUBLIEUR Python et figés ici — c'est ce qui
## vérifie l'accord entre les deux langages sans avoir besoin d'un serveur.
##
## Le transport est injectable ([member RemoteTileSource.fetcher]), donc toute la logique
## — URL, enveloppe, présence, cache, purge — se teste hors réseau.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_remote_tile_source.gd -gexit

const CACHE := "user://test_rts/"

## Produits par tools/publish_tiles.py : tile_blob(bytes(range(16)), compress=True).
## Incompressible, donc stockée telle quelle (flags=0).
const GOLDEN_PLAIN := [68, 83, 84, 76, 136, 226, 206, 206, 0, 0, 0, 0,
		0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
## tile_blob(b"\x2a\x00" * 24, compress=True) : deflatée (flags=1), 48 o -> 13 o.
const GOLDEN_DEFLATED := [68, 83, 84, 76, 106, 79, 61, 27, 1, 0, 0, 0,
		120, 156, 211, 98, 208, 34, 9, 2, 0, 98, 160, 3, 241]

var _served: Dictionary = {}


func _bytes(a: Array) -> PackedByteArray:
	var b := PackedByteArray()
	for v in a:
		b.append(int(v))
	return b


func before_each() -> void:
	_served.clear()
	RemoteTileSource._remove_tree(CACHE)


func after_all() -> void:
	RemoteTileSource._remove_tree(CACHE)
	RemoteTileSource._remove_tree(FLOOR_DIR)


func _fake_fetch(url: String) -> Array:
	if _served.has(url):
		return [200, _served[url]]
	return [404, PackedByteArray()]


func _source() -> RemoteTileSource:
	var s := RemoteTileSource.new()
	s.cache_root = CACHE
	s.fetcher = _fake_fetch
	return s


# ===================================================================
# 1. Enveloppe — l'accord avec le publieur Python
# ===================================================================

func test_decodes_an_uncompressed_blob_from_the_python_publisher() -> void:
	var out := RemoteTileSource.decode_envelope(_bytes(GOLDEN_PLAIN))
	assert_eq(out.size(), 16, "16 octets de charge utile")
	for i in 16:
		assert_eq(out[i], i, "octet %d" % i)


func test_decodes_a_deflated_blob_from_the_python_publisher() -> void:
	# Le cas qui compte : le deflate de zlib doit être lisible par
	# PackedByteArray.decompress_dynamic(). Deux implémentations différentes.
	var out := RemoteTileSource.decode_envelope(_bytes(GOLDEN_DEFLATED))
	assert_eq(out.size(), 48, "48 octets une fois décompressés")
	for i in 24:
		assert_eq(out[i * 2], 42, "octet pair %d" % i)
		assert_eq(out[i * 2 + 1], 0, "octet impair %d" % i)


func test_crc32_matches_zlib() -> void:
	# Godot n'expose pas de CRC32 : celui de la classe est réimplémenté, et doit rendre
	# exactement ce que zlib.crc32 rend côté publieur, sinon toute tuile est rejetée.
	var payload := _bytes(GOLDEN_PLAIN).slice(RemoteTileSource.TILE_HEADER)
	assert_eq(RemoteTileSource._crc32(payload), 3469664904,
			"CRC de bytes(range(16)) selon zlib")


func test_a_flipped_byte_is_rejected() -> void:
	var blob := _bytes(GOLDEN_PLAIN)
	blob[blob.size() - 1] = blob[blob.size() - 1] ^ 0xFF
	assert_eq(RemoteTileSource.decode_envelope(blob).size(), 0,
			"un octet corrompu doit être rejeté, pas rendu comme du relief")


func test_an_html_error_page_is_rejected() -> void:
	# Le cas réel : une page d'erreur mise en cache à la place d'une tuile.
	assert_eq(RemoteTileSource.decode_envelope(
			"<!DOCTYPE html><html>404</html>".to_utf8_buffer()).size(), 0)


func test_a_truncated_blob_is_rejected() -> void:
	assert_eq(RemoteTileSource.decode_envelope(_bytes([68, 83, 84])).size(), 0)


# ===================================================================
# 2. URL et chemins de cache
# ===================================================================

func test_urls_follow_the_published_layout() -> void:
	var s := _source()
	s.base_url = "http://h/dist"
	s.planet = "tarsis_3"
	s.version = "cafe"
	s.shard_tiles = 4096
	assert_eq(s.shard_url(256, 8195), "http://h/dist/tarsis_3/cafe/n256/f2")
	assert_eq(s.tile_url(256, 8195), "http://h/dist/tarsis_3/cafe/n256/f2/f8195.bin")


func test_cache_path_is_scoped_by_version() -> void:
	# La version dans le chemin est ce qui permet de purger une ancienne d'un simple
	# effacement de répertoire, et empêche deux versions de se mélanger.
	var s := _source()
	s.planet = "p"
	s.version = "v1"
	s.shard_tiles = 4096
	assert_string_contains(s.tile_cache_path(64, 5), "/p/v1/n64/f0/f5.bin")
	s.version = "v2"
	assert_string_contains(s.tile_cache_path(64, 5), "/p/v2/n64/f0/f5.bin")


# ===================================================================
# 3. Pointeur, présence, récupération
# ===================================================================

func _serve_pointer() -> RemoteTileSource:
	var s := _source()
	_served["http://h/dist/p/latest.json"] = JSON.stringify({
		"data_version": "cafe", "nside_min": 1, "nside_max": 64,
		"tile_res": 8, "shard_tiles": 4096}).to_utf8_buffer()
	assert_true(s.open_planet("http://h/dist", "p"), "le pointeur doit s'ouvrir")
	return s


func test_open_planet_reads_the_pointer() -> void:
	var s := _serve_pointer()
	assert_eq(s.version, "cafe")
	assert_eq(s.tile_res, 8)
	assert_eq(s.nside_max, 64)


func test_open_planet_fails_cleanly_when_the_service_is_down() -> void:
	var s := _source()
	assert_false(s.open_planet("http://h/dist", "absent"),
			"un service injoignable doit rendre false, pas laisser un état à moitié fait")


func test_presence_map_drives_has_tile() -> void:
	var s := _serve_pointer()
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0)
	bits[0] = 0b00000101          # tuiles 0 et 2 présentes
	_served["http://h/dist/p/cafe/n64/f0/present.bin"] = bits
	assert_true(s.has_tile(64, 0))
	assert_false(s.has_tile(64, 1))
	assert_true(s.has_tile(64, 2))


func test_has_tile_fetches_each_shard_map_once() -> void:
	# 512 octets renseignent sur 4096 tuiles : les redemander annulerait tout l'intérêt.
	var s := _serve_pointer()
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	var url := "http://h/dist/p/cafe/n64/f0/present.bin"
	_served[url] = bits
	assert_true(s.has_tile(64, 0))
	_served.erase(url)            # le service ne répond plus : seul le cache peut servir
	assert_true(s.has_tile(64, 7), "la carte doit être mémorisée")


func test_fetch_now_caches_and_take_reads_it_back() -> void:
	var s := _serve_pointer()
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	_served["http://h/dist/p/cafe/n64/f0/present.bin"] = bits
	_served["http://h/dist/p/cafe/n64/f0/f3.bin"] = _bytes(GOLDEN_PLAIN)

	assert_eq(s.take(64, 3).size(), 0, "rien en cache au départ")
	assert_true(s.fetch_now(64, 3), "récupération")
	var got := s.take(64, 3)
	assert_eq(got.size(), 16, "relu du cache disque")
	for i in 16:
		assert_eq(got[i], i)


func test_take_never_hits_the_network() -> void:
	# take() est appelé sur le chemin chaud : il doit rendre vide plutôt que d'attendre.
	var s := _serve_pointer()
	_served["http://h/dist/p/cafe/n64/f0/f9.bin"] = _bytes(GOLDEN_PLAIN)
	assert_eq(s.take(64, 9).size(), 0,
			"une tuile disponible côté service mais absente du cache reste vide")


func test_fetch_now_refuses_a_tile_the_presence_map_denies() -> void:
	var s := _serve_pointer()
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0)
	_served["http://h/dist/p/cafe/n64/f0/present.bin"] = bits
	_served["http://h/dist/p/cafe/n64/f0/f1.bin"] = _bytes(GOLDEN_PLAIN)
	assert_false(s.fetch_now(64, 1), "la carte fait autorité : pas de requête inutile")


func test_a_corrupted_tile_is_not_cached() -> void:
	var s := _serve_pointer()
	var bits := PackedByteArray()
	bits.resize(512)
	bits.fill(0xFF)
	_served["http://h/dist/p/cafe/n64/f0/present.bin"] = bits
	var bad := _bytes(GOLDEN_PLAIN)
	bad[bad.size() - 1] = 0
	_served["http://h/dist/p/cafe/n64/f0/f4.bin"] = bad
	assert_false(s.fetch_now(64, 4), "CRC invalide")
	assert_eq(s.take(64, 4).size(), 0, "et rien ne doit rester sur le disque")


# ===================================================================
# 4. Purge de version
# ===================================================================

func test_purge_removes_other_versions_only() -> void:
	var s := _serve_pointer()
	for v in ["old1", "old2", "cafe"]:
		var d := "%sp/%s/n1/f0/" % [CACHE, v]
		DirAccess.make_dir_recursive_absolute(d)
		var f := FileAccess.open(d + "f0.bin", FileAccess.WRITE)
		f.store_8(0)
		f.close()
	assert_eq(s.purge_other_versions(), 2, "les deux anciennes versions")
	assert_true(DirAccess.dir_exists_absolute("%sp/cafe" % CACHE), "la version en cours reste")
	assert_false(DirAccess.dir_exists_absolute("%sp/old1" % CACHE))


# ===================================================================
# Le plancher servi en un objet unique
# ===================================================================

const FLOOR_DIR := "user://test_floor/"


func _floor_src() -> RemoteTileSource:
	var rts := RemoteTileSource.new()
	rts.cache_root = FLOOR_DIR
	rts.planet = "p"
	rts.version = "v"
	rts.base_url = "http://h"
	rts.tile_res = 4
	rts.floor_nside_max = 8
	return rts


## Construit un plancher au format du publieur : en-tête, index, puis les charges utiles.
func _floor_blob(tiles: Array) -> PackedByteArray:
	var head := PackedByteArray()
	head.resize(12)
	head.encode_u32(0, RemoteTileSource.FLOOR_MAGIC)
	head.encode_u32(4, 1)
	head.encode_u32(8, tiles.size())
	var index := PackedByteArray()
	index.resize(16 * tiles.size())
	var payloads := PackedByteArray()
	var base := 12 + index.size()
	for k in tiles.size():
		var t: Dictionary = tiles[k]
		var b: PackedByteArray = t["blob"]
		index.encode_u32(16 * k, t["nside"])
		index.encode_u32(16 * k + 4, t["ipix"])
		index.encode_u32(16 * k + 8, base + payloads.size())
		index.encode_u32(16 * k + 12, b.size())
		payloads.append_array(b)
	return head + index + payloads


func _floor_tiles() -> Array:
	return [
		{"nside": 1, "ipix": 0, "blob": PackedByteArray([10, 11, 12])},
		{"nside": 1, "ipix": 5, "blob": PackedByteArray([20, 21])},
		{"nside": 8, "ipix": 700, "blob": PackedByteArray([30, 31, 32, 33])},
	]


func test_floor_explodes_into_the_tile_cache() -> void:
	# Les charges utiles sont les octets exactement servis pour une tuile isolée : on les
	# écrit tels quels, sans les décoder. Un plancher et une tuile ne peuvent pas diverger.
	RemoteTileSource._remove_tree(FLOOR_DIR)
	var rts := _floor_src()
	var tiles := _floor_tiles()
	rts.fetcher = func(_url: String) -> Array: return [200, _floor_blob(tiles)]

	assert_eq(rts.fetch_floor(), 3, "les trois tuiles doivent être écrites")
	for t: Dictionary in tiles:
		var path := rts.tile_cache_path(t["nside"], t["ipix"])
		assert_true(FileAccess.file_exists(path), "n%d f%d en cache" % [t["nside"], t["ipix"]])
		assert_eq(FileAccess.get_file_as_bytes(path), t["blob"] as PackedByteArray,
				"octets identiques à ce que servirait la tuile isolée")


func test_floor_is_fetched_once() -> void:
	# Une requête à l'approche, pas une par retour sur la planète.
	RemoteTileSource._remove_tree(FLOOR_DIR)
	var rts := _floor_src()
	var calls := [0]
	rts.fetcher = func(_url: String) -> Array:
		calls[0] += 1
		return [200, _floor_blob(_floor_tiles())]

	rts.fetch_floor()
	assert_eq(calls[0], 1)
	assert_eq(rts.fetch_floor(), 0, "le témoin doit court-circuiter le second appel")
	assert_eq(calls[0], 1, "aucune seconde requête")


func test_a_server_without_a_floor_costs_nothing() -> void:
	# Les 19 autres corps ne sont pas encore republiés : leur manifeste n'annonce pas de
	# plancher, et le client doit alors se taire et s'en tenir aux tuiles isolées.
	RemoteTileSource._remove_tree(FLOOR_DIR)
	var rts := _floor_src()
	rts.floor_nside_max = 0
	var calls := [0]
	rts.fetcher = func(_url: String) -> Array:
		calls[0] += 1
		return [200, PackedByteArray()]
	assert_eq(rts.fetch_floor(), 0)
	assert_eq(calls[0], 0, "aucune requête pour un plancher qui n'existe pas")


func test_a_truncated_floor_writes_nothing() -> void:
	# Un objet coupé en vol ne doit pas se poser à moitié dans le cache : le témoin
	# resterait alors sur un plancher à trous.
	RemoteTileSource._remove_tree(FLOOR_DIR)
	var rts := _floor_src()
	var full := _floor_blob(_floor_tiles())
	rts.fetcher = func(_url: String) -> Array: return [200, full.slice(0, full.size() / 2)]

	assert_eq(rts.fetch_floor(), 0)
	assert_false(FileAccess.file_exists(rts.floor_marker_path()),
			"pas de témoin sur un plancher illisible")
	assert_false(FileAccess.file_exists(rts.tile_cache_path(1, 0)))


func test_a_wrong_magic_is_rejected() -> void:
	# Une page d'erreur servie à la place de l'objet ne doit pas être prise pour un plancher.
	assert_eq(RemoteTileSource.decode_floor("<html>404</html>".to_utf8_buffer()).size(), 0)
	assert_eq(RemoteTileSource.decode_floor(PackedByteArray()).size(), 0)


func test_a_failed_floor_leaves_no_marker() -> void:
	RemoteTileSource._remove_tree(FLOOR_DIR)
	var rts := _floor_src()
	rts.fetcher = func(_url: String) -> Array: return [404, PackedByteArray()]
	assert_eq(rts.fetch_floor(), 0)
	assert_false(FileAccess.file_exists(rts.floor_marker_path()),
			"un échec doit pouvoir être réessayé")


func test_floor_does_not_overwrite_a_fresher_tile() -> void:
	# La tuile isolée a pu arriver avant le plancher : elle porte la même donnée, la
	# réécrire ne serait que du travail perdu.
	RemoteTileSource._remove_tree(FLOOR_DIR)
	var rts := _floor_src()
	var path := rts.tile_cache_path(1, 0)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([99]))
	f.close()
	rts.fetcher = func(_url: String) -> Array: return [200, _floor_blob(_floor_tiles())]

	assert_eq(rts.fetch_floor(), 2, "seules les deux tuiles absentes sont écrites")
	assert_eq(FileAccess.get_file_as_bytes(path), PackedByteArray([99]))


# ===================================================================
# La connexion conservée n'appartient qu'au fil de téléchargement
# ===================================================================

func test_only_the_download_thread_reuses_the_connection() -> void:
	# LA régression : un HTTPClient partagé entre deux fils se corrompt. Deux requêtes
	# entrelacées sur le même flux ont donné un signal 11 dans les entrailles de
	# HTTPClient — le plancher sondé depuis le thread principal pendant que le fil
	# téléchargeait des tuiles. Tout appelant qui n'est pas le fil reçoit donc une
	# connexion jetable, ce qui est le comportement d'origine.
	var rts := RemoteTileSource.new()
	assert_false(rts._reuses_connection(), "fil non démarré : personne ne réutilise")

	rts._worker_tid = OS.get_thread_caller_id() + 1
	assert_false(rts._reuses_connection(),
			"un autre fil que celui de téléchargement ne touche jamais à _conn")

	rts._worker_tid = OS.get_thread_caller_id()
	assert_true(rts._reuses_connection(), "le fil de téléchargement, lui, la conserve")


func test_the_worker_claims_the_connection_when_it_starts() -> void:
	var rts := RemoteTileSource.new()
	rts.cache_root = FLOOR_DIR
	assert_eq(rts._worker_tid, 0)
	rts.start()
	# start() lance le fil ; il s'inscrit dès sa première instruction.
	var t0 := Time.get_ticks_msec()
	while rts._worker_tid == 0 and Time.get_ticks_msec() - t0 < 2000:
		OS.delay_msec(5)
	assert_ne(rts._worker_tid, 0, "le fil doit s'être inscrit")
	assert_ne(rts._worker_tid, OS.get_thread_caller_id(),
			"et ce n'est pas le thread principal")
	rts.stop()


func test_crc_survives_an_uninitialised_table() -> void:
	# LA régression : l'initialiseur de variable statique n'avait pas tourné quand
	# l'éditeur a commencé à lire des tuiles. La table était vide, chaque octet indexait
	# hors bornes, le CRC était faux — et l'éditeur n'affichait aucun terrain sans que
	# rien ne désigne le CRC. La table doit se reconstruire à la demande.
	var payload := PackedByteArray([0x78, 0x9C, 0x01, 0x02, 0x03])
	var want := RemoteTileSource._crc32(payload)
	RemoteTileSource._crc_table = PackedInt64Array()
	assert_eq(RemoteTileSource._crc32(payload), want, "même CRC après table vidée")
	assert_eq(RemoteTileSource._crc_table.size(), 256, "et la table est reconstruite")


func test_an_envelope_decodes_after_the_table_was_emptied() -> void:
	# La conséquence réelle : une enveloppe valide doit se décoder, pas être rejetée.
	var payload := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	var blob := PackedByteArray()
	blob.resize(RemoteTileSource.TILE_HEADER)
	blob.encode_u32(0, RemoteTileSource.TILE_MAGIC)
	blob.encode_u32(4, RemoteTileSource._crc32(payload))
	blob.encode_u32(8, 0)
	blob.append_array(payload)
	RemoteTileSource._crc_table = PackedInt64Array()
	assert_eq(RemoteTileSource.decode_envelope(blob), payload)


func test_an_unreachable_service_returns_instead_of_spinning() -> void:
	# Les boucles d'attente de HTTPClient sont des boucles serrées sur poll(). Sans
	# échéance, un service injoignable les fait tourner indéfiniment — et comme
	# open_planet part du thread principal, cela gèle l'éditeur à l'ouverture d'une scène.
	# Le cas « accepte puis se tait » a été vérifié par sonde : rendu en 2001 ms pour une
	# échéance de 2000. Ici on couvre le cas testable partout, un port fermé.
	var rts := RemoteTileSource.new()
	rts.request_timeout_ms = 1000
	var t0 := Time.get_ticks_msec()
	var res: Array = rts._http_get("http://127.0.0.1:9/nothing")
	assert_eq(res[0], 0, "un service injoignable rend un code nul, pas une exception")
	assert_true((res[1] as PackedByteArray).is_empty())
	assert_lt(Time.get_ticks_msec() - t0, 5000, "et rend la main")


func test_the_timeout_has_a_sane_default() -> void:
	assert_between(RemoteTileSource.new().request_timeout_ms, 1000, 60000)
