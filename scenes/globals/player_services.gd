# gdlint:disable=max-public-methods
# One method per REST endpoint is the point of this file: it is the typed face of the services API,
# and splitting it would only scatter the same surface. Disabled from line 1, before `extends`.
extends Node

## Player-facing REST client for the mission / social / economie services. The game's single owner
## of that transport, the way [ChatNetwork] owns the MQTT broker socket.
##
## The three services are separate processes behind the same `/api` prefix; each method names the
## service it talks to. Auth is a Keycloak JWT (`Authorization: Bearer`) taken from the game client's
## own token (the `--token=` argument, stored on the network agent). On a headless dedicated server
## there is nothing to call and every method answers a clean failure.
##
## Reads and writes both go through [HttpClient]; the typed methods are what the interface binds to.
## A mutation that succeeded announces it on [signal changed] so the visible section can refresh
## itself without every caller remembering to.

## A mutating call succeeded. [param area] is one of: profile, friends, groups, corporations,
## missions, economy, market, reports, pois. The terminal refreshes the matching section when it is
## the one on screen.
signal changed(area: String)

const HTTP_CLIENT := preload("res://ui/services/http_client.gd")

const SERVICE_SOCIAL: String = "social"
const SERVICE_MISSION: String = "mission"
const SERVICE_ECONOMIE: String = "economie"
const SERVICE_INVENTORY: String = "inventory"
const SERVICE_MARKET: String = "market"

## Every service behind the gateway, in display order. Drives config loading and the diagnostics.
const SERVICES: PackedStringArray = [
	SERVICE_SOCIAL, SERVICE_MISSION, SERVICE_ECONOMIE, SERVICE_INVENTORY, SERVICE_MARKET,
]

## Scheme used to reach the services. `[services] scheme` in client.ini picks `http` (default) or
## `https`; whatever scheme the [<service>] url carries is replaced by it, so the same hostnames work
## behind either an HTTP ingress or a TLS one without editing three URLs.
const DEFAULT_SCHEME: String = "http"

## The single gateway FQDN every service is reached through. Each service is a path under it
## (`/social`, `/mission`, `/economie`, `/inventory`, `/market`), overridden by client.ini.
const DEFAULT_GATEWAY: String = "http://service.dyingstar.local"

## Fallback per-service base URLs (gateway + path), overridden by client.ini [<service>] url/path.
const DEFAULT_BASE: Dictionary = {
	SERVICE_SOCIAL: "http://service.dyingstar.local/social",
	SERVICE_MISSION: "http://service.dyingstar.local/mission",
	SERVICE_ECONOMIE: "http://service.dyingstar.local/economie",
	SERVICE_INVENTORY: "http://service.dyingstar.local/inventory",
	SERVICE_MARKET: "http://service.dyingstar.local/market",
}

var _http: HTTPRequest = null
var _client: HttpClient = null
var _base: Dictionary = DEFAULT_BASE.duplicate()
var _scheme: String = DEFAULT_SCHEME
var _player_id_cache: String = ""
## The token given on the command line (`--token=<jwt>`), the way the game client passes it. Used as a
## fallback when no live network agent holds one — e.g. the standalone terminal smoke scene.
var _cli_token: String = ""


func _ready() -> void:
	# The HTTPRequest MUST live in the tree: created (and parented) here, it is polled by the engine,
	# which is what makes request_completed ever fire. A node built inside a coroutine is not polled.
	_http = HTTPRequest.new()
	_http.timeout = HttpClient.DEFAULT_TIMEOUT_S
	add_child(_http)
	_client = HTTP_CLIENT.new(_http)
	_cli_token = _read_cli_token()
	_load_config()


## `--token=<jwt>` from the command line, the same flag server/client.gd reads. Empty when absent.
static func _read_cli_token() -> String:
	for arg: String in OS.get_cmdline_args():
		if arg.begins_with("--token="):
			return arg.substr("--token=".length())
	return ""


func _load_config() -> void:
	var config := ConfigFile.new()
	if config.load("client.ini") != OK:
		return
	# Scheme first: it rewrites every base URL below, whichever scheme they were written with.
	if config.has_section_key("services", "scheme"):
		var chosen: String = str(config.get_value("services", "scheme", DEFAULT_SCHEME)).strip_edges().to_lower()
		if chosen == "http" or chosen == "https":
			_scheme = chosen
		else:
			push_warning("[PlayerServices] client.ini [services] scheme '%s' is neither http nor https"
					% chosen)
	# The gateway every service hangs off, unless a service overrides its whole url.
	var gateway: String = DEFAULT_GATEWAY
	if config.has_section_key("services", "url"):
		var configured: String = str(config.get_value("services", "url", "")).strip_edges()
		if configured != "":
			gateway = configured
	for service: String in SERVICES:
		var url: String = ""
		if config.has_section_key(service, "url"):
			url = str(config.get_value(service, "url", "")).strip_edges()
		if url == "":
			var path: String = "/" + service
			if config.has_section_key(service, "path"):
				var configured_path: String = str(config.get_value(service, "path", "")).strip_edges()
				if configured_path != "":
					path = configured_path if configured_path.begins_with("/") else "/" + configured_path
			url = gateway.rstrip("/") + path
		_base[service] = _with_scheme(url, _scheme)


## The scheme the services are reached with (http/https), as chosen in client.ini.
func scheme() -> String:
	return _scheme


## Replace whatever scheme [param url] carries with [param scheme]; a bare "host[:port]" is accepted
## and gets the scheme prepended. A url the caller left empty is returned untouched.
static func _with_scheme(url: String, scheme: String) -> String:
	var rest: String = url.strip_edges()
	var sep: int = rest.find("://")
	if sep != -1:
		rest = rest.substr(sep + 3)
	rest = rest.lstrip("/").rstrip("/")
	if rest == "":
		return url
	return "%s://%s" % [scheme, rest]


## True when a request can actually be attempted (not the headless server, configuration loaded).
func is_available() -> bool:
	return not GameOrchestrator.is_server() and _client != null


## Whether a player token is present (network agent or `--token=`). A reachable /api/health with no
## token is exactly the "it is an auth problem, not a network one" case.
func has_token() -> bool:
	return _player_token() != ""


## The server's own service-account token (OAuth2 client credentials), fetched and renewed by
## [ServiceAuth]. Distinct from the player token: its `sub` is a service account, so it is good for
## the internal/service routes only. Empty when [ServiceAuth] is not configured or the grant failed.
## Not consumed by the player-facing methods yet — it is the transport for future server-to-service
## calls.
func service_token() -> String:
	return await ServiceAuth.get_token()


func base_url(service: String) -> String:
	return str(_base.get(service, ""))


# ---------------------------------------------------------------------------------------------
# Profile / Me
# ---------------------------------------------------------------------------------------------

func profile_get() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me")

func profile_update(patch: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_patch(SERVICE_SOCIAL, "/api/me", patch)
	if _ok(r): changed.emit("profile")
	return r

func my_activity(limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/activity", {"limit": limit})

func my_reputation(limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/reputation", {"limit": limit})

func my_sanctions() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/sanctions")

## Every catalogued organisation action with its evaluation rules, localized through
## Accept-Language: what a rank or office permission means (legacy flag, `satisfiedBy`,
## `defaultMember`). Readable by any authenticated player.
func permission_catalog() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/permissions/catalog")


# ---------------------------------------------------------------------------------------------
# Friends
# ---------------------------------------------------------------------------------------------

func friends_list() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/friends")

func friends_online() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/friends/online")

func friend_requests() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/friends/requests")

func friend_send(player_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/friends/requests", {"playerId": player_id})
	if _ok(r): changed.emit("friends")
	return r

func friend_accept(request_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/friends/requests/%d/accept" % request_id)
	if _ok(r): changed.emit("friends")
	return r

func friend_decline(request_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/friends/requests/%d/decline" % request_id)
	if _ok(r): changed.emit("friends")
	return r

func friend_suggestions(limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/friends/suggestions", {"limit": limit})

func friend_remove(player_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_SOCIAL, "/api/friends/%s" % player_id)
	if _ok(r): changed.emit("friends")
	return r


# ---------------------------------------------------------------------------------------------
# Temporary groups (a player belongs to at most one)
# ---------------------------------------------------------------------------------------------

## The caller's group with their join date, or null when they have none.
func my_group() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/groups")

func group_invitations() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/group/invitations")

func group_invitation_accept(invitation_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL,
			"/api/me/group/invitations/%d/accept" % invitation_id)
	if _ok(r): changed.emit("groups")
	return r

func group_invitation_decline(invitation_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL,
			"/api/me/group/invitations/%d/decline" % invitation_id)
	if _ok(r): changed.emit("groups")
	return r

func group_create(body: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/groups", body)
	if _ok(r): changed.emit("groups")
	return r

func group_get(group_id: String) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/groups/%s" % group_id)

func group_update(group_id: String, patch: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_patch(SERVICE_SOCIAL, "/api/groups/%s" % group_id, patch)
	if _ok(r): changed.emit("groups")
	return r

func group_disband(group_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_SOCIAL, "/api/groups/%s" % group_id)
	if _ok(r): changed.emit("groups")
	return r

func group_members(group_id: String) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/groups/%s/members" % group_id)

func group_invite(group_id: String, player_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL,
			"/api/groups/%s/invitations" % group_id, {"playerId": player_id})
	if _ok(r): changed.emit("groups")
	return r

func group_leave(group_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/groups/%s/leave" % group_id)
	if _ok(r): changed.emit("groups")
	return r

func group_member_remove(group_id: String, player_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_SOCIAL,
			"/api/groups/%s/members/%s" % [group_id, player_id])
	if _ok(r): changed.emit("groups")
	return r


# ---------------------------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------------------------

func profiles_search(search: String = "", limit: int = 20, entity_type: String = "") -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/profiles",
			{"search": search, "limit": limit, "entityType": entity_type})

func profile_get_by_id(player_id: String) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/profiles/%s" % player_id)


# ---------------------------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------------------------

func blocks_list() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/blocks")

func block_add(player_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/blocks", {"playerId": player_id})
	if _ok(r): changed.emit("friends")
	return r

func block_remove(player_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_SOCIAL, "/api/blocks/%s" % player_id)
	if _ok(r): changed.emit("friends")
	return r


# ---------------------------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------------------------

func reports_list(limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/reports", {"limit": limit})

func report_create(target_type: String, target_id: String, reason: String, message: String = "") -> Dictionary:
	var body := {"targetType": target_type, "targetId": target_id, "reason": reason}
	if message != "":
		body["message"] = message
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/reports", body)
	if _ok(r): changed.emit("reports")
	return r


# ---------------------------------------------------------------------------------------------
# Corporations
# ---------------------------------------------------------------------------------------------

func corporations_list(search: String = "", limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/corporations", {"search": search, "limit": limit})

func corporation_create(name: String, ticker: String, description: String = "",
		recruitment: String = "apply") -> Dictionary:
	var body := {"name": name, "ticker": ticker, "recruitment": recruitment}
	if description != "":
		body["description"] = description
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/corporations", body)
	if _ok(r): changed.emit("corporations")
	return r

func corporation_get(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/corporations/%s" % corporation_id)

func corporation_update(corporation_id: String, patch: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_patch(SERVICE_SOCIAL, "/api/corporations/%s" % corporation_id, patch)
	if _ok(r): changed.emit("corporations")
	return r

func corporation_disband(corporation_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_SOCIAL, "/api/corporations/%s" % corporation_id)
	if _ok(r): changed.emit("corporations")
	return r

func corporation_activity(corporation_id: String, limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/corporations/%s/activity" % corporation_id, {"limit": limit})

## Members are served on the same path by BOTH social and economie (different shapes). [param service]
## picks which one answers.
func corporation_members(corporation_id: String, service: String = SERVICE_SOCIAL) -> Dictionary:
	return await _http_get(service, "/api/corporations/%s/members" % corporation_id)

func corporation_member_rank(corporation_id: String, player_id: String, rank_id: int) -> Dictionary:
	var r: Dictionary = await _http_patch(SERVICE_SOCIAL,
			"/api/corporations/%s/members/%s" % [corporation_id, player_id], {"rankId": rank_id})
	if _ok(r): changed.emit("corporations")
	return r

func corporation_member_remove(corporation_id: String, player_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_SOCIAL,
			"/api/corporations/%s/members/%s" % [corporation_id, player_id])
	if _ok(r): changed.emit("corporations")
	return r

func corporation_ranks(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/corporations/%s/ranks" % corporation_id)

func corporation_rank_create(corporation_id: String, name: String, priority: int,
		permissions: Array = [], is_default: bool = false) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/corporations/%s/ranks" % corporation_id,
			{"name": name, "priority": priority, "permissions": permissions, "isDefault": is_default})
	if _ok(r): changed.emit("corporations")
	return r

func corporation_rank_update(corporation_id: String, rank_id: int, patch: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_patch(SERVICE_SOCIAL,
			"/api/corporations/%s/ranks/%d" % [corporation_id, rank_id], patch)
	if _ok(r): changed.emit("corporations")
	return r

func corporation_rank_delete(corporation_id: String, rank_id: int) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_SOCIAL,
			"/api/corporations/%s/ranks/%d" % [corporation_id, rank_id])
	if _ok(r): changed.emit("corporations")
	return r

func corporation_requests(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/corporations/%s/requests" % corporation_id)

func corporation_request_accept(corporation_id: String, request_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL,
			"/api/corporations/%s/requests/%d/accept" % [corporation_id, request_id])
	if _ok(r): changed.emit("corporations")
	return r

func corporation_request_decline(corporation_id: String, request_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL,
			"/api/corporations/%s/requests/%d/decline" % [corporation_id, request_id])
	if _ok(r): changed.emit("corporations")
	return r

func corporation_invite(corporation_id: String, player_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL,
			"/api/corporations/%s/invitations" % corporation_id, {"playerId": player_id})
	if _ok(r): changed.emit("corporations")
	return r

func corporation_join(corporation_id: String, message: String = "") -> Dictionary:
	var body: Dictionary = {}
	if message != "":
		body["message"] = message
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/corporations/%s/join" % corporation_id, body)
	if _ok(r): changed.emit("corporations")
	return r

func corporation_transfer(corporation_id: String, player_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL,
			"/api/corporations/%s/transfer" % corporation_id, {"playerId": player_id})
	if _ok(r): changed.emit("corporations")
	return r

## Attach the corporation to a holding company, or detach it. [param parent_id] empty sends `null` —
## the server reads that as "no parent" and makes the corporation independent again.
func corporation_set_parent(corporation_id: String, parent_id: String) -> Dictionary:
	var body := {"parentId": null if parent_id.strip_edges() == "" else parent_id.strip_edges()}
	var r: Dictionary = await _http_put(SERVICE_SOCIAL,
			"/api/corporations/%s/parent" % corporation_id, body)
	if _ok(r): changed.emit("corporations")
	return r

## Direct subsidiaries of a corporation (holding companies own others).
func corporation_subsidiaries(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/corporations/%s/subsidiaries" % corporation_id)

## Every corporation the caller belongs to, with rank (empty array when none).
func my_corporations() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/corporations")

func my_corporation_requests() -> Dictionary:
	return await _http_get(SERVICE_SOCIAL, "/api/me/corporation/requests")

func my_corporation_request_accept(request_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/me/corporation/requests/%d/accept" % request_id)
	if _ok(r): changed.emit("corporations")
	return r

func my_corporation_request_decline(request_id: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_SOCIAL, "/api/me/corporation/requests/%d/decline" % request_id)
	if _ok(r): changed.emit("corporations")
	return r


# ---------------------------------------------------------------------------------------------
# Missions
# ---------------------------------------------------------------------------------------------

func missions_list(status: String = "", kind: String = "", category: String = "",
		issuer_type: String = "", issuer_id: String = "", visibility: String = "",
		limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_MISSION, "/api/missions", {
		"status": status, "kind": kind, "category": category,
		"issuerType": issuer_type, "issuerId": issuer_id, "visibility": visibility, "limit": limit,
	})

## The mission builder's discovery catalogue: categories, objective kinds (evaluation, quantity
## flag, summary, params JSON Schema), prerequisite kinds and the reward schema.
func mission_kinds() -> Dictionary:
	return await _http_get(SERVICE_MISSION, "/api/missions/kinds")

## Dry-run a mission spec (mode "player" enforces the reward/escrow rules): no persistence, no
## escrow. Returns the normalized spec on success, or the precise 400 the create would answer.
func mission_validate(mission_body: Dictionary) -> Dictionary:
	return await _http_post(SERVICE_MISSION, "/api/missions/validate",
			{"mode": "player", "mission": mission_body})

## Restrict a mission to the members of the caller's group (the Squad). Creator or issuing
## corporation member only; rejected while the mission has active assignees.
func mission_share(mission_id: String, group_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MISSION,
			"/api/missions/%s/share" % mission_id, {"groupId": group_id})
	if _ok(r): changed.emit("missions")
	return r

## Back to public/corporation access (rejected while the mission has active assignees).
func mission_unshare(mission_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_MISSION, "/api/missions/%s/share" % mission_id)
	if _ok(r): changed.emit("missions")
	return r

func mission_create(body: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MISSION, "/api/missions", body)
	if _ok(r): changed.emit("missions")
	return r

func mission_get(mission_id: String) -> Dictionary:
	return await _http_get(SERVICE_MISSION, "/api/missions/%s" % mission_id)

func mission_accept(mission_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MISSION, "/api/missions/%s/accept" % mission_id)
	if _ok(r): changed.emit("missions")
	return r

func mission_abandon(mission_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MISSION, "/api/missions/%s/abandon" % mission_id)
	if _ok(r): changed.emit("missions")
	return r

func mission_complete(mission_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MISSION, "/api/missions/%s/complete" % mission_id)
	if _ok(r): changed.emit("missions")
	return r

func mission_progress(mission_id: String, objective_id: String, quantity: int) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MISSION,
			"/api/missions/%s/objectives/%s/progress" % [mission_id, objective_id], {"quantity": quantity})
	if _ok(r): changed.emit("missions")
	return r

## Confirm an issuer-verified objective (`manual` kind) — mission creator only.
func mission_confirm(mission_id: String, objective_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MISSION,
			"/api/missions/%s/objectives/%s/confirm" % [mission_id, objective_id])
	if _ok(r): changed.emit("missions")
	return r

func my_missions(status: String = "", limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_MISSION, "/api/me/missions", {"status": status, "limit": limit})


# ---------------------------------------------------------------------------------------------
# Economy
# ---------------------------------------------------------------------------------------------

func wallet() -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE, "/api/me/wallet")

func wallet_transactions(limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE, "/api/me/wallet/transactions", {"limit": limit})

func transfer(to_player_id: String, amount: int, memo: String = "") -> Dictionary:
	var body := {"toPlayerId": to_player_id, "amount": amount}
	if memo != "":
		body["memo"] = memo
	var r: Dictionary = await _http_post(SERVICE_ECONOMIE, "/api/transfers", body)
	if _ok(r): changed.emit("economy")
	return r

func corporation_wallet(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE, "/api/corporations/%s/wallet" % corporation_id)

func corporation_wallet_transactions(corporation_id: String, limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE,
			"/api/corporations/%s/wallet/transactions" % corporation_id, {"limit": limit})

func corporation_donation(corporation_id: String, amount: int, memo: String = "") -> Dictionary:
	var body := {"amount": amount}
	if memo != "":
		body["memo"] = memo
	var r: Dictionary = await _http_post(SERVICE_ECONOMIE,
			"/api/corporations/%s/donations" % corporation_id, body)
	if _ok(r): changed.emit("economy")
	return r

func corporation_report(corporation_id: String, from: String = "", to: String = "") -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE, "/api/corporations/%s/report" % corporation_id,
			{"from": from, "to": to})

## Role salary defaults and per-member overrides (leader/treasurer only).
func corporation_salaries(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE, "/api/corporations/%s/salaries" % corporation_id)

func corporation_salary_set_member(corporation_id: String, player_id: String, amount: int,
		currency: String = "credits", enabled: bool = true) -> Dictionary:
	var r: Dictionary = await _http_put(SERVICE_ECONOMIE,
			"/api/corporations/%s/salaries/members/%s" % [corporation_id, player_id],
			_salary_body(amount, currency, enabled))
	if _ok(r): changed.emit("economy")
	return r

func corporation_salary_remove_member(corporation_id: String, player_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_ECONOMIE,
			"/api/corporations/%s/salaries/members/%s" % [corporation_id, player_id])
	if _ok(r): changed.emit("economy")
	return r

func corporation_salary_set_role(corporation_id: String, role: String, amount: int,
		currency: String = "credits", enabled: bool = true) -> Dictionary:
	var r: Dictionary = await _http_put(SERVICE_ECONOMIE,
			"/api/corporations/%s/salaries/roles/%s" % [corporation_id, role],
			_salary_body(amount, currency, enabled))
	if _ok(r): changed.emit("economy")
	return r

## One-off prime paid to a member from the treasury (leader/treasurer only).
func corporation_prime(corporation_id: String, player_id: String, amount: int,
		currency: String = "credits", memo: String = "") -> Dictionary:
	var body := {"amount": amount, "currency": currency}
	if memo != "":
		body["memo"] = memo
	var r: Dictionary = await _http_post(SERVICE_ECONOMIE,
			"/api/corporations/%s/members/%s/prime" % [corporation_id, player_id], body)
	if _ok(r): changed.emit("economy")
	return r

## Pay every member's salary now from the treasury (leader/treasurer only).
func corporation_payroll(corporation_id: String, currency: String = "credits") -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_ECONOMIE, "/api/corporations/%s/payroll" % corporation_id,
			null, {"currency": currency})
	if _ok(r): changed.emit("economy")
	return r

## My tax debts, due and settled, newest first.
func my_taxes() -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE, "/api/me/taxes")

## Settle every affordable due tax debt. An empty currency settles in every currency, an empty
## entity id to every entity the caller owes — both fields are optional on the wire.
func my_taxes_pay(currency: String = "", entity_id: String = "") -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_ECONOMIE, "/api/me/taxes/pay",
			_tax_pay_body(currency, entity_id))
	if _ok(r): changed.emit("economy")
	return r

## Tax debts of a corporation (member only).
func corporation_taxes(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_ECONOMIE, "/api/corporations/%s/taxes" % corporation_id)

## Settle a corporation's affordable due taxes (`economie:treasury:manage`). The treasury moves, so
## both the corporation section and the wallet balance behind it are told.
func corporation_taxes_pay(corporation_id: String, currency: String = "",
		entity_id: String = "") -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_ECONOMIE,
			"/api/corporations/%s/taxes/pay" % corporation_id, _tax_pay_body(currency, entity_id))
	if _ok(r):
		changed.emit("corporations")
		changed.emit("economy")
	return r

static func _salary_body(amount: int, currency: String, enabled: bool) -> Dictionary:
	return {"amount": amount, "currency": currency, "enabled": enabled}


## The `{currency?, entityId?}` body the two tax-payment endpoints share: fields the caller leaves
## empty are absent rather than blank, so the service keeps its own "every currency" default.
static func _tax_pay_body(currency: String, entity_id: String) -> Dictionary:
	var body: Dictionary = {}
	if currency.strip_edges() != "":
		body["currency"] = currency.strip_edges()
	if entity_id.strip_edges() != "":
		body["entityId"] = entity_id.strip_edges()
	return body


# ---------------------------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------------------------

## The caller's inventory: stacks (with held/available) and owned instances.
func inventory_me() -> Dictionary:
	return await _http_get(SERVICE_INVENTORY, "/api/me/inventory")

## One of the caller's stacks, with its held and available quantities.
func inventory_me_stack(good_type: String) -> Dictionary:
	return await _http_get(SERVICE_INVENTORY, "/api/me/inventory/stacks/%s" % good_type)

## A corporation's inventory (member only, membership checked by Social).
func corporation_inventory(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_INVENTORY, "/api/corporations/%s/inventory" % corporation_id)

func corporation_inventory_stack(corporation_id: String, good_type: String) -> Dictionary:
	return await _http_get(SERVICE_INVENTORY,
			"/api/corporations/%s/inventory/stacks/%s" % [corporation_id, good_type])


# ---------------------------------------------------------------------------------------------
# Points of interest
# ---------------------------------------------------------------------------------------------

## The POIs of the caller's scope: owned ones, read-only grants, and every POI published `public`.
func poi_list() -> Dictionary:
	return await _http_get(SERVICE_INVENTORY, "/api/me/pois")

## Create a POI for the caller — or, with `owner` = `{"type": "corporation"|"political", "id": ...}`
## in the body, for an organisation the caller manages (which needs `inventory:poi:manage` there).
func poi_create(body: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_INVENTORY, "/api/me/pois", body)
	if _ok(r): changed.emit("pois")
	return r

## One POI with its shares (owned, granted or public).
func poi_get(poi_id: String) -> Dictionary:
	return await _http_get(SERVICE_INVENTORY, "/api/me/pois/%s" % poi_id)

## Edit a POI the caller manages: name, description, location, visibility. Ownership is unchanged.
func poi_update(poi_id: String, patch: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_patch(SERVICE_INVENTORY, "/api/me/pois/%s" % poi_id, patch)
	if _ok(r): changed.emit("pois")
	return r

## Delete a POI the caller manages; its shares cascade away.
func poi_delete(poi_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_INVENTORY, "/api/me/pois/%s" % poi_id)
	if _ok(r): changed.emit("pois")
	return r

## Grant read-only access to a player, an NPC, a corporation or a political entity.
func poi_share(poi_id: String, grantee_type: String, grantee_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_INVENTORY, "/api/me/pois/%s/shares" % poi_id,
			{"granteeType": grantee_type, "granteeId": grantee_id})
	if _ok(r): changed.emit("pois")
	return r

## Revoke one read-only grant (a share the caller created).
func poi_unshare(poi_id: String, grantee_type: String, grantee_id: String) -> Dictionary:
	var r: Dictionary = await _http_delete(SERVICE_INVENTORY,
			"/api/me/pois/%s/shares/%s/%s" % [poi_id, grantee_type, grantee_id])
	if _ok(r): changed.emit("pois")
	return r

## Hand the POI's ownership over; the previous owner keeps no implicit grant.
func poi_transfer(poi_id: String, to_type: String, to_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_INVENTORY, "/api/me/pois/%s/transfer" % poi_id,
			{"toType": to_type, "toId": to_id})
	if _ok(r): changed.emit("pois")
	return r

## POIs owned by or granted to a corporation (member only, membership checked in Social).
func corporation_pois(corporation_id: String) -> Dictionary:
	return await _http_get(SERVICE_INVENTORY, "/api/corporations/%s/pois" % corporation_id)

## One POI of a corporation's scope (member only).
func corporation_poi(corporation_id: String, poi_id: String) -> Dictionary:
	return await _http_get(SERVICE_INVENTORY,
			"/api/corporations/%s/pois/%s" % [corporation_id, poi_id])


# ---------------------------------------------------------------------------------------------
# Market
# ---------------------------------------------------------------------------------------------

## Tradable good types (enabled only).
func market_catalog() -> Dictionary:
	return await _http_get(SERVICE_MARKET, "/api/market/catalog")

## Order book depth (open buy/sell counts) for a good type.
func market_book(good_type: String) -> Dictionary:
	return await _http_get(SERVICE_MARKET, "/api/market/book", {"goodType": good_type})

func market_orders(good_type: String = "", side: String = "", status: String = "",
		limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_MARKET, "/api/market/orders",
			{"goodType": good_type, "side": side, "status": status, "limit": limit})

func market_order(order_id: String) -> Dictionary:
	return await _http_get(SERVICE_MARKET, "/api/market/orders/%s" % order_id)

func market_order_create(body: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MARKET, "/api/market/orders", body)
	if _ok(r): changed.emit("market")
	return r

func market_order_cancel(order_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MARKET, "/api/market/orders/%s/cancel" % order_id)
	if _ok(r): changed.emit("market")
	return r

func market_demands(good_type: String = "", status: String = "", limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_MARKET, "/api/market/demands",
			{"goodType": good_type, "status": status, "limit": limit})

func market_demand(demand_id: String) -> Dictionary:
	return await _http_get(SERVICE_MARKET, "/api/market/demands/%s" % demand_id)

func market_demand_create(body: Dictionary) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MARKET, "/api/market/demands", body)
	if _ok(r): changed.emit("market")
	return r

func market_demand_cancel(demand_id: String) -> Dictionary:
	var r: Dictionary = await _http_post(SERVICE_MARKET, "/api/market/demands/%s/cancel" % demand_id)
	if _ok(r): changed.emit("market")
	return r

func market_demand_fulfill(demand_id: String, unit_price: int, corporation_id: String = "") -> Dictionary:
	var body := {"unitPrice": unit_price}
	if corporation_id != "":
		body["corporationId"] = corporation_id
	var r: Dictionary = await _http_post(SERVICE_MARKET,
			"/api/market/demands/%s/fulfill" % demand_id, body)
	if _ok(r): changed.emit("market")
	return r

func market_trades(status: String = "", limit: int = 20) -> Dictionary:
	return await _http_get(SERVICE_MARKET, "/api/market/trades", {"status": status, "limit": limit})


# ---------------------------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------------------------

func health(service: String = SERVICE_SOCIAL) -> Dictionary:
	var h := PackedStringArray([
			"Accept: application/json",
			"Accept-Language: " + SettingsManager.language.resolve(),
	])
	return await _client.request(HTTPClient.METHOD_GET, _url(service, "/api/health", {}), h)


# ---------------------------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------------------------

func _http_get(service: String, path: String, query: Dictionary = {}) -> Dictionary:
	if not is_available():
		return _unavailable()
	return await _client.request(HTTPClient.METHOD_GET, _url(service, path, query), _headers())

func _http_post(service: String, path: String, body: Variant = null, query: Dictionary = {}) -> Dictionary:
	if not is_available():
		return _unavailable()
	return await _client.request(HTTPClient.METHOD_POST, _url(service, path, query), _headers(), body)

func _http_patch(service: String, path: String, body: Variant = null, query: Dictionary = {}) -> Dictionary:
	if not is_available():
		return _unavailable()
	return await _client.request(HTTPClient.METHOD_PATCH, _url(service, path, query), _headers(), body)

func _http_put(service: String, path: String, body: Variant = null, query: Dictionary = {}) -> Dictionary:
	if not is_available():
		return _unavailable()
	return await _client.request(HTTPClient.METHOD_PUT, _url(service, path, query), _headers(), body)

func _http_delete(service: String, path: String, query: Dictionary = {}) -> Dictionary:
	if not is_available():
		return _unavailable()
	return await _client.request(HTTPClient.METHOD_DELETE, _url(service, path, query), _headers())

func _url(service: String, path: String, query: Dictionary = {}) -> String:
	var url: String = base_url(service).rstrip("/") + path
	var parts: PackedStringArray = PackedStringArray()
	for key: Variant in query:
		var value: Variant = query[key]
		if value == null or str(value) == "":
			continue
		parts.append("%s=%s" % [str(key).uri_encode(), str(value).uri_encode()])
	if parts.size() > 0:
		url += "?" + "&".join(parts)
	return url

func _headers() -> PackedStringArray:
	# Accept-Language carries the player's language — resolve() turns "auto" into a real en/fr
	# code — so the services answer their own text (error messages, catalogue summaries) in it.
	var headers := PackedStringArray([
			"Accept: application/json",
			"Accept-Language: " + SettingsManager.language.resolve(),
	])
	var token: String = _player_token()
	if token != "":
		headers.append("Authorization: Bearer " + token)
	return headers

## The game client's JWT (the `--token=` argument, held by the client network agent) — the same
## token the chat transport reuses. Falls back to the command-line token when no network agent is
## alive (standalone smoke scene), and is empty in a token-less local dev session.
func _player_token() -> String:
	var agent = NetworkOrchestrator.network_agent
	if agent != null and "token" in agent and str(agent.token) != "":
		return str(agent.token)
	return _cli_token


## The caller's player id, read from the token's `sub` claim. Several routes carry it in the path
## (leave a corporation, set a member's rank) and there is no /me shortcut for them. Empty when no
## token is present.
func player_id() -> String:
	if _player_id_cache == "":
		var subject: String = _jwt_sub(_player_token())
		if subject != "":
			_player_id_cache = subject
		return subject
	return _player_id_cache


## The `exp` claim of the current token (unix seconds), or 0 when there is no readable claim. A local,
## offline answer to "is it still valid?" — the server-side answer needs a protected call.
func token_expiry() -> int:
	return int(_jwt_payload(_player_token()).get("exp", 0))


## Seconds before the token expires (negative once past). 0 when the token is absent/has no exp.
func token_seconds_left() -> int:
	var expiry: int = token_expiry()
	if expiry <= 0:
		return 0
	return expiry - int(Time.get_unix_time_from_system())


static func _jwt_sub(token: String) -> String:
	return str(_jwt_payload(token).get("sub", ""))


## The token's payload claims (base64url middle segment), or {} when it is not a readable JWT.
static func _jwt_payload(token: String) -> Dictionary:
	var parts: PackedStringArray = token.split(".")
	if parts.size() < 2:
		return {}
	var encoded: String = parts[1].replace("-", "+").replace("_", "/")
	while encoded.length() % 4 != 0:
		encoded += "="
	var payload: Variant = JSON.parse_string(Marshalls.base64_to_utf8(encoded))
	if payload is Dictionary:
		return payload
	return {}


static func _ok(result: Dictionary) -> bool:
	return bool(result.get("ok", false))

static func _unavailable() -> Dictionary:
	return {"ok": false, "status": 0, "data": null, "error": "SERVICES_UNAVAILABLE",
			"result": HTTPRequest.RESULT_CANT_CONNECT}
