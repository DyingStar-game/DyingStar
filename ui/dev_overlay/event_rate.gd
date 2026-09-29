class_name EventRate
extends RefCounted
## A per-second rate from a running total, measured by its own reader. The network monitors report
## totals so that several readers (this panel, ClientPerf, the editor profiler) never steal counts
## from each other, as a counter reset on read made them do.

var _last_total : int = -1
var _last_ms : int = 0
var _rate : float = 0.0


## The rate since the previous call; 0 on the first.
func per_second(total: int, now_ms: int) -> float:
	if _last_total >= 0 and now_ms > _last_ms:
		_rate = float(total - _last_total) * 1000.0 / float(now_ms - _last_ms)
	_last_total = total
	_last_ms = now_ms
	return _rate
