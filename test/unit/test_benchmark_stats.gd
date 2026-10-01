extends GutTest
## BenchmarkStats and PerfMath: what one measuring window boils down to.


func test_percentiles_on_the_edges() -> void:
	var series := PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 5.0])
	assert_eq(PerfMath.percentile(series, 0.0), 1.0, "the minimum")
	assert_eq(PerfMath.percentile(series, 0.5), 3.0, "the median")
	assert_eq(PerfMath.percentile(series, 1.0), 5.0, "the maximum")
	assert_eq(PerfMath.percentile(PackedFloat32Array(), 0.5), 0.0, "nothing measured, no crash")


func test_a_known_series() -> void:
	var stats := BenchmarkStats.new()
	for i in 99:
		stats.add_frame(10.0, {"gpu": 8.0, "proc": 1.0})
	stats.add_frame(100.0, {"gpu": 8.0, "proc": 1.0})
	stats.finish({"draws": 1200})
	var w := stats.summary()
	assert_eq(w["frames"], 100, "every frame counted")
	assert_almost_eq(w["mean"], 10.9, 0.001, "mean frame")
	assert_eq(w["p50"], 10.0, "median")
	assert_eq(w["max"], 100.0, "the long one")
	assert_eq(w["hitches"], 1, "one frame over 50 ms")
	assert_almost_eq(w["low1"], 10.0, 0.001, "the slowest 1 % ran at 10 fps")
	assert_almost_eq(w["gpu"], 8.0, 0.001, "mean GPU time")
	assert_eq(w["draws"], 1200, "the window's counters come along")


func test_an_empty_window_reads_as_zeros() -> void:
	var w := BenchmarkStats.new().summary()
	assert_eq(w["frames"], 0, "no frame")
	assert_eq(w["mean"], 0.0, "no time")
	assert_eq(BenchmarkStats.hint(w), "n/a", "and no verdict")


func test_what_held_the_frame_back() -> void:
	assert_eq(BenchmarkStats.hint({"mean": 18.0, "gpu": 16.0}), "gpu", "the card fills the frame")
	assert_eq(BenchmarkStats.hint({"mean": 18.0, "gpu": 5.0, "proc": 18.0}), "not_gpu",
		"well short of it: not the card (the process monitor, which counts the wait, is not a verdict)")
	assert_eq(BenchmarkStats.hint({"mean": 18.0, "gpu": 13.0}), "mixed", "in between")
	assert_eq(BenchmarkStats.hint({"mean": 18.0, "gpu": 0.0}), "n/a", "no GPU time reported")


func test_a_step_that_saves_time_reads_negative() -> void:
	var d := BenchmarkStats.delta({"mean": 20.0, "gpu": 16.0}, {"mean": 15.0, "gpu": 11.0})
	assert_eq(d["d_frame"], -5.0, "5 ms saved")
	assert_eq(d["d_gpu"], -5.0, "on the card")
	assert_eq(d["d_pct"], -25.0, "a quarter of the frame")
