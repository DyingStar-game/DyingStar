extends ServicePanel

## App « Corporations » : the player's corporations as sub-tiles, the directory (search/join/invite),
## the management of a selected corporation (members, ranks, requests, holding), creation, and the
## corporation treasury. Covers /api/corporations* and /api/me/corporations*.

const RECRUITMENT_ENTRIES: Array = [
	["open", "%%SVC_ENUM_RECRUITMENT_OPEN"],
	["apply", "%%SVC_ENUM_RECRUITMENT_APPLY"],
	["closed", "%%SVC_ENUM_RECRUITMENT_CLOSED"],
]

var _my_corps_grid: GridContainer
var _my_requests: ItemList
var _directory: ItemList
var _search: LineEdit
var _detail: Label
var _members: ItemList
var _ranks: ItemList
var _requests: ItemList
var _invite_player: LineEdit
var _rank_id: LineEdit
var _rank_name: LineEdit
var _rank_priority: LineEdit
var _rank_default: CheckBox
var _transfer_player: LineEdit
var _parent_id: LineEdit
var _create_name: LineEdit
var _create_ticker: LineEdit
var _create_recruitment: OptionButton
# Treasury (moved here from the bank).
var _corporation_id: LineEdit
var _corp_wallet: ItemList
var _corp_ledger: ItemList
var _corp_report: ItemList
var _corp_from: LineEdit
var _corp_to: LineEdit
var _donation_amount: LineEdit
var _selected_id: String = ""
# Salaires / prime / paie (economie endpoints).
var _salary_roles: ItemList
var _salary_members: ItemList
var _salary_role: LineEdit
var _salary_role_amount: LineEdit
var _salary_member: LineEdit
var _salary_member_amount: LineEdit
var _prime_player: LineEdit
var _prime_amount: LineEdit


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_CORPORATIONS"), ServiceAppIcon.Kind.CORPORATIONS)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_child(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_CORPS"), tr("%%SVC_TAB_DIRECTORY"), tr("%%SVC_TAB_MANAGE"),
			tr("%%SVC_TAB_CREATE"), tr("%%SVC_TAB_TREASURY")]))

	# Mes corps — one sub-tile per corporation, then the two entries (join / create), then invitations.
	_my_corps_grid = GridContainer.new()
	_my_corps_grid.columns = 2
	_my_corps_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_my_corps_grid.add_theme_constant_override("h_separation", 12)
	_my_corps_grid.add_theme_constant_override("v_separation", 12)
	pages[0].add_child(_titled(tr("%%SVC_LBL_MY_CORPORATIONS"), _my_corps_grid))
	var entries := _row()
	_action_button(entries, tr("%%SVC_ACT_JOIN_CORP"), func() -> void: goto_segment(1))
	_action_button(entries, tr("%%SVC_ACT_CREATE_CORP"), func() -> void: goto_segment(3))
	pages[0].add_child(entries)
	_my_requests = _list(150.0)
	pages[0].add_child(_titled(tr("%%SVC_LBL_PENDING_REQUESTS"), _my_requests, true))
	var my_req_row := _row()
	_action_button(my_req_row, tr("%%SVC_ACT_ACCEPT"), func() -> void: _my_request(true))
	_action_button(my_req_row, tr("%%SVC_ACT_DECLINE"), func() -> void: _my_request(false))
	pages[0].add_child(my_req_row)

	# Annuaire
	var search_row := _row()
	_search = _field(tr("%%SVC_PH_SEARCH"), 240.0)
	_search.text_submitted.connect(func(_t: String) -> void: _search_directory())
	search_row.add_child(_search)
	_action_button(search_row, tr("%%SVC_ACT_SEARCH"), func() -> void: _search_directory())
	_action_button(search_row, tr("%%SVC_ACT_JOIN"), func() -> void: _join_selected())
	pages[1].add_child(search_row)
	_directory = _list(320.0)
	_directory.item_selected.connect(func(_i: int) -> void: _load_detail())
	pages[1].add_child(_titled(tr("%%SVC_LBL_DIRECTORY"), _directory, true))
	var invite_row := _row()
	_invite_player = _field(tr("%%SVC_PH_INVITE_PLAYER"), 260.0)
	invite_row.add_child(_invite_player)
	_action_button(invite_row, tr("%%SVC_ACT_INVITE"), func() -> void: _invite_selected())
	pages[1].add_child(invite_row)

	# Gérer (detail + membership actions)
	_detail = _label(tr("%%SVC_MSG_SELECT_CORP"), DIM)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pages[2].add_child(_titled(tr("%%SVC_LBL_CORPORATION"), _detail))
	var membership_row := _row()
	_action_button(membership_row, tr("%%SVC_ACT_LEAVE"), func() -> void: _leave_selected())
	_action_button(membership_row, tr("%%SVC_ACT_DISBAND"), func() -> void: _disband_selected())
	pages[2].add_child(membership_row)
	var detail_columns := _row(18)
	_members = _list(150.0)
	detail_columns.add_child(_titled(tr("%%SVC_LBL_MEMBERS"), _members, true))
	_ranks = _list(150.0)
	detail_columns.add_child(_titled(tr("%%SVC_LBL_RANKS"), _ranks, true))
	_requests = _list(150.0)
	detail_columns.add_child(_titled(tr("%%SVC_LBL_REQUESTS"), _requests, true))
	pages[2].add_child(detail_columns)

	var manage_row := _row()
	_rank_id = _number_field(tr("%%SVC_PH_RANK_ID"), 110.0)
	manage_row.add_child(_label(tr("%%SVC_LBL_RANK"), DIM))
	manage_row.add_child(_rank_id)
	_action_button(manage_row, tr("%%SVC_ACT_APPLY"), func() -> void: _set_member_rank())
	_action_button(manage_row, tr("%%SVC_ACT_REMOVE_MEMBER"), func() -> void: _remove_member())
	_action_button(manage_row, tr("%%SVC_ACT_ACCEPT_REQUEST"), func() -> void: _request_action(true))
	_action_button(manage_row, tr("%%SVC_ACT_DECLINE_REQUEST"), func() -> void: _request_action(false))
	pages[2].add_child(manage_row)

	var rank_row := _row()
	_rank_name = _field(tr("%%SVC_PH_RANK_NAME"), 170.0)
	_rank_priority = _number_field(tr("%%SVC_PH_PRIORITY"), 110.0)
	_rank_default = CheckBox.new()
	rank_row.add_child(_rank_name)
	rank_row.add_child(_rank_priority)
	rank_row.add_child(_label(tr("%%SVC_LBL_DEFAULT"), DIM))
	rank_row.add_child(_rank_default)
	_action_button(rank_row, tr("%%SVC_ACT_CREATE_RANK"), func() -> void: _create_rank())
	_action_button(rank_row, tr("%%SVC_ACT_DELETE_RANK"), func() -> void: _delete_rank())
	pages[2].add_child(rank_row)

	var transfer_row := _row()
	_transfer_player = _field(tr("%%SVC_PH_NEW_LEADER"), 240.0)
	transfer_row.add_child(_transfer_player)
	_action_button(transfer_row, tr("%%SVC_ACT_TRANSFER"), func() -> void: _transfer())
	pages[2].add_child(transfer_row)

	var parent_row := _row()
	_parent_id = _field(tr("%%SVC_PH_PARENT_HOLDING"), 260.0)
	parent_row.add_child(_parent_id)
	_action_button(parent_row, tr("%%SVC_ACT_ATTACH"), func() -> void: _set_parent())
	_action_button(parent_row, tr("%%SVC_ACT_DETACH"), func() -> void: _detach_parent())
	pages[2].add_child(parent_row)

	# Créer
	var create := VBoxContainer.new()
	create.add_theme_constant_override("separation", 10)
	_create_name = _field(tr("%%SVC_LBL_NAME"), 260.0)
	_create_ticker = _field(tr("%%SVC_LBL_TICKER"), 120.0)
	_create_recruitment = _option_enum(RECRUITMENT_ENTRIES)
	create.add_child(_label(tr("%%SVC_LBL_NAME"), DIM))
	create.add_child(_create_name)
	create.add_child(_label(tr("%%SVC_LBL_TICKER"), DIM))
	create.add_child(_create_ticker)
	create.add_child(_label(tr("%%SVC_LBL_RECRUITMENT"), DIM))
	create.add_child(_create_recruitment)
	_action_button(create, tr("%%SVC_ACT_CREATE_CORP"), func() -> void: _create_corporation())
	pages[3].add_child(_titled(tr("%%SVC_ACT_CREATE_CORP"), create))

	# Trésorerie
	var corp := VBoxContainer.new()
	corp.add_theme_constant_override("separation", 10)
	_corporation_id = _field(tr("%%SVC_PH_CORP_ID"), 300.0)
	_corp_from = _field(tr("%%SVC_PH_FROM"), 170.0)
	_corp_to = _field(tr("%%SVC_PH_TO"), 170.0)
	corp.add_child(_label(tr("%%SVC_LBL_CORPORATION"), DIM))
	corp.add_child(_corporation_id)
	var load_row := _row()
	_action_button(load_row, tr("%%SVC_ACT_LOAD"), func() -> void: _load_corp())
	_action_button(load_row, tr("%%SVC_ACT_REPORT"), func() -> void: _load_report())
	corp.add_child(load_row)
	corp.add_child(_label(tr("%%SVC_LBL_REPORT_PERIOD"), DIM))
	var period := _row()
	period.add_child(_corp_from)
	period.add_child(_corp_to)
	corp.add_child(period)
	pages[4].add_child(_titled(tr("%%SVC_TAB_TREASURY"), corp))
	_corp_wallet = _list(120.0)
	pages[4].add_child(_titled(tr("%%SVC_LBL_CORP_ACCOUNTS"), _corp_wallet, true))
	_corp_ledger = _list(120.0)
	pages[4].add_child(_titled(tr("%%SVC_LBL_LEDGER"), _corp_ledger, true))
	_corp_report = _list(120.0)
	pages[4].add_child(_titled(tr("%%SVC_LBL_FINANCIAL_REPORT"), _corp_report, true))
	var donation := _row()
	_donation_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	donation.add_child(_label(tr("%%SVC_LBL_DONATION"), DIM))
	donation.add_child(_donation_amount)
	_action_button(donation, tr("%%SVC_ACT_DONATE"), func() -> void: _donate())
	pages[4].add_child(donation)

	# Salaires / prime / paie (mêmes corporation id que la trésorerie).
	var salary_columns := _row(18)
	_salary_roles = _list(120.0)
	salary_columns.add_child(_titled(tr("%%SVC_LBL_ROLE_DEFAULTS"), _salary_roles, true))
	_salary_members = _list(120.0)
	salary_columns.add_child(_titled(tr("%%SVC_LBL_MEMBER_OVERRIDES"), _salary_members, true))
	pages[4].add_child(salary_columns)
	_action_button(pages[4], tr("%%SVC_ACT_LOAD_SALARIES"), func() -> void: _load_salaries())

	var role_salary := _row()
	_salary_role = _field(tr("%%SVC_PH_ROLE"), 140.0)
	_salary_role_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	role_salary.add_child(_label(tr("%%SVC_LBL_ROLE"), DIM))
	role_salary.add_child(_salary_role)
	role_salary.add_child(_salary_role_amount)
	_action_button(role_salary, tr("%%SVC_ACT_SET_ROLE_SALARY"), func() -> void: _set_role_salary())
	pages[4].add_child(role_salary)

	var member_salary := _row()
	_salary_member = _field(tr("%%SVC_PH_PLAYER_ID"), 240.0)
	_salary_member_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	member_salary.add_child(_label(tr("%%SVC_LBL_MEMBER"), DIM))
	member_salary.add_child(_salary_member)
	member_salary.add_child(_salary_member_amount)
	_action_button(member_salary, tr("%%SVC_ACT_SET_MEMBER_SALARY"), func() -> void: _set_member_salary())
	_action_button(member_salary, tr("%%SVC_ACT_REMOVE_SALARY"), func() -> void: _remove_member_salary())
	pages[4].add_child(member_salary)

	var prime_row := _row()
	_prime_player = _field(tr("%%SVC_PH_PLAYER_ID"), 240.0)
	_prime_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	prime_row.add_child(_label(tr("%%SVC_LBL_PRIME"), DIM))
	prime_row.add_child(_prime_player)
	prime_row.add_child(_prime_amount)
	_action_button(prime_row, tr("%%SVC_ACT_PRIME"), func() -> void: _prime())
	pages[4].add_child(prime_row)

	_action_button(pages[4], tr("%%SVC_ACT_PAYROLL"), func() -> void: _payroll())

	add_child(_status_line())


func refresh() -> void:
	if not _begin_refresh():
		return
	var mine: Dictionary = await PlayerServices.my_corporations()
	var my_requests: Dictionary = await PlayerServices.my_corporation_requests()
	var directory: Dictionary = await PlayerServices.corporations_list()
	_apply_mine(mine)
	_apply_my_requests(my_requests)
	_apply_directory(directory)
	_end_refresh()


func _apply_mine(result: Dictionary) -> void:
	for child: Node in _my_corps_grid.get_children():
		_my_corps_grid.remove_child(child)
		child.queue_free()
	if not bool(result.get("ok", false)):
		_my_corps_grid.add_child(_label(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), WARN))
		return
	var memberships: Variant = result.get("data")
	if not (memberships is Array) or (memberships as Array).is_empty():
		var empty := _label(tr("%%SVC_MSG_NO_CORPS"), ServiceStyle.MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_my_corps_grid.columns = 1
		_my_corps_grid.add_child(empty)
		return
	_my_corps_grid.columns = 2
	for membership: Dictionary in memberships:
		_my_corps_grid.add_child(_corp_tile(membership))


## One corporation as a tappable sub-tile: name over ticker · rank. Tapping opens its management.
func _corp_tile(membership: Dictionary) -> Button:
	var id: String = str(membership.get("id", ""))
	var tile := Button.new()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.custom_minimum_size = Vector2(0, 92)
	ServiceStyle.apply_tile(tile)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 12.0
	box.offset_right = -12.0
	box.offset_top = 10.0
	box.offset_bottom = -10.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := _label(str(membership.get("name", "—")), ServiceStyle.TEXT)
	ServiceStyle.font_of(name_label, 16, true)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)
	var rank_name: String = ""
	if membership.get("rank") is Dictionary:
		rank_name = str((membership.get("rank") as Dictionary).get("name", ""))
	var sub := _label("%s   ·   %s" % [ServiceTypes.dash(membership.get("ticker")), rank_name],
			ServiceStyle.MUTED)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(sub)
	tile.add_child(box)
	tile.pressed.connect(func() -> void: _select_corp(id))
	return tile


func _apply_my_requests(result: Dictionary) -> void:
	_fill_requests(_my_requests, result, tr("%%SVC_MSG_NO_PENDING"))


func _apply_directory(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_directory, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for corp: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(ServiceTypes.corporation_line(corp))
		metadata.append(corp)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_CORPORATION_EMPTY"))
	_fill_list(_directory, lines, metadata)


func _fill_requests(list: ItemList, result: Dictionary, empty: String) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for request: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(ServiceTypes.request_line(request))
		metadata.append(request)
	if lines.is_empty():
		lines.append(empty)
	_fill_list(list, lines, metadata)


func _search_directory() -> void:
	release_fields()
	var result: Dictionary = await PlayerServices.corporations_list(_search.text.strip_edges())
	_apply_directory(result)


func _select_corp(id: String) -> void:
	await _open_detail(id)


func _load_detail() -> void:
	var meta: Variant = _selected_meta(_directory)
	if meta is Dictionary:
		await _open_detail(str((meta as Dictionary).get("id", "")))


func _join_selected() -> void:
	var meta: Variant = _selected_meta(_directory)
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	_report(await PlayerServices.corporation_join(str((meta as Dictionary).get("id", ""))),
			tr("%%SVC_MSG_JOIN_SENT"))


func _invite_selected() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	_invite_by_id()


func _invite_by_id() -> void:
	release_fields()
	var player_id: String = _invite_player.text.strip_edges()
	if _selected_id == "" or player_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_AND_PLAYER"), WARN)
		return
	_report(await PlayerServices.corporation_invite(_selected_id, player_id), tr("%%SVC_MSG_INVITE_SENT"))


## Load a corporation's detail and open the management tab.
func _open_detail(corporation_id: String) -> void:
	if corporation_id == "":
		return
	_selected_id = corporation_id
	var detail: Dictionary = await PlayerServices.corporation_get(_selected_id)
	var subsidiaries: Dictionary = await PlayerServices.corporation_subsidiaries(_selected_id)
	if bool(detail.get("ok", false)) and detail.get("data") is Dictionary:
		var corp: Dictionary = detail.get("data")
		var parent_text: String = ServiceTypes.dash(corp.get("parentId"))
		var subsidiary_text := PackedStringArray()
		if bool(subsidiaries.get("ok", false)) and subsidiaries.get("data") is Array:
			for subsidiary: Dictionary in subsidiaries.get("data"):
				subsidiary_text.append(ServiceTypes.corporation_line(subsidiary))
		_detail.text = "\n".join([
			ServiceTypes.corporation_line(corp),
			tr("%%SVC_FMT_CORP_PARENT") % parent_text,
			tr("%%SVC_FMT_CORP_SUBSIDIARIES") % (tr("%%SVC_MSG_NONE")
					if subsidiary_text.is_empty() else ", ".join(subsidiary_text)),
		])
	elif not bool(detail.get("ok", false)):
		_detail.text = HttpClient.describe_error(detail)
	var members: Dictionary = await PlayerServices.corporation_members(_selected_id)
	var ranks: Dictionary = await PlayerServices.corporation_ranks(_selected_id)
	var requests: Dictionary = await PlayerServices.corporation_requests(_selected_id)
	_fill_simple(_members, members, ServiceTypes.member_line, tr("%%SVC_MSG_NO_MEMBERS"))
	_fill_simple(_ranks, ranks, ServiceTypes.rank_line, tr("%%SVC_MSG_NO_RANKS"))
	_fill_requests(_requests, requests, tr("%%SVC_MSG_NO_REQUESTS"))
	goto_segment(2)


func _fill_simple(list: ItemList, result: Dictionary, formatter: Callable, empty: String) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for item: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(formatter.call(item))
		metadata.append(item)
	if lines.is_empty():
		lines.append(empty)
	_fill_list(list, lines, metadata)


func _set_member_rank() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	var member: Variant = _selected_meta(_members)
	if not (member is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_MEMBER"), WARN)
		return
	if not _rank_id.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_RANK_ID"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_member_rank(_selected_id,
			str((member as Dictionary).get("playerId", "")), int(_rank_id.text))
	if _report(result, tr("%%SVC_MSG_RANK_UPDATED")):
		_open_detail(_selected_id)


func _remove_member() -> void:
	if _selected_id == "":
		return
	var member: Variant = _selected_meta(_members)
	if not (member is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_MEMBER"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_member_remove(_selected_id,
			str((member as Dictionary).get("playerId", "")))
	if _report(result, tr("%%SVC_MSG_MEMBER_REMOVED")):
		_open_detail(_selected_id)


func _request_action(accept: bool) -> void:
	if _selected_id == "":
		return
	var meta: Variant = _selected_meta(_requests)
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_REQUEST"), WARN)
		return
	var request_id: int = ServiceTypes.num((meta as Dictionary).get("id"))
	var result: Dictionary
	if accept:
		result = await PlayerServices.corporation_request_accept(_selected_id, request_id)
	else:
		result = await PlayerServices.corporation_request_decline(_selected_id, request_id)
	if _report(result, tr("%%SVC_MSG_REQUEST_HANDLED")):
		_open_detail(_selected_id)


func _create_rank() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	release_fields()
	var priority: int = int(_rank_priority.text) if _rank_priority.text.strip_edges().is_valid_int() else 0
	var result: Dictionary = await PlayerServices.corporation_rank_create(_selected_id,
			_rank_name.text.strip_edges(), priority, [], _rank_default.button_pressed)
	if _report(result, tr("%%SVC_MSG_RANK_CREATED")):
		_open_detail(_selected_id)


func _delete_rank() -> void:
	if _selected_id == "":
		return
	var rank: Variant = _selected_meta(_ranks)
	if not (rank is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_RANK"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_rank_delete(_selected_id,
			ServiceTypes.num((rank as Dictionary).get("id")))
	if _report(result, tr("%%SVC_MSG_RANK_DELETED")):
		_open_detail(_selected_id)


func _transfer() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	var player_id: String = _transfer_player.text.strip_edges()
	if player_id == "":
		_say(tr("%%SVC_MSG_NEED_NEW_LEADER"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_transfer(_selected_id, player_id)
	if _report(result, tr("%%SVC_MSG_TRANSFER_DONE")):
		_open_detail(_selected_id)


func _create_corporation() -> void:
	release_fields()
	var name: String = _create_name.text.strip_edges()
	var ticker: String = _create_ticker.text.strip_edges()
	if name == "" or ticker == "":
		_say(tr("%%SVC_MSG_NAME_TICKER_REQUIRED"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_create(name, ticker, "",
			_enum_value(_create_recruitment) if _create_recruitment != null else "apply")
	if _report(result, tr("%%SVC_MSG_CORP_CREATED")):
		_create_name.text = ""
		_create_ticker.text = ""
		refresh()


func _my_request(accept: bool) -> void:
	var meta: Variant = _selected_meta(_my_requests)
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_REQUEST"), WARN)
		return
	var request_id: int = ServiceTypes.num((meta as Dictionary).get("id"))
	var result: Dictionary
	if accept:
		result = await PlayerServices.my_corporation_request_accept(request_id)
	else:
		result = await PlayerServices.my_corporation_request_decline(request_id)
	if _report(result, tr("%%SVC_MSG_REQUEST_HANDLED")):
		refresh()


## Attach the selected corporation under a holding company (`Rattacher`).
func _set_parent() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	release_fields()
	var parent_id: String = _parent_id.text.strip_edges()
	if parent_id == "":
		_say(tr("%%SVC_MSG_NEED_PARENT"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_set_parent(_selected_id, parent_id)
	if _report(result, tr("%%SVC_MSG_PARENT_SET")):
		_parent_id.text = ""
		_open_detail(_selected_id)


## Detach the selected corporation from its holding company (`Détacher`, parentId null).
func _detach_parent() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_set_parent(_selected_id, "")
	if _report(result, tr("%%SVC_MSG_CORP_DETACHED")):
		_open_detail(_selected_id)


func _leave_selected() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	var player_id: String = PlayerServices.player_id()
	if player_id == "":
		_say(tr("%%SVC_MSG_NO_PLAYER_ID"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_member_remove(_selected_id, player_id)
	if _report(result, tr("%%SVC_MSG_CORP_LEFT")):
		refresh()


func _disband_selected() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_disband(_selected_id)
	if _report(result, tr("%%SVC_MSG_CORP_DISBANDED")):
		refresh()


# ---------------------------------------------------------------------------------------------
# Treasury (moved here from the bank)
# ---------------------------------------------------------------------------------------------

func _load_corp() -> void:
	release_fields()
	var corporation_id: String = _corporation_id.text.strip_edges()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	var wallet: Dictionary = await PlayerServices.corporation_wallet(corporation_id)
	var ledger: Dictionary = await PlayerServices.corporation_wallet_transactions(corporation_id)
	_apply_corp_accounts(wallet)
	_apply_corp_ledger(ledger)


func _apply_corp_accounts(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_corp_wallet, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var data: Variant = result.get("data")
	var accounts: Variant = (data as Dictionary).get("accounts") if data is Dictionary else data
	var lines := PackedStringArray()
	var metadata: Array = []
	for account: Dictionary in (accounts if accounts is Array else []):
		lines.append(ServiceTypes.account_line(account))
		metadata.append(account)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_ACCOUNTS"))
	_fill_list(_corp_wallet, lines, metadata)


func _apply_corp_ledger(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_corp_ledger, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for transaction: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(ServiceTypes.transaction_line(transaction))
		metadata.append(transaction)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_TRANSACTIONS"))
	_fill_list(_corp_ledger, lines, metadata)


func _load_report() -> void:
	release_fields()
	var corporation_id: String = _corporation_id.text.strip_edges()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_report(corporation_id,
			_corp_from.text.strip_edges(), _corp_to.text.strip_edges())
	if not bool(result.get("ok", false)):
		_fill_list(_corp_report, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var data: Dictionary = result.get("data", {}) if result.get("data") is Dictionary else {}
	var lines := PackedStringArray()
	var metadata: Array = []
	for total: Dictionary in (data.get("totals", []) if data.get("totals") is Array else []):
		lines.append(ServiceTypes.report_total_line(total))
		metadata.append(total)
	for entry: Dictionary in (data.get("byType", []) if data.get("byType") is Array else []):
		lines.append("%s  %s  x%d  +%d / -%d" % [ServiceTypes.dash(entry.get("type")),
				ServiceTypes.dash(entry.get("currency")), ServiceTypes.num(entry.get("count")),
				ServiceTypes.num(entry.get("inflow")), ServiceTypes.num(entry.get("outflow"))])
		metadata.append(entry)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_MOVEMENTS"))
	_fill_list(_corp_report, lines, metadata)


func _donate() -> void:
	release_fields()
	var corporation_id: String = _corporation_id.text.strip_edges()
	if corporation_id == "" or not _donation_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_CORP_AMOUNT"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_donation(corporation_id,
			int(_donation_amount.text))
	if _report(result, tr("%%SVC_MSG_DONATION_SENT")):
		_donation_amount.text = ""
		_load_corp()


# ---------------------------------------------------------------------------------------------
# Salaires / prime / paie (economie)
# ---------------------------------------------------------------------------------------------

func _load_salaries() -> void:
	release_fields()
	var corporation_id: String = _corporation_id.text.strip_edges()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_salaries(corporation_id)
	if not bool(result.get("ok", false)):
		var error: String = tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))
		_fill_list(_salary_roles, PackedStringArray([error]))
		_fill_list(_salary_members, PackedStringArray([error]))
		return
	var data: Dictionary = result.get("data", {}) if result.get("data") is Dictionary else {}
	_apply_salary_list(_salary_roles, data.get("roleDefaults"), ServiceTypes.salary_role_line,
			tr("%%SVC_MSG_NO_SALARIES"))
	_apply_salary_list(_salary_members, data.get("memberOverrides"), ServiceTypes.salary_member_line,
			tr("%%SVC_MSG_NO_SALARIES"))


func _apply_salary_list(list: ItemList, value: Variant, formatter: Callable, empty: String) -> void:
	var lines := PackedStringArray()
	var metadata: Array = []
	for entry: Dictionary in (value if value is Array else []):
		lines.append(formatter.call(entry))
		metadata.append(entry)
	if lines.is_empty():
		lines.append(empty)
	_fill_list(list, lines, metadata)


func _set_role_salary() -> void:
	if _corporation_id.text.strip_edges() == "" or _salary_role.text.strip_edges() == "" \
			or not _salary_role_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_SALARY_FIELDS"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_salary_set_role(
			_corporation_id.text.strip_edges(), _salary_role.text.strip_edges(), int(_salary_role_amount.text))
	if _report(result, tr("%%SVC_MSG_SALARY_ROLE_SET")):
		_load_salaries()


func _set_member_salary() -> void:
	if _corporation_id.text.strip_edges() == "" or _salary_member.text.strip_edges() == "" \
			or not _salary_member_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_SALARY_FIELDS"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_salary_set_member(
			_corporation_id.text.strip_edges(), _salary_member.text.strip_edges(),
			int(_salary_member_amount.text))
	if _report(result, tr("%%SVC_MSG_SALARY_MEMBER_SET")):
		_load_salaries()


func _remove_member_salary() -> void:
	if _corporation_id.text.strip_edges() == "" or _salary_member.text.strip_edges() == "":
		_say(tr("%%SVC_MSG_NEED_CORP_AND_PLAYER"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_salary_remove_member(
			_corporation_id.text.strip_edges(), _salary_member.text.strip_edges())
	if _report(result, tr("%%SVC_MSG_SALARY_REMOVED")):
		_load_salaries()


func _prime() -> void:
	if _corporation_id.text.strip_edges() == "" or _prime_player.text.strip_edges() == "" \
			or not _prime_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_CORP_AND_PLAYER"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_prime(
			_corporation_id.text.strip_edges(), _prime_player.text.strip_edges(), int(_prime_amount.text))
	if _report(result, tr("%%SVC_MSG_PRIME_SENT")):
		_load_corp()


func _payroll() -> void:
	if _corporation_id.text.strip_edges() == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_payroll(_corporation_id.text.strip_edges())
	if _report(result, tr("%%SVC_MSG_PAYROLL_DONE")):
		_load_corp()
