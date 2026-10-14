extends GutTest
## The main menu's Settings, Credits and Back. From a fresh launch of an EXPORTED build they did nothing:
## the settings page the menu preloaded was caught in a load loop (settings -> Graphics tab -> menu stage
## -> this menu -> settings) and came out empty. The menu now loads the page when it is opened.

const MAIN_PAGE_SCRIPT := "res://ui/main_page/main_page.gd"


func test_the_menu_does_not_preload_the_settings() -> void:
	var source := FileAccess.get_file_as_string(MAIN_PAGE_SCRIPT)
	assert_false(source.contains("preload(\"res://ui/settings_page/"),
			"a preload here closes the loop that empties the settings in an export")
	assert_true(ResourceLoader.exists(MainPage.SETTINGS_SCENE_PATH), "the page it loads is there")


func test_settings_credits_and_back() -> void:
	var menu : MainPage = load("res://ui/main_page/main_page.tscn").instantiate()
	add_child_autofree(menu)
	for entry: StringName in [MainPage.SETTINGS, MainPage.CREDITS]:
		menu._on_entry_pressed(entry)
		assert_true(menu._settings_overlay is SettingsPage, "%s opens the settings frame" % entry)
		menu._close_settings()
		await wait_process_frames(2)
		assert_null(menu._settings_overlay, "Back closes it")
