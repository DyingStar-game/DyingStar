extends GutTest
## The DataPad's NAVIGATION tab hosts the star chart's face: the tab shows a slot in the content card
## and asks for the chart (navigation_requested); leaving the tab — home, another app, the tablet
## closed — says so (navigation_closed). The tablet never reaches for the chart itself: a stand-in
## Control is hosted here.


var _tablet : TerminalUI
var _opened : int = 0
var _closed : int = 0


func before_each() -> void:
	_opened = 0
	_closed = 0
	_tablet = TerminalUI.new()
	add_child_autofree(_tablet)
	_tablet.navigation_requested.connect(func() -> void: _opened += 1)
	_tablet.navigation_closed.connect(func() -> void: _closed += 1)


func test_the_slot_is_in_the_content_card_and_hidden_until_the_tab() -> void:
	var slot : Control = _tablet.navigation_slot()
	assert_not_null(slot)
	assert_true(_tablet.is_ancestor_of(slot))
	assert_false(slot.visible, "home shows the overview, not the chart")
	_tablet.open()
	assert_false(slot.visible)
	assert_eq(_opened, 0)


func test_the_tab_shows_the_slot_and_asks_for_the_chart_once() -> void:
	var face := Control.new()
	_tablet.navigation_slot().add_child(face)
	_tablet.open_navigation()
	assert_true(_tablet.is_open())
	assert_true(face.is_visible_in_tree(), "the hosted face is on show in the slot")
	assert_eq(_opened, 1)
	_tablet.open_navigation()
	assert_eq(_opened, 1, "already on the tab: not asked again")
	assert_eq(_closed, 0)


func test_leaving_the_tab_tells_the_chart() -> void:
	_tablet.open_navigation()
	_tablet.close()
	assert_eq(_closed, 1, "the tablet closed")
	assert_false(_tablet.navigation_slot().visible)
	_tablet.open_navigation()
	assert_eq(_opened, 2)
	_tablet._go_home()
	assert_eq(_closed, 2, "home left the tab")
	_tablet.close()
	assert_eq(_closed, 2, "closing from home: nothing more to close")
