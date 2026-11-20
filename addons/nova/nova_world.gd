extends Node
## Nova's game view: the body as the game shows it, without a server.
##
## The offline world of the volcano viewer (test/volcano/volcano_world.gd) is the game's own client code:
## terrain, vegetation, volcanoes, roads, sky, dust, the star and the player with its god mode. This scene
## runs it for Nova: the dock starts it in the editor's "Game" tab and drives it (NovaLink), and the player
## walks or flies where the biome is being dressed.
##
## Keys (the world's own): click takes the mouse, Escape gives it back; Z Q S D move, Space and Ctrl climb
## and descend, the wheel sets the flying speed, Shift goes faster. Added here: G lands and walks (and
## takes off again), V shows the character from behind, B shows the game as it is without Nova and back
## (before / after): the world is built again at the same place, a few seconds.
##
## The sun: the view keeps one local time of day wherever the player goes ([member hour], the dock's
## slider), noon by default.

const World := preload("res://test/volcano/volcano_world.gd")
const WeatherHud := preload("res://addons/nova/nova_weather_hud.gd")
## Where the view starts until the dock sends it somewhere: longitude, latitude (degrees), height (m).
const START := Vector3(-41.3, 20.0, 500.0)
## Third person: the camera's place behind the character, in the camera pivot's frame (m).
const BEHIND := Vector3(0.0, 0.4, 3.5)
## Steps the day is searched in for the sun's highest point (96: a quarter of an hour of a 24 h day).
const SUN_STEPS := 96
const HELP := "Clic : prendre la souris · Échap : la rendre · Z Q S D : se déplacer · Espace / Ctrl : monter / descendre\n" \
		+ "Molette : vitesse · Maj : plus vite · G : à pied / en vol · V : voir le personnage · B : avant / après · L : fondu des LOD\n" \
		+ "Météo — M : carte · P : aller devant un mur de poussière · T : aller voir un tourbillon"
const AFTER := "APRÈS — avec Nova"
const BEFORE := "AVANT — le jeu actuel, sans Nova"
## After a before / after switch, how long the dock's "go to" is ignored (s): the rebuilt game says hello
## again and the dock answers with the editor's place, which would move the player.
const KEEP_PLACE_S := 4.0
## After the player is put somewhere, the ground under them is read again every SETTLE_EVERY_S for
## SETTLE_S: the terrain's relief (mountains, volcanoes) is streamed, and the height read before its tiles
## came is the bare heightmap's, which can lie hundreds of metres under the ground that is then drawn.
## The player is put back at their height over it, as long as they have not moved SETTLE_STAY_M away.
const SETTLE_S := 60.0
const SETTLE_EVERY_S := 0.5
const SETTLE_STAY_M := 30.0
## Going to see a dust wall (P): the hours the walls fall in are walked in steps of WALL_SEARCH_STEP_H and
## the most imposing wall met is kept; the player is put WALL_AHEAD_M before it and WALL_ABOVE_M over the
## ground. The clock is left as it is for that move (the weather is a function of the instant: setting the
## hour again for the new place, a few minutes off, would put the wall somewhere else).
const WALL_SEARCH_STEP_H := 0.1
const WALL_AHEAD_M := 2500.0
const WALL_ABOVE_M := 60.0
## Going to see a dust devil (T): looked for this far round the player (m), at DEVIL_HOUR when the sun is
## not up, and watched from DEVIL_BACK heights away, DEVIL_ABOVE_M over the ground.
const DEVIL_RANGE_M := 12000.0
const DEVIL_HOUR := 13.0
const DEVIL_BACK := 1.3
const DEVIL_BACK_MIN_M := 250.0
const DEVIL_ABOVE_M := 20.0

## The offline world: its player, body and collision terrain.
var world: Node3D
var _hud := Label.new()
var _camera_rest := Vector3.ZERO
## Where to put the player once the world is built: [ground point, height]. The dock's first "go to" comes
## as soon as the game says hello, before there is a player to move.
var _start: Array = [HEALPix.lonlat2vec(START.x, START.y), START.z]
var _built := false
var _switching := false
var _keep_place_until := 0
var _state := Label.new()
var _weather_hud := WeatherHud.new()
## The last place the player was put at: [ground point, height over the ground, the ground's height read then].
var _settled: Array = []
var _settle_left := 0.0
var _settle_since := 0.0
## Local time of day kept wherever the player is sent, hours: 12 is the sun at its highest there. A colour
## cannot be judged at sunset — the low sun turns a blue rock khaki — and at noon nothing casts a shadow:
## the view opens in mid-morning, when colours are true and the relief reads.
var hour := 10.0


func _ready() -> void:
	# A checking run (NOVA_GAME_PROBE) takes no focus: it would steal the keyboard from whoever is working
	# on the machine, and their typing would land on the world's shortcuts.
	if OS.get_environment("NOVA_GAME_PROBE") != "":
		get_window().set_flag(Window.FLAG_NO_FOCUS, true)
		PlanetTerrain.lod_morph_enabled = OS.get_environment("NOVA_LOD_MORPH") != "0"
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud.text = HELP
	_hud.position = Vector2(12, 8)
	_state.position = Vector2(12, 70)
	for label: Label in [_hud, _state]:
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", 4)
		layer.add_child(label)
	_state.add_theme_font_size_override("font_size", 18)
	add_child(_weather_hud)
	await _build()
	var probe := OS.get_environment("NOVA_GAME_PROBE")  # a checking script to run in the game view, for tests
	if probe != "":
		add_child((load(probe) as GDScript).new())


## Builds the offline world and puts the player at [member _start].
func _build() -> void:
	_built = false
	_state.text = "Chargement…"
	world = World.new()
	add_child(world)
	while world.player == null or world._busy:
		await get_tree().process_frame
	get_window().title = "Nova — vue jeu"
	_camera_rest = world.player.camera.position
	_built = true
	# The planet's climate for its weather when it has one (ClimateWeather): here only, the game keeps the
	# weather source its scene sets.
	var climate := ClimateWeather.for_body(world.body.planet_data.planet_name)
	if climate != null:
		world.body.weather_source = climate
		# What the local weather stands on the ground: dust devils, dust walls.
		var phenomena := WeatherPhenomena.new()
		phenomena.eye = func() -> Node3D: return world.player.camera if world != null and world.player != null else null
		world.body.add_child(phenomena)
	_weather_hud.planet = world.body
	_weather_hud.player = world.player
	_place(_start[0], _start[1])
	_state.text = (BEFORE if NovaBody.disabled else AFTER) \
			+ ("" if PlanetTerrain.lod_morph_enabled else " · sans fondu des niveaux de détail")


## Before / after: builds the world again without Nova (the game as it is), or with it, at the same place,
## looking the same way.
func toggle_nova() -> void:
	await _rebuild(func() -> void: NovaBody.disabled = not NovaBody.disabled)


## With / without the LOD morph (a finer chunk appearing on its parent's shape and easing into its own),
## to judge the popping: the world is built again at the same place. Its meshes differ, so the first
## switch bakes them again.
func toggle_lod_morph() -> void:
	await _rebuild(func() -> void: PlanetTerrain.lod_morph_enabled = not PlanetTerrain.lod_morph_enabled)


## Builds the world again after [param change], at the same place, looking the same way.
func _rebuild(change: Callable) -> void:
	if not _built or _switching:
		return
	_switching = true
	var player: Player = world.player
	var dir := player_direction()
	var above: float = world.body.to_local(player.global_position).length() - world.body.planet_data.radius \
			- _ground_at(dir)
	var facing := player.transform.basis
	var pitch := player.camera_pivot.rotation
	var third := player.puppet.visible
	_start = [dir, maxf(above, 1.8)]
	_built = false
	_state.text = "Chargement…"
	_weather_hud.planet = null
	_weather_hud.player = null
	var old := world
	await old.shutdown()
	old.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	change.call()
	await _build()
	world.player.transform.basis = facing
	world.player.camera_pivot.rotation = pitch
	_set_third_person(third)
	_keep_place_until = Time.get_ticks_msec() + int(KEEP_PLACE_S * 1000.0)
	_switching = false


## The ground as it is drawn at unit [param dir]: the heightmap and the relief of the zone's biome (the one
## Nova sets, when Nova is on).
func _ground_at(dir: Vector3) -> float:
	var data: PlanetData = world.body.planet_data
	return data.sample_height_for_direction(dir) + BiomeRelief.offset(dir, data.radius, data.biome_at(dir))


## Put the player [param above] metres over the ground at unit [param dir] (the body's frame), flying,
## upright, facing north. The dock's "go to" moves land here.
func nova_goto(dir: Vector3, above: float) -> void:
	if _switching or Time.get_ticks_msec() < _keep_place_until:
		return
	if not _built:
		_start = [dir, above]
		return
	_place(dir, above)


func _place(dir: Vector3, above: float, keep_clock := false) -> void:
	var data: PlanetData = world.body.planet_data
	var ground := _ground_at(dir)
	if _settled.is_empty() or (_settled[0] as Vector3) != dir or float(_settled[1]) != above:
		_settle_left = SETTLE_S
	_settled = [dir, above, ground]
	var at := dir * (data.radius + ground + above)
	# The world keeps the player near the origin: the body is moved, like the volcano viewer's own jumps.
	world._anchor = at
	world._update_system_frame()
	var player: Player = world.player
	player.god_mode = true
	var north := Vector3.UP - dir * Vector3.UP.dot(dir)
	var forward := north.normalized() if north.length() > 0.01 else Vector3.RIGHT
	player.transform = Transform3D(Basis(forward.cross(dir).normalized(), dir, -forward), at)
	player.camera_pivot.rotation = Vector3(-0.35, 0.0, 0.0)
	player.call_deferred("server_teleport_to", world.body, player.position)
	if not keep_clock:
		_apply_hour()


func _process(delta: float) -> void:
	if _settle_left <= 0.0 or not _built or _switching or _settled.is_empty():
		return
	_settle_left -= delta
	_settle_since += delta
	if _settle_since < SETTLE_EVERY_S:
		return
	_settle_since = 0.0
	var dir: Vector3 = _settled[0]
	if absf(_ground_at(dir) - float(_settled[2])) < 0.5 			or player_direction().angle_to(dir) * world.body.planet_data.radius > SETTLE_STAY_M:
		return
	# The ground has changed under the place (its relief has come): the same height over it, looking the same way.
	var player: Player = world.player
	var facing := player.transform.basis
	var pitch := player.camera_pivot.rotation
	_place(dir, float(_settled[1]), true)
	player.transform.basis = facing
	player.camera_pivot.rotation = pitch


## Set the local time of day (the dock's slider).
func nova_set_hour(value: float) -> void:
	hour = value
	if _built:
		_apply_hour()


## Sine of the sun's elevation where the player stands.
func _sun_height() -> float:
	var at: Vector3 = world.player.global_position
	return world.body.global_position.direction_to(at).dot(
			at.direction_to((world._universe.get_node("Star") as Node3D).global_position))


## Turn the world's clock so that it is [member hour] where the player stands: find the moment of the day
## when the sun is highest there (local noon), then move from it by the hours wanted.
func _apply_hour() -> void:
	var day: float = (world.body.rotation_period_hours if world.body.rotation_period_hours > 0.0 else 24.0) * 3600.0
	var base := fposmod(Globals.debug_time_offset, day)
	var noon := 0
	var highest := -2.0
	for k in SUN_STEPS:
		Globals.debug_time_offset = base + day * k / SUN_STEPS
		world._update_system_frame()
		var h := _sun_height()
		if h > highest:
			highest = h
			noon = k
	Globals.debug_time_offset = base + day * (float(noon) / SUN_STEPS + (hour - 12.0) / 24.0)
	world._update_system_frame()


## The ground point under the player, as a unit direction in the body's frame.
func player_direction() -> Vector3:
	return world.body.to_local(world.player.global_position).normalized()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or world == null or world.player == null:
		return
	# By their letters: on an AZERTY keyboard the M key is not where QWERTY has it.
	var weather_key: Callable = {KEY_M: _weather_hud.toggle_map, KEY_P: goto_wall, KEY_T: goto_devil}.get(key.keycode, Callable())
	if weather_key.is_valid():
		weather_key.call()
		get_viewport().set_input_as_handled()
		return
	match key.physical_keycode:
		KEY_G:
			world.toggle_walk()
		KEY_V:
			_set_third_person(not world.player.puppet.visible)
		KEY_B:
			toggle_nova()
		KEY_L:
			toggle_lod_morph()
		_:
			return
	get_viewport().set_input_as_handled()


## The planet's climate weather, null without one or before the world is built.
func _climate() -> ClimateWeather:
	return world.body.current_weather_source() as ClimateWeather if _built and not _switching else null


## Where the player stands, (longitude, latitude) in degrees.
func _lonlat() -> Vector2:
	return HEALPix.vec2lonlat(player_direction())


## Turn the player toward a place (longitude, latitude), the camera raised by [param pitch].
func _face(target: Vector2, pitch: float) -> void:
	var dir := player_direction()
	var to := WeatherLocal.offset_m(_lonlat(), target, world.body.planet_data.radius)
	var axes: Array = Planet.local_axes(dir)
	var forward: Vector3 = ((axes[0] as Vector3) * to.x + (axes[1] as Vector3) * to.y).normalized()
	world.player.transform.basis = Basis(forward.cross(dir).normalized(), dir, -forward)
	world.player.camera_pivot.rotation = Vector3(pitch, 0.0, 0.0)


## How much there is to see of a dust wall: its height, as far as it is still strong.
static func _wall_show(wall: Dictionary) -> float:
	return float(wall["strength"]) * float(wall["height_m"]) if not wall.is_empty() else 0.0


## The most imposing of the dust walls running near the player now, {} when none.
func _wall_near(weather: ClimateWeather) -> Dictionary:
	var best := {}
	for wall: Dictionary in weather.walls_near(world.body, _lonlat()):
		if _wall_show(wall) > _wall_show(best):
			best = wall
	return best


## Go and stand before a dust wall: the hours the walls fall in are walked here until the most imposing
## wall of the neighbourhood is found; the player is put in its way, facing it.
func goto_wall() -> void:
	var weather := _climate()
	if weather == null:
		return
	var best := {}
	var best_hour := 0.0
	var best_clock := 0.0
	var last := WeatherLocal.WALL_FROM_H + WeatherLocal.WALL_SPREAD_H + WeatherLocal.WALL_LIFE_S / 3600.0
	var at := WeatherLocal.WALL_FROM_H
	while at < last:
		nova_set_hour(at)
		var wall := _wall_near(weather)
		if _wall_show(wall) > _wall_show(best):
			best = wall
			best_hour = at
			best_clock = Globals.debug_time_offset
		at += WALL_SEARCH_STEP_H
	if best.is_empty():
		_weather_hud.note("Aucun mur de poussière ce soir à moins de 60 km d'ici : essaie depuis un autre endroit, près d'un relief.")
		return
	# Back to the very instant the wall was met at: setting the hour again lands a few minutes off (the
	# clock finds noon to a quarter of an hour), and the wall would be somewhere else.
	hour = best_hour
	Globals.debug_time_offset = best_clock
	world._update_system_frame()
	var radius: float = world.body.planet_data.radius
	var front := Vector2(best["lon"], best["lat"])
	var ahead := WeatherLocal.moved(front, Vector2(best["east"], best["north"]) * WALL_AHEAD_M, radius)
	_place(HEALPix.lonlat2vec(ahead.x, ahead.y), WALL_ABOVE_M, true)
	_face(front, 0.15)
	_weather_hud.note("Mur de poussière droit devant, à %.0f km : %.0f m de haut, %.0f km de front. Il vient vers toi à %.0f m/s." % [
			WALL_AHEAD_M / 1000.0, float(best["height_m"]), float(best["length_m"]) / 1000.0, float(best["speed_m_s"])])


## Go and look at the largest dust devil round the player (by day: the hour is set to the early afternoon
## when the sun is not up).
func goto_devil() -> void:
	var weather := _climate()
	if weather == null:
		return
	if _sun_height() < WeatherLocal.DEVIL_SUN[1]:
		nova_set_hour(DEVIL_HOUR)
	var best := {}
	for devil: Dictionary in weather.devils_near(world.body, _lonlat(), DEVIL_RANGE_M):
		if best.is_empty() or float(devil["radius_m"]) * float(devil["strength"]) > float(best["radius_m"]) * float(best["strength"]):
			best = devil
	if best.is_empty():
		_weather_hud.note("Aucun tourbillon à moins de 12 km : ils naissent aux basses latitudes (sous 32°), par vent faible.")
		return
	var radius: float = world.body.planet_data.radius
	var at := Vector2(best["lon"], best["lat"])
	var back := maxf(float(best["height_m"]) * DEVIL_BACK, DEVIL_BACK_MIN_M)
	var from := WeatherLocal.moved(at, Vector2(0.0, -back), radius)
	_place(HEALPix.lonlat2vec(from.x, from.y), DEVIL_ABOVE_M, true)
	_face(at, 0.3)
	_weather_hud.note("Tourbillon droit devant, à %.0f m : %.0f m de rayon, %.0f m de haut. Ils vivent 5 minutes." % [
			back, float(best["radius_m"]), float(best["height_m"])])


## Show the character and step the camera back behind it, or go back to its eyes.
func _set_third_person(on: bool) -> void:
	var player: Player = world.player
	player.puppet.visible = on
	player.camera.position = _camera_rest + (BEHIND if on else Vector3.ZERO)
