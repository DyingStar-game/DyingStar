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
