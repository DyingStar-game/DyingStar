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


## PlayerClient closes the chart only while it is open (_close_navigation): told once its slot was
## hidden, the chart read as closed already and never closed -- its right click's menu stayed over the
## next tab (playtest 2026-11-18).
func test_the_chart_is_told_while_it_is_still_on_show() -> void:
	var chart := StarMap.new()
	add_child_autofree(chart)
	var tablet := TerminalUI.new()
	add_child_autofree(tablet)
	chart.host_in(tablet.navigation_slot())
	tablet.navigation_requested.connect(chart.open)
	var closed: Array[bool] = []
	tablet.navigation_closed.connect(func() -> void:
		closed.append(chart.is_open())
		if chart.is_open():
			chart.close())
	tablet.open_navigation()
	chart._gestures._press = {"action": &"star_map_menu"}  # a button held as the tab is left
	tablet._go_home()
	assert_eq(closed, [true], "asked while open: it closes")
	assert_true(chart._gestures._press.is_empty(), "its gestures and its menu go with it")


## The menu is a window: it does not hide with the face it hangs from. Whoever hides the face, it goes.
func test_the_right_click_s_menu_goes_with_the_face() -> void:
	var pair := _wire()
	var chart: StarMap = pair[0]
	var tablet: TerminalUI = pair[1]
	tablet.open_navigation()
	chart._gestures._press = {"action": &"star_map_menu"}
	tablet.navigation_slot().visible = false  # hidden behind the chart's back
	assert_true(chart._gestures._press.is_empty(), "the face off screen: gestures reset, menu hidden")
