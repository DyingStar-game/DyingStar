class_name BenchmarkReport
extends RefCounted
## The benchmark's report, as plain text. English and `key=value` on purpose: it is read by the
## developers whatever the player's language, and a script can split every line. Never translated
## (no tr() here), and every number has a fixed format so two reports line up in a diff.

const FORMAT_VERSION : int = 1
## The last turn with the player's settings differs from the first by more than this: the machine
## drifted (heat, background work, people walking by) and the step differences are suspect.
const DRIFT_WARN_PCT : float = 5.0
const TOP_COSTS : int = 5
## Steps that are not the cost of one option: the two references and the resolution probe.
const _NOT_RANKED : Array[String] = [BenchmarkPlan.BASELINE, BenchmarkPlan.BASELINE_END, "render_scale"]


## [param data]:
##   status        "complete" or "cancelled"
##   header        [[section, [[key, value], …]], …] — machine, game, display, settings, place
##   run           {turn_s, warmup_min_s, duration_s, focus_losses}
##   results       [{id, set: {key: value}, window: BenchmarkStats.summary()}, …], in run order
##   subviewports  [{path, size, update, visible, gpu}, …]
static func format(data: Dictionary) -> String:
	var lines : PackedStringArray = []
	lines.append("DyingStar benchmark  format=%d  status=%s" % [FORMAT_VERSION, data.get("status", "complete")])
	for section in data.get("header", []):
		var pairs : PackedStringArray = []
		for pair in section[1]:
			pairs.append("%s=%s" % [pair[0], _value(pair[1])])
		lines.append("%s: %s" % [section[0], " ".join(pairs)])
	var run : Dictionary = data.get("run", {})
	lines.append("run: turn=360deg/%.1fs warmup>=%.1fs windows=%d duration=%ds focus_losses=%d" % [
		float(run.get("turn_s", 0.0)), float(run.get("warmup_min_s", 0.0)), data.get("results", []).size(),
		int(run.get("duration_s", 0)), int(run.get("focus_losses", 0))])
	var results : Array = data.get("results", [])
	var base : Dictionary = _window_of(results, BenchmarkPlan.BASELINE)
	lines.append("== steps (ms; d_* = change against the baseline) ==")
	for result in results:
		lines.append(step_line(result, base))
	lines.append("== summary ==")
	lines.append_array(_summary(results, base, run))
	lines.append("== subviewports (drawn on top of the root viewport, not in its gpu time) ==")
	# Only the ones that may draw: a disabled one costs nothing, and a truck brings four of them.
	var disabled : int = 0
	for vp in data.get("subviewports", []):
		if vp.get("update", "") == "disabled":
			disabled += 1
			continue
		lines.append("vp path=%s size=%s update=%s visible=%s gpu=%.2f" % [
			_value(vp.get("path", "")), vp.get("size", ""), vp.get("update", ""),
			"yes" if vp.get("visible", false) else "no", float(vp.get("gpu", 0.0))])
	lines.append("disabled=%d" % disabled)
	return "\n".join(lines) + "\n"


## One measured step as a report line; with [param base] (the baseline window), its d_* columns.
static func step_line(result: Dictionary, base: Dictionary) -> String:
	var w : Dictionary = result.get("window", {})
	var set_parts : PackedStringArray = []
	var values : Dictionary = result.get("set", {})
	for key in values:
		set_parts.append("%s=%s" % [key, _value(values[key])])
	if result.get("id", "") == BenchmarkPlan.AERIAL:
		set_parts.append("aerial=off")
	var line : String = ("step=%s set=%s frames=%d fps=%.1f mean=%.2f p50=%.2f p95=%.2f p99=%.2f low1=%.1f"
		+ " max=%.1f hitches=%d gpu=%.2f gpu_p95=%.2f cpu=%.2f setup=%.2f proc=%.2f phys=%.2f") % [
		result.get("id", "?"), ",".join(set_parts) if not set_parts.is_empty() else "-", int(w.get("frames", 0)),
		float(w.get("fps", 0.0)), float(w.get("mean", 0.0)), float(w.get("p50", 0.0)), float(w.get("p95", 0.0)),
		float(w.get("p99", 0.0)), float(w.get("low1", 0.0)), float(w.get("max", 0.0)), int(w.get("hitches", 0)),
		float(w.get("gpu", 0.0)), float(w.get("gpu_p95", 0.0)), float(w.get("cpu", 0.0)), float(w.get("setup", 0.0)),
		float(w.get("proc", 0.0)), float(w.get("phys", 0.0))]
	line += " draws=%d objs=%d prims=%d vram_mib=%d pipe=%d settle=%.1f settled=%s" % [
		int(w.get("draws", 0)), int(w.get("objects", 0)), int(w.get("primitives", 0)), int(w.get("vram_mib", 0)),
		int(w.get("pipe", 0)), float(w.get("settle_s", 0.0)), "yes" if w.get("settled", true) else "no"]
	var id : String = result.get("id", "")
	if id != BenchmarkPlan.BASELINE and not base.is_empty():
		var d : Dictionary = BenchmarkStats.delta(base, w)
		line += " d_frame=%+.2f d_gpu=%+.2f d_pct=%+.1f" % [d["d_frame"], d["d_gpu"], d["d_pct"]]
	line += " hint=%s" % BenchmarkStats.hint(w)
	return line


static func _summary(results: Array, base: Dictionary, run: Dictionary) -> PackedStringArray:
	var out : PackedStringArray = []
	if base.is_empty():
		out.append("no baseline measured")
		return out
	var bound : String = "bound=%s (baseline: frame %.2f ms, gpu %.2f ms, %.1f fps)" % [
		BenchmarkStats.hint(base), float(base.get("mean", 0.0)), float(base.get("gpu", 0.0)), float(base.get("fps", 0.0))]
	var probe : Dictionary = _window_of(results, "render_scale")
	if not probe.is_empty():
		var d : Dictionary = BenchmarkStats.delta(base, probe)
		bound += "; render_scale 50%% saved %.2f ms (%.1f%%)" % [-d["d_frame"], -d["d_pct"]]
	out.append(bound)
	var ranked : Array = []
	for result in results:
		if result.get("id", "") in _NOT_RANKED:
			continue
		var d : Dictionary = BenchmarkStats.delta(base, result.get("window", {}))
		if d["d_frame"] < 0.0:
			ranked.append({"id": result["id"], "d": d})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["d"]["d_frame"] < b["d"]["d_frame"])
	var top : PackedStringArray = []
	for i in mini(TOP_COSTS, ranked.size()):
		top.append("%d. %s %+.2f ms (%+.1f%%)" % [i + 1, ranked[i]["id"], ranked[i]["d"]["d_frame"], ranked[i]["d"]["d_pct"]])
	out.append("top costs (savings overlap, do not add them up): %s" % ("  ".join(top) if not top.is_empty() else "none"))
	out.append("warnings: %s" % _warnings(results, base, run))
	return out


static func _warnings(results: Array, base: Dictionary, run: Dictionary) -> String:
	var warnings : PackedStringArray = []
	var last : Dictionary = _window_of(results, BenchmarkPlan.BASELINE_END)
	if not last.is_empty():
		var drift : float = BenchmarkStats.delta(base, last)["d_pct"]
		if absf(drift) > DRIFT_WARN_PCT:
			warnings.append("drift=%+.1f%% UNSTABLE (the same settings measured differently at the end)" % drift)
	var compiled : PackedStringArray = []
	var unsettled : PackedStringArray = []
	for result in results:
		var w : Dictionary = result.get("window", {})
		if int(w.get("pipe", 0)) > 0:
			compiled.append(result["id"])
		if not w.get("settled", true):
			unsettled.append(result["id"])
	if not compiled.is_empty():
		warnings.append("pipelines compiled while measuring: %s" % ",".join(compiled))
	if not unsettled.is_empty():
		warnings.append("not settled: %s" % ",".join(unsettled))
	if int(run.get("focus_losses", 0)) > 0:
		warnings.append("window lost focus %d time(s)" % int(run["focus_losses"]))
	return " | ".join(warnings) if not warnings.is_empty() else "none"


static func _window_of(results: Array, id: String) -> Dictionary:
	for result in results:
		if result.get("id", "") == id:
			return result.get("window", {})
	return {}


## A value as it reads in a key=value line: quoted when it holds a space, so a line still splits on
## spaces; floats with up to three decimals.
static func _value(value: Variant) -> String:
	var text : String
	if typeof(value) == TYPE_FLOAT:
		text = String.num(value, 3)
	else:
		text = str(value)
	if text.contains(" ") or text.is_empty():
		return "\"%s\"" % text.replace("\"", "'")
	return text
