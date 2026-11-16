extends GutTest

## CharacterSheet (a character as the backend keeps it) and CharacterLibrary (the player's sheets; here its folder
## on this machine).

const FOLDER := "user://test_character_library"
const STORE := "user://test_character_library.cfg"


func before_each() -> void:
	CharacterStore.path = STORE
	CharacterStore.clear()
	CharacterLibrary.backend = CharacterLibrary.Local.new(FOLDER)
	_clear()


func after_all() -> void:
	_clear()
	CharacterStore.clear()
	CharacterStore.path = CharacterStore.PATH
	CharacterLibrary.backend = CharacterLibrary.Local.new()


func _clear() -> void:
	if not DirAccess.dir_exists_absolute(FOLDER):
		return
	for file: String in DirAccess.get_files_at(FOLDER):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FOLDER.path_join(file)))


func test_a_sheet_carries_the_look_and_what_to_filter_by() -> void:
	var look: CharacterAppearance = CharacterAppearance.random(6)
	var sheet: Dictionary = CharacterSheet.make("Ada", look)
	assert_eq(sheet["appearance_version"], CharacterDocument.VERSION)
	assert_eq(sheet["filters"]["gender"], "male")
	assert_eq(sheet["filters"]["age"], int(roundf(look.years())))
	assert_eq(sheet["filters"]["origin"], "Race_MiddleEastern")
	assert_eq(sheet["filters"]["hair"], "crest")
	var back: Dictionary = CharacterSheet.read(JSON.parse_string(JSON.stringify(sheet)))
	assert_eq(back["name"], "Ada")
	assert_eq((back["look"] as CharacterAppearance).encode(), look.encode())


func test_a_portrait_travels_as_webp() -> void:
	var image := Image.create(CharacterSheet.THUMBNAIL_SIZE, CharacterSheet.THUMBNAIL_SIZE, false, Image.FORMAT_RGB8)
	image.fill(Color(0.6, 0.4, 0.3))
	var sheet: Dictionary = CharacterSheet.make("", CharacterAppearance.random(1), image)
	assert_lt(String(sheet["thumbnail"]).length(), 20000, "small")
	var back: Image = CharacterSheet.thumbnail_of(sheet)
	assert_not_null(back)
	assert_eq(back.get_size(), image.get_size())
	assert_null(CharacterSheet.thumbnail_of({}), "none")


func test_an_upgrade_keeps_what_the_backend_added() -> void:
	var sheet: Dictionary = CharacterSheet.make("Ada", CharacterAppearance.random(3))
	sheet["id"] = "abc123"
	sheet["created_at"] = "2026-11-16T10:00:00Z"
	sheet["filters"] = {"stale": true}
	var up: Dictionary = CharacterSheet.upgrade(sheet)
	assert_eq(up["error"], "")
	assert_false(up["changed"], "already at the game's version")
	assert_eq(up["sheet"]["id"], "abc123")
	assert_eq(up["sheet"]["created_at"], "2026-11-16T10:00:00Z")
	assert_false((up["sheet"]["filters"] as Dictionary).has("stale"), "filters derived again")
	sheet["appearance"]["version"] = CharacterDocument.VERSION + 1
	var refused: Dictionary = CharacterSheet.upgrade(sheet)
	assert_string_contains(refused["error"], "newer")
	assert_eq(refused["sheet"], sheet, "a newer sheet is left as it is")


func test_sheets_are_saved_listed_fetched_and_removed() -> void:
	assert_eq(await CharacterLibrary.list(), [], "none yet")
	var first: Dictionary = await CharacterLibrary.save(CharacterSheet.make("Ada", CharacterAppearance.random(1)))
	assert_true(String(first["id"]).is_valid_hex_number(), "an id given")
	assert_true(first.has("created_at") and first.has("updated_at"))
	var second: Dictionary = await CharacterLibrary.save(CharacterSheet.make("Bob", CharacterAppearance.random(2)))
	assert_eq((await CharacterLibrary.list()).size(), 2)
	first["name"] = "Ada II"
	var again: Dictionary = await CharacterLibrary.save(first)
	assert_eq(again["id"], first["id"], "the same sheet")
	assert_eq(again["created_at"], first["created_at"])
	assert_eq((await CharacterLibrary.fetch(first["id"]))["name"], "Ada II")
	assert_eq(await CharacterLibrary.fetch("../../etc"), {}, "an id never leaves the folder")
	assert_true(await CharacterLibrary.remove(second["id"]))
	assert_false(await CharacterLibrary.remove(second["id"]), "already gone")
	assert_eq((await CharacterLibrary.list()).size(), 1)


func test_the_single_look_of_before_becomes_the_first_sheet() -> void:
	var look: CharacterAppearance = CharacterAppearance.random(9)
	CharacterStore.save_edit(look)
	var sheets: Array = await CharacterLibrary.list()
	assert_eq(sheets.size(), 1)
	assert_eq(String(sheets[0]["id"]), CharacterStore.active_id(), "and the worn one")
	assert_eq((CharacterSheet.read(sheets[0])["look"] as CharacterAppearance).encode(), look.encode())
	assert_true(CharacterStore.is_pending(), "the store keeps its own state")
	assert_eq((await CharacterLibrary.list()).size(), 1, "taken once")
