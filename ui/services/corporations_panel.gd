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
var _page_mine: ServicePage
var _my_requests: ItemList
var _page_my_requests: ServicePage
var _directory: ItemList
var _page_directory: ServicePage
var _search: LineEdit
var _detail: Label
var _members: ItemList
var _page_members: ServicePage
var _ranks: ItemList
var _requests: ItemList
var _page_requests: ServicePage
var _invite_picker: ServiceTargetPicker
var _rank_id: LineEdit
var _rank_name: LineEdit
var _rank_priority: LineEdit
var _rank_default: CheckBox
## What a rank may do: one checkbox per organization action (see [method _permission_rows]), and
## which rank those ticks currently belong to (`-1` = none, so the grid would only mislead).
var _perm_grid: GridContainer
var _perm_rank: Label
var _perm_checks: Dictionary = {}
var _perm_rank_id: int = -1
var _transfer_picker: ServiceTargetPicker
var _parent_picker: ServiceTargetPicker
var _create_name: LineEdit
var _create_ticker: LineEdit
var _create_recruitment: OptionButton
# Treasury (moved here from the bank): one corporation pick feeds every action below it.
var _corp_picker: ServiceTargetPicker
var _corp_wallet: ItemList
var _corp_ledger: ItemList
var _page_corp_ledger: ServicePage
var _corp_report: ItemList
var _corp_taxes: ItemList
var _page_corp_taxes: ServicePage
var _corp_from: LineEdit
var _corp_to: LineEdit
var _donation_amount: LineEdit
var _selected_id: String = ""
# Salaries / prime / payroll (economy endpoints).
var _salary_roles: ItemList
var _salary_members: ItemList
var _page_salary_members: ServicePage
var _salary_role: LineEdit
var _salary_role_amount: LineEdit
var _salary_member_picker: ServiceTargetPicker
var _salary_member_amount: LineEdit
var _prime_picker: ServiceTargetPicker
var _prime_amount: LineEdit


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_CORPORATIONS"), ServiceAppIcon.Kind.CORPORATIONS)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_CORPS"), tr("%%SVC_TAB_DIRECTORY"), tr("%%SVC_TAB_MANAGE"),
			tr("%%SVC_TAB_CREATE"), tr("%%SVC_TAB_TREASURY")]))

	# Each segment's half in the right-hand column: what you can DO with it (search, invite,
	# manage, create, run the treasury). The lists those actions act on stay in the card.
	var side0 := _side_page(0)
	var side1 := _side_page(1)
	var side2 := _side_page(2)
	var side3 := _side_page(3)
	var side4 := _side_page(4)

	# My corporations — one sub-tile per corporation, then the two entries (join / create), then
	# the invitations.
	_my_corps_grid = GridContainer.new()
	_my_corps_grid.columns = 2
	_my_corps_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_my_corps_grid.add_theme_constant_override("h_separation", 12)
	_my_corps_grid.add_theme_constant_override("v_separation", 12)
	_page_mine = ServicePage.new()
	_page_mine.load_requested.connect(_load_mine)
	_paged_box(pages[0], tr("%%SVC_LBL_MY_CORPORATIONS"), _page_mine, _my_corps_grid)
	var entries := _row()
	_action_button(entries, tr("%%SVC_ACT_JOIN_CORP"), func() -> void: goto_segment(1))
	_action_button(entries, tr("%%SVC_ACT_CREATE_CORP"), func() -> void: goto_segment(3))
	side0.add_child(entries)
	_page_my_requests = ServicePage.new()
	_page_my_requests.load_requested.connect(_load_my_requests)
	_my_requests = _paged_list(pages[0], tr("%%SVC_LBL_PENDING_REQUESTS"), _page_my_requests, 150.0)
	var my_req_row := _row()
	_action_button(my_req_row, tr("%%SVC_ACT_ACCEPT"), func() -> void: _my_request(true))
	_action_button(my_req_row, tr("%%SVC_ACT_DECLINE"), func() -> void: _my_request(false))
	side0.add_child(my_req_row)

	# Directory
	var search_row := _row()
	_search = _field(tr("%%SVC_PH_SEARCH"), 240.0)
	_search.text_submitted.connect(func(_t: String) -> void: _search_directory())
	search_row.add_child(_search)
	_action_button(search_row, tr("%%SVC_ACT_SEARCH"), func() -> void: _search_directory())
	_action_button(search_row, tr("%%SVC_ACT_JOIN"), func() -> void: _join_selected())
	side1.add_child(search_row)
	_page_directory = ServicePage.new()
	_page_directory.load_requested.connect(_load_directory)
	_directory = _paged_list(pages[1], tr("%%SVC_LBL_DIRECTORY"), _page_directory, 320.0)
	_directory.item_selected.connect(func(_i: int) -> void: _load_detail())
	var invite_row := _row()
	_invite_picker = ServiceTargetPicker.new()
	_invite_picker.setup(ServiceTargetPicker.Mask.PLAYERS, true)
	adopt_field(_invite_picker.search_field())
	invite_row.add_child(_invite_picker)
	_action_button(invite_row, tr("%%SVC_ACT_INVITE"), func() -> void: _invite_selected())
	side1.add_child(invite_row)

	# Manage (detail + membership actions)
	_detail = _label(tr("%%SVC_MSG_SELECT_CORP"), DIM)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pages[2].add_child(_titled(tr("%%SVC_LBL_CORPORATION"), _detail))
	var membership_row := _row()
	_action_button(membership_row, tr("%%SVC_ACT_LEAVE"), func() -> void: _leave_selected())
	_action_button(membership_row, tr("%%SVC_ACT_DISBAND"), func() -> void: _disband_selected())
	side2.add_child(membership_row)
	var detail_columns := _row(18)
	_page_members = ServicePage.new()
	_page_members.load_requested.connect(_load_members)
	_members = _paged_list(detail_columns, tr("%%SVC_LBL_MEMBERS"), _page_members, 150.0)
	_ranks = _list(150.0)
	_ranks.item_selected.connect(func(_i: int) -> void: _load_rank_permissions())
	detail_columns.add_child(_titled(tr("%%SVC_LBL_RANKS"), _ranks, true))
	_page_requests = ServicePage.new()
	_page_requests.load_requested.connect(_load_requests)
	_requests = _paged_list(detail_columns, tr("%%SVC_LBL_REQUESTS"), _page_requests, 150.0)
	pages[2].add_child(detail_columns)

	var manage_row := _row()
	_rank_id = _number_field(tr("%%SVC_PH_RANK_ID"), 110.0)
	manage_row.add_child(_label(tr("%%SVC_LBL_RANK"), DIM))
	manage_row.add_child(_rank_id)
	_action_button(manage_row, tr("%%SVC_ACT_APPLY"), func() -> void: _set_member_rank())
	_action_button(manage_row, tr("%%SVC_ACT_REMOVE_MEMBER"), func() -> void: _remove_member())
	_action_button(manage_row, tr("%%SVC_ACT_ACCEPT_REQUEST"), func() -> void: _request_action(true))
	_action_button(manage_row, tr("%%SVC_ACT_DECLINE_REQUEST"), func() -> void: _request_action(false))
	side2.add_child(manage_row)

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
	side2.add_child(rank_row)

	# The rights themselves: one checkbox per action of the catalogue, ticked from the selected
	# rank. Creating a rank sends whatever is ticked; « apply » writes the ticks onto the rank the
	# grid is showing, which is why a rank must be selected first.
	_perm_rank = _label(tr("%%SVC_MSG_SELECT_RANK"), DIM)
	pages[2].add_child(_perm_rank)
	_perm_grid = GridContainer.new()
	_perm_grid.columns = 2
	_perm_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_perm_grid.add_theme_constant_override("h_separation", 20)
	_perm_grid.add_theme_constant_override("v_separation", 6)
	pages[2].add_child(_titled(tr("%%SVC_LBL_PERMISSIONS"), _perm_grid, true))
	var perm_row := _row()
	_action_button(perm_row, tr("%%SVC_ACT_APPLY_PERMISSIONS"), func() -> void: _apply_rank_permissions())
	side2.add_child(perm_row)

	var transfer_row := _row()
	_transfer_picker = ServiceTargetPicker.new()
	_transfer_picker.setup(ServiceTargetPicker.Mask.PLAYERS, true)
	adopt_field(_transfer_picker.search_field())
	transfer_row.add_child(_transfer_picker)
	_action_button(transfer_row, tr("%%SVC_ACT_TRANSFER"), func() -> void: _transfer())
	side2.add_child(transfer_row)

	var parent_row := _row()
	_parent_picker = ServiceTargetPicker.new()
	_parent_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_parent_picker.search_field())
	parent_row.add_child(_parent_picker)
	_action_button(parent_row, tr("%%SVC_ACT_ATTACH"), func() -> void: _set_parent())
	_action_button(parent_row, tr("%%SVC_ACT_DETACH"), func() -> void: _detach_parent())
	side2.add_child(parent_row)

	# Create
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
	# The create form is the whole of the fourth segment: it goes to the column, which then
	# takes the card.
	side3.add_child(_titled(tr("%%SVC_ACT_CREATE_CORP"), create))

	# Treasury
	var corp := VBoxContainer.new()
	corp.add_theme_constant_override("separation", 10)
	_corp_picker = ServiceTargetPicker.new()
	_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_corp_picker.search_field())
	_corp_from = _field(tr("%%SVC_PH_FROM"), 170.0)
	_corp_to = _field(tr("%%SVC_PH_TO"), 170.0)
	corp.add_child(_label(tr("%%SVC_LBL_CORPORATION"), DIM))
	corp.add_child(_corp_picker)
	var load_row := _row()
	_action_button(load_row, tr("%%SVC_ACT_LOAD"), func() -> void: _load_corp())
	_action_button(load_row, tr("%%SVC_ACT_REPORT"), func() -> void: _load_report())
	corp.add_child(load_row)
	corp.add_child(_label(tr("%%SVC_LBL_REPORT_PERIOD"), DIM))
	var period := _row()
	period.add_child(_corp_from)
	period.add_child(_corp_to)
	corp.add_child(period)
	# The treasury pick drives every list below it: the pick, its buttons and the period are the
	# column, the accounts and the movements they load are the card.
	side4.add_child(_titled(tr("%%SVC_TAB_TREASURY"), corp))
	_corp_wallet = _list(120.0)
	pages[4].add_child(_titled(tr("%%SVC_LBL_CORP_ACCOUNTS"), _corp_wallet, true))
	_page_corp_ledger = ServicePage.new()
	_page_corp_ledger.load_requested.connect(_load_corp_ledger)
	_corp_ledger = _paged_list(pages[4], tr("%%SVC_LBL_LEDGER"), _page_corp_ledger, 120.0)
	_corp_report = _list(120.0)
	pages[4].add_child(_titled(tr("%%SVC_LBL_FINANCIAL_REPORT"), _corp_report, true))
	var donation := _row()
	_donation_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	donation.add_child(_label(tr("%%SVC_LBL_DONATION"), DIM))
	donation.add_child(_donation_amount)
	_action_button(donation, tr("%%SVC_ACT_DONATE"), func() -> void: _donate())
	side4.add_child(donation)

	# The corporation's own tax debts, settled from the same pick as the treasury.
	_page_corp_taxes = ServicePage.new()
	_page_corp_taxes.load_requested.connect(_load_corp_taxes)
	_corp_taxes = _paged_list(pages[4], tr("%%SVC_LBL_TAX_DEBTS"), _page_corp_taxes, 110.0)
	_action_button(side4, tr("%%SVC_ACT_PAY_TAXES"), func() -> void: _pay_corp_taxes())

	# Salaries / prime / payroll — the same corporation pick as the treasury. The role defaults are
	# a fixed table; the per-member overrides are the window the footer walks.
	var salary_columns := _row(18)
	_salary_roles = _list(120.0)
	salary_columns.add_child(_titled(tr("%%SVC_LBL_ROLE_DEFAULTS"), _salary_roles, true))
	_page_salary_members = ServicePage.new()
	_page_salary_members.rows_key = "memberOverrides"
	_page_salary_members.total_keys = PackedStringArray(["memberOverridesTotal"])
	_page_salary_members.load_requested.connect(_load_salary_members)
	_salary_members = _paged_list(salary_columns, tr("%%SVC_LBL_MEMBER_OVERRIDES"),
			_page_salary_members, 120.0)
	pages[4].add_child(salary_columns)
	_action_button(side4, tr("%%SVC_ACT_LOAD_SALARIES"), func() -> void: _load_salaries())

	var role_salary := _row()
	_salary_role = _field(tr("%%SVC_PH_ROLE"), 140.0)
	_salary_role_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	role_salary.add_child(_label(tr("%%SVC_LBL_ROLE"), DIM))
	role_salary.add_child(_salary_role)
	role_salary.add_child(_salary_role_amount)
	_action_button(role_salary, tr("%%SVC_ACT_SET_ROLE_SALARY"), func() -> void: _set_role_salary())
	side4.add_child(role_salary)

	var member_salary := _row()
	_salary_member_picker = ServiceTargetPicker.new()
	_salary_member_picker.setup(ServiceTargetPicker.Mask.PLAYERS, true)
	adopt_field(_salary_member_picker.search_field())
	_salary_member_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	member_salary.add_child(_label(tr("%%SVC_LBL_MEMBER"), DIM))
	member_salary.add_child(_salary_member_picker)
	member_salary.add_child(_salary_member_amount)
	_action_button(member_salary, tr("%%SVC_ACT_SET_MEMBER_SALARY"), func() -> void: _set_member_salary())
	_action_button(member_salary, tr("%%SVC_ACT_REMOVE_SALARY"), func() -> void: _remove_member_salary())
	side4.add_child(member_salary)

	var prime_row := _row()
	_prime_picker = ServiceTargetPicker.new()
	_prime_picker.setup(ServiceTargetPicker.Mask.PLAYERS, true)
	adopt_field(_prime_picker.search_field())
	_prime_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 140.0)
	prime_row.add_child(_label(tr("%%SVC_LBL_PRIME"), DIM))
	prime_row.add_child(_prime_picker)
	prime_row.add_child(_prime_amount)
	_action_button(prime_row, tr("%%SVC_ACT_PRIME"), func() -> void: _prime())
	side4.add_child(prime_row)

	_action_button(side4, tr("%%SVC_ACT_PAYROLL"), func() -> void: _payroll())

	add_chrome(_status_line())


func refresh() -> void:
	if not _begin_refresh():
		return
	await _load_mine()
	await _load_my_requests()
	await _load_directory()
	_end_refresh()


func _load_mine() -> void:
	var at: int = _page_mine.offset
	var result: Dictionary = await PlayerServices.my_corporations(_page_mine.limit, at)
	if _land(_page_mine, at, result):
		_apply_mine(_page_mine, result)


func _load_my_requests() -> void:
	var at: int = _page_my_requests.offset
	var result: Dictionary = await PlayerServices.my_corporation_requests(
			_page_my_requests.limit, at)
	if _land(_page_my_requests, at, result):
		_fill_requests(_page_my_requests, _my_requests, result, tr("%%SVC_MSG_NO_PENDING"))


func _load_directory() -> void:
	var at: int = _page_directory.offset
	var result: Dictionary = await PlayerServices.corporations_list(_search.text.strip_edges(),
			_page_directory.limit, at)
	if _land(_page_directory, at, result):
		_apply_directory(_page_directory, result)


## The members of the corporation being managed. The window belongs to whichever corporation is
## selected, so opening one starts it again at the first page.
func _load_members() -> void:
	if _selected_id == "":
		return
	var at: int = _page_members.offset
	var result: Dictionary = await PlayerServices.corporation_members(_selected_id,
			PlayerServices.SERVICE_SOCIAL, _page_members.limit, at)
	if _land(_page_members, at, result):
		_fill_simple(_members, result, ServiceTypes.member_line, tr("%%SVC_MSG_NO_MEMBERS"))


func _load_requests() -> void:
	if _selected_id == "":
		return
	var at: int = _page_requests.offset
	var result: Dictionary = await PlayerServices.corporation_requests(_selected_id,
			_page_requests.limit, at)
	if _land(_page_requests, at, result):
		_fill_requests(_page_requests, _requests, result, tr("%%SVC_MSG_NO_REQUESTS"))


func _apply_mine(page: ServicePage, result: Dictionary) -> void:
	for child: Node in _my_corps_grid.get_children():
		_my_corps_grid.remove_child(child)
		child.queue_free()
	# A GridContainer sizes its columns from the children's minimums: without SIZE_EXPAND_FILL the
	# column never receives the grid's width, and an autowrap label (minimum ≈ 0) collapses to one
	# letter per line. The corp tiles below carry the same flag — these messages must too.
	if not bool(result.get("ok", false)):
		var error := _label(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), WARN)
		error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		error.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_my_corps_grid.columns = 1
		_my_corps_grid.add_child(error)
		return
	var memberships: Array = page.rows(result)
	if memberships.is_empty():
		var empty := _label(tr("%%SVC_MSG_NO_CORPS"), ServiceStyle.MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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


func _apply_directory(page: ServicePage, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_directory, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for corp: Dictionary in page.rows(result):
		lines.append(ServiceTypes.corporation_line(corp))
		metadata.append(corp)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_CORPORATION_EMPTY"))
	_fill_list(_directory, lines, metadata)


func _fill_requests(page: ServicePage, list: ItemList, result: Dictionary, empty: String) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for request: Dictionary in page.rows(result):
		lines.append(ServiceTypes.request_line(request))
		metadata.append(request)
	if lines.is_empty():
		lines.append(empty)
	_fill_list(list, lines, metadata)


func _search_directory() -> void:
	release_fields()
	# A new question: back to the first window, which loads it with the new query.
	_page_directory.reset()


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
	var player_id: String = _invite_picker.picked_id()
	if _selected_id == "" or player_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_AND_PLAYER"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_invite(_selected_id, player_id)
	if _report(result, tr("%%SVC_MSG_INVITE_SENT")):
		_invite_picker.clear_pick()


## Load a corporation's detail and open the management tab.
func _open_detail(corporation_id: String) -> void:
	if corporation_id == "":
		return
	_selected_id = corporation_id
	var detail: Dictionary = await PlayerServices.corporation_get(_selected_id)
	var subsidiaries: Dictionary = await PlayerServices.corporation_subsidiaries(_selected_id)
	if bool(detail.get("ok", false)) and detail.get("data") is Dictionary:
		var corp: Dictionary = detail.get("data")
		# The corporation opened here is the one the treasury page will act on: one pick, shared
		# by the wallet, the report, the donations, the salaries, the primes and the payroll.
		_corp_picker.set_pick(str(corp.get("id", "")), ServiceTargetPicker.KIND_CORPORATION,
				str(corp.get("name", "")))
		var parent_text: String = ServiceTypes.dash(corp.get("parentId"))
		var subsidiary_text := PackedStringArray()
		if bool(subsidiaries.get("ok", false)):
			for subsidiary: Dictionary in ServicePage.items_of(subsidiaries):
				subsidiary_text.append(ServiceTypes.corporation_line(subsidiary))
		_detail.text = "\n".join([
			ServiceTypes.corporation_line(corp),
			tr("%%SVC_FMT_CORP_PARENT") % parent_text,
			tr("%%SVC_FMT_CORP_SUBSIDIARIES") % (tr("%%SVC_MSG_NONE")
					if subsidiary_text.is_empty() else ", ".join(subsidiary_text)),
		])
	elif not bool(detail.get("ok", false)):
		_detail.text = HttpClient.describe_error(detail)
	var ranks: Dictionary = await PlayerServices.corporation_ranks(_selected_id)
	_fill_simple(_ranks, ranks, ServiceTypes.rank_line, tr("%%SVC_MSG_NO_RANKS"))
	# The two paged lists below are scoped to this corporation: start them at its first window.
	_page_members.reset()
	_page_requests.reset()
	# The permission grid below is built once per session, and always re-read: the rank list it
	# describes has just been replaced, so its ticks point at a rank that no longer exists.
	await _prepare_permission_grid()
	_load_rank_permissions()
	goto_segment(2)


## Fill a plain list from a response whose rows are not behind a window of their own (the ranks
## are a bare array, a corporation's members a page object) — the service's error wins over rows.
func _fill_simple(list: ItemList, result: Dictionary, formatter: Callable, empty: String) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for item: Dictionary in ServicePage.items_of(result):
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
	# The new rank starts with whatever the grid has ticked — the same ticks the « apply » button
	# would write onto an existing rank.
	var result: Dictionary = await PlayerServices.corporation_rank_create(_selected_id,
			_rank_name.text.strip_edges(), priority, _checked_actions(),
			_rank_default.button_pressed)
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


# ---------------------------------------------------------------------------------------------
# Rank permissions — the catalogue is the vocabulary, the grid is the editor
# ---------------------------------------------------------------------------------------------

## Build the permission grid, fetching the catalogue the first time it is missing: it is what says
## what an action MEANS (localized by the service, with its `satisfiedBy` and `defaultMember`
## flags). A failed fetch is not fatal — the grid then falls back to the five legacy permissions
## the API has always accepted.
func _prepare_permission_grid() -> void:
	if ServiceTypes.action_catalog.is_empty():
		var result: Dictionary = await PlayerServices.permission_catalog()
		if bool(result.get("ok", false)):
			ServiceTypes.set_action_catalog(result.get("data"))
		else:
			_say(HttpClient.describe_error(result), WARN)
	_build_perm_grid()


## The actions the grid offers: the service's catalogue when it answers, the legacy table when it
## does not — a player who never reached the service still sees the rights the API has always had.
func _permission_rows() -> Array:
	var rows: Array = ServiceTypes.catalog_for("corporation")
	if not rows.is_empty():
		return rows
	for action: String in ServiceTypes.PERMISSION_KEYS:
		rows.append({"action": action, "holder": "corporation", "legacy": true,
				"description": tr(ServiceTypes.PERMISSION_KEYS[action])})
	return rows


## One checkbox per action, in catalogue order. A `defaultMember` row starts ticked and locked:
## every member holds it whether the rank says so or not, so a tick there would only be decoration.
func _build_perm_grid() -> void:
	_clear(_perm_grid)
	_perm_checks.clear()
	var rows := _permission_rows()
	if rows.is_empty():
		_perm_grid.add_child(_label(tr("%%SVC_MSG_NO_PERMISSIONS"), DIM))
		return
	for row: Dictionary in rows:
		var action := str(row.get("action", ""))
		if action == "":
			continue
		var check := CheckBox.new()
		check.text = _permission_text(row)
		check.tooltip_text = action
		check.button_pressed = bool(row.get("defaultMember", false))
		check.disabled = check.button_pressed
		ServiceStyle.apply_check(check)
		_perm_grid.add_child(check)
		_perm_checks[action] = check


## Tick exactly [param permissions] — a rank's current rights, or nothing for a fresh grid. A
## locked (`defaultMember`) action stays ticked: the service grants it regardless.
func _sync_perm_grid(permissions: Array) -> void:
	var wanted: Dictionary = {}
	for permission: Variant in permissions:
		wanted[str(permission)] = true
	for action: String in _perm_checks:
		var check := _perm_checks[action] as CheckBox
		check.set_pressed_no_signal(wanted.has(action) or check.disabled)


## Show the selected rank's rights. Nothing selected means the grid belongs to nobody — which is
## exactly the state a rank about to be created starts from.
func _load_rank_permissions() -> void:
	var rank: Variant = _selected_meta(_ranks)
	if not (rank is Dictionary):
		_perm_rank_id = -1
		_perm_rank.text = tr("%%SVC_MSG_SELECT_RANK")
		_sync_perm_grid([])
		return
	_perm_rank_id = ServiceTypes.num((rank as Dictionary).get("id"))
	_perm_rank.text = "%s : %s (#%d)" % [tr("%%SVC_LBL_RANK"),
			ServiceTypes.dash((rank as Dictionary).get("name")), _perm_rank_id]
	var value: Variant = (rank as Dictionary).get("permissions")
	if value is Array:
		_sync_perm_grid(value as Array)
	else:
		_sync_perm_grid([])


## Write the ticked actions onto the rank the grid is showing (`manage_ranks`).
func _apply_rank_permissions() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	if _perm_rank_id < 0:
		_say(tr("%%SVC_MSG_SELECT_RANK"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_rank_update(_selected_id,
			_perm_rank_id, {"permissions": _checked_actions()})
	if _report(result, tr("%%SVC_MSG_PERMISSIONS_SAVED")):
		_open_detail(_selected_id)


## The ticked actions as the API stores them. Locked rows are left out: the service grants those
## anyway, and a rank's list should read as what the rank was actually granted.
func _checked_actions() -> Array:
	var actions: Array = []
	for action: String in _perm_checks:
		var check := _perm_checks[action] as CheckBox
		if check.button_pressed and not check.disabled:
			actions.append(action)
	return actions


## The checkbox caption: the catalogue's description when there is one, the legacy label otherwise.
## The action id rides in the tooltip — that is what the API stores, and what a rank line shows.
func _permission_text(row: Dictionary) -> String:
	var description := str(row.get("description", "")).strip_edges()
	return description if description != "" else ServiceTypes.permission_label(row.get("action"))


func _transfer() -> void:
	if _selected_id == "":
		_say(tr("%%SVC_MSG_SELECT_CORP_SHORT"), WARN)
		return
	var player_id: String = _transfer_picker.picked_id()
	if player_id == "":
		_say(tr("%%SVC_MSG_NEED_NEW_LEADER"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_transfer(_selected_id, player_id)
	if _report(result, tr("%%SVC_MSG_TRANSFER_DONE")):
		_transfer_picker.clear_pick()
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
	var parent_id: String = _parent_picker.picked_id()
	if parent_id == "":
		_say(tr("%%SVC_MSG_NEED_PARENT"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_set_parent(_selected_id, parent_id)
	if _report(result, tr("%%SVC_MSG_PARENT_SET")):
		_parent_picker.clear_pick()
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

## The corporation every action on this page acts on: the single pick made once, at the top.
func _picked_corp() -> String:
	return _corp_picker.picked_id()


func _load_corp() -> void:
	release_fields()
	var corporation_id: String = _picked_corp()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	# The pick (or the movement just made) is what this page now shows: both windows start again
	# at their first page — which is also where a brand-new transaction lands.
	_page_corp_ledger.reset()
	_page_corp_taxes.reset()
	var wallet: Dictionary = await PlayerServices.corporation_wallet(corporation_id)
	_apply_corp_accounts(wallet)


func _load_corp_ledger() -> void:
	var corporation_id: String = _picked_corp()
	if corporation_id == "":
		return
	var at: int = _page_corp_ledger.offset
	var result: Dictionary = await PlayerServices.corporation_wallet_transactions(corporation_id,
			_page_corp_ledger.limit, at)
	if _land(_page_corp_ledger, at, result):
		_apply_corp_ledger(_page_corp_ledger, result)


func _load_corp_taxes() -> void:
	var corporation_id: String = _picked_corp()
	if corporation_id == "":
		return
	var at: int = _page_corp_taxes.offset
	var result: Dictionary = await PlayerServices.corporation_taxes(corporation_id,
			_page_corp_taxes.limit, at)
	if _land(_page_corp_taxes, at, result):
		_apply_taxes(_page_corp_taxes, _corp_taxes, result)


## Settle everything the corporation can afford, right where the treasury sits — the balance the
## payment moves is the list just above it.
func _pay_corp_taxes() -> void:
	release_fields()
	var corporation_id: String = _picked_corp()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_taxes_pay(corporation_id)
	if not bool(result.get("ok", false)):
		_say(HttpClient.describe_error(result), WARN)
		return
	var data: Variant = result.get("data")
	var summary := tr("%%SVC_MSG_TAXES_PAID")
	if data is Dictionary:
		summary = ServiceTypes.tax_payment_line(data as Dictionary)
	_say(summary, GOOD)
	_load_corp()


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


func _apply_corp_ledger(page: ServicePage, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_corp_ledger, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for transaction: Dictionary in page.rows(result):
		lines.append(ServiceTypes.transaction_line(transaction))
		metadata.append(transaction)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_TRANSACTIONS"))
	_fill_list(_corp_ledger, lines, metadata)


## Tax debts into a list: what is owed, and what has already been settled.
func _apply_taxes(page: ServicePage, list: ItemList, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([
				tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for debt: Dictionary in page.rows(result):
		lines.append(ServiceTypes.tax_debt_line(debt))
		metadata.append(debt)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_TAXES"))
	_fill_list(list, lines, metadata)


func _load_report() -> void:
	release_fields()
	var corporation_id: String = _picked_corp()
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
	var corporation_id: String = _picked_corp()
	if corporation_id == "" or not _donation_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_CORP_AMOUNT"), WARN)
		return
	var result: Dictionary = await PlayerServices.corporation_donation(corporation_id,
			int(_donation_amount.text))
	if _report(result, tr("%%SVC_MSG_DONATION_SENT")):
		_donation_amount.text = ""
		_load_corp()


# ---------------------------------------------------------------------------------------------
# Salaries / prime / payroll (economy)
# ---------------------------------------------------------------------------------------------

func _load_salaries() -> void:
	release_fields()
	var corporation_id: String = _picked_corp()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	# Overrides changed (or another corporation was picked): back to its first window, which
	# fetches the role defaults and the overrides together.
	_page_salary_members.reset()


func _load_salary_members() -> void:
	var corporation_id: String = _picked_corp()
	if corporation_id == "":
		return
	var at: int = _page_salary_members.offset
	var result: Dictionary = await PlayerServices.corporation_salaries(corporation_id,
			_page_salary_members.limit, at)
	if not _land(_page_salary_members, at, result):
		return
	if not bool(result.get("ok", false)):
		var error: String = tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))
		_fill_list(_salary_roles, PackedStringArray([error]))
		_fill_list(_salary_members, PackedStringArray([error]))
		return
	var data: Dictionary = result.get("data", {}) if result.get("data") is Dictionary else {}
	_apply_salary_list(_salary_roles, data.get("roleDefaults"), ServiceTypes.salary_role_line,
			tr("%%SVC_MSG_NO_SALARIES"))
	_apply_salary_list(_salary_members, _page_salary_members.rows(result),
			ServiceTypes.salary_member_line, tr("%%SVC_MSG_NO_SALARIES"))


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
	if _picked_corp() == "" or _salary_role.text.strip_edges() == "" \
			or not _salary_role_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_SALARY_FIELDS"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_salary_set_role(
			_picked_corp(), _salary_role.text.strip_edges(), int(_salary_role_amount.text))
	if _report(result, tr("%%SVC_MSG_SALARY_ROLE_SET")):
		_load_salaries()


func _set_member_salary() -> void:
	if _picked_corp() == "" or _salary_member_picker.picked_id() == "" \
			or not _salary_member_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_SALARY_FIELDS"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_salary_set_member(
			_picked_corp(), _salary_member_picker.picked_id(),
			int(_salary_member_amount.text))
	if _report(result, tr("%%SVC_MSG_SALARY_MEMBER_SET")):
		_load_salaries()


func _remove_member_salary() -> void:
	if _picked_corp() == "" or _salary_member_picker.picked_id() == "":
		_say(tr("%%SVC_MSG_NEED_CORP_AND_PLAYER"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_salary_remove_member(
			_picked_corp(), _salary_member_picker.picked_id())
	if _report(result, tr("%%SVC_MSG_SALARY_REMOVED")):
		_load_salaries()


func _prime() -> void:
	if _picked_corp() == "" or _prime_picker.picked_id() == "" \
			or not _prime_amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_CORP_AND_PLAYER"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_prime(
			_picked_corp(), _prime_picker.picked_id(), int(_prime_amount.text))
	if _report(result, tr("%%SVC_MSG_PRIME_SENT")):
		_load_corp()


func _payroll() -> void:
	if _picked_corp() == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	release_fields()
	var result: Dictionary = await PlayerServices.corporation_payroll(_picked_corp())
	if _report(result, tr("%%SVC_MSG_PAYROLL_DONE")):
		_load_corp()
