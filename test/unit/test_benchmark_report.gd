extends GutTest
## BenchmarkReport: the text a player sends. Fixed keys, one line per step, splittable by a script.


func _window(mean: float, gpu: float, extra: Dictionary = {}) -> Dictionary:
	var w : Dictionary = {"frames": 330, "fps": 1000.0 / mean, "mean": mean, "gpu": gpu, "settled": true}
	w.merge(extra, true)
	return w


func _data(end_mean: float = 20.0) -> Dictionary:
	return {
		"status": "complete",
		"header": [["gpu", [["name", "Some GPU 9000"], ["vendor", "ACME"]]], ["graphics", [["ssao", 3]]]],
		"run": {"turn_s": 6.0, "warmup_min_s": 1.5, "duration_s": 150, "focus_losses": 0},
		"results": [
			{"id": "baseline", "set": {}, "window": _window(20.0, 18.0)},
			{"id": "render_scale", "set": {"render_scale": 0.5}, "window": _window(10.0, 8.0)},
			{"id": "ssao", "set": {"ssao": 0}, "window": _window(19.0, 17.0)},
			{"id": "atmosphere_quality", "set": {"atmosphere_quality": 0}, "window": _window(12.0, 10.0, {"pipe": 3})},
			{"id": "aerial", "set": {}, "window": _window(21.0, 18.5)},
			{"id": "baseline_end", "set": {}, "window": _window(end_mean, 18.0)},
		],
		"subviewports": [{"path": "Truck/Screen", "size": "1921x1112", "update": "always", "visible": false, "gpu": 0.8},
			{"path": "Truck/RearCamera", "size": "320x200", "update": "disabled", "visible": false, "gpu": 0.0}],
	}


func _lines(text: String, prefix: String) -> PackedStringArray:
	var out : PackedStringArray = []
	for line in text.split("\n"):
		if line.begins_with(prefix):
			out.append(line)
	return out


func test_one_line_per_step_and_only_the_steps_carry_a_difference() -> void:
	var text := BenchmarkReport.format(_data())
	var steps := _lines(text, "step=")
	assert_eq(steps.size(), 6, "one line per measured step")
	assert_false(steps[0].contains("d_frame="), "the baseline is the reference")
	assert_true(steps[2].contains("d_frame=-1.00"), "SSAO saved 1 ms")
	assert_true(_lines(text, "step=aerial")[0].contains("aerial=off"), "the haze step says what it changed")


func test_every_step_line_splits_into_key_value_pairs() -> void:
	for line in _lines(BenchmarkReport.format(_data()), "step="):
		for pair in line.split(" ", false):
			assert_true(pair.contains("="), "'%s' is key=value" % pair)


func test_a_value_with_spaces_is_quoted() -> void:
	assert_true(BenchmarkReport.format(_data()).contains("name=\"Some GPU 9000\""), "the GPU name stays one token")


func test_the_summary_ranks_the_costs_and_leaves_the_probe_out() -> void:
	var summary : String = _lines(BenchmarkReport.format(_data()), "top costs")[0]
	assert_true(summary.find("atmosphere_quality") < summary.find("ssao"), "the bigger saving first")
	assert_false(summary.contains("render_scale"), "the resolution probe is not an option's cost")
	assert_false(summary.contains("aerial"), "a step that cost time saved nothing")
	assert_true(_lines(BenchmarkReport.format(_data()), "bound=")[0].contains("render_scale 50% saved 10.00 ms"),
		"the probe says how much the pixels cost")


func test_warnings() -> void:
	var calm : String = _lines(BenchmarkReport.format(_data()), "warnings:")[0]
	assert_true(calm.contains("pipelines compiled while measuring: atmosphere_quality"), "a stutter in a window")
	assert_false(calm.contains("drift"), "same settings, same numbers")
	var drifting : String = _lines(BenchmarkReport.format(_data(22.0)), "warnings:")[0]
	assert_true(drifting.contains("UNSTABLE"), "10 % apart at the end: suspect")


func test_the_report_is_never_translated_and_lists_the_screens() -> void:
	var text := BenchmarkReport.format(_data())
	assert_false(text.contains("%%"), "no translation key left in it")
	assert_eq(_lines(text, "vp path=Truck/Screen").size(), 1, "the truck's screen is listed")
	assert_eq(_lines(text, "vp path=Truck/RearCamera").size(), 0, "a disabled one is only counted")
	assert_eq(_lines(text, "disabled=1").size(), 1, "there")
	assert_true(text.begins_with("DyingStar benchmark  format=1  status=complete"), "a header a script can check")
