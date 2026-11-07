extends GutTest
## The in-world screens' shared widgets: the one-line chip filter with its searchable "…" list
## (ChipPicker), the screen saver (ScreenAttract), the hover every branded button answers with
## (AresBrand.hover_of), and the sort orders that turn round (MissionQuery).

## The world screen script (it has no class_name).
const GUI_3D := preload("res://scenes/interactables/gui_3d.gd")
const OPTIONS: Array = [
	{"value": "mining", "text": "Minage"},
	{"value": "delivery", "text": "Livraison"},
	{"value": "exploration", "text": "Exploration géologique"},
]


func test_search_ignores_case_and_accents_and_wants_every_word() -> void:
	assert_true(ChipPicker.matches("Relevés géologiques du canyon", "geo CANY"))
	assert_true(ChipPicker.matches("Écoles", "eco"))
	assert_false(ChipPicker.matches("Livraison", "liv minage"), "every word must be found")
	assert_true(ChipPicker.matches("Livraison", ""), "nothing typed: everything")


func test_pressing_the_chosen_chip_again_unchooses_it() -> void:
	var picker := ChipPicker.new()
	add_child_autofree(picker)
	var got: Array = []
	picker.chosen.connect(func(v: String) -> void: got.append(v))
	picker.set_options(OPTIONS)
	picker._toggle("delivery")
	assert_eq(picker.selected, "delivery")
	picker._toggle("delivery")
	assert_eq(picker.selected, "", "the same chip again: no filter")
	assert_eq(got, ["delivery", ""])


func test_a_narrow_line_shows_the_chosen_chip_first_then_more() -> void:
	var picker := ChipPicker.new()
	add_child_autofree(picker)
	picker.selected = "exploration"
	picker.set_options(OPTIONS)
	picker.size = Vector2(260, 44)
	picker._relayout()
	var texts: Array = picker.get_children().map(func(c: Node) -> String: return (c as Button).text)
	assert_eq(texts[0], "Exploration géologique", "the chosen one first")
	assert_eq(texts[-1], ChipPicker.MORE, "the rest behind \"…\"")
	assert_lt(texts.size(), OPTIONS.size() + 1, "not all of them fit")
	var right: float = 0.0
	for chip: Control in picker.get_children():
		assert_gte(chip.position.x, right, "%s does not lie over the one before" % (chip as Button).text)
		if not (chip as Button).clip_text:
			assert_almost_eq(chip.size.x, chip.get_combined_minimum_size().x, 0.5, "as wide as its text")
		right = chip.position.x + chip.size.x
	assert_lte(right, picker.size.x, "nothing past the line's end")
	picker.size = Vector2(4000, 44)
	picker._relayout()
	assert_eq(picker.get_child_count(), OPTIONS.size(), "all of them fit: no \"…\"")


func test_the_list_narrows_as_one_types_and_enter_takes_the_first() -> void:
	var picker := ChipPicker.new()
	add_child_autofree(picker)
	picker.set_options(OPTIONS)
	picker._open_list()
	assert_eq(picker._rows.get_child_count(), 3)
	picker._search.text = "liv"
	picker._fill_list()
	assert_eq(picker._rows.get_child_count(), 1)
	assert_true(picker.is_typing(), "its search field has the keyboard")
	picker._choose_first()
	assert_eq(picker.selected, "delivery")
	assert_null(picker._list, "a choice closes the list")


func test_the_screen_saver_wakes_on_a_press_and_sleeps_when_left_alone() -> void:
	var attract := ScreenAttract.new().setup(AresBrand.Subsidiary.CORP, "%%MISSION_KIOSK_TITLE")
	add_child_autofree(attract)
	assert_true(attract.visible, "asleep at first")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	attract._gui_input(press)
	assert_true(attract.is_loading(), "a press unlocks it: the ring fills first")
	assert_true(attract.visible, "still covering the screen while it loads")
	attract._gui_input(press)
	attract._process(ScreenAttract.LOAD_S * 0.5)
	assert_true(attract.visible, "a second press does not start it over, nor skip it")
	attract._process(ScreenAttract.LOAD_S * 0.5 + 0.01)
	assert_false(attract.visible, "loaded: the screen is at hand")
	attract._process(ScreenAttract.IDLE_S * 0.5)
	assert_false(attract.visible, "still in use")
	attract._process(ScreenAttract.IDLE_S)
	assert_true(attract.visible, "left alone: asleep again")


func test_a_sleeping_screen_only_moves_near_the_camera_and_in_its_view() -> void:
	var machine := Node3D.new()
	add_child_autofree(machine)
	var viewport := SubViewport.new()
	machine.add_child(viewport)
	var attract := ScreenAttract.new().setup(AresBrand.Subsidiary.CORP, "%%MISSION_KIOSK_TITLE")
	viewport.add_child(attract)
	var pattern: FacetPattern = attract._pattern
	assert_false(pattern.is_processing(), "nobody has looked yet")

	var camera := Camera3D.new()  # looks down -Z
	add_child_autofree(camera)
	camera.make_current()
	machine.global_position = Vector3(0.0, 0.0, -ScreenAttract.ANIMATE_RANGE_M * 0.5)
	attract._update_seen()
	assert_true(pattern.is_processing(), "near and in view: it moves")
	machine.global_position = Vector3(0.0, 0.0, -ScreenAttract.ANIMATE_RANGE_M * 2.0)
	attract._update_seen()
	assert_false(pattern.is_processing(), "in view but too far")
	machine.global_position = Vector3(0.0, 0.0, ScreenAttract.ANIMATE_RANGE_M * 0.5)
	attract._update_seen()
	assert_false(pattern.is_processing(), "near but behind the camera")


func test_a_screen_with_no_camera_stands_still_and_one_not_in_3d_moves() -> void:
	var machine := Node3D.new()
	add_child_autofree(machine)
	var viewport := SubViewport.new()
	machine.add_child(viewport)
	var in_world := ScreenAttract.new().setup(AresBrand.Subsidiary.CORP, "%%MISSION_KIOSK_TITLE")
	viewport.add_child(in_world)
	var flat := ScreenAttract.new().setup(AresBrand.Subsidiary.CORP, "%%MISSION_KIOSK_TITLE")
	add_child_autofree(flat)
	var current: Camera3D = get_viewport().get_camera_3d()
	if current != null:
		current.clear_current()
	in_world._update_seen()
	flat._update_seen()
	assert_false(in_world._pattern.is_processing(), "the dedicated server's case: nobody is looking")
	assert_true(flat._pattern.is_processing(), "not in a 3D world: the screen is on show as it is")


func test_a_paused_pattern_takes_up_where_it_stopped() -> void:
	var pattern := FacetPattern.new()
	add_child_autofree(pattern)
	pattern.drift = 0.5
	assert_true(pattern.is_processing())
	pattern._process(1.0)
	pattern.paused = true
	assert_false(pattern.is_processing())
	assert_almost_eq(pattern._t, 1.0, 0.001, "no time passes while nobody looks")
	pattern.paused = false
	assert_true(pattern.is_processing())
	pattern.drift = 0.0
	assert_false(pattern.is_processing(), "still, whatever paused says")


func test_every_button_lights_up_under_the_pointer() -> void:
	for fill: Color in [Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.0), Color(1.0, 0.4, 0.0), Color(1, 1, 1, 1)]:
		var lit: Color = AresBrand.hover_of(fill)
		assert_ne(lit, fill, "%s changes when hovered" % fill)
		if fill.a >= 0.5 and fill.get_luminance() > 0.85:
			assert_lt(lit.v, fill.v, "white cannot get lighter: it darkens")
		else:
			assert_true(lit.a >= fill.a and lit.v >= fill.v - 0.001, "otherwise towards lighter")


func test_each_order_has_its_own_direction_and_turns_round() -> void:
	assert_eq(MissionQuery.arrow(MissionQuery.Sort.REWARD, false), "↓", "best paid first")
	assert_eq(MissionQuery.arrow(MissionQuery.Sort.EXPIRY, false), "↑", "soonest due first")
	assert_eq(MissionQuery.arrow(MissionQuery.Sort.REWARD, true), "↑")
	var a := {"id": "a", "rewards": [{"type": "credits", "amount": 10}]}
	var b := {"id": "b", "rewards": [{"type": "credits", "amount": 20}]}
	assert_eq(MissionQuery.apply([a, b], "", "", MissionQuery.Sort.REWARD, true), [a, b])


func test_a_world_screen_renders_only_near_the_camera_and_in_its_view() -> void:
	var gui: Node3D = GUI_3D.new()
	var viewport := SubViewport.new()
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	gui.add_child(viewport)
	gui.add_child(quad)
	gui.node_viewport = viewport
	gui.node_quad = quad
	add_child_autofree(gui)
	var camera := Camera3D.new()  # looks down -Z
	add_child_autofree(camera)
	camera.make_current()
	var range_m: float = gui.render_range_m
	gui.global_position = Vector3(0.0, 0.0, -range_m * 0.5)
	gui._process(1.0)
	assert_eq(viewport.render_target_update_mode, SubViewport.UPDATE_ALWAYS, "near and in view: live")
	gui.global_position = Vector3(0.0, 0.0, -range_m * 3.0)
	gui._process(1.0)
	assert_eq(viewport.render_target_update_mode, SubViewport.UPDATE_ONCE, "too far: one last picture")
	gui.global_position = Vector3(0.0, 0.0, range_m * 0.5)
	gui._process(1.0)
	assert_eq(viewport.render_target_update_mode, SubViewport.UPDATE_ONCE, "behind the camera: still")


func test_a_screen_that_drives_its_own_viewport_is_left_alone() -> void:
	var gui: Node3D = GUI_3D.new()
	var viewport := SubViewport.new()
	gui.add_child(viewport)
	gui.node_viewport = viewport
	gui.render_when_seen = false
	add_child_autofree(gui)
	assert_false(gui.is_processing(), "the truck's dashboard, the wrist: their owners decide")
