extends GutTest
## Suite GUT pour DSHP v2 dans HeightPack : échantillons uint16 et pack creux.
##
## v2 poursuit deux buts, tous deux mesurés sur les données réelles (voir
## docs/PLANET_CHUNK_STREAMING.md, phase 1) :
##
##   · uint16 plutôt que float32 — l'amplitude d'une planète tient dans 10 700 m, où le
##     float32 offre des pas de 0,163 m. Sans objet, et -50 % de volume.
##   · pack creux — une tuile fine assez proche de l'upsample bilinéaire de son parent
##     n'apporte rien. Sondé à 75 % d'élagage à epsilon = 1 m sur tarsis_3.
##
## Le lecteur reste BI-FORMAT : un pack par planète est ré-exporté quand son projet QGIS
## l'est, donc v1 et v2 coexistent forcément. test_height_pack.gd couvre v1 ; ce fichier
## couvre v2 et vérifie que le contrat de read_tile() n'a pas bougé — il rend toujours du
## float32, quel que soit l'encodage sur disque.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_height_pack_v2.gd -gexit

const HeightPackScript := preload("res://scenes/planet/height_pack.gd")

const TILE_RES := 2
const NSIDE_MIN := 1
## n32 porte 12 288 tuiles, donc plus d'un bloc de rang (4096) : c'est ce qui exerce
## l'index. n1 en porte 12, non multiple de 8 : c'est ce qui exerce la queue de bits.
const NSIDE_MAX := 32
const DIR := "user://test_dshp_v2/"

var _levels: Array[int] = []


func before_all() -> void:
	var ns := NSIDE_MIN
	while ns <= NSIDE_MAX:
		_levels.append(ns)
		ns *= 2
	DirAccess.make_dir_recursive_absolute(DIR)


func after_all() -> void:
	var d := DirAccess.open(DIR)
	if d:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			d.remove(f)
			f = d.get_next()
		d.list_dir_end()


## Valeur normalisée d'une tuile, choisie exactement représentable en uint16 pour que les
## comparaisons soient exactes plutôt qu'approchées.
func _tile_value(nside: int, ipix: int) -> float:
	return float((nside * 7 + ipix * 13) % 65536 % 65535) / 65535.0


func _present(nside: int, ipix: int) -> bool:
	# Motif volontairement non aligné sur les octets ni sur les blocs de rang.
	return (ipix + nside) % 3 != 0


func _write(path: String, u16: bool, sparse: bool) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(f, "impossible d'écrire %s" % path)
	var manifest := JSON.stringify({"planet_name": "v2test", "tile_res": TILE_RES}).to_utf8_buffer()
	var bitmap_bytes := 0
	if sparse:
		for nside in _levels:
			bitmap_bytes += (12 * nside * nside + 7) >> 3
	var blob_start := 32 + manifest.size() + bitmap_bytes

	f.store_buffer("DSHP".to_ascii_buffer())
	f.store_32(2)
	f.store_32(TILE_RES)
	f.store_32(NSIDE_MIN)
	f.store_32(NSIDE_MAX)
	f.store_32((1 if u16 else 0) | (2 if sparse else 0))
	f.store_32(blob_start)
	f.store_32(manifest.size())
	f.store_buffer(manifest)

	if sparse:
		for nside in _levels:
			var npix := 12 * nside * nside
			var bits := PackedByteArray()
			bits.resize((npix + 7) >> 3)
			bits.fill(0)
			for ipix in npix:
				if _present(nside, ipix):
					bits[ipix >> 3] = bits[ipix >> 3] | (1 << (ipix & 7))
			f.store_buffer(bits)

	for nside in _levels:
		for ipix in 12 * nside * nside:
			if sparse and not _present(nside, ipix):
				continue
			var v := _tile_value(nside, ipix)
			for _px in TILE_RES * TILE_RES:
				if u16:
					f.store_16(int(round(v * 65535.0)))
				else:
					f.store_float(v)
	f.close()


func _open(name: String, u16: bool, sparse: bool):
	var path := DIR + name
	_write(path, u16, sparse)
	var pack = HeightPackScript.new()
	assert_true(pack.open(path), "ouverture de %s" % name)
	return pack


func _first_float(bytes: PackedByteArray) -> float:
	return bytes.to_float32_array()[0]


# ===================================================================
# uint16
# ===================================================================

func test_u16_dense_reads_every_tile() -> void:
	var pack = _open("dense_u16.pack", true, false)
	for nside in _levels:
		for ipix in [0, 3, 12 * nside * nside - 1]:
			var b: PackedByteArray = pack.read_tile(nside, ipix)
			assert_eq(b.size(), TILE_RES * TILE_RES * 4,
					"read_tile doit rendre du float32 même si le disque est en uint16")
			assert_almost_eq(_first_float(b), _tile_value(nside, ipix), 1.0 / 65535.0,
					"n%d ipix %d" % [nside, ipix])
	pack.close()


func test_u16_halves_the_stored_size() -> void:
	_write(DIR + "a_f32.pack", false, false)
	_write(DIR + "a_u16.pack", true, false)
	var f32 := FileAccess.open(DIR + "a_f32.pack", FileAccess.READ).get_length()
	var u16 := FileAccess.open(DIR + "a_u16.pack", FileAccess.READ).get_length()
	assert_lt(u16, f32, "uint16 doit être plus petit")
	# En-tête et manifeste mis à part, le blob doit exactement doubler de u16 à f32.
	var header := 32 + JSON.stringify({"planet_name": "v2test", "tile_res": TILE_RES}).length()
	assert_eq(f32 - header, 2 * (u16 - header), "le blob f32 doit peser exactement le double")


# ===================================================================
# Pack creux
# ===================================================================

func test_sparse_reads_present_tiles_and_reports_absent_ones() -> void:
	var pack = _open("sparse.pack", true, true)
	for nside in _levels:
		for ipix in 12 * nside * nside:
			var here := _present(nside, ipix)
			assert_eq(pack.has_tile(nside, ipix), here,
					"présence n%d ipix %d" % [nside, ipix])
			var b: PackedByteArray = pack.read_tile(nside, ipix)
			if here:
				assert_almost_eq(_first_float(b), _tile_value(nside, ipix), 1.0 / 65535.0,
						"valeur n%d ipix %d" % [nside, ipix])
			else:
				assert_eq(b.size(), 0, "tuile absente -> tableau vide, pas des octets faux")
	pack.close()


func test_sparse_rank_survives_block_boundaries() -> void:
	# n32 porte 12 288 tuiles, soit trois blocs de rang. Une erreur d'index ne se verrait
	# pas sur un petit niveau : elle décalerait la lecture au-delà du premier bloc.
	var pack = _open("sparse_rank.pack", true, true)
	var slot := 0
	for ipix in 12 * 32 * 32:
		if _present(32, ipix):
			assert_eq(pack.slot_of(32, ipix), slot, "rang attendu pour ipix %d" % ipix)
			slot += 1
		else:
			assert_eq(pack.slot_of(32, ipix), -1, "ipix %d est absent" % ipix)
	pack.close()


func test_sparse_handles_a_level_whose_count_is_not_a_byte_multiple() -> void:
	# n1 porte 12 tuiles : la carte de présence a une queue de 4 bits dans le dernier
	# octet, et le popcount doit s'arrêter à 12 et non à 16.
	var pack = _open("sparse_tail.pack", true, true)
	var expected := 0
	for ipix in 12:
		assert_eq(pack.slot_of(1, ipix), expected if _present(1, ipix) else -1,
				"n1 ipix %d" % ipix)
		if _present(1, ipix):
			expected += 1
	pack.close()


# ===================================================================
# Bi-format
# ===================================================================

func test_v1_float32_still_reads() -> void:
	# La raison d'être du bi-format : les 20 packs actuels sont en v1 et doivent rester
	# lisibles pendant que les planètes sont ré-exportées une par une.
	var pack = _open("legacy_v1.pack", false, false)
	# _write écrit un en-tête v2 ; on refait un vrai v1 (version=1, flags nuls).
	pack.close()
	var path := DIR + "true_v1.pack"
	var f := FileAccess.open(path, FileAccess.WRITE)
	var manifest := JSON.stringify({"planet_name": "v1test"}).to_utf8_buffer()
	f.store_buffer("DSHP".to_ascii_buffer())
	f.store_32(1)
	f.store_32(TILE_RES)
	f.store_32(NSIDE_MIN)
	f.store_32(NSIDE_MIN)
	f.store_32(0)
	f.store_32(32 + manifest.size())
	f.store_32(manifest.size())
	f.store_buffer(manifest)
	for ipix in 12:
		for _px in TILE_RES * TILE_RES:
			f.store_float(_tile_value(1, ipix))
	f.close()

	var p1 = HeightPackScript.new()
	assert_true(p1.open(path), "un pack v1 doit s'ouvrir")
	for ipix in 12:
		assert_almost_eq(_first_float(p1.read_tile(1, ipix)), _tile_value(1, ipix), 1e-6,
				"v1 ipix %d" % ipix)
		assert_true(p1.has_tile(1, ipix), "un pack dense a toutes ses tuiles")
	p1.close()


func test_unsupported_version_is_refused() -> void:
	var path := DIR + "v99.pack"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("DSHP".to_ascii_buffer())
	f.store_32(99)
	for _i in 6:
		f.store_32(0)
	f.close()
	var pack = HeightPackScript.new()
	assert_false(pack.open(path), "une version inconnue doit être refusée, pas lue de travers")
