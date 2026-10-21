class_name MovementProbe
extends RefCounted
## Where the owner's on-foot movement stutters, in the log (client.ini debug_move_probe=true). The body
## has no client prediction: the server moves it, its positions arrive at the network rate and
## NetInterpolator glides the body after them. A felt "mini cut" is then one of:
##  - net   : a position came late (a gap well over the usual one): the body ran out of target and stopped;
##  - jump  : one position stepped much further than the others (a burst after a gap, or a correction);
##  - back  : the target went back against the way it was going, keys held (the server put us back);
##  - stall : keys held, the body suddenly drawn much slower than it had been moving;
##  - frame : the frame itself was long (the [CPerf] hitch lines say why);
##  - snap  : the interpolation was reset (a reparent: a new frame).
## Each one is printed at once as a "[MoveHitch]" line (with the time since boot, to match what was felt),
## and every PERIOD_S a "[MoveProbe]" line sums the period up. Pure: fed by PlayerClient and the network
## code, it never reads the scene, so it is tested on its own (test_movement_probe).
##
## The same line also measures the stream's cadence: how many positions a second really arrive while we
## walk (keys held the whole gap: the server sends nothing standing still), how regular they are
## (percentiles, spread, histogram) and how many came in the same frame as the one before (packets that
## waited, then caught up). client.ini debug_move_probe_csv=true also writes every position to
## user://logs/move_probe_<date>.csv, to plot the stream afterwards without a print per packet.
##
## Each position may come with the clocks of its trip (unix ms): the game server's simulation time
## (servergodot_ms), Horizon's on receiving it (horizon_received_ms) and on sending it to us
## (horizon_sent_ms). The line then splits the trip: the server's own cadence, Godot -> Horizon, the time
## spent in Horizon (its rate limiter included).

const PERIOD_S: float = 2.0
## A gap between two positions this many times the usual one is a hole in the stream...
const GAP_FACTOR: float = 2.5
## ...as long as it is at least this long (ms): a 30 Hz stream wobbling by a frame is not a hole.
const GAP_MIN_MS: float = 60.0
## One position this much further (m) than the one before: a jump, not a step.
const JUMP_M: float = 1.0
## Keys held and the body drawn under this share of its recent speed: a stall...
const STALL_SHARE: float = 0.3
## ...once it had been moving at least this fast (m/s), which a walk always is.
const STALL_MIN_SPEED: float = 1.0
## A frame this long (ms) is a hitch of its own.
const FRAME_HITCH_MS: float = 50.0
## Hitch lines printed per period at most: a long freeze must not flood the log.
const MAX_LINES: int = 12
## How fast the usual gap and speed follow the stream (share per sample).
const EMA: float = 0.1
## Upper bounds (ms) of the cadence histogram's buckets, the last bucket is everything above: 30 Hz lands
## in the second one, 15 Hz in the third.
const HIST_MS: PackedFloat32Array = [25.0, 45.0, 80.0, 120.0]

var _last_target := Vector3.ZERO
var _last_step := Vector3.ZERO
var _last_target_us: int = -1
var _gap_ms_usual: float = 0.0
var _last_shown := Vector3.ZERO
var _has_shown := false
var _speed_usual: float = 0.0
var _keys_held := false
var _pending: PackedStringArray = []

# The period's sums.
var _age: float = 0.0
var _updates: int = 0
var _gap_max_ms: float = 0.0
var _gap_sum_ms: float = 0.0
var _step_max_m: float = 0.0
var _lag_sum_m: float = 0.0
var _lag_max_m: float = 0.0
var _frames: int = 0
var _frame_max_ms: float = 0.0
var _cam_min := Vector3.INF  # the camera pivot (body frame) while the keys are held: its swing
var _cam_max := -Vector3.INF
var _keys_frames: int = 0
var _counts: Dictionary = {}  # kind -> how many this period
var _lines: int = 0
var _gaps: PackedFloat32Array = []  # the period's gaps (ms) walked through: the cadence samples
var _pauses: int = 0  # gaps left out of the cadence: keys released at some point during them
var _same_frame: int = 0  # positions drawn from the socket in the same frame as the one before
var _server_gaps: PackedFloat32Array = []  # the server clock's step between two walked positions (ms)
var _to_horizon: PackedFloat32Array = []  # horizon_received_ms - servergodot_ms (ms)
var _in_horizon: PackedFloat32Array = []  # horizon_sent_ms - horizon_received_ms (ms)
var _last_clocks := PackedFloat64Array([-1.0, -1.0, -1.0])

var _last_frame_idx: int = -1  # process frame of the last position
var _keys_all_gap := true  # keys held on every frame since the last position
var _last_frame_us: int = -1
var _last_frame_ms: float = 0.0
var _csv: FileAccess = null


## true when client.ini asks for the probe.
static func wanted() -> bool:
	return ClientConfig.get_bool("debug_move_probe", false)


## true when client.ini also asks for the raw CSV of every position.
static func csv_wanted() -> bool:
	return ClientConfig.get_bool("debug_move_probe_csv", false)


## Writes every position from now on to [param path] (default: user://logs/move_probe_<date>.csv), one
## line each; flushed with every period line. Returns the path, or "" when the file cannot be opened.
func open_csv(path: String = "") -> String:
	if path.is_empty():
		DirAccess.make_dir_recursive_absolute("user://logs")
		path = "user://logs/move_probe_%s.csv" % Time.get_datetime_string_from_system().replace(":", "-")
	_csv = FileAccess.open(path, FileAccess.WRITE)
	if _csv == null:
		return ""
	_csv.store_line("t_us,gap_ms,step_m,cadence,same_frame,frame_ms_last,keys,servergodot_ms,horizon_received_ms,"
			+ "horizon_sent_ms")
	return path


## A position from the server (the owner's, local to its frame), at [param usec] (Time.get_ticks_usec),
## drawn from the socket in process frame [param frame] (Engine.get_process_frames, -1 when unknown), with
## [param clocks] (servergodot_ms, horizon_received_ms, horizon_sent_ms; -1 or missing when not sent).
func on_target(local_pos: Vector3, usec: int, frame: int = -1,
		clocks: PackedFloat64Array = PackedFloat64Array()) -> void:
	var clk := PackedFloat64Array([-1.0, -1.0, -1.0])
	for i: int in mini(clocks.size(), 3):
		clk[i] = clocks[i]
	if clk[0] >= 0.0 and clk[1] >= 0.0:
		_to_horizon.append(clk[1] - clk[0])
	if clk[1] >= 0.0 and clk[2] >= 0.0:
		_in_horizon.append(clk[2] - clk[1])
	var same_frame: bool = frame >= 0 and frame == _last_frame_idx
	if same_frame:
		_same_frame += 1
	_last_frame_idx = frame
	if _last_target_us >= 0:
		var gap_ms: float = float(usec - _last_target_us) / 1000.0
		var step: Vector3 = local_pos - _last_target
		_updates += 1
		_gap_sum_ms += gap_ms
		_gap_max_ms = maxf(_gap_max_ms, gap_ms)
		_step_max_m = maxf(_step_max_m, step.length())
		# Only a gap walked through end to end says how often the server sends: keys released, it sends
		# nothing, and the gap is a pause.
		if _keys_all_gap:
			_gaps.append(gap_ms)
			var server_gap: float = clk[0] - _last_clocks[0]
			if clk[0] >= 0.0 and _last_clocks[0] >= 0.0 and server_gap > 0.0 and server_gap <= 1000.0:
				_server_gaps.append(server_gap)
		else:
			_pauses += 1
		if _csv != null:
			_csv.store_line("%d,%.2f,%.3f,%d,%d,%.1f,%d,%d,%d,%d" % [usec, gap_ms, step.length(), int(_keys_all_gap),
					int(same_frame), _last_frame_ms, int(_keys_held), int(clk[0]), int(clk[1]), int(clk[2])])
		# Standing still, the server sends nothing (only what changes): the gap that ends a stop is a
		# pause, not a hole. Only a stream that was moving can have one.
		var moving: bool = _last_step.length() > 0.02
		if moving and _gap_ms_usual > 0.0 and gap_ms > maxf(GAP_MIN_MS, _gap_ms_usual * GAP_FACTOR):
			_event("net", usec, "gap %.0f ms (usual %.0f)" % [gap_ms, _gap_ms_usual])
		if step.length() > JUMP_M:
			_event("jump", usec, "%.2f m in one position, after %.0f ms" % [step.length(), gap_ms])
		elif _keys_held and step.dot(_last_step) < 0.0 and _last_step.length() > 0.02 and step.length() > 0.02:
			_event("back", usec, "%.2f m back against the way it went" % step.length())
		_gap_ms_usual = gap_ms if _gap_ms_usual == 0.0 else lerpf(_gap_ms_usual, minf(gap_ms, 250.0), EMA)
		_last_step = step
	_last_target = local_pos
	_last_target_us = usec
	_keys_all_gap = _keys_held
	_last_clocks = clk


## The interpolation was reset (a reparent): the next position is in another frame, [param frame].
func on_snap(usec: int, frame: String = "") -> void:
	_event("snap", usec, "interpolation reset, new frame %s" % frame)
	_last_target_us = -1
	_last_step = Vector3.ZERO
	_has_shown = false
	_last_clocks = PackedFloat64Array([-1.0, -1.0, -1.0])


## A drawn frame: the body [param shown_pos] (local, after the interpolation), [param delta_s] long,
## [param keys_held] when a move key is down. Returns the lines to print now (hitches, and the period's
## summary once it is over), most often none.
func on_frame(shown_pos: Vector3, delta_s: float, keys_held: bool, usec: int) -> PackedStringArray:
	_keys_held = keys_held
	if not keys_held:
		_keys_all_gap = false
	_frames += 1
	# Measured from the clock, not from delta_s: the engine caps delta, which would hide the long frames.
	var frame_ms: float = delta_s * 1000.0
	if _last_frame_us >= 0 and usec > _last_frame_us:
		frame_ms = float(usec - _last_frame_us) / 1000.0
	_last_frame_us = usec
	_last_frame_ms = frame_ms
	_frame_max_ms = maxf(_frame_max_ms, frame_ms)
	if frame_ms > FRAME_HITCH_MS:
		_event("frame", usec, "%.0f ms frame" % frame_ms)
	if keys_held:
		_keys_frames += 1
	if _last_target_us >= 0:
		var lag: float = shown_pos.distance_to(_last_target)
		_lag_sum_m += lag
		_lag_max_m = maxf(_lag_max_m, lag)
	if _has_shown and delta_s > 0.0:
		var speed: float = shown_pos.distance_to(_last_shown) / delta_s
		if keys_held and _speed_usual > STALL_MIN_SPEED and speed < _speed_usual * STALL_SHARE:
			_event("stall", usec, "drawn at %.1f m/s, was %.1f" % [speed, _speed_usual])
		# Followed only while moving: standing still is not the speed a stall is measured against.
		if keys_held:
			_speed_usual = lerpf(_speed_usual, speed, EMA)
		else:
			_speed_usual = 0.0
	_last_shown = shown_pos
	_has_shown = true
	_age += delta_s
	var out: PackedStringArray = _pending
	_pending = []
	if _age >= PERIOD_S:
		out.append(report())
		_reset_period()
	return out


## The first-person camera pivot this frame ([param local], body frame), [param keys_held]: how far it
## swings while walking -- the HeadCam follows the head's forward lean, and the stride with it.
func on_camera(local: Vector3, keys_held: bool) -> void:
	if keys_held:
		_cam_min = _cam_min.min(local)
		_cam_max = _cam_max.max(local)


## How far the camera swung (m, x y z) this period while walking; zero when it did not walk.
func camera_swing() -> Vector3:
	return Vector3.ZERO if _cam_min == Vector3.INF else _cam_max - _cam_min


## How many [param kind] events this period (for the tests).
func count(kind: String) -> int:
	return int(_counts.get(kind, 0))


## The period's cadence, over the gaps walked through: "n", "rate_hz", "p50", "p90", "p99", "max", "sd"
## (ms), "hist" (count per HIST_MS bucket, plus one above), "same_frame" and "pauses".
func cadence() -> Dictionary:
	var sorted: PackedFloat32Array = _gaps.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	var total: float = 0.0
	var hist: Array[int] = []
	hist.resize(HIST_MS.size() + 1)
	hist.fill(0)
	for gap: float in sorted:
		total += gap
		var bucket: int = HIST_MS.size()
		for i: int in HIST_MS.size():
			if gap < HIST_MS[i]:
				bucket = i
				break
		hist[bucket] += 1
	var mean: float = total / maxf(float(n), 1.0)
	var var_sum: float = 0.0
	for gap: float in sorted:
		var_sum += (gap - mean) * (gap - mean)
	return {
		"n": n,
		"rate_hz": 1000.0 * float(n) / total if total > 0.0 else 0.0,
		"p50": _percentile(sorted, 0.5),
		"p90": _percentile(sorted, 0.9),
		"p99": _percentile(sorted, 0.99),
		"max": sorted[n - 1] if n > 0 else 0.0,
		"sd": sqrt(var_sum / float(n)) if n > 0 else 0.0,
		"hist": hist,
		"same_frame": _same_frame,
		"pauses": _pauses,
	}


## The period's trip, from the clocks the positions came with: [code]{server_gap, to_horizon, in_horizon}[/code],
## each [code][p50, p90, max][/code] in ms, or empty when no position carried that clock.
func trip() -> Dictionary:
	var out: Dictionary = {}
	for pair: Array in [["server_gap", _server_gaps], ["to_horizon", _to_horizon], ["in_horizon", _in_horizon]]:
		var sorted: PackedFloat32Array = (pair[1] as PackedFloat32Array).duplicate()
		sorted.sort()
		out[pair[0]] = [] if sorted.is_empty() else [_percentile(sorted, 0.5), _percentile(sorted, 0.9),
				sorted[sorted.size() - 1]]
	return out


## The period's "[MoveProbe]" line.
func report() -> String:
	var gap_avg: float = _gap_sum_ms / maxf(float(_updates), 1.0)
	var lag_avg: float = _lag_sum_m / maxf(float(_frames), 1.0)
	var kinds: PackedStringArray = []
	for kind: String in ["net", "jump", "back", "stall", "frame", "snap"]:
		kinds.append("%s=%d" % [kind, count(kind)])
	var c: Dictionary = cadence()
	var hist: PackedStringArray = []
	for bucket: int in c["hist"]:
		hist.append(str(bucket))
	if _csv != null:
		_csv.flush()
	var trip_parts: PackedStringArray = []
	var t: Dictionary = trip()
	for key: String in ["server_gap", "to_horizon", "in_horizon"]:
		var v: Array = t[key]
		trip_parts.append("%s -" % key if v.is_empty() else "%s p50 %.0f p90 %.0f max %.0f" % [key, v[0], v[1], v[2]])
	return ("[MoveProbe] positions=%d gap avg %.0f max %.0f ms | step max %.2f m | behind avg %.2f max %.2f m"
			+ " | frame max %.0f ms | keys %d%% | cam swing y %.1f z %.1f cm | %s"
			+ " | net rate %.1f Hz over %d p50 %.0f p90 %.0f p99 %.0f max %.0f sd %.0f ms | hist %s"
			+ " | same_frame %d pauses %d | trip ms: %s") % [_updates, gap_avg,
			_gap_max_ms, _step_max_m, lag_avg, _lag_max_m, _frame_max_ms,
			roundi(100.0 * _keys_frames / maxf(float(_frames), 1.0)), camera_swing().y * 100.0,
			camera_swing().z * 100.0, " ".join(kinds), c["rate_hz"], c["n"], c["p50"], c["p90"], c["p99"],
			c["max"], c["sd"], "/".join(hist), c["same_frame"], c["pauses"], ", ".join(trip_parts)]


## Nearest-rank percentile [param p] (0..1) of the ascending [param sorted]; 0 when empty.
static func _percentile(sorted: PackedFloat32Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(ceili(p * sorted.size()) - 1, 0, sorted.size() - 1)]


func _event(kind: String, usec: int, what: String) -> void:
	_counts[kind] = count(kind) + 1
	if _lines >= MAX_LINES:
		return
	_lines += 1
	_pending.append("[MoveHitch] t=%.3f s %s: %s" % [float(usec) / 1e6, kind, what])


func _reset_period() -> void:
	_age = 0.0
	_updates = 0
	_gap_max_ms = 0.0
	_gap_sum_ms = 0.0
	_step_max_m = 0.0
	_lag_sum_m = 0.0
	_lag_max_m = 0.0
	_frames = 0
	_frame_max_ms = 0.0
	_cam_min = Vector3.INF
	_cam_max = -Vector3.INF
	_keys_frames = 0
	_counts.clear()
	_lines = 0
	_gaps.clear()
	_pauses = 0
	_same_frame = 0
	_server_gaps.clear()
	_to_horizon.clear()
	_in_horizon.clear()
