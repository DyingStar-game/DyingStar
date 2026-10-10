class_name TerminalUI
extends CanvasLayer

## The player's tablet: a content card, the open app's action column beside it, and a bar of app
## tabs along the bottom (the mockup in `ui interface.png`). Built in code and styled through
## [ServiceStyle]; no scene, no shared theme.
##
## The bar carries the six apps that fit a tab (home, profile, economy, inventory, missions,
## social, system), the star chart (NAVIGATION: the chart's face is hosted in the content card, see
## [method navigation_slot]) and the PLUS grid for the rest. The right-hand column is the
## segment's action half: panels build their forms and buttons into [member ServicePanel.side_slot]
## instead of stacking them under their lists, and a segment that is nothing but a form leaves the
## left card empty so the column takes the whole width.
##
## Like [StarMap] it is a full-screen [CanvasLayer] (its own layer, a full-rect Panel inside), opened
## with F3; while it is up the game is frozen and the mouse is free.

## The installed apps, in PLUS grid order. `area` is the [signal PlayerServices.changed] key that
## app refreshes on.
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
	{"id": "pois", "title": "%%SVC_APP_POIS", "area": "pois",
		"icon": ServiceAppIcon.Kind.POIS, "path": "res://ui/services/poi_panel.gd"},
	{"id": "market", "title": "%%SVC_APP_MARKET", "area": "market",
		"icon": ServiceAppIcon.Kind.MARKET, "path": "res://ui/services/market_panel.gd"},
	{"id": "reports", "title": "%%SVC_APP_REPORTS", "area": "reports",
		"icon": ServiceAppIcon.Kind.REPORTS, "path": "res://ui/services/reports_panel.gd"},
	{"id": "diagnostics", "title": "%%SVC_APP_DIAGNOSTICS", "area": "diagnostics",
		"icon": ServiceAppIcon.Kind.DIAGNOSTICS, "path": "res://ui/services/diagnostics_panel.gd"},
]

## The bottom bar, left to right. `app` is what the tab opens: an APPS id, `""` for the overview,
## `"plus"` for the grid of the apps with no tab of their own, and NAVIGATION for the star chart,
## drawn in the content card (see [signal navigation_requested]).
const NAV: Array = [
	{"app": "", "title": "%%SVC_NAV_HOME"},
	{"app": "identity", "title": "%%SVC_NAV_PROFILE"},
	{"app": "bank", "title": "%%SVC_NAV_ECONOMY"},
	{"app": "inventory", "title": "%%SVC_NAV_INVENTORY"},
	{"app": "missions", "title": "%%SVC_NAV_MISSIONS"},
	{"app": NAVIGATION, "title": "%%SVC_NAV_NAVIGATION"},
	{"app": "contacts", "title": "%%SVC_NAV_SOCIAL"},
	{"app": "diagnostics", "title": "%%SVC_NAV_SYSTEM"},
	{"app": "plus", "title": "%%SVC_NAV_PLUS"},
]

## The apps the bar has no room for: the PLUS grid, in the order they were on the old home rail.
const PLUS_APPS: PackedStringArray = ["squad", "corporations", "pois", "market", "reports"]

## The action column's width while the left card still has something to show beside it.
const SIDE_WIDTH: float = 400.0
## The tab that shows the star chart: not an app of APPS, a slot in the content card the chart's face
## is hosted in.
const NAVIGATION: String = "navigation"

## The lore's manufacturer mark (a white wordmark on transparent, see the ARES decal assets). Cropped
## to its own bounds and left white, so it reads as the tablet's brand at any size.
const ARES_LOGO := preload("res://assets/textures/decals/ares_logo/ares_logo_decal_alpha.png")
const ARES_LOGO_REGION := Rect2(51, 67, 416, 131)

## The NAVIGATION tab is on show: its slot ([method navigation_slot]) is visible and empty-handed.
## PlayerClient opens the chart hosted there — this file never reaches for [StarMap] itself.
signal navigation_requested
## The NAVIGATION tab is left (another tab, home, the tablet closed): PlayerClient closes the chart.
signal navigation_closed

var _overview: ServiceOverviewScreen = null
## id -> ServicePanel, and id -> the `area` its mutations announce on.
var _panels: Dictionary = {}
var _areas: Dictionary = {}
## id -> that app's action column (the right-hand half; one per app, never reparented).
var _side_slots: Dictionary = {}
## Bottom-bar tab id -> its button.
var _nav_tabs: Dictionary = {}
## id -> that app's chrome slot (its title bar and segment tabs).
var _tab_slots: Dictionary = {}
var _chrome: VBoxContainer = null
var _main_card: PanelContainer = null
var _side_card: PanelContainer = null
var _content: MarginContainer = null
var _plus: Control = null
## The NAVIGATION tab's content: whatever is hosted in it (the chart's face), full card.
var _navigation: Control = null
var _clock: Label = null
## The open app id, "plus" for the grid, or "" when the overview is showing.
var _active_id: String = ""
var _built: bool = false
var _close_armed: bool = false


## One tab of the bottom bar: a wide tile carrying the active app's amber corner mark, the mockup's
## flag on ECONOMIE. The style is [ServiceStyle.apply_nav]; only the flag is drawn here.
class NavTab extends Button:
	var active: bool = false

	func set_active(value: bool) -> void:
		if active == value:
			return
		active = value
		ServiceStyle.apply_nav(self, active)
		queue_redraw()

	func _draw() -> void:
		if not active:
			return
		# Inset from the corner so the mark sits inside the rounded tile rather than over its curve.
		var inset: float = 4.0
		var leg: float = minf(size.x, size.y) * 0.30
		var corner := Vector2(size.x - inset, inset)
		draw_colored_polygon(PackedVector2Array([
			Vector2(corner.x - leg, inset),
			corner,
			Vector2(corner.x, inset + leg),
		]), ServiceStyle.ACCENT)


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


## Open on the NAVIGATION tab: the F2 of the chart, which lives there. Already on it, nothing moves
## (open() would go home first, closing the chart only to open it again).
func open_navigation() -> void:
	if GameOrchestrator.is_server():
		return
	_ensure_built()
	show()
	_show_navigation()


func close() -> void:
	_close_armed = false
	release_fields()
	_leave_navigation()
	hide()


## The content card's slot of the NAVIGATION tab, for the chart's face to be hosted in.
func navigation_slot() -> Control:
	_ensure_built()
	return _navigation


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
		margin.add_theme_constant_override("margin_" + side, 20)
	root.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(column)

	# Chrome: the open app's title bar and segment tabs, above the cards so they survive a
	# form-only segment (which hands the whole content card to the action column).
	var chrome := VBoxContainer.new()
	chrome.add_theme_constant_override("separation", 8)
	chrome.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(chrome)
	_chrome = chrome

	# The two cards: what the app shows, and the column its actions live in.
	var panes := HBoxContainer.new()
	panes.add_theme_constant_override("separation", 16)
	panes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(panes)

	_main_card = PanelContainer.new()
	ServiceStyle.apply_frame(_main_card, 14.0)
	_main_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panes.add_child(_main_card)

	# The content: the overview, the PLUS grid and every app overlap; one is visible at a time.
	_content = MarginContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_card.add_child(_content)

	_side_card = PanelContainer.new()
	ServiceStyle.apply_frame(_side_card, 8.0)
	_side_card.custom_minimum_size = Vector2(SIDE_WIDTH, 0)
	_side_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panes.add_child(_side_card)

	var side_scroll := ScrollContainer.new()
	side_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_side_card.add_child(side_scroll)
	var side_host := VBoxContainer.new()
	side_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_scroll.add_child(side_host)

	_overview = ServiceOverviewScreen.new()
	_overview.setup()
	_overview.visible = false
	_content.add_child(_overview)

	_plus = _build_plus()
	_plus.visible = false
	_content.add_child(_plus)

	_navigation = Control.new()
	_navigation.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_navigation.visible = false
	_content.add_child(_navigation)

	# Every app gets its chrome slot and its column up front: the panel fills the slots it is handed
	# in _build, and the tablet only ever shows one of each — nothing is ever reparented.
	for app: Dictionary in APPS:
		var id: String = str(app["id"])
		var tabs := VBoxContainer.new()
		tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tabs.visible = false
		chrome.add_child(tabs)
		_tab_slots[id] = tabs

		var slot := VBoxContainer.new()
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.visible = false
		side_host.add_child(slot)
		_side_slots[id] = slot

		var script: GDScript = load(str(app["path"]))
		var panel: ServicePanel = script.new()
		panel.tab_slot = tabs
		panel.side_slot = slot
		panel.pane_layout.connect(_on_pane_layout.bind(panel))
		panel.visible = false
		panel.home_requested.connect(_go_home)
		_content.add_child(panel)
		_panels[id] = panel
		_areas[id] = str(app["area"])

	column.add_child(_build_nav_bar())
	_start_clock()
	# The overview is what an opening shows: one card, no chrome, no action column.
	_set_chrome("")
	_apply_pane_layout(true, false)


## Show one app's chrome, or none of it — the overview and the grid need no title bar of their own.
func _set_chrome(id: String) -> void:
	if _chrome != null:
		_chrome.visible = id != ""
	for key: String in _tab_slots:
		(_tab_slots[key] as Control).visible = key == id


## The grid of the apps with no tab of their own, opened by the PLUS tab.
func _build_plus() -> Control:
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 18)

	var heading := Label.new()
	heading.text = tr("%%SVC_LBL_MORE_APPS").to_upper()
	heading.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(heading, 13, true)
	page.add_child(heading)

	var grid := GridContainer.new()
	grid.columns = PLUS_APPS.size()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	for id: String in PLUS_APPS:
		for app: Dictionary in APPS:
			if str(app["id"]) != id:
				continue
			var tile := ServiceAppTile.new()
			tile.setup(id, tr(str(app["title"])), app["icon"])
			tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			# bind, not a lambda: the id has to be the one this tile was built for, whatever the
			# loop variable holds by the time the tile is pressed.
			tile.pressed.connect(_open_app.bind(id))
			grid.add_child(tile)
	page.add_child(grid)
	return page


## The bottom bar: the tabs, then the clock and the brand they leave room for.
func _build_nav_bar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	for tab: Dictionary in NAV:
		var app: String = str(tab["app"])
		var button := NavTab.new()
		button.text = tr(str(tab["title"])).to_upper()
		# No fixed width: a Button is at least its own label, and the tabs share whatever is left
		# once the clock and the brand have taken theirs — so the bar never pushes them off screen.
		button.custom_minimum_size = Vector2(0, 54)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ServiceStyle.apply_nav(button, app == _active_id)
		button.active = app == _active_id
		button.pressed.connect(_nav_to.bind(app))
		bar.add_child(button)
		_nav_tabs[app] = button

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_clock = Label.new()
	_clock.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(_clock, 26, true)
	_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(_clock)

	var brand := VBoxContainer.new()
	brand.add_theme_constant_override("separation", 0)
	brand.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var name := Label.new()
	name.text = "A.R.E.S. OS"
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	name.add_theme_color_override("font_color", ServiceStyle.TEXT)
	ServiceStyle.font_of(name, 14, true)
	brand.add_child(name)
	var version := Label.new()
	version.text = tr("%%SVC_FMT_VERSION") % _build_version()
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version.add_theme_color_override("font_color", ServiceStyle.MUTED)
	ServiceStyle.font_of(version, 12)
	brand.add_child(version)
	bar.add_child(brand)
	bar.add_child(_brand_logo())
	return bar


## The ARES wordmark, cropped to the mark inside the decal texture and shown white.
func _brand_logo() -> Control:
	var atlas := AtlasTexture.new()
	atlas.atlas = ARES_LOGO
	atlas.region = ARES_LOGO_REGION
	var logo := TextureRect.new()
	logo.texture = atlas
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.modulate = Color.WHITE
	logo.custom_minimum_size = Vector2(72, 26)
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return logo


## The build the brand block shows under its name (the project's own version string).
static func _build_version() -> String:
	var version: String = str(ProjectSettings.get_setting("application/config/version", ""))
	if version == "":
		version = "?"
	# An exported build also shows its own id (BuildInfo), to tell two builds of one version apart.
	if BuildInfo.build_id() != "":
		version += " · " + BuildInfo.build_id()
	return version


func _start_clock() -> void:
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_tick_clock)
	add_child(timer)
	_tick_clock()


func _tick_clock() -> void:
	if _clock == null:
		return
	var now := Time.get_time_dict_from_system()
	_clock.text = "%02d:%02d" % [int(now["hour"]), int(now["minute"])]


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
	_side_slots.clear()
	_tab_slots.clear()
	_nav_tabs.clear()
	_overview = null
	_plus = null
	_chrome = null
	_main_card = null
	_side_card = null
	_content = null
	_clock = null
	_active_id = ""
	_close_armed = false
	_build()
	if was_open != "" and (_panels.has(was_open) or was_open == "plus"):
		if was_open == "plus":
			_open_plus()
		else:
			_open_app(was_open)
	else:
		_go_home()
	visible = was_visible


# ---------------------------------------------------------------------------------------------
# Navigation (the bottom bar)
# ---------------------------------------------------------------------------------------------

## One tab of the bar: open what it stands for.
func _nav_to(app: String) -> void:
	if app == NAVIGATION:
		_show_navigation()
	elif app == "":
		_go_home()
	elif app == "plus":
		_open_plus()
	else:
		_open_app(app)


## Light the tab of whatever is now on show. An app opened from the grid has no tab of its own:
## the grid keeps the light — that is where the player came from, and where the rest wait.
func _set_nav_active(app: String) -> void:
	var lit: String = app if _nav_tabs.has(app) else "plus"
	for key: String in _nav_tabs:
		(_nav_tabs[key] as NavTab).set_active(key == lit)


## The chart's tab: one card, no chrome, the slot shown — and the chart asked for, once the slot is up.
func _show_navigation() -> void:
	if _active_id == NAVIGATION:
		return
	_show_nothing()
	_active_id = NAVIGATION
	_navigation.visible = true
	_set_chrome("")
	_set_nav_active(NAVIGATION)
	_apply_pane_layout(true, false)
	navigation_requested.emit()


## Hide every content (the overview, the grid, the apps, the chart's slot) before showing one.
func _show_nothing() -> void:
	_leave_navigation()
	_overview.visible = false
	if _plus != null:
		_plus.visible = false
	for key: String in _panels:
		(_panels[key] as ServicePanel).visible = false
	for key: String in _side_slots:
		(_side_slots[key] as Control).visible = false


## Off the NAVIGATION tab, if that is where we were: the slot hidden, the chart told.
func _leave_navigation() -> void:
	if _navigation != null:
		_navigation.visible = false
	if _active_id == NAVIGATION:
		_active_id = ""
		navigation_closed.emit()


func _open_app(id: String) -> void:
	if not _panels.has(id):
		return
	_show_nothing()
	_active_id = id
	(_panels[id] as ServicePanel).visible = true
	(_side_slots[id] as Control).visible = true
	_set_chrome(id)
	_set_nav_active(id)
	var panel := _panels[id] as ServicePanel
	_apply_pane_layout(panel.has_main_content(), panel.has_side_content())
	if PlayerServices.is_available():
		panel.refresh()


func _open_plus() -> void:
	_show_nothing()
	_active_id = "plus"
	if _plus != null:
		_plus.visible = true
	_set_chrome("")
	_set_nav_active("plus")
	_apply_pane_layout(true, false)


func _go_home() -> void:
	_show_nothing()
	_active_id = ""
	_overview.visible = true
	_set_chrome("")
	_set_nav_active("")
	_apply_pane_layout(true, false)
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
	if str(_areas.get(_active_id, "")) == area and _panels.has(_active_id):
		(_panels[_active_id] as ServicePanel).refresh()


# ---------------------------------------------------------------------------------------------
# The two cards
# ---------------------------------------------------------------------------------------------

## A panel told the tablet how the screen splits for the segment now on show. Only the app in
## charge is listened to — the others announce themselves while they are built.
func _on_pane_layout(has_main: bool, has_side: bool, panel: Node) -> void:
	if _active_id == "" or not _panels.has(_active_id):
		return
	if panel != _panels[_active_id]:
		return
	_apply_pane_layout(has_main, has_side)


## Draw the split: both cards, or the action column alone when the segment is nothing but a form
## (the form then takes the whole width rather than leaving an empty card beside it).
func _apply_pane_layout(has_main: bool, has_side: bool) -> void:
	if _side_card == null or _main_card == null:
		return
	_side_card.visible = has_side
	_main_card.visible = has_main or not has_side
	_side_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL \
			if has_side and not has_main else Control.SIZE_FILL


# ---------------------------------------------------------------------------------------------
# Screen contract (see ScreenZone)
# ---------------------------------------------------------------------------------------------

## True while a field of the visible screen holds the keyboard — an app's, or one of whatever is
## hosted in the NAVIGATION slot (the chart's search box), which is only known by its focus.
func is_typing() -> bool:
	if _hosted_field() != null:
		return true
	if _active_id == "" or not _panels.has(_active_id):
		return false
	var panel: ServicePanel = _panels[_active_id]
	return panel != null and panel.is_typing()


## Give the keyboard back to the game (Escape, or focus left).
func release_fields() -> void:
	for key: String in _panels:
		(_panels[key] as ServicePanel).release_fields()
	var hosted: Control = _hosted_field()
	if hosted != null:
		hosted.release_focus()


## The focused control inside the NAVIGATION slot, if the focus is there.
func _hosted_field() -> Control:
	if _navigation == null or not _navigation.visible or not is_inside_tree():
		return null
	var owner: Control = get_viewport().gui_get_focus_owner()
	return owner if owner != null and _navigation.is_ancestor_of(owner) else null
