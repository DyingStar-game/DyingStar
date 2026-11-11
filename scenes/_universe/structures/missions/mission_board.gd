class_name MissionBoard
extends Node3D

## The giant mission screen of a town hall, a wall of classified ads: every mission on offer here as
## tiles (MissionTile), as many across as the screen holds. When they do not all fit, they roll up
## without end like a conveyor — a row leaving at the top joins the bottom behind the last one — so
## the board never jumps back. To look at only: the missions are taken at the kiosks (MissionKiosk).
## It shows what its building's MissionFeed brings (MissionFeed.near) and keeps the tiles it has: a
## refresh drops the missions gone and slips the new ones in near the bottom of the screen, where
## they light up (MissionTile.highlight) for HIGHLIGHT_S. The dedicated server keeps the frame and
## drops the screen.

## How fast the tiles roll up (px of the screen per second).
@export_range(5.0, 200.0, 1.0) var scroll_px_s: float = 40.0
## The size of a tile on the screen, in MissionTile.BASE_SIZE.
@export_range(0.5, 3.0, 0.05) var tile_zoom: float = 0.8

const BG_COLOR := Color(0.04, 0.05, 0.06)
const TITLE_PX: int = 54
const COUNT_PX: int = 34
const LOGO_PX: float = 90.0
const GAP_PX: int = 24
const MARGIN_PX: int = 48
## How long (s) a mission that just arrived stays lit.
const HIGHLIGHT_S: float = 8.0

@onready var _viewport: SubViewport = $SubViewport
@onready var _screen: MeshInstance3D = $Screen

var _feed: MissionFeed
## The window the tiles roll through, and the grid that rolls.
var _view: Control
var _grid: GridContainer
var _count: Label
var _empty: Label
## Tile key (MissionBoard.key_of) -> its tile, so a refresh only adds and drops.
var _tiles: Dictionary = {}
## How far (px) the top row has gone up out of the window.
var _offset: float = 0.0


func _ready() -> void:
	if GameOrchestrator.is_server():
		_viewport.queue_free()
		set_process(false)
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = _viewport.get_texture()
	_screen.material_override = material
	# It hums as every screen of the world does, from further: it is as wide as the hall.
	var face: AABB = _screen.get_aabb()
	ScreenHum.attach(self, _screen.position, maxf(face.size.x, face.size.y))
	_build()
	_feed = MissionFeed.near(self)
	_feed.updated.connect(show_missions)
	show_missions(_feed.missions)


## How many tiles of [param zoom] go across a screen [param width_px] wide: as many as fit.
static func columns_for(width_px: float, zoom: float) -> int:
	var tile: float = MissionTile.BASE_SIZE.x * zoom + GAP_PX
	return maxi(int((width_px - 2 * MARGIN_PX + GAP_PX) / tile), 1)


## A tile's key: its mission, and its creator's name, which lands after it (MissionFeed) and is
## worth a new tile.
static func key_of(mission: Dictionary) -> String:
	return "%s|%s" % [mission.get("id", ""), mission.get("creatorName", "")]


## Put [param missions] (mission service dictionaries) up. The tiles of missions gone leave; the
## others stay where they are in the roll. New ones join newest first — while the feed is first
## read, at the end; afterwards near the bottom of the window, lit, since they are news.
func show_missions(missions: Array) -> void:
	var ordered: Array = MissionQuery.apply(missions, "", "", MissionQuery.Sort.NEWEST)
	var wanted: Dictionary = {}
	for mission: Dictionary in ordered:
		wanted[key_of(mission)] = mission
	# Where each mission stood, by id: a tile made again (its creator's name came) takes that place.
	var stood: Dictionary = {}
	for key: String in _tiles.keys():
		stood[key.get_slice("|", 0)] = (_tiles[key] as Node).get_index()
		if not wanted.has(key):
			var gone: Node = _tiles[key]
			_grid.remove_child(gone)
			gone.queue_free()
			_tiles.erase(key)
	var news: bool = _feed != null and _feed.is_loaded() and not stood.is_empty()
	var at: int = _arrival_index()
	var now: float = Time.get_unix_time_from_system()
	for key: String in wanted:
		if _tiles.has(key):
			continue
		var tile := MissionTile.new().setup(wanted[key], tile_zoom, now)
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_grid.add_child(tile)
		_tiles[key] = tile
		var id: String = str(wanted[key].get("id", ""))
		if stood.has(id):
			_grid.move_child(tile, mini(int(stood[id]), _grid.get_child_count() - 1))
		elif news:
			_grid.move_child(tile, mini(at, _grid.get_child_count() - 1))
			at += 1
			tile.highlight(HIGHLIGHT_S)
	_grid.reset_size()  # out of a container, a grid does not shrink by itself
	_empty.visible = _tiles.is_empty()
	_count.text = str(_tiles.size()) if not _tiles.is_empty() else ""


## Whether the tiles roll: only when they fill the window and a row more (else a gap would show).
func rolls() -> bool:
	return _grid.size.y >= _view.size.y + _row_px()


## Move the roll on by [param px]: a row gone out at the top goes to the bottom, behind the last one.
func advance(px: float) -> void:
	var row: float = _row_px()
	if row <= 0.0:
		return
	_offset += px
	while _offset >= row:
		for i: int in range(_grid.columns):
			_grid.move_child(_grid.get_child(0), -1)
		_offset -= row


func _process(delta: float) -> void:
	if rolls():
		advance(scroll_px_s * delta)
	else:
		_offset = 0.0
	_grid.position = Vector2(maxf((_view.size.x - _grid.size.x) * 0.5, 0.0), -_offset)


## One row's height with its gap (px), 0 with no tile.
func _row_px() -> float:
	if _grid.get_child_count() == 0:
		return 0.0
	return (_grid.get_child(0) as Control).size.y + GAP_PX


## Where news goes: the start of the window's second-to-last full row, seen at once and for a while.
func _arrival_index() -> int:
	var row: float = _row_px()
	if row <= 0.0:
		return 0
	var rows_seen: int = int((_view.size.y + _offset) / row)
	return clampi((rows_seen - 1) * _grid.columns, 0, _grid.get_child_count())


func _build() -> void:
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	panel.add_theme_stylebox_override("panel", bg)
	_viewport.add_child(panel)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN_PX)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", GAP_PX)
	margin.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 32)
	header.add_child(AresBrand.logo_control(AresBrand.Subsidiary.CORP, LOGO_PX))
	var title := AresBrand.screen_label("%%MISSION_BOARD_TITLE", TITLE_PX, Color.WHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)
	_count = AresBrand.screen_label("", COUNT_PX, MissionTile.DIM)
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_count)
	column.add_child(header)
	var rule := ColorRect.new()
	rule.color = Color.WHITE
	rule.custom_minimum_size = Vector2(0, 4)
	column.add_child(rule)

	# The window: the grid inside is placed by hand (_process), not by a container, so it can roll.
	_view = Control.new()
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.clip_contents = true
	column.add_child(_view)
	_grid = GridContainer.new()
	_grid.columns = columns_for(_viewport.size.x, tile_zoom)
	_grid.add_theme_constant_override("h_separation", GAP_PX)
	_grid.add_theme_constant_override("v_separation", GAP_PX)
	_view.add_child(_grid)
	_empty = AresBrand.screen_label("%%MISSION_BOARD_EMPTY", COUNT_PX, MissionTile.DIM)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.set_anchors_preset(Control.PRESET_CENTER)
	_view.add_child(_empty)
