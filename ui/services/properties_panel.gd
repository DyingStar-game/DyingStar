extends ServicePanel

## App « Propriétés » : what the player owns, in two sections under one app — the inventory (the
## stacks and instances in their hold) and the points of interest (the places they marked, shared
## or held by their corporation). Each segment MOUNTS a whole section (see [method ServicePanel.
## mount_segment]), so each keeps its own app bar, tabs and action column; this shell only owns the
## bar that picks between them and relays the keyboard and layout contract.
##
## The sections stay in their own files ([inventory_panel], [poi_panel]): this app composes them.

## The two sections, in bar order. Each is mounted into the segment of the same index.
const SECTIONS: Array = [
	{"title": "%%SVC_TAB_INVENTORY", "path": "res://ui/services/inventory_panel.gd"},
	{"title": "%%SVC_TAB_POIS", "path": "res://ui/services/poi_panel.gd"},
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


## The chart named a place: hand it to every section, so the one that asked (the points of
## interest form) can take it and the others, which never did, can ignore it.
##
## Answers whether one of them took it, for the console to know this app is the one to go back to.
func set_placed(place: Dictionary) -> bool:
	var taken: bool = false
	for mount: Dictionary in _mounts:
		var section: ServicePanel = mount.get("panel") as ServicePanel
		if section != null and section.set_placed(place):
			taken = true
	return taken


## The segment holding the form that asks the chart for a place: the points of interest's, which is
## the second section — the inventory's is the first, and the player is never sent there by mistake.
func placement_segment() -> int:
	return 1
