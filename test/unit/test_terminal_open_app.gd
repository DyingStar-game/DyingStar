extends GutTest
## [method TerminalUI.open_app] is what a notification toast clicks into: the tablet opens on
## [param id] and lands on [param segment] of its tab bar, so the click lands where the player can
## act on what they were told (a friend request opens the contacts app on its requests tab). The id
## is one of [member TerminalUI.APPS] — never NAVIGATION, which has no app behind it.

var _tablet: TerminalUI


func before_each() -> void:
	_tablet = TerminalUI.new()
	add_child_autofree(_tablet)


func test_open_app_opens_the_tablet_on_that_app() -> void:
	_tablet.open_app("contacts")
	assert_true(_tablet.is_open())
	assert_eq(_tablet._active_id, "contacts")
	assert_true(_panel("contacts").visible, "its panel is the one on show")
	assert_false(_tablet.navigation_slot().visible, "not the chart")


func test_open_app_lands_on_the_asked_segment() -> void:
	_tablet.open_app("contacts", 1)
	assert_eq(_panel("contacts")._seg_index, 1, "the requests tab, where Accept / Decline are")


func test_a_negative_segment_leaves_the_app_where_it_was() -> void:
	_tablet.open_app("contacts", 1)
	_tablet.open_app("contacts", -1)
	assert_eq(_panel("contacts")._seg_index, 1, "segment < 0: whichever tab it was already showing")


func test_open_app_leaves_the_overview_behind() -> void:
	_tablet.open()
	_tablet.open_app("corporations", -1)
	assert_false(_tablet._overview.visible, "no longer home")
	assert_true(_panel("corporations").visible)


## The panel the tablet built for [param id], as the app opened it.
func _panel(id: String) -> ServicePanel:
	return _tablet._panels[id] as ServicePanel
