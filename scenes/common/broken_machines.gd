class_name BrokenMachines
extends RefCounted

## CLIENT: which machines are broken down (services ADR 0020), read from the simulator now and then
## (MachineRepair asks) -- a handful of ids for a whole planet. Read from the service and not replicated
## with each machine: most machines' network definitions carry no state of their own, and a breakdown is
## the simulator's, the same for every kind of machine. The server holds its own list and decides
## (MachineBreakdowns); this one only draws.

## Machine id -> true.
static var _ids: Dictionary = {}
## Machine id -> when its restart ends (Time.get_ticks_msec): repaired a moment ago, not working yet.
static var _restarting: Dictionary = {}


static func is_broken(machine_id: String) -> bool:
	return _ids.has(machine_id)


## How long (s) [param machine_id], just repaired, still takes to restart; 0 when it does not.
static func restart_left(machine_id: String, now_ms: int = Time.get_ticks_msec()) -> float:
	return maxf(float(int(_restarting.get(machine_id, 0)) - now_ms) / 1000.0, 0.0)


## The simulator's answer ([param data]: {items: [{machineId}]}) as {machine id: true}. Pure.
static func ids_of(data: Variant) -> Dictionary:
	var out: Dictionary = {}
	var items: Variant = data.get("items") if data is Dictionary else null
	if not (items is Array):
		return out
	for item: Variant in items:
		if item is Dictionary and str(item.get("machineId", "")) != "":
			out[str(item["machineId"])] = true
	return out


## Read the list again; the machines are drawn again when it changed. An unanswered call keeps what was
## known.
static func refresh(tree: SceneTree) -> void:
	var answer: Dictionary = await PlayerServices.broken_machines()
	if bool(answer.get("ok", false)) and tree != null:
		_take(ids_of(answer.get("data")), tree)


## The server said [param machine_id] is repaired: it restarts (MachineBreakdown.RESTART_S), drawn so
## at once, before the next reading.
static func mark_repaired(machine_id: String, tree: SceneTree, now_ms: int = Time.get_ticks_msec()) -> void:
	if machine_id == "":
		return
	_restarting[machine_id] = now_ms + int(MachineBreakdown.RESTART_S * 1000.0)
	_ids = _ids.duplicate()
	_ids.erase(machine_id)
	if tree != null:
		tree.call_group(MachineBreakdown.GROUP, &"refresh")


static func _take(ids: Dictionary, tree: SceneTree) -> void:
	if ids == _ids:
		return
	_ids = ids
	tree.call_group(MachineBreakdown.GROUP, &"refresh")
