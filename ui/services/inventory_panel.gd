extends ServicePanel

## App « Inventaire » : the player's stacks and owned instances, a stack's detail (available /
## reserved), and a corporation's inventory. Covers /api/me/inventory* and
## /api/corporations/{id}/inventory*.
##
## Laid out as the A.R.E.S. OS mock-up (2026-11): the stacks and the instances in a column, the stack
## picked beside them with what can be done with it; the corporation tab says so plainly when the
## player belongs to none.

## The list column's width (px): the mock-up's 480, scaled.
const LIST_WIDTH: float = 600.0

## One window carries both lists of a scope: the stacks and the instances are fetched together, so
## the footer under the stacks drives them both.
var _stacks: RowList
var _instances: RowList
var _page_stacks: ServicePage
var _stacks_card: Card
var _instances_head: Card
var _detail: VBoxContainer
## "Put on sale": shown with a picked stack, it takes the player to the market's orders.
var _sell: Button
var _corp_picker: ServiceTargetPicker
var _corp_stacks: RowList
var _corp_instances: RowList
var _corp_stacks_card: Card
var _corp_instances_card: Card
var _page_corp_stacks: ServicePage
## The corporation tab's two faces: its inventory, or "you belong to no corporation".
var _corp_content: Control
var _corp_empty: Card


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_INVENTORY"), ServiceAppIcon.Kind.INVENTORY)
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_INVENTORY"), tr("%%SVC_TAB_CORP_INVENTORY")]))
	_frameless(pages[0])
	_frameless(pages[1])
	_build_mine(pages[0])
	_build_corp(pages[1])
	add_chrome(_status_line())


func _build_mine(page: VBoxContainer) -> void:
	var columns := _columns()
	page.add_child(columns)

	# The stacks, then the instances, in one column.
	_stacks_card = _panel(tr("%%SVC_LBL_STACKS"))
	columns.add_child(_fixed(_stacks_card, LIST_WIDTH))
	_page_stacks = ServicePage.new()
	_page_stacks.rows_key = "stacks"
	_page_stacks.total_keys = PackedStringArray(["total", "instancesTotal"])
	_page_stacks.load_requested.connect(_load_inventory)
	var lists := VBoxContainer.new()
	lists.add_theme_constant_override("separation", 18)
	_stacks = RowList.new()
	_stacks.row_selected.connect(_load_stack_detail)
	lists.add_child(_stacks)
	var stacks_empty := _empty_state(tr("%%SVC_MSG_NO_STACKS"), tr("%%SVC_EMPTY_STACKS_TEXT"))
	stacks_empty.custom_minimum_size.y = 220.0
	stacks_empty.visible = false
	lists.add_child(stacks_empty)
	_stacks.set_meta(&"empty", stacks_empty)
	# The instances under the stacks, under a head of their own (no second frame).
	_instances_head = _panel(tr("%%SVC_LBL_INSTANCES"), "", 0.0, false)
	_instances_head.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	lists.add_child(_instances_head)
	_instances = RowList.new()
	_instances_head.body.add_child(_instances)
	var instances_empty := _empty_state("", tr("%%SVC_EMPTY_INSTANCES_TEXT"))
	instances_empty.custom_minimum_size.y = 110.0
	instances_empty.visible = false
	_instances_head.body.add_child(instances_empty)
	_instances.set_meta(&"empty", instances_empty)
	_stacks_card.body.add_child(_scroll(lists))
	_stacks_card.body.add_child(_pager(_page_stacks))

	# The stack picked: what it is, how much, and what to do with it.
	var detail_card := _panel()
	columns.add_child(detail_card)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 20)
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_card.body.add_child(_detail)
	_detail.add_child(_empty_state("", tr("%%SVC_MSG_SELECT_STACK")))
	var actions := _actions_bar()
	actions.add_child(_spacer())
	# Economy › Market › Orders, where a sell order is placed.
	_sell = _primary_button(actions, tr("%%SVC_ACT_PUT_ON_SALE"),
			func() -> void: open_app_requested.emit("economy", 1, 1))
	_sell.visible = false
	detail_card.body.add_child(actions)


func _build_corp(page: VBoxContainer) -> void:
	_corp_empty = _panel()
	_corp_empty.body.add_child(_empty_state(tr("%%SVC_MSG_NO_CORPS"), tr("%%SVC_EMPTY_CORP_INVENTORY_TEXT"),
			tr("%%SVC_ACT_JOIN_OR_CREATE_CORP"), func() -> void: open_app_requested.emit("social", 2, -1)))
	_corp_empty.visible = false
	page.add_child(_corp_empty)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 24)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(content)
	_corp_content = content
	# The pick that drives everything below it.
	var pick_card := _panel(tr("%%SVC_LBL_CORPORATION"), "", 20.0, false)
	pick_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var corp_row := _row()
	_corp_picker = ServiceTargetPicker.new()
	_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	_corp_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adopt_field(_corp_picker.search_field())
	corp_row.add_child(_corp_picker)
	_primary_button(corp_row, tr("%%SVC_ACT_LOAD"), func() -> void: _load_corp())
	pick_card.body.add_child(corp_row)
	content.add_child(pick_card)

	var columns := _columns()
	content.add_child(columns)
	_page_corp_stacks = ServicePage.new()
	_page_corp_stacks.rows_key = "stacks"
	_page_corp_stacks.total_keys = PackedStringArray(["total", "instancesTotal"])
	_page_corp_stacks.load_requested.connect(_load_corp_inventory)
	_corp_stacks_card = _panel(tr("%%SVC_LBL_STACKS"))
	columns.add_child(_corp_stacks_card)
	_corp_stacks = _list_in(_corp_stacks_card, tr("%%SVC_MSG_NO_STACKS"))
	_corp_stacks_card.body.add_child(_pager(_page_corp_stacks))
	_corp_instances_card = _panel(tr("%%SVC_LBL_INSTANCES"))
	columns.add_child(_corp_instances_card)
	_corp_instances = _list_in(_corp_instances_card, tr("%%SVC_MSG_NO_INSTANCES"))


## A scrolling [RowList] in [param card], with an empty state titled [param empty_title].
func _list_in(card: Card, empty_title: String) -> RowList:
	var list := RowList.new()
	var scroll := _scroll(list)
	card.body.add_child(scroll)
	var empty := _empty_state(empty_title, "")
	empty.visible = false
	card.body.add_child(empty)
	list.set_meta(&"empty", empty)
	list.set_meta(&"scroll", scroll)
	return list


func refresh() -> void:
	if not _begin_refresh():
		return
	await _load_inventory()
	await _load_membership()
	_end_refresh()


func _load_inventory() -> void:
	var at: int = _page_stacks.offset
	var result: Dictionary = await PlayerServices.inventory_me(_page_stacks.limit, at)
	if _land(_page_stacks, at, result):
		_apply_inventory(_page_stacks, result, _stacks, _instances)
		var ok: bool = bool(result.get("ok", false))
		# The stacks are always the whole list (the service pages only the instances): count them.
		_stacks_card.set_count(str(ServicePage.items_of(result, "stacks").size()) if ok else "")


## Whether the player belongs to a corporation: the corporation tab shows its inventory, or says so.
func _load_membership() -> void:
	var profile: Dictionary = await PlayerServices.profile_get()
	if not bool(profile.get("ok", false)) or not (profile.get("data") is Dictionary):
		return  # unknown: the tab stays as it is
	var corporations: Variant = (profile.get("data") as Dictionary).get("corporations")
	var member: bool = corporations is Array and not (corporations as Array).is_empty()
	_corp_content.visible = member
	_corp_empty.visible = not member


func _load_stack_detail(meta: Variant) -> void:
	if not (meta is Dictionary):
		return
	var good_type: String = str((meta as Dictionary).get("goodType", ""))
	if good_type == "":
		return
	var result: Dictionary = await PlayerServices.inventory_me_stack(good_type)
	_clear(_detail)
	if not bool(result.get("ok", false)):
		_detail.add_child(_label(HttpClient.describe_error(result), WARN))
		return
	if not (result.get("data") is Dictionary):
		_detail.add_child(_label(tr("%%SVC_MSG_UNEXPECTED"), WARN))
		return
	var view: Dictionary = result.get("data")
	var head := _row(18)
	head.add_child(_thumb(_code_of(good_type), 72.0))
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 6)
	titles.alignment = BoxContainer.ALIGNMENT_CENTER
	# Its share of the row's width: a wrapping title given none wraps at every letter.
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(_tag(tr("%%SVC_ENUM_GOOD_STACK")))
	titles.add_child(_title_lg(ServiceTypes.good_label(good_type), 28))
	head.add_child(titles)
	_detail.add_child(head)
	var cards := GridContainer.new()
	cards.columns = 2
	cards.add_theme_constant_override("h_separation", 14)
	cards.add_theme_constant_override("v_separation", 14)
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_child(_stat_card(tr("%%SVC_LBL_QUANTITY"),
			ServiceTypes.good_quantity(good_type, view.get("quantity")), "", ServiceStyle.TEXT, 28))
	cards.add_child(_stat_card(tr("%%SVC_LBL_IDENTIFIER"), good_type, "", ServiceStyle.TEXT, 18))
	_detail.add_child(cards)
	_detail.add_child(_hint(tr("%%SVC_FMT_STACK_AVAILABLE") % [
			ServiceTypes.good_quantity(good_type, view.get("available")),
			ServiceTypes.good_quantity(good_type, view.get("held")),
			ServiceTypes.good_quantity(good_type, view.get("carried"))]))
	_sell.visible = true


func _load_corp() -> void:
	release_fields()
	var corporation_id: String = _corp_picker.picked_id()
	if corporation_id == "":
		_say(tr("%%SVC_MSG_NEED_CORP_ID"), WARN)
		return
	# Another corporation is another inventory: back to its first window, which loads it.
	_page_corp_stacks.reset()


func _load_corp_inventory() -> void:
	var corporation_id: String = _corp_picker.picked_id()
	if corporation_id == "":
		return
	var at: int = _page_corp_stacks.offset
	var result: Dictionary = await PlayerServices.corporation_inventory(corporation_id,
			_page_corp_stacks.limit, at)
	if _land(_page_corp_stacks, at, result):
		_apply_inventory(_page_corp_stacks, result, _corp_stacks, _corp_instances)
		var ok: bool = bool(result.get("ok", false))
		_corp_stacks_card.set_count(str(ServicePage.items_of(result, "stacks").size()) if ok else "")
		_corp_instances_card.set_count(
				str(ServicePage.total_of(result, PackedStringArray(["instancesTotal"]))) if ok else "")


func _apply_inventory(page: ServicePage, result: Dictionary, stacks: RowList,
		instances: RowList) -> void:
	if not bool(result.get("ok", false)):
		_say(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), WARN)
		_set_rows(stacks, [])
		_set_rows(instances, [])
		return
	var stack_rows: Array = []
	for stack: Dictionary in page.rows(result):
		var good: String = str(stack.get("goodType", ""))
		stack_rows.append({"thumb": _code_of(good), "name": ServiceTypes.good_label(good), "sub": good,
				"value": "×" + ServiceTypes.good_quantity(good, stack.get("quantity")), "mono": true,
				"meta": stack})
	_set_rows(stacks, stack_rows)
	var instance_rows: Array = []
	for instance: Dictionary in ServicePage.items_of(result, "instances"):
		var good: String = str(instance.get("goodType", ""))
		instance_rows.append({"thumb": _code_of(good), "name": ServiceTypes.good_label(good),
				"sub": ServiceTypes.instance_status_label(instance.get("status")), "meta": instance})
	_set_rows(instances, instance_rows)
	if instances == _instances:
		_instances_head.set_count(str(instance_rows.size()))


## Fill [param list], or show its empty state when there is nothing to list.
static func _set_rows(list: RowList, rows: Array) -> void:
	list.set_rows(rows)
	var shown: Control = list.get_meta(&"scroll") if list.has_meta(&"scroll") else list
	shown.visible = not rows.is_empty()
	if list.has_meta(&"empty"):
		(list.get_meta(&"empty") as Control).visible = rows.is_empty()


## The short code a good's badge shows: a metal's symbol for the ore chain ("ore.gold" -> "Au"), else
## the first letters of its name. The market's badges read the same.
static func _code_of(good_type: String) -> String:
	const SYMBOLS := {"gold": "Au", "silver": "Ag", "copper": "Cu", "iron": "Fe", "titanium": "Ti",
		"aluminium": "Al", "aluminum": "Al", "nickel": "Ni", "platinum": "Pt", "uranium": "U", "lead": "Pb",
		"tin": "Sn", "zinc": "Zn", "cobalt": "Co", "lithium": "Li"}
	var tail: String = good_type.get_slice(".", good_type.count(".")) if good_type != "" else ""
	if SYMBOLS.has(tail):
		return SYMBOLS[tail]
	return tail.left(2).capitalize() if tail != "" else "—"
