extends GutTest
## ClientPerf.bands_line: what a slow frame was made of, the dearest first, without the small change.


func test_the_dearest_comes_first_and_the_small_change_goes() -> void:
	var line := ClientPerf.bands_line({"a.gd": 2.0, "rest0": 20.5, "b.gd": 0.4, "prio+": 3.0}, 1.0)
	assert_eq(line, "rest0=20.5 prio+=3.0 a.gd=2.0")


func test_nothing_to_say() -> void:
	assert_eq(ClientPerf.bands_line({}, 1.0), "")
	assert_eq(ClientPerf.bands_line({"a.gd": 0.2}, 1.0), "")
