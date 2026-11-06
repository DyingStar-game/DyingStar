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

const DEPOT_TYPE := "cargo_depot"


## [param crate] was just stored on [param shelf].
static func on_stored(crate: Node, shelf: Node) -> void:
	var depot_uuid := depot_uuid_of(shelf)
	var content: Variant = crate.get("content")
	if depot_uuid == "" or not (content is Dictionary) or (content as Dictionary).is_empty():
		return
	var c: Dictionary = (content as Dictionary).duplicate()
	if str(c.get("delivered_to", "")) == depot_uuid:
		return  # already counted in this warehouse (moved from the buffer rack to its shelf)
	var holder := str(c.get("carrier_id", c.get("miner_id", "")))
	var good := CrateContent.good_type(c)
	var units := int(c.get("units", 0))
	if holder != "" and good != "" and units > 0:
		MissionHeartbeat.drop_carried(holder, good, units, warehouse(depot_uuid))
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
		MissionHeartbeat.load_carried(carrier, good, units, warehouse(from))
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


static func warehouse(depot_uuid: String) -> Dictionary:
	return {"holderType": "warehouse", "holderId": depot_uuid}


## Set the crate's new content here and on every client (and in persistence).
static func _update(crate: Node, content: Dictionary) -> void:
	crate.set("content", content)
	var sync := PropSync.of(crate)
	if sync != null:
		sync.server_prop_update({"content": content})
