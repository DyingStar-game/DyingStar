class_name ServicePage
extends RefCounted

## One list's window into a paginated endpoint.
##
## The services answer every list endpoint with a page object — `{items, total, limit, offset}`,
## the mission service's `{missions, total, limit, offset}` — and hand over at most `limit` rows
## starting at `offset`. Reading `result.data` as an array therefore yields nothing at all: the list
## renders empty while the service happily serves row 21 of 500.
##
## So every paged list owns one of these. It carries the window (which page of how many), moves it
## when the footer buttons are pressed, absorbs the window a response reports, and tells its footer
## when to redraw. The panel wires the fetch to [signal load_requested]; the footer redraws on
## [signal windowed]. A window is only trusted once a response lands: a refused fetch gives it back
## to the rows still on screen ([method adopt]), and a fetch a newer jump superseded is dropped by
## [method ServicePanel._land] before it ever gets here.

## A fetch is wanted for this window: a footer button moved it, or the panel asked for a reload.
signal load_requested

## A response was absorbed (or a refused jump was undone): redraw the footer.
signal windowed

## Which key the response carries this list's rows under: "items" for most services, "missions" for
## the mission service, "stacks" for an inventory, "events" for the reputation history, "incoming"
## for the pending requests (whose outgoing half rides the same window).
var rows_key: String = "items"

## Which keys say how many rows exist in all, summed: ["total"] for most pages, ["eventsTotal"] for
## the reputation history, ["total", "instancesTotal"] for an inventory (one window carries both
## lists), ["incomingTotal", "outgoingTotal"] for the pending requests.
var total_keys: PackedStringArray = PackedStringArray(["total"])

## Rows per window — the `limit` the service is asked for, and the one it confirms back.
var limit: int = 20

## First row of the window: the `offset` in flight.
var offset: int = 0

## Rows in all, as last reported.
var total: int = 0

## The window the rows on screen came from; a refused fetch falls back to it.
var _landed_offset: int = 0


## The rows a response carries, under [param rows_key]. A bare array response passes through: a few
## endpoints are not paginated at all and still return their rows directly.
static func items_of(result: Dictionary, rows_key: String = "items") -> Array:
	var data: Variant = result.get("data")
	if data is Array:
		return data
	if data is Dictionary and (data as Dictionary).get(rows_key) is Array:
		return (data as Dictionary).get(rows_key)
	return []


## How many rows exist in all, summed over [param total_keys]; 0 when the response says nothing
## about it. A JSON number may arrive as an int or a float depending on how the body was written,
## so both count — a count read the wrong way would hide the footer behind a total of zero.
static func total_of(result: Dictionary, total_keys: PackedStringArray) -> int:
	var data: Variant = result.get("data")
	if not (data is Dictionary):
		return 0
	var sum: int = 0
	for key: String in total_keys:
		var value: Variant = (data as Dictionary).get(key)
		if value is int or value is float:
			sum += int(value)
	return sum


## The rows this list's window of a response carries.
func rows(result: Dictionary) -> Array:
	return ServicePage.items_of(result, rows_key)


## Number of the window being shown or asked for, 1-based.
func page() -> int:
	if limit <= 0:
		return 1
	return offset / limit + 1


## How many windows the total fills (at least one — an empty list is still a page).
func pages() -> int:
	if limit <= 0:
		return 1
	return maxi(1, ceili(float(total) / float(limit)))


func can_prev() -> bool:
	return offset > 0


func can_next() -> bool:
	return offset + limit < total


## Move to the first window (a no-op, and no fetch, when already there).
func first() -> void:
	_go(0)


## Move one window back, clamped at the first.
func prev() -> void:
	_go(maxi(0, offset - limit))


## Move one window forward, clamped at the last.
func next() -> void:
	if can_next():
		_go(offset + limit)


## Move to the last window.
func last() -> void:
	_go((pages() - 1) * limit)


## Back to the first window — and load it, always: a filter or a search changed, so whichever page
## was showing is no longer the question being asked.
func reset() -> void:
	offset = 0
	load_requested.emit()


## Load the window again without moving: the panel's « Refresh ».
func reload() -> void:
	load_requested.emit()


## Forget the window — the list it belonged to is gone (no group, nothing picked). The footer
## hides with it.
func clear() -> void:
	offset = 0
	_landed_offset = 0
	total = 0
	windowed.emit()


## Absorb a response: the window it reports is now the window on screen. A refused response gives
## the window back to the rows still on screen — the error is the panel's to report, but the footer
## must not claim a page that never landed.
func adopt(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		offset = _landed_offset
		windowed.emit()
		return
	if result.get("data") is Dictionary:
		total = ServicePage.total_of(result, total_keys)
		var reported: int = int((result.get("data") as Dictionary).get("limit", limit))
		if reported > 0:
			limit = reported
	_landed_offset = offset
	windowed.emit()


## The footer's sentence: « Page 2 of 7 · 128 items ».
func status_text() -> String:
	return tr("%%PG_STATUS") % [page(), pages(), total]


func _go(target: int) -> void:
	var wanted: int = maxi(0, target)
	if wanted == offset:
		return
	offset = wanted
	load_requested.emit()
