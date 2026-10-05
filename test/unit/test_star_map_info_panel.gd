extends GutTest
## The chart's info panel (a body's or a POI's card) sits in the top-right corner, and moves left by the
## width of the debug panel while that one shows (DevOverlay calls set_right_inset on every open and
## close). It was written as a position, measured from the LEFT edge once in the tree: the panel went
## off screen the first time the chart opened, and no card ever showed again.


func test_the_info_panel_stays_in_the_top_right_corner() -> void:
	var chart := StarMap.new()
	add_child_autofree(chart)
	var panel: Control = chart._info_panel
	var screen_w: float = chart.get_viewport().get_visible_rect().size.x
	for inset: float in [0.0, 400.0, 0.0, 400.0, 0.0]:
		chart.set_right_inset(inset)
		assert_almost_eq(panel.get_global_rect().position.x, screen_w + StarMap.INFO_PANEL_X - inset, 0.5,
				"left edge with a %d px inset" % int(inset))
		assert_almost_eq(panel.get_global_rect().size.x, panel.custom_minimum_size.x, 0.5, "its width kept")
