extends ServicePanel

## App « Banque » : the caller's wallet (big balance + accounts), the ledger with signed/coloured
## movements, and direct transfers. Covers /api/me/wallet*, /api/transfers.

var _balance_label: Label
var _accounts: ItemList
var _transactions: ItemList
var _txn_detail: VBoxContainer
var _my_account_ids: Dictionary = {}
var _recipient: ServiceTargetPicker
var _amount: LineEdit
var _memo: LineEdit


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_BANK"), ServiceAppIcon.Kind.BANK)
	_action_button(bar, tr("%%SVC_ACT_REFRESH"), func() -> void: refresh())
	add_child(bar)

	var pages := _segments_pages(PackedStringArray([
			tr("%%SVC_TAB_ACCOUNTS"), tr("%%SVC_TAB_TRANSACTIONS"), tr("%%SVC_TAB_TRANSFER")]))

	# Comptes — a big balance header, then every account.
	_balance_label = _label("—", ServiceStyle.ACCENT)
	ServiceStyle.font_of(_balance_label, 40, true)
	_balance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var balance_caption := _label(tr("%%SVC_LBL_MAIN_BALANCE"), ServiceStyle.MUTED)
	balance_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ServiceStyle.font_of(balance_caption, 12, true)
	var balance_box := VBoxContainer.new()
	balance_box.add_theme_constant_override("separation", 2)
	balance_box.add_child(balance_caption)
	balance_box.add_child(_balance_label)
	pages[0].add_child(_card(tr("%%SVC_LBL_ACCOUNT"), balance_box))
	_accounts = _list(240.0)
	pages[0].add_child(_titled(tr("%%SVC_LBL_MY_ACCOUNTS"), _accounts, true))

	# Transactions — the list, then the detail of the picked one (all fields already in the payload).
	_transactions = _list(340.0)
	_transactions.item_selected.connect(func(_i: int) -> void: _open_txn_detail())
	pages[1].add_child(_titled(tr("%%SVC_LBL_HISTORY"), _transactions, true))
	_txn_detail = VBoxContainer.new()
	_txn_detail.add_theme_constant_override("separation", 4)
	_txn_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_txn_detail.add_child(_label(tr("%%SVC_MSG_SELECT_TRANSACTION"), ServiceStyle.MUTED))
	pages[1].add_child(_titled(tr("%%SVC_LBL_DETAIL"), _txn_detail))

	# Transfer — recipient picked from contacts / players / my corps / corps search; a corporation
	# pick routes the same amount and memo through the donation endpoint (treasury, no tax).
	var transfer := VBoxContainer.new()
	transfer.add_theme_constant_override("separation", 10)
	_recipient = ServiceTargetPicker.new()
	_recipient.setup(ServiceTargetPicker.Mask.EITHER)
	adopt_field(_recipient.search_field())
	_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 160.0)
	_memo = _field(tr("%%SVC_PH_MEMO"), 320.0)
	transfer.add_child(_label(tr("%%SVC_LBL_RECIPIENT"), ServiceStyle.MUTED))
	transfer.add_child(_recipient)
	transfer.add_child(_label(tr("%%SVC_LBL_AMOUNT_CREDITS"), ServiceStyle.MUTED))
	transfer.add_child(_amount)
	transfer.add_child(_label(tr("%%SVC_LBL_MEMO"), ServiceStyle.MUTED))
	transfer.add_child(_memo)
	_action_button(transfer, tr("%%SVC_ACT_SEND_TRANSFER"), func() -> void: _transfer())
	pages[2].add_child(_card(tr("%%SVC_TAB_TRANSFER"), transfer))

	add_child(_status_line())


## A card with a small caption header over its body.
func _card(caption: String, body: Control) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.PANEL, ServiceStyle.RADIUS, ServiceStyle.BORDER, 1, 20.0, 16.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var header := _label(caption.to_upper(), ServiceStyle.MUTED)
	ServiceStyle.font_of(header, 12, true)
	box.add_child(header)
	box.add_child(body)
	card.add_child(box)
	return card


func refresh() -> void:
	if not _begin_refresh():
		return
	var wallet: Dictionary = await PlayerServices.wallet()
	var transactions: Dictionary = await PlayerServices.wallet_transactions()
	var my_ids: Dictionary = _account_ids(wallet)
	_my_account_ids = my_ids
	_apply_accounts(wallet, my_ids)
	_apply_transactions(transactions, my_ids)
	_end_refresh()


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
		_fill_list(_accounts, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		_balance_label.text = "—"
		return
	var accounts: Array = _accounts_of(result)
	_balance_label.text = "%s" % Globals.format_thousands(_main_balance(accounts))
	var lines := PackedStringArray()
	var metadata: Array = []
	for account: Dictionary in accounts:
		lines.append(ServiceTypes.account_line(account))
		metadata.append(account)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_ACCOUNTS"))
	_fill_list(_accounts, lines, metadata)


func _apply_transactions(result: Dictionary, my_ids: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fill_list(_transactions, PackedStringArray([tr("%%SVC_MSG_ERROR_PREFIX") + " " + str(result.get("error", ""))]))
		return
	var lines := PackedStringArray()
	var metadata: Array = []
	var colours: Array = []
	for transaction: Dictionary in (result.get("data", []) if result.get("data") is Array else []):
		var amount: int = ServiceTypes.num(transaction.get("amount"))
		var incoming: bool = my_ids.has(str(transaction.get("toAccountId", "")))
		var outgoing: bool = my_ids.has(str(transaction.get("fromAccountId", "")))
		var sign: String = ""
		var colour: Color = ServiceStyle.MUTED
		if incoming and not outgoing:
			sign = "+"
			colour = GOOD
		elif outgoing and not incoming:
			sign = "-"
			colour = WARN
		lines.append("%s%d %s     %s     %s" % [sign, amount,
				ServiceTypes.dash(transaction.get("currency")), ServiceTypes.dash(transaction.get("type")),
				ServiceTypes.dash(transaction.get("createdAt"))])
		metadata.append(transaction)
		colours.append(colour)
	if lines.is_empty():
		lines.append(tr("%%SVC_MSG_NO_TRANSACTIONS"))
	_fill_list(_transactions, lines, metadata)
	for i: int in range(mini(colours.size(), _transactions.item_count)):
		_transactions.set_item_custom_fg_color(i, colours[i])


## The player's credits balance, or the first account when there is no `credits` one.
static func _main_balance(accounts: Array) -> int:
	var first: int = 0
	var seen: bool = false
	for account: Dictionary in accounts:
		if not seen:
			first = ServiceTypes.num(account.get("balance"))
			seen = true
		if str(account.get("currency", "")) == "credits":
			return ServiceTypes.num(account.get("balance"))
	return first


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

func _open_txn_detail() -> void:
	var meta: Variant = _selected_meta(_transactions)
	if not (meta is Dictionary):
		return
	var txn: Dictionary = meta
	for child: Node in _txn_detail.get_children():
		_txn_detail.remove_child(child)
		child.queue_free()
	var header := _label("#%d · %s" % [ServiceTypes.num(txn.get("id")),
			ServiceTypes.dash(txn.get("type"))], ServiceStyle.TEXT)
	ServiceStyle.font_of(header, 16, true)
	_txn_detail.add_child(header)
	var details: Variant = txn.get("details")
	var lines := [
		tr("%%SVC_FMT_TXN_DATE") % ServiceTypes.dash(txn.get("createdAt")),
		tr("%%SVC_FMT_TXN_AMOUNT") % [ServiceTypes.num(txn.get("amount")),
				ServiceTypes.dash(txn.get("currency"))],
		tr("%%SVC_FMT_TXN_TAXFEE") % [ServiceTypes.num(txn.get("taxAmount")),
				ServiceTypes.num(txn.get("feeAmount"))],
		tr("%%SVC_FMT_TXN_FROM") % _account_text(txn.get("fromAccountId")),
		tr("%%SVC_FMT_TXN_TO") % _account_text(txn.get("toAccountId")),
		tr("%%SVC_FMT_TXN_REFERENCE") % [ServiceTypes.dash(txn.get("reference")),
				ServiceTypes.dash(txn.get("caller"))],
		tr("%%SVC_FMT_TXN_EXTERNAL") % ServiceTypes.dash(txn.get("externalId")),
		tr("%%SVC_FMT_TXN_DETAILS") % (JSON.stringify(details) if details != null else "—"),
	]
	for line: String in lines:
		_txn_detail.add_child(_label(line, ServiceStyle.TEXT))


## An account id as text, marked when it belongs to the caller's own wallet.
func _account_text(account_id: Variant) -> String:
	if account_id == null or str(account_id) == "":
		return "—"
	var text := str(account_id)
	if _my_account_ids.has(text):
		text += " " + tr("%%SVC_FMT_TXN_MINE")
	return text
