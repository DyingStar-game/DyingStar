extends Node
## What registering a village's pads one at a time costs (PadLevels.settle walks), headless: N pads of many
## sizes in a square, most touching, each with its measure (no relief read), as networked props bring them.
##   <godot> --headless --path . res://test/perf/pad_settle_probe.tscn [-- n=180 side=300]

const RADIUS := 6356000.0
const MPD := RADIUS * PI / 180.0


func _ready() -> void:
	var args := {}
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var n := int(args.get("n", "180"))
	var side := float(args.get("side", "300"))
	var data := PlanetData.new()
	data.radius = RADIUS
	data.max_quadtree_depth = 14
	data.relief_signature = "probe"
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	var t0 := Time.get_ticks_usec()
	for k in n:
		var rec := PadBed.record("prop:p%d" % k, rng.randf_range(0.0, side) / MPD, rng.randf_range(0.0, side) / MPD, 0.0,
				rng.randf_range(0.6, 35.0), rng.randf_range(0.6, 35.0), rng.randf_range(1.0, 8.0), 0.0)
		rec["settled"] = {"z": rng.randf_range(99.0, 101.0), "span": 0.0, "talus_m": 6.0}
		var t := Time.get_ticks_usec()
		data.register_pad(rec)
		worst = maxf(worst, (Time.get_ticks_usec() - t) / 1000.0)
	print("[PadSettle] %d pads one at a time: %.1f ms, worst %.1f ms, phases %s" % [n,
			(Time.get_ticks_usec() - t0) / 1000.0, worst, str(data.take_pad_phases())])
	get_tree().quit()
