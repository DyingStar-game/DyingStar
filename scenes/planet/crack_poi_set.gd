class_name CrackPoiSet
extends RefCounted
## The POI spheres a planet's crack network keeps whole, planet-local: [{dir: Vector3, radius: float}].
## Two halves, published together: the BAKED ones (the planet's <planet>_poi.json, in the chunk cache
## key) and the NETWORKED ones (the POI villages, arriving at run time, in no key).
##
## Written on the main thread, read by the chunk builders on workers. A published list is never
## edited, only replaced — but replacing an Array member is not atomic in Godot: a worker copying the
## reference while the main thread dropped the last one of the old list took a freed Array
## (Array::_ref "!success", then SIGSEGV — 3 server runs in 12 while 118 POI villages came in,
## test/perf/server_ingest_bench 2026-10-16). References are therefore swapped and copied under one
## lock: a list stays alive for as long as anyone holds it, and the caller reads it freely.

var _baked: Array = []
var _networked: Array = []
var _all: Array = []
var _mutex := Mutex.new()


## Replace the baked half — main thread, before the first chunk task and the bridge spans.
func set_baked(pois: Array) -> void:
	var cleaned := clean(pois)
	_mutex.lock()
	_baked = cleaned
	_all = _baked + _networked
	_mutex.unlock()


## Replace the networked half — main thread, whenever a village comes or goes.
func set_networked(pois: Array) -> void:
	var cleaned := clean(pois)
	_mutex.lock()
	_networked = cleaned
	_all = _baked + _networked
	_mutex.unlock()


## Both halves, from any thread.
func all() -> Array:
	_mutex.lock()
	var out: Array = _all
	_mutex.unlock()
	return out


## The baked half, from any thread.
func baked() -> Array:
	_mutex.lock()
	var out: Array = _baked
	_mutex.unlock()
	return out


## The networked half, from any thread.
func networked() -> Array:
	_mutex.lock()
	var out: Array = _networked
	_mutex.unlock()
	return out


## The entries a crack test can use: a unit direction and a positive radius.
static func clean(pois: Array) -> Array:
	var out: Array = []
	for p in pois:
		var d: Vector3 = (p as Dictionary).get("dir", Vector3.ZERO)
		var r := float((p as Dictionary).get("radius", 0.0))
		if d.length_squared() < 0.5 or r <= 0.0:
			continue
		out.append({"dir": d.normalized(), "radius": r})
	return out
