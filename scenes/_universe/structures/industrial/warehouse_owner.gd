class_name WarehouseOwner
extends RefCounted

## SERVER: who owns a cargo depot, and so every crate shelved in it (playtest 2026-11-08: a crate put in a
## warehouse becomes the property of whoever holds the building). A warehouse belongs to its village, and
## the village to a corporation (the team, 2026-11-08): the owner is the village's, read from the
## village's POI in service-inventory (its `metadata.persistence` is the village's uuid), else the
## warehouse's own POI, else ARES -- which holds every village for now (ddurieux: an owner property on
## buildings comes with base building). Asked once per depot, then kept.

## The network type of a village (PoiVillages), to find the depot's by its uuid.
const VILLAGE_TYPE := "poi_village"

## Depot uuid -> {"type", "id", "name", "village"}.
static var _known: Dictionary = {}


## The owner of [param depot] (a CargoDepot): {"type": "political" | "corporation" | ..., "id", "name",
## "village": the village's name} -- ARES (CrateContent.OWNER_ARES) when no POI says otherwise.
static func owner_of(depot: Node) -> Dictionary:
	var depot_uuid := _uuid_of(depot)
	if _known.has(depot_uuid):
		return _known[depot_uuid]
	var village_uuid := str(depot.get("poi_uuid")) if depot != null and depot.get("poi_uuid") != null else ""
	var owner := {"type": "political", "id": "", "name": CrateContent.OWNER_ARES}
	var known := false
	for persistence: String in [village_uuid, depot_uuid]:
		if persistence == "":
			continue
		var result: Dictionary = await MissionHeartbeat.inventory_internal(HTTPClient.METHOD_GET,
				"/pois/by-persistence/%s" % persistence.uri_encode(), null)
		var poi: Variant = result.get("data") if bool(result.get("ok", false)) else null
		if poi is Dictionary:
			owner = owner_from_poi(poi)
			known = true
			break
	owner["village"] = village_name(village_uuid)
	if known:
		_known[depot_uuid] = owner
	return owner


## The owner a POI names: a corporation by its id until its name can be read from social; anything else
## (a federation, a POI made by hand for a test) is ARES, the one federation there is.
static func owner_from_poi(poi: Dictionary) -> Dictionary:
	var type := str(poi.get("ownerType", "political"))
	var id := str(poi.get("ownerId", ""))
	if type == "corporation":
		return {"type": type, "id": id, "name": id.substr(0, 8)}
	return {"type": "political", "id": id if type == "political" else "", "name": CrateContent.OWNER_ARES}


## How a crate's plate names its owner: the owner, and the village whose warehouse holds it
## ("ARES CORP. · M0001").
static func plate_owner(owner: Dictionary) -> String:
	var village := str(owner.get("village", ""))
	var name := str(owner.get("name", CrateContent.OWNER_ARES))
	return name if village == "" else "%s · %s" % [name, village]


## The name of the village [param village_uuid] ("M0001"), "" when it is not loaded here.
static func village_name(village_uuid: String) -> String:
	var agent: Variant = NetworkOrchestrator.network_agent
	var lists: Variant = agent.get("props_list") if agent != null else null
	if village_uuid == "" or not (lists is Dictionary) or not (lists as Dictionary).has(VILLAGE_TYPE):
		return ""
	var village: Variant = (lists as Dictionary)[VILLAGE_TYPE].get(village_uuid)
	return str((village as Node).name) if is_instance_valid(village) else ""


static func _uuid_of(node: Node) -> String:
	var sync := PropSync.of(node) if node != null else null
	return str(sync.uuid) if sync != null else ""
