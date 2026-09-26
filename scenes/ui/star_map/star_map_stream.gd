class_name StarMapStream
extends RefCounted
## Asks the tile service for the ground the chart is being asked to draw and does not have.
##
## The chart can only draw what has been downloaded, and what has been downloaded is wherever somebody
## has walked: measured on Tarsis III, the mining villages have real tiles down to n1024 while every one
## of the fifteen railway cities stops at n8 or n16 — 12 km of ground per sample under a view asking for
## 198 m. Drawn, that is a smooth nothing, and no amount of work on the mesh can put detail into it.
##
## So the tiles in view are asked for. Nothing here fetches anything itself: [RemoteTileSource] already
## owns a worker thread, a queue that never asks twice, a presence map that knows which tiles exist at
## all, and an LRU over the disk cache. This hands it a list and gets out of the way — and the ground
## picks the results up on a later pass, because it reads the same cache.

## How many tiles one pass may ask for.
##
## The queue is served one tile at a time over HTTP, so a whole patch — up to
## [constant StarMapRelief.PATCH_TILES_MAX] — would take minutes to drain and the tiles under the eye
## would sit behind tiles off the edge of the screen. A couple of dozen keeps it answering while the
## view moves, and what is not asked for now is asked for on the next pass, the wanted set being
## recomputed from scratch each time.
const MAX_PER_PASS: int = 24

## How many tiles may be outstanding before a pass asks for nothing more.
##
## Self-regulating, and it has to be: the queue is served one tile at a time over a network whose speed
## nobody here knows, so any fixed rate is either too slow on a fast link or a flood on a slow one. Two
## passes' worth is enough to keep the worker busy without letting the tiles under the eye queue up
## behind hundreds asked for while the view was somewhere else.
const MAX_OUTSTANDING: int = 48

## Print what is being asked for, to the client log. Temporary.
const DEBUG_STREAM: bool = false

var _source: RemoteTileSource = null
var _body: String = ""
var _tried: bool = false
var _asked: Dictionary = {}
var _delivered: int = 0


## Ask for the tiles of [param tiles], which are the ground's own, keyed as [StarMapGround] keys them.
##
## Silent and harmless when there is no tile service configured, which is an ordinary state: the chart
## then draws whatever is on disk, exactly as it did before.
func want(body_key: String, tiles: Dictionary) -> void:
	if body_key != _body:
		close()
		_body = body_key
	if not _open():
		return
	# Nothing more while the service is still working through what it has. The cap on a pass bounds the
	# pass; it does NOT bound the rate, and this runs every frame — twenty-four tiles sixty times a
	# second against a queue that drains about a dozen, which is how it ran to 1 647 asked for and 337
	# answered inside a few seconds. What matters is the BACKLOG, and the counters already say it.
	if backlog() > MAX_OUTSTANDING:
		return
	var picked: Array[int] = _pick(tiles)
	for id: int in picked:
		# Does nothing when the tile is already on disk, or when the service's presence map says that
		# tile was never published. Both are the common case and neither costs a request.
		_source.queue(StarMapGround.id_nside(id), StarMapGround.id_ipix(id))
	if DEBUG_STREAM and not picked.is_empty():
		var levels: Dictionary = {}
		for id: int in picked:
			var n: int = StarMapGround.id_nside(id)
			levels[n] = int(levels.get(n, 0)) + 1
		print("[Flux] %s : %d voulues, %d demandees %s | sert n%d..n%d | demandes %d, recues %d, echecs %d"
				% [_body, tiles.size(), picked.size(), str(levels),
				_source.nside_min, _source.nside_max,
				_source.stat_requested, _source.stat_fetched, _source.stat_failed])


## Which tiles this pass will ask for: those wanted, not asked for before, up to the cap.
##
## Separate from the asking so that the rule can be exercised without a tile service: opening one talks
## to the network to find the current version, which is not something a unit test should do, and the
## rule — never twice, never more than a couple of dozen at once — is the whole of what could be wrong
## here.
func _pick(tiles: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for id: int in tiles:
		if out.size() >= MAX_PER_PASS:
			break
		if _asked.has(id):
			continue
		_asked[id] = true
		out.append(id)
	return out


## Has anything arrived since this was last asked? True once per delivery, never twice.
##
## The one thing the ground cannot find out for itself. It draws from the disk cache and the service
## fills that cache behind its back, so without being told, a tile downloaded a second after it was
## drawn is never drawn again.
func took_delivery() -> bool:
	if _source == null:
		return false
	if _source.stat_fetched <= _delivered:
		return false
	_delivered = _source.stat_fetched
	return true


## How many tiles have been asked for and not yet answered, one way or the other.
func backlog() -> int:
	if _source == null:
		return 0
	return _source.stat_requested - _source.stat_fetched - _source.stat_failed


## Let the body go, and the worker thread with it.
func close() -> void:
	if _source != null:
		_source.stop()
		_source = null
	_asked.clear()
	_delivered = 0
	_tried = false
	_body = ""


# ---------------------------------------------------------------------------

## The service for this body, opened once.
##
## A body with no service, or a service that cannot be reached, is remembered as such: [method
## RemoteTileSource.for_planet] talks to the network to find the current version, and retrying that
## every quarter second for a chart nobody can stream to would be a request storm over a state that is
## not going to change while the chart is open.
func _open() -> bool:
	if _source != null:
		return true
	if _tried or _body == "":
		return false
	_tried = true
	_source = RemoteTileSource.for_planet(_body)
	return _source != null
