extends GutTest
## The ring a ServiceStyle button shows while it holds the focus must be told apart from the button it
## is drawn on. The amber call to action once had an amber ring: "Send" focused showed nothing
## (playtest 2026-11-20).

const KINDS: Array[ServiceStyle.ButtonKind] = [ServiceStyle.ButtonKind.SECONDARY,
	ServiceStyle.ButtonKind.PRIMARY, ServiceStyle.ButtonKind.GHOST, ServiceStyle.ButtonKind.DANGER]


func test_the_focus_ring_is_never_the_colour_of_its_button() -> void:
	for kind: ServiceStyle.ButtonKind in KINDS:
		var button := Button.new()
		add_child_autofree(button)
		ServiceStyle.apply_button_kind(button, kind)
		var normal := button.get_theme_stylebox("normal") as StyleBoxFlat
		var focus := button.get_theme_stylebox("focus") as StyleBoxFlat
		assert_gt(focus.border_width_left, 0, "kind %d: a ring is drawn" % kind)
		assert_false(focus.border_color.is_equal_approx(normal.border_color),
				"kind %d: not the colour of the button's edge" % kind)
		assert_false(focus.border_color.is_equal_approx(normal.bg_color),
				"kind %d: not the colour of the button's fill" % kind)


func test_the_primary_ring_stands_off_the_button() -> void:
	var ring: StyleBoxFlat = ServiceStyle.focus_ring(ServiceStyle.ButtonKind.PRIMARY)
	assert_gt(ring.expand_margin_left, 0.0, "a gap of background between the amber fill and the ring")
	assert_eq(ServiceStyle.focus_ring(ServiceStyle.ButtonKind.SECONDARY).expand_margin_left, 0.0,
			"the other kinds keep the ring on their own edge")
