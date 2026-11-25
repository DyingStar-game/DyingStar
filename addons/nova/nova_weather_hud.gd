extends CanvasLayer
## The game view's weather on screen: one line saying the weather where the player stands (wind,
## temperature, visibility, what is felt there), and the planet's weather map (WeatherMap) on demand, with
## the player's place on it.

const DIRECTIONS := ["nord", "nord-est", "est", "sud-est", "sud", "sud-ouest", "ouest", "nord-ouest"]
const PHENOMENA := {WeatherRelief.NAME_BREEZE: "brise de plateau", WeatherRelief.NAME_KATABATIC: "vent de pente",
		WeatherRelief.NAME_LEE: "rafales sous le vent", WeatherRelief.NAME_HAZE: "voile de poussière",
		WeatherRelief.NAME_DEVIL: "tourbillon", WeatherRelief.NAME_WALL: "mur de poussière"}
const REFRESH_S := 0.5
## How long a note stays on screen, seconds.
const NOTE_S := 12.0
## The map's share of the window's width, and its marker's half size (map pixels).
const MAP_SHARE := 0.8
const MARKER_PX := 7

## The planet and the player whose weather is told.
var planet: Planet
var player: Node3D
## What reads the weather service for this view (no Horizon here), null when the body has no climate.
var service: WeatherService

var _line := Label.new()
var _note := Label.new()
var _note_left := 0.0
var _map := TextureRect.new()
var _since := REFRESH_S
var _task := -1


func _ready() -> void:
	_line.position = Vector2(12, 136)
	_line.add_theme_font_size_override("font_size", 13)
	_line.add_theme_color_override("font_outline_color", Color.BLACK)
	_line.add_theme_constant_override("outline_size", 4)
	add_child(_line)
	_note.position = Vector2(12, 160)
	_note.add_theme_font_size_override("font_size", 16)
	_note.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	_note.add_theme_color_override("font_outline_color", Color.BLACK)
	_note.add_theme_constant_override("outline_size", 5)
	add_child(_note)
	_map.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_map.visible = false
	add_child(_map)


## Says [param text] under the weather line for NOTE_S.
func note(text: String) -> void:
	_note.text = text
	_note_left = NOTE_S


func _process(delta: float) -> void:
	if _note_left > 0.0:
		_note_left -= delta
		if _note_left <= 0.0:
			_note.text = ""
	_since += delta
	if _since < REFRESH_S or planet == null or player == null:
		return
	_since = 0.0
	_line.text = describe(planet.weather_at(player.global_position)) + said_of(service)


## Where the weather shown comes from, to end the weather line with.
static func said_of(from: WeatherService) -> String:
	if from == null:
		return ""
	if from.reached:
		return " — service météo : %d système(s)" % from.count
	return " — service météo non joint (%s) : climat de fond seul" % \
			("aucune adresse dans client.ini, [weather] service_url" if WeatherService.address().is_empty() else WeatherService.address())


## A weather sample in a line of words.
static func describe(sample: Dictionary) -> String:
	if sample.is_empty():
		return ""
	var from: String = DIRECTIONS[posmod(roundi(float(sample.get("wind_from_deg", 0.0)) / 45.0), 8)]
	var parts := PackedStringArray(["Vent %.1f m/s du %s" % [float(sample.get("wind_speed_m_s", 0.0)), from]])
	if sample.has("temperature_k"):
		parts.append("%.0f °C" % (float(sample["temperature_k"]) - 273.15))
	if sample.has("visibility_m"):
		parts.append("visibilité %.0f km" % minf(float(sample["visibility_m"]) / 1000.0, 999.0))
	if float(sample.get("updraft_m_s", 0.0)) > 0.5:
		parts.append("ascendance %.1f m/s" % float(sample["updraft_m_s"]))
	for name: String in sample.get("phenomena", PackedStringArray()):
		parts.append(PHENOMENA.get(StringName(name), name))
	return "Météo ici : " + " · ".join(parts)


## Shows the planet's weather map as it is now (a few seconds to draw, on a worker), or puts it away.
func toggle_map() -> void:
	if _map.visible:
		_map.visible = false
		return
	var weather := planet.current_weather_source() as ClimateWeather if planet != null else null
	if weather == null or _task >= 0:
		return
	var sun := weather.sun_over(planet)
	var live := weather.systems(planet)
	var here := HEALPix.vec2lonlat(planet.to_local(player.global_position).normalized())
	_task = WorkerThreadPool.add_task(func() -> void:
		_show_map.call_deferred(WeatherMap.render(weather, live, sun.y, sun.x)["image"], here))


func _show_map(picture: Image, here: Vector2) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var at := Vector2i(int((here.x + 180.0) / 360.0 * picture.get_width()), int((90.0 - here.y) / 180.0 * picture.get_height()))
	picture.fill_rect(Rect2i(at - Vector2i.ONE * (MARKER_PX + 2), Vector2i.ONE * (MARKER_PX * 2 + 4)), Color.BLACK)
	picture.fill_rect(Rect2i(at - Vector2i.ONE * MARKER_PX, Vector2i.ONE * MARKER_PX * 2), Color(1.0, 0.2, 0.9))
	_map.texture = ImageTexture.create_from_image(picture)
	var window := Vector2(get_viewport().get_visible_rect().size)
	_map.size = Vector2(window.x * MAP_SHARE, window.x * MAP_SHARE * 0.5)
	_map.position = (window - _map.size) * 0.5
	_map.visible = true


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
