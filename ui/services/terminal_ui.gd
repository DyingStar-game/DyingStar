class_name TerminalUI
extends CanvasLayer

## The player's tablet (A.R.E.S. OS): the open app's header and tabs, a content panel with the app's
## action column beside it, and a rail of app tabs along the bottom (the A.R.E.S. OS mock-up,
## 2026-11). Built in code and styled through [ServiceStyle]; no scene, no shared theme.
##
## The rail carries the overview, the apps, the star chart (NAVIGATION: the chart's face is hosted in
## the content panel, see [method navigation_slot]) and PLUS, the app that holds the rest. The right-hand column is the
## segment's action half: panels build their forms and buttons into [member ServicePanel.side_slot]
## instead of stacking them under their lists, and a segment that is nothing but a form leaves the
## left card empty so the column takes the whole width.
##
## Like [StarMap] it is a full-screen [CanvasLayer] (its own layer, a full-rect Panel inside), opened
## with F3; while it is up the game is frozen and the mouse is free.

## The installed apps. `area` is the [signal PlayerServices.changed] key that
## app refreshes on.
const APPS: Array = [
	{"id": "identity", "title": "%%SVC_APP_IDENTITY", "area": "profile",
		"icon": ServiceAppIcon.Kind.IDENTITY, "path": "res://ui/services/profile_panel.gd"},
	{"id": "social", "title": "%%SVC_APP_SOCIAL", "area": "friends",
		"icon": ServiceAppIcon.Kind.CONTACTS, "path": "res://ui/services/social_panel.gd"},
	{"id": "economy", "title": "%%SVC_APP_ECONOMY", "area": "economy",
		"icon": ServiceAppIcon.Kind.BANK, "path": "res://ui/services/economy_panel.gd"},
	{"id": "properties", "title": "%%SVC_APP_PROPERTIES", "area": "inventory",
		"icon": ServiceAppIcon.Kind.INVENTORY, "path": "res://ui/services/properties_panel.gd"},
	{"id": "missions", "title": "%%SVC_APP_MISSIONS", "area": "missions",
		"icon": ServiceAppIcon.Kind.MISSIONS, "path": "res://ui/services/mission_panel.gd"},
	{"id": "plus", "title": "%%SVC_NAV_PLUS", "area": "reports",
		"icon": ServiceAppIcon.Kind.REPORTS, "path": "res://ui/services/plus_panel.gd"},
]

## The bottom bar, left to right. `app` is what the tab opens: an APPS id, `""` for the overview,
## and NAVIGATION for the star chart, drawn in the content panel (see [signal navigation_requested]).
const NAV: Array = [
	{"app": "", "title": "%%SVC_NAV_HOME"},
	{"app": "identity", "title": "%%SVC_NAV_PROFILE"},
	{"app": "economy", "title": "%%SVC_NAV_ECONOMY"},
	{"app": "properties", "title": "%%SVC_NAV_PROPERTIES"},
	{"app": "missions", "title": "%%SVC_NAV_MISSIONS"},
	{"app": NAVIGATION, "title": "%%SVC_NAV_NAVIGATION"},
	{"app": "social", "title": "%%SVC_NAV_SOCIAL"},
	{"app": "plus", "title": "%%SVC_NAV_PLUS"},
]

## The sections the PLUS app holds (plus_panel.gd): news about one of them lights the PLUS tab.
const PLUS_APPS: PackedStringArray = ["reports", "diagnostics"]
## A rail tab's width (px): the mock-up's fixed tiles, scaled to the tablet's 1920.
const NAV_TAB_WIDTH: float = 156.0
## The rail's height (px).
const RAIL_HEIGHT: float = 104.0

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
## A section wants the chart to name a place for it (a point of interest being created). Relayed
## from whichever app asked; PlayerClient opens the chart in placement mode and answers through
## [method set_placed]. The tablet never reaches for the chart itself.
signal placement_requested(radius_m: float)
## A section wants the chart to SHOW a place of the player's. Relayed from whichever app asked;
## PlayerClient opens the chart there and frames the point. The tablet never reaches for the chart
## itself.
##
## The app that asked is remembered, so the player comes back to the form they were filling in when
## they leave the chart's tab.
signal focus_poi_requested(poi_id: String)

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
## The header of the screens that are not apps (the overview, the chart): their title alone.
var _plain_header: Label = null
## The NAVIGATION tab's content: whatever is hosted in it (the chart's face), full card.
var _navigation: Control = null
var _clock: Label = null
## The open app id, NAVIGATION for the chart, or "" when the overview is showing.
var _active_id: String = ""
## The app that last asked the chart for a place, "" when none did.
##
## It is the whole answer to "who was asking": the place comes back to the form that opened the
## chart, and the forms are not interchangeable — the points of interest's form takes a place it
## was offered, and it is built before the mission builder's, so without this the builder's marker
## landed in the inventory instead of in the mission being written.
var _placement_asker: String = ""
## The app that asked the chart to show one of its points, and the segment to come back to.
##
## It is the same courtesy the place gets: a player who leaves the chart to look at a point was
## halfway through a form, and the tablet's home is not where they were.
var _focus_asker: String = ""
var _focus_segment: int = 0
var _built: bool = false
var _close_armed: bool = false
## The tablet was opened straight on NAVIGATION (F2, the chart's key): Escape then closes it, back to the
## game, instead of leaving the chart for the tablet's home (2026-10-11). Cleared as soon as the tab is left.
var _opened_for_navigation: bool = false
## Where the next open() lands instead of home (open_next), once.
var _next_open: Callable = Callable()


## One tab of the rail: a bare tile, amber while it is the one on show ([ServiceStyle.apply_nav]).
## Only the news light is drawn here.
class NavTab extends Button:
	## The light of a tab with news behind it (a notification not read there yet): green, blinking.
	const PENDING_COLOUR := Color(0.25, 1.0, 0.45)
	const PENDING_BLINK_HZ := 1.2
	var active: bool = false
	var pending: bool = false

	func set_active(value: bool) -> void:
		if active == value:
			return
		active = value
		ServiceStyle.apply_nav(self, active)
		queue_redraw()

	## Light the tab (news behind it) or put it out.
	func set_pending(value: bool) -> void:
		if pending == value:
			return
		pending = value
		set_process(value)
		queue_redraw()

	func _ready() -> void:
		set_process(pending)

	func _process(_delta: float) -> void:
		queue_redraw()  # the blink

	func _draw() -> void:
		if pending:
			var t := Time.get_ticks_msec() / 1000.0
			var alpha := 0.35 + 0.65 * (0.5 + 0.5 * sin(t * TAU * PENDING_BLINK_HZ))
			draw_circle(Vector2(size.x - 14.0, 14.0), 6.0, Color(PENDING_COLOUR, alpha))


## The apps with news not looked at yet (a notification about them): their tab blinks until opened.
var _pending: Dictionary = {}

## Some app has news (true), or none any more (false): the wrist's light follows.
signal pending_changed(any: bool)


## [param id] (an APPS id) has news: its tab of the bottom bar blinks until the player opens it.
func flag_app(id: String) -> void:
	if id in PLUS_APPS:
		id = "plus"
	if id == "" or _pending.has(id):
		return
	_pending[id] = true
	_show_pending()
	pending_changed.emit(true)


## Whether an app still has news the player has not opened.
func has_pending() -> bool:
	return not _pending.is_empty()


## The tab each pending app lights: its own, or PLUS for an app without one.
func _show_pending() -> void:
	var lit: Dictionary = {}
	for id: String in _pending:
		lit[id if _nav_tabs.has(id) else "plus"] = true
	for key: String in _nav_tabs:
		(_nav_tabs[key] as NavTab).set_pending(lit.has(key))


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
	_opened_for_navigation = false
	show()
	_go_home()
	if _next_open.is_valid():
		var then: Callable = _next_open
		_next_open = Callable()
		then.call()


## The next open() lands on [param then] (an app, a mission) instead of staying home, once. What a
## kiosk sets up: the mission just taken there is what the player opens the tablet to see.
func open_next(then: Callable) -> void:
	_next_open = then


## Open "My missions" on mission [param mission_id], its contract on show.
func open_mission(mission_id: String) -> void:
	_next_open = Callable()  # seen: the next open() goes home again
	open_app("missions")
	var panel: Variant = _panels.get("missions")
	if panel != null and panel.has_method("focus_mission"):
		panel.focus_mission(mission_id)


## Open on the NAVIGATION tab: the F2 of the chart, which lives there. Already on it, nothing moves
## (open() would go home first, closing the chart only to open it again).
func open_navigation() -> void:
	if GameOrchestrator.is_server():
		return
	_ensure_built()
	var was_open: bool = visible
	show()
	_show_navigation()
	if not was_open:
		_opened_for_navigation = true  # after _show_navigation, which leaves the tab it replaces


## The app on show (`missions`...), NAVIGATION for the chart, "" on the overview or closed.
func current_app() -> String:
	return _active_id if visible else ""


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
		elif _active_id == NAVIGATION and _opened_for_navigation:
			_close_armed = true  # came for the chart: back to the game, not to the tablet's home
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

	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 0)
	root.add_child(column)

	# Chrome: the open app's header and tabs, above the panels so they survive a form-only segment
	# (which hands the whole content panel to the action column).
	var chrome_margin := MarginContainer.new()
	chrome_margin.add_theme_constant_override("margin_left", 36)
	chrome_margin.add_theme_constant_override("margin_right", 36)
	chrome_margin.add_theme_constant_override("margin_top", 14)
	column.add_child(chrome_margin)
	var chrome := VBoxContainer.new()
	chrome.add_theme_constant_override("separation", 10)
	chrome.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chrome_margin.add_child(chrome)
	_chrome = chrome

	# The overview's and the chart's header: a title, as an app's header has.
	_plain_header = ServiceStyle.ares_label("", ServiceStyle.TEXT, ServiceStyle.SIZE_TITLE)
	_plain_header.custom_minimum_size = Vector2(0, 64)
	_plain_header.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chrome.add_child(_plain_header)

	# The two panels: what the app shows, and the column its actions live in.
	var panes_margin := MarginContainer.new()
	panes_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "right"]:
		panes_margin.add_theme_constant_override("margin_" + side, 36)
	panes_margin.add_theme_constant_override("margin_top", 24)
	panes_margin.add_theme_constant_override("margin_bottom", 28)
	column.add_child(panes_margin)
	var panes := HBoxContainer.new()
	panes.add_theme_constant_override("separation", 28)
	panes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panes_margin.add_child(panes)

	# The content area draws no frame of its own (the mock-up's `.content`): every page is a panel,
	# or lays out its panels itself. Only the action column is framed here.
	_main_card = PanelContainer.new()
	_main_card.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_main_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panes.add_child(_main_card)

	# The content: the overview, the chart's slot and every app overlap; one is visible at a time.
	_content = MarginContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_card.add_child(_content)

	_side_card = PanelContainer.new()
	ServiceStyle.apply_frame(_side_card)
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
	_overview.open_app_requested.connect(open_app_at)
	_overview.open_mission_requested.connect(open_mission)
	_content.add_child(_overview)

	# The chart's slot outlives a rebuild (a language change): the chart's face lives in it, and the
	# chart is PlayerClient's — freeing the slot freed the face, and F2 then opened nothing.
	if _navigation == null:
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
		tabs.add_theme_constant_override("separation", 10)
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
		panel.placement_requested.connect(_relay_placement.bind(id))
		panel.focus_poi_requested.connect(_relay_focus_poi.bind(id))
		panel.open_app_requested.connect(open_app_at)
		_content.add_child(panel)
		_panels[id] = panel
		_areas[id] = str(app["area"])

	column.add_child(_build_nav_bar())
	_start_clock()
	# The overview is what an opening shows: one panel, its title, no action column.
	_set_chrome("")
	_apply_pane_layout(true, false)


## Show one app's chrome (its header and tabs).
##
## The overview and the chart have no app header: they get the plain one, their title alone.
func _set_chrome(id: String) -> void:
	if _plain_header != null:
		_plain_header.visible = not _tab_slots.has(id)
		_plain_header.text = tr("%%SVC_NAV_NAVIGATION") if id == NAVIGATION else tr("%%SVC_NAV_HOME")
	for key: String in _tab_slots:
		(_tab_slots[key] as Control).visible = key == id


## The rail along the bottom: the tabs, then the clock and the brand they leave room for.
func _build_nav_bar() -> Control:
	var rail := PanelContainer.new()
	var box := ServiceStyle.flat(ServiceStyle.RAIL, 0, ServiceStyle.LINE, 0, 26.0, 0.0)
	box.border_width_top = 1
	box.corner_radius_bottom_left = 20
	box.corner_radius_bottom_right = 20
	rail.add_theme_stylebox_override("panel", box)
	rail.custom_minimum_size = Vector2(0, RAIL_HEIGHT)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	bar.alignment = BoxContainer.ALIGNMENT_BEGIN
	rail.add_child(bar)

	for tab: Dictionary in NAV:
		var app: String = str(tab["app"])
		var button := NavTab.new()
		button.text = tr(str(tab["title"])).to_upper()
		# A fixed tile, as the mock-up's, but never narrower than its own label.
		button.custom_minimum_size = Vector2(NAV_TAB_WIDTH, 68)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		button.clip_text = false
		ServiceStyle.apply_nav(button, app == _active_id)
		button.active = app == _active_id
		button.pressed.connect(_nav_to.bind(app))
		bar.add_child(button)
		_nav_tabs[app] = button
	_show_pending()

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_clock = ServiceStyle.ares_label("", ServiceStyle.TEXT, 30)
	_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_clock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(_clock)

	# The brand: the ARES mark in amber over the system's name and build, behind a hairline.
	var brand_box := PanelContainer.new()
	var edge := StyleBoxFlat.new()
	edge.bg_color = Color.TRANSPARENT
	edge.border_width_left = 1
	edge.border_color = ServiceStyle.LINE
	edge.content_margin_left = 20.0
	brand_box.add_theme_stylebox_override("panel", edge)
	brand_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var brand := VBoxContainer.new()
	brand.add_theme_constant_override("separation", 4)
	var logo := brand_logo()
	logo.modulate = ServiceStyle.ACCENT
	logo.size_flags_horizontal = Control.SIZE_SHRINK_END
	brand.add_child(logo)
	var version := ServiceStyle.label("A.R.E.S. OS · " + tr("%%SVC_FMT_VERSION") % _build_version(), ServiceStyle.HINT,
			ServiceStyle.SIZE_CAPTION)
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	brand.add_child(version)
	brand_box.add_child(brand)
	bar.add_child(brand_box)
	return rail


## The ARES wordmark, cropped to the mark inside the decal texture and shown white. Static: the wrist
## DataPad's own screen wears the same mark (WristDatapadModel).
static func brand_logo() -> Control:
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
	_clock.text = clock_text()


## The time the tablet shows, "HH:MM" on the system clock. Shared with the wrist DataPad's screen.
static func clock_text() -> String:
	var now := Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(now["hour"]), int(now["minute"])]


## The tablet is built in code, so unlike a scene it does not re-translate itself on a locale change
## (see [LanguageSettings]). Rebuild it from scratch and put the player back where they were.
func _on_language_changed(_language: String) -> void:
	if not _built:
		return
	var was_open: String = _active_id
	var was_visible: bool = visible
	if _active_id == NAVIGATION:
		_leave_navigation()
	if _navigation != null and _navigation.get_parent() != null:
		_navigation.get_parent().remove_child(_navigation)
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_panels.clear()
	_areas.clear()
	_side_slots.clear()
	_tab_slots.clear()
	_nav_tabs.clear()
	_overview = null
	_plain_header = null
	_chrome = null
	_main_card = null
	_side_card = null
	_content = null
	_clock = null
	_active_id = ""
	_close_armed = false
	_build()
	if _panels.has(was_open):
		_open_app(was_open)
	elif was_open == NAVIGATION:
		_show_navigation()
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
	else:
		_open_app(app)


## Light the tab of whatever is now on show.
func _set_nav_active(app: String) -> void:
	var lit: String = app
	for key: String in _nav_tabs:
		(_nav_tabs[key] as NavTab).set_active(key == lit)


## The chart's tab: one panel, its title, the slot shown — and the chart asked for, once the slot is up.
func _show_navigation() -> void:
	if _active_id == NAVIGATION:
		return
	_show_nothing()
	_active_id = NAVIGATION
	_navigation.visible = true
	_set_chrome(NAVIGATION)
	_set_nav_active(NAVIGATION)
	_apply_pane_layout(true, false)
	navigation_requested.emit()


## Hide every content (the overview, the apps, the chart's slot) before showing one.
func _show_nothing() -> void:
	_leave_navigation()
	_overview.visible = false
	for key: String in _panels:
		(_panels[key] as ServicePanel).visible = false
	for key: String in _side_slots:
		(_side_slots[key] as Control).visible = false


## Off the NAVIGATION tab, if that is where we were: the slot hidden, the chart told.
func _leave_navigation() -> void:
	_opened_for_navigation = false
	if _navigation != null:
		_navigation.visible = false
	if _active_id == NAVIGATION:
		_active_id = ""
		navigation_closed.emit()


func _open_app(id: String) -> void:
	if not _panels.has(id):
		return
	if id != _focus_asker:
		# The player chose an app of their own: whatever the chart was asked for is over, and the
		# tablet will not take them back to it later.
		_focus_asker = ""
	_show_nothing()
	_active_id = id
	(_panels[id] as ServicePanel).visible = true
	(_side_slots[id] as Control).visible = true
	_set_chrome(id)
	_set_nav_active(id)
	if _pending.erase(id):
		_show_pending()
		pending_changed.emit(has_pending())
	var panel := _panels[id] as ServicePanel
	_apply_pane_layout(panel.has_main_content(), panel.has_side_content())
	if PlayerServices.is_available():
		panel.refresh()


## Open [param id] and land on [param segment] of its tab bar. The entry point a notification
## uses to take the player where they can act on it — a friend request opens the contacts app on
## the requests tab, so the toast is a shortcut rather than a dead end. [param segment] < 0 leaves
## the app on whichever tab it was already showing.
func open_app(id: String, segment: int = -1) -> void:
	if not _built:
		_ensure_built()
	var held: int = PLUS_APPS.find(id)
	if held >= 0:
		id = "plus"
		segment = held
	show()
	_open_app(id)
	if segment >= 0 and _panels.has(id):
		(_panels[id] as ServicePanel).goto_segment(segment)


## Open [param id] on [param segment], and that segment's own tab [param sub] — a composed app's
## section (the economy's bank, the social's contacts) has tabs of its own. [param sub] < 0 leaves the
## tab as it is. What the home's shortcuts use: "friend requests" lands on Social › Contacts › Requests.
func open_app_at(id: String, segment: int, sub: int = -1) -> void:
	open_app(id, segment)
	if sub < 0 or not _panels.has(id):
		return
	var section: ServicePanel = (_panels[id] as ServicePanel).mounted_section()
	if section != null:
		section.goto_segment(sub)


## An app asked the chart for a place: remember which one, and pass the request on.
##
## The id comes with the request because the console is the only place that knows which app asked —
## the panels do not know their own id, and the chart is two shells away from the form.
func _relay_placement(radius_m: float, app_id: String) -> void:
	_placement_asker = app_id
	placement_requested.emit(radius_m)


## An app asked the chart to show one of its points: remember which one — so the player comes back
## to the form they were filling in — and pass the request on.
func _relay_focus_poi(poi_id: String, app_id: String) -> void:
	_focus_asker = app_id
	_focus_segment = (_panels[app_id] as ServicePanel).placement_segment() \
			if _panels.has(app_id) else 0
	focus_poi_requested.emit(poi_id)


## The chart named a place: hand it to the app that asked for one, and say which.
##
## The app that asked is the ONLY one that gets it. Which one asked is not a detail: the forms are
## not interchangeable, and the first that would "take" a place is not necessarily the one that
## wants it — the points of interest's form takes every place it is offered, and it is built before
## the mission builder's.
##
## When NO app asked — the player used the chart on its own, laying a marker for themselves — no
## form gets it either: the place is theirs, and the caller turns it into a point of interest of
## their own. Offering it around instead used to lose it, or to hand it to a builder that had not
## asked for anything.
##
## Returns the id of the app that took the place, or "" when none did.
func set_placed(place: Dictionary) -> String:
	if not _built:
		return ""
	var asker: String = _placement_asker
	_placement_asker = ""
	if asker != "" and _panels.has(asker):
		if (_panels[asker] as ServicePanel).set_placed(place):
			return asker
	return ""


## Open the app that took a place, on the segment that holds the form that asked for it.
##
## The segment is the app's own answer (see [method ServicePanel.placement_segment]): the mission
## builder's create form, the points of interest's own. The app's default segment is a list, and a
## player sent to a list has lost the thread of what they were doing.
func open_placed_app(app: String) -> void:
	if app == "" or not _panels.has(app):
		return
	open_app(app, (_panels[app] as ServicePanel).placement_segment())


func _go_home() -> void:
	_show_nothing()
	_active_id = ""
	_overview.visible = true
	_set_chrome("")
	_set_nav_active("")
	_apply_pane_layout(true, false)
	if PlayerServices.is_available():
		_overview.refresh()
	# The app that sent the player to the chart is where they go back to: they left a form halfway
	# through to look at a place, and the overview is not that form. An app the player picked
	# themselves wins over this — but then this is not called, they chose their own way out.
	_return_from_chart()


## Open the app that sent the player to the chart, on the segment it was left on.
##
## Does nothing when no app asked for the chart, or when the one that did has gone.
func _return_from_chart() -> void:
	if _focus_asker == "" or not _panels.has(_focus_asker):
		_focus_asker = ""
		return
	var app: String = _focus_asker
	var segment: int = _focus_segment
	_focus_asker = ""
	open_app(app, segment)


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
# Screen contract (see ScreenTarget)
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
