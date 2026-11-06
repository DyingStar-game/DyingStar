class_name WarehouseDelivery
extends RefCounted

## SERVER: what a hauling crate means to service-inventory when it is shelved in, or taken out of, a
## cargo depot. The depot IS the warehouse (holder `warehouse` = the depot's uuid, the id
## universesimulator gives its warehouses).
##   - Shelved (any shelf of the depot, the NPCs' buffer rack included): the goods leave whoever
##     carries them and land in the warehouse. Once per depot: the crate remembers it
##     (`delivered_to`), so the storekeeper moving it from the buffer rack to its shelf counts nothing.
##   - Taken off a shelf by a player (not an NPC storekeeper): the goods leave the warehouse into the
##     player's hands (`carrier_id`) — the load of a transport mission.
## The crate's `content` carries both marks, replicated and persisted with it (see CrateContent).
##
## A crate stays its miner's: stealing one is pointless. A player may only deposit their OWN crates,
## or the crates of a player sharing one of their missions (the same mission id): anybody else's is
## left on the counter by the storekeepers, and counts nothing when shelved by hand (may_deposit).
## Who deposits is the player who put the crate down (`dropped_by`, noted at every drop): the
## storekeeper who shelves it afterwards acts on their behalf.

const DEPOT_TYPE := "cargo_depot"
## Meta on a crate: the service id of the last player who put it down (server only).
const DROPPED_BY_META := &"dropped_by"


## SERVER: [param player] just put [param item] down: they are who deposits it, whoever shelves it.
static func note_dropped_by(item: Node, player: Node) -> void:
	if item != null and player != null and not bool(player.get("is_npc")):
		item.set_meta(DROPPED_BY_META, str(player.get("client_uuid")))


## Who deposits [param crate] when [param player] shelves it: the player themselves, or for a
## storekeeper the player who put it on the counter. "" when unknown.
static func depositor_of(crate: Node, player: Node) -> String:
	if player != null and not bool(player.get("is_npc")):
		return str(player.get("client_uuid"))
	return str(crate.get_meta(DROPPED_BY_META, "")) if crate != null else ""


## Whether [param depositor] may deposit [param crate]: their own, a mission partner's, or a crate
## nobody owns (the admin fill). An unknown depositor (a crate already on the counter at boot) passes.
static func may_deposit(crate: Node, depositor: String) -> bool:
	var content: Variant = crate.get("content") if crate != null else null
	var holder := CrateContent.holder_of(content) if content is Dictionary else ""
	if holder == "" or depositor == "" or holder == depositor:
		return true
	return await share_a_mission(holder, depositor)


## Whether [param a] and [param b] both hold an active assignment of the same mission.
static func share_a_mission(a: String, b: String) -> bool:
	var of_a := await _active_mission_ids(a)
	if of_a.is_empty():
		return false
	for id: String in await _active_mission_ids(b):
		if of_a.has(id):
			return true
	return false


static func _active_mission_ids(player_id: String) -> Array:
	var result := await MissionHeartbeat.mission_internal(HTTPClient.METHOD_GET,
			"/players/%s/missions?limit=100" % player_id.uri_encode(), null)
	var ids: Array = []
	var data: Variant = result.get("data")
	var rows: Variant = data.get("missions") if data is Dictionary else null
	if rows is Array:
		for row: Variant in rows:
			var assignment: Variant = row.get("assignment") if row is Dictionary else null
			if assignment is Dictionary and str(assignment.get("status", "")) == "active":
				ids.append(str(assignment.get("missionId", "")))
	return ids


## [param crate] was just stored on [param shelf] by [param player] (a player or a storekeeper).
static func on_stored(crate: Node, shelf: Node, player: Node = null) -> void:
	var depot_uuid := depot_uuid_of(shelf)
	var content: Variant = crate.get("content")
	if depot_uuid == "" or not (content is Dictionary) or (content as Dictionary).is_empty():
		return
	if str((content as Dictionary).get("delivered_to", "")) == depot_uuid:
		return  # already counted in this warehouse (moved from the buffer rack to its shelf)
	var depositor := depositor_of(crate, player)
	if not await may_deposit(crate, depositor):
		print("[Warehouse] %s refused: %s may not deposit %s's crate" % [_crate_id(crate), depositor,
			CrateContent.holder_of(content)])
		return
	if not is_instance_valid(crate):
		return
	var c: Dictionary = (crate.get("content") as Dictionary).duplicate()
	var holder := CrateContent.holder_of(c)
	var good := CrateContent.good_type(c)
	var units := int(c.get("units", 0))
	if holder != "" and good != "" and units > 0:
		MissionHeartbeat.drop_carried(holder, good, units, warehouse(depot_uuid), move_key(crate, "drop"))
		print("[Warehouse] %d x %s from %s into %s" % [units, good, holder, depot_uuid])
	c["delivered_to"] = depot_uuid
	c.erase("carrier_id")
	_update(crate, c)


## [param crate] is being taken off [param shelf] by [param player].
static func on_taken(crate: Node, shelf: Node, player: Node) -> void:
	if player == null or bool(player.get("is_npc")):
		return  # a storekeeper tidying the depot: the goods stay in the warehouse
	var content: Variant = crate.get("content")
	if not (content is Dictionary):
		return
	var c: Dictionary = (content as Dictionary).duplicate()
	var from := str(c.get("delivered_to", ""))
	if from == "" or from != depot_uuid_of(shelf):
		return
	var carrier := str(player.get("client_uuid"))
	var good := CrateContent.good_type(c)
	var units := int(c.get("units", 0))
	if carrier != "" and good != "" and units > 0:
		MissionHeartbeat.load_carried(carrier, good, units, warehouse(from), move_key(crate, "load"))
		print("[Warehouse] %d x %s from %s to %s" % [units, good, from, carrier])
	c["carrier_id"] = carrier
	c.erase("delivered_to")
	_update(crate, c)


## The uuid of the cargo depot [param shelf] belongs to, "" for a shelf anywhere else.
static func depot_uuid_of(shelf: Node) -> String:
	var depot := shelf.get_parent() if shelf != null else null
	var sync := PropSync.of(depot) if depot != null else null
	if sync == null or sync.type_name != DEPOT_TYPE:
		return ""
	return str(sync.uuid)


## A key unique to this move of [param crate] ([param direction] now), so the mission service
## counts it once even if the call is retried.
static func move_key(crate: Node, direction: String) -> String:
	var sync := PropSync.of(crate)
	var id := str(sync.uuid) if sync != null else str(crate.get_instance_id())
	return "%s:%s:%d" % [id, direction, Time.get_ticks_usec()]


static func _crate_id(crate: Node) -> String:
	var sync := PropSync.of(crate)
	return str(sync.uuid) if sync != null else str(crate.name)


static func warehouse(depot_uuid: String) -> Dictionary:
	return {"holderType": "warehouse", "holderId": depot_uuid}


## Set the crate's new content here and on every client (and in persistence).
static func _update(crate: Node, content: Dictionary) -> void:
	crate.set("content", content)
	var sync := PropSync.of(crate)
	if sync != null:
		sync.server_prop_update({"content": content})
