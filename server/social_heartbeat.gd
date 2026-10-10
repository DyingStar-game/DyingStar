extends Node

## Presence + playtime heartbeat for service-social, pushed by the dedicated server.
##
## service-social only knows a player is online while their presence entry is fresh: every beat
## re-states the whole roster ([code]PUT /api/internal/players/presence/batch[/code]), and the
## service drops a player from the cache [code]PRESENCE_TTL_SECONDS[/code] (90 s in the chart) after
## the last batch. One beat per minute therefore leaves a full missed beat of slack, and a server
## that dies mid-interval still has its players decay to "offline" on their own — no goodbye needed
## for a crash, only for a clean quit.
##
## The same beat flushes each player's playtime as a delta
## ([code]POST /api/internal/players/{id}/stats[/code]): the base only advances when the service
## ACCEPTS a flush, so a failed call is retried at the next beat instead of losing those seconds.
##
## A player's profile is upserted when they join ([code]PUT /api/internal/players/{id}[/code]) —
## an id social has never seen comes back as "unknown" in the batch answer and would be skipped —
## and a clean quit additionally posts an explicit [code]offline[/code] presence, so friends do not
## wait out the TTL. A transfer (freeze/dormant) is deliberately silent: the other server's own
## beat takes over, and racing it would flicker the player offline mid-hand-over.
##
## Identity: this is the SERVER's own service-account traffic, so it authenticates through
## [ServiceAuth] (client credentials), never with a player token. Without a configured [ServiceAuth]
## or an url, the whole thing simply stays dormant — a token-less local dev session behaves like the
## rest of the backend surface (clean no-op, no crash). Secrets are never logged.

const HTTP_CLIENT := preload("res://ui/services/http_client.gd")

## Seconds between two beats. Under service-social's 90 s presence TTL with one beat of slack.
const INTERVAL_S: float = 60.0
## Request timeout, shorter than the beat so a hung call can never overlap the next one.
const TIMEOUT_S: float = 10.0
## Environment override for the social base url (the chart/kube way). Wins over server.ini.
const ENV_URL: String = "SOCIAL_API_URL"
## Base url when neither the environment nor server.ini says otherwise: the in-cluster gateway.
const DEFAULT_URL: String = "http://service.dyingstar.local/social"
## server.ini section and key holding the base url. `url=""` there disables the heartbeat even
## when auth is configured.
const INI_SECTION: String = "social"
const INI_KEY_URL: String = "url"
## service-social's `displayName` bounds (2..32 chars): a name outside them is rejected outright,
## so the profile upsert is skipped rather than failing on every join.
const MIN_DISPLAY_NAME: int = 2
const MAX_DISPLAY_NAME: int = 32

var _url: String = ""
var _http: HTTPRequest = null
var _client: HttpClient = null
var _timer: Timer = null

## uuid -> unix seconds of the LAST playtime flush the service accepted for that player. Also the
## roster of "real" players this heartbeat reports: NPCs never get an entry (their ids mean nothing
## to social), which is what keeps them out of the batch too.
var _playtime_base: Dictionary = {}
## One beat at a time: HTTPRequest serves a single request, and a beat is a chain of them.
var _beat_running: bool = false
## Set when a join asked for a beat while one was in flight — the in-flight beat may predate it.
var _beat_again: bool = false
## Last failure code, for an edge-triggered warning: say it when it CHANGES, not once a minute.
var _last_error: String = ""
## The dormant reason last said out loud, so a fixed/unchanged credential prints nothing twice.
var _dormant_noted: String = ""
## Player count of the last successful presence batch, so the line only prints when it changes.
var _last_reported: int = -1
## Unknown ids of the last batch seen in the response, same edge-triggered idea.
var _unknown_noted: String = ""
## The last service response, kept for the beat's unknown-id lookup and the failure's own message.
## Only ever READ between a completed call and the next one: one beat at a time on one request.
var _last_response: Variant = {}


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
	if _url == "":
		var config := ConfigFile.new()
		if config.load("server.ini") == OK:
			_url = str(config.get_value(INI_SECTION, INI_KEY_URL, DEFAULT_URL)).strip_edges()
		else:
			_url = DEFAULT_URL
	_url = _url.rstrip("/")


## True when a beat may run: this process is the game server, with an url to call and a service
## identity to call it with.
func _is_active() -> bool:
	return GameOrchestrator.is_server() and _url != "" and ServiceAuth.is_configured()


## A live player entered GameServer.players_list. Remember them for playtime, push their profile so
## the next batch is not answered "unknown", and ask for a beat so friends see them now rather than
## up to a minute late. NPCs are social's business only through their own endpoints — skipped here.
func on_player_joined(player_id: String, display_name: String, is_npc: bool) -> void:
	if is_npc or not _is_active():
		_note_dormant()
		return
	if not _playtime_base.has(player_id):
		_playtime_base[player_id] = _unix_now()
	var clean_name := sanitize_display_name(display_name)
	if clean_name != "":
		_upsert_profile(player_id, clean_name)
	_request_beat()


## A live player left (clean quit path — never the transfer/freeze one). Flush the playtime earned
## since the last accepted delta and mark them offline straight away, so nobody waits out the TTL.
## Detached like any other service call: the player is already gone, nothing awaits the answer.
func on_player_left(player_id: String) -> void:
	if not _playtime_base.has(player_id):
		return  # never one of ours: an NPC, or a heartbeat that was dormant when they joined
	var delta: int = _unix_now() - int(_playtime_base[player_id])
	_playtime_base.erase(player_id)
	if not _is_active():
		return
	_leave(player_id, delta)


## Ask for a beat now. Joins use it so a fresh player is visible before the next timer tick; the
## timer uses it on schedule. A beat already in flight just gets a follow-up when it lands, since
## the join it missed may be the reason for the call.
func _request_beat() -> void:
	if _beat_running:
		_beat_again = true
		return
	_run_beat()


func _on_timer() -> void:
	_request_beat()


## The beat body, guarded so timer and join requests can never interleave on the one HTTPRequest.
func _run_beat() -> void:
	if not _is_active():
		_note_dormant()
		return
	_beat_running = true
	await _beat()
	_beat_running = false
	if _beat_again:
		_beat_again = false
		_request_beat()


func _beat() -> void:
	var agent := NetworkOrchestrator.network_agent
	if not (agent is GameServer):
		return
	var players: Dictionary = agent.players_list
	var now := _unix_now()

	# Presence: one batch for the whole roster (limit 5000 per call — far past any server size).
	var entries: Array = []
	for player_id: Variant in players.keys():
		var node: Node = players[player_id]
		if not is_instance_valid(node) or bool(node.get("is_npc")):
			continue
		entries.append({
			"playerId": str(player_id),
			"status": "online",
			"location": agent.social_presence_location(node),
		})
	if not entries.is_empty():
		var sent: bool = await _send(HTTPClient.METHOD_PUT,
				"%s/api/internal/players/presence/batch" % _url, {"players": entries},
				"presence batch")
		if sent:
			_note_presence_ok(entries.size(), _unknown_ids_of(_last_response))

	# Playtime: one delta per player, computed and re-checked here — a player who quit while the
	# batch above was in flight has already had their leaving flush from on_player_left().
	for player_id: Variant in _playtime_base.keys():
		if not players.has(player_id):
			continue
		var delta: int = now - int(_playtime_base[player_id])
		if delta <= 0:
			continue
		if await _post_stats(str(player_id), delta):
			_playtime_base[player_id] = _unix_now()


## A detached quit flush: remaining playtime first, then the explicit offline presence.
func _leave(player_id: String, delta: int) -> void:
	if delta > 0:
		await _post_stats(player_id, delta)
	await _send(HTTPClient.METHOD_PUT, "%s/api/internal/players/%s/presence" % [
			_url, player_id.uri_encode()], {"status": "offline"}, "offline presence")


## One [code]POST .../stats[/code] with a playtime delta. Returns whether the service accepted it:
## the caller is what advances (or doesn't advance) that player's base.
func _post_stats(player_id: String, delta: int) -> bool:
	return await _send(HTTPClient.METHOD_POST,
			"%s/api/internal/players/%s/stats" % [_url, player_id.uri_encode()],
			{"playtimeSecondsDelta": delta}, "stats")


## A detached profile upsert ([code]PUT /api/internal/players/{id}[/code]) so the player's id is
## known to social before the next batch lists them.
func _upsert_profile(player_id: String, display_name: String) -> void:
	await _send(HTTPClient.METHOD_PUT, "%s/api/internal/players/%s" % [_url, player_id.uri_encode()],
			{"displayName": display_name}, "profile upsert")


## One authenticated call. [param what] names it in the failure line ("presence batch", "stats",…)
## so the console says WHAT broke, not just that something did. Returns true on a 2xx: the caller
## is what advances playtime bases and reads unknown ids off [member _last_response].
func _send(method: int, url: String, body: Dictionary, what: String = "") -> bool:
	var headers: PackedStringArray = await ServiceAuth.authorization_header()
	if headers.is_empty():
		_last_response = {}  # no response at all: nothing to describe, nothing to read
		_note_error("NO_SERVICE_TOKEN", what)
		return false
	var result: Dictionary = await _client.request(method, url, headers, body)
	_last_response = result  # what came back, for the beat's unknown-id lookup
	if bool(result.get("ok", false)):
		_note_error("", what)
		return true
	_note_error(str(result.get("error", "ERROR")), what)
	return false


## Warn when the failure reason changes (including when service recovers), stay quiet otherwise.
## The service's own message (HttpClient.describe_error) rides along, so a 400 with a readable
## reason shows it instead of a bare code.
func _note_error(code: String, what: String = "") -> void:
	var key: String = "%s|%s" % [what, code]  # one line per (endpoint, reason), not per endpoint
	if key == _last_error:
		return
	_last_error = key
	if code == "":
		print("[SocialHeartbeat] %sservice calls restored" % ("%s: " % what if what != "" else ""))
	else:
		var detail: String = ""
		if _last_response is Dictionary:
			detail = " (%s)" % HttpClient.describe_error(_last_response)
		push_warning("[SocialHeartbeat] %sfailed (%s)%s — next beat retries" % [
				"%s: " % what if what != "" else "", code, detail])


## Confirmation that social really recorded the roster: first successful batch, then whenever the
## count changes. [param unknown] lists the player ids the service answered it does not know —
## the silent case where the batch is accepted (200) but nobody can ever see those players online,
## usually because the server's player id is not the player's social id.
func _note_presence_ok(count: int, unknown: String) -> void:
	if count != _last_reported:
		_last_reported = count
		print("[SocialHeartbeat] presence OK (%d players)" % count)
	if unknown == _unknown_noted:
		return
	_unknown_noted = unknown
	if unknown != "":
		push_warning("[SocialHeartbeat] presence batch accepted but these ids are UNKNOWN to "
				+ "social (they stay offline until their profile is known): %s" % unknown)


## The "unknown" ids of a presence-batch answer, sorted and joined — or "" when the response
## carries none or is shaped something else (read defensively: the id set is what matters, not
## the envelope).
static func _unknown_ids_of(response: Variant) -> String:
	if not (response is Dictionary):
		return ""
	var data: Variant = (response as Dictionary).get("data")
	if not (data is Dictionary):
		return ""
	var unknown: Variant = (data as Dictionary).get("unknown")
	if not (unknown is Array):
		return ""
	var ids: Array = (unknown as Array)
	if ids.is_empty():
		return ""
	var names: Array = []
	for id in ids:
		names.append(str(id))
	names.sort()
	return ", ".join(names)


## The name to send as social's `displayName`: trimmed, cut to the 32-character cap, and "" when
## what is left is too short to be a name — the caller then skips the profile upsert rather than
## sending something the service will reject on every join.
static func sanitize_display_name(raw: String) -> String:
	var clean := raw.strip_edges()
	if clean.length() > MAX_DISPLAY_NAME:
		clean = clean.substr(0, MAX_DISPLAY_NAME)
	return clean if clean.length() >= MIN_DISPLAY_NAME else ""


## The presence payload for one player: true universe position plus a readable {system, scene}
## ("tarsis" / "tarsis_3"; "space" when off-world, system then empty). Kept static and pure so the
## shape is unit-testable without a scene tree.
##
## A non-finite coordinate becomes 0 rather than being sent: a body mid-transfer or not yet placed
## can still carry INF (see the resend marker in server.gd), and JSON has no INF — it would serialise
## as null and make social reject the WHOLE batch, taking every other player's presence down with it.
static func build_location(system: String, scene: String, position: Vector3) -> Dictionary:
	return {
		"system": system,
		"scene": scene,
		"position": {
			"x": _finite(position.x),
			"y": _finite(position.y),
			"z": _finite(position.z),
		},
	}


## [param value] when it is a real number, 0 when it is INF or NaN.
static func _finite(value: float) -> float:
	return 0.0 if not is_finite(value) else value


## Why the heartbeat is not running, in one line — or "" when everything it needs is in place.
## Server-side only: the client runs this autoload too, and logging a dormant reason there would
## cry wolf on every player session.
func _dormant_reason() -> String:
	if not GameOrchestrator.is_server():
		return ""
	if _url == "":
		return "no url configured ([social] url / SOCIAL_API_URL empty)"
	if not ServiceAuth.is_configured():
		var missing := ServiceAuth.missing_config()
		return "no Keycloak service credentials (missing: %s)" % ", ".join(missing)
	return ""


## Say the heartbeat is dormant — and exactly why: a missing url, or a missing Keycloak piece
## (by NAME only — never the secret). The whole bug this closes is that a dormant heartbeat is
## indistinguishable from a working one: presence simply never reaches social and the contacts
## list shows everyone offline with nothing anywhere to explain it. Said once per reason, so a
## missing credential is a single line rather than one per minute. Recovery prints nothing here —
## it is the first successful beat that says so ("service calls restored").
func _note_dormant() -> void:
	var reason := _dormant_reason()
	if reason == _dormant_noted:
		return
	_dormant_noted = reason
	if reason != "":
		push_warning("[SocialHeartbeat] dormant: %s — presence/playtime NOT sent" % reason)


func _unix_now() -> int:
	return int(Time.get_unix_time_from_system())
