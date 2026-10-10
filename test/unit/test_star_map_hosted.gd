extends GutTest
## The chart hosted in the DataPad: its face moves into the tablet's NAVIGATION slot and is only open
## while that slot is on show — the way PlayerClient wires F2 (open the tab) and F3 (the tablet).


func _wire() -> Array:
	var chart := StarMap.new()
	add_child_autofree(chart)
	var tablet := TerminalUI.new()
	add_child_autofree(tablet)
	chart.host_in(tablet.navigation_slot())
	tablet.navigation_requested.connect(chart.open)
	tablet.navigation_closed.connect(chart.close)
	return [chart, tablet]


func test_the_face_lives_in_the_tab_and_opens_with_it() -> void:
	var pair := _wire()
	var chart: StarMap = pair[0]
	var tablet: TerminalUI = pair[1]
	assert_true(tablet.navigation_slot().is_ancestor_of(chart._surface), "the face is in the slot")
	assert_false(chart.is_open(), "hosted but the tab is not on show")
	tablet.open_navigation()
	assert_true(chart.is_open(), "the tab asked, the chart opened in it")
	assert_true(chart._surface.is_visible_in_tree())


func test_leaving_the_tab_closes_the_chart() -> void:
	var pair := _wire()
	var chart: StarMap = pair[0]
	var tablet: TerminalUI = pair[1]
	tablet.open_navigation()
	tablet._go_home()
	assert_false(chart.is_open(), "home: the chart is gone with the tab")
	assert_true(tablet.is_open(), "the tablet stays")
	tablet.open_navigation()
	tablet.close()
	assert_false(chart.is_open(), "the tablet closed: the chart with it")
