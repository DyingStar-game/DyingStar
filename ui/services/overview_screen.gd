class_name ServiceOverviewScreen
extends VBoxContainer

## The tablet's home (A.R.E.S. OS mock-up, 2026-11): the player's card with the main balance, three
## cards that are shortcuts (active missions, friend requests, inventory), and the missions in
## progress, each one a way into its contract. Shown until an app is opened; refreshed on open and on
## every mutation.
##
## It never opens an app itself: it asks, and the tablet ([TerminalUI]) does it.

## A shortcut wants app [param id] on its segment [param segment], and that segment's own tab
## [param sub] (-1: leave it as it is).
signal open_app_requested(id: String, segment: int, sub: int)
## A row of "Missions in progress" wants its contract open in "My missions".
signal open_mission_requested(mission_id: String)

## How many missions in progress the home lists (each one costs a request for its objectives).
const MISSIONS_SHOWN: int = 3

var _avatar_letter: Label
var _name_label: Label
var _sub_label: Label
var _balance_label: Label
var _missions_value: Label
var _requests_value: Label
var _requests_line: Label
var _stacks_value: Label
var _missions_count: Label
var _missions_box: VBoxContainer
var _busy: bool = false


func setup() -> void:
	add_theme_constant_override("separation", 22)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_identity_card())
	add_child(_shortcuts())
	add_child(_missions_panel())


# ---------------------------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------------------------

func _identity_card() -> Control:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", ServiceStyle.flat(ServiceStyle.SURFACE_2,
			ServiceStyle.RADIUS_PANEL, ServiceStyle.LINE, 1, 32.0, 28.0))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	card.add_child(row)

	var avatar := Panel.new()
	avatar.custom_minimum_size = Vector2(88, 88)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.add_theme_stylebox_override("panel", ServiceStyle.flat(ServiceStyle.ACCENT_SOFT, 44,
			ServiceStyle.ACCENT, 2))
	_avatar_letter = ServiceStyle.ares_label("—", ServiceStyle.ACCENT, 36)
	_avatar_letter.set_anchors_preset(Control.PRESET_FULL_RECT)
	_avatar_letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar_letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar.add_child(_avatar_letter)
	row.add_child(avatar)

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.alignment = BoxContainer.ALIGNMENT_CENTER
	identity.add_theme_constant_override("separation", 10)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 14)
	_name_label = ServiceStyle.ares_label("—", ServiceStyle.TEXT, 30)
	name_row.add_child(_name_label)
	name_row.add_child(_online_pill())
	identity.add_child(name_row)
	_sub_label = ServiceStyle.label("", ServiceStyle.MUTED, ServiceStyle.SIZE_BODY)
	identity.add_child(_sub_label)
	row.add_child(identity)

	# The balance, behind a hairline, with the way to the bank under it.
	var money_box := PanelContainer.new()
	var edge := StyleBoxFlat.new()
	edge.bg_color = Color.TRANSPARENT
	edge.border_width_left = 1
	edge.border_color = ServiceStyle.LINE
	edge.content_margin_left = 36.0
	money_box.add_theme_stylebox_override("panel", edge)
	var money := VBoxContainer.new()
	money.alignment = BoxContainer.ALIGNMENT_CENTER
	money.add_theme_constant_override("separation", 6)
	var caption := ServiceStyle.label(tr("%%SVC_HOME_CAP_ACCOUNT"), ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money.add_child(caption)
	_balance_label = ServiceStyle.ares_label("—", ServiceStyle.ACCENT, 42)
	_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	money.add_child(_balance_label)
	var bank := _link(tr("%%SVC_HOME_OPEN_BANK"))
	bank.size_flags_horizontal = Control.SIZE_SHRINK_END
	bank.pressed.connect(func() -> void: open_app_requested.emit("economy", 0, 0))
	money.add_child(bank)
	money_box.add_child(money)
	row.add_child(money_box)
	return card


func _online_pill() -> Control:
	var pill := PanelContainer.new()
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ServiceStyle.apply_pill(pill, ServiceStyle.GOOD)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(9, 9)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.add_theme_stylebox_override("panel", ServiceStyle.flat(ServiceStyle.GOOD, 5, Color.TRANSPARENT, 0))
	row.add_child(dot)
	row.add_child(ServiceStyle.label(tr("%%SVC_HOME_ONLINE"), ServiceStyle.GOOD, ServiceStyle.SIZE_SMALL, true))
	pill.add_child(row)
	return pill


## The three shortcut cards: what is waiting, and the way to it.
func _shortcuts() -> Control:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 20)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var missions: Array = _shortcut(tr("%%SVC_HOME_CAP_MISSIONS"), tr("%%SVC_HOME_SEE_MISSIONS"), true,
			func() -> void: open_app_requested.emit("missions", 1, -1))
	_missions_value = missions[1]
	grid.add_child(missions[0])
	var requests: Array = _shortcut(tr("%%SVC_HOME_CAP_REQUESTS"), tr("%%SVC_HOME_NO_REQUESTS"), false,
			func() -> void: open_app_requested.emit("social", 0, 1))
	_requests_value = requests[1]
	_requests_line = requests[2]
	grid.add_child(requests[0])
	var stacks: Array = _shortcut(tr("%%SVC_HOME_CAP_INVENTORY"), tr("%%SVC_HOME_OPEN_INVENTORY"), true,
			func() -> void: open_app_requested.emit("properties", 0, 0))
	_stacks_value = stacks[1]
	grid.add_child(stacks[0])
	return grid


## One shortcut card: [card, value label, bottom line label].
func _shortcut(caption: String, line: String, accent_line: bool, handler: Callable) -> Array:
	var card := Button.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size = Vector2(0, 150)
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	ServiceStyle.apply_card_button(card)
	card.pressed.connect(handler)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 24.0
	box.offset_top = 20.0
	box.offset_right = -24.0
	box.offset_bottom = -20.0
	box.add_theme_constant_override("separation", 8)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)
	box.add_child(_quiet(ServiceStyle.label(caption, ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL)))
	var value := _quiet(ServiceStyle.ares_label("—", ServiceStyle.TEXT, 36))
	box.add_child(value)
	var bottom := _quiet(ServiceStyle.label(line, ServiceStyle.ACCENT if accent_line else ServiceStyle.MUTED,
			ServiceStyle.SIZE_SMALL, accent_line))
	box.add_child(bottom)
	return [card, value, bottom]


## The "Missions in progress" panel: its head (title, count, "See all") and the rows.
func _missions_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", ServiceStyle.flat(ServiceStyle.SURFACE_2,
			ServiceStyle.RADIUS_PANEL, ServiceStyle.LINE, 1, 28.0, 24.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.add_child(ServiceStyle.label(tr("%%SVC_HOME_MISSIONS_IN_PROGRESS").to_upper(), ServiceStyle.TEXT_2,
			ServiceStyle.SIZE_SMALL, true))
	_missions_count = ServiceStyle.label("", ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL)
	head.add_child(_missions_count)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var all := _link(tr("%%SVC_HOME_SEE_ALL"))
	all.pressed.connect(func() -> void: open_app_requested.emit("missions", 1, -1))
	head.add_child(all)
	box.add_child(head)

	_missions_box = VBoxContainer.new()
	_missions_box.add_theme_constant_override("separation", 10)
	_missions_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_missions_box)
	return panel


## One mission in progress: its step, title over its route and its time left, the next step over a
## progress bar, and the reward. A button: it opens the contract.
func _mission_row(row: Dictionary) -> Control:
	var tile := Button.new()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.custom_minimum_size = Vector2(0, 84)
	tile.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	ServiceStyle.apply_tile(tile)
	var mission_id: String = str(row.get("id", ""))
	tile.pressed.connect(func() -> void: open_mission_requested.emit(mission_id))
	var line := HBoxContainer.new()
	line.set_anchors_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 18.0
	line.offset_right = -22.0
	line.add_theme_constant_override("separation", 18)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(line)

	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(52, 52)
	thumb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ServiceStyle.apply_thumb(thumb)
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var step := _quiet(ServiceStyle.label(str(row.get("step", "")), ServiceStyle.ACCENT, ServiceStyle.SIZE_SMALL, true))
	step.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	step.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	thumb.add_child(step)
	line.add_child(thumb)

	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_theme_constant_override("separation", 4)
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := _quiet(ServiceStyle.label(str(row.get("title", "—")), ServiceStyle.TEXT, 17, true))
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	texts.add_child(title)
	var route: String = str(row.get("route", ""))
	if route != "":
		texts.add_child(_quiet(ServiceStyle.label(route, ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION)))
	var time_left: String = str(row.get("time", ""))
	if time_left != "":  # "Time left: 3h12" (playtest 2026-11-09)
		texts.add_child(_quiet(ServiceStyle.label(time_left, ServiceStyle.ACCENT, ServiceStyle.SIZE_CAPTION)))
	line.add_child(texts)

	var next := VBoxContainer.new()
	next.custom_minimum_size = Vector2(300, 0)
	next.alignment = BoxContainer.ALIGNMENT_CENTER
	next.add_theme_constant_override("separation", 8)
	next.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var next_label := _quiet(ServiceStyle.label(str(row.get("next", "")), ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION))
	next_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	next_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	next.add_child(next_label)
	var bar := ServicePanel._progress_bar(float(row.get("ratio", 0.0)), 5.0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	next.add_child(bar)
	line.add_child(next)

	var reward := _quiet(ServiceStyle.label(str(row.get("reward", "")), ServiceStyle.ACCENT, ServiceStyle.SIZE_BODY, true))
	reward.custom_minimum_size = Vector2(170, 0)
	reward.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	reward.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(reward)
	return tile


## A text link (the mock-up's "Open the bank →").
static func _link(text: String) -> Button:
	var button := Button.new()
	button.text = text
	ServiceStyle.apply_link(button)
	return button


## A label that lets clicks through to the card it decorates.
static func _quiet(label: Label) -> Label:
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


# ---------------------------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------------------------

func refresh() -> void:
	if _busy:
		return
	_busy = true
	var profile: Dictionary = await PlayerServices.profile_get()
	var wallet: Dictionary = await PlayerServices.wallet()
	# The cards only read counts, and the window they ride in says how many there are in all: one row
	# is as good as twenty, and costs less to carry.
	var requests: Dictionary = await PlayerServices.friend_requests(1)
	var inventory: Dictionary = await PlayerServices.inventory_me(1)
	var missions: Dictionary = await PlayerServices.my_missions("active", MISSIONS_SHOWN)
	_apply(profile, wallet, requests, inventory, missions)
	await _fill_missions(missions)
	_busy = false


func _apply(profile: Dictionary, wallet: Dictionary, requests: Dictionary, inventory: Dictionary,
		missions: Dictionary) -> void:
	if bool(profile.get("ok", false)) and profile.get("data") is Dictionary:
		var me: Dictionary = profile.get("data")
		var display: String = str(me.get("displayName", "—"))
		_name_label.text = display
		_avatar_letter.text = ServiceTypes.initial(display)
		var bits := PackedStringArray()
		var corporations: Variant = me.get("corporations")
		var corporation_found: bool = false
		if corporations is Array:
			for reference: Variant in corporations:
				if reference is Dictionary:
					bits.append(ServiceTypes.corporation_ref_line(reference))
					corporation_found = true
		if not corporation_found:
			bits.append(tr("%%SVC_MSG_NO_CORPORATION"))
		var group: Variant = me.get("group")
		if group is Dictionary:
			bits.append(ServiceTypes.dash((group as Dictionary).get("name")))
		bits.append(tr("%%SVC_FMT_REPUTATION") % ServiceTypes.num(me.get("reputation")))
		_sub_label.text = "  ·  ".join(bits)
	else:
		_name_label.text = tr("%%SVC_MSG_PROFILE_UNAVAILABLE")
		_sub_label.text = str(profile.get("error", ""))

	if bool(wallet.get("ok", false)):
		var accounts: Variant = (wallet.get("data") as Dictionary).get("accounts") \
				if wallet.get("data") is Dictionary else wallet.get("data")
		_balance_label.text = tr("%%SVC_FMT_CREDITS") % Globals.format_thousands(_main_balance(accounts))
	else:
		_balance_label.text = "—"

	if bool(requests.get("ok", false)) and requests.get("data") is Dictionary:
		# The incoming badge counts them all, not just the window the response carried.
		var waiting: int = ServicePage.total_of(requests, PackedStringArray(["incomingTotal"]))
		_requests_value.text = "%d" % waiting
		_requests_line.text = tr("%%SVC_HOME_SEE_REQUESTS") if waiting > 0 else tr("%%SVC_HOME_NO_REQUESTS")
		_requests_line.add_theme_color_override("font_color",
				ServiceStyle.ACCENT if waiting > 0 else ServiceStyle.MUTED)
	else:
		_requests_value.text = "?"
	# The stacks come whole (only the instances are paged): their count is the list length.
	_stacks_value.text = "%d" % ServicePage.items_of(inventory, "stacks").size() \
			if bool(inventory.get("ok", false)) else "?"
	var active: int = ServicePage.total_of(missions, PackedStringArray(["total"])) \
			if bool(missions.get("ok", false)) else -1
	_missions_value.text = "%d" % active if active >= 0 else "?"
	_missions_count.text = "%d" % active if active >= 0 else ""


## The missions in progress: each one read whole (a listing does not carry its objectives), so its
## row can say which step it is on and what comes next.
func _fill_missions(missions: Dictionary) -> void:
	ServicePanel._clear(_missions_box)
	var rows: Array = ServiceTypes.mission_rows(missions.get("data")) if bool(missions.get("ok", false)) else []
	if rows.is_empty():
		var empty := _empty_missions()
		_missions_box.add_child(empty)
		return
	for entry: Dictionary in rows.slice(0, MISSIONS_SHOWN):
		var mission: Variant = entry.get("mission")
		if not (mission is Dictionary):
			continue
		# The list row carries its progress (the mission service's summary): no read per mission.
		# Its time left, to the player's own deadline (the entry's assignment).
		var time_left := MissionTile.deadline_line(mission, Time.get_unix_time_from_system(), entry.get("assignment"))
		if entry.get("progress") is Dictionary:
			var summary := progress_summary(mission, entry.get("progress"))
			summary["time"] = time_left
			_missions_box.add_child(_mission_row(summary))
			continue
		# A service without the summary yet: read the mission whole.
		var mission_id: String = str((mission as Dictionary).get("id", ""))
		var detail: Dictionary = await PlayerServices.mission_get(mission_id)
		var data: Dictionary = detail.get("data") if detail.get("data") is Dictionary else {}
		if not is_inside_tree():
			return
		var whole := mission_summary(mission, data)
		whole["time"] = time_left
		_missions_box.add_child(_mission_row(whole))


## A row's facts from a mission and its list `progress` (GET /api/me/missions): the same as
## [method mission_summary] reads from the whole mission.
static func progress_summary(mission: Dictionary, progress: Dictionary) -> Dictionary:
	var current: Dictionary = progress.get("current") if progress.get("current") is Dictionary else {}
	var rewards: Variant = mission.get("rewards")
	if rewards == null:
		rewards = mission.get("reward")
	return {
		"id": str(mission.get("id", "")),
		"title": str(ServiceTypes.dash(mission.get("title"))),
		"step": "%d/%d" % [maxi(int(progress.get("step", 0)), 1), maxi(int(progress.get("steps", 0)), 1)],
		"next": str(ServiceTypes.dash(current.get("title"))) if not current.is_empty() else "",
		"ratio": ServiceTypes.progress_ratio(progress),
		"route": ServiceTypes.progress_route(progress),
		"reward": ServiceTypes.rewards_text(rewards),
	}


## A row's facts from a mission and its whole read ([param data], GET /api/missions/:id): the step it
## is on ("2/4"), title, route, the next step's sentence, how far that step is, and the reward.
static func mission_summary(mission: Dictionary, data: Dictionary) -> Dictionary:
	var objectives: Array = (data.get("objectives") as Array).filter(
			func(o: Variant) -> bool: return o is Dictionary) if data.get("objectives") is Array else []
	var current: int = objectives.size()
	for i: int in range(objectives.size()):
		if str((objectives[i] as Dictionary).get("status", "")) != "completed":
			current = i
			break
	var next := ""
	var ratio := 0.0
	var route := ""
	if current < objectives.size():
		var objective: Dictionary = objectives[current]
		next = str(ServiceTypes.dash(objective.get("title")))
		var target: int = ServiceTypes.num(objective.get("targetQuantity"))
		if target > 0:
			ratio = float(ServiceTypes.num(objective.get("currentProgress"))) / float(target)
	for objective: Dictionary in objectives:
		var from := _place_name(objective.get("locationFrom"))
		var to := _place_name(objective.get("locationTo"))
		if from != "" and to != "":
			route = "%s → %s" % [from, to]
			break
	var rewards: Variant = mission.get("rewards")
	if rewards == null:
		rewards = mission.get("reward")
	return {
		"id": str(mission.get("id", "")),
		"title": str(ServiceTypes.dash(mission.get("title"))),
		"step": "%d/%d" % [mini(current + 1, maxi(objectives.size(), 1)), maxi(objectives.size(), 1)],
		"next": next,
		"ratio": ratio,
		"route": route,
		"reward": ServiceTypes.rewards_text(rewards),
	}


## A mission location's village (or its name): the short form a route reads in.
static func _place_name(location: Variant) -> String:
	if not (location is Dictionary):
		return ""
	var village: Variant = (location as Dictionary).get("village")
	if village != null and str(village) != "":
		return str(village)
	var name: Variant = (location as Dictionary).get("name")
	return str(name) if name != null else ""


func _empty_missions() -> Control:
	# No button: a mission is taken at a town hall's kiosk, whatever the DataPad offers.
	return ServicePanel._empty_state(tr("%%SVC_HOME_NO_MISSIONS"), tr("%%SVC_HOME_NO_MISSIONS_TEXT"))


## The player's credits balance, or the first account when there is no `credits` one.
static func _main_balance(accounts: Variant) -> int:
	if not (accounts is Array):
		return 0
	var first: int = 0
	var seen: bool = false
	for account: Dictionary in accounts:
		if not seen:
			first = ServiceTypes.num(account.get("balance"))
			seen = true
		if str(account.get("currency", "")) == "credits":
			return ServiceTypes.num(account.get("balance"))
	return first
