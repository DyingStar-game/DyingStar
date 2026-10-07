extends ServicePanel

## App « Inventaire » : the player's stacks and owned instances, a stack's detail (available /
## reserved), and a corporation's inventory. Covers /api/me/inventory* and
## /api/corporations/{id}/inventory*.

## One window carries both lists of a scope: the stacks and the instances are fetched together, so
## the footer under the stacks drives them both.
var _stacks: ItemList
var _instances: ItemList
var _page_stacks: ServicePage
var _stack_detail: Label
var _corp_picker: ServiceTargetPicker
var _corp_stacks: ItemList
var _corp_instances: ItemList
var _page_corp_stacks: ServicePage


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_INVENTORY"), ServiceAppIcon.Kind.INVENTORY)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_MY_INVENTORY"), tr("%%SVC_TAB_CORP_INVENTORY")]))

	# My inventory — stacks, instances, and the detail of the selected stack.
	_page_stacks = ServicePage.new()
	_page_stacks.rows_key = "stacks"
	_page_stacks.total_keys = PackedStringArray(["total", "instancesTotal"])
	_page_stacks.load_requested.connect(_load_inventory)
	_stacks = _paged_list(pages[0], tr("%%SVC_LBL_STACKS"), _page_stacks, 220.0)
	_stacks.item_selected.connect(func(_i: int) -> void: _load_stack_detail())
	var columns := _row(18)
	_instances = _list(160.0)
	columns.add_child(_titled(tr("%%SVC_LBL_INSTANCES"), _instances, true))
	_stack_detail = _label(tr("%%SVC_MSG_SELECT_STACK"), DIM)
	_stack_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	columns.add_child(_titled(tr("%%SVC_LBL_STACK_DETAIL"), _stack_detail, true))
	pages[0].add_child(columns)

	# Corporation — the pick that drives everything below it is the segment's action, so it lives in
	# the column; the inventory it loads stays in the card.
	var side := _side_page(1)
	var corp_row := _row()
	_corp_picker = ServiceTargetPicker.new()
	_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_corp_picker.search_field())
	corp_row.add_child(_corp_picker)
	_action_button(corp_row, tr("%%SVC_ACT_LOAD"), func() -> void: _load_corp())
	side.add_child(corp_row)
	var corp_columns := _row(18)
	_page_corp_stacks = ServicePage.new()
	_page_corp_stacks.rows_key = "stacks"
	_page_corp_stacks.total_keys = PackedStringArray(["total", "instancesTotal"])
	_page_corp_stacks.load_requested.connect(_load_corp_inventory)
	_corp_stacks = _paged_list(corp_columns, tr("%%SVC_LBL_STACKS"), _page_corp_stacks, 220.0)
	_corp_instances = _list(220.0)
	corp_columns.add_child(_titled(tr("%%SVC_LBL_INSTANCES"), _corp_instances, true))
	pages[1].add_child(corp_columns)

	add_chrome(_status_line())


func refresh() -> void:
	if not _begin_refresh():
		return
	await _load_inventory()
	_end_refresh()


func _load_inventory() -> void:
	var at: int = _page_stacks.offset
	var result: Dictionary = await PlayerServices.inventory_me(_page_stacks.limit, at)
	if _land(_page_stacks, at, result):
		_apply_inventory(_page_stacks, result, _stacks, _instances)


func _load_stack_detail() -> void:
	var meta: Variant = _selected_meta(_stacks)
	if not (meta is Dictionary):
		return
	var good_type: String = str((meta as Dictionary).get("goodType", ""))
	if good_type == "":
		return
	var result: Dictionary = await PlayerServices.inventory_me_stack(good_type)
	if not bool(result.get("ok", false)):
		_stack_detail.text = HttpClient.describe_error(result)
		return
	if not (result.get("data") is Dictionary):
		_stack_detail.text = tr("%%SVC_MSG_UNEXPECTED")
		return
	_stack_detail.text = ServiceTypes.stack_view_line(result.get("data"))


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


func _apply_inventory(page: ServicePage, result: Dictionary, stacks: ItemList,
		instances: ItemList) -> void:
	if not bool(result.get("ok", false)):
		var error: String = tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))
		_fill_list(stacks, PackedStringArray([error]))
		_fill_list(instances, PackedStringArray([error]))
		return
	_fill_simple(stacks, page.rows(result), ServiceTypes.stack_line, tr("%%SVC_MSG_NO_STACKS"))
	_fill_simple(instances, ServicePage.items_of(result, "instances"), ServiceTypes.instance_line,
			tr("%%SVC_MSG_NO_INSTANCES"))


func _fill_simple(list: ItemList, items: Array, formatter: Callable, empty: String) -> void:
	var lines := PackedStringArray()
	var metadata: Array = []
	for item: Dictionary in items:
		lines.append(formatter.call(item))
		metadata.append(item)
	if lines.is_empty():
		lines.append(empty)
	_fill_list(list, lines, metadata)
