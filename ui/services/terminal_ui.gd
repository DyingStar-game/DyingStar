class_name TerminalUI
extends CanvasLayer

## The player's tablet: a left rail (ARES brand, clock, app tiles) and a right content pane that shows
## the selected app — or the overview dashboard when none is open. Built in code and styled through
## [ServiceStyle]; no scene, no shared theme.
##
## Like [StarMap] it is a full-screen [CanvasLayer] (its own layer, a full-rect Panel inside), opened
## with F3; while it is up the game is frozen and the mouse is free.

## The installed apps, in grid order. `area` is the [signal PlayerServices.changed] key that app
## refreshes on.
const APPS: Array = [
	{"id": "identity", "title": "%%SVC_APP_IDENTITY", "area": "profile",
		"icon": ServiceAppIcon.Kind.IDENTITY, "path": "res://ui/services/profile_panel.gd"},
	{"id": "contacts", "title": "%%SVC_APP_CONTACTS", "area": "friends",
		"icon": ServiceAppIcon.Kind.CONTACTS, "path": "res://ui/services/friends_panel.gd"},
	{"id": "squad", "title": "%%SVC_APP_SQUAD", "area": "groups",
		"icon": ServiceAppIcon.Kind.SQUAD, "path": "res://ui/services/groups_panel.gd"},
	{"id": "corporations", "title": "%%SVC_APP_CORPORATIONS", "area": "corporations",
		"icon": ServiceAppIcon.Kind.CORPORATIONS, "path": "res://ui/services/corporations_panel.gd"},
	{"id": "missions", "title": "%%SVC_APP_MISSIONS", "area": "missions",
		"icon": ServiceAppIcon.Kind.MISSIONS, "path": "res://ui/services/mission_panel.gd"},
	{"id": "bank", "title": "%%SVC_APP_BANK", "area": "economy",
		"icon": ServiceAppIcon.Kind.BANK, "path": "res://ui/services/economy_panel.gd"},
	{"id": "inventory", "title": "%%SVC_APP_INVENTORY", "area": "inventory",
		"icon": ServiceAppIcon.Kind.INVENTORY, "path": "res://ui/services/inventory_panel.gd"},
	{"id": "market", "title": "%%SVC_APP_MARKET", "area": "market",
		"icon": ServiceAppIcon.Kind.MARKET, "path": "res://ui/services/market_panel.gd"},
	{"id": "reports", "title": "%%SVC_APP_REPORTS", "area": "reports",
		"icon": ServiceAppIcon.Kind.REPORTS, "path": "res://ui/services/reports_panel.gd"},
	{"id": "diagnostics", "title": "%%SVC_APP_DIAGNOSTICS", "area": "diagnostics",
		"icon": ServiceAppIcon.Kind.DIAGNOSTICS, "path": "res://ui/services/diagnostics_panel.gd"},
]

var _launcher: ServiceHomeScreen = null
var _overview: ServiceOverviewScreen = null
## id -> ServicePanel, and id -> the `area` its mutations announce on.
var _panels: Dictionary = {}
var _areas: Dictionary = {}
## The open app id, or "" when the overview is showing.
var _active_id: String = ""
var _built: bool = false
var _close_armed: bool = false


func _ready() -> void:
	# The headless server instantiates the console's scene like any other; it has nothing to draw.
	if GameOrchestrator.is_server():
		return
	layer = 10  # above the HUD, the same band the system chart uses
	visible = false
	PlayerServices.changed.connect(_on_services_changed)
	SettingsManager.language.changed.connect(_on_language_changed)


## The autoloads outlive this node: drop the connections so a freed terminal is never called back.
func _exit_tree() -> void:
	if PlayerServices.changed.is_connected(_on_services_changed):
		PlayerServices.changed.disconnect(_on_services_changed)
	if SettingsManager.language.changed.is_connected(_on_language_changed):
		SettingsManager.language.changed.disconnect(_on_language_changed)


# ---------------------------------------------------------------------------------------------
# Modal lifecycle (F3, see PlayerClient)
# ---------------------------------------------------------------------------------------------

## Build the tablet on the FIRST opening, so a player who never opens it pays nothing.
func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_build()


func open() -> void:
	if GameOrchestrator.is_server():
		return
	_ensure_built()
	show()
	_go_home()


func close() -> void:
	_close_armed = false
	release_fields()
	hide()


func is_open() -> bool:
	return visible


## Escape (or B) backs out one level: it releases a field first, then leaves an app for the overview,
## and only then closes the tablet — and the close runs on RELEASE, so the press cannot also fire the
## pause menu behind it (same two-step as StarMap).
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		if is_typing():
			release_fields()
		elif _active_id != "":
			_go_home()
		else:
			_close_armed = true
		get_viewport().set_input_as_handled()
		return
	if _close_armed and (event.is_action_released("ui_cancel") or event.is_action_released("pause")):
		_close_armed = false
		close()
		get_viewport().set_input_as_handled()


func _build() -> void:
	# A CanvasLayer draws nothing itself: the full-screen Panel inside it IS the window.
	var root := Panel.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	ServiceStyle.apply_window(root)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	root.add_child(margin)

	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 20)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(split)

	# LEFT — the rail: brand, clock and the app grid.
	_launcher = ServiceHomeScreen.new()
	_launcher.setup(APPS)
	_launcher.app_selected.connect(_open_app)
	_launcher.custom_minimum_size = Vector2(360, 0)
	split.add_child(_launcher)

	split.add_child(_rule())

	# RIGHT — the content pane: the overview and every app overlap; one is visible at a time.
	var content := MarginContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(content)

	_overview = ServiceOverviewScreen.new()
	_overview.setup()
	_overview.visible = false
	content.add_child(_overview)

	for app: Dictionary in APPS:
		var script: GDScript = load(str(app["path"]))
		var panel: ServicePanel = script.new()
		panel.visible = false
		panel.home_requested.connect(_go_home)
		content.add_child(panel)
		_panels[str(app["id"])] = panel
		_areas[str(app["id"])] = str(app["area"])


## The tablet is built in code, so unlike a scene it does not re-translate itself on a locale change
## (see [LanguageSettings]). Rebuild it from scratch and put the player back where they were.
func _on_language_changed(_language: String) -> void:
	if not _built:
		return
	var was_open: String = _active_id
	var was_visible: bool = visible
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_panels.clear()
	_areas.clear()
	_launcher = null
	_overview = null
	_active_id = ""
	_close_armed = false
	_build()
	if was_open != "" and _panels.has(was_open):
		_open_app(was_open)
	else:
		_go_home()
	visible = was_visible


## A hairline between the two panes.
func _rule() -> Control:
	var rule := Panel.new()
	rule.custom_minimum_size = Vector2(1, 0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.add_theme_stylebox_override("panel",
			ServiceStyle.flat(ServiceStyle.BORDER, 0, Color.TRANSPARENT, 0))
	return rule


# ---------------------------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------------------------

func _open_app(id: String) -> void:
	if not _panels.has(id):
		return
	_active_id = id
	_overview.visible = false
	for key: String in _panels:
		(_panels[key] as ServicePanel).visible = key == id
	_launcher.set_active(id)
	if PlayerServices.is_available():
		(_panels[id] as ServicePanel).refresh()


func _go_home() -> void:
	_active_id = ""
	for key: String in _panels:
		(_panels[key] as ServicePanel).visible = false
	_overview.visible = true
	_launcher.set_active("")
	if PlayerServices.is_available():
		_overview.refresh()


## A mutation landed somewhere: refresh the visible app, or the overview, as fits.
func _on_services_changed(area: String) -> void:
	if not _built:
		return
	if _active_id == "":
		if _overview.visible:
			_overview.refresh()
		return
	if str(_areas.get(_active_id, "")) == area:
		(_panels[_active_id] as ServicePanel).refresh()


# ---------------------------------------------------------------------------------------------
# Screen contract (see ScreenZone)
# ---------------------------------------------------------------------------------------------

## True while a field of the visible screen holds the keyboard.
func is_typing() -> bool:
	if _active_id == "":
		return false
	var panel: ServicePanel = _panels.get(_active_id)
	return panel != null and panel.is_typing()


## Give the keyboard back to the game (Escape, or focus left).
func release_fields() -> void:
	for key: String in _panels:
		(_panels[key] as ServicePanel).release_fields()
