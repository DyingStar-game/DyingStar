@tool
class_name MarketBoard
extends WallScreen

## The materials market on a town hall's wall, like a stock exchange's board (playtest 2026-11-10): a row
## per resource the federation trades -- its name in the player's language, the curve of its price over the last day, the
## price now and how it moved, the supply and demand behind it. The prices are the universe simulator's
## (GET /api/market), read every REFRESH_S while the screen is seen; a WallScreen, so drawn only when what
## it shows changed (ADR 0027).
##
## Two things are told apart (playtest 2026-11-11: a flooded ore read all green, a bargain to sell):
##  - the MARKET's state, for who sells -- the price's colour and a word by the supply and demand:
##    "Shortage" in green (asked for more than there is, it pays well), "Saturated" in red;
##  - the TREND over a day -- the curve, the arrow and its percentage: green up, red down.

const REFRESH_S := 60.0
const READ_RANGE_M := 45.0
const SIZE_M := Vector2(7.0, 2.625)
const PX := Vector2i(1920, 720)
const ROWS := 5
const ROW_PX := 96.0
const UP := Color(0.25, 0.85, 0.4)
const DOWN := Color(0.95, 0.3, 0.25)
## A price that moved less than this (%) reads as flat.
const FLAT_PCT := 0.05
## A demand within this share of the supply, either way, reads as a balanced market.
const BALANCE_BAND := 0.1

## What a market is for who sells into it (state_of).
enum State { SHORTAGE, BALANCED, SATURATED, IDLE }

var _list: VBoxContainer = null
var _stamp: Label = null
var _asking := false
var _shown: Array = [null]


func _ready() -> void:
	refresh_s = REFRESH_S
	var root := build_screen(SIZE_M, PX, READ_RANGE_M)
	if root == null:
		return
	var parts := WallScreen.header(root, AresBrand.Subsidiary.CORP, "%%MARKET_BOARD_TITLE", 40, 72.0, 48)
	_stamp = parts[1]
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 10)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	(parts[0] as VBoxContainer).add_child(_list)
	show_rows([], "")


func _refresh() -> void:
	if _asking or not PlayerServices.is_available():
		return
	_asking = true
	var result: Dictionary = await PlayerServices.market_prices()
	_asking = false
	if not is_inside_tree() or not bool(result.get("ok", false)) or not (result.get("data") is Dictionary):
		return
	var data: Dictionary = result["data"]
	show_rows(rows_of(data, TranslationServer.get_locale()), str(data.get("currency", "")))


## Put [param rows] (rows_of) up, priced in [param currency].
func show_rows(rows: Array, currency: String) -> void:
	var showing := [rows, currency]
	if showing == _shown:
		return
	_shown = showing.duplicate(true)
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if rows.is_empty():
		var empty := AresBrand.screen_label("%%MARKET_BOARD_EMPTY", 36, WallScreen.DIM)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_list.add_child(empty)
	for row: Dictionary in rows.slice(0, ROWS):
		_list.add_child(_row(row, currency))
	_stamp.text = Time.get_time_string_from_system().left(5) if not rows.is_empty() else ""
	redraw()


func _row(row: Dictionary, currency: String) -> Control:
	var change: float = float(row.get("change_pct", 0.0))
	var colour := trend_colour(change)
	var state: State = state_of(int(row.get("supply", 0)), int(row.get("demand", 0)))
	var parts := WallScreen.card(ROW_PX, 28)
	var line: HBoxContainer = parts[1]
	# The resource by its name in the player's language, never its code (playtest 2026-11-10).
	var title := AresBrand.screen_label(str(row.get("name", "")), 36, Color.WHITE)
	title.custom_minimum_size = Vector2(560, 0)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(title)
	var curve := PriceCurve.new()
	curve.points = row.get("points", PackedFloat32Array())
	curve.colour = colour
	curve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	curve.size_flags_vertical = Control.SIZE_EXPAND_FILL
	line.add_child(curve)
	# The market's state in a word, over the supply and demand it comes from.
	var book := VBoxContainer.new()
	book.custom_minimum_size = Vector2(330, 0)
	book.alignment = BoxContainer.ALIGNMENT_CENTER
	book.add_theme_constant_override("separation", 0)
	book.add_child(AresBrand.screen_label(state_key(state), 26, state_colour(state)))
	book.add_child(AresBrand.screen_label(TranslationServer.translate("%%MARKET_SUPPLY_DEMAND") % [
			ServiceTypes.quantity_text(int(row.get("supply", 0)), row.get("unit")),
			ServiceTypes.quantity_text(int(row.get("demand", 0)), row.get("unit"))], 22, WallScreen.DIM))
	line.add_child(book)
	var price := VBoxContainer.new()
	price.custom_minimum_size = Vector2(250, 0)
	price.alignment = BoxContainer.ALIGNMENT_CENTER
	price.add_theme_constant_override("separation", 0)
	var figure := AresBrand.screen_label("%.2f" % float(row.get("price", 0.0)), 44, state_colour(state))
	figure.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price.add_child(figure)
	var per := AresBrand.screen_label("%s / %s" % [currency, str(row.get("unit", ""))], 20, WallScreen.DIM)
	per.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price.add_child(per)
	line.add_child(price)
	var moved := AresBrand.screen_label(change_text(change), 34, colour)
	moved.custom_minimum_size = Vector2(230, 0)
	moved.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	moved.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(moved)
	return parts[0]


## The rows of the simulator's market ([param data], GET /api/market), named in [param locale]:
## {name, unit, price, change_pct, points, supply, demand}, by name. Pure, for the tests.
static func rows_of(data: Dictionary, locale: String) -> Array:
	var rows: Array = []
	var items: Variant = data.get("items")
	for item: Variant in (items if items is Array else []):
		if not (item is Dictionary):
			continue
		var name := ServiceTypes.localised_name(item, locale)
		var price := float(item.get("unitPrice", 0.0))
		var points := PackedFloat32Array()
		for p: Variant in (item.get("points") if item.get("points") is Array else []):
			points.append(float(p))
		rows.append({"name": name, "unit": str(item.get("unit", "")),
				"price": price, "change_pct": change_pct(float(item.get("previousPrice", price)), price),
				"points": points, "supply": int(float(item.get("supply", 0))), "demand": int(float(item.get("demand", 0)))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return rows


## How much (%) a price moved from [param previous] to [param now]; 0 from nothing.
static func change_pct(previous: float, now: float) -> float:
	return (now - previous) / previous * 100.0 if previous > 0.0 else 0.0


## "▲ +2.4 %", "▼ -1.2 %", "= 0.0 %".
static func change_text(pct: float) -> String:
	if absf(pct) < FLAT_PCT:
		return "= 0.0 %"
	return "%s %+.1f %%" % ["▲" if pct > 0.0 else "▼", pct]


static func trend_colour(pct: float) -> Color:
	if absf(pct) < FLAT_PCT:
		return WallScreen.TEXT
	return UP if pct > 0.0 else DOWN


## What the market of a resource is for who sells: asked for more than there is ([param demand] over
## [param supply] by more than BALANCE_BAND), flooded, or balanced; IDLE when nobody holds any nor asks
## for any -- "saturated" there read as a flood of a resource nobody had (playtest 2026-11-12). Pure.
static func state_of(supply: int, demand: int) -> State:
	if supply <= 0 and demand <= 0:
		return State.IDLE
	var have: float = maxf(float(supply), 1.0)
	var need: float = maxf(float(demand), 0.0)
	if need > have * (1.0 + BALANCE_BAND):
		return State.SHORTAGE
	if need < have / (1.0 + BALANCE_BAND):
		return State.SATURATED
	return State.BALANCED


## A state's word (a translation key).
static func state_key(state: State) -> String:
	match state:
		State.SHORTAGE:
			return "%%MARKET_STATE_SHORTAGE"
		State.SATURATED:
			return "%%MARKET_STATE_SATURATED"
		State.IDLE:
			return "%%MARKET_STATE_IDLE"
	return "%%MARKET_STATE_BALANCED"


## A state's colour, for who sells: a shortage pays (green), a flooded market does not (red).
static func state_colour(state: State) -> Color:
	match state:
		State.SHORTAGE:
			return UP
		State.SATURATED:
			return DOWN
		State.IDLE:
			return WallScreen.DIM
	return WallScreen.TEXT


## The curve of a price: its points joined, scaled to the control.
class PriceCurve extends Control:
	var points := PackedFloat32Array()
	var colour := Color.WHITE

	func _draw() -> void:
		var line := polyline(points, size)
		if line.size() >= 2:
			draw_polyline(line, colour, 3.0, true)

	## [param values] as a line across [param area], the lowest at the bottom; flat in the middle when they
	## do not move. Empty under two values. Pure, for the tests.
	static func polyline(values: PackedFloat32Array, area: Vector2) -> PackedVector2Array:
		var out := PackedVector2Array()
		if values.size() < 2:
			return out
		var low := values[0]
		var high := values[0]
		for v: float in values:
			low = minf(low, v)
			high = maxf(high, v)
		var margin := area.y * 0.15
		for i: int in range(values.size()):
			var t := 0.5 if is_equal_approx(high, low) else (values[i] - low) / (high - low)
			out.append(Vector2(area.x * float(i) / float(values.size() - 1), area.y - margin - t * (area.y - 2.0 * margin)))
		return out
