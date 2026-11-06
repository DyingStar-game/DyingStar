class_name MissionTurnIn
extends RefCounted

## SERVER: turning a finished mission in at a town hall kiosk. A mission created with
## `autoComplete: false` waits there once its objectives are done: the mission service refuses the
## player's own "complete" (TURN_IN_AT_KIOSK), so the game server — which knows where the player
## stands — completes it under its service identity, only if:
##   - the player holds an active assignment of it;
##   - the kiosk stands in the village it delivers to: the cargo depot behind the warehouse of its
##     last warehouse objective (POI `metadata.persistence`) is within TURN_IN_RANGE_M of the kiosk.
## The outcome goes back to the screen (ScreenTarget.announce): {state: "turn_in_result", ok, error}.

## How far (m) the delivery village's cargo depot may stand from the kiosk: a village is a few hundred
## metres across, two villages are kilometres apart.
const TURN_IN_RANGE_M := 900.0
## The group every cargo depot joins (CargoDepot).
const DEPOTS_GROUP := &"cargo_depots"


## Turn [param mission_id] in for [param player] at [param kiosk]; the screen hears the outcome.
static func turn_in(kiosk: Node3D, player: Node, mission_id: String) -> void:
	var error := await _turn_in(kiosk, player, mission_id)
	print("[TurnIn] %s for %s at %s: %s" % [mission_id, player.get("client_uuid"), kiosk.name,
		"ok" if error == "" else error])
	ScreenTarget.announce(kiosk, player, {"state": "turn_in_result", "mission_id": mission_id,
		"ok": error == "", "error": error})


## "" when the mission was completed, else why not.
static func _turn_in(kiosk: Node3D, player: Node, mission_id: String) -> String:
	var player_id := str(player.get("client_uuid"))
	if mission_id == "" or player_id == "":
		return "INVALID"
	var detail := await MissionHeartbeat.mission_internal(HTTPClient.METHOD_GET, "/missions/%s" % mission_id.uri_encode(), null)
	if not bool(detail.get("ok", false)) or not (detail.get("data") is Dictionary):
		return str(detail.get("error", "NOT_FOUND"))
	var data: Dictionary = detail["data"]
	if not holds_assignment(data.get("assignments", []), player_id):
		return "NOT_YOURS"
	var poi_id := delivery_poi(data.get("objectives", []))
	if poi_id != "":
		var depot_uuid := await _warehouse_of_poi(poi_id)
		if not _depot_near(kiosk, depot_uuid):
			return "WRONG_TOWN_HALL"
	var done := await MissionHeartbeat.mission_internal(HTTPClient.METHOD_POST,
			"/missions/%s/complete" % mission_id.uri_encode(), {"playerId": player_id})
	return "" if bool(done.get("ok", false)) else str(done.get("error", "ERROR"))


## Whether [param assignments] (the internal detail's) hold an active one of [param player_id].
static func holds_assignment(assignments: Variant, player_id: String) -> bool:
	if not (assignments is Array):
		return false
	for a: Variant in assignments:
		if a is Dictionary and str(a.get("playerId", "")) == player_id and str(a.get("status", "")) == "active":
			return true
	return false


## The POI of the warehouse the mission delivers to: the zone of its last `via: warehouse` objective
## (by `order`), "" when it has none (a mission turned in at any town hall).
static func delivery_poi(objectives: Variant) -> String:
	var best := ""
	var best_order := -INF
	if not (objectives is Array):
		return ""
	for o: Variant in objectives:
		if not (o is Dictionary):
			continue
		var params: Variant = o.get("params")
		if not (params is Dictionary) or str(params.get("via", "")) != "warehouse":
			continue
		var zone: Variant = params.get("zone")
		var order := float(o.get("order", 0))
		if zone is Dictionary and str(zone.get("poiId", "")) != "" and order >= best_order:
			best = str(zone["poiId"])
			best_order = order
	return best


## The warehouse holder id (the cargo depot's uuid) behind [param poi_id], "" when unknown.
static func _warehouse_of_poi(poi_id: String) -> String:
	var result := await MissionHeartbeat.inventory_internal(HTTPClient.METHOD_POST, "/pois/resolve", {"ids": [poi_id]})
	var data: Variant = result.get("data")
	if not (data is Dictionary) or not (data.get("pois") is Array):
		return ""
	for poi: Variant in data["pois"]:
		var metadata: Variant = poi.get("metadata") if poi is Dictionary else null
		if metadata is Dictionary:
			return str(metadata.get("persistence", ""))
	return ""


## Whether the cargo depot [param depot_uuid] is loaded on this server, within TURN_IN_RANGE_M of
## [param kiosk].
static func _depot_near(kiosk: Node3D, depot_uuid: String) -> bool:
	if depot_uuid == "":
		return false
	for depot: Node in kiosk.get_tree().get_nodes_in_group(DEPOTS_GROUP):
		var sync := PropSync.of(depot)
		if sync != null and str(sync.uuid) == depot_uuid and depot is Node3D:
			return (depot as Node3D).global_position.distance_to(kiosk.global_position) <= TURN_IN_RANGE_M
	return false
