extends ServicePanel

## App « Économie » : the player's money, in two sections under one app — the bank (personal
## accounts, transactions, transfers and taxes) and the market (catalogue, orders, demands and
## trades). Each segment MOUNTS a whole section (see [method ServicePanel.mount_segment]), so each
## keeps its own app bar, tabs and action column; this shell only owns the bar that picks between
## them and relays the keyboard and layout contract.
##
## The sections stay in their own files ([bank_panel], [market_panel]): this app composes them.

## The two sections, in bar order. Each is mounted into the segment of the same index.
const SECTIONS: Array = [
	{"title": "%%SVC_TAB_BANK", "path": "res://ui/services/bank_panel.gd"},
	{"title": "%%SVC_TAB_MARKET", "path": "res://ui/services/market_panel.gd"},
]


func _build() -> void:
	var labels := PackedStringArray()
	for section: Dictionary in SECTIONS:
		labels.append(tr(str(section["title"])))
	_mount_bar(labels)
	for i: int in range(SECTIONS.size()):
		mount_segment(i, str(SECTIONS[i]["path"]))
	add_chrome(_status_line())


func refresh() -> void:
	if not _begin_refresh():
		return
	var section := mounted_section()
	if section != null:
		await section.refresh()
	_end_refresh()
