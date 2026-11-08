class_name TransportReservations
extends RefCounted

## SERVER: the crates a transport mission sends a player to fetch, kept for them (playtest 2026-11-08).
## A crate shelved in a warehouse is the warehouse's (WarehouseDelivery): nobody takes it off a shelf. A
## player who took a transport from that warehouse is let at enough crates of the good to cover what is
## left to deliver: they are marked `reserved_for` {mission, name, ids} (the taker and their partners),
## so the taker sees which ones on the depot's board (CargoDepot) and only they may take them. The marks
## are lifted when the mission is no longer held by anyone here.
##
## Every REFRESH_S: the live players' active missions are read from the mission service, each transport
## objective that loads from a warehouse (`via: warehouse`, its source a depot) is matched against the
## crates on that depot's shelves.

## How often (s) the reservations are brought up to date.
const REFRESH_S: float = 10.0

static var _next_ms: int = 0
static var _running: bool = false


## SERVER, from the server's loop: bring the reservations up to date every REFRESH_S.
static func tick(tree: SceneTree) -> void:
	if _running or Time.get_ticks_msec() < _next_ms:
		return
	_next_ms = Time.get_ticks_msec() + int(REFRESH_S * 1000.0)
	_running = true
	await _refresh(tree)
	_running = false


static func _refresh(tree: SceneTree) -> void:
	var wanted: Dictionary = {}  # mission id -> {"depot", "good", "kg", "name", "ids"}
	var checked: Dictionary = {}  # mission ids known, held or not, for the release
	var seen: Dictionary = {}
	for player: Node in tree.get_nodes_in_group("player"):
		if bool(player.get("is_npc")) or str(player.get("client_uuid")) == "":
			continue
		var player_id := str(player.get("client_uuid"))
		var result: Dictionary = await MissionHeartbeat.mission_internal(HTTPClient.METHOD_GET,
				"/players/%s/missions?limit=100" % player_id.uri_encode(), null)
		for row: Dictionary in ServiceTypes.mission_rows(result.get("data")):
			var mission_id := str((row.get("assignment") as Dictionary).get("missionId", "")) \
					if row.get("assignment") is Dictionary else ""
			if mission_id == "" or seen.has(mission_id):
				continue
			seen[mission_id] = true
			checked[mission_id] = true
			if not ServiceTypes.is_active_assignment(row.get("assignment")):
				continue
			var detail: Dictionary = await MissionHeartbeat.mission_internal(HTTPClient.METHOD_GET,
					"/missions/%s" % mission_id.uri_encode(), null)
			if bool(detail.get("ok", false)) and detail.get("data") is Dictionary:
				var need := await need_of(detail["data"])
				if not need.is_empty():
					wanted[mission_id] = need
	for depot: Node in live_depots(tree):
		apply(depot, wanted, checked)


## What a mission's detail asks of a warehouse: the first transport objective not done that loads from
## a depot — {"depot", "good", "kg" left to deliver, "name" of the taker, "ids" of the players holding
## it} — or {} for any other mission.
static func need_of(detail: Dictionary) -> Dictionary:
	var objectives: Array = detail.get("objectives") if detail.get("objectives") is Array else []
	for objective: Variant in objectives:
		if not (objective is Dictionary) or str(objective.get("type", "")) != "transport" \
				or str(objective.get("status", "")) == "completed":
			continue
		var params: Dictionary = objective.get("params") if objective.get("params") is Dictionary else {}
		if str(params.get("via", "")) != "warehouse":
			continue
		var depot := await _source_depot(objective, params)
		if depot == "":
			continue
		var ids: Array = []
		var name := ""
		var names: Dictionary = detail.get("players") if detail.get("players") is Dictionary else {}
		for assignment: Variant in detail.get("assignments", []):
			if assignment is Dictionary and ServiceTypes.is_active_assignment(assignment):
				var id := str(assignment.get("playerId", ""))
				ids.append(id)
				if name == "":
					name = str(names.get(id, id.substr(0, 8)))
		var left := ServiceTypes.num(objective.get("targetQuantity"), 1) - ServiceTypes.num(objective.get("currentProgress"), 0)
		if ids.is_empty() or left <= 0:
			return {}
		return {"depot": depot, "good": str(params.get("goodType", "")), "kg": float(left), "name": name, "ids": ids}
	return {}


## The depot a transport loads from: its source location's warehouse (universesimulator writes the depot's
## uuid there), else the depot behind its source POI (`metadata.persistence`).
static func _source_depot(objective: Dictionary, params: Dictionary) -> String:
	var from: Variant = objective.get("locationFrom")
	if from is Dictionary and str((from as Dictionary).get("warehouseId", "")) != "":
		return str((from as Dictionary).get("warehouseId"))
	var source: Variant = params.get("source")
	var poi_id := str((source as Dictionary).get("poiId", "")) if source is Dictionary else ""
	if poi_id == "":
		return ""
	var result: Dictionary = await MissionHeartbeat.inventory_internal(HTTPClient.METHOD_GET,
			"/pois/%s" % poi_id.uri_encode(), null)
	var poi: Variant = result.get("data") if bool(result.get("ok", false)) else null
	var metadata: Variant = (poi as Dictionary).get("metadata") if poi is Dictionary else null
	return str((metadata as Dictionary).get("persistence", "")) if metadata is Dictionary else ""


## Bring the marks on [param depot]'s shelved crates in line with [param wanted] (mission id -> need):
## lift those of missions [param checked] says are no longer held, then reserve, per need on this depot,
## crates of its good until their metal covers what is left (shelf order, the board's).
static func apply(depot: Node, wanted: Dictionary, checked: Dictionary) -> void:
	var depot_uuid := _uuid_of(depot)
	var crates: Array = crates_of(depot)
	var held_kg: Dictionary = {}
	for crate: Node in crates:
		var content: Dictionary = crate.get("content")
		var reserved: Variant = content.get("reserved_for")
		if not (reserved is Dictionary):
			continue
		var mission := str((reserved as Dictionary).get("mission", ""))
		var need: Dictionary = wanted.get(mission, {})
		var lift: bool = checked.has(mission) and (need.is_empty() or str(need["depot"]) != depot_uuid)
		if lift or (not need.is_empty() and float(held_kg.get(mission, 0.0)) >= float(need["kg"])):
			_mark(crate, {})
		else:
			held_kg[mission] = float(held_kg.get(mission, 0.0)) + CrateContent.metal_kg(content)
	for mission: String in wanted:
		var need: Dictionary = wanted[mission]
		if str(need["depot"]) != depot_uuid:
			continue
		for crate: Node in crates:
			if float(held_kg.get(mission, 0.0)) >= float(need["kg"]):
				break
			var content: Dictionary = crate.get("content")
			if content.get("reserved_for") is Dictionary or CrateContent.good_type(content) != str(need["good"]):
				continue
			_mark(crate, {"mission": mission, "name": need["name"], "ids": need["ids"]})
			held_kg[mission] = float(held_kg.get(mission, 0.0)) + CrateContent.metal_kg(content)


## The crates shelved in [param depot] (delivered there), in shelf-label order.
static func crates_of(depot: Node) -> Array:
	var depot_uuid := _uuid_of(depot)
	var out: Array = []
	for shelf: Node in depot.get_children():
		if not (shelf is Shelf):
			continue
		for crate: Node in shelf.get_children():
			var content: Variant = crate.get("content")
			if content is Dictionary and str((content as Dictionary).get("delivered_to", "")) == depot_uuid:
				out.append(crate)
	out.sort_custom(func(a: Node, b: Node) -> bool:
		return ShelfLabels.label_for(a.get_parent()) < ShelfLabels.label_for(b.get_parent()))
	return out


static func _mark(crate: Node, reservation: Dictionary) -> void:
	var c: Dictionary = (crate.get("content") as Dictionary).duplicate()
	if reservation.is_empty():
		if not c.has("reserved_for"):
			return
		c.erase("reserved_for")
	else:
		c["reserved_for"] = reservation
	WarehouseDelivery.update(crate, c)


## The cargo depots awake on this server (StockReconciler walks them too).
static func live_depots(tree: SceneTree) -> Array:
	var out: Array = []
	for list_type: String in NetworkOrchestrator.props_list:
		if list_type != WarehouseDelivery.DEPOT_TYPE:
			continue
		for node: Variant in NetworkOrchestrator.props_list[list_type].values():
			if is_instance_valid(node) and (node as Node).is_inside_tree():
				out.append(node)
	if out.is_empty():
		for node: Node in tree.get_nodes_in_group(&"cargo_depot"):
			out.append(node)
	return out


static func _uuid_of(node: Node) -> String:
	var sync := PropSync.of(node)
	return str(sync.uuid) if sync != null else ""
