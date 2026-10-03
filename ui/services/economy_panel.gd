extends ServicePanel

## App « Banque » : the caller's wallet (big balance + accounts), the ledger with signed/coloured
## movements, and direct transfers. Covers /api/me/wallet*, /api/transfers.

var _balance_label: Label
var _accounts: ItemList
var _transactions: ItemList
var _to_player: LineEdit
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

	# Transactions
	_transactions = _list(340.0)
	pages[1].add_child(_titled(tr("%%SVC_LBL_HISTORY"), _transactions, true))

	# Virement
	var transfer := VBoxContainer.new()
	transfer.add_theme_constant_override("separation", 10)
	_to_player = _field(tr("%%SVC_PH_RECIPIENT"), 320.0)
	_amount = _number_field(tr("%%SVC_PH_AMOUNT"), 160.0)
	_memo = _field(tr("%%SVC_PH_MEMO"), 320.0)
	transfer.add_child(_label(tr("%%SVC_LBL_RECIPIENT"), ServiceStyle.MUTED))
	transfer.add_child(_to_player)
	transfer.add_child(_label(tr("%%SVC_LBL_AMOUNT_CREDITS"), ServiceStyle.MUTED))
	transfer.add_child(_amount)
	transfer.add_child(_label(tr("%%SVC_LBL_MEMO"), ServiceStyle.MUTED))
	transfer.add_child(_memo)
	_action_button(transfer, tr("%%SVC_ACT_SEND_TRANSFER"), func() -> void: _transfer())
	pages[2].add_child(_card(tr("%%SVC_LBL_TRANSFER_TO_PLAYER"), transfer))

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
	var to_player: String = _to_player.text.strip_edges()
	if to_player == "" or not _amount.text.strip_edges().is_valid_int():
		_say(tr("%%SVC_MSG_NEED_RECIPIENT_AMOUNT"), WARN)
		return
	var result: Dictionary = await PlayerServices.transfer(to_player, int(_amount.text),
			_memo.text.strip_edges())
	if _report(result, tr("%%SVC_MSG_TRANSFER_SENT")):
		_amount.text = ""
		_memo.text = ""
		refresh()
