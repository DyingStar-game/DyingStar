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
var _last_key := []  # [planet id, relief cell, time step] of _last
var _last := {}
var _fed: Array = []
var _systems: Array = []
var _systems_at_ms := -1
var _systems_of := 0
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
	_last_key = []
	_mutex.unlock()


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
	if planet != null and planet.is_inside_tree():
		for node: Node in planet.get_tree().get_nodes_in_group(WeatherSystem.GROUP):
			if node is WeatherSystem and node.get_parent() == planet:
				out.append((node as WeatherSystem).state())
	_mutex.lock()
	_systems = out
	_systems_at_ms = ms
	_systems_of = id
	_mutex.unlock()
	return out


## The service's weather at a longitude and latitude (degrees) and an altitude, under [param live] systems
## ([method systems]), for the star's declination and the longitude it stands over: every key of
## WeatherSampler.sample, and the dust threshold. The one sample behind [method sample] and the weather map.
func sample_at(lon_deg: float, lat_deg: float, altitude_m: float, decl_deg: float, substellar_lon_deg: float,
		live: Array) -> Dictionary:
	var out := WeatherSampler.sample(profile, live, lon_deg, lat_deg, altitude_m,
			WeatherRelief.solar_hours(lon_deg, substellar_lon_deg), decl_deg)
	out["lift_threshold_m_s"] = profile.v10_threshold_m_s
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
	var key := [planet.get_instance_id() if planet != null else 0, cell.x, cell.y, floori(t / SAMPLE_KEPT_S)]
	_mutex.lock()
	var kept := _last.duplicate() if key == _last_key else {}
	_mutex.unlock()
	if not kept.is_empty():
		return kept
	var sun := sun_over(planet)
	var live := systems(planet)
	var out := sample_at(lonlat.x, lonlat.y, 0.0, sun.y, sun.x, live)
	if not local_enabled or planet == null or planet.planet_data == null:
		return out
	var data: PlanetData = planet.planet_data
	var terrain := relief_at(data, lonlat.x, lonlat.y).duplicate()
	if out["band"] == WeatherSampler.BAND_WESTERLIES:
		var wind := Vector2(out["wind_east_m_s"], out["wind_north_m_s"])
		if wind.length() > 0.1:
			var upwind := WeatherRelief.moved(lonlat, -wind.normalized() * LEE_REACH_M, profile.radius_m)
			terrain["upwind_drop_m"] = float(relief_at(data, upwind.x, upwind.y)["height_m"]) - float(terrain["height_m"])
	out = WeatherRelief.apply(out, profile, terrain, WeatherRelief.devils_near(profile, lonlat,
			WeatherRelief.DEVIL_CELL_M, t, sun.y, sun.x, _air_of(sun, live)), walls_near(planet, lonlat),
			Vector3(haze_base_m, haze_top_m, haze_tau), t)
	_mutex.lock()
	_last_key = key
	_last = out
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


## The service's weather on the ground at a place, as the Callable WeatherRelief asks its air through.
func _air_of(sun: Vector2, live: Array) -> Callable:
	return func(lon: float, lat: float) -> Dictionary: return sample_at(lon, lat, 0.0, sun.y, sun.x, live)


## The dust devils alive now within [param range_m] of a place of [param planet] (WeatherRelief.devils_near).
func devils_near(planet: Planet, lonlat: Vector2, range_m: float) -> Array:
	var sun := sun_over(planet)
	return WeatherRelief.devils_near(profile, lonlat, range_m, now(), sun.y, sun.x, _air_of(sun, systems(planet)))


## The dust walls running now that may reach a place of [param planet] (WeatherRelief.walls_near).
func walls_near(planet: Planet, lonlat: Vector2) -> Array:
	var data: PlanetData = planet.planet_data
	var sun := sun_over(planet)
	var air := _air_of(sun, systems(planet))
	_mutex.lock()
	if _wall_sources.size() >= KEPT_MAX:
		_wall_sources.clear()
	var out := WeatherRelief.walls_near(profile, lonlat, now(), sun.x,
			func(lon: float, lat: float) -> Dictionary: return relief_at(data, lon, lat), _wall_sources, air)
	_mutex.unlock()
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


## Where [param planet]'s star stands overhead, (longitude, latitude) in degrees; the latitude is the
## star's declination. (0, 0) without a planet or a star.
static func star_lonlat(planet: Planet) -> Vector2:
	var sun: Node3D = planet.star() if planet != null and planet.is_inside_tree() else null
	if sun == null:
		return Vector2.ZERO
	return HEALPix.vec2lonlat(planet.global_transform.basis.inverse() * (sun.global_position - planet.global_position))
