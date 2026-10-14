extends Node

## Player-state heartbeat for service-mission, pushed by the dedicated server.
##
## service-mission measures every PHYSICAL objective — `visit`, `deliver_material`, `transport`,
## `transport_passenger` — and matches a mission's availability `zones[]` against this store
## ([code]PUT /api/internal/missions/player-states[/code]). It reads nothing else: not Social's
## presence, not the game's props. That is what makes a mission independent of the server sharding:
## the frame pushed here is the TRUE UNIVERSE frame, identical before and after a hand-over, so the
## same place measures the same wherever the body happens to be simulated.
##
## Three rules this node exists to enforce, each of them a bug otherwise:
##
##  1. **The seat flags are STORED, never re-derived.** [code]onFoot[/code] / [code]passenger[/code]
##     are read off the tree exactly once, when the player becomes live ([method on_player_live],
##     called from [method GameServer._register_player] AFTER the re-seat), and after that only
##     flipped by the explicit seat hooks. Reading [code]_seat_node[/code] while building a payload
##     would be wrong: [method GameServer._unseat_for_transfer] nulls it on every zone crossing,
##     which is a hand-over rather than a player getting out — it would complete every passenger
##     mission at every border.
##  2. **Every live player is re-pushed on EVERY tick**, not only the ones whose state moved. The
##     service expires a state after 30 s and treats it as "outside every zone", fail-closed. A
##     player standing still past the TTL would otherwise silently vanish from the mission list: the
##     store feeds availability zones too, so this is not only about objectives.
##  3. **The place is the same geometry Social already sends.** [method GameServer.mission_place_of]
##     is the single owner of the true-universe frame; this file only flattens it into the shape
##     the mission schema wants. Two services can therefore never be handed two different
##     coordinates for the same body.
##
## Dormant by default, exactly like [SocialHeartbeat]: without a url or a service identity the whole
## thing is a clean no-op. It is the server's own service-account traffic ([ServiceAuth], client
## credentials), never a player token. Secrets are never logged.

const HTTP_CLIENT := preload("res://ui/services/http_client.gd")

## Seconds between two full re-pushes. The service expires a state after 30 s, so one beat of slack
## absorbs a single failed call without every standing player dropping out of their mission list.
const INTERVAL_S: float = 10.0
## Request timeout, shorter than the beat so a hung call can never overlap the next one.
const TIMEOUT_S: float = 3.0
## The schema's `maxItems` on the batch array: a roster larger than this is sent in several calls,
## never truncated, since a dropped tail is players invisible to their own missions.
const MAX_BATCH: int = 500
## How far a player must drift (metres) before a hook-triggered push is worth one. Below this it is
## noise; above it the 10 s tick would have caught it anyway.
const PLACE_EPSILON_M: float = 2.0
## Environment override for the mission base url (the chart/kube way). Wins over server.ini.
const ENV_URL: String = "MISSION_API_URL"
## Base url when neither the environment nor server.ini says otherwise: the in-cluster gateway.
const DEFAULT_URL: String = "http://service.dyingstar.local/mission"
## server.ini section and key holding the base url. `url=""` there disables the heartbeat even
## when auth is configured.
const INI_SECTION: String = "mission"
const INI_KEY_URL: String = "url"
## Same, for service-inventory: this node also writes the goods a player physically carries, which
## the mission service then measures. Inventory stays the OWNER of that quantity — see
## [method credit_mined] and the note on [method set_carried] about why two numbers answer two
## different questions.
const ENV_INVENTORY_URL: String = "INVENTORY_API_URL"
const INI_KEY_INVENTORY_URL: String = "inventory_url"
const DEFAULT_INVENTORY_URL: String = "http://service-inventory:3000"
## The holder kind this node writes under. Only a player can be the server's own actor: a crate of
## ore credited to a corporation is the corporation's good, not the miner stepping on the pedal.
const PLAYER_HOLDER: String = "player"
## service-inventory trades `carried` in whole units, but the world measures ore in cubic metres and
## one hauling box holds about 0.0657 m3 — which rounds to NOTHING in metres. Litres are the unit
## that makes a crate an integer (≈66) while keeping the rounding error under half a litre, which
## the depot absorbs out of its own float pool rather than out of the player's stack.
const LITRES_PER_M3: float = 1000.0
## service-inventory's goods vocabulary for mined ore: a mineral id prefixed with this.
const MINERAL_GOOD_PREFIX: String = "ore."

var _url: String = ""
var _inventory_url: String = ""
var _http: HTTPRequest = null
var _client: HttpClient = null
var _timer: Timer = null

## player uuid -> {onFoot: bool, passenger: bool}. The authority for the two seat flags: set when
## the player becomes live, flipped by the seat hooks, never read back off the node.
var _seat: Dictionary = {}
## player uuid -> {goodType: quantity}. What this player physically has with them RIGHT NOW (in hand,
## or in a bay of the vehicle they are in) — NOT what they own. The owning quantity is
## service-inventory's `carried` column and answers to `available`; the two answer different
## questions and drift on purpose whenever a truck changes hands.
var _carried: Dictionary = {}
## player uuid -> the exact entry the service last accepted, so a hook-triggered push can tell a
## change from a restatement.
var _sent: Dictionary = {}

## One flush at a time: HTTPRequest serves a single request, and a flush is a chain of them.
var _flush_running: bool = false
## Set when a hook asked for a flush while one was in flight: it may predate that change.
var _flush_again: bool = false
## Last failure code, for an edge-triggered warning: say it when it CHANGES, not every 10 s.
var _last_error: String = ""
## The dormant reason last said out loud, so a fixed/unchanged credential prints nothing twice.
var _dormant_noted: String = ""
## How many states the last accepted flush carried, so the line only prints when it changes.
var _last_reported: int = -1


func _ready() -> void:
	_load_config()
	# The HTTPRequest must live in the tree (parented here = polled by the engine) or
	# request_completed never fires — see ui/services/http_client.gd and addons/dyingstar.
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_S
	add_child(_http)
	_client = HTTP_CLIENT.new(_http)
	_timer = Timer.new()
	_timer.wait_time = INTERVAL_S
	_timer.autostart = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)


func _load_config() -> void:
	_url = OS.get_environment(ENV_URL).strip_edges()
	_inventory_url = OS.get_environment(ENV_INVENTORY_URL).strip_edges()
	var config := ConfigFile.new()
	var loaded: bool = config.load("server.ini") == OK
	if _url == "":
		_url = str(config.get_value(INI_SECTION, INI_KEY_URL, DEFAULT_URL)).strip_edges() if loaded \
				else DEFAULT_URL
	if _inventory_url == "":
		_inventory_url = str(config.get_value(INI_SECTION, INI_KEY_INVENTORY_URL,
				DEFAULT_INVENTORY_URL)).strip_edges() if loaded else DEFAULT_INVENTORY_URL
	_url = _url.rstrip("/")
	_inventory_url = _inventory_url.rstrip("/")


## True when a flush may run: this process is the game server, with an url to call and a service
## identity to call it with.
func _is_active() -> bool:
	return GameOrchestrator.is_server() and _url != "" and ServiceAuth.is_configured()


## Same, for the goods side: writing `carried` needs its own url, and a deployment that pushes
## player-states without an inventory would otherwise mint goods into the void.
func _carried_is_active() -> bool:
	return GameOrchestrator.is_server() and _inventory_url != "" and ServiceAuth.is_configured()


# ── Hooks: the game server is the only writer ───────────────────────────────────────────────────

## A player became LIVE here: they joined, or a hand-over woke them in
## [method GameServer.activate_object]. Both paths run through [method GameServer._register_player],
## which re-seats a seated hand-over BEFORE this is called — so the seat read here is the one the
## player actually landed in, not the dormant body's.
func on_player_live(player_id: String, node: Node3D) -> void:
	if not _accepts(player_id, node):
		return
	_seat[player_id] = seat_state_of(node)
	_request_flush()


## The player sat down. [param driver] is the seat's own answer, read by the caller from the seat
## it just entered — never guessed here, so this file needs no knowledge of VehicleSeat.
func on_player_seated(player_id: String, driver: bool) -> void:
	if not _is_active():
		return
	_seat[player_id] = {"onFoot": false, "passenger": not driver}
	_request_flush()


## The player got OUT of the seat: a real disembark, told by the exit handler after it re-read the
## seat (see [method on_player_live] on why that distinction matters). NOT the zone hand-over, which
## frees the body instead and goes through [method forget].
func on_player_dismounted(player_id: String) -> void:
	if not _is_active():
		return
	_seat[player_id] = {"onFoot": true, "passenger": false}
	_request_flush()


## A player left this server for good: clean quit, or a hand-over freeing the body here. Their state
## must not linger — the next server pushes their own.
func forget(player_id: String) -> void:
	_seat.erase(player_id)
	_carried.erase(player_id)
	_sent.erase(player_id)


## What this player physically has with them, as {goodType: quantity}. A full snapshot, not a delta:
## the service reads it as one. [method credit_mined] and friends keep this in step with the
## inventory on their own; call it only for a carrier the inventory does not track.
func set_carried(player_id: String, carried: Dictionary) -> void:
	if not _is_active():
		return
	var clean := sanitize_carried(carried)
	if _carried.get(player_id, {}) == clean:
		return
	_carried[player_id] = clean
	_request_flush()


## Goods that appeared in the world: the mining depot packed a crate out of the ore it refined.
## service-inventory CREATES them (`quantity += units`, `carried += units`).
##
## ⚠️ This is the one call that MINTS goods, which is why it lives here and never on a player
## route: a player able to send it could hand themselves ore at will. The game server is the world
## authority, it is the only thing that knows a crate was really filled, and it acts under
## [ServiceAuth] rather than a player's token.
func credit_mined(player_id: String, good_type: String, units: int) -> void:
	_carried_delta(player_id, good_type, units, {})


## Goods leave the player entirely and land on [param destination] — a `Holder`, e.g.
## `{"holderType": "warehouse", "holderId": <uuid POI>}` for a delivery zone. Mandatory on a
## negative delta: the service answers 422 DESTINATION_REQUIRED rather than voiding the goods.
func drop_carried(player_id: String, good_type: String, units: int, destination: Dictionary) -> void:
	_carried_delta(player_id, good_type, -units, {"to": destination})


## Goods move from a stock the player has access to into their hands. The service re-reads
## [param source]'s AVAILABLE stock, so it is the authority on whether the load was affordable.
func load_carried(player_id: String, good_type: String, units: int, source: Dictionary) -> void:
	_carried_delta(player_id, good_type, units, {"from": source})


## One `POST .../stacks/{goodType}/carried`. [param counterparty] is empty for a mining credit, and
## carries the `from` / `to` half otherwise. Detached: the caller (a depot, an interface) is not
## waiting on it, and the service owns the outcome either way.
##
## A failure is said ONCE and never retried in a loop: the delta has already been lost server-side,
## so replaying it would either double-credit or fight the player's next real action.
func _carried_delta(player_id: String, good_type: String, delta: int,
		counterparty: Dictionary) -> void:
	if not _carried_is_active() or delta == 0 or good_type == "" or player_id == "":
		return
	var body := {"goodType": good_type, "delta": delta}
	body.merge(counterparty)
	var headers: PackedStringArray = await ServiceAuth.authorization_header()
	if headers.is_empty():
		_note_error("NO_SERVICE_TOKEN", "carried", false)
		return
	var result: Dictionary = await _client.request(HTTPClient.METHOD_POST,
			_carried_url(player_id, good_type), headers, body)
	if not bool(result.get("ok", false)):
		_note_error(str(result.get("error", "ERROR")), "carried %s %+d" % [good_type, delta], false)
		return
	_note_error("", "carried")
	# The write answers a Stack, which carries no `carried`: the new figure is whatever the service
	# says it is, so it is read back rather than computed from the delta we just sent.
	await _read_carried(player_id, good_type)


## Re-read one player's carried quantity for one good and adopt it as the truth.
func _read_carried(player_id: String, good_type: String) -> void:
	var headers: PackedStringArray = await ServiceAuth.authorization_header()
	if headers.is_empty():
		return
	var result: Dictionary = await _client.request(HTTPClient.METHOD_GET,
			"%s/api/internal/holders/%s/%s/stacks/%s" % [_inventory_url, PLAYER_HOLDER,
			player_id.uri_encode(), good_type.uri_encode()], headers, null)
	if not bool(result.get("ok", false)):
		_note_error(str(result.get("error", "ERROR")), "carried read", false)
		return
	_adopt_carried(player_id, good_type, int(carried_of(result.get("data"))))


func _carried_url(player_id: String, good_type: String) -> String:
	return "%s/api/internal/holders/%s/%s/stacks/%s/carried" % [_inventory_url, PLAYER_HOLDER,
		player_id.uri_encode(), good_type.uri_encode()]


## [param view] is a StackView; its `carried` is the authoritative physical quantity. An unreadable
## answer reads as 0, which is the safe direction: the player owns less than they should, never more.
static func carried_of(view: Variant) -> int:
	if not (view is Dictionary):
		return 0
	var carried: Variant = (view as Dictionary).get("carried", 0)
	return int(carried) if carried is int or carried is float else 0


## Write one good's quantity into [member _carried] and push if that moved anything.
func _adopt_carried(player_id: String, good_type: String, units: int) -> void:
	var entry: Dictionary = (_carried.get(player_id, {}) as Dictionary).duplicate()
	if units > 0:
		entry[good_type] = units
	else:
		entry.erase(good_type)
	if entry == _carried.get(player_id, {}):
		return
	_carried[player_id] = entry
	_request_flush()


## The service's goods name for a mineral id ("gold" -> "ore.gold"). An empty or inert id yields "",
## which every caller refuses rather than crediting goods to "ore.".
static func good_type_for_mineral(mineral_id: String) -> String:
	var clean := mineral_id.strip_edges()
	return "" if clean == "" else MINERAL_GOOD_PREFIX + clean


## [param cubic_metres] of ore as whole inventory units. One hauling box is ≈0.0657 m3, which is
## ZERO in whole metres — this is the conversion that keeps a crate worth something.
static func units_of_volume(cubic_metres: float) -> int:
	return maxi(0, roundi(cubic_metres * LITRES_PER_M3))


## Push now, so a change is measured in a second instead of at the next tick. Only what actually
## changed goes out: the timer's full refresh is what guarantees no state goes stale, and a hook
## has no reason to restate forty standing players.
func _request_flush() -> void:
	if _flush_running:
		# A tick already asked for everything; remember that the follow-up must be a full one too.
		_flush_again = true
		return
	_run_flush(false)


func _on_timer() -> void:
	if _flush_running:
		_flush_again = true
		return
	_run_flush(true)


func _accepts(player_id: String, node: Node3D) -> bool:
	return _is_active() and player_id != "" and node != null and is_instance_valid(node)


# ── Flush ──────────────────────────────────────────────────────────────────────────────────────

## The flush body, guarded so the timer and the hooks can never interleave on the one HTTPRequest.
func _run_flush(force: bool) -> void:
	if not _is_active():
		_note_dormant()
		return
	_flush_running = true
	await _flush(force)
	_flush_running = false
	if _flush_again:
		_flush_again = false
		_run_flush(true)


func _flush(force: bool) -> void:
	var entries := _entries_to_send(force)
	if entries.is_empty():
		return
	var sent := 0
	var index := 0
	while index < entries.size():
		var chunk: Array = entries.slice(index, mini(index + MAX_BATCH, entries.size()))
		index += chunk.size()
		if await _send_chunk(chunk):
			sent += chunk.size()
	# A rejected tail is players invisible to their own missions, and nothing anywhere would say so.
	if sent != entries.size():
		_note_error("PARTIAL_BATCH", "player-states (%d/%d)" % [sent, entries.size()])


## The entries to push. [param force] is the timer's: the whole live roster, because a state the
## service considers stale has dropped out of every zone. Without it, only what changed since the
## last accepted push — which is what a hook-triggered flush wants.
func _entries_to_send(force: bool) -> Array:
	var agent = NetworkOrchestrator.network_agent
	if not (agent is GameServer):
		return []
	var out: Array = []
	for player_id: Variant in agent.players_list.keys():
		var node: Variant = agent.players_list[player_id]
		if not is_instance_valid(node) or bool(node.get("is_npc")):
			continue
		var id: String = str(player_id)
		var entry := build_entry(id, place_of(node), _seat.get(id, {}), _carried.get(id, {}))
		if force or _needs_push(_sent.get(id, {}), entry):
			out.append(entry)
	return out


## Whether [param entry] is worth a push: anything the last accepted entry did not already say.
static func _needs_push(sent: Dictionary, entry: Dictionary) -> bool:
	if sent.is_empty():
		return true
	if sent.get("onFoot", true) != entry.get("onFoot", true):
		return true
	if sent.get("passenger", false) != entry.get("passenger", false):
		return true
	if sent.get("carried", {}) != entry.get("carried", {}):
		return true
	return place_moved(sent.get("place", null), entry.get("place", null))


## One batch of at most [constant MAX_BATCH] states. Returns whether the service took it, and only
## then records it as sent: a failed batch has to be retried, not remembered as delivered.
func _send_chunk(chunk: Array) -> bool:
	var headers: PackedStringArray = await ServiceAuth.authorization_header()
	if headers.is_empty():
		_note_error("NO_SERVICE_TOKEN", "player-states")
		return false
	var result: Dictionary = await _client.request(HTTPClient.METHOD_PUT,
			"%s/api/internal/missions/player-states" % _url, headers, {"players": chunk})
	if not bool(result.get("ok", false)):
		_note_error(str(result.get("error", "ERROR")), "player-states")
		return false
	_note_error("", "player-states")
	for entry: Dictionary in chunk:
		_sent[str(entry.get("playerId", ""))] = entry
	_note_sent(chunk.size(), _updated_count(result))
	return true


## Record that [param size] states went out and [param updated] is how many the service says it
## took. The two are different questions: the size is what we sent, the count is what the service
## kept, and a gap between them is players missing from their own mission zones with nothing else
## saying so. -1 means the answer carried no count, which is not a gap.
func _note_sent(size: int, updated: int) -> void:
	if size != _last_reported:
		_last_reported = size
		print("[MissionHeartbeat] player-states OK (%d)" % size)
	if updated >= 0 and updated != size:
		push_warning("[MissionHeartbeat] player-states accepted %d of %d — those players are missing "
				+ "from their mission zones" % [updated, size])


## The service's `updated` count, or -1 when the answer does not carry a readable one.
static func _updated_count(result: Dictionary) -> int:
	var data: Variant = result.get("data")
	if not (data is Dictionary):
		return -1
	var updated: Variant = (data as Dictionary).get("updated")
	return int(updated) if updated is int or updated is float else -1


# ── Payload: static and pure, so a test pins the shape without a tree ──────────────────────────

## One [code]PlayerStateEntry[/code] — exactly the object the openapi schema accepts.
##
## [param place] is already flattened to {system, scene, x, y, z}: the mission schema's Place is
## FLAT, unlike Social's {system, scene, position:{x,y,z}} that the very same coordinates come
## from, so it cannot be forwarded as-is. Null means "not known", which the service reads as
## outside every zone — the honest answer, whereas a zeroed coordinate would read as the origin and
## could match a POI sitting on it.
static func build_entry(player_id: String, place: Variant, seat: Dictionary,
		carried: Dictionary) -> Dictionary:
	return {
		"playerId": player_id,
		"place": place,
		"onFoot": bool(seat.get("onFoot", true)),
		"passenger": bool(seat.get("passenger", false)),
		"carried": carried,
	}


## [param location] is a [SocialHeartbeat.build_location] answer; this is its mission twin.
## Empty when the answer carries no position: there is no place to report, and inventing one would
## be worse than reporting none (see [method build_entry] on why an origin is never the answer).
static func build_place(location: Dictionary) -> Dictionary:
	var position: Variant = location.get("position")
	if not (position is Dictionary):
		return {}
	var coords: Dictionary = position as Dictionary
	return {
		"system": str(location.get("system", "")),
		"scene": str(location.get("scene", "")),
		"x": float(coords.get("x", 0.0)),
		"y": float(coords.get("y", 0.0)),
		"z": float(coords.get("z", 0.0)),
	}


## [param node]'s mission place, or null when there is no body to read or the agent cannot say
## where it is. Asks the game server, the single owner of the true-universe frame.
static func place_of(node: Node3D) -> Variant:
	if node == null or not is_instance_valid(node):
		return null
	var agent = NetworkOrchestrator.network_agent
	if not (agent is GameServer) or not agent.has_method("mission_place_of"):
		return null
	var location: Variant = agent.mission_place_of(node)
	if not (location is Dictionary):
		return null
	var place := build_place(location as Dictionary)
	return null if place.is_empty() else place


## The seat state of [param node] right now: seated in a driver seat, seated as a passenger, or on
## foot. Read once, at [method on_player_live], and stored — see the header on why it is never
## re-read while a payload is built.
static func seat_state_of(node: Node3D) -> Dictionary:
	var seat: Variant = node.get("_seat_node")
	if not (seat is Node) or not is_instance_valid(seat):
		return {"onFoot": true, "passenger": false}
	var driver: bool = false
	if (seat as Node).has_method("is_driver_seat"):
		driver = bool((seat as Node).call("is_driver_seat"))
	return {"onFoot": false, "passenger": not driver}


## A {goodType: quantity} map with the empties dropped: the schema wants integers >= 0, and a
## `carried` carrying a zero would make every push differ from the last for no reason.
static func sanitize_carried(carried: Dictionary) -> Dictionary:
	var clean := {}
	for good_type: Variant in carried.keys():
		var quantity: int = int(carried[good_type])
		if quantity > 0:
			clean[str(good_type)] = quantity
	return clean


## Whether a place moved far enough to be worth a push. A body that gained or lost its place counts
## as moved; one that drifted less than [constant PLACE_EPSILON_M] does not.
static func place_moved(old: Variant, current: Variant) -> bool:
	if not (old is Dictionary) or not (current is Dictionary):
		return old != current
	var previous: Dictionary = old as Dictionary
	var now: Dictionary = current as Dictionary
	if str(previous.get("system", "")) != str(now.get("system", "")):
		return true
	if str(previous.get("scene", "")) != str(now.get("scene", "")):
		return true
	var was := Vector3(float(previous.get("x", 0.0)), float(previous.get("y", 0.0)),
			float(previous.get("z", 0.0)))
	return was.distance_to(Vector3(float(now.get("x", 0.0)), float(now.get("y", 0.0)),
			float(now.get("z", 0.0)))) > PLACE_EPSILON_M


# ── Logging ────────────────────────────────────────────────────────────────────────────────────

## Warn when the failure reason changes (including when the service recovers), stay quiet otherwise.
## [param retried] is what the message says about the next try, and it is not cosmetic: the beat
## rebuilds every state from the roster, while a goods delta is gone the moment the service
## refuses it, so promising a retry there would be a lie.
func _note_error(code: String, what: String = "", retried: bool = true) -> void:
	var key: String = "%s|%s" % [what, code]
	if key == _last_error:
		return
	_last_error = key
	if code == "":
		print("[MissionHeartbeat] %sservice calls restored" % ("%s: " % what if what != "" else ""))
		return
	push_warning("[MissionHeartbeat] %sfailed (%s) — %s" % [
		"%s: " % what if what != "" else "", code,
		"next beat retries" if retried else "not retried, the goods were NOT credited"])


## Why the heartbeat is not running, in one line — or "" when everything it needs is in place.
## Server-side only: the client runs this autoload too, and logging a dormant reason there would
## cry wolf on every player session.
func _dormant_reason() -> String:
	if not GameOrchestrator.is_server():
		return ""
	if _url == "":
		return "no url configured ([mission] url / MISSION_API_URL empty)"
	if not ServiceAuth.is_configured():
		return "no Keycloak service credentials (missing: %s)" % ", ".join(ServiceAuth.missing_config())
	return ""


## Say the heartbeat is dormant — and exactly why, once per reason. The bug this closes: a dormant
## heartbeat is indistinguishable from a working one. Nothing reaches service-mission, missions stop
## matching their zones, and nothing anywhere says why.
func _note_dormant() -> void:
	var reason := _dormant_reason()
	if reason == _dormant_noted:
		return
	_dormant_noted = reason
	if reason != "":
		push_warning("[MissionHeartbeat] dormant: %s — player-states NOT sent, mission zones and "
				+ "physical objectives will not match" % reason)