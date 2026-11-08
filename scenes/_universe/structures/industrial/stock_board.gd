class_name StockBoard
extends PickupBoard

## CLIENT: the screen facing the pickup board in a depot's buffer room, by the buffer rack: what the
## warehouse holds (playtest 2026-11-08) -- a line per good, its crates and kilograms, and under it the
## shelves it is on. The crates are the truth (StockReconciler keeps the stock equal to them), so it reads
## the crates shelved in its depot, all replicated: nothing of its own on the wire. When the list is longer
## than the screen it scrolls a line every REFRESH_S. Same screen, same rules as the pickup board (ADR 0027).

## Kept apart from the scrolling lines: the screen's title.
const TITLE_KEY := "%%DEPOT_STOCK_TITLE"

## The first body line shown (the list scrolls).
var _first := 0


func _compose(crates: Array) -> String:
	var body := stock_lines(crates)
	var shown := window(body, _first, MAX_LINES)
	if body.size() > MAX_LINES:
		_first = (_first + 1) % (body.size() + 1)
	else:
		_first = 0
	var lines := PackedStringArray([TranslationServer.translate(TITLE_KEY)])
	lines.append_array(shown)
	return "\n".join(lines)


## The lines of [param crates] (TransportReservations.crates_of): per good, "Ingots · Gold — 2 crates —
## 30 kg", then the shelves it is on. "Empty warehouse" when there is none. Pure, for the tests.
static func stock_lines(crates: Array) -> PackedStringArray:
	var goods: Dictionary = {}  # good type -> {"name", "crates", "kg", "shelves": Array}
	var order: Array = []
	for crate: Node in crates:
		var content: Variant = crate.get("content")
		if not (content is Dictionary):
			continue
		var good := CrateContent.good_type(content)
		if good == "":
			continue
		if not goods.has(good):
			goods[good] = {"name": good_name(content), "crates": 0, "kg": 0, "shelves": []}
			order.append(good)
		var entry: Dictionary = goods[good]
		entry["crates"] += 1
		entry["kg"] += int((content as Dictionary).get("units", 0))
		var shelf := ShelfLabels.label_for(crate.get_parent())
		if shelf != "" and not (entry["shelves"] as Array).has(shelf):
			(entry["shelves"] as Array).append(shelf)
	var lines := PackedStringArray()
	if order.is_empty():
		lines.append(TranslationServer.translate("%%DEPOT_STOCK_NONE"))
		return lines
	order.sort()
	for good: String in order:
		var entry: Dictionary = goods[good]
		lines.append("%s  —  %s  —  %d kg" % [entry["name"],
				TranslationServer.translate("%%DEPOT_STOCK_CRATES") % entry["crates"], entry["kg"]])
		var shelves: Array = entry["shelves"]
		shelves.sort()
		if not shelves.is_empty():
			lines.append("    " + ", ".join(PackedStringArray(shelves)))
	return lines


## What a crate holds, as the board names it: "Ingots · Gold", "Crushed ore · Gold".
static func good_name(content: Dictionary) -> String:
	var kind := "%%SPAWN_CRATE_INGOT" if CrateContent.is_ingot(content) else "%%SPAWN_CRATE_CRUSHED"
	return "%s · %s" % [TranslationServer.translate(kind), TranslationServer.translate(CrateContent.content_key(content))]


## [param count] lines of [param lines] from [param first] on, going round with a blank line between the
## end and the start; all of them when they fit. Pure, for the tests.
static func window(lines: PackedStringArray, first: int, count: int) -> PackedStringArray:
	if lines.size() <= count:
		return lines
	var ring := lines.duplicate()
	ring.append("")
	var out := PackedStringArray()
	for i: int in range(count):
		out.append(ring[(first + i) % ring.size()])
	return out
