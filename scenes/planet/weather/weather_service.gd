@tool
class_name WeatherService
extends Node
## Reads a body's weather systems from the weather service's HTTP API (`services/weather`,
## `GET /api/v1/<body>/systems?t=`) and hands them to the body's ClimateWeather, for what runs without
## Horizon: Nova's game view, the editor's weather map. The game itself never needs this: there the systems
## arrive as WeatherSystem props.
##
## The address is `client.ini`, `[weather] service_url` (the service's root, "http://127.0.0.1:9400" for one run on
## this machine). Without an address or an answer, the climate keeps no system and [member reached] is false:
## the weather shown is then the climate's mean winds, and whoever shows it should say so.

## Emitted after each answer or failure.
signal heard(reached: bool)

## How often the service is asked again, seconds: its own tick toward Horizon.
const POLL_S := 30.0
## How soon it is asked again after a failure, seconds, and how long an answer is waited for.
const RETRY_S := 5.0
const TIMEOUT_S := 10.0

## The climate the systems are handed to; set it to start asking.
var climate: ClimateWeather:
	set(value):
		climate = value
		reached = false
		_since = POLL_S
## True once the last question was answered.
var reached := false
## How many systems the last answer held.
var count := 0
## The instant the last question was asked for, seconds of the shared clock.
var asked_at := 0.0
## Why the service was not reached, in a few words ("" when it was).
var trouble := ""

var _http: HTTPRequest
var _since := POLL_S
var _asked_for: ClimateWeather


## The service's root address from client.ini ("" when none is set).
static func address() -> String:
	var config := ConfigFile.new()
	if config.load("client.ini") != OK:
		return ""
	return str(config.get_value("weather", "service_url", "")).strip_edges().trim_suffix("/")


## The systems of a `/systems` answer as the Dictionaries WeatherSampler reads (WeatherSystem.state()).
## The ids are unsigned 64-bit and are kept as text: a JSON number loses them past 2^53, an int past 2^63.
static func states_of(answer: String) -> Array:
	var quoted := RegEx.create_from_string("\"id\"\\s*:\\s*(\\d+)").sub(answer, "\"id\":\"$1\"", true)
	var out := []
	var json := JSON.new()
	if json.parse(quoted) != OK:
		return out
	var parsed: Variant = json.data
	if not parsed is Dictionary or not (parsed as Dictionary).get("systems") is Array:
		return out
	for s: Variant in parsed["systems"]:
		if not s is Dictionary:
			continue
		out.append({
			"id": str(s.get("id", "")),
			"name": str(s.get("name", "")),
			"kind": StringName(str(s.get("kind", ""))),
			"lon": float(s.get("centre_lon_deg", 0.0)),
			"lat": float(s.get("centre_lat_deg", 0.0)),
			"sigma_m": maxf(float(s.get("sigma_m", 1.0)), 1.0),
			"intensity": float(s.get("intensity", 0.0)),
			"pressure_anomaly_pa": float(s.get("pressure_anomaly_pa", 0.0)),
			"wind_peak": float(s.get("wind_peak_m_s", 0.0)),
			"dust_tau": float(s.get("dust_tau", 0.0)),
			"precipitation_mm_h": float(s.get("precipitation_mm_h", 0.0)),
			"humidity": float(s.get("humidity", 0.0)),
		})
	return out


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_S
	_http.request_completed.connect(_on_answer)
	add_child(_http)


func _process(delta: float) -> void:
	_since += delta
	if _since >= POLL_S:
		ask()


## Asks the service now for the systems at the present instant.
func ask() -> void:
	_since = 0.0
	if climate == null or climate.profile == null or _http == null:
		return
	var root := address()
	if root.is_empty():
		_fail("no address")
		return
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return  # the last question is still out
	_asked_for = climate
	var t := ClimateWeather.now()
	if t <= 0.0:
		t = Time.get_unix_time_from_system()  # the editor has no running sky
	asked_at = floorf(t)
	if _http.request("%s/api/v1/%s/systems?t=%d" % [root, climate.profile.body_name.uri_encode(), int(t)]) != OK:
		_fail("bad address")


func _on_answer(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _asked_for != climate:
		return  # the body changed while the question was out
	if result != HTTPRequest.RESULT_SUCCESS or status != 200:
		_fail("no answer" if result != HTTPRequest.RESULT_SUCCESS else "HTTP %d" % status)
		return
	var states := states_of(body.get_string_from_utf8())
	climate.feed(states)
	count = states.size()
	reached = true
	trouble = ""
	heard.emit(true)


func _fail(why: String) -> void:
	trouble = why
	_since = POLL_S - RETRY_S
	if climate != null:
		climate.feed([])
	count = 0
	reached = false
	heard.emit(false)
