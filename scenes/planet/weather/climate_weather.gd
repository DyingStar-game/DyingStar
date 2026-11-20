@tool
class_name ClimateWeather
extends WeatherSource
## A planet's weather from its climate, computed on the client by the weather service's own model: the mean
## wind of each latitude band (WeatherSampler) and the pressure systems and dust storms that are born,
## drift and die (WeatherSynoptic), both pure functions of the body's ClimateProfile, the place and the
## time. No service, nothing sent: every player computes the same sky from the shared clock.
##
## The weather prototype (branch wip/weather, service `weather/`) re-ported onto this hook.
##
## Beside WeatherSource's keys, a sample carries "temperature_k", "pressure_pa", "pressure_anomaly_pa",
## "visibility_m" and "band" (WeatherSampler's names).
##
## On a planet with its relief ([method sample]), the local weather is laid over that (WeatherLocal): the
## plateaus' breeze, the gusts behind the massifs, the permanent haze, dust devils and dust walls.

## Where a body's weather is kept, by its name ("tarsis_3_weather.tres").
const DIR := "res://scenes/planet/climates"
## How long a list of systems is kept before it is computed again, seconds: a system drifts a few hundred
## metres in that time, and consumers ask for the weather many times a frame.
const SYSTEMS_KEPT_S := 30.0
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
@export_group("Weather systems")
## What WeatherSynoptic needs that the profile does not carry, from the service's derived data
## (`weather/data/derived/<system>.json`) and climate knobs (`weather/data/climate/<system>.json`).
## Speed of the jet, m/s: systems drift at about half of it.
@export var u_jet_m_s := 0.0
## Height of the tropopause, metres: with the rotation, it sets the size of a system.
@export var tropopause_m := 10000.0
## How readily the ground gives dust to a storm, 0–1.
@export_range(0.0, 1.0) var dust_lift_bias := 0.5
## Water the air can carry, 0–1: from 0.3 the lows bring rain instead of dust.
@export_range(0.0, 1.0) var humidity_inventory := 0.0
## About how many systems the body carries at once (it sets the lattice's spacing).
@export var max_systems := 48
## False: the climate's mean winds only, no system.
@export var weather_enabled := true

@export_group("Local weather")
## False: the climate and its systems only, nothing from the relief.
@export var local_enabled := true
## Bottom of the permanent haze, metres over the reference sphere: under it the dust is thinner.
@export var haze_base_m := 500.0
## Top of the permanent haze, metres over the reference sphere: the ground standing higher is clear.
@export var haze_top_m := 3500.0
## Optical depth of the permanent haze inside its layer at low latitudes (0.6: 6.5 km of visibility);
## 0 = no haze.
@export var haze_tau := 0.6

var _relief := {}  # [cell x, cell y] → WeatherLocal's terrain
var _wall_sources := {}
var _last_key := []  # [planet id, relief cell, time step] of _last
var _last := {}
var _systems: Array = []
var _systems_at := -INF
var _systems_decl := 0.0
var _mutex := Mutex.new()


## The climate weather of [param body_name], null when the body has none.
static func for_body(body_name: String) -> ClimateWeather:
	var path := DIR.path_join(body_name + "_weather.tres")
	return load(path) as ClimateWeather if ResourceLoader.exists(path) else null


## The systems alive at [param t] (seconds of the shared clock) for the star's declination
## [param decl_deg], kept for SYSTEMS_KEPT_S. Thread-safe.
func systems(t: float, decl_deg: float) -> Array:
	_mutex.lock()
	if absf(t - _systems_at) > SYSTEMS_KEPT_S or decl_deg != _systems_decl:
		_systems = WeatherSynoptic.systems_at(self, t, decl_deg)
		_systems_at = t
		_systems_decl = decl_deg
	var out := _systems
	_mutex.unlock()
	return out


## The weather at a longitude and latitude (degrees) and an altitude, at [param t], for the star's
## declination and the longitude it stands over: every key of WeatherSampler.sample, and the dust
## threshold. The one sample behind [method sample] and the weather map.
func sample_at(lon_deg: float, lat_deg: float, altitude_m: float, t: float, decl_deg: float,
		substellar_lon_deg: float) -> Dictionary:
	var out := WeatherSampler.sample(profile, systems(t, decl_deg), lon_deg, lat_deg, altitude_m,
			WeatherLocal.solar_hours(lon_deg, substellar_lon_deg), decl_deg)
	out["lift_threshold_m_s"] = profile.v10_threshold_m_s
	return out


func sample(planet: Planet, local_dir: Vector3) -> Dictionary:
	if profile == null:
		return {}
	var lonlat := HEALPix.vec2lonlat(local_dir)
	var sun := sun_over(planet)
	var t := now()
	var out := sample_at(lonlat.x, lonlat.y, 0.0, t, sun.y, sun.x)
	if not local_enabled or planet == null or planet.planet_data == null:
		return out
	var data: PlanetData = planet.planet_data
	var cell := WeatherLocal.cell_of(lonlat.x, lonlat.y, RELIEF_CELL_M, profile.radius_m)
	var key := [planet.get_instance_id(), cell.x, cell.y, floori(t / SAMPLE_KEPT_S)]
	_mutex.lock()
	var kept := _last.duplicate() if key == _last_key else {}
	_mutex.unlock()
	if not kept.is_empty():
		return kept
	var terrain := relief_at(data, lonlat.x, lonlat.y).duplicate()
	if out["band"] == WeatherSampler.BAND_WESTERLIES:
		var wind := Vector2(out["wind_east_m_s"], out["wind_north_m_s"])
		if wind.length() > 0.1:
			var upwind := WeatherLocal.moved(lonlat, -wind.normalized() * LEE_REACH_M, profile.radius_m)
			terrain["upwind_drop_m"] = float(relief_at(data, upwind.x, upwind.y)["height_m"]) - float(terrain["height_m"])
	out = WeatherLocal.apply(out, profile, terrain, WeatherLocal.devils_near(profile, lonlat,
			WeatherLocal.DEVIL_CELL_M, t, sun.y, sun.x), walls_near(planet, lonlat), Vector3(haze_base_m, haze_top_m, haze_tau), t)
	_mutex.lock()
	_last_key = key
	_last = out
	_mutex.unlock()
	return out.duplicate()


## The relief the local weather reads at a place of [param data]'s body (WeatherLocal's terrain: height_m,
## upslope), kept by cell of RELIEF_CELL_M. Thread-safe.
func relief_at(data: PlanetData, lon_deg: float, lat_deg: float) -> Dictionary:
	var cell := WeatherLocal.cell_of(lon_deg, lat_deg, RELIEF_CELL_M, profile.radius_m)
	var key := Vector2i(cell.x, cell.y)
	_mutex.lock()
	var known: Variant = _relief.get(key)
	_mutex.unlock()
	if known != null:
		return known
	var at := Vector2(lon_deg, lat_deg)
	var heights := PackedFloat64Array()
	for arm: Vector2 in [Vector2.ZERO, Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		var place := WeatherLocal.moved(at, arm * SLOPE_ARM_M, profile.radius_m)
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


## The dust devils alive now within [param range_m] of a place of [param planet] (WeatherLocal.devils_near).
func devils_near(planet: Planet, lonlat: Vector2, range_m: float) -> Array:
	var sun := sun_over(planet)
	return WeatherLocal.devils_near(profile, lonlat, range_m, now(), sun.y, sun.x)


## The dust walls running now that may reach a place of [param planet] (WeatherLocal.walls_near).
func walls_near(planet: Planet, lonlat: Vector2) -> Array:
	var data: PlanetData = planet.planet_data
	_mutex.lock()
	if _wall_sources.size() >= KEPT_MAX:
		_wall_sources.clear()
	var out := WeatherLocal.walls_near(profile, lonlat, now(), sun_over(planet).x,
			func(lon: float, lat: float) -> Dictionary: return relief_at(data, lon, lat), _wall_sources)
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
