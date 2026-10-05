extends GutTest
## Credits: an entry of the main and pause menus right after Settings, one line per author from the generated
## list, every line reachable without a mouse.

const PAGE : PackedScene = preload("res://ui/settings_page/credits_page/credits_settings_page.tscn")
const FIXTURE_PATH : String = "user://test_credits.json"
const FIXTURE : Dictionary = {
	"music": [
		{"asset": "a_starry_night.ogg", "author": "Koothka", "source": "Discord", "id": "311230863675359232",
			"url": "", "license": "CC BY-NC-SA 4.0"},
	],
	"sfx": [
		{"asset": "button.ogg", "author": "RescopicSound", "source": "Freesound", "id": "",
			"url": "https://freesound.org/s/750433/", "license": "CC BY-NC 4.0"},
		{"asset": "door.ogg", "author": "Pierro", "source": "Discord", "id": "852633379459039302",
			"url": "", "license": "CC BY-NC-SA 4.0"},
		{"asset": "door-close.ogg", "author": "Pierro", "source": "Discord", "id": "852633379459039302",
			"url": "", "license": "CC BY-NC-SA 4.0"},
		{"asset": "button_important.ogg", "author": "RescopicSound", "source": "Freesound", "id": "",
			"url": "https://freesound.org/s/756269/", "license": "CC BY 4.0"},
	],
	"models": [],
}


func before_each() -> void:
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(FIXTURE))
	file.close()


func after_each() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_PATH))


func _page() -> CreditsSettingsPage:
	var page : CreditsSettingsPage = PAGE.instantiate()
	page.credits_path = FIXTURE_PATH
	add_child_autofree(page)
	return page


func _rows(page: Node) -> Array[SettingsRow]:
	var rows : Array[SettingsRow] = []
	for node in page.find_children("*", "SettingsRow", true, false):
		rows.append(node as SettingsRow)
	return rows


func test_the_main_menu_has_credits_between_settings_and_quit() -> void:
	var menu : CanvasLayer = load("res://ui/main_page/main_page.tscn").instantiate()
	add_child_autofree(menu)
	var tabs : TabStrip = menu.bar.tabs
	var settings : int = tabs.button(MainPage.SETTINGS).get_index()
	assert_eq(tabs.button(MainPage.CREDITS).get_index(), settings + 1, "right after Settings")
	assert_eq(tabs.button(MainPage.QUIT).get_index(), settings + 2, "right before Quit")


func test_the_pause_menu_has_credits_right_after_settings() -> void:
	var pause := PausePage.new()
	add_child_autofree(pause)
	var tabs : TabStrip = pause.bar.tabs
	assert_eq(tabs.button(PausePage.CREDITS).get_index(), tabs.button(PausePage.SETTINGS).get_index() + 1)
	assert_true(tabs.button(PausePage.CREDITS).get_index() < tabs.button(PausePage.QUIT).get_index())


## The credits open in the settings' own frame: same bar, veil and pad focus, one tab as their title.
func test_the_credits_frame_has_one_tab() -> void:
	var frame : SettingsPage = load("res://ui/settings_page/settings_page.tscn").instantiate()
	frame.show_credits = true
	add_child_autofree(frame)
	assert_eq(frame.tabs.active(), &"%%MENU_CAT_CREDITS")
	assert_false(SettingsPage.CATEGORIES.has("%%MENU_CAT_CREDITS"), "not a settings tab")
	var row : Control = frame.get_node("Control/MarginContainer/VBoxContainer/TabRow")
	assert_false(row.visible, "no tab row over the credits: they take the whole width")
	assert_false(frame.get_node("Control/MarginContainer/VBoxContainer/Body/Scenery").visible,
			"no empty share on the right: the page fills the width under the bar")


## "author   work", one line per work: two sounds by one author are two lines.
func test_one_line_per_work_under_its_section() -> void:
	var page := _page()
	assert_eq(_rows(page).size(), 5, "Koothka's tune; then four sounds")
	var headings : Array[String] = []
	for label: Label in page.find_children("*", "Label", true, false):
		if label.uppercase:
			headings.append(label.text)
	assert_eq(headings, ["%%MENU_CREDITS_SECTION_MUSIC", "%%MENU_CREDITS_SECTION_SFX"],
			"an empty section shows no heading")


## A page of plain labels could not be scrolled with the pad: nothing on it took the focus.
func test_every_line_takes_the_focus() -> void:
	var page := _page()
	for row in _rows(page):
		assert_ne(row.focus_mode, Control.FOCUS_NONE)
	assert_true(MenuFocus.first_item(page) is SettingsRow, "the first press lands on a credit line")


## The author and the work, nothing else: no Discord id, no site, no licence.
func test_a_line_is_the_author_and_the_work() -> void:
	var page := _page()
	var texts : Array[String] = []
	for label: Label in _rows(page)[0].find_children("*", "Label", true, false):
		texts.append(label.text)
	assert_eq(texts, ["Koothka", "A starry night"])


func test_lines_sorted_by_author_then_work() -> void:
	var lines : Array[Dictionary] = CreditsSettingsPage.lines_of(FIXTURE.sfx)
	assert_eq(lines.map(func(l: Dictionary) -> String: return "%s %s" % [l.author, l.work]),
			["Pierro Door", "Pierro Door close", "RescopicSound Button", "RescopicSound Button important"])


func test_work_names() -> void:
	assert_eq(CreditsSettingsPage.work_name("a_starry_night.ogg"), "A starry night")
	assert_eq(CreditsSettingsPage.work_name("truck-engine-start.ogg"), "Truck engine start")
	assert_eq(CreditsSettingsPage.work_name("metal_iron_041A_4K_*"), "Metal iron 041A 4K", "a texture set")
	assert_eq(CreditsSettingsPage.work_name("mini_truck.blend"), "Mini truck")


func test_a_missing_list_leaves_only_the_thanks() -> void:
	var page : CreditsSettingsPage = PAGE.instantiate()
	page.credits_path = "user://no_such_credits.json"
	add_child_autofree(page)
	assert_eq(_rows(page).size(), 0)


## The real list ships (export takes *.json) and has every section filled.
func test_the_generated_list_is_in_the_project() -> void:
	var credits : Dictionary = CreditsSettingsPage.load_credits(CreditsSettingsPage.CREDITS_PATH)
	for category: String in CreditsSettingsPage.SECTIONS:
		assert_false((credits.get(category, []) as Array).is_empty(), "%s has credits" % category)


func test_the_credited_music_that_exists_is_what_can_play() -> void:
	var credits : Dictionary = CreditsSettingsPage.load_credits(CreditsSettingsPage.CREDITS_PATH)
	var paths : PackedStringArray = CreditsSettingsPage.music_paths(credits)
	assert_eq(paths.size(), (credits.music as Array).size(), "every credited track is in the project")
	assert_eq(CreditsSettingsPage.music_paths(FIXTURE).size(), 0, "a credit with no path plays nothing")


## A work whose author was lost says so where the name goes — a translation key, unlike a name — and
## comes after the works whose author is known.
func test_a_lost_author_reads_owner_wanted_and_comes_last() -> void:
	var music : Array = [
		{"asset": "zeta.ogg", "author": "", "source": "Unknown", "license": "unknown"},
		{"asset": "alpha.ogg", "author": "Koothka", "source": "Discord"},
	]
	var lines : Array[Dictionary] = CreditsSettingsPage.lines_of(music)
	assert_eq(lines.map(func(l: Dictionary) -> bool: return l.owner_wanted), [false, true])
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({"music": music}))
	file.close()
	var caption : Label = _rows(_page())[1].find_children("*", "Label", true, false)[0]
	assert_eq(caption.text, "%%MENU_CREDITS_OWNER_WANTED")
	assert_ne(caption.auto_translate_mode, Node.AUTO_TRANSLATE_MODE_DISABLED, "the key is translated")


## Every track in the project has a play button, and only tracks do. Pressed, it plays that track over
## the drawn one; pressed again, the drawn one comes back.
func test_a_track_plays_from_its_line_and_stops() -> void:
	var page : CreditsSettingsPage = PAGE.instantiate()
	add_child_autofree(page)
	var drawn : MusicPlaylist = MusicDirector.override()
	var credits : Dictionary = CreditsSettingsPage.load_credits(CreditsSettingsPage.CREDITS_PATH)
	var playable : Array = CreditsSettingsPage.lines_of(credits.music).filter(
			func(l: Dictionary) -> bool: return ResourceLoader.exists(l.path))
	var toggles : Array[Node] = page.find_children("*", "PlayToggle", true, false)
	assert_eq(toggles.size(), playable.size(), "one button per track line, none on sounds or models")
	var path : String = playable[0].path
	page.toggle_track(path)
	assert_eq(MusicDirector.override().tracks[0].resource_path, path)
	assert_eq(toggles.filter(func(t: PlayToggle) -> bool: return t.playing).size(), 1, "only its button stops")
	page.toggle_track(path)
	assert_eq(MusicDirector.override(), drawn, "the drawn track again")
	assert_true(toggles.all(func(t: PlayToggle) -> bool: return not t.playing))


## The pad and the keyboard reach every track: "accept" on a focused track line plays it.
func test_accept_on_a_track_line_plays_it() -> void:
	var page : CreditsSettingsPage = PAGE.instantiate()
	add_child_autofree(page)
	var drawn : MusicPlaylist = MusicDirector.override()
	var toggle : PlayToggle = page.find_children("*", "PlayToggle", true, false)[0]
	var row : Node = toggle
	while not row is SettingsRow:
		row = row.get_parent()
	var accept := InputEventAction.new()
	accept.action = &"ui_accept"
	accept.pressed = true
	(row as SettingsRow).gui_input.emit(accept)
	assert_true(toggle.playing)
	assert_ne(MusicDirector.override(), drawn)


## The page's track wins over the place's music while it is open, and lets go when it closes.
func test_the_music_is_handed_back_on_close() -> void:
	var page : CreditsSettingsPage = PAGE.instantiate()
	add_child(page)
	var music : MusicPlaylist = MusicDirector.override()
	assert_not_null(music, "a credited track asked for")
	assert_eq(music.tracks.size(), 1, "one track, drawn at random: only that one is loaded")
	remove_child(page)
	page.free()
	assert_null(MusicDirector.override(), "the place decides the music again")
