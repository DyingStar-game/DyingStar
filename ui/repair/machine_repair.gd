class_name MachineRepair
extends Node
## CLIENT, own player only: the diagnosis and repair of a broken machine (services ADR 0020). A machine's
## screen asks for it (open_for); the panel reads the fault, and when the player holds the machine's
## repair mission, has them align its gauges, then asks the server to restart the machine. The server
## checks the mission again and answers on the machine's screen (result).
##
## The panel (GaugeRepairPanel) is on the machine's own screen (MachineBreakdown.repair_panel).
##
## It also keeps the list of broken machines read (BrokenMachines), for every machine around to draw.

## How often the list of broken machines is read again (s).
const REFRESH_S := 30.0

## The one of the local player, for the machines' screens to reach. Kept while it lives, in the tree or
## not: the player is moved from a frame to another (a planet, a vehicle), which takes it out of the tree
## for a moment -- cleared on leaving the tree, the diagnosis never opened again (playtest 2026-11-11).
static var _current: MachineRepair = null

var _notify: Callable
## The machine being repaired, null when none.
var _machine: MachineBreakdown = null
## The panel in use, the machine's screen's. Null when none.
var _panel: GaugeRepairPanel = null
## What the players around were last told our panel shows, and the time left before it is looked at again.
var _shared_view: Dictionary = {}
var _share_in_s: float = 0.0


## [param notify] shows a line to the player: func(text, gain) -- gain when it is good news that pays (the
## repair done), which chimes once where the rest beeps until read.
func setup(notify: Callable) -> void:
	_notify = notify
	_current = self
	var timer := Timer.new()
	timer.wait_time = REFRESH_S
	timer.autostart = true
	timer.timeout.connect(func() -> void: BrokenMachines.refresh(get_tree()))
	add_child(timer)
	BrokenMachines.refresh(get_tree())


## While our diagnosis is on a machine's screen, what it shows goes to the server whenever it changes,
## for the players around to watch it (ScreenLock's view).
##
## PlayerClient shares the view of the screen under the crosshair (a Gui3D); a machine that draws its
## own wall screen is never that one, so its repair was told to nobody: the others kept reading
## "BREAKDOWN" while a player repaired in front of them (playtest 2026-11-12). The repair tells it
## itself, whatever the screen.
func _process(delta: float) -> void:
	if not is_open() or _panel.watched or not is_instance_valid(_machine):
		return
	_share_in_s -= delta
	if _share_in_s > 0.0:
		return
	_share_in_s = ScreenLock.CHECK_S
	_share(_machine.view_state())


## Tell the players around what our panel shows ([param view]), when it changed.
func _share(view: Dictionary) -> void:
	if view.is_empty() or view == _shared_view or not is_instance_valid(_machine):
		return
	var machine_host: Node3D = _machine.host()
	if ScreenTarget.address_of(machine_host).is_empty():
		return
	_shared_view = view
	ScreenTarget.send(machine_host, {"state": ScreenLock.STATE, "view": view})


## Whether a diagnosis is on a machine's screen.
func is_open() -> bool:
	return is_instance_valid(_panel) and _panel.visible


## The local player asks for the diagnosis of [param machine].
static func open_for(machine: MachineBreakdown) -> void:
	if not is_instance_valid(_current):
		push_warning("[Repair] no repair controller: the diagnosis cannot open")
		return
	_current._open(machine)


## The server answered a repair of [param machine] ([param event]: {"ok", "error"}): only the player
## whose dialog is on that machine is told.
static func result(machine: MachineBreakdown, event: Dictionary) -> void:
	if is_instance_valid(_current) and _current._machine == machine:
		_current._on_result(event)


## Whether [param objectives] (a mission's, the mission service's) have the machine [param machine_uuid]
## repaired, the job not done yet. Pure.
static func names_machine(objectives: Variant, machine_uuid: String) -> bool:
	if not (objectives is Array) or machine_uuid == "":
		return false
	for objective: Variant in objectives:
		if not (objective is Dictionary) or str(objective.get("status", "")) == "completed":
			continue
		var payload: Variant = objective.get("payload")
		if payload is Dictionary and str(payload.get("machineId", "")) == machine_uuid:
			return true
	return false


func _open(machine: MachineBreakdown) -> void:
	if machine == null:
		return
	_leave()  # a diagnosis left open on another machine
	_machine = machine
	_panel = machine.repair_panel()
	if _panel == null:
		push_warning("[Repair] %s has no screen to show its diagnosis on" % machine.machine_id())
		_machine = null
		return
	if not _panel.aligned.is_connected(_on_aligned):
		_panel.aligned.connect(_on_aligned)
		_panel.dismissed.connect(_on_dismissed)
	_panel.open()
	_shared_view = {}
	_share_in_s = 0.0
	# The screen is ours while we repair (ScreenLock): the players around watch, and a screen opened
	# from its prompt was not clicked yet.
	var machine_host: Node3D = machine.host()
	if not ScreenTarget.address_of(machine_host).is_empty() and not ScreenLock.is_mine(machine_host):
		ScreenTarget.send(machine_host, {"state": ScreenLock.STATE})
	print("[Repair] diagnosis of %s (%s)" % [machine.machine_id(), machine.kind])
	var machine_uuid := machine.machine_id()
	var holds: bool = await _holds_repair(machine_uuid)
	# The mission service answered later: the player may have closed the panel, or opened another.
	print("[Repair] %s: the player %s its repair mission" % [machine_uuid, "holds" if holds else "does not hold"])
	if _machine == machine and is_instance_valid(_panel) and _panel.visible:
		_panel.set_may_repair(holds, hash(machine_uuid) + int(Time.get_ticks_msec()))


## Whether one of the player's active missions has the machine [param machine_uuid] repaired.
func _holds_repair(machine_uuid: String) -> bool:
	var listed: Dictionary = await PlayerServices.my_missions("active", 50)
	if not bool(listed.get("ok", false)):
		return false
	for row: Dictionary in ServiceTypes.mission_rows(listed.get("data")):
		var mission: Variant = row.get("mission")
		# Only the missions that may be a repair are asked for in full (the list has no objectives).
		if not (mission is Dictionary) or str(mission.get("category", "")) != "divers":
			continue
		var detail: Dictionary = await PlayerServices.mission_get(str(mission.get("id", "")))
		var data: Variant = detail.get("data")
		if bool(detail.get("ok", false)) and data is Dictionary and names_machine(data.get("objectives"), machine_uuid):
			return true
	return false


## Close the panel in use, if any, and forget the machine.
func _leave() -> void:
	if is_instance_valid(_panel):
		_panel.close()
	_tell_closed()
	_panel = null
	_machine = null


func _on_dismissed() -> void:
	_tell_closed()
	_panel = null
	_machine = null


## Our diagnosis is over: the players watching it are told, so theirs closes too instead of staying on
## its last picture.
func _tell_closed() -> void:
	if not _shared_view.is_empty():
		_share({"repair": int(GaugeRepairPanel.Phase.CLOSED)})
	_shared_view = {}


func _on_aligned() -> void:
	if _machine == null or not is_instance_valid(_machine) or not is_instance_valid(_panel):
		_leave()
		return
	_panel.show_sent()
	ScreenTarget.send(_machine.host(), {"state": MachineBreakdown.REPAIR_STATE})


func _on_result(event: Dictionary) -> void:
	print("[Repair] the server answered: %s" % ("repaired" if bool(event.get("ok", false)) else str(event.get("error", "ERROR"))))
	_leave()
	if bool(event.get("ok", false)):
		_notify.call(TranslationServer.translate("%%REPAIR_DONE"), true)
		# The mission is paid: the DataPad and the chart read the missions again.
		PlayerServices.changed.emit("missions")
	else:
		_notify.call(TranslationServer.translate("%%REPAIR_FAILED") % str(event.get("error", "ERROR")), false)
