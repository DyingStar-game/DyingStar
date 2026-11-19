class_name StockBoard
extends PickupBoard

## CLIENT: the screen facing the pickup board in a depot's buffer room, by the buffer rack: what the
## warehouse holds (playtest 2026-11-08) -- a row per good with its picto, its crates, its weight, and the
## shelves it is on in tags. The crates are the truth (StockReconciler keeps the stock equal to them), so
## it reads the crates shelved in its depot, all replicated. The same screen and rules as the pickup board.
##
## One thing it asks: what the warehouse buys no more. A warehouse past its capacity for a good pays
## nothing for what is shelved off a mission (services ADR 0017, amended), and the crate is on the shelf
## before the sale is asked -- so the row says it, for the player to read BEFORE they shelve.

## Shelves named on a row; the rest is counted ("+4").
const SHELVES_SHOWN := 7
const CHIP := Color(0.2, 0.22, 0.26)
const FULL := Color(0.78, 0.16, 0.14)
## Refreshes between two readings of what the warehouse still buys (a minute): it fills in crates, not
## in seconds.
const LIMITS_EVERY := 30

## The goods (inventory names) this warehouse buys no more.
var _full: Array = []
var _asking := false
var _since_limits := LIMITS_EVERY


func _title_key() -> String:
	return "%%DEPOT_STOCK_TITLE"


func _empty_key() -> String:
	return "%%DEPOT_STOCK_NONE"


func _refresh() -> void:
	_since_limits += 1
	if _since_limits >= LIMITS_EVERY and not _asking:
		_since_limits = 0
		_read_limits()
	super._refresh()


func _rows(crates: Array) -> Array:
	return mark_full(stock_rows(crates), _full)


## Ask the simulator what this warehouse holds against its capacities. Detached: the next refresh shows it.
func _read_limits() -> void:
	var warehouse := str(_depot.get("uuid")) if _depot != null else ""
	if warehouse == "" or not PlayerServices.is_available():
		return
	_asking = true
	var result: Dictionary = await PlayerServices.warehouse_stock(warehouse)
	_asking = false
	if not is_inside_tree() or not bool(result.get("ok", false)) or not (result.get("data") is Dictionary):
		return
	_full = full_goods(result["data"])


## The header's corner: the weight of everything in stock.
func _count_text(rows: Array) -> String:
	var kg := 0
	for row: Dictionary in rows:
		kg += int(row.get("kg", 0))
	return ServiceTypes.quantity_text(kg, "kg") if kg > 0 else ""


## One row: the good's picto, its name over its shelves, its crates, its weight.
func _row(row: Dictionary) -> Control:
	var parts := WallScreen.card(ROW_PX)
	var line: HBoxContainer = parts[1]
	line.add_child(WallScreen.icon(PickupBoard.good_icon(str(row.get("kind", ""))), 56.0, AMBER))
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_theme_constant_override("separation", 4)
	texts.add_child(AresBrand.screen_label(str(row.get("name", "")), 30, WallScreen.TEXT))
	var shelves := HBoxContainer.new()
	shelves.add_theme_constant_override("separation", 6)
	var names: Array = row.get("shelves", [])
	for shelf: String in names.slice(0, SHELVES_SHOWN):
		shelves.add_child(WallScreen.chip(shelf, 20, CHIP, WallScreen.TEXT))
	if names.size() > SHELVES_SHOWN:
		shelves.add_child(AresBrand.screen_label("+%d" % (names.size() - SHELVES_SHOWN), 20, WallScreen.DIM))
	texts.add_child(shelves)
	line.add_child(texts)
	if bool(row.get("full", false)):
		line.add_child(WallScreen.chip(TranslationServer.translate("%%DEPOT_STOCK_FULL"), 22, FULL, Color.WHITE))
	var crates := AresBrand.screen_label(TranslationServer.translate("%%DEPOT_STOCK_CRATES")
			% int(row.get("crates", 0)), 26, WallScreen.DIM)
	crates.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(crates)
	var weight := AresBrand.screen_label(ServiceTypes.quantity_text(int(row.get("kg", 0)), "kg"), 40, AMBER)
	weight.custom_minimum_size = Vector2(190, 0)
	weight.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	weight.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(weight)
	return parts[0]


## The rows for [param crates] (TransportReservations.crates_of): one per good -- {good, kind, name, crates,
## kg, shelves (sorted)}, sorted by good. Pure, for the tests.
static func stock_rows(crates: Array) -> Array:
	var goods: Dictionary = {}
	for crate: Node in crates:
		var content: Variant = crate.get("content")
		if not (content is Dictionary):
			continue
		var good := CrateContent.good_type(content)
		if good == "":
			continue
		if not goods.has(good):
			goods[good] = {"good": good, "kind": str((content as Dictionary).get("kind", "")),
					"name": good_name(content), "crates": 0, "kg": 0, "shelves": []}
		var row: Dictionary = goods[good]
		row["crates"] += 1
		row["kg"] += int((content as Dictionary).get("units", 0))
		var shelf := PickupBoard.shelf_name(crate.get_parent())
		if not (row["shelves"] as Array).has(shelf):
			(row["shelves"] as Array).append(shelf)
	var order: Array = goods.keys()
	order.sort()
	var rows: Array = []
	for good: String in order:
		(goods[good]["shelves"] as Array).sort()
		rows.append(goods[good])
	return rows


## The goods a warehouse buys no more, from the simulator's view of it ([param data], its `stocks`):
## those it holds its capacity of, or more. A good without a capacity is always bought. Pure, for the tests.
static func full_goods(data: Dictionary) -> Array:
	var full: Array = []
	var stocks: Variant = data.get("stocks")
	if not (stocks is Array):
		return full
	for stock: Variant in stocks:
		if not (stock is Dictionary) or (stock as Dictionary).get("capacity") == null:
			continue
		var good := str((stock as Dictionary).get("goodType", (stock as Dictionary).get("code", "")))
		if good != "" and float((stock as Dictionary).get("quantity", 0)) >= float((stock as Dictionary).get("capacity")):
			full.append(good)
	return full


## [param rows] (stock_rows) with `full` set on those of the goods in [param full]. Pure, for the tests.
static func mark_full(rows: Array, full: Array) -> Array:
	for row: Dictionary in rows:
		if full.has(str(row.get("good", ""))):
			row["full"] = true
	return rows


## What a crate holds, as the board names it: "Ingots · Gold", "Crushed ore · Gold".
static func good_name(content: Dictionary) -> String:
	var kind := "%%SPAWN_CRATE_INGOT" if CrateContent.is_ingot(content) else "%%SPAWN_CRATE_CRUSHED"
	return "%s · %s" % [TranslationServer.translate(kind), TranslationServer.translate(CrateContent.content_key(content))]
