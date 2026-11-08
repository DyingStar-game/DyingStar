extends ServicePanel

## App « Économie » : the player's money, in two sections under one app — the bank (personal
## accounts, transactions, transfers and taxes) and the market (catalogue, orders, demands and
## trades). Each segment MOUNTS a whole section (see [method ServicePanel.mount_segment]), so each
## keeps its own tabs and action column; this shell owns the header — the picker between them and the
## available balance — and relays the keyboard and layout contract.
##
## The sections stay in their own files ([bank_panel], [market_panel]): this app composes them.

## The two sections, in bar order. Each is mounted into the segment of the same index.
const SECTIONS: Array = [
	{"title": "%%SVC_TAB_BANK", "path": "res://ui/services/bank_panel.gd"},
	{"title": "%%SVC_TAB_MARKET", "path": "res://ui/services/market_panel.gd"},
]

## The header's balance figure, refreshed with the app.
var _balance: Label = null


func _build() -> void:
	var labels := PackedStringArray()
	for section: Dictionary in SECTIONS:
		labels.append(tr(str(section["title"])))
	add_chrome(_app_bar(tr("%%SVC_APP_ECONOMY"), ServiceAppIcon.Kind.BANK))
	_mount_bar(labels)
	_header_append(_balance_block())
	for i: int in range(SECTIONS.size()):
		mount_segment(i, str(SECTIONS[i]["path"]))
	add_chrome(_status_line())


## The available balance, at the right-hand end of the header: what every section here spends from.
func _balance_block() -> Control:
	var block := VBoxContainer.new()
	block.alignment = BoxContainer.ALIGNMENT_CENTER
	block.add_theme_constant_override("separation", 2)
	var caption := ServiceStyle.label(tr("%%SVC_ECO_AVAILABLE_BALANCE"), ServiceStyle.MUTED,
			ServiceStyle.SIZE_CAPTION)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	block.add_child(caption)
	_balance = ServiceStyle.ares_label("—", ServiceStyle.ACCENT, 22)
	_balance.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	block.add_child(_balance)
	return block


func refresh() -> void:
	if not _begin_refresh():
		return
	var section := mounted_section()
	if section != null:
		await section.refresh()
	await _load_balance()
	_end_refresh()


func _load_balance() -> void:
	var wallet: Dictionary = await PlayerServices.wallet()
	if _balance == null:
		return
	if not bool(wallet.get("ok", false)):
		_balance.text = "—"
		return
	var accounts: Variant = (wallet.get("data") as Dictionary).get("accounts") \
			if wallet.get("data") is Dictionary else wallet.get("data")
	_balance.text = tr("%%SVC_FMT_CREDITS") % Globals.format_thousands(
			ServiceOverviewScreen._main_balance(accounts))
