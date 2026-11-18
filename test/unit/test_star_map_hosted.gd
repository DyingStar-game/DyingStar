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


## Where _input carries the window's mouse buttons while a test plays the DataPad's part (WristDatapad),
## and the button as it is carried there (the window's own copy has the window's coordinates).
var _screen: SubViewport = null
var _carried: InputEventMouseButton = null


## WristDatapad's part: it reads the window's mouse AFTER the chart (it is earlier in the tree, as the
## player is before the owner's screens) and carries it into the screen's viewport -- unless the chart
## kept the event.
func _input(event: InputEvent) -> void:
	if _screen == null or _carried == null or not (event is InputEventMouseButton):
		return
	_screen.push_input(_carried.duplicate())
	get_viewport().set_input_as_handled()


## A mouse button going down or coming up in the window, at [param at] of the screen once carried.
func _window_button(button: MouseButton, pressed: bool, at: Vector2) -> void:
	_carried = InputEventMouseButton.new()
	_carried.button_index = button
	_carried.pressed = pressed
	_carried.position = at
	_carried.global_position = at
	get_tree().root.push_input(_carried.duplicate())
	_carried = null


## The DataPad's screen is a viewport of its own. The chart kept the right button's release for itself
## (its click, the menu): the screen's viewport went on believing the button held, and gave the left
## clicks that followed to whoever had the mouse -- the chart, then the last tab pressed. The tabs were
## dead after a right click (playtest 2026-11-18).
func test_a_right_click_on_the_chart_leaves_the_next_left_click_alone() -> void:
	_screen = SubViewport.new()
	_screen.size = Vector2i(800, 400)
	_screen.gui_embed_subwindows = true  # as the wrist's: the menu opens ON the screen
	add_child_autofree(_screen)
	var slot := Control.new()
	slot.size = Vector2(400, 400)
	_screen.add_child(slot)
	var beside := Button.new()  # a tab of the rail: beside the chart, in the same viewport
	beside.position = Vector2(500, 100)
	beside.size = Vector2(200, 100)
	_screen.add_child(beside)
	var chart := StarMap.new()
	add_child_autofree(chart)
	chart.host_in(slot)
	chart.open()
	await wait_process_frames(2)
	watch_signals(beside)
	_window_button(MOUSE_BUTTON_RIGHT, true, Vector2(200, 200))
	assert_false(chart._gestures._press.is_empty(), "the press reached the chart's face")
	_window_button(MOUSE_BUTTON_RIGHT, false, Vector2(200, 200))
	assert_false(chart._gestures._context.visible, "the menu waits for the release to have gone all its way")
	await wait_process_frames(1)
	assert_true(chart._gestures._context.visible, "a right click: its menu")
	_window_button(MOUSE_BUTTON_LEFT, true, Vector2(600, 150))
	_window_button(MOUSE_BUTTON_LEFT, false, Vector2(600, 150))
	assert_signal_emitted(beside, "pressed", "the left click is the button's, not the chart's")
	assert_true(chart._gestures._press.is_empty(), "and the chart took it for no gesture")
	_screen = null


func test_only_a_button_coming_up_on_a_hosted_face_is_passed_on() -> void:
	var up := InputEventMouseButton.new()
	up.pressed = false
	var down := InputEventMouseButton.new()
	down.pressed = true
	assert_true(StarMap.releases_pass_on(up, true), "the screen's viewport must hear of it")
	assert_false(StarMap.releases_pass_on(up, false), "full screen, the chart's viewport is the window's: kept")
	assert_false(StarMap.releases_pass_on(down, true), "a press is never the chart's here")
	assert_false(StarMap.releases_pass_on(InputEventMouseMotion.new(), true), "a drag's motion stays the chart's")
