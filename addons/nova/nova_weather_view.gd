@tool
extends VBoxContainer
## The dock's weather map: the body's weather (ClimateWeather) drawn by WeatherMap — temperatures, wind
## arrows, isobars, and the systems read from the weather service (WeatherService) — at the present moment,
## for the hour the dock's slider gives. Without the service the map is the climate's mean winds, and says so. The picture
## goes to whoever listens to [signal drawn] (the dock lays it over its globe); here are the button that
## asks for it and the legend.
##
## The editor has no running sky: the instant is the computer's clock (the service's systems live and drift
## from one press to the next), the star stands over the longitude where it is noon when longitude 0 has
## [member hour], and its declination follows the year as a sine of the body's tilt — close to the game's,
## not equal to it.

const KINDS := {&"anticyclone": "anticyclone(s)", &"depression": "dépression(s)",
		&"dust_storm": "tempête(s) de poussière", &"rain_front": "front(s) de pluie"}

## A new map is ready ([param picture]: longitude/latitude, as NovaAtlas's map), or the map is put away (null).
signal drawn(picture: Image)

## Local solar time at longitude 0, hours.
var hour := 12.0

var _weather: ClimateWeather
var _service := WeatherService.new()
var _waiting := false
var _button := Button.new()
var _legend := Label.new()
var _task := -1


func _init() -> void:
	_button.text = "Carte météo sur le globe"
	_button.toggle_mode = true
	_button.tooltip_text = "Dessine sur le globe la météo de la planète maintenant : températures (couleurs), " \
			+ "vent (flèches), pression (lignes), dépressions, anticyclones et tempêtes de poussière (anneaux). " \
			+ "Relâche le bouton pour retrouver les biomes."
	_button.toggled.connect(func(on: bool) -> void:
		if on:
			refresh()
		else:
			_put_away())
	add_child(_button)
	add_child(_service)
	_service.set_process(false)  # asked on demand, not every POLL_S
	_service.heard.connect(func(_reached: bool) -> void:
		if _waiting:
			_waiting = false
			_draw())
	_legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_legend.add_theme_font_size_override("font_size", 11)
	_legend.visible = false
	add_child(_legend)


## The body whose weather the map draws; the button is off for a body without a climate.
func show_body(body_name: String) -> void:
	_weather = ClimateWeather.for_body(body_name)
	_service.climate = _weather
	_waiting = false
	_button.disabled = _weather == null
	_button.set_pressed_no_signal(false)
	_put_away()


func _put_away() -> void:
	_legend.visible = false
	drawn.emit(null)


## Asks the service for the systems, then draws the map again on a worker (a few seconds).
func refresh() -> void:
	if _weather == null or _task >= 0 or _waiting:
		return
	_button.disabled = true
	_waiting = true
	_service.ask()


func _draw() -> void:
	var weather := _weather
	var live := weather.systems(null)
	var t := Time.get_unix_time_from_system()
	var decl := weather.profile.tilt_deg * sin(TAU * t / maxf(weather.profile.orbit_period_s, 1.0))
	var substellar_lon := -(hour - 12.0) / 24.0 * 360.0
	_task = WorkerThreadPool.add_task(func() -> void:
		_show.call_deferred(WeatherMap.render(weather, live, decl, substellar_lon)))


func _show(out: Dictionary) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_button.disabled = false
	if not _button.button_pressed:
		return  # released while the map was being drawn
	drawn.emit(out.image)
	var systems := PackedStringArray()
	for kind in out.systems:
		systems.append("%d %s" % [int(out.systems[kind]), KINDS.get(kind, str(kind))])
	_legend.text = "Température de l'air : %.0f à %.0f °C (du violet au rouge). Vent jusqu'à %.0f m/s : flèches " \
			% [float(out.t_min_k) - 273.15, float(out.t_max_k) - 273.15, float(out.wind_max_m_s)] \
			+ "blanches là où il soulève la poussière, sombres ailleurs. Voile ocre : poussière en l'air. " \
			+ ("Anneaux : rouge dépression, bleu anticyclone, brun tempête de poussière. Service météo : %s. " % ", ".join(systems)
				if _service.reached else "Service météo non joint (client.ini, [weather] service_url) : climat de fond seul, aucun système. ") \
			+ "Il est %d h à la longitude 0 (curseur « Heure du jour »)." % int(hour)
	_legend.visible = true


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
