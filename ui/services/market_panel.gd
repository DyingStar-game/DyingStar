extends ServicePanel

## App « Marché » : catalogue des biens échangeables, carnet d'ordres (passer/annuler), demandes
## (créer/annuler/honorer) et transactions. Couvre /api/market/*.

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
var _order_good: LineEdit
var _order_side: OptionButton
var _order_status: OptionButton
var _order_new_side: OptionButton
var _order_kind: OptionButton
var _order_qty: LineEdit
var _order_price: LineEdit
var _order_currency: LineEdit
var _order_instance: LineEdit
var _order_corp: LineEdit
var _demands: ItemList
var _demand_good: LineEdit
var _demand_status: OptionButton
var _demand_kind: OptionButton
var _demand_instance: LineEdit
var _demand_qty: LineEdit
var _demand_max: LineEdit
var _demand_currency: LineEdit
var _demand_message: LineEdit
var _demand_corp: LineEdit
var _fulfill_price: LineEdit
var _trades: ItemList
var _trade_status: OptionButton


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_MARKET"), ServiceAppIcon.Kind.MARKET)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_child(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_CATALOG"), tr("%%SVC_TAB_ORDERS"),
			tr("%%SVC_TAB_DEMANDS"), tr("%%SVC_TAB_TRADES")]))
	_build_catalog_page(pages[0])
	_build_orders_page(pages[1])
	_build_demands_page(pages[2])
	_build_trades_page(pages[3])
	add_child(_status_line())


func _build_catalog_page(page: VBoxContainer) -> void:
	_catalog = _list(240.0)
	_catalog.item_selected.connect(func(_i: int) -> void: _load_book())
	page.add_child(_titled(tr("%%SVC_TAB_CATALOG"), _catalog, true))
	_book = _label("—", DIM)
	_book.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_titled(tr("%%SVC_LBL_ORDER_BOOK"), _book))


func _build_orders_page(page: VBoxContainer) -> void:
	var filters := _row()
	_order_good = _field(tr("%%SVC_PH_GOOD_TYPE"), 180.0)
	_order_side = _option_enum(_with_all(SIDE_ENTRIES), 130.0)
	_order_status = _option_enum(ORDER_STATUS_ENTRIES, 150.0)
	filters.add_child(_label(tr("%%SVC_LBL_GOOD_TYPE"), DIM))
	filters.add_child(_order_good)
	filters.add_child(_order_side)
	filters.add_child(_order_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _load_orders())
	page.add_child(filters)
	_orders = _list(240.0)
	page.add_child(_titled(tr("%%SVC_TAB_ORDERS"), _orders, true))
	_action_button(page, tr("%%SVC_ACT_CANCEL_ORDER"), func() -> void: _cancel_order())

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 10)
	_order_new_side = _option_enum(SIDE_ENTRIES, 200.0)
	_order_kind = _option_enum(KIND_ENTRIES)
	_order_qty = _number_field(tr("%%SVC_PH_QUANTITY"), 140.0)
	_order_price = _number_field(tr("%%SVC_PH_PRICE"), 140.0)
	_order_currency = _field(tr("%%SVC_PH_CURRENCY"), 140.0)
	_order_instance = _field(tr("%%SVC_PH_INSTANCE_ID"), 240.0)
	_order_corp = _field(tr("%%SVC_PH_CORP_ID"), 240.0)
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
	form.add_child(_label(tr("%%SVC_LBL_CORPORATION_ID"), DIM))
	form.add_child(_order_corp)
	_action_button(form, tr("%%SVC_ACT_PLACE_ORDER"), func() -> void: _place_order())
	page.add_child(_card(tr("%%SVC_ACT_PLACE_ORDER"), form))


func _build_demands_page(page: VBoxContainer) -> void:
	var filters := _row()
	_demand_good = _field(tr("%%SVC_PH_GOOD_TYPE"), 180.0)
	_demand_status = _option_enum(DEMAND_STATUS_ENTRIES, 150.0)
	filters.add_child(_label(tr("%%SVC_LBL_GOOD_TYPE"), DIM))
	filters.add_child(_demand_good)
	filters.add_child(_demand_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _load_demands())
	page.add_child(filters)
	_demands = _list(220.0)
	page.add_child(_titled(tr("%%SVC_TAB_DEMANDS"), _demands, true))
	var actions := _row()
	_action_button(actions, tr("%%SVC_ACT_CANCEL_DEMAND"), func() -> void: _cancel_demand())
	_fulfill_price = _number_field(tr("%%SVC_PH_UNIT_PRICE"), 150.0)
	actions.add_child(_fulfill_price)
	_action_button(actions, tr("%%SVC_ACT_FULFILL"), func() -> void: _fulfill_demand())
	page.add_child(actions)

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 10)
	_demand_kind = _option_enum(KIND_ENTRIES)
	_demand_instance = _field(tr("%%SVC_PH_INSTANCE_ID"), 240.0)
	_demand_qty = _number_field(tr("%%SVC_PH_QUANTITY"), 140.0)
	_demand_max = _number_field(tr("%%SVC_PH_MAX_PRICE"), 140.0)
	_demand_currency = _field(tr("%%SVC_PH_CURRENCY"), 140.0)
	_demand_message = _field(tr("%%SVC_PH_MESSAGE_OPTIONAL"), 320.0)
	_demand_corp = _field(tr("%%SVC_PH_CORP_ID"), 240.0)
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
	form.add_child(_label(tr("%%SVC_LBL_CORPORATION_ID"), DIM))
	form.add_child(_demand_corp)
	_action_button(form, tr("%%SVC_ACT_CREATE_DEMAND"), func() -> void: _create_demand())
	page.add_child(_card(tr("%%SVC_ACT_CREATE_DEMAND"), form))


func _build_trades_page(page: VBoxContainer) -> void:
	var filters := _row()
	_trade_status = _option_enum(TRADE_STATUS_ENTRIES, 150.0)
	filters.add_child(_trade_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _load_trades())
	page.add_child(filters)
	_trades = _list(320.0)
	page.add_child(_titled(tr("%%SVC_TAB_TRADES"), _trades, true))


func refresh() -> void:
	if not _begin_refresh():
		return
	var catalog: Dictionary = await PlayerServices.market_catalog()
	var orders: Dictionary = await PlayerServices.market_orders()
	var demands: Dictionary = await PlayerServices.market_demands()
	var trades: Dictionary = await PlayerServices.market_trades()
	_apply_catalog(catalog)
	_apply(orders, _orders, ServiceTypes.order_line, tr("%%SVC_MSG_NO_ORDERS"))
	_apply(demands, _demands, ServiceTypes.demand_line, tr("%%SVC_MSG_NO_DEMANDS"))
	_apply(trades, _trades, ServiceTypes.trade_line, tr("%%SVC_MSG_NO_TRADES"))
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


func _load_orders() -> void:
	release_fields()
	var result: Dictionary = await PlayerServices.market_orders(_order_good.text.strip_edges(),
			_enum_value(_order_side), _enum_value(_order_status))
	_apply(result, _orders, ServiceTypes.order_line, tr("%%SVC_MSG_NO_ORDERS"))


func _load_demands() -> void:
	release_fields()
	var result: Dictionary = await PlayerServices.market_demands(_demand_good.text.strip_edges(),
			_enum_value(_demand_status))
	_apply(result, _demands, ServiceTypes.demand_line, tr("%%SVC_MSG_NO_DEMANDS"))


func _load_trades() -> void:
	var result: Dictionary = await PlayerServices.market_trades(_enum_value(_trade_status))
	_apply(result, _trades, ServiceTypes.trade_line, tr("%%SVC_MSG_NO_TRADES"))


func _apply(result: Dictionary, list: ItemList, formatter: Callable, empty: String) -> void:
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
	if _order_corp.text.strip_edges() != "":
		body["corporationId"] = _order_corp.text.strip_edges()
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
	if _demand_corp.text.strip_edges() != "":
		body["corporationId"] = _demand_corp.text.strip_edges()
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
