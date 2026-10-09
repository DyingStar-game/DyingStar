extends ServicePanel

## The "Missions" section: 4 MASTER-DETAIL tabs — the first three are list on the left, CONTRACT on
## the right: Available (filters + search), My missions (assignments), My contracts (missions I
## issued — status filter, sharing, issuer-objective confirmation). The contract is a DOCUMENT CARD
## shared with the creation form: title header + status stamp, rules, metadata (FMT_MISSION_DETAIL_*
## labels), numbered sections "1. …", contextual action footer (Accept / Abandon·Complete + progress
## / Share / Confirm). Tab 4 "New contract" reuses the same shell in edit mode: objectives are
## CLAUSES whose sentence comes from the catalogue (GET /api/missions/kinds, `{variables}` decomposed
## into inline fields, substituted into the `title` on send) — dry-run POST /validate before create.
## Each clause's kind list is filtered to the contract's category: the catalogue marks every kind
## `all` or with an explicit category list, and the service rejects mismatches at validate time.

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
## The full category enum, reused as the create form's fallback when the catalogue is unreachable.
const CATEGORY_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["delivery", "%%SVC_ENUM_CATEGORY_DELIVERY"],
	["transport", "%%SVC_ENUM_CATEGORY_TRANSPORT"],
	["generic", "%%SVC_ENUM_CATEGORY_GENERIC"],
	["mining", "%%SVC_ENUM_CATEGORY_MINING"],
	["farming", "%%SVC_ENUM_CATEGORY_FARMING"],
	["crafting", "%%SVC_ENUM_CATEGORY_CRAFTING"],
	["construction", "%%SVC_ENUM_CATEGORY_CONSTRUCTION"],
	["trading", "%%SVC_ENUM_CATEGORY_TRADING"],
	["exploration", "%%SVC_ENUM_CATEGORY_EXPLORATION"],
	["salvage", "%%SVC_ENUM_CATEGORY_SALVAGE"],
	["combat", "%%SVC_ENUM_CATEGORY_COMBAT"],
	["reception", "%%SVC_ENUM_CATEGORY_RECEPTION"],
]
const VISIBILITY_ENTRIES: Array = [
	["public", "%%SVC_ENUM_VISIBILITY_PUBLIC"],
	["corporation", "%%SVC_ENUM_VISIBILITY_CORPORATION"],
]
## Who funds the credits escrow: the creator's wallet (service default) or the issuing
## corporation's treasury (`escrowSource: issuer` — CEO/manage_corporation checked server-side).
const ESCROW_ENTRIES: Array = [
	["creator", "%%SVC_ENUM_ESCROW_CREATOR"],
	["issuer", "%%SVC_ENUM_ESCROW_ISSUER"],
]
## The create form's zone kinds — exactly the MissionZone discriminator the service validates
## (a `.strict()` union: system / scene / area). A mission with no zone is global.
const ZONE_ENTRIES: Array = [
	["system", "%%SVC_ENUM_ZONE_SYSTEM"],
	["scene", "%%SVC_ENUM_ZONE_SCENE"],
	["area", "%%SVC_ENUM_ZONE_AREA"],
]
## The create form's fallback objective kinds when the catalogue is unreachable.
const OBJECTIVE_TYPE_ENTRIES: Array = [
	["deliver_material", "%%SVC_ENUM_OBJECTIVE_DELIVER_MATERIAL"],
	["transport", "%%SVC_ENUM_OBJECTIVE_TRANSPORT"],
	["visit", "%%SVC_ENUM_OBJECTIVE_VISIT"],
	["custom", "%%SVC_ENUM_OBJECTIVE_CUSTOM"],
]
## Fallback prerequisite kinds — the OpenAPI names these as the registry's examples; displayed raw.
const PREREQ_FALLBACK: PackedStringArray = [
	"has_credits", "owns_items", "min_reputation", "corporation_member",
]
## Sentence variables, `{name}` first (the convention the catalogue now ships) with the legacy
## `` `name` `` still matched so an older summary keeps rendering mid-transition.
const TEMPLATE_PATTERN := "\\{([A-Za-z_][A-Za-z0-9_]*)\\}|`([^`]+)`"

## Segment 0-2 left columns.
var _filter_status: OptionButton
var _kind: OptionButton
var _category: OptionButton
var _visibility: OptionButton
var _browse: ItemList
var _page_browse: ServicePage
var _mine: ItemList
var _page_mine: ServicePage
var _created_status: OptionButton
var _created: ItemList
var _page_created: ServicePage
## Segment 3 — the creation document.
var _create_title: LineEdit
var _create_description: TextEdit
var _create_category: OptionButton
var _create_visibility: OptionButton
## Issuer block — the corporation pick, alone on its own row (shown with the corporation
## visibility; a public contract is paid by its creator).
var _create_corp_row: VBoxContainer
var _create_corp_picker: ServiceTargetPicker
## Funding selector — shown with the corporation visibility, hidden again in public.
var _escrow_caption: Label
var _create_escrow: OptionButton
var _create_amount: LineEdit
var _create_max: LineEdit
## Zone block — the availability zones (no row = the service's "global" mission): a titled box of
## repeatable rows, each {panel, index, kind, fields: Array[LineEdit]}.
var _create_zones: VBoxContainer
var _zone_rows: Array = []
var _create_objectives: VBoxContainer
var _create_prereqs: VBoxContainer
## Editable clauses, each {panel, index, kind, badge, qty?, flow, fallback_box, with_title,
## segments, vars, title_field, param_fields, param_raw, schema_required, schema_has_required}.
var _objective_rows: Array = []
var _prereq_rows: Array = []
## The catalogue (categories, objectiveKinds, prerequisiteKinds), fetched once.
var _catalog: Dictionary = {}


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_MISSIONS"), ServiceAppIcon.Kind.MISSIONS)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_AVAILABLE"), tr("%%SVC_TAB_MY_MISSIONS"),
			tr("%%SVC_TAB_MY_CREATIONS"), tr("%%SVC_TAB_CREATE")]))
	_build_browse_page(pages[0])
	_build_mine_page(pages[1])
	_build_created_page(pages[2])
	# The builder is the whole of the fourth segment: it goes to the column, which then takes
	# the card — the document needs every pixel it can get.
	_build_create_page(_side_page(3))
	add_chrome(_status_line())

	# One clause up front: the contract is never empty.
	_add_objective_row()
	_update_corp_field()


# ---------------------------------------------------------------------------------------------
# Master-detail shell and document card
# ---------------------------------------------------------------------------------------------

## Split a segment page into a fixed left column (caller fills) and the right contract column.
## Returns [left, contract]: the contract VBox is where a rendered mission document lands.
func _master_detail(page: VBoxContainer) -> Array:
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var columns := _row(18)
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.custom_minimum_size = Vector2(320, 0)
	columns.add_child(left)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var contract := VBoxContainer.new()
	contract.add_theme_constant_override("separation", 14)
	contract.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(contract)
	columns.add_child(_titled(tr("%%SVC_LBL_MISSION"), scroll, true))

	page.add_child(columns)
	contract.add_child(_label(tr("%%SVC_MSG_SELECT_MISSION_DETAIL"), DIM))
	return [left, contract]


## The document shell both the read contract and the creation form live in.
func _document_card() -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL, 14, ServiceStyle.BORDER_STRONG, 1, 22.0, 18.0))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return card


## A one-pixel horizontal rule inside a document.
func _rule() -> Control:
	var rule := Panel.new()
	rule.custom_minimum_size = Vector2(0, 1)
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.BORDER_STRONG, 0, Color.TRANSPARENT, 0))
	return rule


## The status stamp on a contract header.
func _status_pill(status: String) -> Control:
	var colour := _status_colour(status)
	var pill := PanelContainer.new()
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ServiceStyle.apply_pill(pill, colour)
	var label := _label(ServiceTypes.mission_status_label(status), colour)
	ServiceStyle.font_of(label, 13, true)
	pill.add_child(label)
	return pill


func _status_colour(status: String) -> Color:
	match status:
		"available":
			return ACCENT
		"active":
			return GOOD
		"cancelled":
			return WARN
		_:
			return DIM


# ---------------------------------------------------------------------------------------------
# Tab 0 — available
# ---------------------------------------------------------------------------------------------

func _build_browse_page(page: VBoxContainer) -> void:
	var parts := _master_detail(page)
	var left: VBoxContainer = parts[0]
	var contract: VBoxContainer = parts[1]
	# The filters are the segment's controls: they run from the column, beside the contract.
	var side := _side_page(0)
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
	side.add_child(filters)
	_page_browse = ServicePage.new()
	_page_browse.rows_key = "missions"
	_page_browse.load_requested.connect(_load_browse)
	_browse = _paged_list(left, tr("%%SVC_LBL_AVAILABLE_MISSIONS"), _page_browse, 240.0)
	_browse.item_selected.connect(func(_i: int) -> void: _open_selected(_browse, contract))


# ---------------------------------------------------------------------------------------------
# Tab 1 — my missions (assignments)
# ---------------------------------------------------------------------------------------------

func _build_mine_page(page: VBoxContainer) -> void:
	var parts := _master_detail(page)
	var left: VBoxContainer = parts[0]
	var contract: VBoxContainer = parts[1]
	_page_mine = ServicePage.new()
	_page_mine.rows_key = "missions"
	_page_mine.load_requested.connect(_load_mine)
	_mine = _paged_list(left, tr("%%SVC_LBL_MY_MISSIONS"), _page_mine, 320.0)
	_mine.item_selected.connect(func(_i: int) -> void: _open_mine(contract))


# ---------------------------------------------------------------------------------------------
# Tab 2 — my contracts (missions I issued)
# ---------------------------------------------------------------------------------------------

func _build_created_page(page: VBoxContainer) -> void:
	var parts := _master_detail(page)
	var left: VBoxContainer = parts[0]
	var contract: VBoxContainer = parts[1]
	var side := _side_page(2)
	var filters := _row()
	_created_status = _option_enum(STATUS_ENTRIES, 140.0)
	filters.add_child(_label(tr("%%SVC_LBL_STATUS"), DIM))
	filters.add_child(_created_status)
	_action_button(filters, tr("%%SVC_ACT_BROWSE"), func() -> void: _created_missions())
	side.add_child(filters)
	_page_created = ServicePage.new()
	_page_created.rows_key = "missions"
	_page_created.load_requested.connect(_load_created)
	_created = _paged_list(left, tr("%%SVC_TAB_MY_CREATIONS"), _page_created, 240.0)
	_created.item_selected.connect(func(_i: int) -> void: _open_selected(_created, contract))


# ---------------------------------------------------------------------------------------------
# Tab 3 — new contract (edit mode, same document shell)
# ---------------------------------------------------------------------------------------------

func _build_create_page(side: VBoxContainer) -> void:
	var card := _document_card()
	var create := VBoxContainer.new()
	create.add_theme_constant_override("separation", 12)

	var eyebrow := _label(tr("%%SVC_LBL_CREATE_MISSION"), ACCENT)
	ServiceStyle.font_of(eyebrow, 13, true)
	create.add_child(eyebrow)
	_create_title = _field(tr("%%SVC_PH_TITLE"), 420.0)
	ServiceStyle.font_of(_create_title, 20, true)
	create.add_child(_label(tr("%%SVC_LBL_TITLE"), DIM))
	create.add_child(_create_title)
	_create_description = _textarea(tr("%%SVC_LBL_DESCRIPTION"), 90.0)
	create.add_child(_create_description)

	var meta := _row(14)
	_create_category = _option_enum(_category_options(), 170.0)
	if _create_category.selected < 0 and _create_category.item_count > 0:
		_create_category.select(0)
	_create_category.item_selected.connect(func(_i: int) -> void: _on_category_changed(_i))
	_create_visibility = _option_enum(VISIBILITY_ENTRIES, 150.0)
	if _create_visibility.selected < 0 and _create_visibility.item_count > 0:
		_create_visibility.select(0)
	_create_visibility.item_selected.connect(func(_i: int) -> void: _update_corp_field())
	_escrow_caption = _label(tr("%%SVC_LBL_ESCROW"), DIM)
	_create_escrow = _option_enum(ESCROW_ENTRIES, 170.0)
	if _create_escrow.selected < 0 and _create_escrow.item_count > 0:
		_create_escrow.select(0)
	_create_amount = _number_field(tr("%%SVC_PH_REWARD"), 110.0)
	_create_max = _number_field(tr("%%SVC_LBL_MAX_ASSIGNEES"), 80.0)
	meta.add_child(_label(tr("%%SVC_LBL_CATEGORY"), DIM))
	meta.add_child(_create_category)
	meta.add_child(_label(tr("%%SVC_LBL_VISIBILITY"), DIM))
	meta.add_child(_create_visibility)
	meta.add_child(_escrow_caption)
	meta.add_child(_create_escrow)
	meta.add_child(_label(tr("%%SVC_LBL_REWARD_CREDITS"), DIM))
	meta.add_child(_create_amount)
	meta.add_child(_label(tr("%%SVC_LBL_MAX_ASSIGNEES"), DIM))
	meta.add_child(_create_max)
	create.add_child(meta)
	# Issuer block: the corporation is picked, not typed. Its own row, so the meta line above
	# never has to carry a control this wide.
	_create_corp_row = VBoxContainer.new()
	_create_corp_row.add_theme_constant_override("separation", 6)
	_create_corp_row.add_child(_label(tr("%%SVC_LBL_CORPORATION"), DIM))
	_create_corp_picker = ServiceTargetPicker.new()
	_create_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_create_corp_picker.search_field())
	_create_corp_row.add_child(_create_corp_picker)
	create.add_child(_create_corp_row)

	# Zones: the availability list — no row means the mission is global. Every row owns the
	# fields its kind needs; "my position" prefills the first one from the presence location.
	var zones := VBoxContainer.new()
	zones.add_theme_constant_override("separation", 8)
	_create_zones = VBoxContainer.new()
	_create_zones.add_theme_constant_override("separation", 8)
	zones.add_child(_create_zones)
	var zone_actions := _row()
	_action_button(zone_actions, tr("%%SVC_ACT_ADD_ZONE"), func() -> void: _new_zone_row())
	_action_button(zone_actions, tr("%%SVC_ACT_ZONE_MINE"), func() -> void: _use_my_position())
	zones.add_child(zone_actions)
	create.add_child(_titled(tr("%%SVC_LBL_ZONES"), zones))
	create.add_child(_rule())

	# Clauses: objectives then prerequisites, each with its decomposed sentence.
	_create_objectives = VBoxContainer.new()
	_create_objectives.add_theme_constant_override("separation", 8)
	create.add_child(_titled(tr("%%SVC_LBL_OBJECTIVES"), _create_objectives))
	_action_button(create, tr("%%SVC_ACT_ADD_OBJECTIVE"), func() -> void: _add_objective_row())

	_create_prereqs = VBoxContainer.new()
	_create_prereqs.add_theme_constant_override("separation", 8)
	create.add_child(_titled(tr("%%SVC_LBL_PREREQUISITES"), _create_prereqs))
	_action_button(create, tr("%%SVC_ACT_ADD_PREREQ"), func() -> void: _add_prereq_row())

	create.add_child(_rule())
	var submit := _row()
	_action_button(submit, tr("%%SVC_ACT_VALIDATE"), func() -> void: _validate_spec())
	_action_button(submit, tr("%%SVC_ACT_CREATE_MISSION"), func() -> void: _create())
	create.add_child(submit)

	card.add_child(create)
	side.add_child(card)


# ---------------------------------------------------------------------------------------------
# List loading
# ---------------------------------------------------------------------------------------------

func refresh() -> void:
	if not _begin_refresh():
		return
	if _catalog.is_empty():
		await _load_catalog()
	await _load_mine()
	await _load_browse()
	await _load_created()
	_end_refresh()


## The catalogue feeds every dynamic dropdown; on failure the hardcoded lists stay in place.
func _load_catalog() -> void:
	var result: Dictionary = await PlayerServices.mission_kinds()
	if bool(result.get("ok", false)) and result.get("data") is Dictionary:
		_catalog = result.get("data")
		_fill_options(_create_category, _category_options())
		for row: Dictionary in _objective_rows:
			_refill_row(row)
		for row: Dictionary in _prereq_rows:
			_refill_row(row)
	else:
		_say(tr("%%SVC_MSG_NO_CATALOG") + " " + HttpClient.describe_error(result), WARN)


## New filters ask a new question: back to the first window, which loads it.
func _browse_missions() -> void:
	_page_browse.reset()


func _load_browse() -> void:
	var at: int = _page_browse.offset
	var result: Dictionary = await PlayerServices.missions_list(
			_enum_value(_filter_status), _enum_value(_kind), _enum_value(_category),
			"", "", _enum_value(_visibility), _page_browse.limit, at)
	if _land(_page_browse, at, result):
		_fill_missions_list(_page_browse, _browse, result, tr("%%SVC_MSG_NO_MISSIONS"))


func _created_missions() -> void:
	_page_created.reset()


## My own contracts: the issuer filters the catalogue by my player id.
func _load_created() -> void:
	var at: int = _page_created.offset
	var result: Dictionary = await PlayerServices.missions_list(
			_enum_value(_created_status), "", "", "player", PlayerServices.player_id(), "",
			_page_created.limit, at)
	if _land(_page_created, at, result):
		_fill_missions_list(_page_created, _created, result, tr("%%SVC_MSG_NO_CREATED"))


func _load_mine() -> void:
	var at: int = _page_mine.offset
	var result: Dictionary = await PlayerServices.my_missions("", _page_mine.limit, at)
	if _land(_page_mine, at, result):
		_apply_mine(_page_mine, result)


## Shared loader for the two mission-dict lists (browse + created).
func _fill_missions_list(page: ServicePage, list: ItemList, result: Dictionary,
		empty_text: String) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for mission: Dictionary in page.rows(result):
		lines.append(ServiceTypes.mission_line(mission))
		metadata.append(mission)
	if lines.is_empty():
		lines.append(empty_text)
	_fill_list(list, lines, metadata)
	_say(tr("%%SVC_FMT_MISSION_COUNT") % page.total, DIM)


func _apply_mine(page: ServicePage, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_mine, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for entry: Dictionary in page.rows(result):
		lines.append(ServiceTypes.player_mission_line(entry))
		metadata.append(entry)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_ASSIGNMENTS"))
	_fill_list(_mine, lines, metadata)


# ---------------------------------------------------------------------------------------------
# Read-only contract
# ---------------------------------------------------------------------------------------------

## Selection handlers: the mission id of the picked row, rendered in that segment's contract box.
func _open_selected(list: ItemList, contract: VBoxContainer) -> void:
	var meta: Variant = _selected_meta(list)
	if not (meta is Dictionary):
		return
	var mission_id := str((meta as Dictionary).get("id", ""))
	if mission_id != "":
		await _open_contract(contract, mission_id)


func _open_mine(contract: VBoxContainer) -> void:
	var meta: Variant = _selected_meta(_mine)
	if not (meta is Dictionary):
		return
	var mission: Variant = (meta as Dictionary).get("mission")
	if not (mission is Dictionary):
		return
	var mission_id := str((mission as Dictionary).get("id", ""))
	if mission_id != "":
		await _open_contract(contract, mission_id)


## Load one mission and render it as a document in [param box].
func _open_contract(box: VBoxContainer, mission_id: String) -> void:
	_clear_contract(box)
	var result: Dictionary = await PlayerServices.mission_get(mission_id)
	if not bool(result.get("ok", false)):
		box.add_child(_label(HttpClient.describe_error(result), WARN))
		return
	if not (result.get("data") is Dictionary):
		box.add_child(_label(tr("%%SVC_MSG_UNEXPECTED"), WARN))
		return
	var data: Dictionary = result.get("data")
	var mission: Dictionary = data.get("mission", {}) if data.get("mission") is Dictionary else {}
	box.add_child(_contract_document(mission_id, mission, data, box))


## The read-only contract: header + stamp, meta block, description, prerequisites, numbered
## objective clauses, footer actions. Every action captures the mission id and [param contract], so
## the contract re-renders in place after a mutation.
func _contract_document(mission_id: String, mission: Dictionary, data: Dictionary,
		contract: VBoxContainer) -> Control:
	var card := _document_card()
	var doc := VBoxContainer.new()
	doc.add_theme_constant_override("separation", 12)
	doc.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Header: title + status stamp, then the rule.
	var header := _row(12)
	var title := _label(ServiceTypes.dash(mission.get("title")), ServiceStyle.TEXT)
	ServiceStyle.font_of(title, 22, true)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(_status_pill(str(mission.get("status", ""))))
	doc.add_child(header)
	doc.add_child(_rule())

	# Metadata block: the existing FMT labels, read-only.
	var rewards: Variant = mission.get("rewards")
	if rewards == null:
		rewards = mission.get("reward")
	var assignment: Dictionary = data.get("assignment") if data.get("assignment") is Dictionary else {}
	var meta := VBoxContainer.new()
	meta.add_theme_constant_override("separation", 3)
	meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_TYPE") % [
			ServiceTypes.mission_kind_label(mission.get("kind")),
			ServiceTypes.mission_category_label(mission.get("category"))], ServiceStyle.TEXT))
	meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_STATUS") %
			ServiceTypes.mission_status_label(mission.get("status")), ServiceStyle.TEXT))
	meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_ISSUER") %
			ServiceTypes.issuer_type_label(mission.get("issuerType")), ServiceStyle.TEXT))
	meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_REWARD") %
			ServiceTypes.rewards_text(rewards), ServiceStyle.TEXT))
	# Who funded the escrow — the field is absent on missions created before escrowPayerType
	# existed, so an old contract simply shows no line.
	var payer_type: Variant = mission.get("escrowPayerType")
	if payer_type is String and str(payer_type) != "":
		var payer := ServiceTypes.escrow_payer_label(payer_type)
		var payer_id: Variant = mission.get("escrowPayerId")
		if payer_id != null and str(payer_id) != "":
			payer = "%s (%s)" % [payer, str(payer_id)]
		meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_ESCROW") % payer, ServiceStyle.TEXT))
	meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_SLOTS") %
			ServiceTypes.num(mission.get("maxAssignees")), ServiceStyle.TEXT))
	# Availability zones — an empty list is the service's "global" mission. The field is absent
	# on payloads from before zones existed, so those contracts simply show no line.
	var zones: Variant = mission.get("zones")
	if zones is Array:
		meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_ZONES") %
				ServiceTypes.zones_text(zones), ServiceStyle.TEXT))
	if not assignment.is_empty():
		meta.add_child(_label(tr("%%SVC_FMT_MISSION_DETAIL_ASSIGNMENT") %
				ServiceTypes.assignment_line(assignment), ServiceStyle.TEXT))
	doc.add_child(meta)

	# Description.
	var description := str(mission.get("description", "")).strip_edges()
	if description != "":
		var body := _label(description, ServiceStyle.TEXT)
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		doc.add_child(_titled(tr("%%SVC_LBL_DESCRIPTION"), body))

	# Prerequisites.
	var prereqs: Variant = mission.get("prerequisites")
	if prereqs is Array and not (prereqs as Array).is_empty():
		var list := VBoxContainer.new()
		list.add_theme_constant_override("separation", 4)
		for prereq: Variant in prereqs:
			if prereq is Dictionary:
				var line := _label(ServiceTypes.prerequisite_line(prereq), ServiceStyle.TEXT)
				line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				list.add_child(line)
		doc.add_child(_titled(tr("%%SVC_LBL_PREREQUISITES"), list))

	# Numbered objectives.
	var objectives := VBoxContainer.new()
	objectives.add_theme_constant_override("separation", 8)
	objectives.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var items: Variant = data.get("objectives")
	var index := 0
	for objective: Variant in (items if items is Array else []):
		if objective is Dictionary:
			index += 1
			objectives.add_child(_objective_clause(mission_id, contract, mission,
					objective, index))
	if index == 0:
		objectives.add_child(_label(tr("%%SVC_MSG_NO_OBJECTIVES"), DIM))
	doc.add_child(_titled(tr("%%SVC_LBL_OBJECTIVES"), objectives))

	doc.add_child(_rule())
	doc.add_child(_contract_actions(mission_id, mission, assignment, contract))
	card.add_child(doc)
	return card


## One numbered objective clause: the sentence, its progress, the evaluation badge, and — on my
## own contracts — the issuer confirmation button.
func _objective_clause(mission_id: String, contract: VBoxContainer, mission: Dictionary,
		objective: Dictionary, index: int) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL_ALT, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 14.0, 10.0))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)

	var line := _row(8)
	var number := _label("%d." % index, ACCENT)
	ServiceStyle.font_of(number, 14, true)
	number.custom_minimum_size = Vector2(26, 0)
	line.add_child(number)
	var sentence := _label(ServiceTypes.dash(objective.get("title")), ServiceStyle.TEXT)
	ServiceStyle.font_of(sentence, 15)
	sentence.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sentence.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(sentence)
	box.add_child(line)

	var footer := _row(10)
	footer.add_child(_label(_objective_progress(objective), DIM))
	var entry := _kind_entry("objectiveKinds", str(objective.get("type", "")))
	var evaluation := str(entry.get("evaluation", ""))
	if evaluation != "":
		var badge := _label(ServiceTypes.evaluation_label(evaluation), DIM)
		ServiceStyle.font_of(badge, 11)
		footer.add_child(badge)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	if _can_confirm(mission, objective):
		_action_button(footer, tr("%%SVC_ACT_CONFIRM_OBJECTIVE"),
				func() -> void: _confirm(mission_id, str(objective.get("id", "")), contract))
	box.add_child(footer)
	return card


## "2/5 units · in progress" — language-neutral numbers, localized objective status.
func _objective_progress(objective: Dictionary) -> String:
	var progress := "%d/%d" % [ServiceTypes.num(objective.get("currentProgress")),
			ServiceTypes.num(objective.get("targetQuantity"))]
	var unit := str(objective.get("unit", "")).strip_edges()
	if unit != "":
		progress += " " + unit
	return progress + " · " + ServiceTypes.objective_status_label(objective.get("status"))


## Confirm only on my own open contract, for an issuer-evaluated objective not yet completed.
func _can_confirm(mission: Dictionary, objective: Dictionary) -> bool:
	if str(mission.get("issuerId", "")) != PlayerServices.player_id():
		return false
	var status := str(mission.get("status", ""))
	if status != "available" and status != "active":
		return false
	if str(objective.get("status", "")) == "completed":
		return false
	var entry := _kind_entry("objectiveKinds", str(objective.get("type", "")))
	return str(entry.get("evaluation", "")) == "issuer"


func _confirm(mission_id: String, objective_id: String, contract: VBoxContainer) -> void:
	if _report(await PlayerServices.mission_confirm(mission_id, objective_id),
			tr("%%SVC_MSG_OBJECTIVE_CONFIRMED")):
		await _open_contract(contract, mission_id)


## Footer: contextual lifecycle actions + the group share line.
func _contract_actions(mission_id: String, mission: Dictionary, assignment: Dictionary,
		contract: VBoxContainer) -> Control:
	var actions := VBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var status := str(mission.get("status", ""))
	var assignment_status := str(assignment.get("status", ""))

	# Accept stays on any open mission — the service is the one saying 409 (already assigned,
	# completed, full), exactly like the panel before the rework.
	if status == "available":
		var accept := _row()
		_action_button(accept, tr("%%SVC_ACT_ACCEPT"),
				func() -> void: _accept(mission_id, contract))
		actions.add_child(accept)

	if assignment_status == "active":
		var lifecycle := _row()
		_action_button(lifecycle, tr("%%SVC_ACT_ABANDON"),
				func() -> void: _abandon(mission_id, contract))
		_action_button(lifecycle, tr("%%SVC_ACT_COMPLETE"),
				func() -> void: _complete(mission_id, contract))
		actions.add_child(lifecycle)
		var progress := _row()
		progress.add_child(_label(tr("%%SVC_LBL_PROGRESS"), DIM))
		var objective_id := _field(tr("%%SVC_PH_OBJECTIVE_ID"), 240.0)
		var quantity := _number_field(tr("%%SVC_PH_QUANTITY"), 100.0)
		progress.add_child(objective_id)
		progress.add_child(quantity)
		_action_button(progress, tr("%%SVC_ACT_REPORT_PROGRESS"),
				func() -> void: _progress(mission_id, contract, objective_id, quantity))
		actions.add_child(progress)

	var group_id: Variant = mission.get("groupId")
	var shared: bool = group_id != null and str(group_id) != ""
	var share := _row()
	share.add_child(_label(tr("%%SVC_LBL_SHARED_GROUP") + " : " + (str(group_id) if shared else "—"), DIM))
	if shared:
		_action_button(share, tr("%%SVC_ACT_UNSHARE"),
				func() -> void: _unshare(mission_id, contract))
	else:
		_action_button(share, tr("%%SVC_ACT_SHARE"),
				func() -> void: _share(mission_id, contract))
	actions.add_child(share)
	return actions


func _accept(mission_id: String, contract: VBoxContainer) -> void:
	if _report(await PlayerServices.mission_accept(mission_id), tr("%%SVC_MSG_MISSION_ACCEPTED")):
		await _open_contract(contract, mission_id)


func _abandon(mission_id: String, contract: VBoxContainer) -> void:
	if _report(await PlayerServices.mission_abandon(mission_id), tr("%%SVC_MSG_MISSION_ABANDONED")):
		await _open_contract(contract, mission_id)


func _complete(mission_id: String, contract: VBoxContainer) -> void:
	var result: Dictionary = await PlayerServices.mission_complete(mission_id)
	if _report(result, tr("%%SVC_MSG_MISSION_COMPLETED")):
		if result.get("data") is Dictionary and (result.get("data") as Dictionary).get("settlement") != null:
			_say(tr("%%SVC_MSG_MISSION_COMPLETED") + " " + ServiceTypes.settlement_text(
					(result.get("data") as Dictionary).get("settlement")), GOOD)
		await _open_contract(contract, mission_id)
		refresh()


func _progress(mission_id: String, contract: VBoxContainer, objective_field: LineEdit,
		quantity_field: LineEdit) -> void:
	release_fields()
	var objective_id: String = objective_field.text.strip_edges()
	if objective_id == "" or not quantity_field.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_OBJECTIVE_QUANTITY"), WARN)
		return
	var result: Dictionary = await PlayerServices.mission_progress(mission_id, objective_id,
			int(quantity_field.text))
	if _report(result, tr("%%SVC_MSG_PROGRESS_SAVED")):
		await _open_contract(contract, mission_id)


# ---------------------------------------------------------------------------------------------
# Sharing with the group (Squad)
# ---------------------------------------------------------------------------------------------

func _share(mission_id: String, contract: VBoxContainer) -> void:
	var mine: Dictionary = await PlayerServices.my_group()
	if not bool(mine.get("ok", false)):
		_say(HttpClient.describe_error(mine), WARN)
		return
	var group: Variant = mine.get("data")
	if not (group is Dictionary):
		_say(tr("%%SVC_MSG_NO_GROUP"), WARN)
		return
	var result: Dictionary = await PlayerServices.mission_share(mission_id,
			str((group as Dictionary).get("id", "")))
	if _report(result, tr("%%SVC_MSG_MISSION_SHARED")):
		await _open_contract(contract, mission_id)


func _unshare(mission_id: String, contract: VBoxContainer) -> void:
	if _report(await PlayerServices.mission_unshare(mission_id), tr("%%SVC_MSG_SHARE_REMOVED")):
		await _open_contract(contract, mission_id)


# ---------------------------------------------------------------------------------------------
# Clauses — construction (edit mode)
# ---------------------------------------------------------------------------------------------

func _add_objective_row() -> void:
	_create_objectives.add_child(_new_clause("objectiveKinds", true, _objective_rows))
	_renumber_clauses()


func _add_prereq_row() -> void:
	_create_prereqs.add_child(_new_clause("prerequisiteKinds", false, _prereq_rows))
	_renumber_clauses()


## Keep the "1. 2. 3." contract numbering honest across adds and removals.
func _renumber_clauses() -> void:
	var index := 1
	for row: Dictionary in _objective_rows:
		(row["index"] as Label).text = "%d." % index
		index += 1
	index = 1
	for row: Dictionary in _prereq_rows:
		(row["index"] as Label).text = "%d." % index
		index += 1


# ---------------------------------------------------------------------------------------------
# Tab 3 — zone rows (the availability list)
# ---------------------------------------------------------------------------------------------

## One zone card: numbered head (N. kind ▾ · ×) over the fields its kind owns. The kind is the
## service's strict MissionZone discriminator; picking another one tears the fields down and
## rebuilds them, the way a clause rebuilds when its kind changes. [param kind_value] preselects
## a kind (the position prefill starts the row on the richest thing the location carries).
func _new_zone_row(kind_value: String = "") -> PanelContainer:
	var row := {}
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL_ALT, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 14.0, 10.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var head := _row(8)
	var index := _label("1.", ACCENT)
	ServiceStyle.font_of(index, 14, true)
	index.custom_minimum_size = Vector2(26, 0)
	head.add_child(index)
	var kind := _option_enum(ZONE_ENTRIES, 140.0)
	if kind.selected < 0 and kind.item_count > 0:
		kind.select(0)
	var entry_index := 0
	for entry: Array in ZONE_ENTRIES:
		if str(entry[0]) == kind_value:
			kind.select(entry_index)
			break
		entry_index += 1
	head.add_child(kind)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	_action_button(head, "×", func() -> void: _remove_zone_row(row))
	box.add_child(head)

	var flow := FlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 6)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(flow)

	# Fill the SAME dictionary the × lambda captured above — rebinding `row` would leave that
	# closure holding an empty dict.
	row["panel"] = panel
	row["index"] = index
	row["kind"] = kind
	row["flow"] = flow
	row["fields"] = []
	_create_zones.add_child(panel)
	_zone_rows.append(row)
	_renumber_zones()
	_rebuild_zone_fields(row)
	kind.item_selected.connect(func(_i: int) -> void: _rebuild_zone_fields(row))
	return panel


func _remove_zone_row(row: Dictionary) -> void:
	_zone_rows.erase(row)
	for field: LineEdit in row.get("fields", []):
		_forget_field(field)
	var panel: Variant = row.get("panel")
	if panel is Node and is_instance_valid(panel):
		(panel as Node).queue_free()
	_renumber_zones()


## Zone rows number "1. 2. 3." the way the clauses do.
func _renumber_zones() -> void:
	var index := 1
	for row: Dictionary in _zone_rows:
		(row["index"] as Label).text = "%d." % index
		index += 1


## Drop a zone row's current fields (they belonged to the previous kind) and build the ones the
## chosen kind owns: `system` alone, `scene` (optionally narrowed to a system), or `area`
## (optional system + centre x/y/z + radius in metres).
func _rebuild_zone_fields(row: Dictionary) -> void:
	# `system` is the one field every kind carries, so a kind switch keeps what was typed there.
	var system := _zone_text(row.get("system"))
	for field: LineEdit in row.get("fields", []):
		_forget_field(field)
	var flow: FlowContainer = row["flow"]
	_clear(flow)
	for key: String in ["system", "scene", "cx", "cy", "cz", "radius"]:
		row[key] = null
	row["fields"] = []
	var kind := _enum_value(row["kind"] as OptionButton)
	_zone_edit(row, flow, "system", tr("%%SVC_PH_ZONE_SYSTEM"), 150.0, false)
	if system != "":
		(row["system"] as LineEdit).text = system
	if kind == "system":
		return
	if kind == "scene":
		_zone_edit(row, flow, "scene", tr("%%SVC_PH_ZONE_SCENE"), 200.0, false)
		return
	_zone_edit(row, flow, "cx", tr("%%SVC_PH_ZONE_X"), 70.0, false)
	_zone_edit(row, flow, "cy", tr("%%SVC_PH_ZONE_Y"), 70.0, false)
	_zone_edit(row, flow, "cz", tr("%%SVC_PH_ZONE_Z"), 70.0, false)
	_zone_edit(row, flow, "radius", tr("%%SVC_PH_ZONE_RADIUS"), 90.0, true)


## One zone field: registered with the keyboard contract, named on the row, and listed in the
## row's field registry so a kind change or a removal can drop it again.
func _zone_edit(row: Dictionary, flow: FlowContainer, key: String, placeholder: String,
		width: float, integer: bool) -> void:
	var field: LineEdit = _number_field(placeholder, width) if integer \
			else _field(placeholder, width)
	row[key] = field
	(row["fields"] as Array).append(field)
	flow.add_child(field)


## Prefill the first zone row from the player's own presence location (`/api/me` →
## `presence.location` = {system, scene, position}), whatever the chosen kind can carry: empty
## fields only, so a value already typed stays put.
func _use_my_position() -> void:
	var result: Dictionary = await PlayerServices.profile_get()
	if not bool(result.get("ok", false)):
		_say(HttpClient.describe_error(result), WARN)
		return
	var data: Variant = result.get("data")
	var presence: Variant = (data as Dictionary).get("presence") if data is Dictionary else null
	var location: Variant = (presence as Dictionary).get("location") if presence is Dictionary \
			else null
	if not (location is Dictionary):
		_say(tr("%%SVC_MSG_NO_POSITION"), WARN)
		return
	var loc: Dictionary = location
	var position: Variant = loc.get("position")
	var system := str(loc.get("system", "")).strip_edges()
	var scene := str(loc.get("scene", "")).strip_edges()
	if system == "" and scene == "" and not (position is Dictionary):
		_say(tr("%%SVC_MSG_NO_POSITION"), WARN)
		return
	if _zone_rows.is_empty():
		_new_zone_row(_prefill_zone_kind(system, scene))
	var row: Dictionary = _zone_rows[0]
	_prefill_zone_field(row.get("system"), system)
	_prefill_zone_field(row.get("scene"), scene)
	if position is Dictionary:
		_prefill_zone_field(row.get("cx"), str((position as Dictionary).get("x", "")))
		_prefill_zone_field(row.get("cy"), str((position as Dictionary).get("y", "")))
		_prefill_zone_field(row.get("cz"), str((position as Dictionary).get("z", "")))
		var radius: Variant = row.get("radius")
		if radius is LineEdit and (radius as LineEdit).text.strip_edges() == "":
			(radius as LineEdit).text = "1000"
	var location_text := ServiceTypes.location_text(loc)
	if location_text != "":
		_say(location_text, GOOD)


## The kind a prefilled row starts on — the richest thing the location actually carries: a scene
## path narrows the most, a bare system next, and only a position with neither needs an area.
static func _prefill_zone_kind(system: String, scene: String) -> String:
	if scene != "":
		return "scene"
	return "system" if system != "" else "area"


## One clause card: numbered head (N. kind ▾ · evaluation badge · quantity · ×) over the sentence
## flow, with a stacked fallback box for catalogue-less kinds. Registered in [param rows].
func _new_clause(catalog_key: String, with_title: bool, rows: Array) -> PanelContainer:
	var row := {}
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL_ALT, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 14.0, 10.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var head := _row(8)
	var index := _label("1.", ACCENT)
	ServiceStyle.font_of(index, 14, true)
	index.custom_minimum_size = Vector2(26, 0)
	head.add_child(index)
	var kind := _option_enum(_kind_options(catalog_key, _current_category()), 170.0)
	if kind.selected < 0 and kind.item_count > 0:
		kind.select(0)
	head.add_child(kind)
	var badge := _label("", DIM)
	ServiceStyle.font_of(badge, 11)
	head.add_child(badge)
	var qty := _number_field(tr("%%SVC_PH_QUANTITY"), 90.0) if with_title else null
	if with_title:
		head.add_child(qty)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	_action_button(head, "×", func() -> void: _remove_clause(row))
	box.add_child(head)

	var flow := FlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 6)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(flow)
	var fallback_box := VBoxContainer.new()
	fallback_box.add_theme_constant_override("separation", 6)
	box.add_child(fallback_box)

	# Fill the SAME dictionary the × lambda captured above — rebinding `row` would leave that
	# closure holding an empty dict.
	row["panel"] = panel
	row["index"] = index
	row["kind"] = kind
	row["badge"] = badge
	row["qty"] = qty
	row["flow"] = flow
	row["fallback_box"] = fallback_box
	row["catalog_key"] = catalog_key
	row["with_title"] = with_title
	row["segments"] = []
	row["vars"] = []
	row["title_field"] = null
	row["param_fields"] = []
	row["param_raw"] = null
	row["schema_required"] = []
	row["schema_has_required"] = false
	kind.item_selected.connect(func(i: int) -> void: _kind_changed(row, i))
	rows.append(row)
	_kind_changed(row, maxi(kind.selected, 0))
	return panel


func _remove_clause(row: Dictionary) -> void:
	_objective_rows.erase(row)
	_prereq_rows.erase(row)
	for field: LineEdit in _row_fields(row):
		_forget_field(field)
	(row["panel"] as Node).queue_free()
	_renumber_clauses()


## Kind chosen: tear the clause down and rebuild it from the new kind's summary — a decomposed
## sentence when it carries variables, the stacked form otherwise.
func _kind_changed(row: Dictionary, index: int) -> void:
	var kind_button := row["kind"] as OptionButton
	if index < 0 or index >= kind_button.item_count:
		return
	for field: LineEdit in _dynamic_fields(row):
		_forget_field(field)
	row["vars"] = []
	row["segments"] = []
	row["title_field"] = null
	row["param_fields"] = []
	row["param_raw"] = null
	row["schema_required"] = []
	row["schema_has_required"] = false
	_clear(row["flow"])
	_clear(row["fallback_box"])

	var kind := str(kind_button.get_item_metadata(index))
	var entry := _kind_entry(str(row["catalog_key"]), kind)
	var evaluation := str(entry.get("evaluation", ""))
	var badge := row["badge"] as Label
	badge.visible = evaluation != ""
	badge.text = ServiceTypes.evaluation_label(evaluation)

	var schema: Variant = entry.get("params")
	if schema is Dictionary and (schema as Dictionary).get("required") is Array:
		row["schema_required"] = (schema as Dictionary).get("required")
		row["schema_has_required"] = true

	var summary := str(entry.get("summary", "")).strip_edges()
	var segments := _split_template(summary)
	var has_vars := false
	for segment: Dictionary in segments:
		if segment.has("var"):
			has_vars = true
			break
	if has_vars:
		row["segments"] = segments
		_render_sentence(row, segments, entry, badge.visible)
	else:
		if summary != "":
			(row["flow"] as FlowContainer).add_child(_label(_without_trailing_note(summary, badge.visible),
					DIM))
		if bool(row["with_title"]):
			var title := _field(tr("%%SVC_PH_OBJECTIVE"), 260.0)
			(row["fallback_box"] as VBoxContainer).add_child(title)
			row["title_field"] = title
		_rebuild_params(row, entry)

	# The quantity field joins the head only for quantity objectives whose sentence has no
	# {targetQuantity} of its own.
	var qty: Variant = row.get("qty")
	if qty is LineEdit:
		var has_target := false
		for variable: Dictionary in row["vars"]:
			if str(variable["name"]) == "targetQuantity":
				has_target = true
		(qty as LineEdit).visible = bool(row["with_title"]) \
				and bool(entry.get("quantity", true)) and not has_target


## The sentence: literals as labels (parenthetical notes muted, the trailing one dropped when the
## evaluation badge already says it), variables as their typed inline controls.
func _render_sentence(row: Dictionary, segments: Array, entry: Dictionary, drop_note: bool) -> void:
	var flow := row["flow"] as FlowContainer
	var objective := bool(row["with_title"])
	var last := segments.size() - 1
	for i: int in range(segments.size()):
		var segment: Dictionary = segments[i]
		if segment.has("var"):
			var name := str(segment["var"])
			var parts := _var_control(name, entry, objective)
			flow.add_child(parts[0])
			(row["vars"] as Array).append({"name": name, "control": parts[0], "meta": parts[1]})
		else:
			var literal := str(segment["text"]).strip_edges()
			if literal == "":
				continue
			var note := i == last and _is_parenthetical(literal)
			if note and drop_note:
				continue
			flow.add_child(_label(literal, DIM if note else ServiceStyle.TEXT))


## One inline control for a sentence variable, and where its value must land: the kind's params
## schema first, then the objective's own fields, then params in the open. A prerequisite is only
## {kind, params} — its variables never reach an objective field.
func _var_control(name: String, entry: Dictionary, objective: bool) -> Array:
	var properties := {}
	var schema: Variant = entry.get("params")
	if schema is Dictionary:
		var declared: Variant = (schema as Dictionary).get("properties")
		if declared is Dictionary:
			properties = declared
	if properties.has(name):
		var property: Dictionary = properties[name] if properties[name] is Dictionary else {}
		var hint := str(property.get("title", property.get("description", name)))
		var enum_values: Variant = property.get("enum")
		if enum_values is Array and not (enum_values as Array).is_empty():
			var option := OptionButton.new()
			ServiceStyle.apply_option(option)
			option.custom_minimum_size = Vector2(140, 34)
			for value: Variant in enum_values:
				option.add_item(str(value))
				option.set_item_metadata(option.item_count - 1, str(value))
			var chosen := 0
			var default_value: Variant = property.get("default")
			if default_value != null:
				for i: int in range(option.item_count):
					if str(option.get_item_metadata(i)) == str(default_value):
						chosen = i
						break
			option.select(chosen)
			return [option, {"name": name, "target": "param",
					"ptype": str(property.get("type", "string"))}]
		var ptype: String = str(property.get("type", "string"))
		if ptype == "boolean":
			var check := CheckBox.new()
			check.button_pressed = bool(property.get("default", false))
			return [check, {"name": name, "target": "param", "ptype": "boolean"}]
		var field: LineEdit = _number_field(hint, 110.0) if ptype in ["integer", "number"] \
				else _field(hint, 150.0)
		var default_scalar: Variant = property.get("default")
		if default_scalar != null:
			field.text = str(default_scalar)
		return [field, {"name": name, "target": "param", "ptype": ptype}]
	if not objective:
		var free := _field(name, 140.0)
		return [free, {"name": name, "target": "param", "ptype": "string"}]
	match name:
		"targetQuantity":
			return [_number_field(name, 90.0), {"name": name, "target": "targetQuantity",
					"ptype": "integer"}]
		"locationTo", "locationFrom":
			return [_field(tr("%%SVC_PH_LOCATION"), 150.0), {"name": name, "target": name,
					"ptype": "location"}]
		"unit":
			return [_field(name, 90.0), {"name": name, "target": "unit", "ptype": "string"}]
	return [_field(name, 140.0), {"name": name, "target": "param", "ptype": "string"}]


## Catalogue-less kinds: the params schema still rendered as stacked fields under the summary
## (fields were already forgotten by the caller; this appends into the cleared fallback box).
func _rebuild_params(row: Dictionary, entry: Dictionary) -> void:
	var box := row["fallback_box"] as VBoxContainer
	var schema: Variant = entry.get("params")
	var properties: Variant = (schema as Dictionary).get("properties") if schema is Dictionary else null
	if not (properties is Dictionary) or (properties as Dictionary).is_empty():
		return
	var rendered: bool = false
	for name: Variant in properties:
		var property: Variant = properties[name]
		if not (property is Dictionary):
			continue
		var ptype: String = str((property as Dictionary).get("type", "string"))
		if not (ptype in ["string", "integer", "number", "boolean"]):
			continue
		var hint: String = str((property as Dictionary).get("title",
				(property as Dictionary).get("description", name)))
		var field := _field(hint, 160.0)
		box.add_child(field)
		(row["param_fields"] as Array).append([str(name), ptype, field])
		rendered = true
	if not rendered:
		var raw := _field(tr("%%SVC_PH_PARAMS_JSON"), 320.0)
		box.add_child(raw)
		row["param_raw"] = raw


## Existing clauses re-option themselves when the catalogue lands after they were built.
func _refill_row(row: Dictionary) -> void:
	_fill_options(row["kind"] as OptionButton,
			_kind_options(str(row["catalog_key"]), _current_category()))
	_kind_changed(row, maxi((row["kind"] as OptionButton).selected, 0))


## Re-filter one clause's kind dropdown for the category now selected, keeping the kind when it is
## still allowed (the sentence and its typed values survive); a kind the new category forbids falls
## back to the first allowed one and its clause silently rebuilds.
func _filter_row_kind(row: Dictionary) -> void:
	var kind_button := row["kind"] as OptionButton
	var previous := _enum_value(kind_button)
	_fill_options(kind_button, _kind_options(str(row["catalog_key"]), _current_category()))
	if _enum_value(kind_button) != previous:
		_kind_changed(row, maxi(kind_button.selected, 0))


## The create form's current category — what the clause kind filters read.
func _current_category() -> String:
	return _enum_value(_create_category) if _create_category != null else ""


## Category picked: re-filter every clause (objectives and prerequisites alike — the service
## rejects a mismatched pair with OBJECTIVE_NOT_IN_CATEGORY / PREREQ_NOT_IN_CATEGORY).
func _on_category_changed(_index: int) -> void:
	for row: Dictionary in _objective_rows:
		_filter_row_kind(row)
	for row: Dictionary in _prereq_rows:
		_filter_row_kind(row)


# ---------------------------------------------------------------------------------------------
# Template — splitting and rebuilding the sentence
# ---------------------------------------------------------------------------------------------

## Split a catalogue summary into alternating literal / variable segments. `{name}` matches first,
## the legacy backtick form too; an unbalanced delimiter simply stays literal.
static func _split_template(text: String) -> Array:
	var out: Array = []
	if text.strip_edges() == "":
		return out
	var regex := RegEx.create_from_string(TEMPLATE_PATTERN)
	if regex == null:
		return out
	var cursor := 0
	for found: RegExMatch in regex.search_all(text):
		var before := text.substr(cursor, found.get_start() - cursor)
		if before != "":
			out.append({"text": before})
		var name := found.get_string(1)
		if name == "":
			name = found.get_string(2)
		out.append({"var": name})
		cursor = found.get_end()
	var tail := text.substr(cursor)
	if tail != "":
		out.append({"text": tail})
	return out


## The objective title the server receives: the template with every variable replaced by the value
## the player typed (an empty optional one falls back to its name).
static func _sentence_title(row: Dictionary, values: Dictionary) -> String:
	var out := ""
	for segment: Dictionary in row.get("segments", []):
		if segment.has("var"):
			var name := str(segment["var"])
			out += str(values.get(name, name))
		else:
			out += str(segment["text"])
	return out.strip_edges()


static func _is_parenthetical(text: String) -> bool:
	var trimmed := text.strip_edges()
	return trimmed.length() >= 2 and trimmed.begins_with("(") and trimmed.ends_with(")")


## Drop the trailing "(measured against Economy)" note when the badge already carries it.
static func _without_trailing_note(summary: String, drop: bool) -> String:
	if not drop or not summary.ends_with(")"):
		return summary
	var open := summary.rfind("(")
	if open < 0:
		return summary
	return summary.substr(0, open).strip_edges()


# ---------------------------------------------------------------------------------------------
# Creation — collection and send
# ---------------------------------------------------------------------------------------------

func _validate_spec() -> void:
	var body := _build_body()
	if body.is_empty():
		return
	var result: Dictionary = await PlayerServices.mission_validate(body)
	if bool(result.get("ok", false)):
		_say(tr("%%SVC_MSG_SPEC_VALID"), GOOD)
	else:
		_say(HttpClient.describe_error(result), WARN)


func _create() -> void:
	var body := _build_body()
	if body.is_empty():
		return
	# Dry-run first: the service answers the exact 400 the create would, without escrow held.
	var check: Dictionary = await PlayerServices.mission_validate(body)
	if not bool(check.get("ok", false)):
		_say(HttpClient.describe_error(check), WARN)
		return
	var result: Dictionary = await PlayerServices.mission_create(body)
	if _report(result, tr("%%SVC_MSG_MISSION_CREATED")):
		_reset_create()
		refresh()


## The CreatePlayerMission body, or {} after reporting the first local problem.
func _build_body() -> Dictionary:
	release_fields()
	var title: String = _create_title.text.strip_edges()
	var objectives: Variant = _collect_objectives()
	if objectives == null:
		return {}  # the collector already said which clause is incomplete
	if title == "" or (objectives as Array).is_empty():
		_say(tr("%%SVC_MSG_TITLE_OBJECTIVE_REQUIRED"), WARN)
		return {}
	var visibility: String = _enum_value(_create_visibility)
	if visibility == "corporation" and _create_corp_picker.picked_id() == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return {}
	var raw_amount: String = _create_amount.text.strip_edges()
	var amount: int = maxi(int(raw_amount) if raw_amount.is_valid_int() else 1, 1)
	var body := {
		"title": title,
		"visibility": visibility,
		"rewards": [{"type": "credits", "currency": "credits", "amount": amount}],
		"objectives": objectives,
	}
	var description: String = _create_description.text.strip_edges()
	if description != "":
		body["description"] = description
	var category: String = _enum_value(_create_category)
	if category != "":
		body["category"] = category
	var raw_max: String = _create_max.text.strip_edges()
	if raw_max.is_valid_int():
		body["maxAssignees"] = int(raw_max)
	if visibility == "corporation":
		body["corporationId"] = _create_corp_picker.picked_id()
		# Sent only when picked: the service default is `creator`, and the dry-run does not see
		# this field — the real POST answers ESCROW_SOURCE_INVALID / TREASURY_FORBIDDEN /
		# INSUFFICIENT_FUNDS, which _report shows verbatim.
		if _enum_value(_create_escrow) == "issuer":
			body["escrowSource"] = "issuer"
	var prereqs: Variant = _collect_prereqs()
	if prereqs == null:
		return {}  # an incomplete required variable was reported by the collector
	if not (prereqs as Array).is_empty():
		body["prerequisites"] = prereqs
	var zones: Variant = _collect_zones()
	if zones == null:
		return {}  # an incomplete zone was reported by the collector
	if not (zones as Array).is_empty():
		body["zones"] = zones
	return body


## Objectives: sentence clauses substitute their variables into the title; stacked clauses keep a
## plain title field. Null when a clause is incomplete (reported here).
func _collect_objectives() -> Variant:
	var out: Array = []
	var order: int = 0
	for row: Dictionary in _objective_rows:
		var objective := {}
		if not (row["vars"] as Array).is_empty():
			var got: Variant = _collect_vars(row)
			if got == null:
				_say(tr("%%SVC_MSG_FILL_CLAUSE"), WARN)
				return null
			objective = {"type": _enum_value(row["kind"] as OptionButton),
					"title": _sentence_title(row, (got as Dictionary)["values"]), "order": order}
			_merge_clause(objective, got)
		else:
			var title_field: LineEdit = row.get("title_field")
			var title: String = title_field.text.strip_edges() if title_field != null else ""
			if title == "":
				_say(tr("%%SVC_MSG_TITLE_OBJECTIVE_REQUIRED"), WARN)
				return null
			objective = {"type": _enum_value(row["kind"] as OptionButton),
					"title": title, "order": order}
			var qty: Variant = row.get("qty")
			if qty is LineEdit and (qty as LineEdit).visible:
				var raw: String = (qty as LineEdit).text.strip_edges()
				objective["targetQuantity"] = maxi(int(raw) if raw.is_valid_int() else 1, 1)
			var stacked: Variant = _collect_params(row)
			if stacked != null:
				objective["params"] = stacked
		out.append(objective)
		order += 1
	return out


func _collect_prereqs() -> Variant:
	var out: Array = []
	for row: Dictionary in _prereq_rows:
		var prereq := {"kind": _enum_value(row["kind"] as OptionButton)}
		if not (row["vars"] as Array).is_empty():
			var got: Variant = _collect_vars(row)
			if got == null:
				_say(tr("%%SVC_MSG_FILL_CLAUSE"), WARN)
				return null
			if not (got as Dictionary)["params"].is_empty():
				prereq["params"] = (got as Dictionary)["params"]
		else:
			var stacked: Variant = _collect_params(row)
			if stacked != null:
				prereq["params"] = stacked
		out.append(prereq)
	return out


## Zones: [] when no row is left (the service's "global" mission), null after the first
## incomplete row has been reported — the same contract as the objective/prereq collectors.
func _collect_zones() -> Variant:
	var out: Array = []
	for row: Dictionary in _zone_rows:
		var zone: Variant = _collect_zone(row)
		if zone == null:
			return null
		out.append(zone)
	return out


## One row's MissionZone payload, carrying only the keys the service's strict schema accepts for
## its kind — a `.strict()` union, so an extra key is a validation error, not an ignored field.
func _collect_zone(row: Dictionary) -> Variant:
	var kind := _enum_value(row["kind"] as OptionButton)
	var system := _zone_text(row.get("system"))
	if kind == "system":
		if system == "":
			_say(tr("%%SVC_MSG_ZONE_SYSTEM_REQUIRED"), WARN)
			return null
		return {"kind": "system", "system": system}
	if kind == "scene":
		var scene := _zone_text(row.get("scene"))
		if scene == "":
			_say(tr("%%SVC_MSG_ZONE_SCENE_REQUIRED"), WARN)
			return null
		var scene_zone := {"kind": "scene", "scene": scene}
		if system != "":
			scene_zone["system"] = system
		return scene_zone
	var point := {}
	for axis: Array in [["cx", "x"], ["cy", "y"], ["cz", "z"]]:
		var raw := _zone_text(row.get(axis[0]))
		if not raw.is_valid_float():
			_say(tr("%%SVC_MSG_ZONE_AREA_INVALID"), WARN)
			return null
		point[str(axis[1])] = float(raw)
	var radius := _zone_text(row.get("radius"))
	if not radius.is_valid_int() or int(radius) < 1 or int(radius) > 1000000:
		_say(tr("%%SVC_MSG_ZONE_AREA_INVALID"), WARN)
		return null
	var area_zone := {"kind": "area", "center": point, "radiusM": int(radius)}
	if system != "":
		area_zone["system"] = system
	return area_zone


## The inline variables of one sentence: display values for the title substitution plus their typed
## destinations. Null when a required variable is empty — a half-filled sentence never ships.
func _collect_vars(row: Dictionary) -> Variant:
	var values := {}
	var params := {}
	var out := {"values": values, "params": params, "targetQuantity": null,
			"locationTo": null, "locationFrom": null, "unit": null}
	var objective := bool(row["with_title"])
	var has_required := bool(row.get("schema_has_required", false))
	var required_names: Array = row.get("schema_required", [])
	for variable: Dictionary in row["vars"]:
		var name := str(variable["name"])
		var control: Control = variable["control"]
		var target := str((variable["meta"] as Dictionary).get("target", "param"))
		var ptype := str((variable["meta"] as Dictionary).get("ptype", "string"))
		# Every objective word must be filled; a prerequisite only owes what its schema requires
		# (and everything when the schema is silent).
		var required: bool = objective or not has_required or name in required_names
		if control is CheckBox:
			var pressed := (control as CheckBox).button_pressed
			values[name] = "true" if pressed else "false"
			if target == "param":
				params[name] = pressed
			continue
		var raw := ""
		var is_set := false
		if control is OptionButton:
			var option := control as OptionButton
			if option.selected >= 0:
				raw = str(option.get_item_metadata(option.selected))
				is_set = raw != ""
		elif control is LineEdit:
			raw = (control as LineEdit).text.strip_edges()
			is_set = raw != ""
		values[name] = raw if is_set else name
		if not is_set:
			if required:
				return null
			continue
		match target:
			"param":
				var typed: Variant = _typed(raw, ptype)
				if typed == null:
					if required:
						return null
					continue
				params[name] = typed
			"targetQuantity":
				if raw.is_valid_int() and int(raw) >= 1:
					out["targetQuantity"] = int(raw)
				elif required:
					return null
			"locationTo", "locationFrom":
				# The objective field is an object; the game reads the scene path out of it.
				out[target] = {"scene": raw}
			"unit":
				out["unit"] = raw
	return out


## Copy the non-params destinations of a collected sentence onto its objective.
static func _merge_clause(objective: Dictionary, got: Variant) -> void:
	var collected: Dictionary = got
	if not (collected["params"] as Dictionary).is_empty():
		objective["params"] = collected["params"]
	for key: String in ["targetQuantity", "locationTo", "locationFrom", "unit"]:
		if collected[key] != null:
			objective[key] = collected[key]


## The typed params of one stacked row: every filled primitive field, plus the raw JSON fallback.
func _collect_params(row: Dictionary) -> Variant:
	var params := {}
	for entry: Array in row.get("param_fields", []):
		var field: LineEdit = entry[2]
		var raw: String = field.text.strip_edges()
		if raw == "":
			continue
		var typed: Variant = _typed(raw, str(entry[1]))
		if typed != null:
			params[entry[0]] = typed
	var raw_field: Variant = row.get("param_raw")
	if raw_field is LineEdit and (raw_field as LineEdit).text.strip_edges() != "":
		var parsed: Variant = JSON.parse_string((raw_field as LineEdit).text)
		if parsed is Dictionary:
			for key: Variant in parsed:
				params[key] = parsed[key]
	return params if not params.is_empty() else null


static func _typed(raw: String, ptype: String) -> Variant:
	match ptype:
		"integer":
			return int(raw) if raw.is_valid_int() else null
		"number":
			return float(raw) if raw.is_valid_float() else null
		"boolean":
			var lowered := raw.to_lower()
			if lowered in ["true", "1", "yes", "oui"]:
				return true
			if lowered in ["false", "0", "no", "non"]:
				return false
			return null
	return raw


func _reset_create() -> void:
	_create_title.text = ""
	_create_description.text = ""
	_create_amount.text = ""
	_create_max.text = ""
	_create_corp_picker.clear_pick()
	for row: Dictionary in _objective_rows:
		for field: LineEdit in _row_fields(row):
			_forget_field(field)
	for row: Dictionary in _prereq_rows:
		for field: LineEdit in _row_fields(row):
			_forget_field(field)
	_objective_rows.clear()
	_prereq_rows.clear()
	for row: Dictionary in _zone_rows:
		for field: LineEdit in row.get("fields", []):
			_forget_field(field)
	_zone_rows.clear()
	_clear(_create_objectives)
	_clear(_create_prereqs)
	_clear(_create_zones)
	_add_objective_row()


# ---------------------------------------------------------------------------------------------
# Catalogue and options
# ---------------------------------------------------------------------------------------------

## Create-form categories: the catalogue's list, else every real entry of the browse enum.
func _category_options() -> Array:
	var out: Array = []
	var categories: Variant = _catalog.get("categories")
	if categories is Array and not (categories as Array).is_empty():
		for category: Variant in categories:
			var value := str(category)
			out.append([value, ServiceTypes.MISSION_CATEGORY_KEYS.get(value, value)])
		return out
	for entry: Array in CATEGORY_ENTRIES:
		if str(entry[0]) != "":
			out.append(entry)
	return out


## Kind options for one clause, filtered to the create form's current category: the catalogue
## marks each kind `all` or with an explicit category list (the service enforces the same pair at
## validate time). Labels are the raw kind names — the catalogue summary is the sentence, not a
## dropdown caption. No catalogue (or a category nothing matches) falls back to the full list.
func _kind_options(catalog_key: String, category: String) -> Array:
	var kinds: Variant = _catalog.get(catalog_key)
	if kinds is Array and not (kinds as Array).is_empty():
		var all: Array = []
		var allowed: Array = []
		for entry: Variant in kinds:
			if not (entry is Dictionary):
				continue
			var kind := str((entry as Dictionary).get("kind", ""))
			all.append([kind, kind])
			if _kind_fits_category(entry, category):
				allowed.append([kind, kind])
		return allowed if not allowed.is_empty() else all
	if catalog_key == "prerequisiteKinds":
		var out: Array = []
		for kind: String in PREREQ_FALLBACK:
			out.append([kind, kind])
		return out
	return OBJECTIVE_TYPE_ENTRIES


## Does this catalogue entry allow [param category]? `all` covers everything, a list is an
## exact membership test; an absent field is tolerated (the dry-run is the enforcer).
static func _kind_fits_category(entry: Dictionary, category: String) -> bool:
	var allowed: Variant = entry.get("categories")
	if allowed is String:
		return str(allowed) == "all" or str(allowed) == category
	if allowed is Array:
		return (allowed as Array).has(category)
	return true


## The catalogue entry for one kind ({} when the catalogue never landed).
func _kind_entry(catalog_key: String, kind: String) -> Dictionary:
	var kinds: Variant = _catalog.get(catalog_key)
	if kinds is Array:
		for entry: Variant in kinds:
			if entry is Dictionary and str((entry as Dictionary).get("kind", "")) == kind:
				return entry
	return {}


## Refill an OptionButton from [value, label] pairs, keeping the previous selection when its value
## is still on offer (the catalogue landing must not reset what the player already picked).
func _fill_options(option: OptionButton, entries: Array) -> void:
	var previous: String = _enum_value(option)
	option.clear()
	for entry: Array in entries:
		option.add_item(tr(str(entry[1])))
		option.set_item_metadata(option.item_count - 1, str(entry[0]))
	var restored: bool = false
	if previous != "":
		for i: int in range(option.item_count):
			if str(option.get_item_metadata(i)) == previous:
				option.select(i)
				restored = true
				break
	if not restored and option.item_count > 0:
		option.select(0)


## The issuer block (corporation pick + funding selector) belongs to the corporation visibility
## only; a public contract is paid by its creator, so the whole row disappears.
func _update_corp_field() -> void:
	var corporate := _enum_value(_create_visibility) == "corporation"
	_create_corp_row.visible = corporate
	_escrow_caption.visible = corporate
	_create_escrow.visible = corporate


# ---------------------------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------------------------

## Empty a contract box after dropping its fields from the keyboard contract's registry.
func _clear_contract(box: VBoxContainer) -> void:
	var kept: Array[LineEdit] = []
	for field: LineEdit in _fields:
		if field != null and box.is_ancestor_of(field):
			continue
		kept.append(field)
	_fields = kept
	_clear(box)


## The clause's controls that die with the current kind (sentence variables, stacked title/params).
func _dynamic_fields(row: Dictionary) -> Array[LineEdit]:
	var out: Array[LineEdit] = []
	var title: Variant = row.get("title_field")
	if title is LineEdit:
		out.append(title)
	for entry: Variant in row.get("param_fields", []):
		if entry is Array and (entry as Array).size() >= 3 and (entry as Array)[2] is LineEdit:
			out.append((entry as Array)[2])
	var raw: Variant = row.get("param_raw")
	if raw is LineEdit:
		out.append(raw)
	for variable: Variant in row.get("vars", []):
		if variable is Dictionary and (variable as Dictionary).get("control") is LineEdit:
			out.append((variable as Dictionary)["control"])
	return out


## Every LineEdit of the clause, the static quantity field included (removal and reset tear it all
## down; a kind change only swaps the dynamic half).
func _row_fields(row: Dictionary) -> Array[LineEdit]:
	var out: Array[LineEdit] = _dynamic_fields(row)
	var qty: Variant = row.get("qty")
	if qty is LineEdit:
		out.append(qty)
	return out


## Drop a field the keyboard contract tracks — its clause (or kind) is being torn down.
func _forget_field(field: LineEdit) -> void:
	var index := _fields.find(field)
	if index >= 0:
		_fields.remove_at(index)


## A zone row's field text — a key the current kind does not own reads as "".
static func _zone_text(field: Variant) -> String:
	if field is LineEdit:
		return (field as LineEdit).text.strip_edges()
	return ""


## Prefill one zone field, leaving a value the player already typed alone.
static func _prefill_zone_field(field: Variant, value: String) -> void:
	if field is LineEdit and (field as LineEdit).text.strip_edges() == "":
		(field as LineEdit).text = value.strip_edges()
