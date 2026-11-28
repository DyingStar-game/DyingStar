class_name LocateProbe
extends RefCounted

## A one-key probe of "Locate on the chart" (action debug_locate_probe, Alt+B, registered at run time,
## switched by Globals.ENABLED_DEV_TOOLS): what the mission said, what the chart made of it and where the
## camera ended, in every frame on the way. "Locate puts me on the other side of the planet" (playtest
## 2026-11-28) can be the data, the frame or the camera; this names which. A development tool: nothing in
## it is shown to a player, nothing to translate.
##
## Every locate request (the kiosk's sheet, the DataPad) is recorded while the tool is switched on, and
## nothing at all is kept while it is off. The key writes the last one into user://locate_probe/<stamp>.json
## (on Windows %APPDATA%\Godot\app_userdata\DyingStar\locate_probe\; the path is printed):
##   raw        the mission's zones and each objective's locationFrom / locationTo / params / payload / state;
##   targets    what MissionLocate made of them, in the order the chart tries them;
##   tries      each target the chart tried: why it failed, or the body it chose (key and index) and the
##              direction it framed in each frame (direction_facts) with the bases that turn one into the next;
##   after      the chart's camera once its travel ended, read the same way (StarMap.locate_probe_facts);
##   now        the same, read when the key is pressed, and the player's own place.
## A direction is "local" in the body's own frame (Planet.to_local, the frame of every service place),
## "drawn" on the chart's sphere (its basis: tilt and spin at the chart's clock), "world" turned by the live
## planet's global_basis. lon / lat are in DEGREES (HEALPix.vec2lonlat, Y up).

const ACTION := &"debug_locate_probe"
const DIR := "user://locate_probe"

## The last request and what the chart did with it; {} until one is made with the tool on.
static var _last: Dictionary = {}


## Whether the probe records and answers its key (Globals.ENABLED_DEV_TOOLS, like the other probes).
static func enabled() -> bool:
	return Globals.is_dev_tool_enabled(ACTION)


## Register the action (Alt+B: no game binding on B) when the tool is on and the project has none of that
## name: no project.godot edit for a debug key.
static func register_action() -> void:
	if not enabled() or InputMap.has_action(ACTION):
		return
	InputMap.add_action(ACTION)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_B
	key.alt_pressed = true
	InputMap.action_add_event(ACTION, key)


## Start a record for [param request] (MissionLocate.request). Nothing when the tool is off.
static func begin(request: Dictionary) -> void:
	if not enabled():
		return
	var mission: Dictionary = request.get("mission") if request.get("mission") is Dictionary else {}
	_last = {
		"requested_at": Time.get_datetime_string_from_system(),
		"mission_id": str(request.get("mission_id", "")),
		"category": str(mission.get("category", "")),
		"title": str(mission.get("title", "")),
		"raw": raw_of(request),
		"targets": request.get("targets", []),
		"tries": [],
	}


## Add [param fact] to the tries of the record under way. Nothing when the tool is off or none is.
static func note_try(fact: Dictionary) -> void:
	if enabled() and not _last.is_empty():
		(_last["tries"] as Array).append(fact)


## Set [param key] of the record under way to [param value]. Nothing when the tool is off or none is.
static func note(key: String, value: Variant) -> void:
	if enabled() and not _last.is_empty():
		_last[key] = value


## Write the record, with [param now] (what is read at the key press), and answer the file's path; "" when
## nothing was asked for since the start or the file could not be written.
static func write(now: Dictionary) -> String:
	if _last.is_empty():
		print("[LocateProbe] no locate request recorded yet: press Locate on a mission first")
		return ""
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := "%s/%s.json" % [DIR, Time.get_datetime_string_from_system().replace(":", "-")]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[LocateProbe] cannot write %s" % path)
		return ""
	var record: Dictionary = _last.duplicate()
	record["written_at"] = Time.get_datetime_string_from_system()
	record["now"] = now
	file.store_string(JSON.stringify(DustSeaProbe.plain(record), "\t"))
	file.close()
	var shown := ProjectSettings.globalize_path(path)
	print("[LocateProbe] %s" % shown)
	return shown


## The mission's data a locate is read from, as the service sent them: its zones, and per objective the
## keys that name a place or say how far it went.
static func raw_of(request: Dictionary) -> Dictionary:
	var mission: Dictionary = request.get("mission") if request.get("mission") is Dictionary else {}
	var steps: Array = []
	for objective: Variant in (request.get("objectives") if request.get("objectives") is Array else []):
		if not (objective is Dictionary):
			continue
		var step := {}
		for key: String in ["id", "type", "status", "order", "targetQuantity", "currentProgress", "state",
				"locationFrom", "locationTo", "params", "payload"]:
			step[key] = (objective as Dictionary).get(key)
		steps.append(step)
	return {"zones": mission.get("zones"), "kind": mission.get("kind"), "objectives": steps}


## [param local_dir] (a direction in a body's own frame) in every frame the chart goes through: as given,
## turned onto the drawn sphere by [param drawn_basis], and onto the world by [param planet_basis] (the live
## planet's global_basis; null when the body is not loaded), with the lon / lat of the local one. Pure.
static func direction_facts(local_dir: Vector3, drawn_basis: Basis, planet_basis: Variant) -> Dictionary:
	if local_dir.is_zero_approx():
		return {}
	var local := local_dir.normalized()
	var out := {"local": local, "local_lonlat_deg": HEALPix.vec2lonlat(local),
		"drawn": (drawn_basis.orthonormalized() * local).normalized()}
	if planet_basis is Basis:
		out["world"] = ((planet_basis as Basis).orthonormalized() * local).normalized()
	return out


## [param basis] as JSON can hold it: its three axes, and its Euler angles in degrees.
static func basis_facts(basis: Basis) -> Dictionary:
	var unit := basis.orthonormalized()
	var euler := unit.get_euler()
	return {"x": unit.x, "y": unit.y, "z": unit.z,
		"euler_deg": Vector3(rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z))}


## The angle between two directions, in degrees; -1 when either is none. 180 is the other side of the body.
static func arc_deg(a: Vector3, b: Vector3) -> float:
	if a.is_zero_approx() or b.is_zero_approx():
		return -1.0
	return rad_to_deg(a.normalized().angle_to(b.normalized()))
