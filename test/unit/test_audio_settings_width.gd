extends GutTest
## The audio page keeps to its column whatever the devices are called. A device selected with a long
## name ("Microphone sur casque (CORSAIR VIRTUOSO SE Wireless Gaming Headset)") made its selector ask
## for the whole name's width: the page grew past its column and, growing both ways, lost its left side
## off screen (a 4K screen with a larger interface, where the column is narrower).

const LONG_NAME := "Microphone sur casque (CORSAIR VIRTUOSO SE Wireless Gaming Headset) - 2nd output"
## Less than the narrowest column the settings get: 920 px at 1080p, narrower with a larger interface.
const COLUMN_PX := 600.0


func test_a_long_device_name_does_not_widen_the_page() -> void:
	var page : Control = load("res://ui/settings_page/audio_page/audio_settings_page.tscn").instantiate()
	add_child_autofree(page)
	await wait_process_frames(2)
	for selector: OptionButton in [page.microphone_device, page.speaker_device]:
		selector.add_item(LONG_NAME)
		selector.select(selector.item_count - 1)  # from code: not a pick, so no device is changed
	await wait_process_frames(2)
	var content : Control = page.get_node("MarginContainer")
	assert_lt(content.get_combined_minimum_size().x, COLUMN_PX,
			"the page asks for its controls' width, not the devices' names")


func test_the_whole_name_shows_on_hover() -> void:
	var selector := OptionButton.new()
	add_child_autofree(selector)
	selector.add_item("Speakers")
	selector.add_item(LONG_NAME)
	SettingsRowFactory.fit_names(selector)
	assert_eq(selector.tooltip_text, "Speakers", "the name selected at first")
	selector.select(1)
	selector.item_selected.emit(1)  # as the player picking it
	assert_eq(selector.tooltip_text, LONG_NAME, "the name picked, whole")
	assert_true(selector.clip_text, "cut at the selector's width")
	assert_eq(selector.text_overrun_behavior, TextServer.OVERRUN_TRIM_ELLIPSIS, "with an ellipsis")
