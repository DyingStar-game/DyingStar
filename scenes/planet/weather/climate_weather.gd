@tool
class_name ClimateWeather
extends WeatherSource
## A planet's weather as the weather service decides it (`services/weather`): the mean wind of each latitude
## band from the body's ClimateProfile (generated from the service's derived data), and the pressure
## systems and dust storms the service makes live, sampled by WeatherSampler, the service's sanctioned twin.
##
## Nothing is made up here. The systems are the WeatherSystem props Horizon replicates under the planet
## ([method systems]); a tool running without Horizon hands in what it read from the service itself
## ([method feed], WeatherService). With no system received the weather is the climate's mean winds: the
## fallback the service's design intends.
##
## While the planet has a fresh WeatherField (the service's atmosphere model, relayed by Horizon), its
## near-ground wind, dust, temperature and pressure are the background instead of the climate profile and
## the systems ([method field_frames]); without one, the profile and the systems as above.
##
## Beside WeatherSource's keys, a sample carries "temperature_k", "pressure_pa", "pressure_anomaly_pa",
## "visibility_m" and "band" (WeatherSampler's names).
##
## On a planet with its relief ([method sample]), two layers are laid over that:
## - WeatherRelief (not from the prototype): the plateaus' breeze, the gusts behind the massifs, the permanent
##   haze, dust devils and dust walls, from the report « De l'atmosphère de Sandbox »;
## - WeatherLocal (the prototype's, as it is): the wind where you stand — channelled along a canyon and
##   sheltered across it (WeatherCanyon), breathing in gusts, stronger with height. The hook gives no
##   height, so [method sample] takes the place on the ground; [method sample_local] takes a world position.

## Where a body's weather is kept, by its name ("tarsis_3_weather.tres").
const DIR := "res://scenes/planet/climates"
## How long the planet's systems are kept before its nodes are read again, milliseconds: a system drifts a
## few metres in that time, and consumers ask for the weather many times a frame.
const SYSTEMS_KEPT_MS := 1000
## The relief the local weather reads: the heightmap's level (tiles about 23 km across on Tarsis 3, a
## height every 700 m: the plateaus and valleys, not the rocks), the arm the slope is measured over (m), how
## far upwind the ground is looked at for a lee (m), and the cell one reading is kept for (m).
const RELIEF_NSIDE := 256
const SLOPE_ARM_M := 1500.0
const LEE_REACH_M := 10000.0
const RELIEF_CELL_M := 250.0
## Readings and wall sources kept at most, each.
const KEPT_MAX := 4096
## A sample with the local weather is kept this long for the place it was asked at (s): the dust, the
## sound and every emitter round the player ask for the same one many times a frame.
const SAMPLE_KEPT_S := 0.25
## Samples kept at most within one SAMPLE_KEPT_S, one per place (relief cell): the player, the avatars
## round them, each volcano's plume and each dust emitter ask at their own place, and one kept sample
## alone was thrown away by each of them in turn.
const SAMPLES_KEPT_MAX := 64

## The body's climate, as the weather service derived it (generated: never hand-edit).
@export var profile: ClimateProfile
@export_group("Local weather")
## False: the service's weather only, nothing from the relief.
@export var local_enabled := true
## Bottom of the permanent haze, metres over the reference sphere: under it the dust is thinner.
@export var haze_base_m := 500.0
## Top of the permanent haze, metres over the reference sphere: the ground standing higher is clear.
@export var haze_top_m := 3500.0
## Optical depth of the permanent haze inside its layer at low latitudes (0.6: 6.5 km of visibility);
## 0 = no haze.
@export var haze_tau := 0.6

var _relief := {}  # [cell x, cell y] → WeatherRelief's terrain
var _wall_sources := {}
var _kept := {}  # [planet id, relief cell x, y] → the sample, for the time step _kept_slot
var _kept_slot := -1
var _kept_epoch := 0  # one more at each feed: a sample computed before it is not kept
var _air_kept := {}  # [lon, lat] → WeatherSampler.air there, under the systems _air_live
var _air_live: Array = []
var _air_field: Variant = null  # the field frames _air_kept was computed under (null: none)
var _air_mutex := Mutex.new()
var _devil_cells := {}  # WeatherRelief.devils_near's known: the cells' hashes
var _devil_mutex := Mutex.new()
var _fed: Array = []
var _systems: Array = []
var _systems_at_ms := -1
var _systems_of := 0
var _field: Array = []  # WeatherField.frames() of the planet's field, read with the systems
var _fed_field: Array = []
var _forced: Array = []  # ForcedDustWall.data() of the walls called in over the planet, read with the systems
var _mutex := Mutex.new()


## The climate weather of [param body_name], null when the body has none.
static func for_body(body_name: String) -> ClimateWeather:
	var path := DIR.path_join(body_name + "_weather.tres")
	return load(path) as ClimateWeather if ResourceLoader.exists(path) else null


## Hand in the systems a tool read from the weather service itself (WeatherService.states_of): what stands
## for Horizon's props where no Horizon runs. An empty list takes them away.
func feed(states: Array) -> void:
	_mutex.lock()
	_fed = states
	_systems_at_ms = -1
	_kept.clear()
	_kept_slot = -1
	_kept_epoch += 1
	_mutex.unlock()


## Hand in the frames of a weather field (WeatherField.frames()) a tool or a test has without Horizon: they
## stand for the planet's WeatherField node. An empty list takes them away.
func feed_field(held: Array) -> void:
	_mutex.lock()
	_fed_field = held
	_systems_at_ms = -1
	_kept.clear()
	_kept_slot = -1
	_kept_epoch += 1
	_mutex.unlock()


## The frames of [param planet]'s WeatherField (WeatherField.frames()), read with [method systems]: [] when
## the planet has none. Thread-safe.
func field_frames(planet: Planet) -> Array:
	systems(planet)
	_mutex.lock()
	var out := _field
	_mutex.unlock()
	return out


## [method field_frames] when they may stand for the weather at [param t] (WeatherField.frames_fresh), else [].
func fresh_field(planet: Planet, t: float) -> Array:
	var held := field_frames(planet)
	return held if WeatherField.frames_fresh(held, t) else []


## The weather systems over [param planet] now, as the Dictionaries WeatherSampler reads
## (WeatherSystem.state()): the props Horizon parented to it, and what a tool handed in ([method feed]).
## Empty when the service was not heard from. Thread-safe: the nodes are read on the main thread only, a
## worker gets the last list.
func systems(planet: Planet) -> Array:
	var id := planet.get_instance_id() if planet != null else 0
	var ms := Time.get_ticks_msec()
	_mutex.lock()
	var out := _systems
	var due := _systems_at_ms < 0 or ms - _systems_at_ms >= SYSTEMS_KEPT_MS or id != _systems_of
	var fed := _fed
	_mutex.unlock()
	if not due or OS.get_thread_caller_id() != OS.get_main_thread_id():
		return out
	out = fed.duplicate()
	var held: Array = _fed_field
	var forced: Array = []
	if planet != null and planet.is_inside_tree():
		for node: Node in planet.get_tree().get_nodes_in_group(WeatherSystem.GROUP):
			if node is WeatherSystem and node.get_parent() == planet:
				out.append((node as WeatherSystem).state())
		for node: Node in planet.get_tree().get_nodes_in_group(WeatherField.GROUP):
			if node is WeatherField and node.get_parent() == planet:
				held = (node as WeatherField).frames()
				break
		for node: Node in planet.get_tree().get_nodes_in_group(ForcedDustWall.GROUP):
			if node is ForcedDustWall and node.get_parent() == planet:
				forced.append((node as ForcedDustWall).data())
	_mutex.lock()
	_systems = out
	_field = held
	_forced = forced
	_systems_at_ms = ms
	_systems_of = id
	_mutex.unlock()
	return out


## The service's weather at a longitude and latitude (degrees) and an altitude, under [param live] systems
## ([method systems]), for the star's declination and the longitude it stands over: every key of
## WeatherSampler.sample, and the dust threshold. The one sample behind [method sample] and the weather map.
## With [param field] (fresh WeatherField frames, [method fresh_field]) sampled at [param t], the field is
## the background and the systems are not counted (the model makes its own); "weather_field" says which.
func sample_at(lon_deg: float, lat_deg: float, altitude_m: float, decl_deg: float, substellar_lon_deg: float,
		live: Array, field: Array = [], t: float = 0.0) -> Dictionary:
	var got := WeatherField.sample_frames(field, lon_deg, lat_deg, t)
	var out := WeatherSampler.sample(profile, live if got.is_empty() else [], lon_deg, lat_deg, altitude_m,
			WeatherRelief.solar_hours(lon_deg, substellar_lon_deg), decl_deg)
	if not got.is_empty():
		out = with_field(profile, out, got)
	out["weather_field"] = not got.is_empty()
	out["lift_threshold_m_s"] = profile.v10_threshold_m_s
	return out


## [param sample] (WeatherSampler.sample's keys, no system counted) with what the field [param got]
## (WeatherField.sample) says in place of the profile's: the wind, the dust and what follows from it
## (visibility), the temperature, and the pressure brought from the reference sphere to the sample's
## altitude (and the density with it). A quantity the field lacks keeps the profile's value.
static func with_field(p: ClimateProfile, sample: Dictionary, got: Dictionary) -> Dictionary:
	var out := sample.duplicate()
	if got.has("wind_east") and got.has("wind_north"):
		var we := float(got["wind_east"])
		var wn := float(got["wind_north"])
		out["wind_east_m_s"] = we
		out["wind_north_m_s"] = wn
		out["wind_speed_m_s"] = sqrt(we * we + wn * wn)
		out["wind_from_deg"] = WeatherSampler.wind_from_deg(we, wn)
	if got.has("dust_tau"):
		var dust := maxf(float(got["dust_tau"]), 0.0)
		out["dust_tau"] = dust
		out["visibility_m"] = (3.912 / (dust / WeatherSampler.DUST_LAYER_M) if dust > 1e-6
				else WeatherSampler.NO_DUST_VISIBILITY_M)
	if got.has("t_air"):
		out["temperature_k"] = float(got["t_air"])
	if got.has("p_sea") and p.has_atmosphere:
		var altitude := float(sample.get("altitude_m", 0.0))
		var fall := exp(-altitude / p.scale_height_m)
		var pressure := float(got["p_sea"]) * fall
		var column := p.pressure_pa * fall
		out["pressure_pa"] = pressure
		out["pressure_anomaly_pa"] = pressure - column
		if column > 0.0:
			out["air_density_kg_m3"] = WeatherSampler.air_density(p, altitude) * pressure / column
	return out


func sample(planet: Planet, local_dir: Vector3) -> Dictionary:
	return _where_you_stand(_regional(planet, local_dir), planet, local_dir, 0.0)


## The weather at a world position with the wind where you stand at your height: as [method sample], the
## canyon's wind fading out above the trench and the wind growing with the height over the ground
## (the prototype's Planet.weather_local_at).
func sample_local(planet: Planet, world_pos: Vector3) -> Dictionary:
	var dir := planet.local_dir_of(world_pos)
	return _where_you_stand(_regional(planet, dir), planet, dir, maxf(planet.surface_altitude_of(world_pos), 0.0))


## [param regional] with WeatherLocal's wind in place of its own, for a place [param above_m] over the ground.
func _where_you_stand(regional: Dictionary, planet: Planet, local_dir: Vector3, above_m: float) -> Dictionary:
	if regional.is_empty() or not local_enabled or planet == null or planet.planet_data == null:
		return regional
	var gust := WeatherLocal.gust_factor(profile.weather_seed, float(regional["lon_deg"]), float(regional["lat_deg"]), now())
	return WeatherLocal.apply(regional, WeatherCanyon.at(planet.planet_data, local_dir, above_m), gust,
			profile.wind_scale_max_ms, above_m)


## The service's weather at a place, with the relief's (WeatherRelief) on a planet that has one.
func _regional(planet: Planet, local_dir: Vector3) -> Dictionary:
	if profile == null:
		return {}
	var lonlat := HEALPix.vec2lonlat(local_dir)
	var t := now()
	# Asked again for the same place within SAMPLE_KEPT_S: the answer kept, before anything is computed.
	var cell := WeatherRelief.cell_of(lonlat.x, lonlat.y, RELIEF_CELL_M, profile.radius_m)
	var key := [planet.get_instance_id() if planet != null else 0, cell.x, cell.y]
	var slot := floori(t / SAMPLE_KEPT_S)
	_mutex.lock()
	if slot != _kept_slot:
		_kept.clear()
		_kept_slot = slot
	var kept: Dictionary = _kept.get(key, {})
	var epoch := _kept_epoch
	_mutex.unlock()
	if not kept.is_empty():
		return kept.duplicate()
	var sun := sun_over(planet)
	var live := systems(planet)
	var field := fresh_field(planet, t)
	var out := sample_at(lonlat.x, lonlat.y, 0.0, sun.y, sun.x, live, field, t)
	if not local_enabled or planet == null or planet.planet_data == null:
		return out
	var data: PlanetData = planet.planet_data
	var terrain := relief_at(data, lonlat.x, lonlat.y).duplicate()
	if out["band"] == WeatherSampler.BAND_WESTERLIES:
		var wind := Vector2(out["wind_east_m_s"], out["wind_north_m_s"])
		if wind.length() > 0.1:
			var upwind := WeatherRelief.moved(lonlat, -wind.normalized() * LEE_REACH_M, profile.radius_m)
			terrain["upwind_drop_m"] = float(relief_at(data, upwind.x, upwind.y)["height_m"]) - float(terrain["height_m"])
	out = WeatherRelief.apply(out, profile, terrain, _devils(lonlat, WeatherRelief.DEVIL_CELL_M, t, sun, live, field),
			walls_near(planet, lonlat),
			Vector3(haze_base_m, haze_top_m, haze_tau), t)
	_mutex.lock()
	if slot == _kept_slot and epoch == _kept_epoch and _kept.size() < SAMPLES_KEPT_MAX:
		_kept[key] = out
	_mutex.unlock()
	return out.duplicate()


## The relief the local weather reads at a place of [param data]'s body (WeatherRelief's terrain: height_m,
## upslope), kept by cell of RELIEF_CELL_M. Thread-safe.
func relief_at(data: PlanetData, lon_deg: float, lat_deg: float) -> Dictionary:
	var cell := WeatherRelief.cell_of(lon_deg, lat_deg, RELIEF_CELL_M, profile.radius_m)
	var key := Vector2i(cell.x, cell.y)
	_mutex.lock()
	var known: Variant = _relief.get(key)
	_mutex.unlock()
	if known != null:
		return known
	var at := Vector2(lon_deg, lat_deg)
	var heights := PackedFloat64Array()
	for arm: Vector2 in [Vector2.ZERO, Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		var place := WeatherRelief.moved(at, arm * SLOPE_ARM_M, profile.radius_m)
		heights.append(data.sample_height_for_direction(HEALPix.lonlat2vec(place.x, place.y), -1, -1, Vector2i(-1, -1),
				null, data.sample_nside_for(RELIEF_NSIDE)))
	# Vector2.DOWN is +y: north here.
	var out := {"height_m": heights[0],
			"upslope": Vector2(heights[1] - heights[2], heights[3] - heights[4]) / (2.0 * SLOPE_ARM_M)}
	_mutex.lock()
	if _relief.size() >= KEPT_MAX:
		_relief.clear()
	_relief[key] = out
	_mutex.unlock()
	return out


## The air of the service's weather on the ground at a place under [param live] systems, or of the fresh
## [param field] when there is one (WeatherSampler.air: band, wind, dust), as the Callable WeatherRelief asks
## it through.
func _air_of(live: Array, field: Array = []) -> Callable:
	var t := now()
	return func(lon: float, lat: float) -> Dictionary: return air_at(lon, lat, live, field, t)


## WeatherSampler.air at (lon, lat) under [param live] systems ([method systems]), kept for that place
## while the systems are that same list: the devils' and walls' places stay put for minutes and are asked
## again at every refresh. With fresh [param field] frames ([method fresh_field]), the field's wind and
## dust at [param t] instead (the band stays the climate's). The Dictionary is shared: read it, never write
## to it. Thread-safe.
func air_at(lon_deg: float, lat_deg: float, live: Array, field: Array = [], t: float = 0.0) -> Dictionary:
	var key := [lon_deg, lat_deg]
	# An empty default list is a new Array at each call: only a held field is told apart by identity.
	var field_key: Variant = field if not field.is_empty() else null
	_air_mutex.lock()
	if not is_same(live, _air_live) or not is_same(field_key, _air_field) or _air_kept.size() >= KEPT_MAX:
		_air_kept.clear()
		_air_live = live
		_air_field = field_key
	var known: Variant = _air_kept.get(key)
	_air_mutex.unlock()
	if known != null:
		return known
	var got := WeatherField.sample_frames(field, lon_deg, lat_deg, t)
	var out: Dictionary
	if got.is_empty():
		out = WeatherSampler.air(profile, live, lon_deg, lat_deg)
	else:
		var we := float(got.get("wind_east", 0.0))
		var wn := float(got.get("wind_north", 0.0))
		out = {"band": WeatherSampler.band_wind(profile, lat_deg)["band"], "wind_east_m_s": we, "wind_north_m_s": wn,
			"wind_speed_m_s": sqrt(we * we + wn * wn), "dust_tau": maxf(float(got.get("dust_tau", 0.0)), 0.0)}
	_air_mutex.lock()
	if is_same(live, _air_live) and is_same(field_key, _air_field):
		_air_kept[key] = out
	_air_mutex.unlock()
	return out


## The dust devils alive now within [param range_m] of a place of [param planet] (WeatherRelief.devils_near).
func devils_near(planet: Planet, lonlat: Vector2, range_m: float) -> Array:
	var t := now()
	return _devils(lonlat, range_m, t, sun_over(planet), systems(planet), fresh_field(planet, t), _sea_shade(planet))


## Under the planet's dust sea (DustSea), how much of a devil the ground can drive at a longitude and latitude:
## Callable(lon_deg, lat_deg) -> 0..1, or none on a planet without the sea.
static func _sea_shade(planet: Planet) -> Callable:
	var data: PlanetData = planet.planet_data if planet != null else null
	if data == null or not DustSea.has_sea(data.atmosphere_profile):
		return Callable()
	return func(lon: float, lat: float) -> float:
		return DustSea.devil_share(data.sample_height_for_direction(HEALPix.lonlat2vec(lon, lat)))


## WeatherRelief.devils_near at [param t] under [param live] systems, the sun at [param sun] (sun_over),
## the cells' hashes kept from one call to the next. Thread-safe.
func _devils(lonlat: Vector2, range_m: float, t: float, sun: Vector2, live: Array, field: Array = [],
		ground_share: Callable = Callable()) -> Array:
	_devil_mutex.lock()
	if _devil_cells.size() >= KEPT_MAX * 4:
		_devil_cells.clear()
	var out := WeatherRelief.devils_near(profile, lonlat, range_m, t, sun.y, sun.x, _air_of(live, field), _devil_cells,
			ground_share)
	_devil_mutex.unlock()
	return out


## The dust walls running now that may reach a place of [param planet] (WeatherRelief.walls_near).
func walls_near(planet: Planet, lonlat: Vector2) -> Array:
	return walls_at(planet, lonlat, now())


## The dust walls running at [param t] (this machine's clock, [method now]) that may reach a place of
## [param planet]: the ones the relief and the day draw (WeatherRelief.walls_near) and the ones called in over
## the planet (ForcedDustWall, WeatherRelief.forced_wall), so that every presenter and the village alarm see
## both. A later [param t] is a forecast: the walls are deterministic, only the service's air they run in is
## taken as it is now.
func walls_at(planet: Planet, lonlat: Vector2, t: float) -> Array:
	var data: PlanetData = planet.planet_data
	var sun := sun_over(planet)
	var air := _air_of(systems(planet), fresh_field(planet, now()))
	_mutex.lock()
	if _wall_sources.size() >= KEPT_MAX:
		_wall_sources.clear()
	var out := WeatherRelief.walls_near(profile, lonlat, t, sun.x,
			func(lon: float, lat: float) -> Dictionary: return relief_at(data, lon, lat), _wall_sources, air)
	var forced := _forced
	_mutex.unlock()
	var reach := WeatherRelief.WALL_CELL_M * WeatherRelief.WALL_REACH_CELLS
	# A called-in wall is an event timed by the server (born_at, dies_at: its clock, which has no dev offset)
	# and lives a few minutes; the dev clock (+ / -) moves this client's sky by hours, which put the wall
	# before its birth or past its end and none was drawn (playtest 2026-11-28). It is placed at the server's
	# time: where the server, its village alarm and every other client have it. The drawn walls above keep
	# the shifted time: they follow the sky, as the dev clock is there to show.
	var server_t := t - dev_clock_offset()
	for one: Dictionary in forced:
		var wall := WeatherRelief.forced_wall(one, server_t, profile.radius_m)
		if not wall.is_empty() and WeatherRelief.offset_m(lonlat, Vector2(wall["lon"], wall["lat"]), profile.radius_m).length() \
				<= reach + float(wall["length_m"]) * 0.5:
			out.append(wall)
	return out


## The weather systems over [param planet] as they will stand at [param t] (WeatherSystem.state_at: walked
## on their keyframes), with what a tool handed in ([method feed]) as it is. Main thread only: it reads the
## nodes. What the village alarm forecasts the storms from.
func systems_at(planet: Planet, t: float) -> Array:
	_mutex.lock()
	var out := _fed.duplicate()
	_mutex.unlock()
	if planet != null and planet.is_inside_tree():
		for node: Node in planet.get_tree().get_nodes_in_group(WeatherSystem.GROUP):
			if node is WeatherSystem and node.get_parent() == planet:
				out.append((node as WeatherSystem).state_at(t))
	return out


## Where the star stands over [param planet] for its weather, (longitude, declination) in degrees: where
## the sky has it (star_lonlat), the declination kept within the climate's tilt. A scene may set its star
## anywhere (Nova's game view has it 39° north of a body tilted 15°); the climate knows no such season.
func sun_over(planet: Planet) -> Vector2:
	var sun := star_lonlat(planet)
	return Vector2(sun.x, clampf(sun.y, -profile.tilt_deg, profile.tilt_deg))


## The shared clock, seconds (0 outside a running game: tests, the editor).
static func now() -> float:
	var loop := Engine.get_main_loop() as SceneTree
	var globals: Node = loop.root.get_node_or_null("Globals") if loop != null else null
	return float(globals.call("sim_time")) if globals != null and globals.has_method("sim_time") else 0.0


## How far the client-only dev clock (Globals.debug_time_offset, the + / - keys) moves [method now] from the
## server's clock, seconds: 0 on the server, in tests and in the editor.
static func dev_clock_offset() -> float:
	var loop := Engine.get_main_loop() as SceneTree
	var globals: Node = loop.root.get_node_or_null("Globals") if loop != null else null
	return float(globals.get("debug_time_offset")) if globals != null and "debug_time_offset" in globals else 0.0


## Where [param planet]'s star stands overhead, (longitude, latitude) in degrees; the latitude is the
## star's declination. (0, 0) without a planet or a star.
static func star_lonlat(planet: Planet) -> Vector2:
	var sun: Node3D = planet.star() if planet != null and planet.is_inside_tree() else null
	if sun == null:
		return Vector2.ZERO
	return HEALPix.vec2lonlat(planet.global_transform.basis.inverse() * (sun.global_position - planet.global_position))
