class_name Discovery
extends Node3D
## A place a player discovered first — a cave for now; lakes, planets, asteroids later — and the name they
## proposed for it, which ARES (the admins) approves or refuses: networked prop "discovery".
##
## A record apart from the place itself, created once by the game server (server/discoveries.gd) as a child
## of the place's prop: a cave re-import replaces the cave's object whole, it never touches its discovery,
## and the admin panel lists every discovery awaiting a decision by its type alone. No geometry.
##
## Status: UNNAMED (found, nothing proposed) -> PENDING (a name awaits ARES) -> APPROVED, or REFUSED (the
## discoverer may propose again).

## Horizon type and scene of the prop (items_def/discovery_def.json).
const TYPE := "discovery"
const SCENE := "scenes/exploration/discovery.tscn"

const UNNAMED := "unnamed"
const PENDING := "pending"
const APPROVED := "approved"
const REFUSED := "refused"

## Every discovery node in the tree, client and server alike: "kind:place_id" -> Discovery.
static var _by_place: Dictionary = {}

## Every field received so far: an update only carries what changed.
var _data: Dictionary = {}
var _key := ""


## The prop's uuid for the place [param place_id] of kind [param kind]: the same on every server and every
## boot, so a discovery is created once and found again by anyone who knows the place.
static func uuid_for(kind: String, place_id: String) -> String:
	return PropSpawn.stable_uuid("discovery:%s:%s" % [kind, place_id])


## The live discovery of that place, or null (none yet, or not streamed here).
static func of_place(kind: String, place_id: String) -> Discovery:
	var found: Discovery = _by_place.get("%s:%s" % [kind, place_id])
	return found if is_instance_valid(found) else null


## The object data of a new discovery, everything but the prop's own uuid, type, scene and parent.
static func record(kind: String, place_id: String, place_uuid: String, planet_name: String, discoverer_id: String,
		discoverer_name: String, discovered_at: int) -> Dictionary:
	return {
		"place_kind": kind, "place_id": place_id, "place_uuid": place_uuid, "planet_name": planet_name,
		"discoverer_id": discoverer_id, "discoverer_name": discoverer_name, "discovered_at": discovered_at,
		"status": UNNAMED, "proposed_name": "", "proposed_at": 0, "approved_name": "", "refusal_reason": "",
		"decided_at": 0, "poi_id": "",
	}


## Whether [param status] lets the discoverer propose a name.
static func open_to_proposal(status: String) -> bool:
	return status == UNNAMED or status == REFUSED


## PropSync: the replicated fields of this discovery.
func apply_prop_data(data: Dictionary) -> void:
	_data.merge(data, true)
	_index()


func _enter_tree() -> void:
	_index()


func _exit_tree() -> void:
	if _by_place.get(_key) == self:
		_by_place.erase(_key)


func _index() -> void:
	if not is_inside_tree() or kind() == "" or place_id() == "":
		return
	var key := "%s:%s" % [kind(), place_id()]
	if key != _key and _by_place.get(_key) == self:
		_by_place.erase(_key)
	_key = key
	_by_place[_key] = self


func kind() -> String:
	return str(_data.get("place_kind", ""))


func place_id() -> String:
	return str(_data.get("place_id", ""))


func status() -> String:
	return str(_data.get("status", UNNAMED))


func discoverer_id() -> String:
	return str(_data.get("discoverer_id", ""))


func discoverer_name() -> String:
	return str(_data.get("discoverer_name", ""))


func approved_name() -> String:
	return str(_data.get("approved_name", ""))


## Whether the player [param player_id] should be asked for a name: they discovered it, and nothing they
## proposed is waiting or approved.
func needs_name_from(player_id: String) -> bool:
	return player_id != "" and player_id == discoverer_id() and open_to_proposal(status())
