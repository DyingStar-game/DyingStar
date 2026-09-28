extends GutTest
## The dev clock (+ / -) is this client's alone: while it is shifted a red banner must say so — the offset
## included — and be gone once the clock is back.

var _saved_offset: float = 0.0


func before_each() -> void:
	_saved_offset = Globals.debug_time_offset


func after_each() -> void:
	Globals.debug_time_offset = _saved_offset


func _banner() -> DevClockWarning:
	var banner: DevClockWarning = add_child_autofree(DevClockWarning.new())
	banner._process(0.0)
	return banner


func test_hidden_while_the_clock_is_the_server_s() -> void:
	Globals.debug_time_offset = 0.0
	assert_false(_banner().visible)


func test_shown_with_the_offset_while_shifted() -> void:
	Globals.debug_time_offset = 12.0 * 3600.0
	var banner: DevClockWarning = _banner()
	assert_true(banner.visible)
	assert_string_contains(banner.text, "+12.0")
	assert_false(banner.text.begins_with("%%"), "translated, not the raw key")


func test_gone_again_once_the_clock_is_back() -> void:
	Globals.debug_time_offset = -3.0 * 3600.0
	var banner: DevClockWarning = _banner()
	assert_true(banner.visible)
	Globals.debug_time_offset = 0.0
	banner._process(0.0)
	assert_false(banner.visible)
