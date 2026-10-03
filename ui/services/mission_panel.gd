extends ServicePanel

## Section « Missions » : browse, detail, accept/abandon/complete, report objective progress, and the
## caller's own assignments. Also creates player-sponsored missions. Covers /api/missions* and
## /api/me/missions.

## Value/key pairs: the raw value goes to the API, the key is the localized label. An empty value is
## the "all" filter and sends no filter.
const STATUS_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["available", "%%SVC_ENUM_STATUS_AVAILABLE"],
	["active", "%%SVC_ENUM_STATUS_ACTIVE"],
	["completed", "%%SVC_ENUM_STATUS_COMPLETED"],
	["cancelled", "%%SVC_ENUM_STATUS_CANCELLED"],
	["expired", "%%SVC_ENUM_STATUS_EXPIRED"],
]
const KIND_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["dynamic", "%%SVC_ENUM_KIND_DYNAMIC"],
	["scenario", "%%SVC_ENUM_KIND_SCENARIO"],
	["player", "%%SVC_ENUM_KIND_PLAYER"],
]
const CATEGORY_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["delivery", "%%SVC_ENUM_CATEGORY_DELIVERY"],
	["transport", "%%SVC_ENUM_CATEGORY_TRANSPORT"],
	["generic", "%%SVC_ENUM_CATEGORY_GENERIC"],
]
const VISIBILITY_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["public", "%%SVC_ENUM_VISIBILITY_PUBLIC"],
	["corporation", "%%SVC_ENUM_VISIBILITY_CORPORATION"],
]
const OBJECTIVE_TYPE_ENTRIES: Array = [
	["deliver_material", "%%SVC_ENUM_OBJECTIVE_DELIVER_MATERIAL"],
	["transport", "%%SVC_ENUM_OBJECTIVE_TRANSPORT"],
	["visit", "%%SVC_ENUM_OBJECTIVE_VISIT"],
	["custom", "%%SVC_ENUM_OBJECTIVE_CUSTOM"],
]

var _filter_status: OptionButton
var _kind: OptionButton
var _category: OptionButton
var _visibility: OptionButton
var _browse: ItemList
var _detail: Label
var _objectives: ItemList
var _objective_id: LineEdit
var _objective_qty: LineEdit
var _mine: ItemList
var _create_title: LineEdit
var _create_amount: LineEdit
var _create_objective: LineEdit
var _create_type: OptionButton
var _create_visibility: OptionButton
var _selected_id: String = ""


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_MISSIONS"), ServiceAppIcon.Kind.MISSIONS)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_child(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_AVAILABLE"), tr("%%SVC_TAB_MY_MISSIONS"),
			tr("%%SVC_TAB_DETAIL"), tr("%%SVC_TAB_CREATE")]))

	# Disponibles
	var filters := _row()
	_filter_status = _option_enum(STATUS_ENTRIES, 140.0)
	_kind = _option_enum(KIND_ENTRIES, 140.0)
	_category = _option_enum(CATEGORY_ENTRIES, 140.0)
	_visibility = _option_enum(VISIBILITY_ENTRIES, 140.0)
	filters.add_child(_label(tr("%%SVC_LBL_STATUS"), DIM))
	filters.add_child(_filter_status)
	filters.add_child(_label(tr("%%SVC_LBL_TYPE"), DIM))
	filters.add_child(_kind)
	filters.add_child(_label(tr("%%SVC_LBL_CATEGORY"), DIM))
	filters.add_child(_category)
	filters.add_child(_label(tr("%%SVC_LBL_VISIBILITY"), DIM))
	filters.add_child(_visibility)
	_action_button(filters, tr("%%SVC_ACT_BROWSE"), func() -> void: _browse_missions())
	pages[0].add_child(filters)
	_browse = _list(320.0)
	_browse.item_selected.connect(func(_i: int) -> void: _load_detail())
	pages[0].add_child(_titled(tr("%%SVC_LBL_AVAILABLE_MISSIONS"), _browse, true))

	# Mes missions
	_mine = _list(320.0)
	_mine.item_selected.connect(func(_i: int) -> void: _load_mine_detail())
	pages[1].add_child(_titled(tr("%%SVC_LBL_MY_MISSIONS"), _mine, true))

	# Détail
	_detail = _label(tr("%%SVC_MSG_SELECT_MISSION_DETAIL"), DIM)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pages[2].add_child(_titled(tr("%%SVC_LBL_MISSION"), _detail))
	_objectives = _list(160.0)
	pages[2].add_child(_titled(tr("%%SVC_LBL_OBJECTIVES"), _objectives))
	var actions := _row()
	_action_button(actions, tr("%%SVC_ACT_ACCEPT"), func() -> void: _accept())
	_action_button(actions, tr("%%SVC_ACT_ABANDON"), func() -> void: _abandon())
	_action_button(actions, tr("%%SVC_ACT_COMPLETE"), func() -> void: _complete())
	pages[2].add_child(actions)
	var progress := _row()
	_objective_id = _field(tr("%%SVC_PH_OBJECTIVE_ID"), 240.0)
	_objective_qty = _number_field(tr("%%SVC_PH_QUANTITY"), 100.0)
	progress.add_child(_label(tr("%%SVC_LBL_PROGRESS"), DIM))
	progress.add_child(_objective_id)
	progress.add_child(_objective_qty)
	_action_button(progress, tr("%%SVC_ACT_REPORT_PROGRESS"), func() -> void: _progress())
	pages[2].add_child(progress)

	# Créer
	var create := VBoxContainer.new()
	create.add_theme_constant_override("separation", 10)
	_create_title = _field(tr("%%SVC_PH_TITLE"), 280.0)
	_create_amount = _number_field(tr("%%SVC_PH_REWARD"), 140.0)
	_create_objective = _field(tr("%%SVC_PH_OBJECTIVE"), 280.0)
	_create_type = _option_enum(OBJECTIVE_TYPE_ENTRIES, 180.0)
	_create_visibility = _option_enum([["public", "%%SVC_ENUM_VISIBILITY_PUBLIC"],
			["corporation", "%%SVC_ENUM_VISIBILITY_CORPORATION"]], 160.0)
	create.add_child(_label(tr("%%SVC_LBL_TITLE"), DIM))
	create.add_child(_create_title)
	create.add_child(_label(tr("%%SVC_LBL_REWARD_CREDITS"), DIM))
	create.add_child(_create_amount)
	create.add_child(_label(tr("%%SVC_LBL_OBJECTIVE"), DIM))
	create.add_child(_create_objective)
	create.add_child(_label(tr("%%SVC_LBL_OBJECTIVE_TYPE"), DIM))
	create.add_child(_create_type)
	create.add_child(_label(tr("%%SVC_LBL_VISIBILITY"), DIM))
	create.add_child(_create_visibility)
	_action_button(create, tr("%%SVC_ACT_CREATE_MISSION"), func() -> void: _create())
	pages[3].add_child(_titled(tr("%%SVC_LBL_CREATE_MISSION"), create))

	add_child(_status_line())


func refresh() -> void:
	if not _begin_refresh():
		return
	var mine: Dictionary = await PlayerServices.my_missions()
	_apply_mine(mine)
	await _browse_missions()
	_end_refresh()


func _browse_missions() -> void:
	var result: Dictionary = await PlayerServices.missions_list(
			_enum_value(_filter_status), _enum_value(_kind), _enum_value(_category),
			"", "", _enum_value(_visibility))
	if not bool(result.get("ok", false)):
		_fill_list(_browse, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	var data: Variant = result.get("data")
	var missions: Variant = (data as Dictionary).get("missions") if data is Dictionary else data
	for mission: Dictionary in (missions if missions is Array else []):
		lines.append(ServiceTypes.mission_line(mission))
		metadata.append(mission)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_MISSIONS"))
	_fill_list(_browse, lines, metadata)
	_say(tr("%%SVC_FMT_MISSION_COUNT") % metadata.size(), DIM)


func _apply_mine(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_mine, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	var data: Variant = result.get("data")
	var missions: Variant = (data as Dictionary).get("missions") if data is Dictionary else data
	for entry: Dictionary in (missions if missions is Array else []):
		lines.append(ServiceTypes.player_mission_line(entry))
		metadata.append(entry)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_ASSIGNMENTS"))
	_fill_list(_mine, lines, metadata)


func _load_detail() -> void:
	var meta: Variant = _selected_meta(_browse)
	if not (meta is Dictionary):
		return
	_selected_id = str((meta as Dictionary).get("id", ""))
	if _selected_id != "":
		await _open_detail()


func _load_mine_detail() -> void:
	var meta: Variant = _selected_meta(_mine)
	if not (meta is Dictionary):
		return
	var mission: Variant = (meta as Dictionary).get("mission")
	if not (mission is Dictionary):
		return
	_selected_id = str((mission as Dictionary).get("id", ""))
	if _selected_id != "":
		await _open_detail()


func _open_detail() -> void:
	var result: Dictionary = await PlayerServices.mission_get(_selected_id)
	if not bool(result.get("ok", false)):
		_detail.text = HttpClient.describe_error(result)
		return
	if not (result.get("data") is Dictionary):
		_detail.text = tr("%%SVC_MSG_UNEXPECTED")
		return
	var data: Dictionary = result.get("data")
	var mission: Dictionary = data.get("mission", {}) if data.get("mission") is Dictionary else {}
	_detail.text = "\n".join([
		tr("%%SVC_FMT_MISSION_DETAIL_TITLE") % ServiceTypes.dash(mission.get("title")),
		tr("%%SVC_FMT_MISSION_DETAIL_TYPE") % [
				ServiceTypes.mission_kind_label(mission.get("kind")),
				ServiceTypes.mission_category_label(mission.get("category"))],
		tr("%%SVC_FMT_MISSION_DETAIL_STATUS") % ServiceTypes.mission_status_label(mission.get("status")),
		tr("%%SVC_FMT_MISSION_DETAIL_ISSUER") % ServiceTypes.issuer_type_label(mission.get("issuerType")),
		tr("%%SVC_FMT_MISSION_DETAIL_REWARD") % ServiceTypes.reward_text(mission.get("reward")),
		tr("%%SVC_FMT_MISSION_DETAIL_SLOTS") % ServiceTypes.num(mission.get("maxAssignees")),
		tr("%%SVC_FMT_MISSION_DETAIL_ASSIGNMENT") % (ServiceTypes.assignment_line(data.get("assignment"))
				if data.get("assignment") is Dictionary else tr("%%SVC_MSG_NONE")),
	])
	var lines := PackedStringArray()
	var metadata: Array = []
	for objective: Dictionary in (data.get("objectives", []) if data.get("objectives") is Array else []):
		lines.append(ServiceTypes.objective_line(objective))
		metadata.append(objective)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_OBJECTIVES"))
	_fill_list(_objectives, lines, metadata)
	goto_segment(2)


func _accept() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_MISSION"), WARN)
		return
	if _report(await PlayerServices.mission_accept(_selected_id), tr("%%SVC_MSG_MISSION_ACCEPTED")):
		await _load_detail()


func _abandon() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_MISSION"), WARN)
		return
	if _report(await PlayerServices.mission_abandon(_selected_id), tr("%%SVC_MSG_MISSION_ABANDONED")):
		await _load_detail()


func _complete() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_MISSION"), WARN)
		return
	var result: Dictionary = await PlayerServices.mission_complete(_selected_id)
	if _report(result, tr("%%SVC_MSG_MISSION_COMPLETED")):
		if result.get("data") is Dictionary and (result.get("data") as Dictionary).get("settlement") != null:
			_say(tr("%%SVC_MSG_MISSION_COMPLETED") + " " + ServiceTypes.settlement_text(
					(result.get("data") as Dictionary).get("settlement")), GOOD)
		await _load_detail()
		refresh()


func _progress() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_MISSION"), WARN)
		return
	release_fields()
	var objective_id: String = _objective_id.text.strip_edges()
	if objective_id == "":
		# Fall back to the selected objective in the list.
		var meta: Variant = _selected_meta(_objectives)
		if meta is Dictionary:
			objective_id = str((meta as Dictionary).get("id", ""))
	if objective_id == "" or not _objective_qty.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_OBJECTIVE_QUANTITY"), WARN)
		return
	var result: Dictionary = await PlayerServices.mission_progress(_selected_id, objective_id,
			int(_objective_qty.text))
	if _report(result, tr("%%SVC_MSG_PROGRESS_SAVED")):
		await _load_detail()


func _create() -> void:
	release_fields()
	var title: String = _create_title.text.strip_edges()
	var objective_title: String = _create_objective.text.strip_edges()
	if title == "" or objective_title == "":
		_say(tr("%%SVC_MSG_TITLE_OBJECTIVE_REQUIRED"), WARN)
		return
	var amount: int = int(_create_amount.text) if _create_amount.text.strip_edges().is_valid_int() else 1
	var body := {
		"title": title,
		"visibility": _enum_value(_create_visibility),
		"reward": {"economic": {"currency": "credits", "amount": amount}},
		"objectives": [{
			"type": _enum_value(_create_type),
			"title": objective_title,
			"targetQuantity": 1,
		}],
	}
	var result: Dictionary = await PlayerServices.mission_create(body)
	if _report(result, tr("%%SVC_MSG_MISSION_CREATED")):
		_create_title.text = ""
		_create_objective.text = ""
		refresh()
