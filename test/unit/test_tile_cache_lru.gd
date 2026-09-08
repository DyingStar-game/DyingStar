extends GutTest
## Suite GUT pour [TileCacheLru] — la borne du cache disque de tuiles.
##
## Le cache grossissait sans limite, et le prefetch en anneau le remplit bien plus vite que
## les demandes à la carte qu'il a remplacées. Trois propriétés sont vérifiées ici :
##
##   1. Le budget est réellement tenu, et il se compte en FICHIERS. Mesuré sur l'export
##      tarsis_3 n256 : 849 Mio de données mais 2,6 Gio sur disque, parce qu'aucune tuile
##      n'atteint 4 Kio et occupe donc un bloc entier. Compter les octets de données ferait
##      consommer trois fois le budget annoncé.
##   2. Les niveaux grossiers sont épinglés. Une tuile n16 couvre 407 km de côté et sert
##      des milliers de chunks ; la laisser évincer par un déplacement au sol rendrait la
##      vue orbitale à nouveau payante.
##   3. C'est bien le moins récemment utilisé qui part.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd \
##     -gtest=res://test/unit/test_tile_cache_lru.gd -gexit

const DIR := "user://test_lru/"


func before_each() -> void:
	RemoteTileSource._remove_tree(DIR)
	DirAccess.make_dir_recursive_absolute(DIR)


func after_all() -> void:
	RemoteTileSource._remove_tree(DIR)


## Crée un fichier de tuile et rend son chemin, comme le ferait fetch_now().
func _write(nside: int, ipix: int) -> String:
	var path := "%sn%d/f0/f%d.bin" % [DIR, nside, ipix]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([1, 2, 3]))
	f.close()
	return path


func _lru(budget_tiles: int) -> TileCacheLru:
	var c := TileCacheLru.new()
	c.open(DIR)
	c.budget_tiles = budget_tiles
	return c


func _files_at(nside: int) -> int:
	var d := DirAccess.open("%sn%d/f0/" % [DIR, nside])
	return 0 if d == null else d.get_files().size()


# ===================================================================
# 1. Le budget
# ===================================================================

func test_default_budget_counts_files_not_data_bytes() -> void:
	# 128 Mio de DISQUE, à un bloc de 4 Kio par tuile. Compter les ~1,4 Kio de données
	# réelles donnerait trois fois plus de fichiers que le disque n'en supporte.
	var c := TileCacheLru.new()
	assert_eq(c.budget_tiles, 32768, "128 Mo / 4 Kio")
	c.set_budget_mb(64)
	assert_eq(c.budget_tiles, 16384)


func test_eviction_keeps_the_cache_under_budget() -> void:
	var c := _lru(10)
	for i in 40:
		c.admit(64, _write(64, i))
	assert_lte(c.size(), 10, "le budget doit être tenu")
	assert_gt(c.stat_evicted, 0, "il a bien fallu évincer")
	assert_eq(_files_at(64), c.size(), "l'index et le disque disent la même chose")


func test_eviction_leaves_headroom_instead_of_purging_to_the_brim() -> void:
	# Purger jusqu'au budget exact relancerait une éviction à chaque tuile écrite ensuite.
	var c := _lru(20)
	for i in 21:
		c.admit(64, _write(64, i))
	assert_lte(c.size(), 18, "purge jusqu'à 90 % du budget")


func test_a_zero_budget_disables_eviction() -> void:
	var c := _lru(0)
	for i in 30:
		c.admit(64, _write(64, i))
	assert_eq(_files_at(64), 30, "budget nul : rien n'est supprimé")


# ===================================================================
# 2. Les niveaux épinglés
# ===================================================================

func test_coarse_levels_are_never_evicted() -> void:
	# n1..n16, c'est la planète entière pour 16 Mo, et une vue orbitale n'émet alors
	# aucune requête. Ces tuiles ne doivent jamais être candidates.
	var c := _lru(4)
	for i in 8:
		c.admit(16, _write(16, i))
	for i in 40:
		c.admit(64, _write(64, i))
	assert_eq(_files_at(16), 8, "les tuiles n16 survivent à toute pression")
	assert_lte(_files_at(64), 4, "seules les tuiles fines paient")


func test_pinned_tiles_do_not_consume_the_budget() -> void:
	var c := _lru(10)
	for i in 50:
		c.admit(8, _write(8, i))
	assert_eq(c.size(), 0, "les niveaux épinglés ne sont même pas suivis")


# ===================================================================
# 3. L'ordre d'éviction
# ===================================================================

func test_the_least_recently_used_goes_first() -> void:
	var c := _lru(6)
	var paths := []
	for i in 6:
		paths.append(_write(64, i))
		c.admit(64, paths[i])
	# On se sert de la plus ancienne : elle ne doit plus être la première à partir.
	c.touch(64, paths[0])
	for i in range(6, 10):
		c.admit(64, _write(64, i))
	assert_true(FileAccess.file_exists(paths[0]), "la tuile réutilisée doit survivre")
	assert_false(FileAccess.file_exists(paths[1]), "la vraie plus ancienne est partie")


# ===================================================================
# 4. La persistance de l'index
# ===================================================================

func test_the_index_survives_a_restart() -> void:
	var c := _lru(100)
	var paths := []
	for i in 5:
		paths.append(_write(64, i))
		c.admit(64, paths[i])
	c.touch(64, paths[0])
	c.save()

	var c2 := _lru(4)
	assert_eq(c2.size(), 5, "les tuiles déjà en cache sont reprises en charge")
	c2.admit(64, _write(64, 99))
	assert_true(FileAccess.file_exists(paths[0]),
			"l'ordre d'usage de la session précédente est respecté")


func test_a_missing_index_falls_back_to_scanning() -> void:
	# Arrêt brutal : l'ordre est perdu, mais le budget doit rester tenu — c'est la
	# propriété qui compte.
	for i in 12:
		_write(64, i)
	var c := _lru(4)
	assert_eq(c.size(), 12, "le parcours retrouve les tuiles évinçables")
	c.admit(64, _write(64, 99))
	assert_lte(c.size(), 4, "le budget est repris en main dès la première écriture")


func test_the_index_is_not_mistaken_for_a_tile() -> void:
	# index.bin porte l'extension des tuiles : le suivre reviendrait à s'auto-évincer.
	var c := _lru(2)
	for i in 3:
		c.admit(64, _write(64, i))
	c.save()
	assert_true(FileAccess.file_exists(c.index_path()))
	var c2 := _lru(1)
	assert_false(c2._use.has("index.bin"), "index.bin n'est pas une tuile")
	c2.admit(64, _write(64, 50))
	assert_true(FileAccess.file_exists(c2.index_path()), "l'index survit à l'éviction")
