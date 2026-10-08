extends ServicePanel

## App « Marché » : the tradable goods catalogue, the order book (place / cancel), demands
## (create / cancel / fulfil) and trades. Covers /api/market/*.

const SIDE_ENTRIES: Array = [
	["sell", "%%SVC_ENUM_ORDER_SELL"],
	["buy", "%%SVC_ENUM_ORDER_BUY"],
]
const ORDER_STATUS_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["open", "%%SVC_ENUM_ORDER_OPEN"],
	["partially_filled", "%%SVC_ENUM_ORDER_PARTIALLY_FILLED"],
	["filled", "%%SVC_ENUM_ORDER_FILLED"],
	["cancelled", "%%SVC_ENUM_ORDER_CANCELLED"],
	["expired", "%%SVC_ENUM_ORDER_EXPIRED"],
]
const DEMAND_STATUS_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["open", "%%SVC_ENUM_DEMAND_OPEN"],
	["fulfilled", "%%SVC_ENUM_DEMAND_FULFILLED"],
	["cancelled", "%%SVC_ENUM_DEMAND_CANCELLED"],
	["expired", "%%SVC_ENUM_DEMAND_EXPIRED"],
]
const TRADE_STATUS_ENTRIES: Array = [
	["", "%%SVC_ENUM_ALL"],
	["pending", "%%SVC_ENUM_TRADE_PENDING"],
	["settled", "%%SVC_ENUM_TRADE_SETTLED"],
	["cancelled", "%%SVC_ENUM_TRADE_CANCELLED"],
]
const KIND_ENTRIES: Array = [
	["stack", "%%SVC_ENUM_GOOD_STACK"],
	["instance", "%%SVC_ENUM_GOOD_INSTANCE"],
]

var _catalog: ItemList
var _book: Label
var _orders: ItemList
var _page_orders: ServicePage
var _order_good: LineEdit
var _order_side: OptionButton
var _order_status: OptionButton
var _order_new_side: OptionButton
var _order_kind: OptionButton
var _order_qty: LineEdit
var _order_price: LineEdit
var _order_currency: LineEdit
var _order_instance: LineEdit
var _order_corp_picker: ServiceTargetPicker
var _demands: ItemList
var _page_demands: ServicePage
var _demand_good: LineEdit
var _demand_status: OptionButton
var _demand_kind: OptionButton
var _demand_instance: LineEdit
var _demand_qty: LineEdit
var _demand_max: LineEdit
var _demand_currency: LineEdit
var _demand_message: LineEdit
var _demand_corp_picker: ServiceTargetPicker
var _fulfill_price: LineEdit
var _trades: ItemList
var _page_trades: ServicePage
var _trade_status: OptionButton


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_MARKET"), ServiceAppIcon.Kind.MARKET)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_CATALOG"), tr("%%SVC_TAB_ORDERS"),
			tr("%%SVC_TAB_DEMANDS"), tr("%%SVC_TAB_TRADES")]))
	_build_catalog_page(pages[0])
	_build_orders_page(pages[1])
	_build_demands_page(pages[2])
	_build_trades_page(pages[3])
	add_chrome(_status_line())


func _build_catalog_page(page: VBoxContainer) -> void:
	_catalog = _list(240.0)
	_catalog.item_selected.connect(func(_i: int) -> void: _load_book())
	page.add_child(_titled(tr("%%SVC_TAB_CATALOG"), _catalog, true))
	_book = _label("—", DIM)
	_book.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_titled(tr("%%SVC_LBL_ORDER_BOOK"), _book))


func _build_orders_page(page: VBoxContainer) -> void:
	# The filters and everything that acts on the list run from the column; the book stays in the
	# card beside them.
	var side := _side_page(1)
	var filters := _row()
	_order_good = _field(tr("%%SVC_PH_GOOD_TYPE"), 180.0)
	_order_side = _option_enum(_with_all(SIDE_ENTRIES), 130.0)
	_order_status = _option_enum(ORDER_STATUS_ENTRIES, 150.0)
	filters.add_child(_label(tr("%%SVC_LBL_GOOD_TYPE"), DIM))
	filters.add_child(_order_good)
	filters.add_child(_order_side)
	filters.add_child(_order_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _search_orders())
	side.add_child(filters)
	_page_orders = ServicePage.new()
	_page_orders.load_requested.connect(_load_orders)
	_orders = _paged_list(page, tr("%%SVC_TAB_ORDERS"), _page_orders, 240.0)
	var cancel := _row()
	_action_button(cancel, tr("%%SVC_ACT_CANCEL_ORDER"), func() -> void: _cancel_order())
	side.add_child(cancel)

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 10)
	_order_new_side = _option_enum(SIDE_ENTRIES, 200.0)
	_order_kind = _option_enum(KIND_ENTRIES)
	_order_qty = _number_field(tr("%%SVC_PH_QUANTITY"), 140.0)
	_order_price = _number_field(tr("%%SVC_PH_PRICE"), 140.0)
	_order_currency = _field(tr("%%SVC_PH_CURRENCY"), 140.0)
	_order_instance = _field(tr("%%SVC_PH_INSTANCE_ID"), 240.0)
	_order_corp_picker = ServiceTargetPicker.new()
	_order_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_order_corp_picker.search_field())
	form.add_child(_label(tr("%%SVC_LBL_SIDE"), DIM))
	form.add_child(_order_new_side)
	form.add_child(_label(tr("%%SVC_LBL_KIND"), DIM))
	form.add_child(_order_kind)
	form.add_child(_label(tr("%%SVC_HINT_STACK_INSTANCE"), DIM))
	form.add_child(_label(tr("%%SVC_LBL_QUANTITY"), DIM))
	form.add_child(_order_qty)
	form.add_child(_label(tr("%%SVC_LBL_PRICE"), DIM))
	form.add_child(_order_price)
	form.add_child(_label(tr("%%SVC_LBL_CURRENCY"), DIM))
	form.add_child(_order_currency)
	form.add_child(_label(tr("%%SVC_LBL_INSTANCE_ID"), DIM))
	form.add_child(_order_instance)
	form.add_child(_label(tr("%%SVC_LBL_CORPORATION"), DIM))
	form.add_child(_order_corp_picker)
	_action_button(form, tr("%%SVC_ACT_PLACE_ORDER"), func() -> void: _place_order())
	side.add_child(_card(tr("%%SVC_ACT_PLACE_ORDER"), form))


func _build_demands_page(page: VBoxContainer) -> void:
	var side := _side_page(2)
	var filters := _row()
	_demand_good = _field(tr("%%SVC_PH_GOOD_TYPE"), 180.0)
	_demand_status = _option_enum(DEMAND_STATUS_ENTRIES, 150.0)
	filters.add_child(_label(tr("%%SVC_LBL_GOOD_TYPE"), DIM))
	filters.add_child(_demand_good)
	filters.add_child(_demand_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _search_demands())
	side.add_child(filters)
	_page_demands = ServicePage.new()
	_page_demands.load_requested.connect(_load_demands)
	_demands = _paged_list(page, tr("%%SVC_TAB_DEMANDS"), _page_demands, 220.0)
	var actions := _row()
	_action_button(actions, tr("%%SVC_ACT_CANCEL_DEMAND"), func() -> void: _cancel_demand())
	_fulfill_price = _number_field(tr("%%SVC_PH_UNIT_PRICE"), 150.0)
	actions.add_child(_fulfill_price)
	_action_button(actions, tr("%%SVC_ACT_FULFILL"), func() -> void: _fulfill_demand())
	side.add_child(actions)

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 10)
	_demand_kind = _option_enum(KIND_ENTRIES)
	_demand_instance = _field(tr("%%SVC_PH_INSTANCE_ID"), 240.0)
	_demand_qty = _number_field(tr("%%SVC_PH_QUANTITY"), 140.0)
	_demand_max = _number_field(tr("%%SVC_PH_MAX_PRICE"), 140.0)
	_demand_currency = _field(tr("%%SVC_PH_CURRENCY"), 140.0)
	_demand_message = _field(tr("%%SVC_PH_MESSAGE_OPTIONAL"), 320.0)
	_demand_corp_picker = ServiceTargetPicker.new()
	_demand_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_demand_corp_picker.search_field())
	form.add_child(_label(tr("%%SVC_LBL_KIND"), DIM))
	form.add_child(_demand_kind)
	form.add_child(_label(tr("%%SVC_HINT_STACK_INSTANCE"), DIM))
	form.add_child(_label(tr("%%SVC_LBL_INSTANCE_ID"), DIM))
	form.add_child(_demand_instance)
	form.add_child(_label(tr("%%SVC_LBL_QUANTITY"), DIM))
	form.add_child(_demand_qty)
	form.add_child(_label(tr("%%SVC_LBL_MAX_PRICE"), DIM))
	form.add_child(_demand_max)
	form.add_child(_label(tr("%%SVC_LBL_CURRENCY"), DIM))
	form.add_child(_demand_currency)
	form.add_child(_label(tr("%%SVC_LBL_MESSAGE"), DIM))
	form.add_child(_demand_message)
	form.add_child(_label(tr("%%SVC_LBL_CORPORATION"), DIM))
	form.add_child(_demand_corp_picker)
	_action_button(form, tr("%%SVC_ACT_CREATE_DEMAND"), func() -> void: _create_demand())
	side.add_child(_card(tr("%%SVC_ACT_CREATE_DEMAND"), form))


func _build_trades_page(page: VBoxContainer) -> void:
	var filters := _row()
	_trade_status = _option_enum(TRADE_STATUS_ENTRIES, 150.0)
	filters.add_child(_trade_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _search_trades())
	_side_page(3).add_child(filters)
	_page_trades = ServicePage.new()
	_page_trades.load_requested.connect(_load_trades)
	_trades = _paged_list(page, tr("%%SVC_TAB_TRADES"), _page_trades, 320.0)


func refresh() -> void:
	if not _begin_refresh():
		return
	var catalog: Dictionary = await PlayerServices.market_catalog()
	_apply_catalog(catalog)
	await _load_orders()
	await _load_demands()
	await _load_trades()
	_end_refresh()


func _apply_catalog(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_catalog, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for entry: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		lines.append(ServiceTypes.catalog_line(entry))
		metadata.append(entry)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_CATALOG"))
	_fill_list(_catalog, lines, metadata)


func _load_book() -> void:
	var meta: Variant = _selected_meta(_catalog)
	if not (meta is Dictionary):
		return
	var good_type: String = str((meta as Dictionary).get("goodType", ""))
	if good_type == "":
		return
	var result: Dictionary = await PlayerServices.market_book(good_type)
	if not bool(result.get("ok", false)):
		_book.text = HttpClient.describe_error(result)
		return
	if not (result.get("data") is Dictionary):
		_book.text = tr("%%SVC_MSG_UNEXPECTED")
		return
	_book.text = "%s — %s" % [good_type, ServiceTypes.book_line(result.get("data"))]


## A new filter answers a new question: back to the first window, which loads it.
func _search_orders() -> void:
	release_fields()
	_page_orders.reset()


func _load_orders() -> void:
	var at: int = _page_orders.offset
	var result: Dictionary = await PlayerServices.market_orders(_order_good.text.strip_edges(),
			_enum_value(_order_side), _enum_value(_order_status), _page_orders.limit, at)
	if _land(_page_orders, at, result):
		_apply(_page_orders, result, _orders, ServiceTypes.order_line, tr("%%SVC_MSG_NO_ORDERS"))


func _search_demands() -> void:
	release_fields()
	_page_demands.reset()


func _load_demands() -> void:
	var at: int = _page_demands.offset
	var result: Dictionary = await PlayerServices.market_demands(_demand_good.text.strip_edges(),
			_enum_value(_demand_status), _page_demands.limit, at)
	if _land(_page_demands, at, result):
		_apply(_page_demands, result, _demands, ServiceTypes.demand_line, tr("%%SVC_MSG_NO_DEMANDS"))


func _search_trades() -> void:
	release_fields()
	_page_trades.reset()


func _load_trades() -> void:
	var at: int = _page_trades.offset
	var result: Dictionary = await PlayerServices.market_trades(_enum_value(_trade_status),
			_page_trades.limit, at)
	if _land(_page_trades, at, result):
		_apply(_page_trades, result, _trades, ServiceTypes.trade_line, tr("%%SVC_MSG_NO_TRADES"))


func _apply(page: ServicePage, result: Dictionary, list: ItemList, formatter: Callable,
		empty: String) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(list, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	for item: Dictionary in page.rows(result):
		lines.append(formatter.call(item))
		metadata.append(item)
	if lines.is_empty():
		lines.append(empty)
	_fill_list(list, lines, metadata)


func _place_order() -> void:
	release_fields()
	var good_type: String = _order_good.text.strip_edges() if _order_good != null else ""
	if good_type == "" or not _order_qty.text.strip_edges().is_valid_int() \
			or not _order_price.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_ORDER_FIELDS"), WARN)
		return
	var body := {
		"side": _enum_value(_order_new_side),
		"goodType": good_type,
		"kind": _enum_value(_order_kind),
		"quantity": int(_order_qty.text),
		"price": int(_order_price.text),
		"currency": _order_currency.text.strip_edges() if _order_currency.text.strip_edges() != "" else "credits",
	}
	if _order_instance.text.strip_edges() != "":
		body["instanceId"] = _order_instance.text.strip_edges()
	if _order_corp_picker.picked_id() != "":
		body["corporationId"] = _order_corp_picker.picked_id()
	if _report(await PlayerServices.market_order_create(body), tr("%%SVC_MSG_ORDER_PLACED")):
		_order_qty.text = ""
		_order_price.text = ""
		refresh()


func _cancel_order() -> void:
	var meta: Variant = _selected_meta(_orders)
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_ORDER"), WARN)
		return
	var order_id: String = str((meta as Dictionary).get("id", ""))
	if _report(await PlayerServices.market_order_cancel(order_id), tr("%%SVC_MSG_ORDER_CANCELLED")):
		refresh()


func _create_demand() -> void:
	release_fields()
	var good_type: String = _demand_good.text.strip_edges() if _demand_good != null else ""
	if good_type == "" or not _demand_qty.text.strip_edges().is_valid_int() \
			or not _demand_max.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_DEMAND_FIELDS"), WARN)
		return
	var body := {
		"goodType": good_type,
		"kind": _enum_value(_demand_kind),
		"quantity": int(_demand_qty.text),
		"maxPrice": int(_demand_max.text),
		"currency": _demand_currency.text.strip_edges() if _demand_currency.text.strip_edges() != "" else "credits",
	}
	if _demand_message.text.strip_edges() != "":
		body["message"] = _demand_message.text.strip_edges()
	if _demand_instance.text.strip_edges() != "":
		body["instanceId"] = _demand_instance.text.strip_edges()
	if _demand_corp_picker.picked_id() != "":
		body["corporationId"] = _demand_corp_picker.picked_id()
	if _report(await PlayerServices.market_demand_create(body), tr("%%SVC_MSG_DEMAND_CREATED")):
		_demand_qty.text = ""
		_demand_max.text = ""
		refresh()


func _cancel_demand() -> void:
	var meta: Variant = _selected_meta(_demands)
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_DEMAND"), WARN)
		return
	var demand_id: String = str((meta as Dictionary).get("id", ""))
	if _report(await PlayerServices.market_demand_cancel(demand_id), tr("%%SVC_MSG_DEMAND_CANCELLED")):
		refresh()


func _fulfill_demand() -> void:
	var meta: Variant = _selected_meta(_demands)
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_DEMAND"), WARN)
		return
	if not _fulfill_price.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_UNIT_PRICE"), WARN)
		return
	if _report(await PlayerServices.market_demand_fulfill(str((meta as Dictionary).get("id", "")),
			int(_fulfill_price.text)), tr("%%SVC_MSG_DEMAND_FULFILLED")):
		refresh()


## The "all" entry the filters share, prepended to a value/key pair list.
static func _with_all(entries: Array) -> Array:
	var all: Array = [["", "%%SVC_ENUM_ALL"]]
	all.append_array(entries)
	return all


## A card with a small caption header over its body.
func _card(caption: String, body: Control) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL_ALT, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 18.0, 14.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var header := _label(caption.to_upper(), ServiceStyle.MUTED)
	ServiceStyle.font_of(header, 12, true)
	box.add_child(header)
	box.add_child(body)
	card.add_child(box)
	return card
