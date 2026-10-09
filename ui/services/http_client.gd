class_name HttpClient
extends RefCounted

## Shared async HTTP helper for the player-facing REST services (mission / social / economie).
##
## Owns nothing of the network stack itself: it is handed ONE [HTTPRequest] node (created and
## parented by PlayerServices, which lives in the tree and is therefore polled by the engine).
## A fresh HTTPRequest built inside a coroutine is never polled and times out — the trap
## documented in addons/dyingstar/dyingstar.gd.
##
## ONE request at a time: an HTTPRequest cannot start a second request before the first completes.
## [method request] serialises callers through a tiny lock so a burst from the interface (a refresh
## firing several reads) can never hit ERR_BUSY and silently drop a call.

## Emitted when a busy request finishes, waking the coroutines parked on the lock.
signal slot_free

const DEFAULT_TIMEOUT_S: float = 20.0

var _http: HTTPRequest
var _busy: bool = false

func _init(http: HTTPRequest) -> void:
	_http = http

## Perform one request and return a uniform result:
##   { ok: bool, status: int, data: Variant, error: String, result: int }
## [param body] is serialised to JSON when non-null (not for GET/DELETE, which carry no body).
## Never throws and always releases the lock.
func request(method: int, url: String, headers: PackedStringArray, body: Variant = null) -> Dictionary:
	await _acquire()
	var out: Dictionary = await _do(method, url, headers, body)
	_release()
	return out

func _do(method: int, url: String, headers: PackedStringArray, body: Variant) -> Dictionary:
	var payload: String = ""
	var send_headers: PackedStringArray = headers.duplicate()
	if body != null and method != HTTPClient.METHOD_GET and method != HTTPClient.METHOD_DELETE:
		payload = JSON.stringify(body)
		var has_ct: bool = false
		for h: String in send_headers:
			if h.to_lower().begins_with("content-type"):
				has_ct = true
				break
		if not has_ct:
			send_headers.append("Content-Type: application/json")
	var err: int = _http.request(url, send_headers, method, payload)
	if err != OK:
		return _failure(0, HTTPRequest.RESULT_CANT_CONNECT, "REQUEST_FAILED_%d" % err)
	var r: Array = await _http.request_completed
	return _from_completed(r)

func _from_completed(r: Array) -> Dictionary:
	if r.size() < 4:
		return _failure(0, HTTPRequest.RESULT_CANT_CONNECT, "NO_RESPONSE")
	var result_code: int = int(r[0])
	var status: int = int(r[1])
	var raw: Variant = r[3]
	var text: String = ""
	if raw is PackedByteArray:
		text = (raw as PackedByteArray).get_string_from_utf8()
	elif raw != null:
		text = str(raw)
	var data: Variant = null
	if text.strip_edges() != "":
		data = JSON.parse_string(text)
		if data == null:
			data = text  # not JSON: hand the raw body back so the console can show it
	var ok: bool = result_code == HTTPRequest.RESULT_SUCCESS and status >= 200 and status < 300
	if ok:
		return {"ok": true, "status": status, "data": data, "error": "", "result": result_code}
	return _failure(status, result_code, _error_code(data, status, result_code), data)

func _failure(status: int, result_code: int, error: String, data: Variant = null) -> Dictionary:
	return {"ok": false, "status": status, "data": data, "error": error, "result": result_code}

## The machine-readable error code the services answer with ({ error, message, status }), or a
## transport-level fallback when the request never reached them.
static func _error_code(data: Variant, status: int, result_code: int) -> String:
	if data is Dictionary and (data as Dictionary).has("error"):
		return str((data as Dictionary)["error"])
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return "UNREACHABLE"
	return "HTTP_%d" % status

## Human-readable detail for a failed result, drawn from the service's own message when present.
static func describe_error(result: Dictionary) -> String:
	var data: Variant = result.get("data")
	if data is Dictionary and (data as Dictionary).has("message"):
		return "%s — %s" % [result.get("error", "ERROR"), str((data as Dictionary)["message"])]
	return str(result.get("error", "ERROR"))

func _acquire() -> void:
	while _busy:
		await slot_free
	_busy = true

func _release() -> void:
	_busy = false
	slot_free.emit()
