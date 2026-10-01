extends GutTest
## OverlayPanel: one panel class, filled with sections. Shown while one section is active and nothing
## hides it; F7-safe; a section that appears is refreshed at once; AltGr (or ALWAYS) gives the pointer.

var _gate_a : bool = true
var _gate_b : bool = false
var _hide : bool = false
var _refreshes : int = 0


func before_each() -> void:
	_gate_a = true
	_gate_b = false
	_hide = false
	_refreshes = 0
	AltGr.reset()
	AltGr.check_keyboard = false


func after_each() -> void:
	AltGr.reset()
	AltGr.check_keyboard = true


func _lines() -> PackedStringArray:
	_refreshes += 1
	return ["line %d" % _refreshes]


func _panel(edge: OverlayPanel.Edge = OverlayPanel.Edge.RIGHT) -> OverlayPanel:
	var panel := OverlayPanel.new(edge, 300.0, "", true)
	panel.setup(func() -> bool: return true, func() -> bool: return _hide)
	add_child_autofree(panel)
	return panel


func _altgr(pressed: bool) -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_ALT
	key.location = KEY_LOCATION_RIGHT
	key.pressed = pressed
	AltGr.feed(key)


func test_it_sits_on_the_edge_it_was_given() -> void:
	assert_eq(_panel(OverlayPanel.Edge.LEFT)._panel.anchor_left, 0.0, "left edge")
	assert_eq(_panel(OverlayPanel.Edge.RIGHT)._panel.anchor_left, 1.0, "right edge")


func test_shown_while_a_section_is_active_and_nothing_hides_it() -> void:
	var panel := _panel()
	var a : OverlaySection = panel.add_section(ReadoutSection.new("A", _lines, 1.0, func() -> bool: return _gate_a))
	var b : OverlaySection = panel.add_section(ReadoutSection.new("B", _lines, 1.0, func() -> bool: return _gate_b))
	panel.reevaluate()
	assert_true(panel.is_shown(), "A is active")
	assert_true(a.box.visible and not b.box.visible, "only the active section shows")
	_gate_a = false
	panel.reevaluate()
	assert_false(panel.is_shown(), "no active section: the panel hides")
	_gate_b = true
	_hide = true
	panel.reevaluate()
	assert_false(panel.is_shown(), "hidden by its caller (the pause menu)")


func test_a_section_that_appears_is_refreshed_at_once() -> void:
	var panel := _panel()
	var section : ReadoutSection = panel.add_section(ReadoutSection.new("A", _lines, 60.0))
	panel.reevaluate()
	assert_eq(_refreshes, 1, "refreshed when shown, not a period later (the F8 frame)")
	assert_eq(section.text(), "line 1", "with the provider's lines")
	section.tick(1.0)
	assert_eq(_refreshes, 1, "then only every period")
	section.tick(60.0)
	assert_eq(_refreshes, 2, "a period later")


func test_a_watched_signal_reevaluates_immediately() -> void:
	var panel := _panel()
	panel.add_section(ReadoutSection.new("B", _lines, 1.0, func() -> bool: return _gate_b))
	panel.watch(panel.visibility_changed, 0)
	panel.reevaluate()
	assert_false(panel.is_shown(), "B off")
	_gate_b = true
	panel.visibility_changed.emit()
	assert_true(panel.is_shown(), "shown in the same frame as the signal")


func test_an_f7_photo_hides_it_for_its_frame() -> void:
	var panel := _panel()
	panel.add_section(ReadoutSection.new("A", _lines, 1.0))
	panel._process(0.0)
	panel.visible = false  # what InterfaceHider.hide_all() does to every CanvasLayer
	panel._process(0.0)
	assert_false(panel.visible, "does not put itself back into the photo")
	assert_true(panel.is_shown(), "while still considering itself on")


func test_pinned_sections_stay_above_the_scroll() -> void:
	var panel := _panel()
	var pinned : OverlaySection = panel.add_section(ReadoutSection.new("P", _lines, 1.0), true)
	var body : OverlaySection = panel.add_section(ReadoutSection.new("B", _lines, 1.0))
	assert_eq(pinned.box.get_parent(), panel._header, "pinned in the header")
	assert_eq(body.box.get_parent(), panel._body, "the rest in the scrolling body")


func test_altgr_gives_the_pointer_to_every_shown_panel() -> void:
	var left := _panel(OverlayPanel.Edge.LEFT)
	left.add_section(ReadoutSection.new("A", _lines, 1.0))
	var right := _panel(OverlayPanel.Edge.RIGHT)
	right.add_section(ReadoutSection.new("A", _lines, 1.0))
	_altgr(true)
	left._process(0.0)
	right._process(0.0)
	assert_true(left.wants_pointer() and right.wants_pointer(), "one key, both panels")
	assert_true(OverlayPanel.any_wants_pointer(get_tree()), "which is what PlayerClient asks")
	_altgr(false)
	left._process(0.0)
	right._process(0.0)
	assert_false(OverlayPanel.any_wants_pointer(get_tree()), "released: back to the camera")


func test_a_widget_section_builds_once() -> void:
	var panel := _panel()
	var built : Array = []
	panel.add_section(WidgetSection.new("W", func(_owner: Node, box: VBoxContainer, _f: SettingsRowFactory) -> void:
		built.append(box)
		box.add_child(Button.new())))
	assert_eq(built.size(), 1, "built when added")
	panel.reevaluate()
	panel._process(1.0)
	assert_eq(built.size(), 1, "never rebuilt")
