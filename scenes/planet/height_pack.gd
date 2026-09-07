@tool
class_name HeightPack
extends RefCounted
## Runtime reader for dense elevation-tile packs (heights.pack, format DSHP v1)
## produced by tools/qgis/export_elevation.py.
##
## The pack holds every .r32 pyramid tile of one planet in a single file. Tiles
## are fixed-size (tile_res² float32) and dense (every ipix exists at every
## level), so no index is stored — a tile's offset is pure arithmetic:
##
##     offset(nside, ipix) = blob_start + level_base[nside] + ipix * tile_size
##
## On-disk layout (little-endian, see export_elevation.py for the authoritative spec):
##   magic      "DSHP" (4B)
##   version    u32 = 1
##   tile_res   u32
##   nside_min  u32
##   nside_max  u32
##   flags      u32 (reserved)
##   blob_start u32
##   json_len   u32 + manifest.json bytes (verbatim)
##   blob: levels ascending (nside_min … nside_max, powers of two), tiles in
##         ipix order, each tile_res²·4 bytes raw float32.
##
## Threading model — designed for WorkerThreadPool mesh/collision tasks:
##   · Coarse levels (nside ≤ preload_max_nside) are read into memory once at
##     open(); reads from them are pure slices — no I/O, no locking.
##   · Fine levels use ONE FileAccess PER CALLING THREAD (lazily opened, keyed
##     by thread id), so concurrent reads never share a file position and need
##     no mutex on the read path. A mutex guards only handle-dictionary inserts.
##   · open() and close() must run on the main thread while no worker tasks
##     are reading (PlanetTerrain drains tasks before teardown).

const MAGIC := "DSHP"
## Version la plus récente que ce lecteur ÉCRIRAIT. Il en lit d'autres : voir SUPPORTED.
const VERSION := 2
## Versions acceptées. Le bi-format n'est pas de la complaisance : un pack par planète est
## ré-exporté quand son projet QGIS l'est, donc v1 et v2 coexistent forcément pendant la
## transition. Refuser v1 rendrait illisibles d'un coup les 20 packs actuels.
const SUPPORTED := [1, 2]

## flags, v2 uniquement.
## Échantillons en uint16 plutôt qu'en float32. L'amplitude d'une planète tient dans
## 10 700 m : le float32 y offre des pas de 0,163 m, sans objet. -50 % sur le volume.
const FLAG_U16 := 1
## Pack creux : toutes les tuiles ne sont pas stockées. Une tuile fine assez proche de
## l'upsample bilinéaire de son parent n'apporte rien et est omise ; le lecteur remonte
## d'un niveau. Une carte de présence par niveau dit lesquelles existent.
const FLAG_SPARSE := 2

## Tuiles couvertes par une entrée de l'index de rang, en puissance de deux : 2^12 = 4096
## tuiles, soit 512 octets de carte à balayer au pire pour situer une tuile — contre 2 Mo
## sans index à n1024.
const RANK_BLOCK_SHIFT := 12
const RANK_BLOCK_TILES := 1 << RANK_BLOCK_SHIFT
## Levels with nside ≤ this are fully preloaded into RAM at open().
## n1…n16 for tile_res=25 is ~10 MB per planet: every far/orbit LOD read
## becomes a memory slice instead of disk I/O.
const PRELOAD_MAX_NSIDE := 16

var _path: String = ""
var _tile_res: int = 0
var _tile_size: int = 0
var _nside_min: int = 0
var _nside_max: int = 0
var _blob_start: int = 0
var _manifest: Dictionary = {}
## nside -> byte offset of that level's first tile, relative to blob_start.
var _level_base: Dictionary = {}
var _total_blob_size: int = 0
## Coarse levels (nside ≤ PRELOAD_MAX_NSIDE) as one contiguous buffer.
var _preloaded: PackedByteArray = PackedByteArray()
## Per-thread FileAccess handles: thread id -> FileAccess.
var _handles: Dictionary = {}
var _handles_mutex: Mutex = Mutex.new()

## Version du fichier ouvert, et taille d'un échantillon sur disque (2 ou 4 octets).
var _version: int = 0
var _sample_bytes: int = 4
var _sparse: bool = false
## nside -> carte de présence (1 bit par ipix), vide quand le pack est dense.
var _present: Dictionary = {}
## nside -> nombre cumulé de tuiles présentes avant chaque bloc de RANK_BLOCK_TILES.
var _rank: Dictionary = {}
## Table de popcount par octet, construite une fois : GDScript n'a pas de popcount.
static var _popcount_table: PackedByteArray = _build_popcount()


static func _build_popcount() -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(256)
	for i in 256:
		var c := 0
		var v := i
		while v > 0:
			c += v & 1
			v >>= 1
		t[i] = c
	return t


## Open a pack and parse its header. Returns true on success.
## Call from the main thread before any worker task reads tiles.
func open(res_path: String) -> bool:
	close()
	var fa := FileAccess.open(res_path, FileAccess.READ)
	if fa == null:
		return false
	if fa.get_buffer(4).get_string_from_ascii() != MAGIC:
		push_warning("HeightPack: bad magic in %s" % res_path)
		return false
	_version = fa.get_32()
	if not (_version in SUPPORTED):
		push_warning("HeightPack: unsupported version %d in %s" % [_version, res_path])
		return false
	_tile_res = fa.get_32()
	_nside_min = fa.get_32()
	_nside_max = fa.get_32()
	var flags := fa.get_32()
	# v1 n'avait pas de flags (champ réservé, toujours nul) : dense et float32.
	_sample_bytes = 2 if (_version >= 2 and (flags & FLAG_U16) != 0) else 4
	_sparse = _version >= 2 and (flags & FLAG_SPARSE) != 0
	_blob_start = fa.get_32()
	var json_len := fa.get_32()
	var manifest_txt := fa.get_buffer(json_len).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(manifest_txt)
	_manifest = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	# Taille SUR DISQUE d'une tuile. read_tile() rend toujours du float32, quoi qu'il y ait
	# sur le disque : c'est ce qui permet de changer d'encodage sans toucher un appelant.
	_tile_size = _tile_res * _tile_res * _sample_bytes

	# Cartes de présence (creux uniquement), une par niveau, juste après le manifeste.
	_present = {}
	_rank = {}
	var counts := {}
	var ns := _nside_min
	while ns <= _nside_max:
		var npix := 12 * ns * ns
		if _sparse:
			var bits := fa.get_buffer((npix + 7) >> 3)
			_present[ns] = bits
			var ranks: PackedInt32Array = _build_rank(bits, npix)
			_rank[ns] = ranks
			# Total = rang au début du dernier bloc + ce que contient ce dernier bloc.
			var last := ((npix - 1) >> RANK_BLOCK_SHIFT) << RANK_BLOCK_SHIFT
			counts[ns] = int(ranks[ranks.size() - 1]) + _popcount_range(bits, last, npix)
		else:
			counts[ns] = npix
		ns *= 2

	# Décalages de niveau : sur le NOMBRE RÉEL de tuiles, pas sur 12·nside².
	_level_base = {}
	var base := 0
	ns = _nside_min
	while ns <= _nside_max:
		_level_base[ns] = base
		base += int(counts[ns]) * _tile_size
		ns *= 2
	_total_blob_size = base
	if fa.get_length() < _blob_start + _total_blob_size:
		push_warning("HeightPack: %s truncated (%d < %d bytes)"
				% [res_path, fa.get_length(), _blob_start + _total_blob_size])
		close()
		return false

	# Preload coarse levels in one sequential read.
	var preload_end := 0
	ns = _nside_min
	while ns <= mini(_nside_max, PRELOAD_MAX_NSIDE):
		preload_end = int(_level_base[ns]) + int(counts[ns]) * _tile_size
		ns *= 2
	if preload_end > 0:
		fa.seek(_blob_start)
		_preloaded = fa.get_buffer(preload_end)

	_path = res_path
	fa.close()
	return true


func close() -> void:
	_handles_mutex.lock()
	for tid: int in _handles:
		(_handles[tid] as FileAccess).close()
	_handles.clear()
	_handles_mutex.unlock()
	_path = ""
	_manifest = {}
	_level_base = {}
	_preloaded = PackedByteArray()
	_present = {}
	_rank = {}
	_version = 0
	_sample_bytes = 4
	_sparse = false


func is_open() -> bool:
	return _path != ""


## Manifest.json embedded in the pack (same content as the loose file).
func get_manifest() -> Dictionary:
	return _manifest


## Raw tile bytes (tile_res² float32) for [param ipix] at pyramid level
## [param nside]. Empty array if out of range. Thread-safe, lock-free:
## coarse levels slice the preloaded buffer; fine levels read through a
## per-thread FileAccess handle.
func read_tile(nside: int, ipix: int) -> PackedByteArray:
	if _path == "" or not _level_base.has(nside):
		return PackedByteArray()
	if ipix < 0 or ipix >= 12 * nside * nside:
		return PackedByteArray()
	# Emplacement de la tuile DANS le niveau : son ipix quand le pack est dense, son rang
	# parmi les tuiles présentes quand il est creux, -1 quand elle n'a pas été stockée.
	var slot := slot_of(nside, ipix)
	if slot < 0:
		return PackedByteArray()
	var off: int = int(_level_base[nside]) + slot * _tile_size
	var raw: PackedByteArray
	if off + _tile_size <= _preloaded.size():
		raw = _preloaded.slice(off, off + _tile_size)
	else:
		var fa := _thread_handle()
		if fa == null:
			return PackedByteArray()
		fa.seek(_blob_start + off)
		raw = fa.get_buffer(_tile_size)
	# Le contrat rend TOUJOURS du float32, quel que soit l'encodage sur disque : c'est ce
	# qui permet de changer d'encodage sans qu'aucun appelant ne bouge.
	return raw if _sample_bytes == 4 else _widen_u16(raw)


## Le pack omet-il des tuiles ? Permet aux appelants de ne payer la remontée de niveau
## que là où elle a un sens : sur un pack dense, une tuile absente reste une anomalie.
func is_sparse() -> bool:
	return _sparse


## La tuile est-elle stockée ? Toujours vrai sur un pack dense.
## Un « non » sur un pack creux n'est pas une erreur : il signifie que le parent la
## reproduit à epsilon près et que l'appelant doit remonter d'un niveau.
func has_tile(nside: int, ipix: int) -> bool:
	return slot_of(nside, ipix) >= 0


## Rang de la tuile dans son niveau, ou -1 si elle est absente.
func slot_of(nside: int, ipix: int) -> int:
	if not _level_base.has(nside) or ipix < 0 or ipix >= 12 * nside * nside:
		return -1
	if not _sparse:
		return ipix
	var bits: PackedByteArray = _present.get(nside, PackedByteArray())
	if bits.is_empty() or ((bits[ipix >> 3] >> (ipix & 7)) & 1) == 0:
		return -1
	var ranks: PackedInt32Array = _rank[nside]
	var block := ipix >> RANK_BLOCK_SHIFT
	return int(ranks[block]) + _popcount_range(bits, block << RANK_BLOCK_SHIFT, ipix)


## uint16 normalisé -> float32 normalisé. 65535 pas sur l'amplitude d'une planète, soit
## 0,16 m sur 10 700 m : sous la résolution verticale des contours (50 m).
func _widen_u16(raw: PackedByteArray) -> PackedByteArray:
	var n := _tile_res * _tile_res
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = float(raw.decode_u16(i * 2)) / 65535.0
	return out.to_byte_array()


## Nombre de bits à 1 dans [from_bit, to_bit). Les octets pleins passent par la table ;
## les extrémités sont traitées bit à bit car 12·nside² n'est pas toujours un multiple de 8
## (n1 en compte 12).
static func _popcount_range(bits: PackedByteArray, from_bit: int, to_bit: int) -> int:
	var c := 0
	var i := from_bit
	while i < to_bit and (i & 7) != 0:
		c += (bits[i >> 3] >> (i & 7)) & 1
		i += 1
	while i + 8 <= to_bit:
		c += _popcount_table[bits[i >> 3]]
		i += 8
	while i < to_bit:
		c += (bits[i >> 3] >> (i & 7)) & 1
		i += 1
	return c


## Nombre cumulé de tuiles présentes AVANT chaque bloc de RANK_BLOCK_TILES.
static func _build_rank(bits: PackedByteArray, npix: int) -> PackedInt32Array:
	var blocks := ((npix - 1) >> RANK_BLOCK_SHIFT) + 1
	var out := PackedInt32Array()
	out.resize(blocks)
	var acc := 0
	for b in blocks:
		out[b] = acc
		acc += _popcount_range(bits, b << RANK_BLOCK_SHIFT,
				mini((b + 1) << RANK_BLOCK_SHIFT, npix))
	return out


## Lazily open (and cache) a FileAccess for the calling thread. Each thread
## owns its handle exclusively, so seek+read never interleave across threads.
func _thread_handle() -> FileAccess:
	var tid := OS.get_thread_caller_id()
	_handles_mutex.lock()
	var fa: FileAccess = _handles.get(tid)
	if fa == null:
		fa = FileAccess.open(_path, FileAccess.READ)
		if fa != null:
			_handles[tid] = fa
	_handles_mutex.unlock()
	return fa
