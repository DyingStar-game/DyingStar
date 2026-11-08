extends ServicePanel

## App « Marché » : the tradable goods catalogue, the order book (place / cancel), demands
## (create / cancel / fulfil) and trades. Covers /api/market/*.
##
## Laid out as the A.R.E.S. OS mock-up (2026-11): every tab draws its own panels — the catalogue beside
## the order book of the good picked, the orders and the demands beside the form that raises one,
## the trades alone with their filters.

const SIDE_ENTRIES: Array = [
	["sell", "%%SVC_ENUM_ORDER_SELL"],
	["buy", "%%SVC_ENUM_ORDER_BUY"],
]
## The order form's "side" chips: shorter words than the filter's.
const SIDE_CHIPS: Array = [
	["sell", "%%SVC_ACT_SELL"],
	["buy", "%%SVC_ACT_BUY"],
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
## The trades' role chips: every trade, the ones I bought, the ones I sold.
const ROLE_CHIPS: Array = [
	["all", "%%SVC_LBL_ALL_TRADES"],
	["buy", "%%SVC_LBL_PURCHASES"],
	["sell", "%%SVC_LBL_SALES"],
]
## The form panels' width (px): the mock-up's 520 px aside, scaled.
const FORM_WIDTH: float = 600.0

# Catalogue.
var _catalog: RowList
var _catalog_rows: Array = []
var _catalog_search: LineEdit
var _catalog_kind: OptionButton
var _catalog_box: Control
var _catalog_empty: Control
var _book: VBoxContainer
# Orders.
var _orders: RowList
var _orders_card: Card
var _page_orders: ServicePage
var _order_good: GoodTypePicker
var _order_side: OptionButton
var _order_status: OptionButton
var _order_form_good: GoodTypePicker
var _order_side_chips: HBoxContainer
var _order_kind_chips: HBoxContainer
var _order_qty: LineEdit
var _order_price: LineEdit
var _order_currency: LineEdit
var _order_instance: InstancePicker
var _order_corp_picker: ServiceTargetPicker
var _order_total: Label
var _cancel_order_button: Button
# Demands.
var _demands: RowList
var _demands_card: Card
var _page_demands: ServicePage
var _demand_good: GoodTypePicker
var _demand_status: OptionButton
var _demand_form_good: GoodTypePicker
var _demand_kind_chips: HBoxContainer
var _demand_instance: InstancePicker
var _demand_qty: LineEdit
var _demand_max: LineEdit
var _demand_currency: LineEdit
var _demand_message: LineEdit
var _demand_corp_picker: ServiceTargetPicker
var _demand_total: Label
var _fulfill_price: LineEdit
var _demand_actions: Array[Button] = []
# Trades.
var _trades: RowList
var _trades_card: Card
var _page_trades: ServicePage
var _trade_status: OptionButton
var _trade_role: HBoxContainer
var _trade_rows: Array = []


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_MARKET"), ServiceAppIcon.Kind.MARKET)
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_CATALOG"), tr("%%SVC_TAB_ORDERS"),
			tr("%%SVC_TAB_DEMANDS"), tr("%%SVC_TAB_TRADES")]))
	for page: VBoxContainer in pages:
		_frameless(page)
	_build_catalog_page(pages[0])
	_build_orders_page(pages[1])
	_build_demands_page(pages[2])
	_build_trades_page(pages[3])
	add_chrome(_status_line())


# ---------------------------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------------------------

func _build_catalog_page(page: VBoxContainer) -> void:
	var columns := _columns()
	page.add_child(columns)

	var list_card := _panel(tr("%%SVC_TAB_CATALOG"))
	columns.add_child(list_card)
	var filters := _row(12)
	_catalog_search = _field(tr("%%SVC_PH_SEARCH_GOOD"))
	_catalog_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_catalog_search.text_changed.connect(func(_t: String) -> void: _show_catalog())
	filters.add_child(_catalog_search)
	_catalog_kind = _option_enum(_with_all(KIND_ENTRIES), 220.0)
	_catalog_kind.item_selected.connect(func(_i: int) -> void: _show_catalog())
	filters.add_child(_catalog_kind)
	list_card.body.add_child(filters)
	_catalog = RowList.new()
	_catalog.row_selected.connect(func(meta: Variant) -> void: _load_book(meta))
	_catalog_box = _scroll(_catalog)
	list_card.body.add_child(_catalog_box)
	_catalog_empty = _empty_state(tr("%%SVC_MSG_NO_GOODS"), tr("%%SVC_EMPTY_CATALOG_TEXT"),
			tr("%%SVC_ACT_SELL_GOOD"), _go_sell, false)
	_catalog_empty.visible = false
	list_card.body.add_child(_catalog_empty)

	var book_card := _panel(tr("%%SVC_LBL_ORDER_BOOK"))
	columns.add_child(_fixed(book_card, FORM_WIDTH))
	_book = VBoxContainer.new()
	_book.add_theme_constant_override("separation", 14)
	_book.size_flags_vertical = Control.SIZE_EXPAND_FILL
	book_card.body.add_child(_book)
	_book.add_child(_empty_state("", tr("%%SVC_MSG_SELECT_GOOD_BOOK")))


## The catalogue is empty: off to the orders, the sell side picked, to put a good on sale.
func _go_sell() -> void:
	goto_segment(1)
	_pick_choice(_order_side_chips, "sell")


## The picked demand's actions (give it up, honour it): usable only once a demand is picked.
func _enable_demand_actions(enabled: bool) -> void:
	for button: Button in _demand_actions:
		button.disabled = not enabled


## The catalogue's rows that pass the search and the kind filter.
func _show_catalog() -> void:
	var needle: String = _catalog_search.text.strip_edges().to_lower()
	var kind: String = _enum_value(_catalog_kind)
	var rows: Array = []
	for entry: Dictionary in _catalog_rows:
		if kind != "" and str(entry.get("kind", "")) != kind:
			continue
		var good: String = str(entry.get("goodType", ""))
		var name: String = str(entry.get("displayName", "")) if str(entry.get("displayName", "")) != "" \
				else ServiceTypes.good_label(good)
		if needle != "" and not (name.to_lower().contains(needle) or good.to_lower().contains(needle)):
			continue
		rows.append({"thumb": _code_of(good), "name": name,
				"sub": "%s  ·  %s" % [good, ServiceTypes.good_kind_label(entry.get("kind"))],
				"value": ServiceTypes.dash(entry.get("unit")), "value_colour": ServiceStyle.MUTED,
				"meta": entry})
	_catalog.set_rows(rows)
	_catalog_box.visible = not rows.is_empty()
	_catalog_empty.visible = rows.is_empty()


func _load_book(meta: Variant) -> void:
	if not (meta is Dictionary):
		return
	var good_type: String = str((meta as Dictionary).get("goodType", ""))
	if good_type == "":
		return
	var result: Dictionary = await PlayerServices.market_book(good_type)
	_clear(_book)
	if not bool(result.get("ok", false)):
		_book.add_child(_label(HttpClient.describe_error(result), WARN))
		return
	if not (result.get("data") is Dictionary):
		_book.add_child(_label(tr("%%SVC_MSG_UNEXPECTED"), WARN))
		return
	var book: Dictionary = result.get("data")
	var head := _row(16)
	head.add_child(_thumb(_code_of(good_type), 56.0))
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", 4)
	titles.add_child(_tag(ServiceTypes.good_kind_label((meta as Dictionary).get("kind"))))
	titles.add_child(_title_lg(ServiceTypes.good_label(good_type), 24))
	head.add_child(titles)
	_book.add_child(head)
	var cards := GridContainer.new()
	cards.columns = 2
	cards.add_theme_constant_override("h_separation", 14)
	cards.add_child(_stat_card(tr("%%SVC_LBL_BOOK_BUY"), str(ServiceTypes.num(book.get("buy"))), "",
			ServiceStyle.TEXT, 28))
	cards.add_child(_stat_card(tr("%%SVC_LBL_BOOK_SELL"), str(ServiceTypes.num(book.get("sell"))), "",
			ServiceStyle.TEXT, 28))
	_book.add_child(cards)
	_book.add_child(_hint(tr("%%SVC_HINT_BOOK")))


# ---------------------------------------------------------------------------------------------
# Orders
# ---------------------------------------------------------------------------------------------

func _build_orders_page(page: VBoxContainer) -> void:
	var columns := _columns()
	page.add_child(columns)

	_orders_card = _panel(tr("%%SVC_TAB_ORDERS"))
	columns.add_child(_orders_card)
	var filters := _row(10)
	_order_good = GoodTypePicker.new()
	_order_good.setup(200.0)
	_order_side = _option_enum(_with_all(SIDE_ENTRIES), 170.0)
	_order_status = _option_enum(ORDER_STATUS_ENTRIES, 170.0)
	filters.add_child(_order_good)
	filters.add_child(_order_side)
	filters.add_child(_order_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _search_orders())
	_orders_card.body.add_child(filters)
	_page_orders = ServicePage.new()
	_page_orders.load_requested.connect(_load_orders)
	_orders = _list_block(_orders_card, _page_orders, tr("%%SVC_MSG_NO_ORDERS"), tr("%%SVC_EMPTY_ORDERS_TEXT"))
	_orders.row_selected.connect(func(_m: Variant) -> void: _cancel_order_button.disabled = false)
	var actions := _actions_bar()
	_cancel_order_button = _action_button(actions, tr("%%SVC_ACT_CANCEL_ORDER"), func() -> void: _cancel_order())
	ServiceStyle.apply_button_kind(_cancel_order_button, ServiceStyle.ButtonKind.DANGER)
	_cancel_order_button.disabled = true
	_orders_card.body.add_child(actions)

	var form_card := _panel(tr("%%SVC_ACT_PLACE_ORDER"))
	columns.add_child(_fixed(form_card, FORM_WIDTH))
	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 16)
	form_card.body.add_child(_scroll(form))
	_order_side_chips = _choice_bar(_translated(SIDE_CHIPS), "sell", Callable())
	for chip: Node in _order_side_chips.get_children():
		(chip as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(_form_field(tr("%%SVC_LBL_SIDE"), _order_side_chips))
	_order_form_good = GoodTypePicker.new()
	_order_form_good.setup(260.0)
	form.add_child(_form_field(tr("%%SVC_LBL_GOOD_TYPE"), _order_form_good))
	_order_instance = InstancePicker.new()
	_order_instance.visible = false
	_order_kind_chips = _choice_bar(_translated(KIND_ENTRIES), "stack",
			func(id: String) -> void: _order_instance.visible = id == "instance")
	form.add_child(_form_field(tr("%%SVC_LBL_KIND"), _order_kind_chips, tr("%%SVC_HINT_STACK_INSTANCE")))
	form.add_child(_order_instance)
	_order_qty = _number_field(tr("%%SVC_PH_QUANTITY"), 120.0)
	_order_price = _number_field(tr("%%SVC_PH_PRICE"), 120.0)
	form.add_child(_field_row([_form_field(tr("%%SVC_LBL_QUANTITY"), _order_qty),
			_form_field(tr("%%SVC_LBL_PRICE"), _suffix_field(_order_price, tr("%%SVC_LBL_PER_UNIT")))]))
	_order_currency = _field(tr("%%SVC_PH_CURRENCY"), 120.0)
	_order_corp_picker = ServiceTargetPicker.new()
	_order_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_order_corp_picker.search_field())
	form.add_child(_form_field(tr("%%SVC_LBL_CURRENCY"), _order_currency))
	form.add_child(_form_field(tr("%%SVC_LBL_ON_BEHALF_OF"), _order_corp_picker, tr("%%SVC_HINT_ON_BEHALF_OF")))
	var foot := _actions_bar()
	foot.add_child(_label(tr("%%SVC_LBL_TOTAL"), DIM))
	_order_total = ServiceStyle.ares_label("0", ServiceStyle.TEXT, 20)
	foot.add_child(_order_total)
	foot.add_child(_spacer())
	_primary_button(foot, tr("%%SVC_ACT_PLACE_ORDER"), func() -> void: _place_order())
	form_card.body.add_child(foot)
	for field: LineEdit in [_order_qty, _order_price, _order_currency]:
		field.text_changed.connect(func(_t: String) -> void:
			_total_into(_order_total, _order_qty, _order_price, _order_currency))


# ---------------------------------------------------------------------------------------------
# Demands
# ---------------------------------------------------------------------------------------------

func _build_demands_page(page: VBoxContainer) -> void:
	var columns := _columns()
	page.add_child(columns)

	_demands_card = _panel(tr("%%SVC_TAB_DEMANDS"))
	columns.add_child(_demands_card)
	var filters := _row(10)
	_demand_good = GoodTypePicker.new()
	_demand_good.setup(200.0)
	_demand_status = _option_enum(DEMAND_STATUS_ENTRIES, 170.0)
	filters.add_child(_demand_good)
	filters.add_child(_demand_status)
	_action_button(filters, tr("%%SVC_ACT_SEARCH"), func() -> void: _search_demands())
	_demands_card.body.add_child(filters)
	_page_demands = ServicePage.new()
	_page_demands.load_requested.connect(_load_demands)
	_demands = _list_block(_demands_card, _page_demands, tr("%%SVC_MSG_NO_DEMANDS"),
			tr("%%SVC_EMPTY_DEMANDS_TEXT"))
	# What acts on the picked demand: give it up (mine), or honour it at my price.
	var actions := _actions_bar()
	var cancel := _action_button(actions, tr("%%SVC_ACT_CANCEL_DEMAND"), func() -> void: _cancel_demand())
	ServiceStyle.apply_button_kind(cancel, ServiceStyle.ButtonKind.DANGER)
	actions.add_child(_spacer())
	_fulfill_price = _number_field(tr("%%SVC_PH_UNIT_PRICE"), 140.0)
	var price := _suffix_field(_fulfill_price, tr("%%SVC_LBL_PER_UNIT"))
	price.custom_minimum_size.x = 240.0
	price.size_flags_horizontal = Control.SIZE_FILL
	actions.add_child(price)
	var fulfil := _primary_button(actions, tr("%%SVC_ACT_FULFILL"), func() -> void: _fulfill_demand())
	_demand_actions = [cancel, fulfil]
	_enable_demand_actions(false)
	_demands.row_selected.connect(func(_m: Variant) -> void: _enable_demand_actions(true))
	_demands_card.body.add_child(actions)

	var form_card := _panel(tr("%%SVC_ACT_CREATE_DEMAND"))
	columns.add_child(_fixed(form_card, FORM_WIDTH))
	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 16)
	form_card.body.add_child(_scroll(form))
	_demand_form_good = GoodTypePicker.new()
	_demand_form_good.setup(260.0)
	form.add_child(_form_field(tr("%%SVC_LBL_GOOD_TYPE"), _demand_form_good))
	_demand_instance = InstancePicker.new()
	_demand_instance.visible = false
	_demand_kind_chips = _choice_bar(_translated(KIND_ENTRIES), "stack",
			func(id: String) -> void: _demand_instance.visible = id == "instance")
	form.add_child(_form_field(tr("%%SVC_LBL_KIND"), _demand_kind_chips, tr("%%SVC_HINT_STACK_INSTANCE")))
	form.add_child(_demand_instance)
	_demand_qty = _number_field(tr("%%SVC_PH_QUANTITY"), 120.0)
	_demand_max = _number_field(tr("%%SVC_PH_MAX_PRICE"), 120.0)
	form.add_child(_field_row([_form_field(tr("%%SVC_LBL_QUANTITY"), _demand_qty),
			_form_field(tr("%%SVC_LBL_MAX_PRICE"), _suffix_field(_demand_max, tr("%%SVC_LBL_PER_UNIT")))]))
	_demand_currency = _field(tr("%%SVC_PH_CURRENCY"), 120.0)
	_demand_corp_picker = ServiceTargetPicker.new()
	_demand_corp_picker.setup(ServiceTargetPicker.Mask.CORPORATIONS, true)
	adopt_field(_demand_corp_picker.search_field())
	form.add_child(_form_field(tr("%%SVC_LBL_CURRENCY"), _demand_currency))
	form.add_child(_form_field(tr("%%SVC_LBL_ON_BEHALF_OF"), _demand_corp_picker, tr("%%SVC_HINT_ON_BEHALF_OF")))
	_demand_message = _field(tr("%%SVC_PH_MESSAGE_OPTIONAL"), 200.0)
	form.add_child(_form_field(tr("%%SVC_LBL_MESSAGE"), _demand_message))
	var foot := _actions_bar()
	foot.add_child(_label(tr("%%SVC_LBL_TOTAL"), DIM))
	_demand_total = ServiceStyle.ares_label("0", ServiceStyle.TEXT, 20)
	foot.add_child(_demand_total)
	foot.add_child(_spacer())
	_primary_button(foot, tr("%%SVC_ACT_CREATE_DEMAND"), func() -> void: _create_demand())
	form_card.body.add_child(foot)
	for field: LineEdit in [_demand_qty, _demand_max, _demand_currency]:
		field.text_changed.connect(func(_t: String) -> void:
			_total_into(_demand_total, _demand_qty, _demand_max, _demand_currency))


# ---------------------------------------------------------------------------------------------
# Trades
# ---------------------------------------------------------------------------------------------

func _build_trades_page(page: VBoxContainer) -> void:
	_trades_card = _panel(tr("%%SVC_LBL_MARKET_TRADES"))
	page.add_child(_trades_card)
	# The role chips sort the window on show (the service answers every trade of mine at once);
	# the status is the service's own filter.
	_trade_role = _choice_bar(_translated(ROLE_CHIPS), "all", func(_id: String) -> void: _show_trades())
	_trades_card.head.add_child(_trade_role)
	_trade_status = _option_enum(TRADE_STATUS_ENTRIES, 170.0)
	_trade_status.item_selected.connect(func(_i: int) -> void: _search_trades())
	_trades_card.head.add_child(_trade_status)
	_page_trades = ServicePage.new()
	_page_trades.load_requested.connect(_load_trades)
	_trades = _list_block(_trades_card, _page_trades, tr("%%SVC_MSG_NO_TRADES"), tr("%%SVC_EMPTY_TRADES_TEXT"))


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
		_catalog_rows = []
		_show_catalog()
		_say(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), WARN)
		return
	_catalog_rows = (result.get("data") as Array).filter(func(e: Variant) -> bool: return e is Dictionary) \
			if result.get("data") is Array else []
	_show_catalog()
	# One catalogue, every goodType field: the filters and the forms read the same rows, so a buyer
	# picks a good once and the form agrees with the list they were just reading.
	for picker: Variant in [_order_good, _demand_good, _order_form_good, _demand_form_good]:
		if picker is GoodTypePicker:
			(picker as GoodTypePicker).fill(result.get("data", []))
	for picker: Variant in [_order_instance, _demand_instance]:
		if picker is InstancePicker:
			(picker as InstancePicker).refresh()


## The goodType a picker holds, or "" when it holds none. The widget speaks the same protocol the
## mission builder uses, so a form never reads a control's internals.
static func _picked_good_type(picker: Variant) -> String:
	if picker is GoodTypePicker:
		var value: Variant = (picker as GoodTypePicker).param_value()
		return "" if value == null else str(value)
	if picker is LineEdit:
		return (picker as LineEdit).text.strip_edges()
	return ""


## A new filter answers a new question: back to the first window, which loads it.
func _search_orders() -> void:
	release_fields()
	_page_orders.reset()


func _load_orders() -> void:
	var at: int = _page_orders.offset
	var result: Dictionary = await PlayerServices.market_orders(_picked_good_type(_order_good),
			_enum_value(_order_side), _enum_value(_order_status), _page_orders.limit, at)
	if _land(_page_orders, at, result):
		_cancel_order_button.disabled = true
		_fill_rows(_page_orders, result, _orders, _orders_card, _order_row)


func _search_demands() -> void:
	release_fields()
	_page_demands.reset()


func _load_demands() -> void:
	var at: int = _page_demands.offset
	var result: Dictionary = await PlayerServices.market_demands(_picked_good_type(_demand_good),
			_enum_value(_demand_status), _page_demands.limit, at)
	if _land(_page_demands, at, result):
		_enable_demand_actions(false)
		_fill_rows(_page_demands, result, _demands, _demands_card, _demand_row)


func _search_trades() -> void:
	release_fields()
	_page_trades.reset()


func _load_trades() -> void:
	var at: int = _page_trades.offset
	var result: Dictionary = await PlayerServices.market_trades(_enum_value(_trade_status),
			_page_trades.limit, at)
	if not _land(_page_trades, at, result):
		return
	if not bool(result.get("ok", false)):
		_trade_rows = []
		_say(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), WARN)
	else:
		_trade_rows = _page_trades.rows(result)
	_trades_card.set_count(str(_page_trades.total))
	_show_trades()


## The trades of the window that pass the role chips: every one, those I bought, those I sold.
func _show_trades() -> void:
	var role: String = str(_trade_role.get_meta(&"current", "all"))
	var me: String = PlayerServices.player_id()
	var rows: Array = []
	for trade: Dictionary in _trade_rows:
		if role == "buy" and str(trade.get("buyerId", "")) != me:
			continue
		if role == "sell" and str(trade.get("sellerId", "")) != me:
			continue
		rows.append(_trade_row(trade))
	_set_list(_trades, rows)


# ---------------------------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------------------------

## One order as a row: its side and good, how much is left of it, its status, and its price.
func _order_row(order: Dictionary) -> Dictionary:
	var good: String = str(order.get("goodType", ""))
	return {"thumb": _code_of(good),
			"name": "%s  ·  %s" % [ServiceTypes.order_side_label(order.get("side")), ServiceTypes.good_label(good)],
			"sub": "%d / %d  ·  %s" % [ServiceTypes.num(order.get("remaining")), ServiceTypes.num(order.get("quantity")),
					ServiceTypes.order_status_label(order.get("status"))],
			"value": _money(order.get("price"), order.get("currency")), "value_colour": ServiceStyle.ACCENT,
			"mono": true, "meta": order}


## One demand as a row: its good, quantity, status, and the most it pays a unit.
func _demand_row(demand: Dictionary) -> Dictionary:
	var good: String = str(demand.get("goodType", ""))
	var message: Variant = demand.get("message")
	var sub := "×%d  ·  %s" % [ServiceTypes.num(demand.get("quantity")),
			ServiceTypes.demand_status_label(demand.get("status"))]
	if message != null and str(message).strip_edges() != "":
		sub += "  ·  " + str(message).strip_edges()
	return {"thumb": _code_of(good), "name": ServiceTypes.good_label(good), "sub": sub,
			"value": "≤ " + _money(demand.get("maxPrice"), demand.get("currency")),
			"value_colour": ServiceStyle.ACCENT, "mono": true, "meta": demand}


## One trade as a row: the good, how much at what unit price, its status, and its total.
func _trade_row(trade: Dictionary) -> Dictionary:
	var good: String = str(trade.get("goodType", ""))
	var me: String = PlayerServices.player_id()
	var role := ""
	if str(trade.get("buyerId", "")) == me:
		role = tr("%%SVC_LBL_PURCHASE") + "  ·  "
	elif str(trade.get("sellerId", "")) == me:
		role = tr("%%SVC_LBL_SALE") + "  ·  "
	return {"thumb": _code_of(good), "name": ServiceTypes.good_label(good),
			"sub": "%s×%d @ %s  ·  %s" % [role, ServiceTypes.num(trade.get("quantity")),
					_money(trade.get("unitPrice"), trade.get("currency")),
					ServiceTypes.trade_status_label(trade.get("status"))],
			"value": _money(trade.get("totalPrice"), trade.get("currency")), "value_colour": ServiceStyle.ACCENT,
			"mono": true, "meta": trade}


## Fill [param list] from a paged answer, one [param to_row] per item; the panel's count follows.
func _fill_rows(page: ServicePage, result: Dictionary, list: RowList, card: Card, to_row: Callable) -> void:
	if not bool(result.get("ok", false)):
		_set_list(list, [])
		_say(tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")), WARN)
		return
	var rows: Array = []
	for item: Dictionary in page.rows(result):
		rows.append(to_row.call(item))
	card.set_count(str(page.total))
	_set_list(list, rows)


## A panel's list: the rows (scrolling inside the panel), its empty state, and the pager under them.
## Returns the [RowList]; [method _set_list] fills it and switches to the empty state when it is empty.
func _list_block(card: Card, page: ServicePage, empty_title: String, empty_text: String) -> RowList:
	var list := RowList.new()
	var scroll := _scroll(list)
	card.body.add_child(scroll)
	var empty := _empty_state(empty_title, empty_text)
	empty.visible = false
	card.body.add_child(empty)
	card.body.add_child(_pager(page))
	list.set_meta(&"scroll", scroll)
	list.set_meta(&"empty", empty)
	return list


static func _set_list(list: RowList, rows: Array) -> void:
	list.set_rows(rows)
	(list.get_meta(&"scroll") as Control).visible = not rows.is_empty()
	(list.get_meta(&"empty") as Control).visible = rows.is_empty()


# ---------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------

func _place_order() -> void:
	release_fields()
	var good_type: String = _picked_good_type(_order_form_good)
	if good_type == "" or not _order_qty.text.strip_edges().is_valid_int() \
			or not _order_price.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_ORDER_FIELDS"), WARN)
		return
	var body := {
		"side": str(_order_side_chips.get_meta(&"current", "sell")),
		"goodType": good_type,
		"kind": str(_order_kind_chips.get_meta(&"current", "stack")),
		"quantity": int(_order_qty.text),
		"price": int(_order_price.text),
		"currency": _order_currency.text.strip_edges() if _order_currency.text.strip_edges() != "" else "credits",
	}
	# Sent only when the seller named one object; the picker's default is "any unit of that good",
	# which is what most orders mean, and an absent instanceId is how the service is told so.
	if _order_instance != null and _order_instance.visible and _order_instance.picked_id() != "":
		body["instanceId"] = _order_instance.picked_id()
	if _order_corp_picker.picked_id() != "":
		body["corporationId"] = _order_corp_picker.picked_id()
	if _report(await PlayerServices.market_order_create(body), tr("%%SVC_MSG_ORDER_PLACED")):
		_order_qty.text = ""
		_order_price.text = ""
		_total_into(_order_total, _order_qty, _order_price, _order_currency)
		refresh()


func _cancel_order() -> void:
	var meta: Variant = _orders.selected_meta()
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_ORDER"), WARN)
		return
	var order_id: String = str((meta as Dictionary).get("id", ""))
	if _report(await PlayerServices.market_order_cancel(order_id), tr("%%SVC_MSG_ORDER_CANCELLED")):
		refresh()


func _create_demand() -> void:
	release_fields()
	var good_type: String = _picked_good_type(_demand_form_good)
	if good_type == "" or not _demand_qty.text.strip_edges().is_valid_int() \
			or not _demand_max.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_DEMAND_FIELDS"), WARN)
		return
	var body := {
		"goodType": good_type,
		"kind": str(_demand_kind_chips.get_meta(&"current", "stack")),
		"quantity": int(_demand_qty.text),
		"maxPrice": int(_demand_max.text),
		"currency": _demand_currency.text.strip_edges() if _demand_currency.text.strip_edges() != "" else "credits",
	}
	if _demand_message.text.strip_edges() != "":
		body["message"] = _demand_message.text.strip_edges()
	if _demand_instance != null and _demand_instance.visible and _demand_instance.picked_id() != "":
		body["instanceId"] = _demand_instance.picked_id()
	if _demand_corp_picker.picked_id() != "":
		body["corporationId"] = _demand_corp_picker.picked_id()
	if _report(await PlayerServices.market_demand_create(body), tr("%%SVC_MSG_DEMAND_CREATED")):
		_demand_qty.text = ""
		_demand_max.text = ""
		_total_into(_demand_total, _demand_qty, _demand_max, _demand_currency)
		refresh()


func _cancel_demand() -> void:
	var meta: Variant = _demands.selected_meta()
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_DEMAND"), WARN)
		return
	var demand_id: String = str((meta as Dictionary).get("id", ""))
	if _report(await PlayerServices.market_demand_cancel(demand_id), tr("%%SVC_MSG_DEMAND_CANCELLED")):
		refresh()


func _fulfill_demand() -> void:
	var meta: Variant = _demands.selected_meta()
	if not (meta is Dictionary):
		_say(tr("%%SVC_MSG_SELECT_DEMAND"), WARN)
		return
	if not _fulfill_price.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_UNIT_PRICE"), WARN)
		return
	if _report(await PlayerServices.market_demand_fulfill(str((meta as Dictionary).get("id", "")),
			int(_fulfill_price.text)), tr("%%SVC_MSG_DEMAND_FULFILLED")):
		refresh()


# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

## A form's total, quantity × unit price, in its currency.
static func _total_into(total: Label, quantity: LineEdit, price: LineEdit, currency: LineEdit) -> void:
	var q: int = int(quantity.text) if quantity.text.strip_edges().is_valid_int() else 0
	var p: int = int(price.text) if price.text.strip_edges().is_valid_int() else 0
	total.text = _money(q * p, currency.text.strip_edges())


## An amount in its currency: credits read "cr" (the DataPad's own unit), any other its own code.
static func _money(amount: Variant, currency: Variant) -> String:
	var code := str(currency if currency != null else "").strip_edges()
	var figure: String = Globals.format_thousands(ServiceTypes.num(amount))
	if code == "" or code == "credits":
		return TranslationServer.translate("%%SVC_FMT_CREDITS") % figure
	return "%s %s" % [figure, code]


## The short code a good's badge shows: a metal's symbol for the ore chain ("ore.gold" -> "Au"), else
## the first letters of its name.
static func _code_of(good_type: String) -> String:
	const SYMBOLS := {"gold": "Au", "silver": "Ag", "copper": "Cu", "iron": "Fe", "titanium": "Ti",
		"aluminium": "Al", "aluminum": "Al", "nickel": "Ni", "platinum": "Pt", "uranium": "U", "lead": "Pb",
		"tin": "Sn", "zinc": "Zn", "cobalt": "Co", "lithium": "Li"}
	var tail: String = good_type.get_slice(".", good_type.count(".")) if good_type != "" else ""
	if SYMBOLS.has(tail):
		return SYMBOLS[tail]
	return tail.left(2).capitalize() if tail != "" else "—"


## A value/key pair list with its keys translated, for [method ServicePanel._choice_bar].
func _translated(entries: Array) -> Array:
	var out: Array = []
	for entry: Array in entries:
		out.append([entry[0], tr(str(entry[1]))])
	return out


## The "all" entry the filters share, prepended to a value/key pair list.
static func _with_all(entries: Array) -> Array:
	var all: Array = [["", "%%SVC_ENUM_ALL"]]
	all.append_array(entries)
	return all
