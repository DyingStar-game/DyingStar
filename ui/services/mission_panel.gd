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
## The create form's zone kinds — exactly the MissionZone discriminator the service validates (a
## `.strict()` union of just two shapes: the whole star system, or one point of interest). The
## `scene` / `area` kinds this form once offered are not in that union: every zone carrying one was
## answered with a validation error. A mission with no zone is global.
const ZONE_ENTRIES: Array = [
	["system", "%%SVC_ENUM_ZONE_SYSTEM"],
	["poi", "%%SVC_ENUM_ZONE_POI"],
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
## Sentence variables: `{name}` (the convention the catalogue now ships) and `{path.to.value}` for a
## param the service documents as a nested object — `{zone.poiId}`, `{source.poiId}` — with the
## legacy `` `name` `` still matched so an older summary keeps rendering mid-transition.
##
## The dot is not decoration. Without it the OBJECTIVE kinds shipped `{zone.poiId}` as literal text:
## the variable was never recognised, so no picker was offered for it and the uuid it names went
## out in the title exactly as written.
const TEMPLATE_PATTERN := "\\{([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)\\}|`([^`]+)`"

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
## repeatable rows, each {panel, index, kind, system, poi, fields, controls}.
var _create_zones: VBoxContainer
var _zone_rows: Array = []
## The caller's own points of interest, fetched the first time a zone row needs to name one: the
## zone points at a POI rather than at coordinates the player would have to type.
var _create_objectives: VBoxContainer
var _create_prereqs: VBoxContainer
## Editable clauses, each {panel, index, kind, badge, qty?, flow, fallback_box, with_title,
## segments, vars, title_field, param_fields, param_raw, schema_required, schema_has_required}.
var _objective_rows: Array = []
var _prereq_rows: Array = []
## The catalogue (categories, objectiveKinds, prerequisiteKinds), fetched once.
var _catalog: Dictionary = {}
## The market catalogue, fetched once and shared by every [GoodTypePicker] on this panel. A clause
## that names a goodType (deliver_material, transport) needs it, and so does the market tab — one
## fetch between them.
var _goods: Array = []
var _goods_loaded: bool = false


## The structured widget a clause param deserves, or null when the param is an ordinary scalar and
## the caller should fall back to a text field.
##
## The service's objective kinds carry their params as a JSON Schema, and the four that place
## something name their place as a nested OBJECT — `{ zone: { kind: "poi", poiId } }`,
## `{ goodType, source: {…}, zone: {…} }`. Until now [method _rebuild_params] skipped every
## non-primitive type and the builder fell through to a raw JSON box, so the one thing a delivery
## contract is made of had to be typed by hand. These four names are what the service documents, so
## they get the widget that makes them pickable.
## [param param_name], not `name`: Node owns a `name`, and a parameter of that name shadows it in
## every warning the editor prints for this file.
func structured_param_widget(param_name: String, width: float = 240.0) -> Control:
	match param_name:
		"zone", "source":
			var place := MissionPlacePicker.new()
			place.setup("%%SVC_POI_MISSION_DEFAULT", width)
			return place
		"passengerId":
			# The passenger is a PLAYER, so the player picker answers it — collapsed, because a
			# clause is a sentence and a full picker would swallow the line.
			var who := ServiceTargetPicker.new()
			who.setup(ServiceTargetPicker.Mask.PLAYERS, true)
			# Shrink, not fill: setup asks to expand, which is what a FORM row wants — and exactly
			# what a sentence does not. This control sits between two labels of a clause, so its
			# minimum width is the whole of its answer.
			who.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			adopt_field(who.search_field())
			return who
		"goodType", "itemId":
			var good := GoodTypePicker.new()
			# setup() is not optional: without it the picker has no field and no list, so it draws
			# as an empty box in the middle of the sentence and its own param_value() reads a
			# `_field` that was never made. The market tab calls it; this branch forgot to.
			good.setup(width)
			# Shrink, for the same reason the passenger picker does: a clause control takes its own
			# width and leaves the rest of the line to the words around it.
			good.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			return good
	return null


## Fill a [GoodTypePicker] with the catalogue, fetching it the first time. Safe to call on any
## widget: a picker created before the catalogue arrives fills itself when the fetch lands.
func _feed_goods(picker: Control) -> void:
	if not (picker is GoodTypePicker):
		return
	if _goods_loaded:
		(picker as GoodTypePicker).fill(_goods)
		return
	_load_goods()


func _load_goods() -> void:
	if _goods_loaded:
		return
	_goods_loaded = true
	var result: Dictionary = await PlayerServices.market_catalog()
	if bool(result.get("ok", false)) and result.get("data") is Array:
		_goods = result["data"]
	else:
		# Not fatal: the picker keeps its text field, and a goodType the catalogue does not carry is
		# still one the service would accept.
		_goods = []
	for row: Dictionary in _objective_rows:
		for widget: Control in row.get("params_widgets", []):
			if widget is GoodTypePicker:
				(widget as GoodTypePicker).fill(_goods)


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

	# One clause up front: the contract is never empty. Built AFTER the places are in hand, because
	# its place picker reads the cache as it is created and would otherwise open on "no point of
	# interest yet" — a sentence about a destination the builder has several of.
	_preload_builder_data()
	_add_objective_row()
	_update_corp_field()


## Fetch what the builder's first clause draws on. Detached on purpose: [method _build] runs while
## the panel is still being assembled, and the panel must appear immediately; [method refresh] lands
## the same data a moment later and refills anything built in between.
func _preload_builder_data() -> void:
	_load_goods()
	MissionPoiCache.ensure_loaded()


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
	# The place pickers and the zone rows draw from one shared list of the caller's POIs; the goods
	# pickers from the market catalogue. Both are fetched once and reused, so a builder that opens
	# six clauses costs one round trip between them rather than twelve.
	await MissionPoiCache.ensure_loaded()
	await _load_goods()
	for row: Dictionary in _objective_rows:
		for entry: Dictionary in row.get("params_widgets", []):
			var control: Variant = entry.get("control")
			if control is MissionPlacePicker:
				(control as MissionPlacePicker).refresh_list()
			elif control is GoodTypePicker:
				(control as GoodTypePicker).fill(_goods)
	for row: Dictionary in _zone_rows:
		var zone_picker: Variant = row.get("poi")
		if zone_picker is MissionPlacePicker:
			(zone_picker as MissionPlacePicker).refresh_list()
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


## My own contracts: the creator's management view, which lists them whatever their visibility or
## issuer. Filtering the catalogue by issuerId never found them — a player mission leaves issuerId
## null and records the creator under createdBy, and a corporation-issued one names the corporation.
func _load_created() -> void:
	var at: int = _page_created.offset
	var result: Dictionary = await PlayerServices.missions_created(
			_enum_value(_created_status), _page_created.limit, at)
	if _land(_page_created, at, result):
		_fill_missions_list(_page_created, _created, result, tr("%%SVC_MSG_NO_CREATED"), true)


func _load_mine() -> void:
	var at: int = _page_mine.offset
	var result: Dictionary = await PlayerServices.my_missions("", _page_mine.limit, at)
	if _land(_page_mine, at, result):
		_apply_mine(_page_mine, result)


## Shared loader for the two mission-dict lists (browse + created).
## [param own] marks every row as the player's contract: true for "My contracts", where the server
## has already done the selecting. The ids are recorded because the CATALOGUE needs them later and
## has no way to ask for them — see [method _mark_mine].
func _fill_missions_list(page: ServicePage, list: ItemList, result: Dictionary,
		empty_text: String, own: bool = false) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for mission: Dictionary in page.rows(result):
		lines.append(ServiceTypes.mission_line(mission))
		metadata.append(mission)
		if own:
			_record_mine(mission)
	if lines.is_empty():
		lines.append(empty_text)
	_fill_list(list, lines, metadata)
	_mark_mine(list)
	_say(tr("%%SVC_FMT_MISSION_COUNT") % page.total, DIM)


## Colour the rows whose contract this player raised, so one line says "yours" without opening it.
##
## Two answers, because the catalogue cannot be relied on to carry the owner: a row is the player's
## when its own fields say so ([method _is_mine] — createdBy or issuerId) OR when it has been seen in
## "My contracts", where the server already filtered by it. Only the second needs no field at all,
## and without it the marker could sit dark over the player's own contract simply because the list
## shape says nothing about who raised it — a marker that never lights reads as a broken one.
##
## A colour rather than a prefix or an icon: the line already carries title, kind, status and reward,
## so the marker must stay out of the text, and tinting a row is how the bank's own list already marks
## money coming in. No artwork, so nothing new to credit.
func _mark_mine(list: ItemList) -> void:
	for i: int in range(list.item_count):
		var meta: Variant = list.get_item_metadata(i)
		if not (meta is Dictionary):
			continue
		var row := meta as Dictionary
		if _is_mine(row) or _mine_ids.has(str(row.get("id", ""))):
			list.set_item_custom_fg_color(i, ServiceStyle.ACCENT)


## Ids of contracts the player raised, learned whenever a list of them has been read.
func _record_mine(mission: Dictionary) -> void:
	_mine_ids[str(mission.get("id", ""))] = true


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
				var entry := _kind_entry("prerequisiteKinds", str((prereq as Dictionary).get("kind", "")))
				var line := _label(ServiceTypes.prerequisite_line(prereq,
						str(entry.get("name", ""))), ServiceStyle.TEXT)
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
	doc.add_child(_contract_actions(mission_id, mission, assignment, contract,
			items if items is Array else []))
	card.add_child(doc)
	return card


## The point of interest an objective names, as {id, name}, or {} when it names none.
##
## `zone` before `source`: a transport carries both a departure and an arrival, and only the arrival
## is "where this clause happens". The keys are the ones the service documents for the objective
## kinds (visit, deliver_material, transport, transport_passenger) — see
## docs/MISSION_PLACE_FRAME.md §1.3 — read rather than guessed from the sentence, which is written
## by the service and may say anything.
##
## The name is resolved here so the clause reads as a place, not as a uuid: [method MissionPoiCache]
## holds the player's own points, which covers every mission the player can build or has taken from
## themselves. A point belonging to someone else's contract is simply not known by name yet — the
## chart fetches it on the click, and the link says what it is rather than what it is called.
static func _objective_poi(objective: Dictionary) -> Dictionary:
	var params: Variant = objective.get("params")
	if not (params is Dictionary):
		return {}
	for field: String in ["zone", "source"]:
		var place: Variant = (params as Dictionary).get(field)
		if not (place is Dictionary):
			continue
		var poi_id := str((place as Dictionary).get("poiId", ""))
		if poi_id != "":
			return {"id": poi_id, "name": _poi_name_of(poi_id)}
	return {}


static func _poi_name_of(poi_id: String) -> String:
	for poi: Dictionary in MissionPoiCache.entries():
		if str(poi.get("id", "")) == poi_id:
			return MissionPoiCache.label_of(poi)
	return ""


## One numbered objective clause: the sentence, where it happens, its progress, the evaluation badge,
## and — on my own contracts — the issuer confirmation button.
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

	# Where this clause happens. A clause you cannot locate is a sentence about somewhere you have
	# never seen, which is the difference between a contract you can take and one you can only hope
	# about. The name alone now: showing it on the chart went with the chart's own points of interest.
	var poi := _objective_poi(objective)
	if not poi.is_empty():
		var where := _row(4)
		var indent := Control.new()
		indent.custom_minimum_size = Vector2(26, 0)
		where.add_child(indent)
		where.add_child(_label(tr("%%SVC_LBL_AT"), DIM))
		var poi_name := str(poi["name"])
		where.add_child(_label(
				poi_name if poi_name != "" else tr("%%SVC_LBL_POI"), ServiceStyle.TEXT))
		box.add_child(where)

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


## The contract's clauses as a picker, for the progress line: a uuid is not an input a player can
## produce, and the clause is on screen above it.
func _objective_picker(objectives: Array) -> OptionButton:
	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(320, 40)
	ServiceStyle.apply_option(picker)
	for objective: Dictionary in objectives:
		var label := "%s. %s" % [str(ServiceTypes.num((objective as Dictionary).get("order", 0)) + 1),
				ServiceTypes.dash((objective as Dictionary).get("title"))]
		picker.add_item(label)
		picker.set_item_metadata(picker.item_count - 1, str((objective as Dictionary).get("id", "")))
	if picker.item_count == 0:
		picker.add_item("%%SVC_MSG_NO_OBJECTIVES")
		picker.set_item_metadata(0, "")
	picker.select(0)
	return picker


## "2/5 units · in progress" — language-neutral numbers, localized objective status.
func _objective_progress(objective: Dictionary) -> String:
	var progress := "%d/%d" % [ServiceTypes.num(objective.get("currentProgress")),
			ServiceTypes.num(objective.get("targetQuantity"))]
	var unit := str(objective.get("unit", "")).strip_edges()
	if unit != "":
		progress += " " + unit
	return progress + " · " + ServiceTypes.objective_status_label(objective.get("status"))


## Confirm only on my own open contract, for an issuer-evaluated objective not yet completed.
##
## "Mine" is the CREATOR, not the issuer: a mission I raised leaves issuerId null and records me
## under createdBy, and filtering on issuerId is exactly what left "My contracts" empty forever.
## A corporation-issued contract names the corporation as its issuer, so issuerId still counts.
func _can_confirm(mission: Dictionary, objective: Dictionary) -> bool:
	if not _is_mine(mission):
		return false
	var status := str(mission.get("status", ""))
	if status != "available" and status != "active":
		return false
	if str(objective.get("status", "")) == "completed":
		return false
	var entry := _kind_entry("objectiveKinds", str(objective.get("type", "")))
	return str(entry.get("evaluation", "")) == "issuer"


## Ids of the player's own contracts, from "My contracts" (see [method _record_mine]).
var _mine_ids: Dictionary = {}


## Whether the caller is the one who raised [param mission] — by creation (a player contract) or by
## issuance (a corporation contract). One question, answered the two ways the service records it.
func _is_mine(mission: Dictionary) -> bool:
	var me := PlayerServices.player_id()
	if me == "":
		return false
	if str(mission.get("createdBy", "")) == me:
		return true
	return str(mission.get("issuerId", "")) == me


func _confirm(mission_id: String, objective_id: String, contract: VBoxContainer) -> void:
	if _report(await PlayerServices.mission_confirm(mission_id, objective_id),
			tr("%%SVC_MSG_OBJECTIVE_CONFIRMED")):
		await _open_contract(contract, mission_id)


## Footer: contextual lifecycle actions + the group share line.
func _contract_actions(mission_id: String, mission: Dictionary, assignment: Dictionary,
		contract: VBoxContainer, objectives: Array) -> Control:
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
		# The objective, chosen by what it SAYS. This used to be a field for the objective's uuid —
		# an id assigned by the service, printed nowhere, knowable only by copying it out of a
		# network answer, and typed into a contract whose clauses are listed on screen a few rows
		# above. The list is right there, so the list is the input.
		var objective_pick := _objective_picker(objectives)
		var quantity := _number_field(tr("%%SVC_PH_QUANTITY"), 100.0)
		if objective_pick != null:
			progress.add_child(objective_pick)
		progress.add_child(quantity)
		_action_button(progress, tr("%%SVC_ACT_REPORT_PROGRESS"),
				func() -> void: _progress(mission_id, contract, objective_pick, quantity))
		actions.add_child(progress)

	# The share line is the CREATOR's business: handing a contract to a group is a decision about
	# who may take it, and that is not the taker's to make. It also names the group rather than
	# printing the opaque id the service stores.
	if _is_mine(mission):
		actions.add_child(_share_line(mission, mission_id, contract))
	return actions


## The group-sharing line: the group's NAME (or nothing shared yet), over its action.
##
## The name is resolved AFTER the line is built: fetching it would make this a coroutine, and the
## whole contract card is laid out in one synchronous pass. The id stands in until the service
## answers, then the line corrects itself.
func _share_line(mission: Dictionary, mission_id: String, contract: VBoxContainer) -> Control:
	var group_id := str(mission.get("groupId", "")).strip_edges()
	var share := _row()
	if group_id == "":
		share.add_child(_label(tr("%%SVC_LBL_SHARED_GROUP") + " : —", DIM))
		_action_button(share, tr("%%SVC_ACT_SHARE"),
				func() -> void: _share(mission_id, contract))
		return share
	var caption := _label(tr("%%SVC_LBL_SHARED_GROUP") + " : " + group_id, DIM)
	share.add_child(caption)
	_action_button(share, tr("%%SVC_ACT_UNSHARE"),
			func() -> void: _unshare(mission_id, contract))
	_resolve_group_name(group_id, caption)
	return share


## Replace [param caption]'s text with the group's name once the service has answered. The id it
## showed is kept as the fallback, so a lookup that fails leaves the line still saying something.
func _resolve_group_name(group_id: String, caption: Label) -> void:
	var result: Dictionary = await PlayerServices.group_get(group_id)
	if not is_instance_valid(caption):
		return  # the card was closed while the lookup was in flight
	if not bool(result.get("ok", false)) or not (result.get("data") is Dictionary):
		return
	# Not `name`: that is Node's own, and shadowing it is a warning this file has enough of.
	var group_label := str((result.get("data") as Dictionary).get("name", "")).strip_edges()
	if group_label != "":
		caption.text = tr("%%SVC_LBL_SHARED_GROUP") + " : " + group_label


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


func _progress(mission_id: String, contract: VBoxContainer, objective_pick: OptionButton,
		quantity_field: LineEdit) -> void:
	release_fields()
	var objective_id := ""
	if objective_pick != null and objective_pick.selected >= 0:
		objective_id = str(objective_pick.get_item_metadata(objective_pick.selected))
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
	row["controls"] = []
	_create_zones.add_child(panel)
	_zone_rows.append(row)
	_renumber_zones()
	_rebuild_zone_fields(row)
	kind.item_selected.connect(func(_i: int) -> void: _rebuild_zone_fields(row))
	return panel


func _remove_zone_row(row: Dictionary) -> void:
	_zone_rows.erase(row)
	for field: Variant in row.get("fields", []):
		# Only the free-text inputs were registered for the keyboard contract; the place picker is
		# a widget and has nothing to give back.
		if field is LineEdit:
			_forget_field(field as LineEdit)
	for control: Variant in row.get("controls", []):
		if control is Node and is_instance_valid(control):
			(control as Node).queue_free()
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
## chosen kind owns: `system` names a star system, `poi` names one of the caller's points of
## interest (optionally widened by a radius in metres).
##
## Nothing here is a coordinate the player types — the service takes a POI and asks Inventory where
## it is. A zone that names a POI and carries no radius matches that POI's whole scene subtree
## (`tarsis_1` matches `tarsis_1/new-paris`, never `tarsis_10`); a radius narrows it to the ground
## around the point, which is the one match that depends on coordinates agreeing between services.
func _rebuild_zone_fields(row: Dictionary) -> void:
	for field: Variant in row.get("fields", []):
		if field is LineEdit:
			_forget_field(field as LineEdit)
	var flow: FlowContainer = row["flow"]
	_clear(flow)
	for key: String in ["system", "poi"]:
		row[key] = null
	row["fields"] = []
	# The place picker of the previous kind: not a LineEdit, so the loop above did not catch it.
	# Freed here rather than leaked, since _clear(flow) only detaches children.
	for control: Variant in row.get("controls", []):
		if control is Node and is_instance_valid(control):
			(control as Node).queue_free()
	row["controls"] = []
	# Every kind carries only its own fields: the service's union is strict, so a field this kind
	# does not own is not ignored, it is a validation error.
	if _enum_value(row["kind"] as OptionButton) == "system":
		_zone_edit(row, flow, "system", tr("%%SVC_PH_ZONE_SYSTEM"), 150.0, false)
		return
	_zone_poi_picker(row, flow)
	# NO radius field here any more. The service refuses a zone radius that does not fit the POI's
	# own (POI_RADIUS_EXCEEDED), and a POI placed from the chart is a POINT with no radius at all —
	# so a typed radius was a guaranteed 400. The radius now belongs to the POI itself, edited where
	# the POI is chosen (see MissionPlacePicker): one place, one rule.


## The POI a `poi` zone points at, and the ways to put one there.
##
## What to call the points of interest this panel creates, so two on one body are not named alike.
##
## Asked by a place picker at the moment it creates one rather than kept in sync: the title is free
## text the player is still typing while the picker sits open, so a single question at the one
## instant it matters beats a signal on every keystroke. Empty while the title is blank, which the
## picker takes as "no prefix".
func mission_name_for_poi() -> String:
	return _create_title.text.strip_edges()


## The same [MissionPlacePicker] an objective's `zone` param uses, so an availability zone and a
## delivery target are chosen the same way: a POI that already exists, one placed « Ici » where the
## builder stands, or one placed « Carte » where the click lands. Before this, a zone could only
## name a POI that existed somewhere else — so making a delivery zone meant leaving the builder,
## creating a POI in another tab, and coming back to find it in a list.
func _zone_poi_picker(row: Dictionary, flow: FlowContainer) -> void:
	var picker := MissionPlacePicker.new()
	picker.setup("%%SVC_POI_MISSION_ZONE", 220.0)
	_relay_placement_from(picker)
	row["poi"] = picker
	flow.add_child(picker)
	# The zone row's own teardown only walks LineEdits; this one is not one, so it is queued for the
	# panel to free with the row rather than left dangling in a cleared flow.
	(row["controls"] as Array).append(picker)


## The id the [param picker] names, or "" when it carries no POI (nothing to point a zone at).
static func _picked_poi_id(picker: Variant) -> String:
	if picker is MissionPlacePicker:
		return (picker as MissionPlacePicker).picked_id()
	return ""


## One zone field: registered with the keyboard contract, named on the row, and listed in the
## row's field registry so a kind change or a removal can drop it again.
func _zone_edit(row: Dictionary, flow: FlowContainer, key: String, placeholder: String,
		width: float, integer: bool) -> void:
	var field: LineEdit = _number_field(placeholder, width) if integer \
			else _field(placeholder, width)
	row[key] = field
	(row["fields"] as Array).append(field)
	flow.add_child(field)


## Use the player's own presence location (`/api/me` → `presence.location` =
## {system, scene, position}) on the first zone row.
##
## Which kind that row ends up on depends on what a place CAN be. A `system` zone names a star
## system, so it can be filled straight from the presence — but only where there IS a system: off-
## world there is none, and the place that actually matters is a point of interest. Since the zone
## row now carries the same place picker as an objective, that case is no longer a dead end — it
## becomes a POI placed right here, and the off-world message only stays for a player who is nowhere
## at all.
func _use_my_position() -> void:
	var loc: Dictionary = await _my_presence()
	if loc.is_empty():
		return
	var system := str(loc.get("system", "")).strip_edges()
	if _zone_rows.is_empty():
		_new_zone_row("system" if system != "" else "poi")
	var row: Dictionary = _zone_rows[0]
	var kind: Variant = row.get("kind")
	var wanted := "system" if system != "" else "poi"
	if kind is OptionButton and _enum_value(kind as OptionButton) != wanted:
		(kind as OptionButton).select(_zone_kind_index(wanted))
		_rebuild_zone_fields(row)
	if system != "":
		_prefill_zone_field(row.get("system"), system)
		var where := ServiceTypes.location_text(loc)
		_say(where if where != "" else system, GOOD)
		return
	var picker: Variant = row.get("poi")
	if picker is MissionPlacePicker:
		(picker as MissionPlacePicker).place_here()
	else:
		_say(tr("%%SVC_MSG_ZONE_OFFWORLD"), DIM)


## The caller's presence location, or {} when there is none to take a place from.
func _my_presence() -> Dictionary:
	var result: Dictionary = await PlayerServices.profile_get()
	if not bool(result.get("ok", false)):
		_say(HttpClient.describe_error(result), WARN)
		return {}
	var data: Variant = result.get("data")
	var presence: Variant = (data as Dictionary).get("presence") if data is Dictionary else null
	var location: Variant = (presence as Dictionary).get("location") if presence is Dictionary \
			else null
	if not (location is Dictionary):
		_say(tr("%%SVC_MSG_NO_POSITION"), WARN)
		return {}
	return location


## The row of [constant ZONE_ENTRIES] a zone kind sits at, so a row can be switched without
## searching the list by hand.
static func _zone_kind_index(kind_value: String) -> int:
	for i: int in range(ZONE_ENTRIES.size()):
		if str((ZONE_ENTRIES[i] as Array)[0]) == kind_value:
			return i
	return 0


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
	row["params_widgets"] = []
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
	row["params_widgets"] = []
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
			# `var_name`, not `name`: Node owns a `name`, and shadowing it makes every warning in
			# this file harder to read than the code it is about.
			var var_name := str(segment["var"])
			# `{zone.poiId}` is a path INTO a param, not a param of its own: the widget is the
			# object `zone`, and one object takes one control however many times a summary names
			# it — the transport clause names `source` and `zone`, each once, but a wording that
			# named a place twice would otherwise put two pickers on one line.
			var root := var_name.split(".")[0]
			if _has_var(row, root):
				continue
			var parts := _var_control(root, entry, objective)
			flow.add_child(parts[0])
			(row["vars"] as Array).append({"name": root, "control": parts[0], "meta": parts[1]})
		else:
			var literal := str(segment["text"]).strip_edges()
			if literal == "":
				continue
			var note := i == last and _is_parenthetical(literal)
			if note and drop_note:
				continue
			flow.add_child(_label(literal, DIM if note else ServiceStyle.TEXT))


## Whether the clause already holds a control for [param root] — a path such as `{zone.poiId}` is
## answered by the object it points into, and an object takes one control.
static func _has_var(row: Dictionary, root: String) -> bool:
	for variable: Variant in row["vars"]:
		if variable is Dictionary and str((variable as Dictionary).get("name", "")) == root:
			return true
	return false


## One inline control for a sentence variable, and where its value must land: the kind's params
## schema first, then the objective's own fields, then params in the open. A prerequisite is only
## {kind, params} — its variables never reach an objective field.
func _var_control(var_name: String, entry: Dictionary, objective: bool) -> Array:
	var properties := {}
	var schema: Variant = entry.get("params")
	if schema is Dictionary:
		var declared: Variant = (schema as Dictionary).get("properties")
		if declared is Dictionary:
			properties = declared
	# A place, a passenger, a good — the params the service documents as something other than a
	# scalar. Checked BEFORE the primitive types below, because these are exactly the ones that used
	# to fall through to a typed field (or, being objects, to the raw JSON box).
	var widget := structured_param_widget(var_name, 240.0)
	if widget != null:
		if widget is GoodTypePicker:
			_feed_goods(widget)
		if widget.has_signal("placement_requested"):
			_relay_placement_from(widget)
		return [widget, {"name": var_name, "target": "param_object"}]
	if properties.has(var_name):
		var property: Dictionary = properties[var_name] if properties[var_name] is Dictionary else {}
		var hint := str(property.get("title", property.get("description", var_name)))
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
			return [option, {"name": var_name, "target": "param",
					"ptype": str(property.get("type", "string"))}]
		var ptype: String = str(property.get("type", "string"))
		if ptype == "boolean":
			var check := CheckBox.new()
			check.button_pressed = bool(property.get("default", false))
			return [check, {"name": var_name, "target": "param", "ptype": "boolean"}]
		var field: LineEdit = _number_field(hint, 110.0) if ptype in ["integer", "number"] \
				else _field(hint, 150.0)
		var default_scalar: Variant = property.get("default")
		if default_scalar != null:
			field.text = str(default_scalar)
		return [field, {"name": var_name, "target": "param", "ptype": ptype}]
	if not objective:
		var free := _field(var_name, 140.0)
		return [free, {"name": var_name, "target": "param", "ptype": "string"}]
	match var_name:
		"targetQuantity":
			return [_number_field(var_name, 90.0), {"name": var_name, "target": "targetQuantity",
					"ptype": "integer"}]
		"locationTo", "locationFrom":
			return [_field(tr("%%SVC_PH_LOCATION"), 150.0), {"name": var_name, "target": name,
					"ptype": "location"}]
		"unit":
			return [_field(name, 90.0), {"name": var_name, "target": "unit", "ptype": "string"}]
	return [_field(var_name, 140.0), {"name": var_name, "target": "param", "ptype": "string"}]


## Catalogue-less kinds: the params schema still rendered as stacked fields under the summary
## (fields were already forgotten by the caller; this appends into the cleared fallback box).
func _rebuild_params(row: Dictionary, entry: Dictionary) -> void:
	var box := row["fallback_box"] as VBoxContainer
	var schema: Variant = entry.get("params")
	var properties: Variant = (schema as Dictionary).get("properties") if schema is Dictionary else null
	if not (properties is Dictionary) or (properties as Dictionary).is_empty():
		return
	var rendered: bool = false
	var skipped: int = 0
	for key: Variant in properties:
		var property: Variant = properties[key]
		if not (property is Dictionary):
			continue
		var param_name := str(key)
		var hint: String = str((property as Dictionary).get("title",
				(property as Dictionary).get("description", param_name)))
		# A place, a passenger, a good: the params the service documents as something other than a
		# scalar. These get a widget, and a widget that picks — never a field to type an id into.
		var widget := structured_param_widget(param_name, 260.0)
		if widget != null:
			var labelled := _titled(hint, widget)
			box.add_child(labelled)
			(row["params_widgets"] as Array).append({"name": param_name, "control": widget})
			if widget is GoodTypePicker:
				_feed_goods(widget)
			if widget.has_signal("placement_requested"):
				_relay_placement_from(widget)
			rendered = true
			continue
		var ptype: String = str((property as Dictionary).get("type", "string"))
		if not (ptype in ["string", "integer", "number", "boolean"]):
			# An object or an array we have no widget for: counted, so the raw box below still
			# appears rather than the clause silently losing the field.
			skipped += 1
			continue
		var field := _field(hint, 160.0)
		box.add_child(field)
		(row["param_fields"] as Array).append([param_name, ptype, field])
		rendered = true
	if skipped > 0 or not rendered:
		# Either nothing was renderable, or something was but is not fully understood: both leave a
		# way to send the rest by hand. The widgets above still go; this only adds to them.
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
		var captured := found.get_string(1)
		if captured == "":
			captured = found.get_string(2)
		out.append({"var": captured})
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
			var var_name := str(segment["var"])
			if values.has(var_name):
				out += str(values[var_name])
				continue
			# A path into an object: `{zone.poiId}` reads what the OBJECT carries, and what it
			# carries is its picker's LABEL — "Depot — tarsis_3" — where the uuid under it would be
			# unreadable in a sentence the player is about to restate out loud.
			var root := var_name.split(".")[0]
			out += str(values.get(root, root))
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
		await _reset_create()
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
## One POI zone, and nothing else. The shape is the whole contract: a service union that is strict
## (`MissionZone`), so an extra key is a validation error rather than an ignored field — which is
## exactly why the radius is NOT here. It is a property of the POI, edited where the POI is chosen;
## a zone radius could only ever ask for more than the POI allows (POI_RADIUS_EXCEEDED).
static func _poi_zone(poi_id: String) -> Dictionary:
	return {"kind": "poi", "poiId": poi_id}


func _collect_zone(row: Dictionary) -> Variant:
	if _enum_value(row["kind"] as OptionButton) == "system":
		var system := _zone_text(row.get("system"))
		if system == "":
			_say(tr("%%SVC_MSG_ZONE_SYSTEM_REQUIRED"), WARN)
			return null
		return {"kind": "system", "system": system}
	var poi_id := _picked_poi_id(row.get("poi"))
	if poi_id == "":
		_say(tr("%%SVC_MSG_ZONE_NEED_POI"), WARN)
		return null
	# The radius is the one number here, and it is optional: without it the zone is the POI's whole
	# scene subtree, which needs no coordinates to agree between the services.
	# No radiusM: it lives on the POI now (MissionPlacePicker), and the service takes it from there.
	# Sending one from the zone could only ever be refused — POI_RADIUS_EXCEEDED is exactly a zone
	# radius asking for more than the POI allows.
	return _poi_zone(poi_id)


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
		var var_name := str(variable["name"])
		var control: Control = variable["control"]
		var target := str((variable["meta"] as Dictionary).get("target", "param"))
		var ptype := str((variable["meta"] as Dictionary).get("ptype", "string"))
		# Every objective word must be filled; a prerequisite only owes what its schema requires
		# (and everything when the schema is silent).
		var required: bool = objective or not has_required or var_name in required_names
		if control is CheckBox:
			var pressed := (control as CheckBox).button_pressed
			values[var_name] = "true" if pressed else "false"
			if target == "param":
				params[var_name] = pressed
			continue
		if target == "param_object":
			# A structured widget: a place picker ({kind:"poi",poiId}), a player picker (an id), a
			# good picker (a goodType). They answer `param_value`, so the collector does not have to
			# know which is which — and the label it gives is what the title prints, so a clause
			# reads "deliver to Depot — tarsis_3", never a uuid.
			var value: Variant = null
			if control.has_method("param_value"):
				value = control.call("param_value")
			if value == null:
				values[var_name] = var_name
				if required:
					_say(tr("%%SVC_MSG_CLAUSE_NEEDS_VALUE") % var_name, WARN)
					return null
				continue
			values[var_name] = str(control.call("param_label")) if control.has_method("param_label") \
					else str(value)
			params[var_name] = value
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
		values[var_name] = raw if is_set else name
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
				params[var_name] = typed
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


## The params of one stacked row: the structured widgets (a place, a passenger, a good), then every
## filled primitive field, then the raw JSON fallback for whatever the schema held that has no
## widget. Null means the row cannot be sent — either nothing was filled, or a REQUIRED structured
## widget is empty, which is said out loud here rather than left to fail at validate time with an
## error that does not name the field.
func _collect_params(row: Dictionary) -> Variant:
	var params := {}
	var missing: PackedStringArray = []
	var required_names: Array = row.get("schema_required", [])
	for entry: Dictionary in row.get("params_widgets", []):
		var param_name := str(entry.get("name", ""))
		var control: Variant = entry.get("control")
		var value: Variant = null
		if control is Control and (control as Control).has_method("param_value"):
			value = (control as Control).call("param_value")
		if value == null:
			if param_name in required_names:
				missing.append(param_name)
			continue
		params[param_name] = value
	if not missing.is_empty():
		_say(tr("%%SVC_MSG_CLAUSE_NEEDS_VALUE") % ", ".join(missing), WARN)
		return null
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
	# Written as `if` rather than `x if test else y`: the branches disagree on type (an int against
	# null, a float against null), and a ternary has to pick one. Written out, each return is
	# simply its own type.
	match ptype:
		"integer":
			if raw.is_valid_int():
				return int(raw)
			return null
		"number":
			if raw.is_valid_float():
				return float(raw)
			return null
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
	# The builder is a fresh contract: the places it had open are closed with it. Kept in the panel
	# rather than the widget so the very next clause draws from a list that does not still offer
	# the last mission's delivery points.
	#
	# AWAITED BEFORE the clause is built, not after: [method _add_objective_row] builds its place
	# picker, which reads the cache the moment it appears. Loading afterwards left the fresh clause
	# showing "no point of interest yet" over a list that already held the player's places — and
	# nothing on screen would say so, because the list only fills when someone opens the panel again.
	MissionPoiCache.clear()
	await MissionPoiCache.ensure_loaded()
	_add_objective_row()


## The chart named a place for one of this panel's place pickers. It cannot tell which asked, so
## every one gets it and each decides whether it is waiting: a picker that asked for a place on the
## chart takes the answer, whatever the list had selected for it (the list selects its first row by
## itself, so a chosen id is no proof of a decision), and a picker that never asked is left alone,
## so a stray answer never overwrites a decision already taken.
##
## Answers whether one of them took it, so the console can hand the chart back to the app that asked
## rather than to whichever was built first.
func set_placed(place: Dictionary) -> bool:
	if place.is_empty():
		return false
	var pickers: Array = _place_pickers()
	# A picker that asked for the place is the ONLY one that takes it: the others would create a
	# POI each from the same marker, and the mission would point at several places at once.
	var waiting := false
	for picker: MissionPlacePicker in pickers:
		if picker.is_awaiting_chart():
			waiting = true
			break
	var taken := false
	for picker: MissionPlacePicker in pickers:
		if waiting and not picker.is_awaiting_chart():
			continue
		taken = _deliver_place(picker, place) or taken
	return taken


## Relay a picker's request for the chart, and make sure only ONE picker of this panel is waiting
## for the answer.
##
## The purge is not tidiness: a player who asks for a place, leaves the chart without a marker and
## asks again from another clause would otherwise have TWO pickers waiting, and the answer would
## land in both — two places created from one marker.
func _relay_placement(radius_m: float, source: MissionPlacePicker) -> void:
	for picker: MissionPlacePicker in _place_pickers():
		if picker != source:
			picker.cancel_awaiting()
	placement_requested.emit(radius_m)


## Wire a widget's request for the chart to this panel's own signal. A place picker is wired with
## itself, so the panel can tell the other pickers that they are no longer the one waiting.
func _relay_placement_from(widget: Control) -> void:
	if widget is MissionPlacePicker:
		(widget as MissionPlacePicker).placement_requested.connect(
				_relay_placement.bind(widget as MissionPlacePicker))
		return
	widget.connect("placement_requested",
			func(radius: float) -> void: placement_requested.emit(radius))


## Every place picker this panel holds: the ones in the clauses' sentences (an objective's `zone`
## and `source`, inline in the sentence), the ones in their stacked forms, and the availability
## zones' own picker.
##
## Both containers matter: a clause is either a sentence with its control inline, or a stacked form
## with the same control below it — which of the two a clause gets depends on its kind's summary,
## not on anything the player does. A picker the player pressed « Carte » on is therefore in one of
## the two, and the one that answers must be the one that asked.
func _place_pickers() -> Array:
	var pickers: Array = []
	for rows: Array in [_objective_rows, _prereq_rows]:
		for row: Dictionary in rows:
			for entry: Dictionary in row.get("vars", []):
				var inline: Variant = entry.get("control")
				if inline is MissionPlacePicker:
					pickers.append(inline)
			for entry: Dictionary in row.get("params_widgets", []):
				var control: Variant = entry.get("control")
				if control is MissionPlacePicker:
					pickers.append(control)
	for row: Dictionary in _zone_rows:
		var zone: Variant = row.get("poi")
		if zone is MissionPlacePicker:
			pickers.append(zone)
	return pickers


## The segment holding the form that asks the chart for a place: the builder's, which is the
## fourth one (browse, my missions, my creations, create). The player is taken back to the form they
## were filling in, not to the list of missions that opens the app.
func placement_segment() -> int:
	return 3


## Answers whether the picker takes the place, for the same reason [method set_placed] does.
##
## The rule is static and pure so a test can pin it without a picker that would create a POI: a
## picker that is WAITING takes the place, and one that is not takes it only while it holds no
## choice of its own.
static func _picker_wants_place(picker: MissionPlacePicker) -> bool:
	if picker.is_awaiting_chart():
		return true
	return picker.picked_id() == ""


## Answers whether the picker took the place, for the same reason [method set_placed] does.
func _deliver_place(control: Variant, place: Dictionary) -> bool:
	if not (control is MissionPlacePicker):
		return false
	var picker := control as MissionPlacePicker
	if not _picker_wants_place(picker):
		return false
	picker.accept_place(place)
	return true


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
## validate time). The label is the catalogue's own `name` — localized by the service, since
## PlayerServices sends Accept-Language with every call. No catalogue (or a category nothing
## matches) falls back to the full list, whose labels are the raw kind names.
func _kind_options(catalog_key: String, category: String) -> Array:
	var kinds: Variant = _catalog.get(catalog_key)
	if kinds is Array and not (kinds as Array).is_empty():
		var all: Array = []
		var allowed: Array = []
		for entry: Variant in kinds:
			if not (entry is Dictionary):
				continue
			var kind := str((entry as Dictionary).get("kind", ""))
			var pair := [kind, _kind_label(entry as Dictionary, kind)]
			all.append(pair)
			if _kind_fits_category(entry, category):
				allowed.append(pair)
		return allowed if not allowed.is_empty() else all
	if catalog_key == "prerequisiteKinds":
		var out: Array = []
		for kind: String in PREREQ_FALLBACK:
			out.append([kind, kind])
		return out
	return OBJECTIVE_TYPE_ENTRIES


## A kind's dropdown caption: the catalogue's localized `name` when it carries one, the raw kind
## otherwise (an old service, or a kind the catalogue never heard of).
static func _kind_label(entry: Dictionary, kind: String) -> String:
	var label: String = str(entry.get("name", "")).strip_edges()
	return label if label != "" else kind


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
