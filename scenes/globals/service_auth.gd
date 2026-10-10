extends Node

## Service-account token provider: the single owner of the game server's own Keycloak identity.
##
## The player-facing [PlayerServices] carries a *player* JWT handed over by the launcher
## (`--token=`, `sub` = player id). The dedicated server has no player, but it still has to reach
## the services' internal routes (`/api/internal/*`) — and the services authenticate each other the
## same way. Both use an OAuth2 **client credentials** grant: the process holds a `client_id` and a
## `client_secret`, exchanges them at Keycloak's token endpoint for a short-lived access token, and
## renews it before it expires.
##
## Credentials come from the environment (the container passes them in), with a `server.ini [auth]`
## fallback for a run straight from a config file. When neither is present the provider is simply
## "not configured": [method is_configured] is false and [method get_token] answers "", so a
## token-less local dev session behaves like the rest of the backend surface (clean failure, no
## crash). Secrets are never logged.
##
## The token's `sub` is the client's service-account id, NOT a player id: it is good for the
## internal/service routes only, never for the player `/api/*` routes.

const HTTP_CLIENT := preload("res://ui/services/http_client.gd")

const ENV_URL: String = "KEYCLOAK_URL"
const ENV_REALM: String = "KEYCLOAK_REALM"
const ENV_CLIENT_ID: String = "KEYCLOAK_CLIENT_ID"
const ENV_CLIENT_SECRET: String = "KEYCLOAK_CLIENT_SECRET"

const DEFAULT_REALM: String = "dyingstar"
## Refresh this many seconds before the token's own `exp`, so a call made right after a renew never
## races the expiry.
const RENEW_MARGIN_S: int = 30

var _url: String = ""
var _realm: String = DEFAULT_REALM
var _client_id: String = ""
var _client_secret: String = ""

## The current access token and the unix instant it goes stale (exp - RENEW_MARGIN_S). Zero means
## "no token": either none fetched yet or the last fetch failed.
var _token: String = ""
var _refresh_at: int = 0
## Set while a fetch is in flight so a burst of callers shares the one request.
var _fetching: bool = false

var _http: HTTPRequest = null


func _ready() -> void:
	# The HTTPRequest MUST live in the tree: created (and parented) here, it is polled by the engine,
	# which is what makes request_completed ever fire. A node built inside a coroutine is not polled.
	_http = HTTPRequest.new()
	_http.timeout = HTTP_CLIENT.DEFAULT_TIMEOUT_S
	add_child(_http)
	_load_config()


func _load_config() -> void:
	_url = OS.get_environment(ENV_URL).strip_edges()
	_realm = OS.get_environment(ENV_REALM).strip_edges()
	_client_id = OS.get_environment(ENV_CLIENT_ID).strip_edges()
	_client_secret = OS.get_environment(ENV_CLIENT_SECRET).strip_edges()
	# server.ini fills whatever the environment left empty, so a file-configured server (or a run from
	# the editor) works without exporting variables.
	var config := ConfigFile.new()
	if config.load("server.ini") == OK:
		if _url == "":
			_url = str(config.get_value("auth", "url", _url)).strip_edges()
		if _realm == "":
			_realm = str(config.get_value("auth", "realm", _realm)).strip_edges()
		if _client_id == "":
			_client_id = str(config.get_value("auth", "client_id", _client_id)).strip_edges()
		if _client_secret == "":
			_client_secret = str(config.get_value("auth", "client_secret", _client_secret)).strip_edges()
	_url = _with_scheme(_url)
	if _realm == "":
		_realm = DEFAULT_REALM


## A bare "host[:port]" gets https, since the auth server is never plain HTTP in practice.
static func _with_scheme(url: String) -> String:
	var rest: String = url.strip_edges().rstrip("/")
	if rest == "":
		return ""
	if rest.find("://") != -1:
		return rest
	return "https://%s" % rest


## True when the four credentials needed to ask Keycloak for a token are all present.
func is_configured() -> bool:
	return _url != "" and _realm != "" and _client_id != "" and _client_secret != ""


## Which of the four credentials are missing, by NAME (never value): "url", "realm", "client_id",
## "client_secret". So a consumer can say exactly what to fill in without printing a secret.
## The secret is only ever named, never read out.
func missing_config() -> PackedStringArray:
	var missing := PackedStringArray()
	if _url == "":
		missing.append("url")
	if _realm == "":
		missing.append("realm")
	if _client_id == "":
		missing.append("client_id")
	if _client_secret == "":
		missing.append("client_secret")
	return missing


## The Keycloak token endpoint for this realm.
func token_url() -> String:
	return "%s/realms/%s/protocol/openid-connect/token" % [_url, _realm]


## The current access token, fetching or renewing it when needed. Empty when the provider is not
## configured or the last fetch failed — the caller treats "" as "no service identity".
func get_token() -> String:
	if not is_configured():
		return ""
	if _token != "" and int(Time.get_unix_time_from_system()) < _refresh_at:
		return _token
	if _fetching:
		# Another caller is already asking Keycloak: wait for its result instead of firing a second
		# grant (which would race the stored token).
		while _fetching:
			await get_tree().process_frame
		return _token
	var fetched: String = await request_token()
	return fetched


## Force one client-credentials exchange and store the result. Returns the fresh token, or "" on any
## failure (unreachable, rejected client, malformed answer). Safe to call directly to renew now.
func request_token() -> String:
	if not is_configured():
		return ""
	_fetching = true
	var form: String = _form_body()
	var headers := PackedStringArray([
		"Content-Type: application/x-www-form-urlencoded",
		"Accept: application/json",
	])
	var err: int = _http.request(token_url(), headers, HTTPClient.METHOD_POST, form)
	if err != OK:
		_fetching = false
		push_warning("[ServiceAuth] token request could not start (error %d)" % err)
		return ""
	var response: Array = await _http.request_completed
	_fetching = false
	return _store(response)


## The `Authorization` header for a service call, or an empty list when no token is available.
func authorization_header() -> PackedStringArray:
	var token: String = await get_token()
	if token == "":
		return PackedStringArray()
	return PackedStringArray(["Authorization: Bearer " + token])


func _form_body() -> String:
	return "grant_type=client_credentials&client_id=%s&client_secret=%s" % [
		_client_id.uri_encode(), _client_secret.uri_encode(),
	]


func _store(response: Array) -> String:
	if response.size() < 4:
		push_warning("[ServiceAuth] no response from the token endpoint")
		return ""
	var result_code: int = int(response[0])
	var status: int = int(response[1])
	var body: Variant = response[3]
	var text: String = ""
	if body is PackedByteArray:
		text = (body as PackedByteArray).get_string_from_utf8()
	var data: Variant = JSON.parse_string(text) if text.strip_edges() != "" else null
	if result_code != HTTPRequest.RESULT_SUCCESS or status < 200 or status >= 300 or not (data is Dictionary):
		push_warning("[ServiceAuth] token refused (transport %d, status %d)" % [result_code, status])
		return ""
	var token: String = str((data as Dictionary).get("access_token", "")).strip_edges()
	if token == "":
		push_warning("[ServiceAuth] token endpoint answered without an access_token")
		return ""
	var expires_in: int = int((data as Dictionary).get("expires_in", 0))
	_token = token
	# Prefer the token's own `exp` claim over expires_in; fall back to expires_in when unreadable.
	var exp: int = int(_jwt_payload(token).get("exp", 0))
	if exp <= 0:
		exp = int(Time.get_unix_time_from_system()) + expires_in
	_refresh_at = exp - RENEW_MARGIN_S
	return _token


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
