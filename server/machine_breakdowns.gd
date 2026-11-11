class_name MachineBreakdowns
extends RefCounted

## SERVER: which machines are broken (services ADR 0020). The simulator breaks a machine of a village and
## offers its repair as an ARES Machinery mission; the game server tells it which machines it has, makes
## the broken ones unusable, and says when a player repaired one.
##
## The machines are the ones carrying a MachineBreakdown (its group): each says its id and its kind.
## Asked by MissionHeartbeat, now and then.

## Machine uuid -> {"breakdown": String, "mission": String ("" until its mission is published)}.
static var _broken: Dictionary = {}
## Breakdown ids repaired here: not broken again by an answer the simulator made before it was told.
static var _repaired: Dictionary = {}
## Machine uuid -> when its restart ends (Time.get_ticks_msec): repaired, not working yet.
static var _restarting: Dictionary = {}


## Whether the machine [param machine_uuid] is broken down.
static func is_broken(machine_uuid: String) -> bool:
	return _broken.has(machine_uuid)


## Whether the machine [param machine_uuid], just repaired, is still restarting
## (MachineBreakdown.RESTART_S): it answers nothing yet.
static func is_restarting(machine_uuid: String, now_ms: int = Time.get_ticks_msec()) -> bool:
	if not _restarting.has(machine_uuid):
		return false
	if int(_restarting[machine_uuid]) > now_ms:
		return true
	_restarting.erase(machine_uuid)
	return false


## Tell the simulator the machines loaded in [param tree], planet by planet, and take its answer: the
## machines broken down. [param call] is the simulator's internal API: func(method, path, body) ->
## {ok, data | error}. A planet that does not answer keeps what was known. Returns how many are broken.
static func sync(call: Callable, tree: SceneTree) -> int:
	var listed: Dictionary = listing(tree.get_nodes_in_group(MachineBreakdown.GROUP))
	for scene: String in listed:
		var answer: Dictionary = await call.call(HTTPClient.METHOD_PUT, "/machines",
				{"scene": scene, "machines": listed[scene]})
		if not bool(answer.get("ok", false)):
			continue
		var ids: Array = (listed[scene] as Array).map(func(m: Dictionary) -> String: return str(m["id"]))
		_broken = merged(_broken, ids, broken_of(answer.get("data")), _repaired)
	return _broken.size()


## The machines of [param nodes] (MachineBreakdown) as the simulator takes them, by planet:
## {scene: [{id, kind, position}]}, the position from the planet's centre. One with no id yet or on no
## planet is left out.
static func listing(nodes: Array) -> Dictionary:
	var out: Dictionary = {}
	for node: Variant in nodes:
		var breakdown := node as MachineBreakdown
		var machine: Node3D = breakdown.host() if breakdown != null and breakdown.is_inside_tree() else null
		if machine == null:
			continue
		var planet := Planet.of(machine)
		var id := breakdown.machine_id()
		var kind := breakdown.kind
		if planet == null or planet.planet_data == null or id == "" or kind == "":
			continue
		var at: Vector3 = planet.to_local(machine.global_position)
		(out.get_or_add(str(planet.planet_data.planet_name), []) as Array).append(
				{"id": id, "kind": kind, "position": {"x": at.x, "y": at.y, "z": at.z}})
	return out


## The simulator's answer ([param data]: {broken: [{machineId, breakdownId, missionId}]}) as
## {machine uuid: {"breakdown", "mission"}}. Pure.
static func broken_of(data: Variant) -> Dictionary:
	var out: Dictionary = {}
	var rows: Variant = data.get("broken") if data is Dictionary else null
	if not (rows is Array):
		return out
	for row: Variant in rows:
		if not (row is Dictionary) or str(row.get("machineId", "")) == "" or str(row.get("breakdownId", "")) == "":
			continue
		var mission: Variant = row.get("missionId")
		out[str(row["machineId"])] = {"breakdown": str(row["breakdownId"]), "mission": str(mission) if mission != null else ""}
	return out


## [param known] after a planet answered: its machines listed ([param ids]) take the answer
## ([param answered], broken_of), the others keep what they had -- they stand on another planet, or
## sleep. A breakdown in [param repaired] is not taken back. Pure.
static func merged(known: Dictionary, ids: Array, answered: Dictionary, repaired: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for machine: String in known:
		if not ids.has(machine):
			out[machine] = known[machine]
	for machine: String in answered:
		if not repaired.has(str((answered[machine] as Dictionary).get("breakdown", ""))):
			out[machine] = answered[machine]
	return out


## The objective of [param objectives] (a mission's, the internal detail's) that has the machine
## [param machine_uuid] repaired and is not done: its id, "" when there is none. Pure.
static func repair_objective(objectives: Variant, machine_uuid: String) -> String:
	if not (objectives is Array) or machine_uuid == "":
		return ""
	for objective: Variant in objectives:
		if not (objective is Dictionary) or str(objective.get("status", "")) == "completed":
			continue
		var payload: Variant = objective.get("payload")
		if payload is Dictionary and str(payload.get("machineId", "")) == machine_uuid:
			return str(objective.get("id", ""))
	return ""


## The player [param player_id] has repaired the machine [param machine_uuid]: the mission's objective is
## confirmed (the mission service pays), the machine works again, and the simulator is told. Returns ""
## when done, else why not: NOT_BROKEN, NO_MISSION, NOT_YOURS (the repair is for who holds its mission),
## or a service's error code.
static func repair(machine_uuid: String, player_id: String) -> String:
	var entry: Dictionary = _broken.get(machine_uuid, {})
	if entry.is_empty():
		return "NOT_BROKEN"
	var mission_id := str(entry.get("mission", ""))
	if mission_id == "" or player_id == "":
		return "NO_MISSION"
	var detail: Dictionary = await MissionHeartbeat.mission_internal(HTTPClient.METHOD_GET,
			"/missions/%s" % mission_id.uri_encode(), null)
	if not bool(detail.get("ok", false)) or not (detail.get("data") is Dictionary):
		return str(detail.get("error", "NOT_FOUND"))
	var data: Dictionary = detail["data"]
	if not MissionTurnIn.holds_assignment(data.get("assignments", []), player_id):
		return "NOT_YOURS"
	var objective := repair_objective(data.get("objectives", []), machine_uuid)
	if objective == "":
		return "NO_MISSION"
	var done: Dictionary = await MissionHeartbeat.mission_internal(HTTPClient.METHOD_POST,
			"/missions/%s/objectives/%s/confirm" % [mission_id.uri_encode(), objective.uri_encode()], {})
	if not bool(done.get("ok", false)):
		return str(done.get("error", "ERROR"))
	var breakdown := str(entry.get("breakdown", ""))
	_repaired[breakdown] = true
	_broken.erase(machine_uuid)
	_restarting[machine_uuid] = Time.get_ticks_msec() + int(MachineBreakdown.RESTART_S * 1000.0)
	print("[Breakdown] machine %s repaired by %s" % [machine_uuid, player_id])
	# The mission is paid whatever this answers: a tick that reads it as done repairs the machine too.
	var told: Dictionary = await MissionHeartbeat.usim_internal(HTTPClient.METHOD_PUT,
			"/breakdowns/%s/repaired" % breakdown.uri_encode(), {"playerId": player_id})
	if not bool(told.get("ok", false)):
		push_warning("[Breakdown] the simulator was not told of the repair of %s: %s" % [machine_uuid, str(told.get("error", "ERROR"))])
	return ""
