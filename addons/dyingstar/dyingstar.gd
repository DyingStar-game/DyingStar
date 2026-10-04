@tool
extends EditorPlugin

const MainPanel = preload("res://addons/dyingstar/main_panel.tscn")
const ServerPropsIO = preload("res://addons/dyingstar/server_props_io.gd")
const PropSyncInspector = preload("res://addons/dyingstar/prop_sync_inspector.gd")

const ITEM_IMPORT := 0
const ITEM_EXPORT := 1
const ITEM_CLEAR := 2
const ITEM_UPDATE_DEFS := 3
const ITEM_VIEW_DEFS := 4
const ITEM_UPDATE_DEFS_LOCAL := 5

## Local horizonserver checkout, next to this project: the PRIMARY source of the network definitions
## (no network, same branch as the server you run). GitHub is the fallback when it is absent.
const HORIZON_PROPS_DIR := "../horizonserver/ds_genericprops/props"

## GitHub source of the network definitions (<type>_def.json), when there is no local horizonserver.
const DEFS_API := "https://api.github.com/repos/DyingStar-game/horizonserver/contents/ds_genericprops/props?ref=develop"
const DEFS_HEADERS := ["User-Agent: dyingstar-godot-plugin", "Accept: application/vnd.github+json"]
## Fallback type list when the GitHub API listing is rate-limited (403): each file is then fetched
## by its own api.github.com contents URL. The listing is preferred when available (discovers new types).
const DEFS_KNOWN := ["box", "building", "cargo_depot", "city", "crate_container", "mining_depot",
	"miningrock", "miningzone", "planet", "player", "poi_village", "shelf", "spawnbuilding", "star",
	"storagewarehouse", "vehicle", "vehicle_component", "vehicle_lift", "vehicle_lift_platform",
	"vehicle_lift_platformsystem"]


## Dev/test tools, keyed by their InputMap action: `true` = switched ON, `false` = switched OFF.
## A tool that is switched off keeps its code and its binding ON PURPOSE — we will need it again —
## so this is the single switch: PlayerClient skips building the tool, and the controls menu hides
## its binding (a key that does nothing must not be rebindable). Flip the value to bring a tool back,
## nothing else to change. A tool missing from this dictionary counts as OFF (see is_dev_tool_enabled).
##
## A tool with NO binding may use a plain name instead (see Teleporter.DEV_TOOL, "teleporter" —
## you walk into it, you do not press it). The controls menu simply never looks such a key up.
## What does not change is WHERE the switch is read: a tool is switched off where it RUNS. The
## teleporter is server-authoritative, so the server refuses; greying the interface out is only a
## courtesy.
const ENABLED_DEV_TOOLS: Dictionary = {
	"teleporter": false,   # test teleporter cabin — no binding: you walk into it
	"spawn_wheel": false,  # dev spawn wheel (Alt+T) — testing phase over
	"zapette": false,      # admin cleanup tool (key 2) — testing phase over
	"toggle_eva": false,   # EVA free-flight ($) — testing phase over, normal play only
	"debug_time": false,    # sky clock sweep (debug_time_forward / debug_time_back)
	"debug_toggle_moon_lights": false,  # moon lights on/off (Alt+key)
	"debug_isolate_light": false,       # remove one light contributor at a time (Alt+key)
	# Not an InputMap action: a build switch. The chunk mesh gets its edge skirts (the curtains
	# dropped under every chunk border that hide LOD seams) only when ON — OFF bakes bare grids,
	# to see the seams themselves or measure the skirt's share of the build. Part of the mesh
	# cache key (PlanetTerrain), so flipping it re-bakes instead of serving cached skirts.
	"build_chunk_skirts": false,
}
const SETTINGS_PREFIX = "DyingStar/outils_dev/"


var main_panel_instance
var _menu_button: MenuButton = null
var _ds_popup: PopupMenu = null  # the menu when hosted in an editor MenuBar
var _tool_menu_added := false
var _file_dialog: EditorFileDialog = null
var _dialog_mode := ""  # "import" or "export"
var _http: HTTPRequest = null
var _defs_loading := false
var _defs_ready := false  # whether Import/Export are allowed (items_def/ updated, or current accepted)
var _defs_abort := false  # set by "Keep current defs" to stop the in-progress download
var _inspector_plugin: EditorInspectorPlugin = null


func _enable_plugin() -> void:
	pass


func _disable_plugin() -> void:
	remove_custom_settings()


func _enter_tree() -> void:
	main_panel_instance = MainPanel.instantiate()
	add_control_to_bottom_panel(main_panel_instance, "DyingStar")
	_http = HTTPRequest.new()
	_http.timeout = 20.0  # never hang forever (would lock _defs_loading and the menus)
	EditorInterface.get_base_control().add_child(_http)
	_install_menu()
	_inspector_plugin = PropSyncInspector.new()
	add_inspector_plugin(_inspector_plugin)
	add_custom_settings()
	# Never update on our own: ask the developer first. Downloading on every editor start froze the
	# editor for seconds, and every devmode/N-clients restart from the bottom panel re-triggered the
	# whole thing. The items_def/ files alone decide whether Import/Export are usable — this MUST be
	# set here, or they would stay greyed out forever since no update runs at startup.
	_defs_ready = ServerPropsIO.has_network_defs()
	_refresh_menu_state()
	_ask_refresh_defs.call_deferred()


func _exit_tree() -> void:
	remove_control_from_bottom_panel(main_panel_instance)
	if is_instance_valid(main_panel_instance):
		main_panel_instance.queue_free()
		main_panel_instance = null
	_remove_menu()
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if is_instance_valid(_file_dialog):
		_file_dialog.queue_free()
		_file_dialog = null
	if is_instance_valid(_http):
		_http.queue_free()
		_http = null


func _get_plugin_name():
	return "DyingStar"


func _get_plugin_icon():
	return null


# ── "DyingStar" top menu (sits just before Help/Aide in the editor menu bar) ──

func _install_menu() -> void:
	var base := EditorInterface.get_base_control()
	# Strategy A — the editor uses a MenuBar (Godot 4.3+): add our PopupMenu as a top menu.
	var menubar := _find_by_class(base, "MenuBar")
	if menubar != null:
		_ds_popup = PopupMenu.new()
		_ds_popup.name = "DyingStar"
		_fill_popup(_ds_popup)
		menubar.add_child(_ds_popup)
		var idx := _menubar_index(menubar, ["Help", "Aide"])
		if idx >= 0:
			menubar.move_child(_ds_popup, idx)  # sit right before Help/Aide
		print("DyingStar: menu added to the editor MenuBar.")
		return
	# Strategy B — a row of MenuButton/Button: sit right before the Help/Aide entry.
	var help := _find_menu_label(base, ["Help", "Aide"])
	if help != null and help.get_parent() != null:
		_menu_button = MenuButton.new()
		_menu_button.text = "DyingStar"
		_menu_button.flat = true
		_fill_popup(_menu_button.get_popup())
		help.get_parent().add_child(_menu_button)
		help.get_parent().move_child(_menu_button, help.get_index())
		print("DyingStar: menu added before '%s' in the editor menu row." % help.text)
		return
	# Strategy C — fallback to Project > Tools.
	push_warning("DyingStar: editor menu bar not found, using Project > Tools fallback.")
	add_tool_menu_item("DyingStar — Import server props…", _on_import)
	add_tool_menu_item("DyingStar — Export server props…", _on_export)
	add_tool_menu_item("DyingStar — Clear server props", _on_clear)
	if _local_defs_dir() != "":
		add_tool_menu_item("DyingStar — Update network definitions (horizonserver)", _sync_defs_local)
	add_tool_menu_item("DyingStar — Update network definitions (GitHub)", _on_update_defs)
	add_tool_menu_item("DyingStar — View network definitions…", _on_view_defs)
	_tool_menu_added = true


func _fill_popup(pm: PopupMenu) -> void:
	pm.add_item("Import server props from JSON…", ITEM_IMPORT)
	pm.add_item("Export server props to JSON…", ITEM_EXPORT)
	pm.add_separator()
	pm.add_item("Clear server props (build clean)", ITEM_CLEAR)
	pm.add_separator()
	pm.add_item("Update network definitions from horizonserver (%s)" % HORIZON_PROPS_DIR.get_base_dir().get_base_dir(),
		ITEM_UPDATE_DEFS_LOCAL)
	pm.set_item_tooltip(pm.get_item_index(ITEM_UPDATE_DEFS_LOCAL),
		"Copy the <type>_def.json files of %s into res://%s/." % [_local_defs_path(), ServerPropsIO.DEFS_DIR.trim_prefix("res://")])
	pm.add_item("Update network definitions from GitHub", ITEM_UPDATE_DEFS)
	pm.add_item("View network definitions…", ITEM_VIEW_DEFS)
	pm.id_pressed.connect(_on_menu_id)
	_refresh_menu_state()


func _remove_menu() -> void:
	if is_instance_valid(_ds_popup):
		_ds_popup.queue_free()
		_ds_popup = null
	if is_instance_valid(_menu_button):
		_menu_button.queue_free()
		_menu_button = null
	if _tool_menu_added:
		remove_tool_menu_item("DyingStar — Import server props…")
		remove_tool_menu_item("DyingStar — Export server props…")
		remove_tool_menu_item("DyingStar — Clear server props")
		remove_tool_menu_item("DyingStar — Update network definitions (horizonserver)")
		remove_tool_menu_item("DyingStar — Update network definitions (GitHub)")
		remove_tool_menu_item("DyingStar — View network definitions…")
		_tool_menu_added = false


## Depth-first search for the first node of a given class (e.g. "MenuBar").
func _find_by_class(node: Node, klass: String) -> Node:
	if node.is_class(klass):
		return node
	for c in node.get_children():
		var r := _find_by_class(c, klass)
		if r != null:
			return r
	return null


## Index of the MenuBar menu whose title matches one of `labels` (-1 if none).
func _menubar_index(menubar, labels: Array) -> int:
	for i in menubar.get_menu_count():
		if String(menubar.get_menu_title(i)).strip_edges() in labels:
			return i
	return -1


## First Button/MenuButton whose (trimmed) text matches one of `labels` — an editor menu entry.
func _find_menu_label(node: Node, labels: Array) -> Control:
	if node is Button and String((node as Button).text).strip_edges() in labels:
		return node
	for c in node.get_children():
		var r := _find_menu_label(c, labels)
		if r != null:
			return r
	return null


func _on_menu_id(id: int) -> void:
	match id:
		ITEM_IMPORT:
			_on_import()
		ITEM_EXPORT:
			_on_export()
		ITEM_CLEAR:
			_on_clear()
		ITEM_UPDATE_DEFS:
			_on_update_defs()
		ITEM_UPDATE_DEFS_LOCAL:
			_sync_defs_local()
		ITEM_VIEW_DEFS:
			_on_view_defs()


# ── Actions ──────────────────────────────────────────────────────────────────

func _on_import() -> void:
	_open_dialog("import")


func _on_export() -> void:
	_open_dialog("export")


func _open_dialog(mode: String) -> void:
	_dialog_mode = mode
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM  # browse outside res:// (e.g. horizonserver)
		_file_dialog.add_filter("*.json", "JSON files")
		_file_dialog.file_selected.connect(_on_file_selected)
		EditorInterface.get_base_control().add_child(_file_dialog)
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE if mode == "import" else EditorFileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.title = "Import server props JSON" if mode == "import" else "Export server props JSON"
	if mode == "export":
		_file_dialog.current_file = "startup_items.json"
	_file_dialog.popup_centered_ratio(0.6)


func _on_file_selected(path: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var res: Dictionary
	if _dialog_mode == "import":
		res = ServerPropsIO.import_from_json(scene_root, path)
		# Select the import root so the designer can frame it with F (objects sit at planetary coords).
		if res.get("ok", false) and res.get("root_node") != null:
			var sel := EditorInterface.get_selection()
			sel.clear()
			sel.add_node(res["root_node"])
	else:
		res = ServerPropsIO.export_to_json(scene_root, path)
	_report(_dialog_mode, res)


func _on_clear() -> void:
	_report("clear", ServerPropsIO.clear(EditorInterface.get_edited_scene_root()))


## Print + a small dialog with the result of an import/export/clear.
func _report(action: String, res: Dictionary) -> void:
	var msg := ""
	if res.get("ok", false):
		msg = "DyingStar %s: OK — %d objects." % [action, int(res.get("count", 0))]
		if res.has("by_type"):
			msg += "\nBy type: %s" % str(res["by_type"])
		if int(res.get("skipped", 0)) > 0:
			msg += "\n%d skipped (see Output)." % int(res["skipped"])
		# Remind where the server actually spawns this scene (the editor keeps the root at 0,0,0).
		var sp = res.get("server_position")
		if sp != null:
			msg += "\nServer spawn (JSON): (%.1f, %.1f, %.1f)" % [
				float(sp.get("x", 0.0)), float(sp.get("y", 0.0)), float(sp.get("z", 0.0))]
			if str(res.get("server_parent_id", "")) != "":
				msg += " under %s" % str(res["server_parent_id"])
			msg += " — edited at (0,0,0)."
	else:
		msg = "DyingStar %s FAILED: %s" % [action, str(res.get("error", "unknown"))]
	print(msg)
	# Persistent feedback in the DyingStar bottom panel.
	if is_instance_valid(main_panel_instance) and main_panel_instance.has_method("show_status"):
		main_panel_instance.show_status(msg)
	var dlg := AcceptDialog.new()
	dlg.title = "DyingStar"
	dlg.dialog_text = msg
	dlg.exclusive = false  # exclusive dialogs collide with the Save-Scene modal -> editor crash
	EditorInterface.get_base_control().add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)


# ── Network definitions (items_def/, updated from ../horizonserver or GitHub) ───

func _on_update_defs() -> void:
	_refresh_defs()


## Absolute path of the local horizonserver props directory (may not exist).
func _local_defs_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join(HORIZON_PROPS_DIR).simplify_path()


## The local horizonserver props directory, or "" when there is no checkout next to this project.
func _local_defs_dir() -> String:
	var d := _local_defs_path()
	return d if DirAccess.dir_exists_absolute(d) else ""


## The primary source: the local horizonserver when present, else GitHub.
func _update_defs_auto() -> void:
	if _local_defs_dir() != "":
		_sync_defs_local()
	else:
		_refresh_defs()


## Copy ../horizonserver's <type>_def.json files into items_def/. Local disk: synchronous, no progress.
func _sync_defs_local() -> void:
	if _defs_loading:
		return
	var dir := _local_defs_dir()
	var msg := ""
	if dir == "":
		msg = "FAILED — no local horizonserver at %s." % _local_defs_path()
	else:
		var files := {}
		for fname in DirAccess.get_files_at(dir):
			if fname.ends_with(ServerPropsIO.DEFS_SUFFIX):
				files[fname] = FileAccess.get_file_as_string(dir.path_join(fname))
		var count := ServerPropsIO.write_defs(files)
		if count > 0:
			_on_defs_written()
			msg = "OK — %d type definitions copied from %s into items_def/." % [count, dir]
		else:
			msg = "FAILED — no valid definition in %s; items_def/ left unchanged." % dir
	_status(msg)
	var dlg := AcceptDialog.new()
	dlg.title = "DyingStar — Network definitions"
	dlg.dialog_text = msg
	dlg.exclusive = false  # exclusive dialogs collide with the Save-Scene modal -> editor crash
	EditorInterface.get_base_control().add_child(dlg)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered()


## items_def/ was rewritten: enable Import/Export, show the new files, refresh an open PropSync dropdown.
func _on_defs_written() -> void:
	_defs_ready = true
	_refresh_menu_state()
	EditorInterface.get_resource_filesystem().scan()
	var edited := EditorInterface.get_inspector().get_edited_object()
	if edited != null:
		edited.notify_property_list_changed()


## Startup prompt: the developer decides whether we update at all. Deferred so it does not pop
## while the editor is still building itself, and NOT exclusive — an exclusive dialog collides with
## the editor's own Save-Scene modal and crashes it (same reason as _propose_cached below).
func _ask_refresh_defs() -> void:
	var cd := ConfirmationDialog.new()
	cd.title = "DyingStar — Network definitions"
	cd.exclusive = false
	var local := _local_defs_dir() != ""
	var source := ("the local horizonserver\n(%s)" % _local_defs_path()) if local else "GitHub"
	if _defs_ready:
		cd.dialog_text = "Update the network definitions from %s?\nCurrent items_def/: %d types." % [
			source, ServerPropsIO.load_network_defs().size()]
		cd.get_cancel_button().text = "Keep current"
	else:
		cd.dialog_text = ("Update the network definitions from %s?\n" % source
			+ "items_def/ is empty — Import / Export stay disabled until you do.")
		cd.get_cancel_button().text = "Later"
	cd.get_ok_button().text = "Update from horizonserver" if local else "Update from GitHub"
	EditorInterface.get_base_control().add_child(cd)
	cd.confirmed.connect(_on_startup_update.bind(cd))
	# Declining reuses the existing handlers: keep items_def/ when it has defs, else stay disabled.
	cd.canceled.connect((_on_use_cached if _defs_ready else _on_decline_cached).bind(cd))
	cd.popup_centered()


func _on_startup_update(cd: ConfirmationDialog) -> void:
	cd.queue_free()
	_update_defs_auto()


## Fetch the <type>_def.json files from GitHub into items_def/, and refresh the menu state. Used on
## startup when there is no local horizonserver, and by the "… from GitHub" menu item.
func _refresh_defs() -> void:
	if _defs_loading or not is_instance_valid(_http):
		return
	_defs_loading = true
	_defs_abort = false
	_refresh_menu_state()
	# Progress modal with a progress bar: the designer sees the download.
	# NOTE: must NOT be exclusive. An exclusive modal here collides with the
	# editor's own exclusive Save-Scene ProgressDialog if the user saves while
	# this async GitHub fetch is still pending (20s timeout), corrupting the
	# exclusive-window bookkeeping and crashing the editor (SIGSEGV on save).
	var dlg := AcceptDialog.new()
	dlg.title = "DyingStar — Network definitions"
	dlg.exclusive = false
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(440, 0)
	var lbl := Label.new()
	lbl.text = "Connecting to GitHub…"
	var bar := ProgressBar.new()
	vbox.add_child(lbl)
	vbox.add_child(bar)
	dlg.add_child(vbox)
	EditorInterface.get_base_control().add_child(dlg)
	dlg.get_ok_button().disabled = true  # cannot dismiss while downloading
	# "Keep current defs": skip the download and keep items_def/ (disabled when it is empty).
	var cache_btn := dlg.add_button("Keep current defs", false, "use_cache")
	cache_btn.disabled = not ServerPropsIO.has_network_defs()
	dlg.custom_action.connect(_on_progress_action.bind(dlg))
	dlg.popup_centered(Vector2i(520, 160))
	var count := await _fetch_defs(lbl, bar)
	if _defs_abort:
		return  # the "Keep current defs" button already handled everything
	_defs_loading = false
	if count > 0:
		_on_defs_written()
		_finish_dialog(dlg, lbl, bar,
			"OK — updated %d type definitions from GitHub into items_def/.\nImport / Export are now enabled." % count)
	elif ServerPropsIO.has_network_defs():
		dlg.queue_free()  # close the progress modal; let the designer choose whether to keep items_def/
		_propose_cached()
	else:
		_defs_ready = false
		_finish_dialog(dlg, lbl, bar,
			"FAILED — could not fetch the definitions and items_def/ is empty.\nImport / Export disabled.")
	_refresh_menu_state()


## "Keep current defs" pressed in the progress modal: stop the download and keep items_def/.
func _on_progress_action(action: StringName, dlg: AcceptDialog) -> void:
	if String(action) != "use_cache":
		return
	_defs_abort = true
	_defs_loading = false
	_defs_ready = true
	_refresh_menu_state()
	_status("DyingStar: keeping the network definitions in items_def/ (download skipped).")
	if is_instance_valid(dlg):
		dlg.queue_free()


## Turn the progress modal into its final state (result text + closable OK) and report it.
func _finish_dialog(dlg: AcceptDialog, lbl: Label, bar: ProgressBar, msg: String) -> void:
	lbl.text = msg
	bar.value = bar.max_value
	dlg.get_ok_button().disabled = false
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	_status(msg)


## GitHub unreachable but items_def/ has definitions: ask the designer whether to use them.
func _propose_cached() -> void:
	var n := ServerPropsIO.load_network_defs().size()
	var cd := ConfirmationDialog.new()
	cd.title = "DyingStar — Network definitions"
	cd.exclusive = false  # exclusive dialogs collide with the Save-Scene modal -> editor crash
	cd.dialog_text = "Could not reach GitHub.\nUse the current definitions in items_def/ (%d types)?" % n
	cd.get_ok_button().text = "Use current"
	cd.get_cancel_button().text = "Disable"
	EditorInterface.get_base_control().add_child(cd)
	cd.confirmed.connect(_on_use_cached.bind(cd))
	cd.canceled.connect(_on_decline_cached.bind(cd))
	cd.popup_centered()


func _on_use_cached(cd: ConfirmationDialog) -> void:
	_defs_ready = true
	_refresh_menu_state()
	_status("DyingStar: using the network definitions in items_def/ (Import / Export enabled).")
	cd.queue_free()


func _on_decline_cached(cd: ConfirmationDialog) -> void:
	_defs_ready = false
	_refresh_menu_state()
	_status("DyingStar: current definitions declined — Import / Export disabled.")
	cd.queue_free()


func _status(msg: String) -> void:
	print(msg)
	if is_instance_valid(main_panel_instance) and main_panel_instance.has_method("show_status"):
		main_panel_instance.show_status(msg)


## Show the network definitions of items_def/ ({type: [properties]}) in a searchable tree.
func _on_view_defs() -> void:
	var defs := ServerPropsIO.load_network_defs()
	var dlg := AcceptDialog.new()
	dlg.title = "DyingStar — Network definitions (%d types)" % defs.size()
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(420, 460)
	var search := LineEdit.new()
	search.placeholder_text = "Filter by type or property…"
	search.clear_button_enabled = true
	var tree := Tree.new()
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(search)
	vbox.add_child(tree)
	dlg.add_child(vbox)
	EditorInterface.get_base_control().add_child(dlg)
	_populate_defs_tree(tree, defs, "")
	search.text_changed.connect(_on_defs_filter.bind(tree, defs))
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered(Vector2i(460, 520))


func _on_defs_filter(text: String, tree: Tree, defs: Dictionary) -> void:
	_populate_defs_tree(tree, defs, text)


## (Re)build the tree: one item per type matching the filter, with its properties as children. A
## type matches if its name contains the filter (then all its properties show), or if any property
## does (then only the matching ones show).
func _populate_defs_tree(tree: Tree, defs: Dictionary, filter: String) -> void:
	tree.clear()
	var root := tree.create_item()
	var f := filter.strip_edges().to_lower()
	var types := defs.keys()
	types.sort()
	for type_name in types:
		var props: Array = defs[type_name]
		var type_match := f == "" or str(type_name).to_lower().contains(f)
		var shown: Array = []
		for p in props:
			if type_match or str(p).to_lower().contains(f):
				shown.append(p)
		if not type_match and shown.is_empty():
			continue
		var ti := tree.create_item(root)
		ti.set_text(0, "%s  (%d)" % [str(type_name), props.size()])
		for p in shown:
			tree.create_item(ti).set_text(0, str(p))
	if root.get_child_count() == 0:
		var msg := "No definitions — run 'Update network definitions' first." if defs.is_empty() else "No match."
		tree.create_item(root).set_text(0, msg)


## Download the props directory listing then each <type>_def.json, and mirror them into items_def/.
## Returns the type count (0 = failure; items_def/ untouched).
func _fetch_defs(lbl: Label, bar: ProgressBar) -> int:
	# List via the GitHub API (1 call) to discover every <type>_def.json; fall back to the built-in
	# list if it fails. File CONTENT is fetched from the SAME api.github.com host (base64): raw
	# .githubusercontent.com times out via Godot's HTTPRequest on some networks (even when curl works).
	lbl.text = "Listing definitions on GitHub…"
	var files: Array = []  # [{name, url}]  url = api.github.com contents URL
	var listed := false  # a real listing: types gone from GitHub may be removed from items_def/
	var r := await _http_req(DEFS_API, DEFS_HEADERS)
	if _http_ok(r):
		var listing = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())
		if typeof(listing) == TYPE_ARRAY:
			for item in listing:
				var n := str(item.get("name", ""))
				if n.ends_with("_def.json"):
					files.append({"name": n, "url": str(item.get("url", ""))})
			listed = not files.is_empty()
	if files.is_empty():
		push_warning("DyingStar defs: API listing unavailable %s — using the built-in list." % _http_status(r))
		for t in DEFS_KNOWN:
			files.append({"name": "%s_def.json" % t, "url": DEFS_API.replace("?ref=", "/%s_def.json?ref=" % t)})
	bar.max_value = max(1, files.size())
	bar.value = 0
	var downloaded := {}  # {"<type>_def.json": text}
	var i := 0
	for fobj in files:
		if _defs_abort:  # "Keep current defs" was pressed
			return 0
		i += 1
		var fname := str(fobj["name"])
		var url := str(fobj["url"])
		lbl.text = "Downloading %s  (%d/%d)" % [fname, i, files.size()]
		bar.value = i
		if url == "":
			continue
		var rf := await _http_req(url, DEFS_HEADERS)
		if not _http_ok(rf):
			push_warning("DyingStar defs: %s failed %s" % [fname, _http_status(rf)])
			continue
		var meta = JSON.parse_string((rf[3] as PackedByteArray).get_string_from_utf8())
		if typeof(meta) != TYPE_DICTIONARY:
			continue
		var b64 := str(meta.get("content", "")).replace("\n", "").replace("\r", "")
		downloaded[fname] = Marshalls.base64_to_utf8(b64)
	# A partial download (rate limit, timeout) or the built-in list must not delete the defs it missed.
	var complete := listed and downloaded.size() == files.size()
	if not complete:
		push_warning("DyingStar defs: %d/%d files downloaded%s; other items_def/ files kept" % [
			downloaded.size(), files.size(), "" if listed else " (built-in list)"])
	return ServerPropsIO.write_defs(downloaded, complete)


## Reuse the SHARED HTTPRequest (created in _enter_tree, which the editor polls correctly; a fresh
## HTTPRequest created inside a coroutine is not polled and times out). [result, code, headers, body] or [].
func _http_req(url: String, headers) -> Array:
	if _http.request(url, headers) != OK:
		return []
	return await _http.request_completed


func _http_ok(r: Array) -> bool:
	return r.size() >= 4 and int(r[0]) == HTTPRequest.RESULT_SUCCESS and int(r[1]) == 200


func _http_status(r: Array) -> String:
	if r.size() < 2:
		return "(no response — connection error)"
	return "(result %d, HTTP %d)" % [int(r[0]), int(r[1])]


## Grey out Import/Export while the network definitions are missing or being fetched, and the
## horizonserver update when there is no local checkout.
func _refresh_menu_state() -> void:
	var ready := _defs_ready and not _defs_loading
	for pm in [_ds_popup, (_menu_button.get_popup() if is_instance_valid(_menu_button) else null)]:
		if pm == null:
			continue
		for id in [ITEM_IMPORT, ITEM_EXPORT]:
			var idx: int = pm.get_item_index(id)
			if idx >= 0:
				pm.set_item_disabled(idx, not ready)
		var local_idx: int = pm.get_item_index(ITEM_UPDATE_DEFS_LOCAL)
		if local_idx >= 0:
			pm.set_item_disabled(local_idx, _defs_loading or _local_defs_dir() == "")


func add_custom_settings() -> void:
	var needs_save := false
	
	for key in ENABLED_DEV_TOOLS:
		var setting_name = SETTINGS_PREFIX + str(key)
		var default_value = ENABLED_DEV_TOOLS[key]
		
		if not ProjectSettings.has_setting(setting_name):
			ProjectSettings.set_setting(setting_name, default_value)
			needs_save = true
			
		ProjectSettings.set_initial_value(setting_name, default_value)
		
		var property_info = {
			"name": setting_name,
			"type": TYPE_BOOL,
			"hint": PROPERTY_HINT_NONE
		}
		ProjectSettings.add_property_info(property_info)
		
		ProjectSettings.set_as_basic(setting_name, true)
	
	if needs_save:
		ProjectSettings.save()


func remove_custom_settings() -> void:
	for key in ENABLED_DEV_TOOLS:
		var setting_name = SETTINGS_PREFIX + str(key)
		if ProjectSettings.has_setting(setting_name):
			ProjectSettings.clear(setting_name)
	ProjectSettings.save()
