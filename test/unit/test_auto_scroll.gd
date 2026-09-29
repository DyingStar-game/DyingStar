extends GutTest
## AutoScroll: a view whose content overflows scrolls on its own, in a loop; content that fits again
## goes back to the top and stops moving.

var _view : ScrollContainer
var _content : Control
var _auto : AutoScroll


func before_each() -> void:
	_view = ScrollContainer.new()
	_view.size = Vector2(200, 100)
	_view.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content = Control.new()
	_view.add_child(_content)
	_auto = AutoScroll.new(_content)
	_view.add_child(_auto)
	add_child_autofree(_view)


func _settle() -> void:
	for i in 3:
		await get_tree().process_frame


func test_the_overflow_is_what_does_not_fit() -> void:
	assert_eq(AutoScroll.max_scroll(80.0, 100.0), 0, "fits: nothing to scroll")
	assert_eq(AutoScroll.max_scroll(100.0, 100.0), 0, "exactly fits")
	assert_eq(AutoScroll.max_scroll(340.5, 100.0), 241, "the rest, rounded up so the last line shows")


func test_content_that_fits_does_not_move() -> void:
	_content.custom_minimum_size.y = 60.0
	await _settle()
	assert_false(_auto.is_running(), "no loop for a list that fits")
	assert_eq(_view.scroll_vertical, 0, "at the top")


func test_overflowing_content_scrolls_and_stops_once_it_fits() -> void:
	_content.custom_minimum_size.y = 400.0
	await _settle()
	assert_true(_auto.is_running(), "a long list scrolls on its own")
	_view.scroll_vertical = 50  # as if the loop had moved it
	_content.custom_minimum_size.y = 60.0
	await _settle()
	assert_false(_auto.is_running(), "the loop stops once the list fits")
	assert_eq(_view.scroll_vertical, 0, "and the view is back at the top")
