class_name MachineBreakdown
extends Node

## What makes a machine with a 3D screen able to break down (services ADR 0020): a crusher, a refinery,
## a dispenser, a vehicle terminal, a mission kiosk, a lift's call screen, a teleporter, a wall screen.
## The machine's script adds one in its _ready (attach) and nothing else: the breakdown is the
## simulator's, not the machine's.
##
## SERVER: the machine is listed to the simulator (MachineBreakdowns) and, while broken, its screen
## answers nothing but a repair (PlayerServer, "screen_state"). Repaired, it takes RESTART_S to restart
## and still answers nothing meanwhile.
## CLIENT: while broken (BrokenMachines, read from the simulator), the screen is covered by "BREAKDOWN /
## DIAGNOSE" and the machine sparks; the button (the prompt, on a screen that takes no click) opens the
## repair ON the screen (MachineRepair, GaugeRepairPanel), which the players around watch (ScreenLock's
## view). Repaired, the cover counts the restart down over scrolling code (BootLog). A machine that does more than answer its screen
## hears breakdown_changed(down) when it has such a method.

## CLIENT: what the screen shows of the breakdown.
enum Shown { WORKING, BROKEN, RESTARTING }

const GROUP := &"machine_breakdown"
const NODE_NAME := &"MachineBreakdown"
## The screen states of a repair: asked by the client, answered by the server.
const REPAIR_STATE := "repair"
const RESULT_STATE := "repair_result"
## How long (s) a repaired machine takes to restart: unusable meanwhile, its screen counting down.
const RESTART_S := 30.0
## How often (s) the countdown and its scrolling code are looked at.
const COUNTDOWN_CHECK_S := BootLog.LINE_S
## The cover's ink: the screens' warning orange.
const INK := Color(1.0, 0.55, 0.1)
const BACKGROUND := Color(0.04, 0.04, 0.05)
## The broken machine on the star chart (F2): a pictogram in the breakdown's colour, over everything,
## seen from MARKER_VIEW_M (m) up -- a repair mission names a village, the chart shows which machine.
const MARKER_ICON: Texture2D = preload("res://assets/textures/map_markers/workbench.png")
const MARKER_NAME := &"BreakdownMarker"
const MARKER_LABEL := "%%MAP_MARKER_BREAKDOWN"
const MARKER_VIEW_M := 10000.0

## What the machine is, a slug the simulator names in the mission's text (crusher, refinery, dispenser,
## terminal, kiosk, lift, teleporter, screen).
var kind: String = ""

var _id: String = ""
## CLIENT: what the cover shows now.
var _shown: Shown = Shown.WORKING
var _cover: Control = null
## CLIENT: where the cover is drawn, and whether the machine draws that screen itself (a wall screen).
var _viewport: SubViewport = null
var _own_screen: bool = false
## CLIENT: the cover's words (their title, their button on a screen that takes clicks), and the repair's
## panel that takes their place.
var _words: Control = null
var _title: Label = null
var _button: Button = null
## CLIENT: the code scrolling under the countdown while the machine restarts (BootLog).
var _boot: Label = null
var _panel: GaugeRepairPanel = null
var _sparks: MachineSparks = null
## CLIENT: the prompt a screen that takes no click is repaired from (RepairPrompt), while broken.
var _prompt: RepairPrompt = null
## CLIENT: the countdown's next look (s), the seconds and the lines of code it last wrote.
var _check_left: float = 0.0
var _counted: int = -1
var _scrolled: int = -1


## Make [param host] (a screen's owner: it has update_screen) a machine of [param machine_kind] that can
## break down. Null in the editor.
static func attach(host: Node3D, machine_kind: String) -> MachineBreakdown:
	if Engine.is_editor_hint() or host == null or machine_kind == "":
		return null
	var breakdown := MachineBreakdown.new()
	breakdown.name = NODE_NAME
	breakdown.kind = machine_kind
	host.add_child(breakdown)
	return breakdown


## The breakdown of [param host], null when it cannot break down.
static func of(host: Node) -> MachineBreakdown:
	return host.get_node_or_null(NodePath(NODE_NAME)) as MachineBreakdown if host != null else null


## The id the simulator knows a machine by, from the uuid of the networked object carrying it
## ([param networked_uuid]) and the path from that object to it ([param path]): the object's own uuid
## when the machine is the object, else one made of both -- a lift has several screens. Pure.
static func id_of(networked_uuid: String, path: String) -> String:
	if networked_uuid == "":
		return ""
	return networked_uuid if path == "." or path == "" else PropSpawn.stable_uuid("%s|%s" % [networked_uuid, path])


## The seconds a countdown shows for [param left] s to go: never 0 while anything is left. Pure.
static func seconds_shown(left: float) -> int:
	return maxi(ceili(left), 0)


func _ready() -> void:
	add_to_group(GROUP)
	set_process(false)
	if not GameOrchestrator.is_server():
		refresh.call_deferred()


## The machine itself.
func host() -> Node3D:
	return get_parent() as Node3D


## The machine's id for the simulator, "" while it is not inside anything networked.
func machine_id() -> String:
	if _id == "":
		var address: Dictionary = ScreenTarget.address_of(host())
		_id = id_of(str(address.get("target_uuid", "")), str(address.get("screen", "")))
	return _id


## Whether the machine is out of use: broken down, or restarting after its repair.
func is_broken() -> bool:
	var id := machine_id()
	if id == "":
		return false
	if GameOrchestrator.is_server():
		return MachineBreakdowns.is_broken(id) or MachineBreakdowns.is_restarting(id)
	return BrokenMachines.is_broken(id) or BrokenMachines.restart_left(id) > 0.0


## CLIENT: show the machine as it is now: broken, restarting or working. Called when the list of broken
## machines changes.
func refresh() -> void:
	if GameOrchestrator.is_server() or not is_inside_tree():
		return
	var now := _state()
	if now == _shown:
		return
	_shown = now
	var machine := host()
	var gui: Node3D = ScreenTarget.gui_of(machine)
	var broken := now == Shown.BROKEN
	if broken and _sparks == null:
		_sparks = MachineSparks.new()
		machine.add_child(_sparks)
		if gui != null:
			_sparks.position = machine.to_local(gui.global_position)
	if _sparks != null:
		_sparks.set_running(broken)
	_mark_on_chart(machine, broken)
	# A repair left on the screen (ours, or one watched) is over.
	if not broken and _panel != null and _panel.visible:
		_panel.close()
	_cover_screen(gui, now != Shown.WORKING)
	_write_words()
	_offer_prompt(broken)
	set_process(now == Shown.RESTARTING)
	if machine.has_method("breakdown_changed"):
		machine.breakdown_changed(now != Shown.WORKING)


## SERVER: [param player] says they repaired the machine. The answer goes to the screens around.
func server_repair(player: Node) -> void:
	var error: String = await MachineBreakdowns.repair(machine_id(), str(player.get("client_uuid")))
	# The services answered later: the player may have left, the machine streamed out.
	if is_inside_tree() and is_instance_valid(player):
		ScreenTarget.announce(host(), player, {"state": RESULT_STATE, "ok": error == "", "error": error})


## CLIENT: the server answered a repair of [param machine] ([param event]: {"ok", "error"}).
static func on_result(machine: Node, event: Dictionary) -> void:
	var breakdown := of(machine)
	if breakdown == null:
		return
	if bool(event.get("ok", false)):
		BrokenMachines.mark_repaired(breakdown.machine_id(), machine.get_tree())
	MachineRepair.result(breakdown, event)


# -- The repair, watched by the players around (ScreenLock's view contract) ----------------------------

## CLIENT: what stands for the view of [param screen_owner]'s screen while it is broken -- its repair,
## not the interface under the cover. Null when the machine is not broken.
static func view_of(screen_owner: Node) -> Node:
	var breakdown := of(screen_owner)
	return breakdown if breakdown != null and breakdown._shown == Shown.BROKEN and breakdown._cover != null else null


## CLIENT, the player repairing: what their repair shows (GaugeRepairPanel.view_state).
func view_state() -> Dictionary:
	return _panel.view_state() if _panel != null else {}


## CLIENT, a player watching: show the repair as the one repairing sees it.
func apply_view_state(view: Dictionary) -> void:
	var panel := repair_panel()
	if panel != null:
		panel.apply_view_state(view)


## CLIENT: nobody holds the screen any more (ScreenLock): a repair watched on it is over.
func screen_freed() -> void:
	if _panel != null and _panel.visible and _panel.watched:
		_panel.close()


## CLIENT: the repair's panel on this machine's screen, filling it over the cover; null when the screen
## is not covered.
func repair_panel() -> GaugeRepairPanel:
	if _cover == null or _words == null or _viewport == null:
		return null
	if _panel == null:
		_panel = GaugeRepairPanel.new()
		_cover.add_child(_panel)
		_panel.fit(Vector2(_viewport.size))
		_panel.visibility_changed.connect(_on_panel_shown)
	return _panel


func _process(delta: float) -> void:
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = COUNTDOWN_CHECK_S
	if _state() != Shown.RESTARTING:
		refresh()
	else:
		var left: float = BrokenMachines.restart_left(machine_id())
		if seconds_shown(left) != _counted or BootLog.lines_at(RESTART_S - left) != _scrolled:
			_write_words()


func _state() -> Shown:
	var id := machine_id()
	if id == "":
		return Shown.WORKING
	if BrokenMachines.is_broken(id):
		return Shown.BROKEN
	return Shown.RESTARTING if BrokenMachines.restart_left(id) > 0.0 else Shown.WORKING


## Put [param machine] on the star chart while it is broken ([param on]), take it off once repaired.
func _mark_on_chart(machine: Node3D, on: bool) -> void:
	var marker := machine.get_node_or_null(NodePath(MARKER_NAME)) as MapMarker
	if not on:
		if marker != null:
			marker.queue_free()
		return
	if marker != null:
		return
	machine.add_child(chart_marker())


## The star chart's marker of a broken machine. Static, for the tests.
static func chart_marker() -> MapMarker:
	var marker := MapMarker.new()
	marker.name = MARKER_NAME
	marker.icon = MARKER_ICON
	marker.label = MARKER_LABEL
	marker.icon_tint = INK
	marker.importance = 1
	marker.max_view_m = MARKER_VIEW_M
	marker.show_footprint = false
	marker.footprint_size = Vector3.ONE
	marker.groupable = false
	marker.on_top = true
	return marker


## Cover the machine's screen with the breakdown's, or take the cover off.
func _cover_screen(gui: Node3D, on: bool) -> void:
	var machine := host()
	if _viewport == null:
		# A screen that draws itself (WallScreen) says where; the others show a Gui3D's viewport.
		_own_screen = machine.has_method("breakdown_viewport")
		_viewport = machine.breakdown_viewport() if _own_screen \
				else (gui.get("node_viewport") as SubViewport if gui != null else null)
	if _viewport == null:
		return
	if on and _cover == null:
		_cover = _build_cover(_viewport.size, not _own_screen)
		_viewport.add_child(_cover)
	if _cover != null:
		_cover.visible = on
	# A panel closed while the cover was off left the words hidden.
	if on and _words != null:
		_words.visible = _panel == null or not _panel.visible
	_redraw()


## The cover's words for what is shown: the breakdown and its button, or the restart's countdown.
func _write_words() -> void:
	if _title == null:
		return
	var restarting := _shown == Shown.RESTARTING
	if restarting:
		var left: float = BrokenMachines.restart_left(machine_id())
		_counted = seconds_shown(left)
		_scrolled = BootLog.lines_at(RESTART_S - left)
		_title.text = TranslationServer.translate("%%MACHINE_RESTARTING").replace("%d", str(_counted))
		_boot.text = BootLog.text(_scrolled)
	else:
		_title.text = "%%MACHINE_BROKEN"
	_title.add_theme_color_override("font_color", BootLog.INK if restarting else INK)
	_boot.visible = restarting
	if _cover is ColorRect:
		(_cover as ColorRect).color = BootLog.BACKGROUND if restarting else BACKGROUND
	if _button != null:
		_button.visible = not restarting
	_redraw()


## One more picture of the screen. It renders only while seen (ADR 0027): a wall screen draws itself
## the next time it is, a Gui3D's viewport that is not live is asked for one frame.
func _redraw() -> void:
	if _viewport == null:
		return
	if _own_screen:
		if host().has_method("redraw"):
			host().redraw()
	elif _viewport.render_target_update_mode != SubViewport.UPDATE_WHEN_VISIBLE:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## A screen that takes no click (a wall screen) is repaired from a prompt in front of it, there only
## while it is broken.
func _offer_prompt(on: bool) -> void:
	var machine := host()
	if not machine.has_method("breakdown_prompt_size"):
		return
	if on and _prompt == null:
		_prompt = RepairPrompt.new()
		_prompt.setup(self, machine.breakdown_prompt_size())
		machine.add_child(_prompt)
	elif not on and _prompt != null:
		_prompt.queue_free()
		_prompt = null


## The cover: the breakdown's words and, when the screen takes clicks ([param clickable]), the button.
func _build_cover(screen_px: Vector2i, clickable: bool) -> Control:
	var cover := ColorRect.new()
	cover.color = BACKGROUND
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.mouse_filter = Control.MOUSE_FILTER_STOP  # what is under answers nothing
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	_words = column
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", int(screen_px.y * 0.06))
	cover.add_child(column)
	_title = Label.new()
	_title.text = "%%MACHINE_BROKEN"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.add_theme_font_override("font", AresBrand.font())
	_title.add_theme_font_size_override("font_size", maxi(12, int(screen_px.y * 0.075)))
	_title.add_theme_color_override("font_color", INK)
	column.add_child(_title)
	# The restart's code, under its countdown: as many lines as BootLog shows, whatever the screen.
	_boot = Label.new()
	_boot.visible = false
	_boot.clip_text = true
	_boot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_boot.custom_minimum_size = Vector2(screen_px.x * 0.9, 0.0)
	_boot.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_boot.add_theme_font_override("font", BootLog.font())
	_boot.add_theme_font_size_override("font_size", maxi(8, int(screen_px.y * 0.6 / (BootLog.ROWS * 1.3))))
	_boot.add_theme_color_override("font_color", BootLog.INK)
	column.add_child(_boot)
	if not clickable:
		return cover
	_button = Button.new()
	_button.text = "%%MACHINE_DIAGNOSE"
	_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_button.custom_minimum_size = Vector2(screen_px.x * 0.6, screen_px.y * 0.16)
	_button.add_theme_font_override("font", AresBrand.font())
	_button.add_theme_font_size_override("font_size", maxi(12, int(screen_px.y * 0.07)))
	_button.pressed.connect(_on_diagnose_pressed)
	column.add_child(_button)
	return cover


## The repair's panel came on the screen, or left it: the cover's words step aside for it, the prompt
## too, and a screen that takes no click takes the crosshair meanwhile.
func _on_panel_shown() -> void:
	var open: bool = _panel.visible
	if _words != null:
		_words.visible = not open
	if _prompt != null:
		_prompt.set_offered(not open)
	if host().has_method("set_interactive"):
		host().set_interactive(open)
	_redraw()


func _on_diagnose_pressed() -> void:
	print("[Repair] DIAGNOSE pressed on %s (%s)" % [machine_id(), kind])
	MachineRepair.open_for(self)
