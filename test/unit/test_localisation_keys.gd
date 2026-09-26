extends GutTest
## The translation table and the keys the game actually uses, checked against each other.
##
## Nothing errors when these two drift apart. A key nobody translated renders as "%%SOMETHING" on
## screen — visible, but only to whoever opens that screen in that language. A key translated but no
## longer used just rots in the table. And a format string whose translation lost a "%s" does not
## fail to compile: it throws at runtime, in front of the player, in one language only.
##
## So this pinches both ends: every key used exists, every key declared is used, both languages are
## filled, and their placeholders agree.

const CSV_PATH := "res://tools/localization/localisation.csv"
## Where player-facing text lives. "res://" whole would also walk .godot/ and addons/, whose vendored
## code is none of our business.
const SCAN_ROOTS : PackedStringArray = ["res://ui", "res://scenes", "res://server", "res://assets"]
## A key is %% followed by SHOUTING_SNAKE_CASE. Matches both `text = "%%FOO"` in a scene and
## `tr("%%FOO")` in a script, which is the whole point: one rule for both halves.
const KEY_PATTERN := "%%[A-Z][A-Z0-9_]*"
## A printf-style hole, once the escaped "%%" have been taken out of the way.
const PLACEHOLDER_PATTERN := "%[0-9.*+-]*[sdfxXcv]"
## Below this, the walk found nothing and every check would pass for the wrong reason.
const MIN_FILES_SCANNED := 50

## key -> {"en": String, "fr": String}, in file order.
var _table : Dictionary = {}
## key -> the first file that uses it, so a failure names somewhere to look.
var _used : Dictionary = {}
var _files_scanned : int = 0


func before_all() -> void:
	_table = _read_table()
	for root in SCAN_ROOTS:
		_scan_dir(root)


func test_the_walk_actually_read_the_project() -> void:
	# Guard for every other test here: a silent zero would make them all pass on an empty set.
	assert_gt(_files_scanned, MIN_FILES_SCANNED,
			"scanned %d files — the scan roots are wrong" % _files_scanned)
	assert_gt(_table.size(), 0, "the translation table is empty")


func test_every_used_key_is_translated() -> void:
	var missing : Array[String] = []
	for key in _used:
		if not _table.has(key):
			missing.append("%s (used in %s)" % [key, _used[key]])
	assert_eq(missing, [] as Array[String],
			"these keys are shown to players but absent from localisation.csv")


func test_every_translated_key_is_used() -> void:
	var orphans : Array[String] = []
	for key in _table:
		if not _used.has(key):
			orphans.append(key)
	assert_eq(orphans, [] as Array[String],
			"these keys are translated but nothing uses them — drop them or wire them up")


func test_english_and_french_are_both_filled() -> void:
	var holes : Array[String] = []
	for key in _table:
		for lang in ["en", "fr"]:
			if str(_table[key][lang]).strip_edges() == "":
				holes.append("%s.%s" % [key, lang])
	assert_eq(holes, [] as Array[String], "empty translations render as the raw key on screen")


func test_placeholders_agree_between_languages() -> void:
	var mismatched : Array[String] = []
	for key in _table:
		var en : Array = _placeholders(str(_table[key]["en"]))
		var fr : Array = _placeholders(str(_table[key]["fr"]))
		# Order may legitimately differ between languages; the SET of holes may not.
		en.sort()
		fr.sort()
		if en != fr:
			mismatched.append("%s: en=%s fr=%s" % [key, en, fr])
	assert_eq(mismatched, [] as Array[String],
			"a translation that lost or gained a %-hole throws at runtime, not at compile time")


## Read the CSV through get_csv_line so quoted fields holding a comma survive.
func _read_table() -> Dictionary:
	var out : Dictionary = {}
	var file := FileAccess.open(CSV_PATH, FileAccess.READ)
	assert_not_null(file, "cannot open " + CSV_PATH)
	if file == null:
		return out
	var header := file.get_csv_line()
	var en_col := Array(header).find("en")
	var fr_col := Array(header).find("fr")
	assert_gt(en_col, -1, "the CSV needs an 'en' column")
	assert_gt(fr_col, -1, "the CSV needs a 'fr' column")
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() <= maxi(en_col, fr_col) or row[0].strip_edges() == "":
			continue
		out[row[0]] = {"en": row[en_col], "fr": row[fr_col]}
	file.close()
	return out


func _scan_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := path.path_join(entry)
		if dir.current_is_dir():
			_scan_dir(full)
		# .tres as well as .gd and .tscn. A resource carries keys just as legitimately as a script
		# does — the star chart pairs a kind of place with its picture AND its wording in a .tres —
		# and a key the walk cannot see is reported as unused, which is a failure for the wrong
		# reason and teaches people to delete a key that is in fact in service.
		elif entry.ends_with(".gd") or entry.ends_with(".tscn") or entry.ends_with(".tres"):
			_collect_keys(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _collect_keys(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	_files_scanned += 1
	var text := file.get_as_text()
	file.close()
	var re := RegEx.create_from_string(KEY_PATTERN)
	for m in re.search_all(text):
		var key := m.get_string()
		if not _used.has(key):
			_used[key] = path


## The %-holes in a format string. "%%" is an escaped percent, not a hole, so it goes first.
func _placeholders(text: String) -> Array:
	var re := RegEx.create_from_string(PLACEHOLDER_PATTERN)
	var out : Array = []
	for m in re.search_all(text.replace("%%", "")):
		out.append(m.get_string())
	return out
