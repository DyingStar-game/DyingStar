extends GutTest
## A dust wall called in by an admin (ForcedDustWall) as a client draws it: the server times it on its own clock,
## and the client's dev clock (+ / -, Globals.debug_time_offset) must not take it away. Playtest 2026-11-28: the
## server's village alarm rang for it, but a client whose sky had been moved by hours drew nothing.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_forced_dust_wall.gd

const WALL_SCENE := "res://scenes/_universe/environment/weather/forced_dust_wall.tscn"
## The village M0001 of the playtest, on Tarsis 3.
const VILLAGE := Vector2(-39.553, 24.856)

var _kept_offset := 0.0


func before_each() -> void:
	_kept_offset = Globals.debug_time_offset
	Globals.debug_time_offset = 0.0


func after_each() -> void:
	Globals.debug_time_offset = _kept_offset


## A planet with Tarsis 3's weather and, under it, a wall called in on VILLAGE now on the server's clock,
## received as a client receives it (PropSync's channel data, then into the tree): [planet, weather].
func _client_with_called_wall() -> Array:
	var planet := Planet.new()
	var weather := ClimateWeather.for_body("tarsis_3").duplicate() as ClimateWeather
	planet.weather_source = weather
	planet.planet_data = PlanetData.new()
	add_child_autofree(planet)
	var server_now := ClimateWeather.now() - Globals.debug_time_offset
	var data := ForcedDustWall.spawn_data("planet", "wall-uuid", Vector3.ZERO, VILLAGE, Vector2(3.0, 1.0), server_now,
			weather.profile.radius_m)
	var node: ForcedDustWall = load(WALL_SCENE).instantiate()
	PropSync.of(node).uuid = "wall-uuid"
	PropSync.of(node).client_channel_data_update(data)
	planet.add_child(node)
	return [planet, weather]


## The called-in wall among [param walls] (ClimateWeather.walls_near's), {} when it is not there.
static func _called_in(walls: Array) -> Dictionary:
	for wall: Dictionary in walls:
		if int(wall["id"]) == hash("wall-uuid"):
			return wall
	return {}


func test_the_dev_clock_offset_is_globals_one() -> void:
	assert_eq(ClimateWeather.dev_clock_offset(), 0.0)
	Globals.debug_time_offset = 7200.0
	assert_eq(ClimateWeather.dev_clock_offset(), 7200.0)


func test_a_called_in_wall_is_drawn_without_the_dev_clock() -> void:
	var got := _client_with_called_wall()
	var wall := _called_in((got[1] as ClimateWeather).walls_near(got[0], VILLAGE))
	assert_false(wall.is_empty(), "the wall the server called in, round the village")


func test_the_dev_clock_does_not_take_a_called_in_wall_away() -> void:
	# Set before the wall is called in, as in the playtest: the server's clock knows nothing of it.
	for hours: float in [3.0, -3.0]:
		Globals.debug_time_offset = hours * 3600.0
		var got := _client_with_called_wall()
		var weather: ClimateWeather = got[1]
		var wall := _called_in(weather.walls_near(got[0], VILLAGE))
		assert_false(wall.is_empty(), "drawn with the sky moved by %+.0f h" % hours)
		if wall.is_empty():
			continue
		# Where the server has it now: its front still upwind of the village, by about its lead.
		var front := Vector2(float(wall["lon"]), float(wall["lat"]))
		assert_almost_eq(WeatherRelief.offset_m(front, VILLAGE, weather.profile.radius_m).length(),
				ForcedDustWall.upwind_m(), ForcedDustWall.SPEED_M_S * 5.0,
				"at the server's time, not %+.0f h away from it" % hours)
