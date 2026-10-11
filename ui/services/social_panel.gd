extends ServicePanel

## App « Social » : the three social sections under one app — the contacts phone-book, the squads
## and the corporations. Each segment MOUNTS a whole section (see [method ServicePanel.
## mount_segment]), so every section keeps its own app bar, its own tabs and its own action column;
## this shell only owns the bar that picks between them and relays the keyboard and layout contract.
##
## The sections stay in their own files ([friends_panel], [groups_panel], [corporations_panel]):
## this app composes them, it does not restate them.

## The three sections, in bar order. Each is mounted into the segment of the same index.
const SECTIONS: Array = [
	{"title": "%%SVC_TAB_CONTACTS", "path": "res://ui/services/friends_panel.gd"},
	{"title": "%%SVC_TAB_SQUAD", "path": "res://ui/services/groups_panel.gd"},
	{"title": "%%SVC_TAB_CORPORATIONS", "path": "res://ui/services/corporations_panel.gd"},
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
