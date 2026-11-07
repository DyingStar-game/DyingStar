class_name MissionKioskUI
extends Panel

## A mission kiosk's screen (MissionKiosk): the missions on offer here as tiles (MissionTile), sorted
## and filtered by category and by giver (MissionQuery); a tile opens its sheet (objectives, rewards,
## deadline, places) with ACCEPT. Each filter is one line of chips with "…" for a searchable list of
## the rest (ChipPicker), drawn on the screen itself: a pop-up window would open outside it. The chips
## offer only what the missions on offer hold, so a new category or a new faction needs nothing here.
## Pressing the chosen order again turns it round (its arrow says which way). A screen saver
## (ScreenAttract) covers it until pressed, and comes back when nobody uses it. Accepting goes straight to the mission
## service with the player's own token (PlayerServices.mission_accept): nothing in the world changes,
## and the service, not the screen, decides.
##
## The IN PROGRESS tab lists the player's own missions: each sheet shows every objective's progress,
## and a mission whose objectives are done and that is turned in at a town hall gets TURN IN, which
## asks the game server (MissionKiosk -> MissionTurnIn): only it knows where the kiosk stands.

const BG_COLOR := Color(0.06, 0.07, 0.09)
const TEXT := Color(0.92, 0.93, 0.95)
const DIM := Color(1.0, 1.0, 1.0, 0.55)
const WARN := Color(1.0, 0.45, 0.35)
const TITLE_PX: int = 30
const CHIP_PX: int = 20
const BODY_PX: int = 22
const BUTTON_PX: int = 30
const LOGO_PX: float = 48.0
const TILE_ZOOM: float = 1.08

var _accent: Color = Color.WHITE
var _feed: MissionFeed
var _missions: Array = []
var _category: String = ""
var _giver: String = ""
var _sort: MissionQuery.Sort = MissionQuery.Sort.REWARD
var _reverse: bool = false

var _list_view: VBoxContainer
var _sheet_view: VBoxContainer
var _category_chips: ChipPicker
var _giver_chips: ChipPicker
var _sort_chips: HBoxContainer
var _attract: ScreenAttract
var _grid: GridContainer
var _list_scroll: ScrollContainer
var _empty: Label
var _sheet: VBoxContainer
var _accept: Button
var _status: Label
## The mission whose sheet is open, {} on the list.
var _open: Dictionary = {}
## The IN PROGRESS tab is shown instead of the offers.
var _mine: bool = false
var _tab_chips: HBoxContainer
var _turn_in: Button


## Build the screen in [param subsidiary]'s colours (AresBrand), showing what [param feed] brings.
func setup(subsidiary: AresBrand.Subsidiary, feed: MissionFeed) -> void:
	_accent = AresBrand.colour(subsidiary)
	_build(subsidiary)
	_attract = ScreenAttract.new().setup(subsidiary, "%%MISSION_KIOSK_TITLE")
	_attract.slept.connect(_back_to_start)
	add_child(_attract)
	_feed = feed
	_feed.updated.connect(show_missions)
	show_missions(_feed.missions)


## The missions on offer changed: the chips and the tiles follow; an open sheet stays open.
func show_missions(missions: Array) -> void:
	_missions = missions
	var facets: Array = MissionQuery.facets(missions)
	if _category != "" and not (facets[0] as PackedStringArray).has(_category):
		_category = ""
	var giver_keys: Array = (facets[1] as Array).map(func(g: MissionGiver) -> String: return g.key())
	if _giver != "" and not giver_keys.has(_giver):
		_giver = ""
	_fill_category_chips(facets[0])
	_fill_giver_chips(facets[1])
	_fill_sort_chips()
	_render_tiles()


## The tiles shown under the current filters and order.
func shown() -> Array:
	return MissionQuery.apply(_missions, _category, _giver, _sort, _reverse)


## Whether a search field of this screen has the keyboard (MissionKiosk.is_typing).
## Screen view contract (ScreenLock): what its user is looking at, for the players watching.
func view_state() -> Dictionary:
	return {"awake": not _attract.visible, "mine": _mine, "category": _category, "giver": _giver,
			"sort": int(_sort), "reverse": _reverse, "open": str(_open.get("id", "")),
			"scroll": _list_scroll.scroll_vertical}


## Screen view contract (ScreenLock): show what the user of this kiosk is looking at. The missions are
## this player's own fetch (the "In progress" tab lists the watcher's), the page is the user's.
func apply_view_state(view: Dictionary) -> void:
	var awake := bool(view.get("awake", false))
	if awake:
		_attract.keep_awake()
	if awake and _attract.visible:
		_attract.wake()
	elif not awake and not _attract.visible:
		_attract.sleep()
	if bool(view.get("mine", false)) != _mine:
		_set_tab(bool(view.get("mine", false)))
	var filters := [str(view.get("category", "")), str(view.get("giver", "")), int(view.get("sort", 0)),
			bool(view.get("reverse", false))]
	if not _mine and filters != [_category, _giver, int(_sort), _reverse]:
		_category = filters[0]
		_giver = filters[1]
		_sort = filters[2] as MissionQuery.Sort
		_reverse = filters[3]
		show_missions(_missions)
	var open_id := str(view.get("open", ""))
	if open_id == "" and not _open.is_empty():
		_close_sheet()
	elif open_id != "" and str(_open.get("id", "")) != open_id:
		var mission: Dictionary = {"id": open_id}
		for m: Variant in _missions:
			if m is Dictionary and str((m as Dictionary).get("id", "")) == open_id:
				mission = m
		_open_sheet(mission)
	_list_scroll.scroll_vertical = int(view.get("scroll", 0))


func is_typing() -> bool:
	return _category_chips.is_typing() or _giver_chips.is_typing()


## Nobody uses the screen any more: the next one finds it as new — the list at its top, no filter,
## the default order, no sheet open.
func _back_to_start() -> void:
	_set_tab(false)
	_category_chips.close_list()
	_giver_chips.close_list()
	_close_sheet()
	_category = ""
	_giver = ""
	_sort = MissionQuery.Sort.REWARD
	_reverse = false
	show_missions(_missions)
	_list_scroll.scroll_vertical = 0


func _render_tiles() -> void:
	if _mine:
		return  # the IN PROGRESS tab fills the grid itself (_load_mine)
	_fill_grid(shown())


func _fill_grid(missions: Array) -> void:
	for tile: Node in _grid.get_children():
		tile.queue_free()
	var now: float = Time.get_unix_time_from_system()
	for mission: Dictionary in missions:
		var tile := MissionTile.new().setup(mission, TILE_ZOOM, now)
		tile.picked.connect(_open_sheet)
		_grid.add_child(tile)
	_empty.visible = _grid.get_child_count() == 0


# -- Filters -------------------------------------------------------------------------------------------

func _fill_category_chips(categories: PackedStringArray) -> void:
	var options: Array = []
	for id: String in categories:
		options.append({"value": id, "text": MissionCategories.label(id), "icon": MissionCategories.icon(id)})
	_category_chips.selected = _category
	_category_chips.set_options(options)


func _fill_giver_chips(givers: Array) -> void:
	var options: Array = []
	for giver: MissionGiver in givers:
		options.append({"value": giver.key(), "text": giver.display_name(), "colour": giver.colour()})
	_giver_chips.selected = _giver
	_giver_chips.set_options(options)


func _fill_sort_chips() -> void:
	_clear(_sort_chips)
	for sort: int in MissionQuery.SORT_KEYS:
		var text: String = TranslationServer.translate(MissionQuery.SORT_KEYS[sort])
		if _sort == sort:
			text += "  " + MissionQuery.arrow(sort, _reverse)
		_sort_chips.add_child(_chip(text, _sort == sort, _set_sort.bind(sort)))


func _set_category(id: String) -> void:
	_category = id
	show_missions(_missions)


func _set_giver(key: String) -> void:
	_giver = key
	show_missions(_missions)


## A new order, its own way round; the same one again, turned round.
func _set_sort(sort: MissionQuery.Sort) -> void:
	_reverse = not _reverse if sort == _sort else false
	_sort = sort
	show_missions(_missions)


# -- The mission sheet -----------------------------------------------------------------------------

func _open_sheet(mission: Dictionary) -> void:
	_open = mission
	_list_view.visible = false
	_sheet_view.visible = true
	_say("", DIM)
	_accept.disabled = false
	_accept.visible = true
	_turn_in.visible = false
	_fill_sheet(mission, [])
	var id: String = str(mission.get("id", ""))
	var result: Dictionary = await PlayerServices.mission_get(id)
	if _open.get("id") != mission.get("id"):
		return  # the player moved on meanwhile
	var data: Variant = result.get("data")
	if bool(result.get("ok", false)) and data is Dictionary:
		var full: Dictionary = data.get("mission") if data.get("mission") is Dictionary else mission
		var objectives: Array = data.get("objectives") if data.get("objectives") is Array else []
		_fill_sheet(full, objectives)
		var participants := ServiceTypes.participants_text(data.get("participants"))
		if participants != "":
			_sheet.add_child(_text(TranslationServer.translate("%%SVC_FMT_MISSION_PARTICIPANTS") % participants, DIM))
		var assignment: Variant = data.get("assignment")
		if assignment is Dictionary:
			_accept.visible = false  # already the player's
			_show_turn_in(full, objectives, assignment)
	else:
		_say(HttpClient.describe_error(result), WARN)


func _close_sheet() -> void:
	_open = {}
	_sheet_view.visible = false
	_list_view.visible = true


func _fill_sheet(mission: Dictionary, objectives: Array) -> void:
	_clear(_sheet)
	var giver: MissionGiver = MissionGivers.of_mission(mission)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	var picto := TextureRect.new()
	picto.texture = MissionCategories.icon(mission.get("category"))
	picto.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picto.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picto.custom_minimum_size = Vector2(64, 64)
	picto.modulate = giver.colour()
	head.add_child(picto)
	var title := AresBrand.screen_label(ServiceTypes.dash(mission.get("title")), TITLE_PX, TEXT)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.custom_minimum_size = Vector2(1, 0)
	head.add_child(title)
	_sheet.add_child(head)
	_sheet.add_child(_text("%s  ·  %s" % [giver.display_name(), MissionCategories.label(mission.get("category"))],
			giver.colour()))
	var description: String = str(mission.get("description", "")).strip_edges() \
			if mission.get("description") != null else ""
	if description != "":
		_sheet.add_child(_text(description, TEXT))
	if not objectives.is_empty():
		_sheet.add_child(_text("%%MISSION_OBJECTIVES", _accent))
		for objective: Variant in objectives:
			if objective is Dictionary:
				_sheet.add_child(_text("•  " + objective_line(objective) + progress_suffix(objective), TEXT))
				var step := ServiceTypes.transport_step_text(objective)
				if step != "":
					_sheet.add_child(_text("     " + step, _accent))
	var now: float = Time.get_unix_time_from_system()
	_sheet.add_child(_text(TranslationServer.translate("%%MISSION_REWARD")
			% MissionTile.reward_line(mission), TEXT))
	_sheet.add_child(_text(MissionTile.deadline_line(mission, now), DIM))
	_sheet.add_child(_text(TranslationServer.translate("%%MISSION_ZONES")
			% ServiceTypes.zones_text(mission.get("zones")), DIM))


## One objective as a line: its title, and how much when it counts some ("Deliver ore  ×12",
## "Deliver ingots  ×90 kg").
static func objective_line(objective: Dictionary) -> String:
	var line: String = ServiceTypes.dash(objective.get("title"))
	var target: int = ServiceTypes.num(objective.get("targetQuantity"), 1)
	if target > 1:
		line += "  ×" + ServiceTypes.quantity_text(target, objective.get("unit"))
	if bool(objective.get("isBonus", false)):
		line += "  (%s)" % TranslationServer.translate("%%MISSION_BONUS")
	return line


## The progress of a started objective ("  —  12 / 66", "  —  done"), "" when nothing counts yet.
static func progress_suffix(objective: Dictionary) -> String:
	if str(objective.get("status", "")) == "completed":
		return "  —  " + TranslationServer.translate("%%MISSION_OBJECTIVE_DONE")
	var progress: int = ServiceTypes.num(objective.get("currentProgress"), 0)
	if progress <= 0:
		return ""
	var unit: Variant = objective.get("unit")
	return "  —  %s / %s" % [ServiceTypes.quantity_text(progress, unit),
			ServiceTypes.quantity_text(ServiceTypes.num(objective.get("targetQuantity"), 1), unit)]


## Whether every required (non-bonus) objective is done: the mission can be turned in.
static func ready_to_turn_in(objectives: Array) -> bool:
	var any := false
	for o: Variant in objectives:
		if o is Dictionary and not bool(o.get("isBonus", false)):
			any = true
			if str(o.get("status", "")) != "completed":
				return false
	return any


## The player's mission: TURN IN when it waits for a town hall and its objectives are done, else
## where it stands.
func _show_turn_in(mission: Dictionary, objectives: Array, assignment: Dictionary) -> void:
	var turned_at_kiosk: bool = mission.get("autoComplete") == false
	if str(assignment.get("status", "")) != "active":
		_say("%%MISSION_ALREADY_YOURS", _accent)
	elif turned_at_kiosk and ready_to_turn_in(objectives):
		_turn_in.visible = true
		_turn_in.disabled = false
		_say("%%MISSION_READY_TO_TURN_IN", _accent)
	else:
		_say("%%MISSION_IN_PROGRESS", DIM)


func _on_turn_in_pressed() -> void:
	if _open.is_empty():
		return
	_turn_in.disabled = true
	_say("%%MISSION_TURNING_IN", DIM)
	ScreenTarget.send(ScreenTarget.owner_of(self), {"state": "turn_in", "mission_id": str(_open.get("id", ""))})


## The game server's answer to a TURN IN (MissionKiosk.screen_event).
func turn_in_result(event: Dictionary) -> void:
	if str(event.get("mission_id", "")) != str(_open.get("id", "")):
		return
	if bool(event.get("ok", false)):
		_turn_in.visible = false
		_say("%%MISSION_TURNED_IN", _accent)
		PlayerServices.changed.emit("missions")
	else:
		_turn_in.disabled = false
		var error := str(event.get("error", ""))
		_say("%%MISSION_TURN_IN_ELSEWHERE" if error == "WRONG_TOWN_HALL" else "%%MISSION_TURN_IN_FAILED", WARN)


# -- Tabs: offers / in progress ---------------------------------------------------------------------

func _set_tab(mine: bool) -> void:
	_mine = mine
	_clear(_tab_chips)
	_tab_chips.add_child(_chip(TranslationServer.translate("%%MISSION_TAB_OFFERS"), not mine, _set_tab.bind(false)))
	_tab_chips.add_child(_chip(TranslationServer.translate("%%MISSION_TAB_MINE"), mine, _set_tab.bind(true)))
	for line: Node in [_category_chips.get_parent(), _giver_chips.get_parent(), _sort_chips]:
		(line as Control).visible = not mine
	_close_sheet()
	if mine:
		_load_mine()
	else:
		_empty.text = "%%MISSION_BOARD_EMPTY"
		_render_tiles()


## The player's missions in progress, as tiles: a tile opens the sheet with each objective's progress.
func _load_mine() -> void:
	_fill_grid([])
	_empty.text = "%%MISSION_MINE_EMPTY"
	var result: Dictionary = await PlayerServices.my_missions("active", 50)
	if not _mine:
		return
	var missions: Array = []
	for row: Dictionary in ServiceTypes.mission_rows(result.get("data")):
		if row.get("mission") is Dictionary:
			missions.append(row["mission"])
	_fill_grid(missions)


func _on_accept_pressed() -> void:
	var mission: Dictionary = _open
	if mission.is_empty():
		return
	_accept.disabled = true
	_say("%%MISSION_ACCEPTING", DIM)
	var result: Dictionary = await PlayerServices.mission_accept(str(mission.get("id", "")),
			str(mission.get("title", "")))
	if _open.get("id") != mission.get("id"):
		return
	if bool(result.get("ok", false)):
		_accept.visible = false
		_say("%%MISSION_ACCEPTED", _accent)
	else:
		_accept.disabled = false
		_say(HttpClient.describe_error(result), WARN)


func _say(text: String, ink: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", ink)


# -- Building ---------------------------------------------------------------------------------------

func _build(subsidiary: AresBrand.Subsidiary) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG_COLOR
	add_theme_stylebox_override("panel", bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 20)
	header.add_child(AresBrand.logo_control(subsidiary, LOGO_PX))
	var title := AresBrand.screen_label("%%MISSION_KIOSK_TITLE", TITLE_PX, _accent)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)
	column.add_child(header)
	var rule := ColorRect.new()
	rule.color = _accent
	rule.custom_minimum_size = Vector2(0, 4)
	column.add_child(rule)
	_tab_chips = HBoxContainer.new()
	_tab_chips.add_theme_constant_override("separation", 8)
	column.add_child(_tab_chips)

	_list_view = VBoxContainer.new()
	_list_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_view.add_theme_constant_override("separation", 8)
	column.add_child(_list_view)
	_category_chips = _filter_line("%%MISSION_FILTER_TYPE", _set_category)
	_giver_chips = _filter_line("%%MISSION_FILTER_GIVER", _set_giver)
	_sort_chips = HBoxContainer.new()
	_sort_chips.add_theme_constant_override("separation", 8)
	_list_view.add_child(_sort_chips)
	_list_scroll = ScrollContainer.new()
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_view.add_child(_list_scroll)
	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.add_child(holder)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	holder.add_child(_grid)
	_empty = _text("%%MISSION_BOARD_EMPTY", DIM)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	holder.add_child(_empty)

	_sheet_view = VBoxContainer.new()
	_sheet_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sheet_view.visible = false
	column.add_child(_sheet_view)
	var sheet_scroll := ScrollContainer.new()
	sheet_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sheet_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_sheet_view.add_child(sheet_scroll)
	_sheet = VBoxContainer.new()
	_sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sheet.add_theme_constant_override("separation", 8)
	sheet_scroll.add_child(_sheet)
	_status = _text("", DIM)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sheet_view.add_child(_status)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 16)
	_sheet_view.add_child(buttons)
	var back := Button.new()
	back.text = "%%MISSION_BACK"
	back.custom_minimum_size = Vector2(240, 72)
	back.focus_mode = Control.FOCUS_NONE
	AresBrand.style_button(back, Color(1, 1, 1, 0.08), TEXT, BUTTON_PX)
	back.pressed.connect(_close_sheet)
	buttons.add_child(back)
	_accept = Button.new()
	_accept.text = "%%MISSION_ACCEPT"
	_accept.custom_minimum_size = Vector2(0, 72)
	_accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_accept.focus_mode = Control.FOCUS_NONE
	AresBrand.style_button(_accept, _accent, BG_COLOR, BUTTON_PX)
	_accept.pressed.connect(_on_accept_pressed)
	buttons.add_child(_accept)
	_turn_in = Button.new()
	_turn_in.text = "%%MISSION_TURN_IN"
	_turn_in.custom_minimum_size = Vector2(0, 72)
	_turn_in.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_turn_in.focus_mode = Control.FOCUS_NONE
	_turn_in.visible = false
	AresBrand.style_button(_turn_in, _accent, BG_COLOR, BUTTON_PX)
	_turn_in.pressed.connect(_on_turn_in_pressed)
	buttons.add_child(_turn_in)
	_set_tab(false)


## One filter's line: its caption [param caption_key], then its chips; [param choose] gets the value.
func _filter_line(caption_key: String, choose: Callable) -> ChipPicker:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	_list_view.add_child(line)
	var caption := AresBrand.screen_label(caption_key, CHIP_PX, DIM)
	caption.custom_minimum_size = Vector2(130, 0)
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(caption)
	var picker := ChipPicker.new()
	picker.accent = _accent
	picker.ink = TEXT
	picker.font_px = CHIP_PX
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.chosen.connect(choose)
	line.add_child(picker)
	return picker


## A filter's chip: lit in the kiosk's colour when [param on]; [param choose] when pressed.
func _chip(text: String, on: bool, choose: Callable) -> Button:
	var chip := Button.new()
	chip.text = text
	chip.focus_mode = Control.FOCUS_NONE
	chip.custom_minimum_size = Vector2(0, 44)
	AresBrand.style_button(chip, Color(_accent, 0.25) if on else Color(1, 1, 1, 0.05),
			_accent if on else TEXT, CHIP_PX)
	chip.pressed.connect(choose)
	return chip


func _text(text: String, ink: Color) -> Label:
	var line := AresBrand.screen_label(text, BODY_PX, ink)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.custom_minimum_size = Vector2(1, 0)
	return line


static func _clear(box: Node) -> void:
	for child: Node in box.get_children():
		box.remove_child(child)
		child.queue_free()
