extends GutTest
## AtomicFile (scenes/planet/atomic_file.gd) : écriture par temporaire + rename, pour
## les caches partagés entre serveurs.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gdir=res://test/unit -gtest=test_atomic_file.gd

const DIR := "user://test_atomic_file/"


func before_each() -> void:
	_rm(DIR)


func after_all() -> void:
	_rm(DIR)


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f: String in d.get_files():
		d.remove(f)
	for s: String in d.get_directories():
		_rm(path.path_join(s))
	DirAccess.remove_absolute(path)


func _files(path: String) -> PackedStringArray:
	var d := DirAccess.open(path)
	return d.get_files() if d != null else PackedStringArray()


func test_temp_path_keeps_extension_and_is_unique() -> void:
	var a := AtomicFile.temp_path(DIR + "n4/f0/f12.bin")
	var b := AtomicFile.temp_path(DIR + "n4/f0/f12.bin")
	assert_true(a.ends_with(".bin"), "garde l'extension (ResourceSaver, balayage LRU)")
	assert_true(a.contains(".tmp."), a)
	assert_ne(a, b, "deux appels ne se marchent pas dessus")
	assert_eq(a.get_base_dir(), DIR + "n4/f0")


func test_write_buffer_creates_dirs_and_leaves_no_temp() -> void:
	var path := DIR + "a/b/tile.bin"
	var data := PackedByteArray([1, 2, 3, 4])
	assert_true(AtomicFile.write_buffer(path, data))
	assert_eq(FileAccess.get_file_as_bytes(path), data)
	assert_eq(_files(DIR + "a/b"), PackedStringArray(["tile.bin"]), "pas de .tmp abandonné")


func test_write_replaces_existing_content() -> void:
	var path := DIR + "v.txt"
	assert_true(AtomicFile.write_string(path, "old"))
	assert_true(AtomicFile.write_string(path, "new"))
	assert_eq(FileAccess.get_file_as_string(path), "new")
	assert_eq(_files(DIR), PackedStringArray(["v.txt"]))


func test_write_var_roundtrip() -> void:
	var path := DIR + "index.bin"
	var v := {"n32/f0/f1.bin": 3, "n32/f0/f2.bin": 7}
	assert_true(AtomicFile.write_var(path, v))
	var f := FileAccess.open(path, FileAccess.READ)
	assert_eq(f.get_var(), v)
	f.close()


func test_save_resource_roundtrip() -> void:
	var path := DIR + "chunk_lod0_col.res"
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP]))
	assert_eq(AtomicFile.save_resource(shape, path, ResourceSaver.FLAG_COMPRESS), OK)
	var back := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(back is ConcavePolygonShape3D)
	assert_eq((back as ConcavePolygonShape3D).get_faces().size(), 3)
	assert_eq(_files(DIR), PackedStringArray(["chunk_lod0_col.res"]))


func test_commit_when_other_writer_won() -> void:
	# Le temporaire a disparu (l'autre écrivain a nettoyé, ou rename a échoué) mais la
	# cible existe : c'est un succès, le contenu d'une version est immuable.
	var path := DIR + "won.bin"
	assert_true(AtomicFile.write_buffer(path, PackedByteArray([9])))
	assert_true(AtomicFile.commit(DIR + "missing.tmp.bin", path))
	assert_false(AtomicFile.commit(DIR + "missing.tmp.bin", DIR + "absent.bin"))
