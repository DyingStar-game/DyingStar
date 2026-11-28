class_name MissionLocate
extends RefCounted

## Where a mission is shown on the star chart (F2): ONE answer for every screen that offers to locate a
## mission -- the kiosk's sheet and the DataPad's missions app -- so the two cannot disagree again.
## Each had its own reading, and each failed somewhere else: the kiosk found nothing for a hauling
## mission, the DataPad showed its destination while the step under way was loading at its source.
##
## The answer is a list of TARGETS in the order to try them: the places the step under way sends the
## player to first, then the steps after it, then the villages the mission is offered in. The chart
## shows the first one it can (StarMap.focus_mission_targets); a target it cannot show (a point the
## service does not hand out, a body it does not draw) gives way to the next one rather than to a toast.
##
## A target is {"why": what the place is for (WHY_*), "poi": an inventory point of interest's id,
## "machine": a repair's broken machine (MachineBreakdown.machine_id), "position": the place in metres
## from the centre of the body `scene` names, in that body's OWN frame (Planet.to_local, the frame every
## service place is in), "scene": that body's key, "name": what the place is called, "village": the
## village it is in}. Unknown keys are "" (Vector3.ZERO for the position), never missing. An empty
## `scene` is read by the chart as the body the player is on: a warehouse's location does not name its
## body (its `scenename` is the depot's scene file), and the federation that wrote the mission is there.
##
## Which key is a point of interest: `params.zone.poiId` and `params.source.poiId`, the mission service's
## documented places (docs/MISSION_PLACE_FRAME.md §1.3), and `locationTo.poiUuid` only when the params name
## none (a repair). A warehouse transport's `locationTo.poiUuid` is the WAREHOUSE's persistence uuid
## (universesimulator, publisher.rs `location()`), not a point of interest: asked for as one, the inventory
## service knew nothing of it, and every hauling mission ended on "cannot be shown" (playtest 2026-11-28).

## The place where a transport's goods are taken (its source warehouse).
const WHY_LOAD := "load"
## The place where an objective is judged: a delivery's warehouse, a player mission's destination.
const WHY_DELIVER := "deliver"
## An inspection's zone (the mission service's `visit`).
const WHY_VISIT := "visit"
## A repair: its broken machine, in its village.
const WHY_REPAIR := "repair"
## A village the mission is offered in (its `zones`): the last resort, the mission's own region.
const WHY_ZONE := "zone"


## What a "Locate" button hands the chart (PlayerServices.locate_requested): the [method targets] of
## [param mission] and [param objectives] (the mission service's), with the mission's id and the raw
## data they were read from, for the locate probe (LocateProbe). The raw data are references, not copies.
static func request(mission: Variant, objectives: Variant) -> Dictionary:
	var m: Dictionary = mission if mission is Dictionary else {}
	return {
		"mission_id": _text(m.get("id")),
		"targets": targets(mission, objectives),
		"mission": m,
		"objectives": objectives if objectives is Array else [],
	}


## Every place [param mission] can be shown at, the one to try first first: the objectives not done
## yet in their order, each its own (objective_targets), then the mission's poi zones. Each place once;
## [] when the mission names none. Pure.
static func targets(mission: Variant, objectives: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for objective: Variant in (objectives if objectives is Array else []):
		if objective is Dictionary and str((objective as Dictionary).get("status", "")) != "completed":
			for target: Dictionary in objective_targets(objective):
				_add(out, target)
	var zones: Variant = (mission as Dictionary).get("zones") if mission is Dictionary else null
	for zone: Variant in (zones if zones is Array else []):
		if zone is Dictionary and str((zone as Dictionary).get("kind", "")) == "poi":
			var z: Dictionary = zone
			_add(out, make(WHY_ZONE, _text(z.get("poiId")), "", Vector3.ZERO, _text(z.get("scene")),
					_text(z.get("poiName")), ""))
	return out


## The places of one objective, the one its step under way needs first: a transport whose goods are not
## loaded yet (is_loaded) starts at its source, then goes to where it is judged -- a repair's machine, an
## inspection's zone, a delivery's warehouse. Pure.
static func objective_targets(objective: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var params: Dictionary = _dict(objective.get("params"))
	var from: Dictionary = _dict(objective.get("locationFrom"))
	var to: Dictionary = _dict(objective.get("locationTo"))
	var payload: Dictionary = _dict(objective.get("payload"))
	var source_poi := _text(_dict(params.get("source")).get("poiId"))
	var zone_poi := _text(_dict(params.get("zone")).get("poiId"))
	if (source_poi != "" or not from.is_empty()) and not is_loaded(objective):
		_add(out, _at(WHY_LOAD, source_poi, "", from))
	var machine := _text(payload.get("machineId"))
	if machine == "":
		machine = _text(to.get("machineId"))
	# `locationTo.poiUuid` only when the params name no point: see the class's note on warehouses.
	var poi := zone_poi if zone_poi != "" or source_poi != "" else _text(to.get("poiUuid"))
	var why := WHY_DELIVER
	if machine != "":
		why = WHY_REPAIR
	elif str(objective.get("type", "")) == "visit":
		why = WHY_VISIT
	_add(out, _at(why, poi, machine, to))
	return out


## Whether a transport's goods have left its source: the whole quantity counted out of the warehouse
## (`state.loaded`, the mission service's count), else a first crate taken (`state.loadedAt`) or any
## delivered. The same reading as the step the DataPad ticks (ServiceTypes.transport_steps). Pure.
static func is_loaded(objective: Dictionary) -> bool:
	var target: int = ServiceTypes.num(objective.get("targetQuantity"), 0)
	var progress: int = ServiceTypes.num(objective.get("currentProgress"), 0)
	var state: Dictionary = _dict(objective.get("state"))
	if state.get("loaded") != null:
		return ServiceTypes.num(state.get("loaded"), 0) >= target or progress >= target
	return progress > 0 or state.get("loadedAt") != null


## A target, every key set (see the class's doc).
static func make(why: String, poi: String, machine: String, position: Vector3, scene: String,
		name: String, village: String) -> Dictionary:
	return {"why": why, "poi": poi, "machine": machine, "position": position, "scene": scene,
		"name": name, "village": village}


## Whether the chart has anything to go on in [param target]: a point, a machine, a position or a village.
static func is_showable(target: Dictionary) -> bool:
	return str(target.get("poi", "")) != "" or str(target.get("machine", "")) != "" \
			or not (target.get("position", Vector3.ZERO) as Vector3).is_zero_approx() \
			or str(target.get("village", "")) != ""


## The name a mission's location carries ({village, name}, as the simulator writes it): "F0001 · CargoDepot_2",
## the village alone or the place alone when only one is known, "" when neither.
static func place_name(location: Variant) -> String:
	if not (location is Dictionary):
		return ""
	var village := _text((location as Dictionary).get("village"))
	var place := _text((location as Dictionary).get("name"))
	if village != "" and place != "" and village != place:
		return "%s · %s" % [village, place]
	return village if village != "" else place


## A mission location's `position` ({x, y, z}, metres from its body's centre), Vector3.ZERO when it has
## none or an incomplete one -- a place at the very centre of a body is no place to show.
static func position_of(location: Variant) -> Vector3:
	var at: Variant = (location as Dictionary).get("position") if location is Dictionary else null
	if not (at is Dictionary):
		return Vector3.ZERO
	for axis: String in ["x", "y", "z"]:
		var value: Variant = (at as Dictionary).get(axis)
		if not (value is float or value is int):
			return Vector3.ZERO
	return Vector3(float(at["x"]), float(at["y"]), float(at["z"]))


## The target [param why] at [param location] (a mission location), its point [param poi] and machine
## [param machine].
static func _at(why: String, poi: String, machine: String, location: Dictionary) -> Dictionary:
	return make(why, poi, machine, position_of(location), _text(location.get("scene")), place_name(location),
			_text(location.get("village")))


## Append [param target] to [param out] unless it names nothing or a place already in it: a repair's
## village is also the zone it is offered in, and trying it twice would only wait twice.
static func _add(out: Array[Dictionary], target: Dictionary) -> void:
	if not is_showable(target):
		return
	for known: Dictionary in out:
		if _same_place(known, target):
			return
	out.append(target)


## Whether [param candidate] adds nothing to [param known]: no other machine, and the same point, the same
## position, or the same village with nothing more precise.
static func _same_place(known: Dictionary, candidate: Dictionary) -> bool:
	if candidate["machine"] != "" and candidate["machine"] != known["machine"]:
		return false
	if candidate["poi"] != "" and candidate["poi"] == known["poi"]:
		return true
	var at: Vector3 = candidate["position"]
	if not at.is_zero_approx() and at.is_equal_approx(known["position"]):
		return true
	return candidate["poi"] == "" and at.is_zero_approx() and candidate["village"] != "" \
			and candidate["village"] == known["village"]


static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


## [param value] as text, "" for null (str(null) is "<null>").
static func _text(value: Variant) -> String:
	return "" if value == null else str(value)
