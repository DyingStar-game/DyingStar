extends GutTest
## The settings' frame: its tab row, and what stands at the end of it.

const PAGE : PackedScene = preload("res://ui/settings_page/settings_page.tscn")


## The frame rate was the first line of the Graphics tab: what an option costs could only be read on
## that one tab. It stands at the end of the tab row now, on every tab.
func test_the_frame_rate_stands_at_the_end_of_the_tab_row() -> void:
	var page : CanvasLayer = PAGE.instantiate()
	add_child_autofree(page)
	var row : HBoxContainer = page.get_node("Control/MarginContainer/VBoxContainer/TabRow")
	assert_true(row.get_child(0) is TabStrip, "the tabs first")
	var perf : PerfLabel = row.get_child(row.get_child_count() - 1) as PerfLabel
	assert_not_null(perf, "the readout last")
	assert_string_contains(perf.text, "FPS", "the frame rate")
	assert_string_contains(perf.text, "GPU", "and the GPU time")
	page.open("%%MENU_CAT_AUDIO")
	assert_true(is_instance_valid(perf) and perf.is_inside_tree(), "still there on another tab")
