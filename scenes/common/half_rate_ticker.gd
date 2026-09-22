class_name HalfRateTicker
extends RefCounted
## Runs a per-frame update every OTHER frame while enabled, handing the caller the time both frames
## covered, so anything integrated over delta (smoothing, lerps, footstep distance) comes out the
## same — only the update cadence halves. Disabled, it is transparent: every frame, the frame's delta.
##
## Used by a remote avatar's presentation once it is far enough that 30 Hz (the rate the network
## feeds it anyway) cannot be told from 60: with 30 players around, the per-avatar scripts were
## 1.3 ms/frame (test/perf/remote_players_bench `noscript`), paid in full for avatars 20 m away.

var enabled: bool = false
var _pending: float = 0.0
var _skip: bool = false

## The delta to integrate this frame, or a negative value when this frame is skipped.
func due(delta: float) -> float:
	if not enabled:
		_pending = 0.0
		return delta
	_pending += delta
	_skip = not _skip
	if _skip:
		return -1.0
	var covered: float = _pending
	_pending = 0.0
	return covered
