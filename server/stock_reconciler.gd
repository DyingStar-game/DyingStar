class_name StockReconciler
extends RefCounted

## SERVER: keeps the crates on a cargo depot's shelves equal to its warehouse stock in service-inventory
## (the team, 2026-11-08: the physical crates are the truth). The stock moves by crates shelved or taken
## (WarehouseDelivery), and by the simulator's factories consuming: when the stock is a crate's worth below
## the crates, crates are taken off the shelves (never one kept for a transport); when it is a crate's worth
## above them -- a fresh world's initial stock -- crates appear, the stock being already there.
##
## Every REFRESH_S, on the depots awake on this server whose shelves are in: one read of the warehouse,
## then per good of the gold chain the crates are matched to it. A depot is left alone a cycle while a crate
## is being shelved or taken, and for WAKE_GRACE_S after it woke (its shelves and crates stream in).

const REFRESH_S := 30.0
## Seconds after a depot woke before it is reconciled.
const WAKE_GRACE_S := 20.0
## The network type of a hauling crate.
const CRATE_TYPE := "crate_container"
## The SpawnCatalog entry of the crate a warehouse is stocked with (CargoDepot.FILL_CATALOG_KEY too).
const CRATE_CATALOG_KEY := "hauling_box"

static var _next_ms: int = 0
static var _running: bool = false
## Depot node instance id -> ticks msec it was first seen awake.
static var _seen_ms: Dictionary = {}


## SERVER, from the server's loop: reconcile every REFRESH_S.
static func tick(tree: SceneTree) -> void:
	if _running or Time.get_ticks_msec() < _next_ms:
		return
	_next_ms = Time.get_ticks_msec() + int(REFRESH_S * 1000.0)
	_running = true
	var depots: Array = TransportReservations.live_depots(tree)
	var live: Dictionary = {}
	for depot: Node in depots:
		live[depot.get_instance_id()] = true
	for id: int in _seen_ms.keys():
		if not live.has(id):
			_seen_ms.erase(id)  # gone to sleep: its grace starts over when it wakes again
	for depot: Node in depots:
		if is_instance_valid(depot) and _settled(depot):
			await reconcile(depot)
	_running = false


static func _settled(depot: Node) -> bool:
	var id := depot.get_instance_id()
	if not _seen_ms.has(id):
		_seen_ms[id] = Time.get_ticks_msec()
	return Time.get_ticks_msec() - int(_seen_ms[id]) >= int(WAKE_GRACE_S * 1000.0) \
			and not _moving(depot)


## Whether a crate of [param depot] is being shelved or taken right now (its goods and its marks not yet
## agreeing): the stock and the crates may disagree for a moment.
static func _moving(depot: Node) -> bool:
	var depot_uuid := _uuid_of(depot)
	for shelf: Node in depot.get_children():
		if not (shelf is Shelf):
			continue
		for crate: Node in shelf.get_children():
			var content: Variant = crate.get("content")
			if not (content is Dictionary) or (content as Dictionary).is_empty():
				continue
			if crate.has_meta(WarehouseDelivery.DELIVERING_META) \
					or str((content as Dictionary).get("delivered_to", "")) != depot_uuid:
				return true
	return false


## Match [param depot]'s crates to its warehouse stock, good by good.
static func reconcile(depot: Node) -> void:
	var depot_uuid := _uuid_of(depot)
	var result: Dictionary = await MissionHeartbeat.inventory_internal(HTTPClient.METHOD_GET,
			"/holders/warehouse/%s" % depot_uuid.uri_encode(), null)
	if not bool(result.get("ok", false)) or not is_instance_valid(depot):
		return
	var stock := stock_of(result.get("data"))
	for good: String in [MissionHeartbeat.good_type_for_mineral(SpawnCatalog.TEST_MINERAL),
			CrateContent.INGOT_GOOD_PREFIX + SpawnCatalog.TEST_MINERAL]:
		var crates: Array = crates_of_good(depot, good)
		var sum := 0
		for crate: Node in crates:
			sum += int((crate.get("content") as Dictionary).get("units", 0))
		var per_crate := int(_new_content(good, {}).get("units", 0))
		var change := change_for(int(stock.get(good, 0)), sum, per_crate)
		if change < 0:
			_take(crates, -change, good, depot.name)
		elif change > 0:
			await _add(depot, good, change)


## The quantity of each good a warehouse holds, from service-inventory's holder view.
static func stock_of(view: Variant) -> Dictionary:
	var out: Dictionary = {}
	var stacks: Variant = (view as Dictionary).get("stacks") if view is Dictionary else null
	for stack: Variant in (stacks if stacks is Array else []):
		if stack is Dictionary:
			out[str(stack.get("goodType", ""))] = int(float(stack.get("quantity", 0)))
	return out


## How many crates to take (negative) or add (positive) so crates holding [param crate_units] in all match a
## stock of [param stock], each new crate worth [param per_crate]: only whole crates, and a crate is taken
## only when the stock is short of it by a whole crate -- what is left under a crate's worth stays as it is,
## so the two directions never fight. Pure, for the tests.
static func change_for(stock: int, crate_units: int, per_crate: int) -> int:
	if per_crate <= 0:
		return 0
	if crate_units - stock >= per_crate:
		return -int(float(crate_units - stock) / float(per_crate))
	if stock - crate_units >= per_crate:
		return int(float(stock - crate_units) / float(per_crate))
	return 0


## The shelved crates of [param good] in [param depot], those that may go first (not kept for a transport),
## last shelf first.
static func crates_of_good(depot: Node, good: String) -> Array:
	var out: Array = []
	for crate: Node in TransportReservations.crates_of(depot):
		if CrateContent.good_type(crate.get("content")) == good:
			out.append(crate)
	return out


## Take [param count] crates of [crates] off their shelves for good, never one kept for a transport.
static func _take(crates: Array, count: int, good: String, depot_name: String) -> void:
	var taken := 0
	for i: int in range(crates.size() - 1, -1, -1):
		if taken >= count:
			break
		var crate: Node = crates[i]
		if (crate.get("content") as Dictionary).get("reserved_for") is Dictionary:
			continue
		var shelf := crate.get_parent()
		if shelf != null and shelf.has_method("release_cargo"):
			shelf.release_cargo(crate)
		var uuid := _uuid_of(crate)
		crate.queue_free()
		if NetworkOrchestrator.network_agent != null and NetworkOrchestrator.network_agent.has_method("_on_prop_delete"):
			NetworkOrchestrator.network_agent._on_prop_delete(uuid, CRATE_TYPE)
		taken += 1
	print("[Stock] %s: %d crate(s) of %s taken off the shelves (consumed)" % [depot_name, taken, good])


## Put [param count] crates of [param good] on free slots of [param depot]'s shelves, as if delivered: the
## stock already holds their goods, so nothing is credited.
static func _add(depot: Node, good: String, count: int) -> void:
	var owner: Dictionary = await WarehouseOwner.owner_of(depot)
	if not is_instance_valid(depot):
		return
	var batch: Array = []
	for shelf: Node in depot.get_children():
		if batch.size() >= count:
			break
		if not (shelf is Shelf) or (shelf as Shelf).uuid == "" or ShelfLabels.label_for(shelf) == "":
			continue
		for idx: int in (shelf as Shelf).reserve_free_slots(count - batch.size()):
			batch.append(crate_spawn(shelf as Shelf, idx, _new_content(good, owner), _uuid_of(depot)))
	NetworkOrchestrator.spawn_props_authoritative(batch, false)
	print("[Stock] %s: %d crate(s) of %s put on the shelves (stock)" % [depot.name, batch.size(), good])


## The spawn of a crate holding [param content] on slot [param idx] of [param shelf], delivered to
## [param depot_uuid] (CargoDepot.server_stock_ore spawns its crates with it too).
static func crate_spawn(shelf: Shelf, idx: int, content: Dictionary, depot_uuid: String) -> Dictionary:
	var c := content.duplicate()
	c["delivered_to"] = depot_uuid
	var slot: Vector3 = shelf.shelf_slots[idx]
	var box: Dictionary = SpawnCatalog.entry(CRATE_CATALOG_KEY)
	return {
		"type": str(box["type"]),
		"uuid": UUID_UTIL.v4(),
		"position": {"x": slot.x, "y": slot.y, "z": slot.z},
		"rotation": {"x": 0.0, "y": Shelf.SLOT_YAW, "z": 0.0},
		"scenename": str(box["scene"]).trim_prefix("res://"),
		"parent_id": shelf.uuid,
		"content": c,
	}


## A crate of [param good] as the gold chain packs it (SpawnCatalog's test crate), its owner the warehouse's.
static func _new_content(good: String, owner: Dictionary) -> Dictionary:
	var kind := CrateContent.KIND_INGOT if good.begins_with(CrateContent.INGOT_GOOD_PREFIX) else CrateContent.KIND_CRUSHED
	var plate := WarehouseOwner.plate_owner(owner) if not owner.is_empty() else CrateContent.OWNER_ARES
	var content := SpawnCatalog.test_crate({"crate": kind}, "", plate)
	if not owner.is_empty():
		content["owner_type"] = str(owner.get("type", ""))
		content["owner_id"] = str(owner.get("id", ""))
	return content


static func _uuid_of(node: Node) -> String:
	var sync := PropSync.of(node) if node != null else null
	return str(sync.uuid) if sync != null else ""


const UUID_UTIL := preload("res://addons/uuid/uuid.gd")
