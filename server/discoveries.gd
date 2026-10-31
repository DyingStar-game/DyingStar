class_name Discoveries
extends Node
## SERVER: who discovered a place first, and the name they propose for it (Discovery). Any kind of place goes
## through here: server.gd reports a player standing in a place ([method found]), PlayerServer a proposal
## ([method propose]).
##
## A discovery is created ONCE. A second create_object for the same uuid replaces the whole stored record (the
## persistence service does not merge a create), which would wipe a name ARES had approved; so nothing is
## created while this server may still be receiving its zone's objects (SETTLE_MS after it was given zones),
## and every later change is an update, which the persistence service merges.
##
## The discoverer also gets a POINT OF INTEREST of their own in service-inventory, private, on their star map,
## which they can share like any other: created with the discovery, named after the proposed name, and after
## the approved one by the admin panel. A service that does not answer never holds the discovery back: the
## point is tried again the next time the discoverer stands there (POI_RETRY_MS apart).

## How long after receiving zones (or booting) the objects of those zones may still be on their way (ms).
const SETTLE_MS := 20000
## Wait (ms) before asking service-inventory again for a discoverer's point of interest.
const POI_RETRY_MS := 60000
## The point's name until one is proposed, read by no player: the star map shows its own words for an
## uncharted place (metadata "uncharted", StarMapPoi.service_entry).
const UNCHARTED_POI_NAMES := {"cave": "Uncharted cave"}

## Hooks into the server, bound by server.gd (tests pass their own).
## func(uuid: String) -> Dictionary: the object data the server holds for that prop, {} when it has none.
var registry_data: Callable
## func(uuid: String, props: Dictionary, type: String): change a prop's fields, replicated and persisted.
var update_prop: Callable
## func(data: Dictionary): create a prop (see NetworkOrchestrator.spawn_prop_authoritative).
var spawn_prop: Callable
var now_ms: Callable = func() -> int: return Time.get_ticks_msec()
var now_unix: Callable = func() -> int: return int(Time.get_unix_time_from_system())

var _settled_at := 0
var _poi_retry_at: Dictionary = {}  # discovery uuid -> now_ms() before which the point is not asked again
var _poi_busy: Dictionary = {}  # discovery uuid -> true while its point is being created
var _inventory_url := ""
var _client: HttpClient = null


func _ready() -> void:
	_settled_at = int(now_ms.call()) + SETTLE_MS
	_inventory_url = _inventory_url_from_config()
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	_client = HttpClient.new(http)


## The server was given zones: Horizon sends their objects again, discoveries among them.
func zones_assigned() -> void:
	_settled_at = int(now_ms.call()) + SETTLE_MS


## The player [param player_id] ([param player_name]) stands in the place [param place_id] of kind [param kind],
## whose prop is [param place_uuid] on the body [param planet_name]; [param location] is where the place is for
## the services ({system, scene, x, y, z}, the body's frame). Called every sweep while they stay there: cheap
## once the discovery exists.
func found(player_id: String, player_name: String, kind: String, place_id: String, place_uuid: String,
		planet_name: String, location: Dictionary) -> void:
	if player_id == "" or place_id == "" or place_uuid == "":
		return
	var uuid := Discovery.uuid_for(kind, place_id)
	var known: Dictionary = registry_data.call(uuid)
	if not known.is_empty():
		if str(known.get("discoverer_id", "")) == player_id and str(known.get("poi_id", "")) == "":
			_ensure_poi(uuid, known, location)
		return
	if int(now_ms.call()) < _settled_at:
		return
	var data := Discovery.record(kind, place_id, place_uuid, planet_name, player_id, player_name,
			int(now_unix.call()))
	data.merge({"type": Discovery.TYPE, "uuid": uuid, "scenename": Discovery.SCENE, "parent_id": place_uuid,
		"position": {"x": 0.0, "y": 0.0, "z": 0.0}, "rotation": {"x": 0.0, "y": 0.0, "z": 0.0}})
	spawn_prop.call(data)
	print("[Discoveries] %s discovered %s %s" % [player_name, kind, place_id])
	_ensure_poi(uuid, data, location)


## The player [param player_id] proposes [param raw_name] for the discovery [param uuid]. Returns "" when it is
## now awaiting ARES, else why it was refused: the client checks the same rule first, so a refusal here is a
## stale or tampered client.
func propose(player_id: String, uuid: String, raw_name: String) -> String:
	var known: Dictionary = registry_data.call(uuid)
	if known.is_empty():
		return "unknown discovery"
	if str(known.get("discoverer_id", "")) != player_id:
		return "not its discoverer"
	if not Discovery.open_to_proposal(str(known.get("status", Discovery.UNNAMED))):
		return "a name is already %s" % str(known.get("status", ""))
	var name := PlaceNameRule.clean(raw_name)
	var error := PlaceNameRule.error_key(name)
	if error != "":
		return "invalid name (%s)" % error
	update_prop.call(uuid, {"proposed_name": name, "status": Discovery.PENDING,
		"proposed_at": int(now_unix.call()), "refusal_reason": ""}, Discovery.TYPE)
	_rename_poi(uuid, known, name)
	return ""


## The private point of interest of the discovery's discoverer, created once (see the class notes).
func _ensure_poi(uuid: String, data: Dictionary, location: Dictionary) -> void:
	if not _inventory_active() or _poi_busy.has(uuid) or int(now_ms.call()) < int(_poi_retry_at.get(uuid, 0)):
		return
	_poi_busy[uuid] = true
	var kind := str(data.get("place_kind", ""))
	var body := {
		"owner": {"type": "player", "id": str(data.get("discoverer_id", ""))},
		"name": str(UNCHARTED_POI_NAMES.get(kind, "Uncharted place")),
		"system": str(location.get("system", "")), "scene": str(location.get("scene", "")),
		"x": float(location.get("x", 0.0)), "y": float(location.get("y", 0.0)), "z": float(location.get("z", 0.0)),
		"visibility": "private", "metadata": poi_metadata(uuid, data, true),
	}
	var result: Dictionary = await _inventory(HTTPClient.METHOD_POST, "/api/internal/pois", body)
	_poi_busy.erase(uuid)
	var poi_id := str((result.get("data") as Dictionary).get("id", "")) \
			if bool(result.get("ok", false)) and result.get("data") is Dictionary else ""
	if poi_id == "":
		_poi_retry_at[uuid] = int(now_ms.call()) + POI_RETRY_MS
		push_warning("[Discoveries] no point of interest for %s: %s" % [uuid, str(result.get("error", "?"))])
		return
	_poi_retry_at.erase(uuid)
	update_prop.call(uuid, {"poi_id": poi_id}, Discovery.TYPE)


## The discoverer's point of interest renamed after the name they proposed.
func _rename_poi(uuid: String, data: Dictionary, name: String) -> void:
	var poi_id := str(data.get("poi_id", ""))
	if poi_id == "" or not _inventory_active():
		return
	var result: Dictionary = await _inventory(HTTPClient.METHOD_PATCH, "/api/internal/pois/%s" % poi_id.uri_encode(),
			{"name": name, "metadata": poi_metadata(uuid, data, false)})
	if not bool(result.get("ok", false)):
		push_warning("[Discoveries] point of interest %s not renamed: %s" % [poi_id, str(result.get("error", "?"))])


## What a discovery's point of interest carries for the star map (its icon) and the admin panel (which
## discovery it belongs to); [param uncharted] while no name has been proposed.
static func poi_metadata(uuid: String, data: Dictionary, uncharted: bool) -> Dictionary:
	return {"kind": str(data.get("place_kind", "")), "discovery_uuid": uuid,
		"place_uuid": str(data.get("place_uuid", "")), "place_id": str(data.get("place_id", "")),
		"uncharted": uncharted}


func _inventory_active() -> bool:
	return _inventory_url != "" and _client != null and ServiceAuth.is_configured()


func _inventory(method: int, path: String, body: Dictionary) -> Dictionary:
	var headers: PackedStringArray = await ServiceAuth.authorization_header()
	if headers.is_empty():
		return {"ok": false, "error": "NO_SERVICE_TOKEN"}
	return await _client.request(method, _inventory_url + path, headers, body)


## service-inventory's url, read like MissionHeartbeat reads it (environment, then server.ini).
static func _inventory_url_from_config() -> String:
	var url := OS.get_environment(MissionHeartbeat.ENV_INVENTORY_URL).strip_edges()
	if url == "":
		var config := ConfigFile.new()
		url = str(config.get_value(MissionHeartbeat.INI_SECTION, MissionHeartbeat.INI_KEY_INVENTORY_URL,
				MissionHeartbeat.DEFAULT_INVENTORY_URL)) if config.load("server.ini") == OK \
				else MissionHeartbeat.DEFAULT_INVENTORY_URL
	return url.strip_edges().rstrip("/")
