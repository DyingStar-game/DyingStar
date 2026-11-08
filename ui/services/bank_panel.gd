extends ServicePanel

## App « Banque » (A.R.E.S. OS mock-up, 2026-11): the caller's wallet — the main balance over a table
## of every account —, the ledger beside the detail of the picked movement, direct transfers beside a
## live summary, and the tax debts beside their payment. Covers /api/me/wallet*, /api/transfers,
## /api/me/taxes*.

## The segments, in tab order (also what the hero's buttons jump to).
const SEG_ACCOUNTS: int = 0
const SEG_TRANSACTIONS: int = 1
const SEG_TRANSFER: int = 2
const SEG_TAXES: int = 3
## Width (px) of the right-hand panel of the two-column tabs.
const ASIDE_WIDTH: float = 460.0

var _balance_label: Label
var _owner_label: Label
## The table of accounts: a grid whose header row stays, the rows below are rebuilt.
var _accounts_table: GridContainer
var _accounts_card: Card
var _transactions: RowList
var _transactions_card: Card
var _transactions_empty: Control
var _page_transactions: ServicePage
var _txn_detail: VBoxContainer
var _my_account_ids: Dictionary = {}
## The caller's display name, the holder of every account in their wallet.
var _me_name: String = ""
## The main balance, read by the transfer's "available" hint and its summary.
var _available: int = 0
var _recipient: ServiceTargetPicker
var _amount: LineEdit
var _memo: LineEdit
var _available_hint: Label
var _summary: GridContainer
var _send: Button
var _send_hint: Label
var _taxes: RowList
var _taxes_card: Card
var _taxes_empty: Control
var _page_taxes: ServicePage
var _tax_currency: LineEdit
var _tax_total: GridContainer


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_BANK"), ServiceAppIcon.Kind.BANK)
	add_chrome(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_ACCOUNTS"), tr("%%SVC_TAB_TRANSACTIONS"), tr("%%SVC_TAB_TRANSFER"),
			tr("%%SVC_TAB_TAXES")]))
	_build_accounts(pages[SEG_ACCOUNTS])
	_build_transactions(pages[SEG_TRANSACTIONS])
	_build_transfer(pages[SEG_TRANSFER])
	_build_taxes(pages[SEG_TAXES])
	add_chrome(_status_line())


# ---------------------------------------------------------------------------------------------
# Comptes — the main balance and its two ways out, over the table of accounts
# ---------------------------------------------------------------------------------------------

func _build_accounts(page: VBoxContainer) -> void:
	_frameless(page)
	page.add_theme_constant_override("separation", 24)
	var hero := _panel("", "", 32.0, false)
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := _row(16)
	hero.body.add_child(row)
	var money := VBoxContainer.new()
	money.add_theme_constant_override("separation", 6)
	money.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	money.add_child(ServiceStyle.label(tr("%%SVC_LBL_MAIN_BALANCE"), ServiceStyle.MUTED, ServiceStyle.SIZE_CAPTION))
	_balance_label = _big("—", ServiceStyle.ACCENT, 52)
	money.add_child(_balance_label)
	_owner_label = ServiceStyle.label("", ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL)
	money.add_child(_owner_label)
	row.add_child(money)
	var history := _action_button(row, tr("%%SVC_LBL_HISTORY"), func() -> void: goto_segment(SEG_TRANSACTIONS))
	history.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var transfer := _primary_button(row, tr("%%SVC_ACT_NEW_TRANSFER"), func() -> void: goto_segment(SEG_TRANSFER))
	transfer.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	page.add_child(hero)

	_accounts_card = _panel(tr("%%SVC_LBL_MY_ACCOUNTS"))
	_accounts_table = GridContainer.new()
	_accounts_table.columns = 5
	_accounts_table.add_theme_constant_override("h_separation", 24)
	_accounts_table.add_theme_constant_override("v_separation", 0)
	_accounts_table.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_accounts_card.body.add_child(_scroll(_accounts_table))
	page.add_child(_accounts_card)
	_fill_accounts_table([], "")


## The table's header, then one row per account (or [param message] alone: none, or the error).
func _fill_accounts_table(accounts: Array, message: String) -> void:
	_clear(_accounts_table)
	var headers := [tr("%%SVC_LBL_ACCOUNT"), tr("%%SVC_LBL_HOLDER"), tr("%%SVC_LBL_CURRENCY"),
			tr("%%SVC_LBL_STATUS"), tr("%%SVC_LBL_BALANCE")]
	for i: int in range(headers.size()):
		_accounts_table.add_child(_cell(headers[i], ServiceStyle.MUTED, i == headers.size() - 1, true))
	for account: Dictionary in accounts:
		var main: bool = account == _main_account(accounts)
		_accounts_table.add_child(_cell(_account_name(account, main), ServiceStyle.TEXT, false, false, true))
		_accounts_table.add_child(_cell(_me_name if _me_name != "" else "—", ServiceStyle.MUTED))
		_accounts_table.add_child(_cell(ServiceTypes.dash(account.get("currency")), ServiceStyle.MUTED))
		_accounts_table.add_child(_cell(ServiceTypes.dash(account.get("status")), ServiceStyle.MUTED))
		_accounts_table.add_child(_cell(_money(ServiceTypes.num(account.get("balance")), account.get("currency")),
				ServiceStyle.ACCENT, true))
	_accounts_card.set_count("%d" % accounts.size() if message == "" else "")
	if message != "":
		var note := ServiceStyle.label(message, ServiceStyle.MUTED, ServiceStyle.SIZE_SMALL)
		note.custom_minimum_size.y = 52
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_accounts_table.add_child(note)


## One cell of the accounts table: a header (small, muted, a line under it) or a value (a line under it
## too, the table's row rule). [param right] aligns it to the end (the balance column).
func _cell(text: String, colour: Color, right: bool = false, header: bool = false, bold: bool = false) -> Label:
	var cell := ServiceStyle.label(text, colour, ServiceStyle.SIZE_CAPTION if header else ServiceStyle.SIZE_BODY,
			header or bold)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	cell.custom_minimum_size.y = 40 if header else 56
	cell.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cell.add_theme_stylebox_override("normal", ServiceStyle.underline(ServiceStyle.LINE if header else Color("#1A202B")))
	return cell


## An account's name as the table reads it: the main one is "Main account", the others by currency.
func _account_name(account: Dictionary, main: bool) -> String:
	if main:
		return tr("%%SVC_HOME_CAP_ACCOUNT")
	return tr("%%SVC_FMT_BANK_ACCOUNT") % ServiceTypes.dash(account.get("currency"))


## An amount in its currency: credits as "1 500 cr", any other currency by its code.
static func _money(amount: int, currency: Variant) -> String:
	var code := str(currency if currency != null else "credits")
	if code == "credits" or code == "":
		return TranslationServer.translate("%%SVC_FMT_CREDITS") % Globals.format_thousands(amount)
	return "%s %s" % [Globals.format_thousands(amount), code]


# ---------------------------------------------------------------------------------------------
# Transactions — the ledger, and the detail of the picked movement
# ---------------------------------------------------------------------------------------------

func _build_transactions(page: VBoxContainer) -> void:
	_frameless(page)
	var columns := _columns()
	page.add_child(columns)
	_transactions_card = _panel(tr("%%SVC_LBL_HISTORY"))
	_page_transactions = ServicePage.new()
	_page_transactions.load_requested.connect(_load_transactions)
	_transactions = RowList.new()
	_transactions.row_selected.connect(_open_txn_detail)
	_transactions_card.body.add_child(_scroll(_transactions))
	_transactions_empty = _empty_state(tr("%%SVC_MSG_NO_TRANSACTIONS"), tr("%%SVC_EMPTY_TRANSACTIONS_TEXT"))
	_transactions_empty.visible = false
	_transactions_card.body.add_child(_transactions_empty)
	_transactions_card.body.add_child(_pager(_page_transactions))
	columns.add_child(_transactions_card)

	var detail := _panel(tr("%%SVC_LBL_DETAIL"))
	_txn_detail = VBoxContainer.new()
	_txn_detail.add_theme_constant_override("separation", 18)
	_txn_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.body.add_child(_scroll(_txn_detail))
	columns.add_child(_fixed(detail, ASIDE_WIDTH))
	_show_no_detail()


func _show_no_detail() -> void:
	_clear(_txn_detail)
	_txn_detail.add_child(_empty_state("", tr("%%SVC_MSG_SELECT_TRANSACTION")))


# ---------------------------------------------------------------------------------------------
# Virement — the form beside its live summary
# ---------------------------------------------------------------------------------------------

## Recipient picked from contacts / players / my corporations / corporations; a corporation pick routes
## the same amount and memo through the donation endpoint (treasury, no tax).
func _build_transfer(page: VBoxContainer) -> void:
	_frameless(page)
	var columns := _columns()
	page.add_child(columns)

	var form := _panel(tr("%%SVC_LBL_NEW_TRANSFER"))
	var fields := VBoxContainer.new()
	fields.add_theme_constant_override("separation", 22)
	form.body.add_child(_scroll(fields))
	_recipient = ServiceTargetPicker.new()
	_recipient.setup(ServiceTargetPicker.Mask.EITHER)
	adopt_field(_recipient.search_field())
	_recipient.picked.connect(func(_id: String, _kind: String) -> void: _update_summary())
	_recipient.cleared.connect(_update_summary)
	var recipient := _form_field(tr("%%SVC_FMT_STEP_RECIPIENT"), _recipient)
	# No contact yet: Social is where one is added (the mock-up's empty block, under the picker).
	var contacts := HBoxContainer.new()
	contacts.add_theme_constant_override("separation", 12)
	var contacts_hint := _hint(tr("%%SVC_BANK_CONTACTS_HINT"))
	# A wrapping label in a row needs its share of the width, or it wraps at every letter.
	contacts_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contacts.add_child(contacts_hint)
	var add_contact := Button.new()
	add_contact.text = tr("%%SVC_ACT_ADD_CONTACT_LINK")
	ServiceStyle.apply_link(add_contact)
	add_contact.pressed.connect(func() -> void: open_app_requested.emit("social", 0, 2))
	contacts.add_child(add_contact)
	recipient.add_child(contacts)
	fields.add_child(recipient)

	_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 160.0)
	_amount.text_changed.connect(func(_t: String) -> void: _update_summary())
	var amount := _form_field(tr("%%SVC_FMT_STEP_AMOUNT"), _suffix_field(_amount, "cr"))
	_available_hint = _hint("")
	amount.add_child(_available_hint)
	_memo = _field(tr("%%SVC_PH_MEMO"), 240.0)
	fields.add_child(_field_row([amount, _form_field(tr("%%SVC_LBL_MEMO"), _memo)]))
	columns.add_child(form)

	var aside := _panel(tr("%%SVC_LBL_SUMMARY"))
	_summary = _kv_grid([[tr("%%SVC_TXN_CAP_FROM"), tr("%%SVC_HOME_CAP_ACCOUNT")],
			[tr("%%SVC_TXN_CAP_TO"), tr("%%SVC_MSG_TO_CHOOSE")],
			[tr("%%SVC_TXN_CAP_AMOUNT"), "—"], [tr("%%SVC_LBL_BALANCE_AFTER"), "—"]], 150.0)
	aside.body.add_child(_summary)
	aside.body.add_child(_spacer_v())
	_send = _primary_button(aside.body, tr("%%SVC_ACT_SEND_TRANSFER"), func() -> void: _transfer())
	_send.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_send_hint = _hint(tr("%%SVC_MSG_NEED_RECIPIENT_AMOUNT"))
	_send_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	aside.body.add_child(_send_hint)
	columns.add_child(_fixed(aside, ASIDE_WIDTH))
	_update_summary()


## Push what follows to the bottom of a panel.
static func _spacer_v() -> Control:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return spacer


## The summary follows the form: recipient, amount, what is left after, and whether it can go.
func _update_summary() -> void:
	if _summary == null:
		return
	var values: Array = _summary.get_meta(&"values")
	var to: String = _recipient.picked_name()
	(values[1] as Label).text = to if to != "" else tr("%%SVC_MSG_TO_CHOOSE")
	(values[1] as Label).add_theme_color_override("font_color", ServiceStyle.TEXT if to != "" else ServiceStyle.MUTED)
	var raw := _amount.text.strip_edges()
	var amount: int = int(raw) if raw.is_valid_int() else 0
	(values[2] as Label).text = _money(amount, "credits")
	(values[3] as Label).text = _money(_available - amount, "credits")
	(values[3] as Label).add_theme_color_override("font_color",
			WARN if amount > _available else ServiceStyle.TEXT)
	_available_hint.text = tr("%%SVC_FMT_AVAILABLE") % _money(_available, "credits")
	var ready: bool = _recipient.picked_id() != "" and amount > 0
	_send.disabled = not ready
	_send_hint.visible = not ready


# ---------------------------------------------------------------------------------------------
# Impôts — every debt, and the payment that settles what it can
# ---------------------------------------------------------------------------------------------

## Every debt the caller owes (settled ones included: the list is the whole history), and one payment
## that settles all it can afford — an empty currency pays in all of them, the service's own default.
func _build_taxes(page: VBoxContainer) -> void:
	_frameless(page)
	var columns := _columns()
	page.add_child(columns)
	_taxes_card = _panel(tr("%%SVC_LBL_TAX_DEBTS"))
	_page_taxes = ServicePage.new()
	_page_taxes.load_requested.connect(_load_taxes)
	_taxes = RowList.new()
	_taxes_card.body.add_child(_scroll(_taxes))
	_taxes_empty = _empty_state(tr("%%SVC_TAX_UP_TO_DATE"), tr("%%SVC_TAX_EMPTY_TEXT"))
	_taxes_empty.visible = false
	_taxes_card.body.add_child(_taxes_empty)
	_taxes_card.body.add_child(_pager(_page_taxes))
	columns.add_child(_taxes_card)

	var aside := _panel(tr("%%SVC_LBL_PAYMENT"))
	_tax_currency = _field(tr("%%SVC_PH_CURRENCY"), 150.0)
	aside.body.add_child(_form_field(tr("%%SVC_LBL_CURRENCY"), _tax_currency, tr("%%SVC_TAX_CURRENCY_HINT")))
	_tax_total = _kv_grid([[tr("%%SVC_LBL_TOTAL_DUE"), "—"]], 150.0)
	aside.body.add_child(_tax_total)
	aside.body.add_child(_spacer_v())
	var pay := _primary_button(aside.body, tr("%%SVC_ACT_PAY_TAXES"), func() -> void: _pay_taxes())
	pay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(_fixed(aside, ASIDE_WIDTH))


# ---------------------------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------------------------

func refresh() -> void:
	if not _begin_refresh():
		return
	var profile: Dictionary = await PlayerServices.profile_get()
	if bool(profile.get("ok", false)) and profile.get("data") is Dictionary:
		_me_name = str((profile.get("data") as Dictionary).get("displayName", ""))
	var wallet: Dictionary = await PlayerServices.wallet()
	var my_ids: Dictionary = _account_ids(wallet)
	_my_account_ids = my_ids
	_apply_accounts(wallet, my_ids)
	await _load_transactions()
	await _load_taxes()
	_end_refresh()


## One window of the ledger. The wallet that signs the rows comes from the accounts page, so the
## first load always rides refresh(); later loads are the footer's.
func _load_transactions() -> void:
	var at: int = _page_transactions.offset
	var result: Dictionary = await PlayerServices.wallet_transactions(_page_transactions.limit, at)
	if _land(_page_transactions, at, result):
		_apply_transactions(result)


func _load_taxes() -> void:
	var at: int = _page_taxes.offset
	var result: Dictionary = await PlayerServices.my_taxes(_page_taxes.limit, at)
	if _land(_page_taxes, at, result):
		_apply_taxes(result)


## The set of the caller's account ids, used to tell an incoming movement from an outgoing one.
static func _account_ids(wallet: Dictionary) -> Dictionary:
	var ids: Dictionary = {}
	for account: Dictionary in _accounts_of(wallet):
		var id: String = str(account.get("id", ""))
		if id != "":
			ids[id] = true
	return ids


static func _accounts_of(result: Dictionary) -> Array:
	if not bool(result.get("ok", false)):
		return []
	var data: Variant = result.get("data")
	var accounts: Variant = (data as Dictionary).get("accounts") if data is Dictionary else data
	return accounts if accounts is Array else []


func _apply_accounts(result: Dictionary, _my_ids: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_accounts_table([], tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", "")))
		_balance_label.text = "—"
		_available = 0
		_update_summary()
		return
	var accounts: Array = _accounts_of(result)
	_available = _main_balance(accounts)
	_balance_label.text = _money(_available, "credits")
	_owner_label.text = tr("%%SVC_FMT_BANK_PERSONAL") % _me_name if _me_name != "" else ""
	_fill_accounts_table(accounts, "" if not accounts.is_empty() else tr("%%SVC_MSG_NO_ACCOUNTS"))
	_update_summary()


func _apply_transactions(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_transactions.set_rows([])
		_transactions.visible = false
		(_transactions_empty.get_meta(&"title") as Label).text = \
				tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))
		_transactions_empty.visible = true
		return
	var rows: Array = []
	for transaction: Dictionary in _page_transactions.rows(result):
		var amount: int = ServiceTypes.num(transaction.get("amount"))
		var incoming: bool = _my_account_ids.has(str(transaction.get("toAccountId", "")))
		var outgoing: bool = _my_account_ids.has(str(transaction.get("fromAccountId", "")))
		var sign: String = ""
		var colour: Color = ServiceStyle.MUTED
		if incoming and not outgoing:
			sign = "+"
			colour = GOOD
		elif outgoing and not incoming:
			sign = "−"
			colour = WARN
		rows.append({
			"thumb": sign if sign != "" else "·",
			"name": ServiceTypes.dash(transaction.get("type")),
			"sub": ServiceTypes.dash(transaction.get("createdAt")),
			"value": sign + _money(amount, transaction.get("currency")),
			"value_colour": colour,
			"meta": transaction,
		})
	_transactions.set_rows(rows)
	_transactions.visible = not rows.is_empty()
	(_transactions_empty.get_meta(&"title") as Label).text = tr("%%SVC_MSG_NO_TRANSACTIONS")
	_transactions_empty.visible = rows.is_empty()
	_transactions_card.set_count("%d" % _page_transactions.total)
	if _transactions.selected_meta() == null:
		_show_no_detail()


## What the caller owes, settled debts included — the list is the whole history, the status is in
## each row's line; the payment's total adds up what is still due in the window on show.
func _apply_taxes(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_taxes.set_rows([])
		_taxes.visible = false
		(_taxes_empty.get_meta(&"title") as Label).text = \
				tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))
		_taxes_empty.visible = true
		return
	var rows: Array = []
	var due: Dictionary = {}
	for debt: Dictionary in _page_taxes.rows(result):
		var status := str(debt.get("status", ""))
		var currency: Variant = debt.get("currency")
		if status == "due":
			due[str(currency)] = int(due.get(str(currency), 0)) + ServiceTypes.num(debt.get("amount"))
		rows.append({
			"name": ServiceTypes.tax_type_label(debt.get("taxType")),
			"sub": "%s  ·  %s  ·  %s" % [ServiceTypes.tax_debtor_label(debt.get("debtorType")),
					ServiceTypes.tax_status_label(debt.get("status")), ServiceTypes.dash(debt.get("createdAt"))],
			"value": _money(ServiceTypes.num(debt.get("amount")), currency),
			"value_colour": ServiceStyle.ACCENT if status == "due" else ServiceStyle.MUTED,
			"meta": debt,
		})
	_taxes.set_rows(rows)
	_taxes.visible = not rows.is_empty()
	(_taxes_empty.get_meta(&"title") as Label).text = tr("%%SVC_TAX_UP_TO_DATE")
	_taxes_empty.visible = rows.is_empty()
	_taxes_card.set_count("%d" % _page_taxes.total)
	var totals := PackedStringArray()
	for currency: String in due:
		totals.append(_money(int(due[currency]), currency))
	((_tax_total.get_meta(&"values") as Array)[0] as Label).text = \
			", ".join(totals) if not totals.is_empty() else _money(0, "credits")


## Settle everything affordable. The service answers with what it paid and what is still due, and
## that summary is what the player needs to read — not a generic « done ».
func _pay_taxes() -> void:
	release_fields()
	var result: Dictionary = await PlayerServices.my_taxes_pay(_tax_currency.text.strip_edges())
	if not bool(result.get("ok", false)):
		_say(HttpClient.describe_error(result), WARN)
		return
	var data: Variant = result.get("data")
	var summary := tr("%%SVC_MSG_TAXES_PAID")
	if data is Dictionary:
		summary = ServiceTypes.tax_payment_line(data as Dictionary)
	_say(summary, GOOD)
	refresh()


## The player's credits account, or the first one when there is no `credits` account; {} for none.
static func _main_account(accounts: Array) -> Dictionary:
	for account: Dictionary in accounts:
		if str(account.get("currency", "")) == "credits":
			return account
	return accounts[0] if not accounts.is_empty() else {}


## The player's credits balance, or the first account when there is no `credits` one.
static func _main_balance(accounts: Array) -> int:
	return ServiceTypes.num(_main_account(accounts).get("balance"))


func _transfer() -> void:
	release_fields()
	var target: String = _recipient.picked_id()
	if target == "" or not _amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_RECIPIENT_AMOUNT"), WARN)
		return
	var amount := int(_amount.text)
	var memo := _memo.text.strip_edges()
	# Player picks ride the taxed transfer; corporation picks ride the donation endpoint — same
	# amount and memo, the recipient decides which one the service receives.
	var result: Dictionary
	if _recipient.picked_kind() == ServiceTargetPicker.KIND_CORPORATION:
		result = await PlayerServices.corporation_donation(target, amount, memo)
	else:
		result = await PlayerServices.transfer(target, amount, memo)
	if _report(result, tr("%%SVC_MSG_TRANSFER_SENT")):
		_amount.text = ""
		_memo.text = ""
		_recipient.clear_pick()
		refresh()


# ---------------------------------------------------------------------------------------------
# Transaction detail — every field below already rides in the list payload; no extra fetch.
# ---------------------------------------------------------------------------------------------

func _open_txn_detail(meta: Variant) -> void:
	if not (meta is Dictionary):
		return
	var txn: Dictionary = meta
	_clear(_txn_detail)
	var incoming: bool = _my_account_ids.has(str(txn.get("toAccountId", "")))
	var outgoing: bool = _my_account_ids.has(str(txn.get("fromAccountId", "")))
	var sign: String = "+" if incoming and not outgoing else ("−" if outgoing and not incoming else "")
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(_tag("#%d · %s" % [ServiceTypes.num(txn.get("id")), ServiceTypes.dash(txn.get("type"))]))
	head.add_child(_big(sign + _money(ServiceTypes.num(txn.get("amount")), txn.get("currency")),
			GOOD if sign == "+" else (WARN if sign == "−" else ServiceStyle.TEXT), 34))
	_txn_detail.add_child(head)
	var details: Variant = txn.get("details")
	var memo: Variant = (details as Dictionary).get("memo") if details is Dictionary else null
	_txn_detail.add_child(_kv_grid([
		[tr("%%SVC_TXN_CAP_DATE"), ServiceTypes.dash(txn.get("createdAt"))],
		[tr("%%SVC_TXN_CAP_FROM"), _account_text(txn.get("fromAccountId"))],
		[tr("%%SVC_TXN_CAP_TO"), _account_text(txn.get("toAccountId"))],
		[tr("%%SVC_LBL_MEMO"), ServiceTypes.dash(memo)],
		[tr("%%SVC_TXN_CAP_TAXFEE"), "%d / %d" % [ServiceTypes.num(txn.get("taxAmount")),
				ServiceTypes.num(txn.get("feeAmount"))]],
		[tr("%%SVC_TXN_CAP_REFERENCE"), "%s · %s" % [ServiceTypes.dash(txn.get("reference")),
				ServiceTypes.dash(txn.get("caller"))]],
		[tr("%%SVC_TXN_CAP_EXTERNAL"), ServiceTypes.dash(txn.get("externalId"))],
		[tr("%%SVC_TXN_CAP_DETAILS"), JSON.stringify(details) if details != null else "—"],
	], 150.0))


## An account id as text, marked when it belongs to the caller's own wallet.
func _account_text(account_id: Variant) -> String:
	if account_id == null or str(account_id) == "":
		return "—"
	var text := str(account_id)
	if _my_account_ids.has(text):
		text += " " + tr("%%SVC_FMT_TXN_MINE")
	return text
