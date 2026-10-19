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


## true when client.ini asks for the probe.
static func wanted() -> bool:
	return ClientConfig.get_bool("debug_move_probe", false)


## A position from the server (the owner's, local to its frame), at [param usec] (Time.get_ticks_usec).
func on_target(local_pos: Vector3, usec: int) -> void:
	if _last_target_us >= 0:
		var gap_ms: float = float(usec - _last_target_us) / 1000.0
		var step: Vector3 = local_pos - _last_target
		_updates += 1
		_gap_sum_ms += gap_ms
		_gap_max_ms = maxf(_gap_max_ms, gap_ms)
		_step_max_m = maxf(_step_max_m, step.length())
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


## The interpolation was reset (a reparent): the next position is in another frame, [param frame].
func on_snap(usec: int, frame: String = "") -> void:
	_event("snap", usec, "interpolation reset, new frame %s" % frame)
	_last_target_us = -1
	_last_step = Vector3.ZERO
	_has_shown = false


## A drawn frame: the body [param shown_pos] (local, after the interpolation), [param delta_s] long,
## [param keys_held] when a move key is down. Returns the lines to print now (hitches, and the period's
## summary once it is over), most often none.
func on_frame(shown_pos: Vector3, delta_s: float, keys_held: bool, usec: int) -> PackedStringArray:
	_keys_held = keys_held
	_frames += 1
	var frame_ms: float = delta_s * 1000.0
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


## The period's "[MoveProbe]" line.
func report() -> String:
	var gap_avg: float = _gap_sum_ms / maxf(float(_updates), 1.0)
	var lag_avg: float = _lag_sum_m / maxf(float(_frames), 1.0)
	var kinds: PackedStringArray = []
	for kind: String in ["net", "jump", "back", "stall", "frame", "snap"]:
		kinds.append("%s=%d" % [kind, count(kind)])
	return ("[MoveProbe] positions=%d gap avg %.0f max %.0f ms | step max %.2f m | behind avg %.2f max %.2f m"
			+ " | frame max %.0f ms | keys %d%% | cam swing y %.1f z %.1f cm | %s") % [_updates, gap_avg,
			_gap_max_ms, _step_max_m, lag_avg, _lag_max_m, _frame_max_ms,
			roundi(100.0 * _keys_frames / maxf(float(_frames), 1.0)), camera_swing().y * 100.0,
			camera_swing().z * 100.0, " ".join(kinds)]


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
