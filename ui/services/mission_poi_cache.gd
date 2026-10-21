class_name MissionPoiCache
extends RefCounted

## The POIs a mission builder can point a zone at, fetched once and kept for the session.
##
## It exists because two different widgets need the same list — the mission's AVAILABILITY zones
## (`mission.zones[]`) and an objective's TARGET (`params.zone` / `params.source`) — and because a
## POI the builder just created has to appear in the other widget immediately, without either of
## them re-fetching. Both read it; only [method add] and [method refresh] write.
##
## The list is the caller's own POIs (`GET /api/me/pois`): owned, granted, public — plus, in this
## session, whatever [method add] created. Mission-owned POIs are invisible to that endpoint unless
## the caller created them, so the ones made here are also kept locally rather than trusted to come
## back: a builder must never lose the POI it just placed because a list did not refresh.

static var _shared: Array = []
static var _loaded: bool = false


## Every POI this session can offer, the fetched ones first. Empty until [method ensure_loaded].
static func entries() -> Array:
	return _shared


## Fetch the caller's POIs if this session has not already. Returns whether the fetch worked, so a
## caller can tell "no POI yet" from "the service is down" — they read very differently in the UI.
##
## A caller that arrives while the fetch is still in flight is answered against the list as it
## stands, which may not have the fetch in it yet. That costs a caller nothing in practice: a picker
## reads [method entries] again after it places a POI, and placing is what needs the full list.
static func ensure_loaded() -> bool:
	if _loaded:
		return true
	_loaded = true
	var result: Dictionary = await PlayerServices.poi_list(PICK_LIMIT, 0)
	if not bool(result.get("ok", false)):
		return false
	var fetched: Array = ServicePage.items_of(result)
	# Keep whatever this session created: the endpoint is not expected to list them, and a builder
	# that drops a POI it just placed would send a mission naming nothing.
	#
	# Only the ones the endpoint did NOT bring back: a point of the PLAYER's own — one laid on the
	# chart without a mission behind it — is listed by the service, and appending the session's copy
	# of it would show the same place twice in every list, and draw it twice on the chart.
	for known: Dictionary in _shared:
		if str(known.get("origin", "")) != ORIGIN_SESSION:
			continue
		if not _holds(fetched, str(known.get("id", ""))):
			fetched.append(known)
	_shared = fetched
	return true


## Does [param records] already hold the point whose id is [param poi_id]?
static func _holds(records: Array, poi_id: String) -> bool:
	if poi_id == "":
		return false
	for record: Variant in records:
		if record is Dictionary and str((record as Dictionary).get("id", "")) == poi_id:
			return true
	return false


## The caller's own POIs in one request. The API's own maximum, so the picker needs no page of its own.
const PICK_LIMIT: int = 100

## Marks a POI this session created rather than fetched, so [method ensure_loaded] does not lose it.
const ORIGIN_SESSION: String = "session"

## Refetch from the service, keeping the session's own points. For a builder that was left open a
## long time and wants the truth rather than what it remembers.
##
## The session's points are kept DELIBERATELY: the endpoint is not expected to list a POI that
## belongs to a mission rather than to a player, so a refetch would lose the place the builder just
## laid — and a mission that names nothing is a mission that cannot be taken. They used to survive
## only by luck of timing (the list was emptied before the fetch and refilled after the creation),
## which is not a promise anyone can keep.
static func refresh() -> bool:
	_loaded = false
	var kept: Array = []
	for known: Dictionary in _shared:
		if str(known.get("origin", "")) == ORIGIN_SESSION:
			kept.append(known)
	_shared = kept
	return await ensure_loaded()


## Remember a POI that was just created here, and answer its id. Returns what [method entries] holds
## for it, so a caller can select it without a second round trip.
static func add(poi: Dictionary) -> Dictionary:
	var known := poi.duplicate()
	known["origin"] = ORIGIN_SESSION
	for i: int in range(_shared.size()):
		if str((_shared[i] as Dictionary).get("id", "")) == str(known.get("id", "")):
			_shared[i] = known
			return known
	_shared.append(known)
	return known


## The display label for a POI row: its name, or the language's word for "this one has none".
##
## An id is never the answer, here or on the chart — the same rule as [StarMapPoi.label_of], which
## this mirrors on purpose rather than calling: a label belongs to whatever is showing it, and a
## cache is not a chart.
static func label_of(poi: Dictionary) -> String:
	# Not `name`: Node owns one, and shadowing it makes every warning in this file harder to read.
	# Not str() either: a nullable column arrives as an explicit null, which is not the same as an
	# absent key, and Dictionary's default only covers the absent kind.
	var value: Variant = poi.get("name")
	var text := "" if value == null else str(value).strip_edges()
	return text if text != "" else ServiceTypes.text("%%SVC_POI_UNNAMED")


## Forget everything. Called when a builder is reset, so a POI from an abandoned mission does not
## linger in a session that has moved on.
static func clear() -> void:
	_shared = []
	_loaded = false