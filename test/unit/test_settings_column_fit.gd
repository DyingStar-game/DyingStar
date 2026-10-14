extends GutTest
## Every settings tab keeps to its column, whatever the interface size. The column narrows as the
## size grows (728 px at 100 %, 600 at 120 %), and a row's caption that did not wrap made the page
## wider than it: from 105 % the page, growing both ways, lost its left side off screen.

const CATEGORIES : Array[String] = ["%%MENU_CAT_GENERAL", "%%MENU_CAT_GRAPHICS", "%%MENU_CAT_AUDIO",
		"%%MENU_CAT_CONTROLS", "%%MENU_CAT_DEBUG"]

var _saved_size : Vector2i
var _saved_scale : float


func before_each() -> void:
	_saved_size = get_tree().root.size
	_saved_scale = get_tree().root.content_scale_factor


func after_each() -> void:
	get_tree().root.size = _saved_size
	get_tree().root.content_scale_factor = _saved_scale


func test_a_long_caption_wraps_instead_of_widening_its_row() -> void:
	var line := HBoxContainer.new()
	var caption := Label.new()
	caption.text = "Menu principal animé (Tarsis 3, au prochain affichage du menu)"
	line.add_child(caption)
	var button := Button.new()
	button.custom_minimum_size.x = 200.0
	line.add_child(button)
	var value := Label.new()
	value.text = "110"
	line.add_child(value)
	var row := SettingsRow.new()
	row.add_child(line)
	add_child_autofree(row)
	await wait_process_frames(1)  # its minimum size is worked out again once the caption wraps
	assert_eq(caption.autowrap_mode, TextServer.AUTOWRAP_WORD_SMART, "the caption breaks between words")
	assert_lt(row.get_combined_minimum_size().x, 300.0, "the row asks for its controls, not its caption")
	assert_eq(value.autowrap_mode, TextServer.AUTOWRAP_OFF, "a value after the control is left whole")


func test_every_tab_fits_its_column_at_the_largest_interface_size() -> void:
	get_tree().root.size = Vector2i(1920, 1080)
	get_tree().root.content_scale_factor = UiScaleSettings.MAX
	await wait_process_frames(2)
	var page : Node = load("res://ui/settings_page/settings_page.tscn").instantiate()
	add_child_autofree(page)
	await wait_process_frames(3)
	var viewport : SubViewport = page.settings_container
	for category: String in CATEGORIES:
		page.open(category)
		await wait_process_frames(3)
		var tab : Control = viewport.get_child(viewport.get_child_count() - 1)
		var leftmost : float = 0.0
		for node: Node in tab.find_children("*", "Control", true, false):
			if (node as Control).is_visible_in_tree():
				leftmost = minf(leftmost, (node as Control).get_global_rect().position.x)
		assert_gte(leftmost, 0.0, "%s: nothing off the left of its column" % category)
