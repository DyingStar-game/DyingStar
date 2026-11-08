class_name WarehouseOwner
extends RefCounted

## SERVER: who owns a cargo depot, and so every crate shelved in it (playtest 2026-11-08: a crate put in a
## warehouse becomes the property of the corporation holding the building). The owner is the one of
## the depot's warehouse POI in service-inventory (its `metadata.persistence` is the depot's uuid):
## universesimulator creates it for the federation (ARES); a corporation may own one later.
## Asked once per depot, then kept.

## Depot uuid -> {"type", "id", "name"}.
static var _known: Dictionary = {}


## The owner of [param depot_uuid]: {"type": "political" | "corporation" | ..., "id", "name"} — ARES
## (CrateContent.OWNER_ARES) when no POI says otherwise.
static func owner_of(depot_uuid: String) -> Dictionary:
	if _known.has(depot_uuid):
		return _known[depot_uuid]
	var owner := {"type": "political", "id": "", "name": CrateContent.OWNER_ARES}
	var result: Dictionary = await MissionHeartbeat.inventory_internal(HTTPClient.METHOD_GET,
			"/pois/by-persistence/%s" % depot_uuid.uri_encode(), null)
	var poi: Variant = result.get("data") if bool(result.get("ok", false)) else null
	if poi is Dictionary:
		owner = owner_from_poi(poi)
		_known[depot_uuid] = owner
	return owner


## The owner a warehouse POI names: a federation (political) is ARES, the one there is; anything else
## by its id until its name can be read from social.
static func owner_from_poi(poi: Dictionary) -> Dictionary:
	var type := str(poi.get("ownerType", "political"))
	var id := str(poi.get("ownerId", ""))
	var name := CrateContent.OWNER_ARES if type == "political" else id.substr(0, 8)
	return {"type": type, "id": id, "name": name}
