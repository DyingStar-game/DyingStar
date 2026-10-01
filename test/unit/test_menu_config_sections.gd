extends GutTest
## Controls > General gathers four unrelated things (the star chart, the chat, the sound, the
## captures) and read as one long list: it is cut into titled sections.

const PAGE : PackedScene = preload("res://ui/menu_config/MenuConfig.tscn")


func test_general_is_cut_into_four_titled_sections() -> void:
	var sections : Array = MenuConfig.sections_of(MenuConfig.ACTION_GROUPS["%%KM_GROUP_GENERAL"])
	var titles : Array = sections.map(func(s: Array) -> String: return s[0])
	assert_eq(titles, ["", "%%KM_SECTION_STAR_MAP", "%%KM_SECTION_CHAT", "%%KM_SECTION_AUDIO",
			"%%KM_SECTION_GALLERY"], "pause on its own first, then the four")
	assert_true((sections[1][1] as Dictionary).has("star_map"), "the chart under its title")
	assert_true((sections[4][1] as Dictionary).has("screenshot"), "the captures under theirs")


func test_a_family_without_sections_is_one_untitled_section() -> void:
	var sections : Array = MenuConfig.sections_of(MenuConfig.ACTION_GROUPS["%%KM_GROUP_VEHICLE"])
	assert_eq(sections.size(), 1)
	assert_eq(sections[0][0], "")


func test_labels_reach_into_the_sections() -> void:
	var labels : Dictionary = MenuConfig.labels_of(MenuConfig.ACTION_GROUPS["%%KM_GROUP_GENERAL"])
	assert_eq(labels.get("pause"), "%%ACT_PAUSE")
	assert_eq(labels.get("toggle_microphone"), "%%ACT_TOGGLE_MICROPHONE")


func test_the_titles_show_on_their_tab_and_give_way_to_a_search() -> void:
	var page : MenuConfig = PAGE.instantiate()
	add_child_autofree(page)
	var general : Dictionary = page._groups[0]
	assert_eq((general["sections"] as Array).size(), 4, "four titles in General")
	var star_map_title : Label = general["sections"][0]["header"]
	assert_eq(star_map_title.text, "%%KM_SECTION_STAR_MAP")
	assert_true(star_map_title.visible, "shown on the General tab")
	page.search_bar.text = "a"
	page._refresh_visibility()
	assert_false(star_map_title.visible, "a search shows family headings, not section titles")
	page._on_tab_pressed(1)
	assert_false(star_map_title.visible, "nor on another family's tab")
