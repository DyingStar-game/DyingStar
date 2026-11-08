class_name WarehouseDelivery
extends RefCounted

## SERVER: what a hauling crate means to service-inventory when it is shelved in, or taken out of, a
## cargo depot. The depot IS the warehouse (holder `warehouse` = the depot's uuid, the id
## universesimulator gives its warehouses).
##   - Shelved (any shelf of the depot, the NPCs' buffer rack included): the goods leave whoever
##     carries them and land in the warehouse. Once per depot: the crate remembers it
##     (`delivered_to`), so the storekeeper moving it from the buffer rack to its shelf counts nothing.
##   - Taken off a shelf by its owner or a mission partner: the goods leave the warehouse into their
##     hands (`carrier_id`) — the load of a transport mission.
## The crate's `content` carries those marks, replicated and persisted with it (see CrateContent).
##
## A crate stays its miner's until it is shelved: a player may only deposit their OWN crates, or the
## crates of a player sharing one of their missions (the same mission id): anybody else's is left on
## the counter by the storekeepers, and counts nothing when shelved by hand (may_deposit).
## Shelved, it becomes the property of the depot's owner (WarehouseOwner): nobody takes it off a shelf
## but the storekeepers and the players it is reserved for, the takers of a transport mission from this
## depot and their partners (TransportReservations, `reserved_for`); they load it (become its carrier).
## Who deposits is the player who put the crate down (`dropped_by`, noted at every drop): the
## storekeeper who shelves it afterwards acts on their behalf.

const DEPOT_TYPE := "cargo_depot"
## Meta on a crate: the service id of the last player who put it down (server only).
const DROPPED_BY_META := &"dropped_by"
## Meta on a crate: {player id: may deposit it} — the mission service asked once per player.
const DEPOSIT_OK_META := &"deposit_ok"
## Meta on a crate: the depot it is being delivered to while the services answer (a second shelving
## meanwhile — the storekeeper's — must not deliver it twice).
const DELIVERING_META := &"delivering_to"


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


## Whether [param player_id] may deposit (or load) [param crate]: their own, a mission partner's, or a
## crate nobody owns (the admin fill). An unknown player (a crate already on the counter at boot)
## passes. The partner question is asked once per player and remembered on the crate.
static func may_deposit(crate: Node, player_id: String) -> bool:
	var content: Variant = crate.get("content") if crate != null else null
	var holder := CrateContent.holder_of(content) if content is Dictionary else ""
	if owns_or_unknown(holder, player_id):
		return true
	var known: Dictionary = crate.get_meta(DEPOSIT_OK_META, {})
	if known.has(player_id):
		return bool(known[player_id])
	var ok := await share_a_mission(holder, player_id)
	if is_instance_valid(crate):
		known[player_id] = ok
		crate.set_meta(DEPOSIT_OK_META, known)
	return ok


## The cases decided without asking anybody: nobody owns it, nobody is known, or it is theirs.
static func owns_or_unknown(holder: String, player_id: String) -> bool:
	return holder == "" or player_id == "" or holder == player_id


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
	for row: Dictionary in ServiceTypes.mission_rows(result.get("data")):
		if ServiceTypes.is_active_assignment(row.get("assignment")):
			ids.append(str(row["assignment"].get("missionId", "")))
	return ids


## [param crate] was just stored on [param shelf] by [param player] (a player or a storekeeper).
static func on_stored(crate: Node, shelf: Node, player: Node = null) -> void:
	var depot_uuid := depot_uuid_of(shelf)
	var content: Variant = crate.get("content")
	if depot_uuid == "" or not (content is Dictionary) or (content as Dictionary).is_empty():
		return
	if str((content as Dictionary).get("delivered_to", "")) == depot_uuid \
			or str(crate.get_meta(DELIVERING_META, "")) == depot_uuid:
		return  # counted, or being counted, in this warehouse (the storekeeper moving it on)
	crate.set_meta(DELIVERING_META, depot_uuid)
	var depositor := depositor_of(crate, player)
	var delivered := await _deliver(crate, shelf, depot_uuid, depositor)
	if is_instance_valid(crate):
		crate.remove_meta(DELIVERING_META)
	if not delivered:
		return
	var owner: Dictionary = await WarehouseOwner.owner_of(shelf.get_parent())
	if not is_instance_valid(crate):
		return
	var c: Dictionary = (crate.get("content") as Dictionary).duplicate()
	c["delivered_to"] = depot_uuid
	c.erase("carrier_id")
	c.erase("reserved_for")
	# The warehouse's now: its owner on the plate.
	c["owner"] = WarehouseOwner.plate_owner(owner)
	c["owner_type"] = str(owner.get("type", ""))
	c["owner_id"] = str(owner.get("id", ""))
	c["move_seq"] = int(c.get("move_seq", 0)) + 1
	update(crate, c)


## The goods of [param crate] into [param depot_uuid]'s stock: true when they are there.
static func _deliver(crate: Node, shelf: Node, depot_uuid: String, depositor: String) -> bool:
	if not await may_deposit(crate, depositor):
		print("[Warehouse] %s refused: %s may not deposit %s's crate" % [_crate_id(crate), depositor,
			CrateContent.holder_of(crate.get("content"))])
		return false
	# Still on that shelf once the mission service answered: taken back meanwhile, it is no delivery.
	if not is_instance_valid(crate) or crate.get_parent() != shelf:
		return false
	var c: Dictionary = crate.get("content")
	var holder := CrateContent.holder_of(c)
	var good := CrateContent.good_type(c)
	var units := int(c.get("units", 0))
	if holder == "" or good == "" or units <= 0:
		return true  # nothing anybody holds (the admin fill): shelved, nothing to move
	var ok: bool = await MissionHeartbeat.drop_carried(holder, good, units, warehouse(depot_uuid),
			move_key(c, _crate_id(crate), "drop", depot_uuid))
	print("[Warehouse] %d x %s from %s into %s: %s" % [units, good, holder, depot_uuid, "ok" if ok else "refused"])
	return ok and is_instance_valid(crate)


## [param crate] is being taken off [param shelf] by [param player], who may (may_take): the goods leave
## the warehouse into their hands — the load of their transport.
static func on_taken(crate: Node, shelf: Node, player: Node) -> void:
	if player == null or bool(player.get("is_npc")):
		return  # a storekeeper tidying the depot: the goods stay in the warehouse
	var content: Variant = crate.get("content")
	if not (content is Dictionary):
		return
	var from := str((content as Dictionary).get("delivered_to", ""))
	if from == "" or from != depot_uuid_of(shelf):
		return
	var carrier := str(player.get("client_uuid"))
	if carrier == "" or not may_take(crate, player):
		return
	var c: Dictionary = (crate.get("content") as Dictionary).duplicate()
	var good := CrateContent.good_type(c)
	var units := int(c.get("units", 0))
	if good == "" or units <= 0:
		return
	if not await MissionHeartbeat.load_carried(carrier, good, units, warehouse(from),
			move_key(c, _crate_id(crate), "load", from)):
		return  # the warehouse refused: the goods stay there, the crate stays the owner's
	print("[Warehouse] %d x %s from %s to %s" % [units, good, from, carrier])
	if not is_instance_valid(crate):
		return
	c["carrier_id"] = carrier
	c.erase("delivered_to")
	c.erase("reserved_for")
	c["move_seq"] = int(c.get("move_seq", 0)) + 1
	update(crate, c)


## Whether [param player] may take [param crate]: anything not shelved in a warehouse; a shelved one
## (the warehouse's) only for a storekeeper or the players it is reserved for (reserved_for.ids). Both
## sides answer it: the server for the grab, the client for the prompt (Player.horizon_id is the id
## the services know on both).
static func may_take(crate: Node, player: Node) -> bool:
	var content: Variant = crate.get("content") if crate != null else null
	if not (content is Dictionary) or str((content as Dictionary).get("delivered_to", "")) == "":
		return true
	if player == null or bool(player.get("is_npc")):
		return true
	var id := str(player.call("horizon_id")) if player.has_method("horizon_id") else str(player.get("client_uuid"))
	var reserved: Variant = (content as Dictionary).get("reserved_for")
	return reserved is Dictionary and id in ((reserved as Dictionary).get("ids", []) as Array)


## The uuid of the cargo depot [param shelf] belongs to, "" for a shelf anywhere else.
static func depot_uuid_of(shelf: Node) -> String:
	var depot := shelf.get_parent() if shelf != null else null
	var sync := PropSync.of(depot) if depot != null else null
	if sync == null or sync.type_name != DEPOT_TYPE:
		return ""
	return str(sync.uuid)


## The key of one move of a crate, the same however often it is sent: the crate, which way, which
## depot, and how many moves the crate has made ([code]move_seq[/code] in [param content]) — so the
## mission service counts a repeated report once, and the crate's next real move anew.
static func move_key(content: Dictionary, crate_id: String, direction: String, depot_uuid: String) -> String:
	return "%s:%s:%s:%d" % [crate_id, direction, depot_uuid, int(content.get("move_seq", 0))]


static func _crate_id(crate: Node) -> String:
	var sync := PropSync.of(crate)
	return str(sync.uuid) if sync != null else str(crate.name)


## The inventory holder of a warehouse: the cargo depot it is.
static func warehouse(depot_uuid: String) -> Dictionary:
	return {"holderType": "warehouse", "holderId": depot_uuid}


## Set the crate's new content here and on every client (and in persistence).
static func update(crate: Node, content: Dictionary) -> void:
	crate.set("content", content)
	var sync := PropSync.of(crate)
	if sync != null:
		sync.server_prop_update({"content": content})
