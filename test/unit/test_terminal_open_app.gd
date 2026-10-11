extends GutTest
## [method TerminalUI.open_app] is what a notification toast clicks into: the tablet opens on
## [param id] and lands on [param segment] of its tab bar, so the click lands where the player can
## act on what they were told (a friend request opens the contacts segment, which carries the
## requests too). The id is one of [member TerminalUI.APPS] — never NAVIGATION, which has no app.

var _tablet: TerminalUI


func before_each() -> void:
	_tablet = TerminalUI.new()
	add_child_autofree(_tablet)


func test_open_app_opens_the_tablet_on_that_app() -> void:
	_tablet.open_app("social")
	assert_true(_tablet.is_open())
	assert_eq(_tablet._active_id, "social")
	assert_true(_panel("social").visible, "its panel is the one on show")
	assert_false(_tablet.navigation_slot().visible, "not the chart")


func test_open_app_lands_on_the_asked_segment() -> void:
	_tablet.open_app("social", 1)
	assert_eq(_panel("social")._seg_index, 1, "the squad segment")


func test_a_negative_segment_leaves_the_app_where_it_was() -> void:
	_tablet.open_app("social", 1)
	_tablet.open_app("social", -1)
	assert_eq(_panel("social")._seg_index, 1, "segment < 0: whichever tab it was already showing")


func test_open_app_leaves_the_overview_behind() -> void:
	_tablet.open()
	_tablet.open_app("economy", -1)
	assert_false(_tablet._overview.visible, "no longer home")
	assert_true(_panel("economy").visible)


func test_a_mounted_section_is_shown_only_while_its_own_segment_is() -> void:
	_tablet.open()
	var social := _panel("social")
	social.goto_segment(0)
	assert_true(social.mounted_section().visible,
			"the contacts section draws in the card, not just its chrome")
	social.goto_segment(1)
	assert_false(_mounted(social, 0).visible, "contacts left with its segment")
	assert_true(_mounted(social, 1).visible, "the squad section took its place")


## The section mounted into segment [param index] of [param panel].
func _mounted(panel: ServicePanel, index: int) -> ServicePanel:
	for mount: Dictionary in panel._mounts:
		if int(mount.get("index", -1)) == index:
			return mount.get("panel") as ServicePanel
	return null


## The panel the tablet built for [param id], as the app opened it.
func _panel(id: String) -> ServicePanel:
	return _tablet._panels[id] as ServicePanel
