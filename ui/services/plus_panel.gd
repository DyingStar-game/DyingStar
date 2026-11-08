extends ServicePanel

## App « Plus » : the sections with no tab of their own on the bottom bar — the reports and the
## diagnostics — under one app, picked from its header like the economy's bank and market. Each
## segment MOUNTS a whole section (see [method ServicePanel.mount_segment]); this shell only owns the
## picker and relays the keyboard and layout contract.
##
## It replaced the grid of app tiles the PLUS tab used to open (A.R.E.S. OS mock-up, 2026-11).

## The sections, in picker order. `id` is the [TerminalUI] APPS id a notification flags.
const SECTIONS: Array = [
	{"id": "reports", "title": "%%SVC_APP_REPORTS", "path": "res://ui/services/reports_panel.gd"},
	{"id": "diagnostics", "title": "%%SVC_APP_DIAGNOSTICS",
		"path": "res://ui/services/diagnostics_panel.gd"},
]


func _build() -> void:
	var labels := PackedStringArray()
	for section: Dictionary in SECTIONS:
		labels.append(tr(str(section["title"])))
	add_chrome(_app_bar(tr("%%SVC_NAV_PLUS"), ServiceAppIcon.Kind.REPORTS))
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


## The segment of section [param id] (an APPS id), or -1 when this app does not hold it.
static func segment_of(id: String) -> int:
	for i: int in range(SECTIONS.size()):
		if str(SECTIONS[i]["id"]) == id:
			return i
	return -1
