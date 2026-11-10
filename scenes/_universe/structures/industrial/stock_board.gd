class_name StockBoard
extends PickupBoard

## CLIENT: the screen facing the pickup board in a depot's buffer room, by the buffer rack: what the
## warehouse holds (playtest 2026-11-08) -- a row per good with its picto, its crates, its weight, and the
## shelves it is on in tags. The crates are the truth (StockReconciler keeps the stock equal to them), so
## it reads the crates shelved in its depot, all replicated. The same screen and rules as the pickup board.

## Shelves named on a row; the rest is counted ("+4").
const SHELVES_SHOWN := 7
const CHIP := Color(0.2, 0.22, 0.26)


func _title_key() -> String:
	return "%%DEPOT_STOCK_TITLE"


func _empty_key() -> String:
	return "%%DEPOT_STOCK_NONE"


func _rows(crates: Array) -> Array:
	return stock_rows(crates)


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


## What a crate holds, as the board names it: "Ingots · Gold", "Crushed ore · Gold".
static func good_name(content: Dictionary) -> String:
	var kind := "%%SPAWN_CRATE_INGOT" if CrateContent.is_ingot(content) else "%%SPAWN_CRATE_CRUSHED"
	return "%s · %s" % [TranslationServer.translate(kind), TranslationServer.translate(CrateContent.content_key(content))]
