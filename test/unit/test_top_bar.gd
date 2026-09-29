extends GutTest
## TabStrip / TopBar: the SQUAD-style menu bar and tabs. One entry is active at a time (amber, a line
## under it); the text is the translation, upper-cased; a press says which entry.


func test_the_active_entry_is_amber_and_underlined() -> void:
	var strip := TabStrip.new(18)
	add_child_autofree(strip)
	strip.add_entry(&"a", "%%MENU_SETTINGS")
	strip.add_entry(&"b", "%%MENU_QUIT")
	strip.set_active(&"a")
	var on : Button = strip.button(&"a")
	var off : Button = strip.button(&"b")
	assert_eq(on.get_theme_color("font_color"), SettingsStyle.ACTIVE_COLOR, "active: amber")
	assert_eq(off.get_theme_color("font_color"), SettingsStyle.INACTIVE_COLOR, "the others: white")
	assert_gt((on.get_theme_stylebox("normal") as StyleBoxFlat).border_width_bottom, 0, "a line under it")
	assert_eq((off.get_theme_stylebox("normal") as StyleBoxFlat).border_width_bottom, 0, "none under the others")
	assert_false(on.flat, "a flat button would not draw its line")


func test_an_entry_reads_its_translation_in_capitals() -> void:
	var strip := TabStrip.new(18)
	add_child_autofree(strip)
	var button : Button = strip.add_entry(&"q", "%%MENU_QUIT", "‹ ")
	assert_eq(button.text, "‹ " + tr("%%MENU_QUIT").to_upper(), "prefix, then the translation upper-cased")
	assert_false(button.text.contains("%%"), "never the raw key")


func test_a_press_names_its_entry() -> void:
	var bar := TopBar.new()
	bar.add_entry(&"settings", "%%MENU_SETTINGS")
	add_child_autofree(bar)
	watch_signals(bar)
	bar.tabs.button(&"settings").pressed.emit()
	assert_signal_emitted_with_parameters(bar, "entry_pressed", [&"settings"])


func test_the_back_entry_shows_only_when_asked() -> void:
	var bar := TopBar.new()
	add_child_autofree(bar)
	var back : Control = bar.get_node("Area/Row/Back")
	assert_false(back.visible, "no way back from the home screen")
	bar.set_back_visible(true)
	assert_true(back.visible, "shown while a sub-screen is open")
	watch_signals(bar)
	(back as TabStrip).button(&"back").pressed.emit()
	assert_signal_emitted(bar, "back_pressed")


func test_a_tooltip_is_cut_into_lines() -> void:
	var text : String = "one two three four five six seven eight nine ten"
	var wrapped : String = SettingsText.tooltip(text, 14)
	for line in wrapped.split("\n"):
		assert_lte(line.length(), 14, "no line longer than asked: '%s'" % line)
	assert_eq(wrapped.replace("\n", " "), text, "every word kept, in order")
	assert_eq(SettingsText.tooltip("a\n\nb", 14), "a\n\nb", "its own line breaks kept")
