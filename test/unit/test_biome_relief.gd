extends GutTest
## BiomeRelief: a bounded, deterministic undulation, dropped on coarse grids
## and flattened under roads.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##       -gtest=res://test/unit/test_biome_relief.gd

const RADIUS := 3467000.0
const LAT := 24.8
const LON0 := -39.6


func _bd(lo: float, hi: float, wl: float) -> BiomeDefinition:
	var b := BiomeDefinition.new()
	b.biome_type = "test-relief"
	b.relief_min_m = lo
	b.relief_max_m = hi
	b.relief_wavelength_m = wl
	return b


func _dirs(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(Vector3(sin(i * 0.37), cos(i * 0.53), sin(i * 0.11 + 1.0)).normalized())
	return out


func test_offset_stays_in_range_and_uses_it() -> void:
	var bd := _bd(-0.5, 1.0, 60.0)
	var lo := INF
	var hi := -INF
	for d in _dirs(1000):
		var o := BiomeRelief.offset(d, RADIUS, bd)
		assert_between(o, -0.5 - 1e-9, 1.0 + 1e-9)
		lo = minf(lo, o)
		hi = maxf(hi, o)
	assert_lt(lo, 0.0, "dips below the heightmap")
	assert_gt(hi, 0.5, "and bumps above it")


func test_offset_is_deterministic() -> void:
	var bd := _bd(-0.5, 1.0, 60.0)
	for d in _dirs(50):
		assert_eq(BiomeRelief.offset(d, RADIUS, bd), BiomeRelief.offset(d, RADIUS, bd))


func test_biome_without_relief_gives_zero() -> void:
	assert_false(_bd(0.0, 0.0, 60.0).has_relief())
	assert_eq(BiomeRelief.offset(Vector3.UP, RADIUS, _bd(0.0, 0.0, 60.0)), 0.0)
	assert_eq(BiomeRelief.offset(Vector3.UP, RADIUS, null), 0.0)
	var plateau := load("res://scenes/planet/biomes/outcrop-plateau.tres") as BiomeDefinition
	assert_true(plateau.has_relief(), "the outcrop plateau asks for one")
	var sand := load("res://scenes/planet/biomes/aride_desert-sandy_desert.tres") as BiomeDefinition
	assert_false(sand.has_relief(), "other biomes are untouched")


func test_lod_gate_drops_the_relief_on_a_coarse_grid() -> void:
	var bd := _bd(-0.5, 1.0, 60.0)
	var d := Vector3(0.3, 0.5, 0.8).normalized()
	assert_ne(BiomeRelief.offset(d, RADIUS, bd, 13.5), 0.0, "fine grid (LOD0) carries it")
	assert_eq(BiomeRelief.offset(d, RADIUS, bd, 30.0), 0.0, "half a wavelength: dropped, not faded")
	assert_eq(BiomeRelief.offset(d, RADIUS, bd, 433.0), 0.0, "coarse server grid: dropped")
	# Between the two octave gates only the long one survives (still bounded).
	var mid := BiomeRelief.offset(d, RADIUS, bd, 15.0)
	assert_between(mid, -0.5 - 1e-9, 1.0 + 1e-9)


func _road(hw_total_m: float, road_type: String = "road") -> Dictionary:
	var mpd := RADIUS * PI / 180.0
	var clat := cos(deg_to_rad(LAT))
	var cl := PackedVector2Array()
	for i in 6:
		cl.append(Vector2(LON0 + (i * 200.0) / (mpd * clat), LAT))
	var r := {"centerline": cl, "road_type": road_type, "width_m": hw_total_m, "width": hw_total_m,
			"half_width_m": hw_total_m * 0.5}
	return r


func _at(lat_offset_m: float) -> Vector2:
	var mpd := RADIUS * PI / 180.0
	return Vector2(LON0 + 500.0 / (mpd * cos(deg_to_rad(LAT))), LAT + lat_offset_m / mpd)


func test_road_weight_is_flat_on_the_road_and_full_far_away() -> void:
	var mpd := RADIUS * PI / 180.0
	var roads := [_road(6.0)]   # half-width 3 m
	assert_eq(BiomeRelief.road_weight(_at(0.0), roads, mpd), 0.0, "on the axis")
	assert_eq(BiomeRelief.road_weight(_at(3.0 + 1.9), roads, mpd), 0.0, "inside hw + 2 m")
	assert_almost_eq(BiomeRelief.road_weight(_at(3.0 + 10.5), roads, mpd), 1.0, 1e-9, "past hw + 10 m")
	assert_eq(BiomeRelief.road_weight(_at(500.0), roads, mpd), 1.0)
	assert_eq(BiomeRelief.road_weight(_at(0.0), [], mpd), 1.0, "no road → untouched")
	var prev := 0.0
	var d := 5.5
	while d < 13.0:
		var w := BiomeRelief.road_weight(_at(d), roads, mpd)
		assert_true(w >= prev - 1e-9, "monotone ramp at %.1f m" % d)
		prev = w
		d += 0.5


func test_flat_band_widens_with_the_vertex_pitch() -> void:
	# On a 13.5 m grid every vertex within 1.5 pitches of the road edge is
	# flat, so the interpolated surface under the road cannot rise.
	var mpd := RADIUS * PI / 180.0
	var roads := [_road(6.0)]   # hw 3 m
	assert_eq(BiomeRelief.road_weight(_at(3.0 + 19.0), roads, mpd, 13.5), 0.0, "inside 1.5 pitches")
	assert_gt(BiomeRelief.road_weight(_at(3.0 + 25.0), roads, mpd, 13.5), 0.0, "ramping")
	assert_almost_eq(BiomeRelief.road_weight(_at(3.0 + 41.0), roads, mpd, 13.5), 1.0, 1e-9, "full past 3 pitches")
	# The metre floors still hold on a very fine grid.
	assert_eq(BiomeRelief.road_weight(_at(3.0 + 1.9), roads, mpd, 0.5), 0.0)
	assert_almost_eq(BiomeRelief.road_weight(_at(3.0 + 10.5), roads, mpd, 0.5), 1.0, 1e-9)


func test_road_weight_uses_the_railway_track_width() -> void:
	var mpd := RADIUS * PI / 180.0
	var rail := _road(5.0, "railway")
	rail["tracks"] = 2   # bed half-width 3.44 m, whatever width says
	assert_eq(BiomeRelief.road_weight(_at(3.44 + 1.5), [rail], mpd), 0.0)
	assert_lt(BiomeRelief.road_weight(_at(3.44 + 4.0), [rail], mpd), 1.0)
