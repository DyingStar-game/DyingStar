class_name PickupBoard
extends WallScreen

## CLIENT: the screen in a depot's buffer room that tells a transporter where their crates wait
## (playtest 2026-11-08): a row per player, shelf and good -- the player's name, the shelf in a tag, how
## many crates of what. It reads the crates shelved in its depot and their `reserved_for` marks
## (TransportReservations), all replicated: nothing of its own on the wire. A WallScreen: read again every
## REFRESH_S while seen, drawn only when its rows change (ADR 0027); more rows than fit turn in pages.

const REFRESH_S := 2.0
## How far (m) the screen is read from.
const READ_RANGE_M := 20.0
## The screen (m), and what it is drawn at (px).
const SIZE_M := Vector2(2.4, 1.35)
const PX := Vector2i(1280, 720)
## Rows to a page, and how many refreshes a page stays up.
const ROWS := 5
const PAGE_REFRESHES := 3
const ROW_PX := 92.0
const AMBER := Color(1.0, 0.73, 0.03)

var _depot: Node = null
var _list: VBoxContainer = null
var _count: Label = null
var _pager: Label = null
var _page := 0
var _ticks := 0
## What is on show ([rows of the page, page, pages, the header's count]), to draw again only when it
## changes.
var _shown: Array = []


## Build the screen for [param depot], facing +Z.
func setup(depot: Node) -> PickupBoard:
	_depot = depot
	refresh_s = REFRESH_S
	var root := build_screen(SIZE_M, PX, READ_RANGE_M)
	if root == null:
		return self
	var parts := WallScreen.header(root, AresBrand.Subsidiary.HAULING, _title_key(), 36, 64.0, 44)
	_count = parts[1]
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 10)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	(parts[0] as VBoxContainer).add_child(_list)
	_pager = AresBrand.screen_label("", 22, WallScreen.DIM)
	_pager.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	(parts[0] as VBoxContainer).add_child(_pager)
	return self


func _refresh() -> void:
	if _depot == null or _list == null:
		return
	show_rows(_rows(TransportReservations.crates_of(_depot)))


## Put [param rows] up: the page whose turn it is, drawn again only when what shows changed.
func show_rows(rows: Array) -> void:
	var pages := WallScreen.page_count(rows.size(), ROWS)
	_ticks += 1
	if _ticks >= PAGE_REFRESHES:
		_ticks = 0
		_page = (_page + 1) % pages
	_page = mini(_page, pages - 1)
	var page_rows := WallScreen.page_of(rows, _page, ROWS)
	var count: String = _count_text(rows)  # over every page: it may change while this page does not
	var showing := [page_rows, _page, pages, count]
	if showing == _shown:
		return
	_shown = showing
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if rows.is_empty():
		var empty := AresBrand.screen_label(_empty_key(), 34, WallScreen.DIM)
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_list.add_child(empty)
	for row: Dictionary in page_rows:
		_list.add_child(_row(row))
	_count.text = count
	_pager.text = "%d / %d" % [_page + 1, pages] if pages > 1 else ""
	redraw()


func _title_key() -> String:
	return "%%DEPOT_PICKUP_TITLE"


func _empty_key() -> String:
	return "%%DEPOT_PICKUP_NONE"


## The rows of this screen for [param crates], the depot's shelved crates.
func _rows(crates: Array) -> Array:
	return pickup_rows(crates)


## What the header's corner says of [param rows]: how many crates wait in all.
func _count_text(rows: Array) -> String:
	var crates := 0
	for row: Dictionary in rows:
		crates += int(row.get("count", 0))
	return TranslationServer.translate("%%DEPOT_STOCK_CRATES") % crates if crates > 0 else ""


## One row: the good's picto, whose it is, the shelf in a tag, how many crates of what.
func _row(row: Dictionary) -> Control:
	var parts := WallScreen.card(ROW_PX)
	var line: HBoxContainer = parts[1]
	line.add_child(WallScreen.icon(good_icon(str(row.get("kind", ""))), 56.0, AMBER))
	var who := AresBrand.screen_label(str(row.get("name", "")), 34, WallScreen.TEXT)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	who.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(who)
	var what := AresBrand.screen_label("%d × %s" % [int(row.get("count", 0)),
			TranslationServer.translate(str(row.get("content_key", "")))], 30, WallScreen.DIM)
	what.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(what)
	line.add_child(WallScreen.chip(str(row.get("shelf", "")), 36, AMBER, Color.BLACK))
	return parts[0]


## The picto of a crate's kind: ingots, else crushed ore (the plate's own).
static func good_icon(kind: String) -> Texture2D:
	return CratePlate.ICON_INGOT if kind == CrateContent.KIND_INGOT else CratePlate.ICON_ORE


## Where a crate is, as the board says it: the shelf's label, or the buffer rack's name.
static func shelf_name(shelf: Node) -> String:
	var label := ShelfLabels.label_for(shelf)
	return label if label != "" else TranslationServer.translate("%%DEPOT_BUFFER")


## The rows for [param crates] (TransportReservations.crates_of): one per player, shelf and good holding
## crates kept for them -- {name, shelf, kind, content_key, count}, in the crates' order. Pure, for the tests.
static func pickup_rows(crates: Array) -> Array:
	var rows: Array = []
	var index: Dictionary = {}  # [name, shelf, kind, mineral] -> row
	for crate: Node in crates:
		var content: Dictionary = crate.get("content")
		var reserved: Variant = content.get("reserved_for")
		if not (reserved is Dictionary):
			continue
		var key := [str((reserved as Dictionary).get("name", "")), shelf_name(crate.get_parent()),
				str(content.get("kind", "")), str(content.get("mineral", ""))]
		if not index.has(key):
			var row := {"name": key[0], "shelf": key[1], "kind": key[2],
					"content_key": CrateContent.content_key(content), "count": 0}
			index[key] = row
			rows.append(row)
		index[key]["count"] += 1
	return rows
